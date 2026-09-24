import Foundation

/// Orchestrates OMP log collection for one store: connect, baseline, then
/// incremental slices. It reads files, parses complete records and hands one
/// slice at a time to the store, where identities, reward arithmetic,
/// checkpoints and the ledger entry are committed in a single transaction.
public actor OMPUsageCollector {
    public enum Trigger: String, Sendable {
        case connect
        case manual
        case scheduled
        case activation
        case resume
    }

    public struct Status: Sendable, Hashable {
        public var source: UsageSourceRecord?
        /// The most recent source row even when it is disconnected. A restored
        /// profile keeps its path here so the app can offer "reconnect" and
        /// explain why collection stopped.
        public var latestSource: UsageSourceRecord?
        public var baselineFilesTotal: Int
        public var baselineFilesDone: Int
        public var isBaselineComplete: Bool
        public var lastRun: UsageScanRunSummary?
        public var totals: UsageTotals
        public var diagnostics: UsageDiagnostics
        public var pendingWork: Bool
    }

    /// Reason recorded on a restored source: the next explicit connect must
    /// treat the whole current log as history instead of continuing from an
    /// older checkpoint.
    public static let restoreReconnectReason = "restore_requires_reconnect"

    private let store: PackTraceStore
    private let scanner: OMPLogScanner
    public nonisolated let rule: UsageRewardRule
    private let limits: OMPLogScanner.Limits
    private let clock: @Sendable () -> Date
    private var inFlight: Task<UsageScanRunSummary, any Error>?
    private var pendingWork = false
    /// Session context per file identity, so continuation reads know the schema
    /// version without re-reading the header every slice.
    private var contextCache: [String: OMPLogParser.Context] = [:]
    private var headerCache: [String: OMPLogParser.SessionHeader] = [:]

    public init(
        store: PackTraceStore,
        scanner: OMPLogScanner = OMPLogScanner(),
        rule: UsageRewardRule = .ompNonCacheV1,
        limits: OMPLogScanner.Limits = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.scanner = scanner
        self.rule = rule
        self.limits = limits
        self.clock = clock
    }

    // MARK: - Connection

    /// Connects a root and fixes the baseline boundary for every file that
    /// exists right now. Nothing found by that pass is ever rewarded; the ids
    /// are recorded so a later copy cannot be rewarded either.
    @discardableResult
    public func connect(root: URL) async throws -> UsageSourceRecord {
        let now = clock()
        let source = try await store.connectUsageSource(rootPath: root.path, now: now)
        let requiresRestoreBaseline = source.lastReason == Self.restoreReconnectReason
        let fresh = source.baselineCompletedAt == nil
        if fresh || requiresRestoreBaseline {
            // Restored profile: fix the boundary at the current end of every
            // file, so work done before this reconnect is history, not reward.
            try await seedBaselineCheckpoints(
                root: root,
                sourceID: source.sourceID,
                now: now,
                resetExisting: requiresRestoreBaseline
            )
        }
        _ = try await scan(trigger: .connect)
        guard let updated = try await store.usageSource(tool: .omp) else { throw PackTraceError.usageSourceNotConnected }
        return updated
    }

    private func seedBaselineCheckpoints(
        root: URL,
        sourceID: String,
        now: Date,
        resetExisting: Bool = false
    ) async throws {
        let discovered: [OMPLogScanner.DiscoveredFile]
        do {
            discovered = try scanner.discover(root: root, limits: limits)
        } catch OMPLogScanner.ScanError.rootMissing {
            try await store.setUsageSourceStatus(.rootMissing, reason: "root_missing")
            return
        } catch OMPLogScanner.ScanError.permissionDenied {
            try await store.setUsageSourceStatus(.permissionDenied, reason: "permission_denied")
            return
        }
        let existing = Set(try await store.usageCheckpoints(sourceID: sourceID).map(\.relativePath))
        var checkpoints: [UsageFileCheckpoint] = []
        for file in discovered where resetExisting || !existing.contains(file.relativePath) {
            let boundary = (try? scanner.lastCompleteRecordOffset(of: file, limits: limits)) ?? 0
            checkpoints.append(
                UsageFileCheckpoint(
                    relativePath: file.relativePath,
                    deviceID: file.deviceID,
                    inode: file.inode,
                    // A first connect walks the existing region so its event ids
                    // are recorded as history. A reconnect after a restore only
                    // moves the boundary: everything already in the logs stays
                    // unpriced, whatever it contains.
                    byteOffset: resetExisting ? boundary : 0,
                    baselineOffset: boundary,
                    baselineDone: resetExisting ? true : boundary == 0,
                    fileSize: file.size,
                    status: .ok,
                    reason: nil,
                    updatedAt: now
                )
            )
        }
        if !checkpoints.isEmpty {
            try await store.applyUsageBatch(
                sourceID: sourceID,
                baseline: true,
                entries: [],
                checkpoints: checkpoints,
                run: UsageScanRunSummary(
                    runID: UUID().uuidString.lowercased(),
                    trigger: "baseline-seed",
                    startedAt: now,
                    finishedAt: now,
                    filesConsidered: checkpoints.count
                ),
                rule: rule,
                now: now
            )
        }
    }

    /// A file discovered after the baseline. What it holds when found is read
    /// from the start and checked against the connection time record by record
    /// (`baselineOffset` marks that region); what is appended later is new.
    private func checkpointForNewFile(_ file: OMPLogScanner.DiscoveredFile, now: Date) -> UsageFileCheckpoint {
        UsageFileCheckpoint(
            relativePath: file.relativePath,
            deviceID: file.deviceID,
            inode: file.inode,
            byteOffset: 0,
            baselineOffset: file.size,
            baselineDone: true,
            fileSize: file.size,
            status: .ok,
            reason: nil,
            updatedAt: now
        )
    }

    // MARK: - Scanning

    /// Runs one bounded slice. Concurrent callers share the in-flight slice
    /// instead of scanning twice.
    @discardableResult
    public func scan(trigger: Trigger) async throws -> UsageScanRunSummary {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task<UsageScanRunSummary, any Error> { [self] in
            defer { inFlight = nil }
            return try await performSlice(trigger: trigger)
        }
        inFlight = task
        return try await task.value
    }

    public func pause() async throws {
        try await store.setUsageSourcePaused(true, now: clock())
    }

    public func resume() async throws {
        try await store.setUsageSourcePaused(false, now: clock())
        _ = try await scan(trigger: .resume)
    }

    public func status() async throws -> Status {
        let source = try await store.usageSource(tool: .omp)
        var latestSource = source
        if latestSource == nil {
            latestSource = try await store.latestUsageSource(tool: .omp)
        }
        let checkpoints = try await store.usageCheckpoints(sourceID: latestSource?.sourceID)
        let totals = try await store.usageTotals(ruleID: rule.ruleID)
        let diagnostics = try await store.usageDiagnostics(ruleID: rule.ruleID)
        let baselineTotal = checkpoints.filter { $0.baselineOffset > 0 || !$0.baselineDone }.count
        let baselineDone = checkpoints.filter(\.baselineDone).count
        return Status(
            source: source,
            latestSource: latestSource,
            baselineFilesTotal: baselineTotal,
            baselineFilesDone: baselineDone,
            isBaselineComplete: source?.baselineCompletedAt != nil,
            lastRun: diagnostics.lastRun,
            totals: totals,
            diagnostics: diagnostics,
            pendingWork: pendingWork
        )
    }

    // MARK: - Slice

    private func performSlice(trigger: Trigger) async throws -> UsageScanRunSummary {
        let startedAt = clock()
        var summary = UsageScanRunSummary(
            runID: UUID().uuidString.lowercased(),
            trigger: trigger.rawValue,
            startedAt: startedAt,
            finishedAt: startedAt
        )

        guard let source = try await store.usageSource(tool: .omp) else {
            // No active source: never connected, or a restored profile that is
            // waiting for an explicit reconnect. Nothing to read, and this is a
            // state the UI explains rather than an error to report.
            summary.skippedReason = "usage_source_unconnected"
            summary.finishedAt = clock()
            pendingWork = false
            return summary
        }
        if source.isPaused {
            summary.finishedAt = clock()
            pendingWork = false
            return summary
        }

        let root = URL(fileURLWithPath: source.rootPath)
        let discovered: [OMPLogScanner.DiscoveredFile]
        do {
            discovered = try scanner.discover(root: root, limits: limits)
        } catch OMPLogScanner.ScanError.rootMissing {
            try await store.setUsageSourceStatus(.rootMissing, reason: "root_missing", now: clock())
            summary.errors = 1
            summary.finishedAt = clock()
            return summary
        } catch OMPLogScanner.ScanError.permissionDenied {
            try await store.setUsageSourceStatus(.permissionDenied, reason: "permission_denied", now: clock())
            summary.errors = 1
            summary.finishedAt = clock()
            return summary
        }

        var checkpoints: [String: UsageFileCheckpoint] = [:]
        for checkpoint in try await store.usageCheckpoints(sourceID: source.sourceID) {
            checkpoints[checkpoint.relativePath] = checkpoint
        }
        let isBaselining = source.baselineCompletedAt == nil
        summary.filesConsidered = discovered.count
        summary.baseline = isBaselining

        // A tracked file that disappeared is reported, not silently forgotten:
        // the ledger and the recorded events stay as they are.
        let discoveredPaths = Set(discovered.map(\.relativePath))
        var missingCheckpoints: [UsageFileCheckpoint] = []
        for (path, checkpoint) in checkpoints where !discoveredPaths.contains(path) && checkpoint.status != .missing {
            var updated = checkpoint
            updated.status = .missing
            updated.reason = "file_missing"
            updated.updatedAt = clock()
            checkpoints[path] = updated
            missingCheckpoints.append(updated)
        }
        if !missingCheckpoints.isEmpty {
            summary.errors += missingCheckpoints.count
            try await persist(
                sourceID: source.sourceID,
                baseline: false,
                entries: [],
                checkpoints: missingCheckpoints,
                summary: summary,
                startedAt: startedAt
            )
        }

        var inheritedCount = 0
        var budgetRecords = 0
        var budgetBytes: Int64 = 0
        var budgetFiles = 0
        var moreWork = false

        for file in discovered {
            if budgetFiles >= limits.maxFilesPerSlice || budgetRecords >= limits.maxRecordsPerSlice || budgetBytes >= Int64(limits.maxBytesPerSlice) {
                moreWork = true
                break
            }

            var checkpoint = checkpoints[file.relativePath] ?? {
                let fresh = isBaselining
                    ? UsageFileCheckpoint(
                        relativePath: file.relativePath,
                        deviceID: file.deviceID,
                        inode: file.inode,
                        byteOffset: 0,
                        baselineOffset: (try? scanner.lastCompleteRecordOffset(of: file, limits: limits)) ?? 0,
                        baselineDone: false,
                        fileSize: file.size,
                        status: .ok,
                        reason: nil,
                        updatedAt: clock()
                    )
                    : checkpointForNewFile(file, now: clock())
                checkpoints[file.relativePath] = fresh
                return fresh
            }()

            let previousOffset = checkpoint.byteOffset
            let readingBaseline = !checkpoint.baselineDone
            let unchanged = checkpoint.inode == file.inode
                && checkpoint.deviceID == file.deviceID
                && checkpoint.fileSize == file.size
                && checkpoint.byteOffset == file.size
                && checkpoint.baselineDone
            if unchanged {
                // Incremental: nothing was appended, so the file is not read.
                continue
            }

            guard let context = resolveContext(for: file) else {
                // The header has not been written yet. Leave the checkpoint
                // where it is so nothing is skipped over; a file that never
                // gets a header is reported instead of silently ignored.
                let age = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date) ?? nil
                if let age, clock().timeIntervalSince(age) > 300 {
                    summary.errors += 1
                    checkpoint.status = .error
                    checkpoint.reason = "missing_session_header"
                    checkpoint.updatedAt = clock()
                    checkpoints[file.relativePath] = checkpoint
                    try await persist(
                        sourceID: source.sourceID,
                        baseline: readingBaseline,
                        entries: [],
                        checkpoints: [checkpoint],
                        summary: summary,
                        startedAt: startedAt
                    )
                } else {
                    moreWork = true
                }
                continue
            }

            var outcome: OMPLogScanner.ReadOutcome
            do {
                outcome = try scanner.read(
                    file: file,
                    from: checkpoint.byteOffset,
                    limit: readingBaseline ? checkpoint.baselineOffset : nil,
                    context: context,
                    limits: limits
                )
            } catch {
                summary.errors += 1
                checkpoint.status = Self.fileStatus(for: error)
                checkpoint.reason = "read_failed"
                checkpoint.updatedAt = clock()
                checkpoints[file.relativePath] = checkpoint
                try await persist(
                    sourceID: source.sourceID,
                    baseline: readingBaseline,
                    entries: [],
                    checkpoints: [checkpoint],
                    summary: summary,
                    startedAt: startedAt
                )
                continue
            }

            // A file that appears only after the connection can still carry
            // history (a fork or an import cloned from an older session). Those
            // records occurred before the connection, so they are recorded as
            // baseline and never rewarded; anything that happened after the
            // connection is collected normally. This holds for every slice of the
            // region found in the file, not only the first: a large file is read
            // over several slices.
            if !readingBaseline, previousOffset < checkpoint.baselineOffset, let cutoff = source.connectedAt as Date? {
                let cutoffMilliseconds = Int(cutoff.timeIntervalSince1970 * 1000)
                outcome.entries = outcome.entries.map { entry in
                    guard let event = entry.event,
                          entry.status == .accepted,
                          event.occurredAtMilliseconds < cutoffMilliseconds
                    else { return entry }
                    return UsageBatchEntry(
                        event: event,
                        status: .baseline,
                        reason: .inheritedPreConnection
                    )
                }
                if outcome.entries.contains(where: { $0.reason == .inheritedPreConnection }) {
                    inheritedCount += outcome.entries.filter { $0.reason == .inheritedPreConnection }.count
                }
            }

            if outcome.oversizedRecords > 0 {
                for _ in 0..<outcome.oversizedRecords {
                    outcome.entries.append(
                        UsageBatchEntry(event: nil, status: .unsupported, reason: .oversizedRecord)
                    )
                }
            }
            budgetFiles += 1
            budgetRecords += outcome.recordsSeen
            budgetBytes += outcome.bytesRead
            summary.filesRead += 1
            summary.bytesRead += outcome.bytesRead
            summary.recordsSeen += outcome.recordsSeen
            summary.unsupported += outcome.oversizedRecords

            checkpoint.byteOffset = outcome.nextOffset
            checkpoint.fileSize = file.size
            checkpoint.inode = file.inode
            checkpoint.deviceID = file.deviceID
            if readingBaseline, outcome.nextOffset >= checkpoint.baselineOffset {
                checkpoint.baselineDone = true
            }
            if outcome.rotated {
                checkpoint.status = .rotated
                checkpoint.reason = "identity_changed"
            } else if checkpoint.status != .rotated {
                checkpoint.status = .ok
                checkpoint.reason = nil
            }
            checkpoint.updatedAt = clock()
            checkpoints[file.relativePath] = checkpoint

            let excluded = outcome.entries.filter { $0.status == .excluded }.count
            let unsupported = outcome.entries.filter { $0.status == .unsupported }.count
            summary.excluded += excluded
            summary.unsupported += unsupported

            let result: UsageBatchResult
            do {
                result = try await store.applyUsageBatch(
                    sourceID: source.sourceID,
                    baseline: readingBaseline,
                    entries: outcome.entries,
                    checkpoints: [checkpoint],
                    run: summary,
                    // The header may be far above this slice's window, so the
                    // cached one from the file's first bytes is used when the
                    // slice itself did not cross it.
                    sessionHeader: outcome.sessionHeader ?? resolveHeader(for: file),
                    rule: rule,
                    recordRun: false,
                    now: clock()
                )
            } catch {
                // The store rolled the whole batch back, including the
                // checkpoint. Report it and stop this slice without advancing
                // so the records are retried later instead of being lost.
                summary.errors += 1
                var failed = checkpoint
                // Keep the read position where it was: the records were not
                // recorded, so the next slice must see them again.
                failed.byteOffset = previousOffset
                failed.baselineDone = checkpoint.baselineDone && previousOffset >= checkpoint.baselineOffset
                failed.status = .error
                failed.reason = Self.batchFailureReason(for: error)
                failed.updatedAt = clock()
                // Best effort: the batch already failed; this only records it.
                _ = try? await store.applyUsageBatch(
                    sourceID: source.sourceID,
                    baseline: false,
                    entries: [],
                    checkpoints: [failed],
                    run: summary,
                    rule: rule,
                    recordRun: false,
                    now: clock()
                )
                checkpoints[file.relativePath] = failed
                pendingWork = true
                summary.finishedAt = clock()
                summary.moreWork = true
                // Best effort: the batch already failed; this only records it.
                _ = try? await store.applyUsageBatch(
                    sourceID: source.sourceID,
                    baseline: false,
                    entries: [],
                    checkpoints: [],
                    run: summary,
                    rule: rule,
                    now: clock()
                )
                return summary
            }
            summary.inserted += result.inserted
            summary.duplicates += result.duplicates
            summary.conflicts += result.conflicts
            summary.acceptedTokens += result.acceptedTokens
            summary.pointsAwarded += result.pointsAwarded
            summary.errors += result.conflicts

            let stillHasData = !outcome.reachedEOF
            if stillHasData {
                moreWork = true
                break
            }
            if outcome.recordsSeen >= limits.maxRecordsPerSlice || outcome.bytesRead >= Int64(limits.maxBytesPerSlice) {
                moreWork = true
                break
            }
        }

        // Baseline is complete when every tracked file has been recorded, or can
        // not be: a file that is gone, unreadable or has no session header would
        // otherwise hold the baseline open for good — collecting nothing, and
        // treating every new session as history until it closed.
        if isBaselining {
            let allDone = try await store.usageCheckpoints(sourceID: source.sourceID).allSatisfy { checkpoint in
                checkpoint.baselineDone || [.missing, .permissionDenied, .error].contains(checkpoint.status)
            }
            if allDone {
                try await store.markUsageSourceBaselined(now: clock())
                summary.baseline = false
            } else {
                moreWork = true
            }
        }

        summary.inherited = inheritedCount
        try await store.recordUsageScanTime(clock())
        summary.trigger = trigger.rawValue
        summary.finishedAt = clock()
        summary.moreWork = moreWork
        pendingWork = moreWork
        // Persist the final slice summary (the per-file batches wrote their own
        // snapshots; this keeps the latest state visible to diagnostics).
        try await store.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: false,
            entries: [],
            checkpoints: [],
            run: summary,
            rule: rule,
            now: clock()
        )
        return summary
    }

    private func persist(
        sourceID: String,
        baseline: Bool,
        entries: [UsageBatchEntry],
        checkpoints: [UsageFileCheckpoint],
        summary: UsageScanRunSummary,
        startedAt: Date
    ) async throws {
        _ = try await store.applyUsageBatch(
            sourceID: sourceID,
            baseline: baseline,
            entries: entries,
            checkpoints: checkpoints,
            run: summary,
            rule: rule,
            recordRun: false,
            now: clock()
        )
    }

    private func resolveContext(for file: OMPLogScanner.DiscoveredFile) -> OMPLogParser.Context? {
        let key = "\(file.relativePath)|\(file.inode)"
        if let cached = contextCache[key] { return cached }
        guard let header = resolveHeader(for: file) else { return nil }
        let context = OMPLogParser.Context(sessionID: header.id, schemaVersion: header.version)
        contextCache[key] = context
        return context
    }

    /// Header of a file, cached per identity. Read from the first bytes of the
    /// file, so a slice that resumes mid-file still knows the session and any
    /// fork origin it declares.
    private func resolveHeader(for file: OMPLogScanner.DiscoveredFile) -> OMPLogParser.SessionHeader? {
        let key = "\(file.relativePath)|\(file.inode)"
        if let cached = headerCache[key] { return cached }
        guard let header = scanner.sessionHeader(for: file, limits: limits) else { return nil }
        headerCache[key] = header
        return header
    }

    /// Reason code stored with a file whose batch failed. No log content and no
    /// paths beyond the file's own relative path.
    static func batchFailureReason(for error: any Error) -> String {
        if case let PackTraceError.usageRewardOverflow(ruleID) = error {
            return "award_overflow:\(ruleID)"
        }
        if case let PackTraceError.injectedFailure(label) = error {
            return "injected_failure:\(label)"
        }
        return "storage_failure"
    }

    static func fileStatus(for error: any Error) -> UsageFileStatus {
        let text = String(describing: error)
        if text.contains("permission") || text.contains("EACCES") || text.contains("Operation not permitted") {
            return .permissionDenied
        }
        if text.contains("no such file") || text.contains("doesn't exist") {
            return .missing
        }
        return .error
    }
}
