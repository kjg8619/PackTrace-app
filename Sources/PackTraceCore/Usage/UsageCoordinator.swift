import Foundation

/// Runs the adapters against one store.
///
/// One slice per source per pass, so a source with a large backlog cannot hold
/// the others (or the UI) while it catches up: the next pass comes back to it.
/// A failing source is recorded and skipped; it never stops the others. The
/// store decides reward — the coordinator only moves reading positions.
///
/// OMP is still collected by `OMPUsageCollector` during this transition; this
/// coordinator owns the tools whose adapters live here.
public actor UsageCoordinator {
    public enum Trigger: String, Sendable {
        case connect
        case manual
        case scheduled
        case activation
        case resume
    }

    public struct SourceStatus: Sendable, Hashable, Identifiable {
        public var id: String { source.sourceID }
        public var source: UsageSourceRecord
        public var inspection: UsageSourceInspection
        public var lastRun: UsageScanRunSummary?
        public var acceptedTokens: Int
        public var acceptedEvents: Int
        public var pendingWork: Bool
    }

    private let store: PackTraceStore
    private let registry: UsageAdapterRegistry
    private let rule: UsageRewardRule
    private let budget: UsageScanBudget
    private let clock: @Sendable () -> Date
    private var inFlight: Task<UsageScanRunSummary, any Error>?
    private var nextSourceIndex = 0
    private var lastRuns: [String: UsageScanRunSummary] = [:]
    private var pending: Set<String> = []

    public init(
        store: PackTraceStore,
        registry: UsageAdapterRegistry,
        rule: UsageRewardRule = .ompNonCacheV1,
        budget: UsageScanBudget = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.registry = registry
        self.rule = rule
        self.budget = budget
        self.clock = clock
    }

    /// Connects a tool's storage. The first scan fixes that tool's baseline, so
    /// nothing already on disk is credited.
    @discardableResult
    public func connect(tool: UsageToolKind, rootPath: URL) async throws -> UsageSourceRecord {
        let source = try await store.connectUsageSource(tool: tool, rootPath: rootPath.path, now: clock())
        if let adapter = registry.adapter(for: tool) {
            let inspection = adapter.inspect(source: source)
            try await store.updateUsageSourceMetadata(
                sourceID: source.sourceID,
                toolVersion: inspection.toolVersion,
                formatVersion: inspection.formatVersion
            )
        }
        _ = try? await scan(trigger: .connect)
        return try await store.usageSource(id: source.sourceID) ?? source
    }

    /// One pass: one bounded slice for each connected source, starting where the
    /// previous pass stopped so the order rotates.
    @discardableResult
    public func scan(trigger: Trigger) async throws -> UsageScanRunSummary {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<UsageScanRunSummary, any Error> { [self] in
            defer { inFlight = nil }
            return try await performPass(trigger: trigger)
        }
        inFlight = task
        return try await task.value
    }

    private func performPass(trigger: Trigger) async throws -> UsageScanRunSummary {
        let started = clock()
        var summary = UsageScanRunSummary(
            runID: UUID().uuidString.lowercased(),
            trigger: trigger.rawValue,
            startedAt: started,
            finishedAt: started
        )
        let sources = try await store.usageSources().filter { registry.adapter(for: $0.tool) != nil }
        guard !sources.isEmpty else {
            summary.skippedReason = "no_sources_for_registered_adapters"
            summary.finishedAt = clock()
            return summary
        }
        let ordered = rotate(sources, by: nextSourceIndex)
        nextSourceIndex = (nextSourceIndex + 1) % max(sources.count, 1)
        pending.removeAll()

        for source in ordered {
            if source.isPaused {
                summary.excluded += 1
                continue
            }
            do {
                try await scanOnce(source: source, trigger: trigger, into: &summary)
            } catch {
                // One source's failure is recorded on that source and never
                // stops the others.
                summary.errors += 1
                try? await store.setUsageSourceStatus(
                    .permissionDenied,
                    reason: OMPUsageCollector.batchFailureReason(for: error),
                    sourceID: source.sourceID,
                    now: clock()
                )
            }
        }
        summary.finishedAt = clock()
        summary.moreWork = !pending.isEmpty
        return summary
    }

    private func scanOnce(
        source: UsageSourceRecord,
        trigger: Trigger,
        into summary: inout UsageScanRunSummary
    ) async throws {
        guard let adapter = registry.adapter(for: source.tool) else { return }
        let isBaselining = source.baselineCompletedAt == nil
        let request = UsageSliceRequest(
            source: source,
            fileCheckpoints: try await store.usageCheckpoints(sourceID: source.sourceID),
            cursors: try await store.usageCursors(sourceID: source.sourceID),
            budget: budget,
            isBaselining: isBaselining,
            now: clock()
        )
        let output = try await adapter.scanSlice(request)

        var run = UsageScanRunSummary(
            runID: UUID().uuidString.lowercased(),
            trigger: trigger.rawValue,
            startedAt: request.now,
            finishedAt: clock(),
            filesConsidered: output.counters.filesConsidered,
            filesRead: output.counters.filesRead,
            bytesRead: Int64(output.counters.bytesRead),
            recordsSeen: output.counters.recordsSeen,
            excluded: output.entries.filter { $0.status == .excluded }.count,
            unsupported: output.counters.unsupported + output.entries.filter { $0.status == .unsupported }.count,
            errors: output.counters.errorCount,
            baseline: isBaselining,
            moreWork: output.moreWork
        )

        // A source with nothing to read yet is not an error, and an empty
        // baseline pass still needs its boundary committed.
        let result = try await store.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: isBaselining,
            entries: output.entries,
            checkpoints: output.fileCheckpoints,
            cursors: output.cursors,
            sessions: output.sessions,
            run: run,
            rule: rule,
            now: clock()
        )
        if let status = output.status {
            try await store.setUsageSourceStatus(
                status,
                reason: output.statusReason,
                sourceID: source.sourceID,
                now: clock()
            )
        } else if isBaselining, output.moreWork == false {
            // The boundary is fixed for everything that exists now.
            try await store.markUsageSourceBaselined(sourceID: source.sourceID, now: clock())
        } else if !isBaselining {
            try await store.setUsageSourceStatus(
                .collecting,
                reason: nil,
                sourceID: source.sourceID,
                now: clock()
            )
        }

        run.inserted = result.inserted
        run.duplicates = result.duplicates
        run.conflicts = result.conflicts
        run.acceptedTokens = result.acceptedTokens
        run.pointsAwarded = result.pointsAwarded
        lastRuns[source.sourceID] = run
        if output.moreWork { pending.insert(source.sourceID) }

        summary.filesConsidered += output.counters.filesConsidered
        summary.filesRead += output.counters.filesRead
        summary.bytesRead += Int64(output.counters.bytesRead)
        summary.recordsSeen += output.counters.recordsSeen
        summary.inserted += result.inserted
        summary.duplicates += result.duplicates
        summary.conflicts += result.conflicts
        summary.acceptedTokens += result.acceptedTokens
        summary.pointsAwarded += result.pointsAwarded
    }

    private func rotate(_ sources: [UsageSourceRecord], by offset: Int) -> [UsageSourceRecord] {
        guard !sources.isEmpty else { return sources }
        let index = offset % sources.count
        return Array(sources[index...] + sources[..<index])
    }

    // MARK: - Status

    public func status() async throws -> [SourceStatus] {
        let totals = try await store.usageToolTotals(ruleID: rule.ruleID)
        let byTool = Dictionary(uniqueKeysWithValues: totals.map { ($0.tool, $0) })
        return try await store.allUsageSourceRows().map { source in
            let adapter = registry.adapter(for: source.tool)
            let inspection = adapter?.inspect(source: source)
                ?? UsageSourceInspection(support: .unsupportedVersion, detail: "이 도구의 어댑터가 없습니다")
            let toolTotals = byTool[source.tool]
            return SourceStatus(
                source: source,
                inspection: inspection,
                lastRun: lastRuns[source.sourceID],
                acceptedTokens: toolTotals?.acceptedTokens ?? 0,
                acceptedEvents: toolTotals?.acceptedEvents ?? 0,
                pendingWork: pending.contains(source.sourceID)
            )
        }
    }

    /// Candidates discovered on this machine. Discovery never connects, and it
    /// touches nothing: it only asks each adapter where its storage would be.
    public nonisolated func candidates() -> [UsageSourceCandidate] {
        registry.candidates()
    }

    public func pause(sourceID: String) async throws {
        try await store.setUsageSourcePaused(true, sourceID: sourceID, now: clock())
    }

    public func resume(sourceID: String) async throws {
        try await store.setUsageSourcePaused(false, sourceID: sourceID, now: clock())
        _ = try await scan(trigger: .resume)
    }

    /// Disconnects one source without touching any other.
    public func disconnect(sourceID: String) async throws {
        try await store.setUsageSourceStatus(
            .unconnected,
            reason: "disconnected_by_user",
            sourceID: sourceID,
            now: clock()
        )
    }

    /// The adapters this coordinator can credit through.
    public nonisolated var tools: [UsageToolKind] { registry.tools }
}
