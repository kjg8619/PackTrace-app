import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Achievements as the screens see them: judged on refresh, announced once,
/// paid once into the wallet on screen. Temporary data root only.
@Suite("업적 화면 상태")
@MainActor
struct AchievementsUITests {
    private func environment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-achievements-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = 7
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, root)
    }

    @Test("팩을 끝까지 공개하면 업적이 열리고 알림·보상이 한 번만 생긴다")
    func unlockAfterFullReveal() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(environment.achievements.isEmpty == false, "업적 목록이 채워져야 합니다")
        #expect(environment.achievementRecords.isEmpty)
        #expect(environment.recentUnlocks.isEmpty)

        let pack = try #require(await environment.exchangeRandomPack())
        let opening = try await environment.openPack(pack.id)
        let store = try #require(environment.store)

        // Half revealed: nothing yet, so no card is given away.
        _ = try await store.setRevealedCount(openingID: opening.id, count: 3)
        await environment.refresh()
        #expect(environment.achievementRecords["packs.1"] == nil)
        let balanceBefore = environment.balance

        _ = try await store.setRevealedCount(openingID: opening.id, count: opening.cards.count)
        await environment.refresh()
        #expect(environment.achievementRecords["packs.1"] != nil)
        #expect(environment.recentUnlocks.contains { $0.achievementID == "packs.1" })
        let paid = environment.recentUnlocks.reduce(0) { $0 + $1.rewardPoints }
        #expect(paid >= 10)
        #expect(environment.balance == balanceBefore + paid, "보상이 지금 보는 지갑에 들어갑니다")
        #expect(environment.ledger.contains { $0.reason == .achievementReward })

        // Refreshing again announces and pays nothing new.
        environment.dismissRecentUnlocks()
        await environment.refresh()
        #expect(environment.recentUnlocks.isEmpty)
        #expect(environment.balance == balanceBefore + paid)
    }

    @Test("업적 탭이 사이드바에 있다")
    func tabExists() {
        #expect(AppEnvironment.Tab.allCases.contains(.achievements))
        #expect(AppEnvironment.Tab.achievements.title == "업적")
    }
}
