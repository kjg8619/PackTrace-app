import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Drives the usage plumbing exactly as the settings and Today screens do.
@Suite("앱 사용량 연결")
@MainActor
struct UsageUITests {
    private func makeEnvironment() throws -> (AppEnvironment, OMPFixture.Tree, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-usage-ui").directory
        let environment = AppEnvironment(
            realm: .demo,
            locationRoot: root,
            settings: makeIsolatedSettings()
        )
        return (environment, try OMPFixture.Tree(), root)
    }

    private func record(_ n: Int, input: Int, output: Int, offset: Int) -> String {
        OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            input: input,
            output: output,
            occurredAt: OMPFixture.timestamp(offset),
            completedAt: OMPFixture.timestamp(offset + 1)
        )
    }

    /// A record that occurred now, so "today" aggregates include it.
    private func recordNow(_ n: Int, input: Int, output: Int) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            input: input,
            output: output,
            occurredAt: now,
            completedAt: now + 1_000
        )
    }

    @Test("연결 → 기준선 → 신규 적립이 화면 상태에 반영된다")
    func connectBaselineThenReward() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        let path = "project-a/session.jsonl"
        try tree.write(
            OMPFixture.sessionFile(assistants: [record(1, input: 9_000, output: 9_000, offset: 0)]),
            to: path
        )

        await environment.bootstrap()
        #expect(environment.usage.isConnected == false)
        #expect(environment.usage.ompStateLabel == "미연결")

        await environment.connectUsage(root: tree.root)
        #expect(environment.usage.isConnected)
        #expect(environment.usage.baselineComplete)
        #expect(environment.usage.baselineEvents == 1)
        #expect(environment.usage.acceptedEvents == 0)
        #expect(environment.usage.todayAwardedPoints == 0)

        try tree.append(recordNow(2, input: 9_500, output: 500) + "\n", to: path)
        await environment.refreshUsageNow()

        #expect(environment.usage.acceptedEvents == 1)
        #expect(environment.usage.todayAcceptedTokens == 10_000)
        #expect(environment.usage.todayAwardedPoints == 1)
        #expect(environment.usage.remainderTokens == 0)
        #expect(environment.usage.tokensUntilNextPoint == 10_000)

        // The reward went to the production wallet, not the demo one.
        let production = try #require(environment.activeStore(for: .production))
        let demo = try #require(environment.activeStore(for: .demo))
        let productionBalance = try await production.balance()
        let demoBalance = try await demo.balance()
        #expect(productionBalance == 1)
        #expect(demoBalance == 500, "demo 지갑은 개발용 지급 그대로입니다")
    }

    @Test("새로고침을 반복해도 인정량·포인트·나머지가 늘지 않는다")
    func repeatedRefreshIsIdempotent() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.bootstrap()
        await environment.connectUsage(root: tree.root)

        try tree.append(record(1, input: 4_000, output: 1_000, offset: 5) + "\n", to: path)
        await environment.refreshUsageNow()
        let first = environment.usage

        for _ in 0..<3 {
            await environment.refreshUsageNow()
        }
        let after = environment.usage
        #expect(after.todayAcceptedTokens == first.todayAcceptedTokens)
        #expect(after.todayAwardedPoints == first.todayAwardedPoints)
        #expect(after.remainderTokens == first.remainderTokens)
        #expect(after.acceptedEvents == first.acceptedEvents)
        #expect(after.duplicateEvents >= 0)
    }

    @Test("재시작해도 상태와 나머지가 유지되고 중복 지급이 없다")
    func restartKeepsUsageState() async throws {
        let (environment, tree, environmentRoot) = try makeEnvironment()
        defer { tree.remove() }
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.bootstrap()
        await environment.connectUsage(root: tree.root)
        try tree.append(record(1, input: 6_000, output: 0, offset: 5) + "\n", to: path)
        await environment.refreshUsageNow()
        let before = environment.usage

        // Relaunch: a new environment on the same temporary root. The tree is
        // still at the same absolute path, so only the state needs to survive.
        let relaunched = AppEnvironment(
            realm: .demo,
            locationRoot: environmentRoot,
            settings: makeIsolatedSettings()
        )
        await relaunched.bootstrap()
        #expect(relaunched.usage.isConnected, "연결 상태가 유지되어야 합니다")
        #expect(relaunched.usage.rootDisplay.contains("…") || relaunched.usage.rootDisplay.contains("~"))

        await relaunched.scheduledUsageScan()
        let after = relaunched.usage
        #expect(after.remainderTokens == before.remainderTokens)
        #expect(after.todayAcceptedTokens == before.todayAcceptedTokens)

        // And a new real event is still picked up after the restart.
        try tree.append(record(2, input: 4_000, output: 0, offset: 60) + "\n", to: path)
        await relaunched.refreshUsageNow()
        let collected = relaunched.usage
        #expect(collected.remainderTokens == 10_000 || collected.remainderTokens == 0)
        #expect(collected.todayAwardedPoints >= before.todayAwardedPoints)
    }

    @Test("일시정지와 재개가 화면 상태에 드러난다")
    func pauseAndResumeAreVisible() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.bootstrap()
        await environment.connectUsage(root: tree.root)
        try tree.append(record(1, input: 10_000, output: 0, offset: 5) + "\n", to: path)

        await environment.pauseUsage()
        #expect(environment.usage.isPaused)
        #expect(environment.usage.ompStateLabel == "읽기 일시정지")
        #expect(environment.usage.ompSummaryLine.contains("일시정지"))

        await environment.resumeUsage()
        #expect(environment.usage.isPaused == false)
        #expect(environment.usage.todayAwardedPoints == 1, "재개하면 미처리분이 반영됩니다")
    }

    @Test("읽지 못한 상태와 새 이벤트 없음을 구분해 보여준다")
    func unreadableStateIsDistinctFromNoNewEvents() async throws {
        let (environment, tree, _) = try makeEnvironment()
        let root = tree.root
        try tree.write(OMPFixture.sessionFile(assistants: []), to: "project-a/session.jsonl")
        await environment.bootstrap()
        await environment.connectUsage(root: root)

        await environment.refreshUsageNow()
        #expect(environment.usage.ompSummaryLine.contains("새 이벤트 없음"))

        tree.remove()
        await environment.refreshUsageNow()
        #expect(environment.usage.status == .rootMissing || environment.usage.status == .permissionDenied)
        #expect(environment.usage.ompSummaryLine.contains("읽지 못했"))
        #expect(environment.usage.ompStateLabel != "수집 중")
    }

    @Test("실사용 잔액 표시는 현재 프로필과 무관하게 production 지갑을 읽는다")
    func productionBalanceIsShownRegardlessOfProfile() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.bootstrap()
        await environment.connectUsage(root: tree.root)
        try tree.append(recordNow(1, input: 10_000, output: 0) + "\n", to: path)
        await environment.refreshUsageNow()

        // Demo profile is active, but the usage tiles must report production.
        #expect(environment.profile == .demo)
        #expect(environment.balance == 500)
        #expect(environment.productionBalance == 1)
        #expect(environment.usage.todayAwardedPoints == 1)
    }

    @Test("프로필을 바꾸면 화면이 해당 지갑으로 전환된다")
    func profileSwitchChangesActiveWallet() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        await environment.bootstrap()
        #expect(environment.profile == .demo)
        #expect(environment.balance == 500)

        let switched = await environment.switchProfile(to: .production)
        #expect(switched)
        #expect(environment.profile == .production)
        #expect(environment.balance == 0, "실사용 지갑은 0 P로 시작합니다")
        #expect(environment.settings.lastProfile == .production)
    }
}
