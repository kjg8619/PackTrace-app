import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The settings path for a tool that has its own adapter: connect, credit,
/// disconnect, and never credit on discovery alone.
@Suite("도구 연결 화면")
@MainActor
struct UsageToolsUITests {
    private func environment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-tools-ui").directory
        let environment = AppEnvironment(realm: .production, locationRoot: root, settings: makeIsolatedSettings())
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, root)
    }

    private func codexSession(previousTotal: Int, ordinal: Int, input: Int, output: Int) -> String {
        let header = #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"session-ui","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
        let lastTotal = input + output
        let event = #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(previousTotal + input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(previousTotal + lastTotal)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(lastTotal)},"model_context_window":272000}}}"# + "\n"
        return ordinal == 0 ? header + event : event
    }

    @Test("도구를 연결하면 기준선만 잡고, 이후 신규 기록이 공통 지갑에 적립된다")
    func connectingAToolCreditsNewWorkOnly() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/09/23/rollout-ui.jsonl")
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try codexSession(previousTotal: 0, ordinal: 0, input: 9_000, output: 1_000).write(to: sessions, atomically: true, encoding: .utf8)

        // Discovery proposes; it never connects on its own.
        await environment.refreshToolStatuses()
        #expect(environment.toolCandidates.contains { $0.identity.tool == .codex })
        #expect(environment.toolStatuses.isEmpty, "감지만으로는 연결되지 않습니다")

        await environment.connectTool(.codex, rootPath: root.path)
        let connected = try #require(environment.toolStatuses.first { $0.source.tool == .codex })
        #expect(connected.source.status != .unconnected)
        #expect(connected.source.baselineCompletedAt != nil)
        #expect(connected.acceptedTokens == 0, "연결 전 기록은 기준선입니다")
        // The reward account is the production wallet; the window may be showing
        // the demo profile, whose balance has nothing to do with usage.
        #expect(environment.productionBalance == 0)

        // Work happens after the connection: this is the part that earns.
        let handle = try FileHandle(forWritingTo: sessions)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexSession(previousTotal: 10_000, ordinal: 1, input: 9_500, output: 500).utf8))
        try handle.close()

        _ = await environment.runToolSlices(trigger: .manual)
        let credited = try #require(environment.toolStatuses.first { $0.source.tool == .codex })
        #expect(credited.acceptedTokens == 10_000)
        #expect(environment.productionBalance == 1, "공통 지갑에 1 P가 적립됩니다")
        #expect(environment.usage.totalAcceptedTokens == 10_000, "공통 계정이 도구 합계와 일치합니다")

        // Disconnecting stops collection for that tool and earns nothing more.
        await environment.disconnectTool(sourceID: credited.source.sourceID)
        let handle2 = try FileHandle(forWritingTo: sessions)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(codexSession(previousTotal: 20_000, ordinal: 2, input: 5_000, output: 0).utf8))
        try handle2.close()
        _ = await environment.runToolSlices(trigger: .manual)
        #expect(environment.productionBalance == 1, "연결 해제된 소스는 더 적립하지 않습니다")
    }

    @Test("도구별 인정 토큰이 공통 합계와 일치하고, 오류 도구가 숨겨지지 않는다")
    func toolBreakdownAndFailingSource() async throws {
        let (environment, root) = try await environment()
        // The tool's storage lives outside the PackTrace data root, as it does on
        // a real machine: removing one must not touch the wallet's database.
        let toolRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: toolRoot)
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = toolRoot.appendingPathComponent("sessions/2026/09/23/rollout-breakdown.jsonl")
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try codexSession(previousTotal: 0, ordinal: 0, input: 5_000, output: 0).write(to: sessions, atomically: true, encoding: .utf8)

        await environment.connectTool(.codex, rootPath: toolRoot.path)
        let handle = try FileHandle(forWritingTo: sessions)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexSession(previousTotal: 5_000, ordinal: 1, input: 9_000, output: 1_000).utf8))
        try handle.close()
        _ = await environment.runToolSlices(trigger: .manual)

        // The breakdown is the shared account split by tool, not a second one.
        let totals = environment.usage.toolTotals
        #expect(totals.count == 1)
        let codex = try #require(totals.first { $0.tool == .codex })
        #expect(codex.acceptedTokens == 10_000)
        #expect(totals.reduce(0) { $0 + $1.acceptedTokens } == environment.usage.totalAcceptedTokens)
        #expect(environment.usageOverview.failing.count == 0)

        // The tool's storage disappears: that has to be visible, not swallowed.
        try FileManager.default.removeItem(at: toolRoot)
        _ = await environment.runToolSlices(trigger: .manual)
        let states = environment.toolStatuses.map { "\($0.source.tool.rawValue):\($0.source.status.rawValue):\($0.source.lastReason ?? "-")" }
        #expect(environment.usageOverview.failing.count == 1, "states=\(states) error=\(environment.toolScanError ?? "-")")
        #expect(environment.toolScanError == nil || environment.usageOverview.failing.count > 0)
    }
}
