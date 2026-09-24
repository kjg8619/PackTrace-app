import Foundation
import PackTraceTestSupport
import SwiftUI
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// What Today, the menu bar and the top of Settings say about collection: every
/// connected tool, with OMP as one of them. These screens used to show OMP's
/// connection alone, so with only Codex connected they read "미연결" and
/// offered "connect OMP" while Codex was being credited.
@Suite("사용량 전체 상태")
@MainActor
struct UsageOverviewUITests {
    // MARK: - Pure

    private func source(
        _ tool: UsageToolKind,
        status: UsageSourceStatus = .collecting,
        paused: Bool = false,
        baselined: Bool = true,
        reason: String? = nil,
        lastScanAt: Date? = nil
    ) -> UsageCoordinator.SourceStatus {
        UsageCoordinator.SourceStatus(
            source: UsageSourceRecord(
                sourceID: "\(tool.rawValue)-source",
                realm: .production,
                tool: tool,
                toolVersion: nil,
                formatVersion: nil,
                rootPath: "/tmp/\(tool.rawValue)",
                connectedAt: Date(timeIntervalSince1970: 1_000),
                baselineCompletedAt: baselined ? Date(timeIntervalSince1970: 1_001) : nil,
                isPaused: paused,
                lastScanAt: lastScanAt,
                status: status,
                lastReason: reason
            ),
            inspection: UsageSourceInspection(support: .supported, detail: "test"),
            lastRun: nil,
            acceptedTokens: 0,
            acceptedEvents: 0,
            pendingWork: false
        )
    }

    private func connectedOMP(paused: Bool = false) -> UsageStatusSnapshot {
        var omp = UsageStatusSnapshot()
        omp.isConnected = true
        omp.status = .collecting
        omp.isPaused = paused
        omp.baselineComplete = true
        return omp
    }

    @Test("OMP 없이 다른 도구만 연결해도 '미연결'이 아니고 OMP 연결을 요구하지 않는다")
    func toolsWithoutOMPAreConnected() {
        let overview = UsageOverview.make(omp: UsageStatusSnapshot(), tools: [source(.codex), source(.claudeCode)])
        #expect(overview.hasConnection)
        #expect(overview.sources.map(\.tool) == [.codex, .claudeCode])
        #expect(overview.stateLabel == "수집 대기")
        #expect(overview.tone == .active)
        #expect(!overview.summaryLine.contains("OMP"), "\(overview.summaryLine)")
        #expect(overview.summaryLine.contains("2개 도구"))
    }

    @Test("아무 도구도 연결하지 않았을 때만 '미연결'이고, 어느 도구든 연결하라고 안내한다")
    func nothingConnected() {
        let overview = UsageOverview.make(omp: UsageStatusSnapshot(), tools: [])
        #expect(!overview.hasConnection)
        #expect(overview.stateLabel == "미연결")
        // Points at settings without naming one tool as the one to connect.
        #expect(overview.summaryLine.contains("설정") && overview.summaryLine.contains("AI 도구"))
        #expect(!overview.summaryLine.contains("OMP"))
        // A tool the user disconnected is not part of collection.
        let disconnected = UsageOverview.make(
            omp: UsageStatusSnapshot(),
            tools: [source(.codex, status: .unconnected, reason: "disconnected_by_user")]
        )
        #expect(disconnected.sources.isEmpty)
    }

    @Test("OMP는 도구 중 하나로 한 번만 센다")
    func ompCountedOnce() {
        // The coordinator lists every source row, OMP's included.
        let overview = UsageOverview.make(omp: connectedOMP(), tools: [source(.omp), source(.openCode)])
        #expect(overview.sources.map(\.tool) == [.omp, .openCode])
        #expect(overview.activeCount == 2)
    }

    @Test("한 도구의 오류는 다른 도구가 수집 중이어도 숨기지 않는다")
    func failingToolIsVisible() {
        let overview = UsageOverview.make(
            omp: connectedOMP(),
            tools: [source(.codex, status: .rootMissing), source(.claudeCode)]
        )
        #expect(overview.failing.map(\.tool) == [.codex])
        #expect(overview.stateLabel == "확인 필요 1")
        #expect(overview.tone == .attention)
        #expect(overview.summaryLine.contains("Codex"))
    }

    @Test("모든 도구가 일시정지일 때만 '읽기 일시정지'이고, 일부만 멈추면 나머지는 수집으로 보인다")
    func pausedStates() {
        let all = UsageOverview.make(omp: connectedOMP(paused: true), tools: [source(.codex, paused: true)])
        #expect(all.stateLabel == "읽기 일시정지")
        #expect(all.canResume && !all.canPause)

        let some = UsageOverview.make(omp: connectedOMP(paused: true), tools: [source(.codex)])
        #expect(some.stateLabel == "수집 대기")
        #expect(some.canPause && some.canResume)
        #expect(some.summaryLine.contains("1개 일시정지"))
    }

    @Test("복원 뒤에는 OMP와 다른 도구 모두 재연결 필요로 보인다")
    func restoredSourcesNeedReconnect() {
        var omp = UsageStatusSnapshot()
        omp.requiresReconnect = true
        let overview = UsageOverview.make(
            omp: omp,
            tools: [source(.codex, status: .unconnected, paused: true, reason: OMPUsageCollector.restoreReconnectReason)]
        )
        #expect(overview.sources.map(\.state) == [.needsReconnect, .needsReconnect])
        #expect(!overview.hasConnection)
        #expect(overview.stateLabel == "재연결 필요")
        #expect(!overview.canPause && !overview.canResume)
    }

    @Test("기준선을 잡는 도구가 있으면 그 상태를 보여 준다")
    func baseliningTool() {
        let overview = UsageOverview.make(omp: UsageStatusSnapshot(), tools: [source(.openCode, baselined: false)])
        #expect(overview.baselining.map(\.tool) == [.openCode])
        #expect(overview.stateLabel == "기준선 설정 중")
    }

    @Test("마지막 확인 시각은 가장 최근에 읽은 도구의 시각이다")
    func lastScanAcrossTools() {
        var omp = connectedOMP()
        omp.lastScanAt = Date(timeIntervalSince1970: 2_000)
        let overview = UsageOverview.make(omp: omp, tools: [source(.codex, lastScanAt: Date(timeIntervalSince1970: 3_000))])
        #expect(overview.lastScanAt == Date(timeIntervalSince1970: 3_000))
    }

    // MARK: - Environment

    private func environment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-overview-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = .production
        let environment = AppEnvironment(realm: .production, locationRoot: root, settings: settings)
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, root)
    }

    private func codexHeader() -> String {
        #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"session-overview","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
    }

    private func codexCall(ordinal: Int, previousTotal: Int, input: Int) -> String {
        let total = previousTotal + input
        return #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(input)},"model_context_window":272000}}}"# + "\n"
    }

    /// A connected Codex session under `root/codex-home`; returns the file.
    private func connectCodex(_ environment: AppEnvironment, root: URL) async throws -> URL {
        let codexRoot = root.appendingPathComponent("codex-home", isDirectory: true)
        let session = codexRoot.appendingPathComponent("2026/09/23/rollout-overview.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (codexHeader() + codexCall(ordinal: 0, previousTotal: 0, input: 4_000)).write(to: session, atomically: true, encoding: .utf8)
        await environment.connectTool(.codex, rootPath: codexRoot.path)
        return session
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func codex(_ environment: AppEnvironment) -> UsageCoordinator.SourceStatus? {
        environment.toolStatuses.first { $0.source.tool == .codex }
    }

    @Test("Codex만 연결하면 전체 상태는 연결됨이고, OMP 연결 상태는 따로 미연결이다")
    func environmentWithCodexOnly() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(environment.usageOverview.stateLabel == "미연결")

        _ = try await connectCodex(environment, root: root)
        #expect(environment.usage.isConnected == false, "OMP는 연결하지 않았습니다")
        #expect(environment.usageOverview.hasConnection)
        #expect(environment.usageOverview.sources.map(\.tool) == [.codex])
        #expect(environment.usageOverview.stateLabel != "미연결")
        #expect(environment.usageOverview.sources.first?.state == .collecting)
        // Codex's scan run is not OMP's: the OMP card has no scan time of its own.
        #expect(environment.usage.lastScanAt == nil)
    }

    @Test("수집 일시정지·재개는 OMP와 다른 도구 모두에 적용되고, 재개하면 쌓인 사용량을 한 번만 적립한다")
    func pauseAndResumeAll() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let tree = try OMPFixture.Tree()
        defer { tree.remove() }
        try tree.write(OMPFixture.sessionFile(assistants: []), to: "project/session.jsonl")
        await environment.connectUsage(root: tree.root)
        let session = try await connectCodex(environment, root: root)
        #expect(environment.usageOverview.canPause)

        await environment.pauseAllUsage()
        #expect(environment.usage.isPaused, "OMP도 멈춥니다")
        #expect(codex(environment)?.source.isPaused == true, "Codex도 멈춥니다")
        #expect(environment.usageOverview.stateLabel == "읽기 일시정지")
        #expect(!environment.hasCollectableSource)

        // Work that happens while paused is read on resume, once.
        try append(codexCall(ordinal: 1, previousTotal: 4_000, input: 10_000), to: session)
        await environment.scheduledUsageScan()
        #expect(codex(environment)?.acceptedTokens == 0, "일시정지 중에는 읽지 않습니다")

        await environment.resumeAllUsage()
        #expect(environment.usage.isPaused == false)
        #expect(codex(environment)?.source.isPaused == false)
        #expect(codex(environment)?.acceptedTokens == 10_000)
        #expect(environment.productionBalance == 1)
        await environment.refreshUsageNow()
        #expect(environment.productionBalance == 1, "다시 읽어도 한 번만 적립됩니다")
        #expect(environment.usageOverview.activeCount == 2)
    }

    // MARK: - Opt-in render

    @Test("사용량 화면 렌더(옵트인)", .enabled(if: RenderProbeTests.directory != nil))
    func renderUsageScreens() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        func render(_ suffix: String) async throws {
            let width: CGFloat = 760
            try ScreenProbeTests.write(
                try await ScreenProbeTests.snapshot(
                    TodayUsagePanel().environmentObject(environment).padding(16).background(Palette.backdrop),
                    size: CGSize(width: width, height: 330)
                ),
                "usage-today-\(suffix)"
            )
            try ScreenProbeTests.write(
                try await ScreenProbeTests.snapshot(
                    VStack(spacing: 16) {
                        UsageOverviewSection()
                        AIToolsSection()
                    }
                    .environmentObject(environment).padding(16).background(Palette.backdrop),
                    size: CGSize(width: width, height: 760)
                ),
                "usage-settings-\(suffix)"
            )
            try ScreenProbeTests.write(
                try await ScreenProbeTests.snapshot(
                    MenuBarSummary().environmentObject(environment),
                    size: CGSize(width: 300, height: 400)
                ),
                "usage-menu-\(suffix)"
            )
        }
        try await render("none")
        _ = try await connectCodex(environment, root: root)
        try await render("codex-only")
        // Today's per-tool line with a dashboard-sized day (sample figures).
        try ScreenProbeTests.write(
            try await ScreenProbeTests.snapshot(
                TodayToolBreakdown(days: [
                    UsageToolDay(tool: .claudeCode, events: 1_688, inputTokens: 3_470, outputTokens: 1_877_483,
                                 cacheReadTokens: 873_482_953, cacheWriteTokens: 12_606_890, acceptedTokens: 1_880_953),
                    UsageToolDay(tool: .omp, events: 4, inputTokens: 856, outputTokens: 1_916,
                                 cacheReadTokens: 1_032_832, cacheWriteTokens: 0, acceptedTokens: 2_772),
                ])
                .padding(16).background(Palette.backdrop),
                size: CGSize(width: 760, height: 120)
            ),
            "usage-today-by-tool"
        )
    }

    @Test("토큰 수는 억·만 단위로 줄여 보여 준다")
    func compactTokenCounts() {
        #expect(TokenCount.compact(3_470) == "3,470")
        #expect(TokenCount.compact(1_877_483) == "187만")
        #expect(TokenCount.compact(12_606_890) == "1,260만")
        #expect(TokenCount.compact(873_482_953) == "8.7억")
        #expect(TokenCount.compact(1_081_522_465) == "10.8억")
        #expect(TokenCount.compact(0) == "0")
    }
}

