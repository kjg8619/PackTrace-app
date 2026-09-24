import Foundation
import PackTraceCore

/// Connects an AI tool's usage storage to the real wallet, from the terminal.
///
/// The same action the settings panel offers, for when the app is not in front:
/// it opens the production profile, connects the tool, and lets the first scan
/// fix that tool's baseline. Nothing already in the storage is credited — the
/// connection moment is the boundary — so this is safe to run at any time.
enum UsageTool {
    static func run(mode: String, flags: [String: String], log: (String) -> Void) async throws {
        let network = UsageAdapterRegistry.standard
        let home = FileManager.default.homeDirectoryForCurrentUser

        switch mode {
        case "list":
            log("== candidates on this machine ==")
            for candidate in network.candidates(home: home, environment: ProcessInfo.processInfo.environment) {
                log("  \(candidate.identity.tool.rawValue)\t\(candidate.maskedPath)\t\(candidate.exists ? "found" : "missing")")
            }
            try await status(log: log)

        case "connect":
            guard let name = flags["--tool"] else { throw UsageToolError.missingFlag("--tool") }
            guard let tool = UsageToolKind(rawValue: name) else { throw UsageToolError.unknownTool(name) }
            let root = try resolveRoot(tool: tool, flags: flags, home: home, network: network)
            let (store, coordinator) = try await openProduction()
            let source = try await coordinator.connect(tool: tool, rootPath: root)
            log("connected \(tool.rawValue)")
            log("  path      \(UsageSourceIdentity.mask(source.rootPath))")
            log("  status    \(source.status.rawValue)")
            log("  baseline  \(source.baselineCompletedAt == nil ? "설정 중(다음 스캔에서 확정)" : "완료")")
            log("  이 시점 이전의 기록은 소급 지급되지 않습니다")
            await store.close()

        case "disconnect":
            guard let name = flags["--tool"] else { throw UsageToolError.missingFlag("--tool") }
            guard let tool = UsageToolKind(rawValue: name) else { throw UsageToolError.unknownTool(name) }
            let (store, coordinator) = try await openProduction()
            for source in try await store.usageSources().filter({ $0.tool == tool }) {
                try await coordinator.disconnect(sourceID: source.sourceID)
                log("disconnected \(tool.rawValue) \(UsageSourceIdentity.mask(source.rootPath))")
            }
            await store.close()

        case "status":
            try await status(log: log)

        case "correction":
            try await correction(flags: flags, log: log)

        default:
            throw UsageToolError.unknownMode(mode)
        }
    }

    /// The real profile: the same database the app writes. Opened through the
    /// store so every invariant (identity, baseline, reward) still applies.
    static func openProduction() async throws -> (PackTraceStore, UsageCoordinator) {
        let library = try CatalogLoader.bundledLibrary()
        let location = try StoreLocation.applicationSupport(realm: .production)
        let store = try PackTraceStore(location: location, library: library)
        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry.standard
        )
        return (store, coordinator)
    }

    static func resolveRoot(
        tool: UsageToolKind,
        flags: [String: String],
        home: URL,
        network: UsageAdapterRegistry
    ) throws -> URL {
        if let path = flags["--root"] { return URL(fileURLWithPath: path) }
        guard let adapter = network.adapter(for: tool),
              let candidate = adapter.candidates(home: home, environment: ProcessInfo.processInfo.environment).first(where: \.exists)
        else { throw UsageToolError.noCandidate(tool.rawValue) }
        return URL(fileURLWithPath: candidate.identity.canonicalPath)
    }

    /// One incident's correction: dry-run by default, and the real apply only
    /// when the caller states the size of the target set it expects. A plan made
    /// against a different set or account is refused instead of applied.
    static func correction(flags: [String: String], log: (String) -> Void) async throws {
        guard let incidentID = flags["--incident"], !incidentID.isEmpty else {
            throw UsageToolError.missingFlag("--incident")
        }
        // A name that is not a tool is an error: falling back to OpenCode planned
        // a correction against the wrong source on a typo.
        let name = flags["--tool"] ?? "opencode"
        guard let tool = UsageToolKind(rawValue: name) else { throw UsageToolError.unknownTool(name) }
        let apply = flags["--apply"] != nil
        let (store, _) = try await openProduction()
        defer { Task { await store.close() } }

        let sources = try await store.allUsageSourceRows().filter { $0.tool == tool }
        guard let source = sources.first else { throw UsageToolError.noCandidate(tool.rawValue) }
        // Several roots of one tool: the plan would silently pick one of them.
        guard sources.count == 1 else { throw UsageToolError.ambiguousSource(tool.rawValue, sources.count) }
        let plan = try await store.usageCorrectionPlan(incidentID: incidentID, sourceID: source.sourceID)

        log("== correction plan (\(apply ? "apply" : "dry-run")) ==")
        log("  incident   \(plan.incidentID)")
        log("  source     \(source.tool.rawValue) \(UsageSourceIdentity.mask(source.rootPath))")
        log("  events     \(plan.eventCount)")
        log("  excluded   \(plan.excludedTokens) tokens")
        log("  digest     \(plan.eventDigest)")
        log("  before     accepted=\(plan.beforeAcceptedTokens) points=\(plan.beforePoints) remainder=\(plan.beforeRemainder) balance=\(plan.beforeBalance)")
        log("  after      accepted=\(plan.afterAcceptedTokens) points=\(plan.afterPoints) remainder=\(plan.afterRemainder)")
        log("  adjustment \(plan.deltaPoints) P")
        log("  expected   balance=\(plan.expectedBalance) P")
        log("  applicable \(plan.isApplicable)\(plan.blockedReason.map { " (\($0))" } ?? "")")

        guard apply else { return }
        guard plan.isApplicable else { throw UsageCorrectionError.blocked(plan.blockedReason ?? "unknown") }
        // The caller must state what it believes it is correcting.
        if let expectedEvents = flags["--expect-events"], Int(expectedEvents) != plan.eventCount {
            throw UsageCorrectionError.blocked("대상 이벤트 수가 기대값과 다릅니다(\(plan.eventCount) != \(expectedEvents))")
        }
        if let expectedTokens = flags["--expect-tokens"], Int(expectedTokens) != plan.excludedTokens {
            throw UsageCorrectionError.blocked("제외 토큰이 기대값과 다릅니다(\(plan.excludedTokens) != \(expectedTokens))")
        }
        if let expectedDigest = flags["--expect-digest"], expectedDigest != plan.eventDigest {
            throw UsageCorrectionError.blocked("대상 집합 지문이 기대값과 다릅니다")
        }
        let applied = try await store.applyUsageCorrection(plan)
        log("== applied ==")
        log("  adjustment \(applied.deltaPoints) P · valid accepted=\(applied.afterAcceptedTokens) points=\(applied.afterPoints) remainder=\(applied.afterRemainder)")
        log("  corrections=\(try await store.corrections().count)")
    }

    /// Read-only report of the real profile: sources, accepted tokens per tool
    /// and the shared account. It cannot create a database, run a migration or
    /// start collecting, even if the profile is missing or older.
    static func status(log: (String) -> Void) async throws {
        let database = try StoreLocation.applicationSupport(realm: .production).databaseURL
        log("== production profile (read-only) ==")
        guard let report = try UsageProfileReader().read(databaseURL: database) else {
            log("  아직 데이터베이스가 없습니다(앱을 한 번 실행하면 만들어집니다)")
            return
        }
        log("  schema v\(report.schemaVersion)")
        if report.sources.isEmpty { log("  연결된 사용량 소스가 없습니다") }
        for source in report.sources {
            log("  \(source.tool.rawValue)\t\(source.status.rawValue)\t\(source.isPaused ? "paused" : "active")\t\(source.maskedPath)\tbaseline=\(source.baselineCompleted)\t\(source.reason ?? "-")")
        }
        for total in report.toolTotals {
            log("  accepted  \(total.tool.rawValue): \(total.acceptedTokens) 토큰 · \(total.acceptedEvents)건")
        }
        if let reward = report.reward {
            log("  공통 계정  나머지 \(reward.remainderTokens) · 누적 인정 \(reward.acceptedTokens) · 누적 적립 \(reward.awardedPoints) P")
        }
    }

    enum UsageToolError: Error, CustomStringConvertible {
        case missingFlag(String)
        case unknownTool(String)
        case unknownMode(String)
        case noCandidate(String)
        case ambiguousSource(String, Int)

        var description: String {
            switch self {
            case let .ambiguousSource(tool, count): "\(tool) has \(count) connected roots; correct one root at a time"

            case let .missingFlag(name): "missing required flag \(name)"
            case let .unknownTool(name): "unknown tool \(name) (\(UsageToolKind.allCases.map(\.rawValue).joined(separator: "|")))"
            case let .unknownMode(mode): "unknown usage mode \(mode) (list|connect|disconnect|status|correction)"
            case let .noCandidate(tool): "no storage found for \(tool); pass --root"
            }
        }
    }
}
