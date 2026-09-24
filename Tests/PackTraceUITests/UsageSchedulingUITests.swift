import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// When the app scans: the scheduled, activation and manual scans follow every
/// connected source, not only OMP, and a demo restore leaves production
/// collection running. Temporary data root and synthetic logs only.
@Suite("사용량 스캔 스케줄")
@MainActor
struct UsageSchedulingUITests {
    private func environment(profile: Realm = .production) async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-scheduling-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = profile
        let environment = AppEnvironment(realm: profile, locationRoot: root, settings: settings)
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, root)
    }

    private func codexHeader() -> String {
        #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"session-schedule","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
    }

    private func codexCall(ordinal: Int, previousTotal: Int, input: Int) -> String {
        let total = previousTotal + input
        return #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(input)},"model_context_window":272000}}}"# + "\n"
    }

    /// A Codex session under `root/codex-home`, connected, with one call made
    /// after the connection that no scan has read yet.
    private func connectCodexWithPendingCall(_ environment: AppEnvironment, root: URL) async throws {
        let codexRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        let session = codexRoot.appendingPathComponent("2026/09/23/rollout-schedule.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (codexHeader() + codexCall(ordinal: 0, previousTotal: 0, input: 4_000)).write(to: session, atomically: true, encoding: .utf8)
        await environment.connectTool(.codex, rootPath: codexRoot.path)
        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexCall(ordinal: 1, previousTotal: 4_000, input: 10_000).utf8))
        try handle.close()
    }

    private func codexAccepted(_ environment: AppEnvironment) -> Int {
        environment.toolStatuses.first { $0.source.tool == .codex }?.acceptedTokens ?? 0
    }

    @Test("OMP를 연결하지 않아도 예약 스캔이 다른 도구를 계속 적립한다")
    func scheduledScanCollectsToolsWithoutOMP() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        try await connectCodexWithPendingCall(environment, root: root)
        #expect(environment.usage.isConnected == false, "OMP는 연결하지 않았습니다")
        #expect(codexAccepted(environment) == 0)

        await environment.scheduledUsageScan()
        #expect(codexAccepted(environment) == 10_000, "예약 스캔이 Codex를 읽어야 합니다")
        #expect(environment.productionBalance == 1)
    }

    @Test("OMP를 일시정지해도 다른 도구는 계속 수집한다")
    func pausingOMPDoesNotStopOtherTools() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try OMPFixture.Tree()
        defer { tree.remove() }
        try tree.write(OMPFixture.sessionFile(assistants: []), to: "project/session.jsonl")
        await environment.connectUsage(root: tree.root)
        await environment.pauseUsage()
        #expect(environment.usage.isPaused)

        try await connectCodexWithPendingCall(environment, root: root)
        await environment.scheduledUsageScan()
        #expect(codexAccepted(environment) == 10_000)
        await environment.applicationDidBecomeActive()
        #expect(codexAccepted(environment) == 10_000, "다시 읽어도 한 번만 적립됩니다")
        #expect(environment.usage.isPaused, "OMP의 일시정지는 그대로입니다")
    }

    @Test("demo 프로필을 복원해도 실사용 OMP 수집은 일시정지되지 않는다")
    func demoRestoreLeavesProductionCollecting() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try OMPFixture.Tree()
        defer { tree.remove() }
        try tree.write(OMPFixture.sessionFile(assistants: []), to: "project/session.jsonl")
        await environment.connectUsage(root: tree.root)
        #expect(environment.usage.isConnected && !environment.usage.isPaused)

        #expect(await environment.switchProfile(to: .demo))
        await environment.createBackup()
        let backup = try #require(environment.backups.first)
        await environment.restore(from: backup)

        await environment.refreshUsage()
        #expect(environment.usage.isPaused == false, "demo 복원이 실사용 수집을 멈추면 안 됩니다")
        #expect(environment.usage.isConnected)
    }
}
