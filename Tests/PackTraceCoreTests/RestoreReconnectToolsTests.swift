import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Restoring a profile with several connected tools: nothing may keep collecting
/// quietly, and each source's reconnect is its own decision.
@Suite("복원 후 도구 재연결")
struct RestoreReconnectToolsTests {
    static func tree(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-restore-tools-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    static func codexHeader(session: String) -> String {
        #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(session)","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
    }

    static func codexCall(ordinal: Int, previousTotal: Int, input: Int, output: Int) -> String {
        let lastTotal = input + output
        return #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(previousTotal + input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(previousTotal + lastTotal)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(lastTotal)},"model_context_window":272000}}}"# + "\n"
    }

    static func claudeCall(requestID: String, input: Int, output: Int) -> String {
        #"{"type":"assistant","uuid":"u-\#(requestID)","sessionId":"session-claude","isSidechain":false,"timestamp":"2026-09-23T00:00:05.000Z","requestId":"\#(requestID)","message":{"id":"\#(requestID)","model":"claude-fixture","stop_reason":"end_turn","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"# + "\n"
    }

    @Test("복원하면 모든 소스가 멈추고, 재연결한 소스만 새 기준선으로 이어간다")
    func restoreStopsEverySourceAndReconnectsIndividually() async throws {
        let root = try Self.tree("main")
        defer { try? FileManager.default.removeItem(at: root) }
        let codexRoot = root.appendingPathComponent("codex/sessions")
        let codexFile = codexRoot.appendingPathComponent("2026/09/23/rollout-a.jsonl")
        let claudeRoot = root.appendingPathComponent("claude/projects")
        let claudeFile = claudeRoot.appendingPathComponent("project/session-claude.jsonl")
        try FileManager.default.createDirectory(at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Self.codexHeader(session: "session-codex") + Self.codexCall(ordinal: 0, previousTotal: 0, input: 5_000, output: 0))
            .write(to: codexFile, atomically: true, encoding: .utf8)
        try Self.claudeCall(requestID: "req-old", input: 3_000, output: 0).write(to: claudeFile, atomically: true, encoding: .utf8)

        let catalog = Fixtures.syntheticCatalog()
        let location = try StoreLocation.temporary(label: "packtrace-restore-tools-store")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = try Fixtures.makeStore(catalog: catalog, location: location)
        let library = store.library
        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry([CodexUsageAdapter(), ClaudeCodeUsageAdapter()])
        )

        // Both tools connected and baselined: their existing history earns nothing.
        _ = try await coordinator.connect(tool: .codex, rootPath: codexRoot)
        _ = try await coordinator.connect(tool: .claudeCode, rootPath: claudeRoot)
        #expect(try await store.usageTotals().acceptedTokens == 0)

        // One new call each, then a backup of that state.
        try Self.append(Self.codexCall(ordinal: 1, previousTotal: 5_000, input: 6_000, output: 0), to: codexFile)
        try Self.append(Self.claudeCall(requestID: "req-new", input: 4_000, output: 0), to: claudeFile)
        _ = try await coordinator.scan(trigger: .manual)
        let beforeBackup = try await store.usageTotals()
        #expect(beforeBackup.acceptedTokens == 10_000)
        #expect(beforeBackup.awardedPoints == 1)
        #expect(try await store.usageSources().count == 2)

        let backup = try StoreBackup.create(location: location, library: library, poolVersion: "packs-v1")
        await store.close()

        // Restore it and reopen.
        _ = try StoreRestore.restore(packageURL: backup.packageURL, location: location, library: library)
        let restored = try Fixtures.makeStore(catalog: catalog, location: location)
        let restoredCoordinator = UsageCoordinator(
            store: restored,
            registry: UsageAdapterRegistry([CodexUsageAdapter(), ClaudeCodeUsageAdapter()])
        )
        defer { Task { await restored.close() } }

        // The wallet came back; collection did not.
        #expect(try await restored.balance() == 1, "복원된 잔액은 유지됩니다")
        let sources = try await restored.allUsageSourceRows()
        #expect(sources.count == 2)
        for source in sources {
            #expect(source.status == .unconnected, "\(source.tool.rawValue)가 자동 수집을 계속하면 안 됩니다")
            #expect(source.isPaused)
            #expect(source.baselineCompletedAt == nil)
            #expect(source.lastReason == OMPUsageCollector.restoreReconnectReason)
        }
        #expect(try await restored.usageSources().isEmpty, "숨은 소스는 수집 대상이 아닙니다")

        // Work continues in both tools while the app is disconnected.
        try Self.append(Self.codexCall(ordinal: 2, previousTotal: 11_000, input: 7_000, output: 0), to: codexFile)
        try Self.append(Self.claudeCall(requestID: "req-later", input: 8_000, output: 0), to: claudeFile)
        _ = try await restoredCoordinator.scan(trigger: .manual)
        #expect(try await restored.usageTotals().acceptedTokens == 10_000, "연결되지 않은 소스는 읽지 않습니다")

        // Reconnecting one tool makes its current history the baseline.
        let codexSource = try #require(sources.first { $0.tool == .codex })
        _ = try await restoredCoordinator.connect(tool: .codex, rootPath: URL(fileURLWithPath: codexSource.rootPath))
        let afterReconnect = try await restored.usageTotals()
        #expect(afterReconnect.acceptedTokens == 10_000, "재연결 이전 기록은 기준선입니다")
        let codexStatus = try #require(try await restored.usageSource(tool: .codex))
        #expect(codexStatus.baselineCompletedAt != nil)
        #expect(codexStatus.isPaused == false, "재연결은 수집을 다시 시작해야 합니다")

        // Only the reconnected tool keeps crediting.
        try Self.append(Self.codexCall(ordinal: 3, previousTotal: 18_000, input: 1_500, output: 500), to: codexFile)
        try Self.append(Self.claudeCall(requestID: "req-after", input: 9_000, output: 0), to: claudeFile)
        _ = try await restoredCoordinator.scan(trigger: .manual)
        let final = try await restored.usageTotals()
        #expect(final.acceptedTokens == 12_000, "재연결한 도구의 신규 기록만 적립됩니다")
        #expect(final.awardedPoints == 1)
        #expect(final.remainderTokens == 2_000)

        let claudeStillOut = try #require(
            try await restored.allUsageSourceRows().first { $0.tool == .claudeCode }
        )
        #expect(claudeStillOut.status == .unconnected, "재연결하지 않은 도구는 그대로 멈춰 있습니다")
        #expect(claudeStillOut.lastReason == OMPUsageCollector.restoreReconnectReason)
    }
}
