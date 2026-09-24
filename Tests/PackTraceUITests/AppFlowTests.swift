import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Drives the same `AppEnvironment` the window uses, through a temporary store,
/// so the user-visible flow is exercised without a click.
@Suite("앱 흐름")
@MainActor
struct AppFlowTests {
    private func makeEnvironment() throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-appflow").directory
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: makeIsolatedSettings())
        return (environment, root)
    }

    private func bootstrapped() async throws -> (AppEnvironment, URL) {
        let (environment, location) = try makeEnvironment()
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, location)
    }

    @Test("카드 카탈로그 없이 만든 빌드는 설치 방법을 안내한다", .enabled(if: CatalogLoader.bundledCatalogURLs().isEmpty))
    func missingCatalogsExplainWhatToRun() async throws {
        let root = try StoreLocation.temporary(label: "packtrace-no-catalogs").directory
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: makeIsolatedSettings())
        await environment.bootstrap()
        #expect(environment.loadState == .failed(AppEnvironment.missingCatalogsMessage))
    }

    @Test("첫 실행에서 개발용 포인트가 지급되고 화면 상태가 채워진다")
    func firstLaunchGrantsPointsAndFillsState() async throws {
        let (environment, _) = try await bootstrapped()

        #expect(environment.balance == 500)
        #expect(environment.sealedPacks.isEmpty)
        #expect(environment.lastGrantNotice != nil)

        // Every era's real product; a series is picked first, then a pack.
        let pool = try #require(environment.pool)
        let summary = environment.candidateSummary
        #expect(pool.poolVersion == "packs-v3")
        #expect(summary.count == pool.candidates.count)
        for candidate in summary {
            #expect(abs(candidate.probability - pool.probability(of: candidate.product.packID)) < 1e-12)
        }
        #expect(abs(summary.reduce(0) { $0 + $1.probability } - 1) < 1e-9)
        let sets = ["sv01", "sv02", "sv03", "sv04", "sv05", "sv06", "sv07", "sv08", "sv09", "sv10"]
        #expect(Set(summary.map(\.product.setID)).isSuperset(of: sets))
        #expect(Set(environment.setSummaries.map(\.setID)).isSuperset(of: sets))
        // Shelves list every set exactly once, by series.
        let shelved = environment.seriesGroups.flatMap(\.setIDs)
        #expect(shelved.count == environment.setSummaries.count)
        #expect(Set(shelved) == Set(environment.setSummaries.map(\.setID)))
        #expect(environment.seriesGroups.first?.id == "me", "최신 시리즈 먼저")
    }

    @Test("팩 받기 → 뜯기 → 한 장씩 공개 → 바인더 반영")
    func openingLoopReachesBinder() async throws {
        let (environment, _) = try await bootstrapped()

        let pack = try #require(await environment.exchangeRandomPack())
        #expect(environment.balance == 400)
        #expect(environment.sealedPacks.count == 1)
        let packSet = try #require(environment.product(for: pack)?.setID)
        // The binder is set-aware: the received pack's set still has nothing.
        await environment.selectBinderSet(packSet)
        #expect(environment.binderEntries.allSatisfy { $0.quantity == 0 })

        let opening = try await environment.openPack(pack.id)
        let recipe = try #require(pinnedRecipe(of: pack, in: environment))
        #expect(opening.cards.count == recipe.packSize)
        #expect(opening.revealedCount == 0)
        #expect(environment.sealedPacks.isEmpty)
        await environment.selectBinderSet(packSet)
        #expect(opening.cards.allSatisfy { recipe.setIDs.contains($0.cardKey.setID) }, "다른 세트 카드가 섞이면 안 됩니다")
        let fromPackSet = opening.cards.filter { $0.cardKey.setID == packSet }
        #expect(environment.binderEntries.filter { $0.quantity > 0 }.count == Set(
            fromPackSet.map { "\($0.cardKey.rawValue)#\($0.variant.rawValue)" }
        ).count)

        var current = opening
        for expected in 1...opening.cards.count {
            current = try #require(await environment.revealNext(current))
            #expect(current.revealedCount == expected)
        }
        #expect(current.isComplete)
        #expect(environment.unfinishedOpenings.isEmpty)
        await environment.selectBinderSet(packSet)
        #expect(environment.progress.totalCopies == fromPackSet.count)
        #expect(environment.collectionTotals.totalCopies == recipe.packSize)
    }

    @Test("빠르게 열기 설정도 같은 카드 결과를 남긴다")
    func fastOpenSettingKeepsSameResult() async throws {
        let (environment, _) = try await bootstrapped()
        environment.settings.fastOpen = true
        #expect(environment.settings.skipsAnimations(systemReduceMotion: false))

        let pack = try #require(await environment.exchangeRandomPack())
        let opening = try await environment.openPack(pack.id)
        let all = try #require(await environment.revealAll(opening))
        #expect(all.isComplete)
        #expect(all.cards == opening.cards)
        #expect(environment.collectionTotals.totalCopies == opening.cards.count)
        #expect(opening.cards.count == pinnedRecipe(of: pack, in: environment)?.packSize)
    }

    @Test("앱을 다시 시작해도 팩·카드·진행 위치가 그대로 복구된다")
    func restartRestoresCollectionAndRevealProgress() async throws {
        let (environment, location) = try await bootstrapped()
        let pack = try #require(await environment.exchangeRandomPack())
        var opening = try await environment.openPack(pack.id)
        for _ in 0..<2 {
            opening = try #require(await environment.revealNext(opening))
        }
        let beforeRestart = try #require(environment.openings.first)
        #expect(beforeRestart.revealedCount == 2)
        let packSet = try #require(environment.product(for: pack)?.setID)

        // A fresh environment on the same directory models relaunching the app.
        let relaunched = AppEnvironment(realm: .demo, locationRoot: location, settings: makeIsolatedSettings())
        await relaunched.bootstrap()

        #expect(relaunched.balance == 400, "재시작으로 개발용 포인트가 다시 지급되면 안 됩니다")
        #expect(relaunched.allPacks.count == 1)
        #expect(relaunched.sealedPacks.isEmpty)
        let restored = try #require(relaunched.openings.first)
        #expect(restored.id == beforeRestart.id)
        #expect(restored.revealedCount == 2)
        #expect(restored.cards == beforeRestart.cards)
        #expect(relaunched.unfinishedOpenings.count == 1)
        let fromPackSet = beforeRestart.cards.filter { $0.cardKey.setID == packSet }.count
        await relaunched.selectBinderSet(packSet)
        #expect(relaunched.progress.totalCopies == fromPackSet)
        #expect(relaunched.collectionTotals.totalCopies == beforeRestart.cards.count)

        // 공개를 마저 해도 카드가 다시 뽑히지 않는다.
        let finished = try #require(await relaunched.revealAll(restored))
        #expect(finished.cards == beforeRestart.cards)
        await relaunched.selectBinderSet(packSet)
        #expect(relaunched.progress.totalCopies == fromPackSet)
    }

    @Test("잔액이 부족하면 화면에 포인트 부족이 남고 팩은 늘지 않는다")
    func insufficientBalanceSurfacesInState() async throws {
        let (environment, _) = try await bootstrapped()
        // Spend the whole 500 P grant, then try once more.
        for _ in 0..<5 {
            _ = await environment.exchangeRandomPack()
        }
        #expect(environment.balance == 0)
        #expect(environment.sealedPacks.count == 5)

        let extra = await environment.exchangeRandomPack()
        #expect(extra == nil)
        #expect(environment.balance == 0)
        #expect(environment.sealedPacks.count == 5)
        let error = try #require(environment.lastActionError)
        #expect(error.contains("포인트가 부족"))
    }

    /// The recipe the pack was pinned to: packs differ in size by era.
    private func pinnedRecipe(of pack: PackInstanceRecord, in environment: AppEnvironment) -> PackRecipe? {
        guard let product = environment.product(for: pack) else { return nil }
        return environment.library?.catalog(version: pack.catalogVersion)?.recipe(id: product.recipeID)
    }
}
