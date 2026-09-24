import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("개봉 확정과 복구")
struct OpeningTests {
    private func sealedPack(_ store: PackTraceStore) async throws -> PackInstanceRecord {
        try await store.grantInitialDemoPoints()
        return try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 21).packInstance
    }

    @Test("개봉은 카드 저장과 소유 기록을 한 번에 확정한다")
    func openingCommitsCardsAndOwnership() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store)
        let recipe = try #require(store.catalog.recipes.first)

        let opening = try await store.openPack(instanceID: pack.id, seed: 33)
        #expect(opening.cards.count == recipe.packSize)
        #expect(opening.revealedCount == 0)
        #expect(opening.isComplete == false)

        let owned = try await store.ownedCardInstances()
        #expect(owned.count == recipe.packSize)
        let packs = try await store.packInstances()
        #expect(packs.first?.state == .opened)
        let sealedCount = try await store.sealedPackCount()
        #expect(sealedCount == 0)
    }

    @Test("같은 팩을 다시 열어도 카드가 다시 뽑히지 않는다")
    func reopeningReturnsStoredResult() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store)

        let first = try await store.openPack(instanceID: pack.id, seed: 1)
        let second = try await store.openPack(instanceID: pack.id, seed: 999_999)

        #expect(first.id == second.id)
        #expect(first.cards == second.cards)
        let owned = try await store.ownedCardInstances()
        #expect(owned.count == first.cards.count)
    }

    @Test("저장 직전에 실패하면 팩은 미개봉으로 남는다")
    func openingFailureLeavesPackSealed() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store)
        await store.setInjectedFailureForTesting(.beforeOpeningCommit)

        let error = await captureError("주입된 개봉 실패") {
            try await store.openPack(instanceID: pack.id, seed: 5)
        }
        #expect(error == .injectedFailure("opening.before-commit"))

        let packs = try await store.packInstances()
        let owned = try await store.ownedCardInstances()
        let opening = try await store.opening(forPack: pack.id)
        #expect(packs.first?.state == .sealed)
        #expect(owned.isEmpty)
        #expect(opening == nil)
        let sealedCount = try await store.sealedPackCount()
        #expect(sealedCount == 1)

        await store.setInjectedFailureForTesting(nil)
        let committed = try await store.openPack(instanceID: pack.id, seed: 5)
        #expect(committed.cards.count == 6)
    }

    @Test("공개 도중 앱이 종료되어도 저장된 결과와 진행 위치로 복구한다")
    func revealProgressSurvivesRestart() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store)
        let opening = try await store.openPack(instanceID: pack.id, seed: 77)
        _ = try await store.setRevealedCount(openingID: opening.id, count: 3)

        // A second store on the same directory stands in for a relaunched app.
        let relaunched = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog(), location: store.location)
        let restored = try #require(try await relaunched.opening(forPack: pack.id))

        #expect(restored.id == opening.id)
        #expect(restored.revealedCount == 3)
        #expect(restored.cards == opening.cards)
        let unfinished = try await relaunched.unfinishedOpenings()
        #expect(unfinished.count == 1)

        // Re-opening the same pack after the restart must not draw again.
        let again = try await relaunched.openPack(instanceID: pack.id, seed: 12_345)
        #expect(again.id == opening.id)
        #expect(again.cards == opening.cards)
        let owned = try await relaunched.ownedCardInstances()
        #expect(owned.count == opening.cards.count)
    }

    @Test("공개 진행은 저장되고 마지막 장에서 완료 시각이 기록된다")
    func revealProgressIsPersisted() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store)
        let opening = try await store.openPack(instanceID: pack.id, seed: 4)

        for expected in 1...opening.cards.count {
            let updated = try await store.setRevealedCount(openingID: opening.id, count: expected)
            #expect(updated.revealedCount == expected)
            #expect(updated.isComplete == (expected == opening.cards.count))
        }
        let completed = try #require(try await store.opening(id: opening.id))
        #expect(completed.completedAt != nil)

        // 진행 위치는 클램프된다: 범위를 넘겨도 장수 이상으로 저장되지 않는다.
        let clampedHigh = try await store.setRevealedCount(openingID: opening.id, count: 999)
        #expect(clampedHigh.revealedCount == opening.cards.count)
        let clampedLow = try await store.setRevealedCount(openingID: opening.id, count: -4)
        #expect(clampedLow.revealedCount == 0)
    }

    @Test("빠르게 열기와 한 장씩 열기가 같은 결과를 남긴다")
    func fastRevealMatchesStepwise() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()

        let packA = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 101).packInstance
        let packB = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 101).packInstance
        let openingA = try await store.openPack(instanceID: packA.id, seed: 8)
        let openingB = try await store.openPack(instanceID: packB.id, seed: 8)

        #expect(openingA.cards == openingB.cards)
        _ = try await store.setRevealedCount(openingID: openingA.id, count: openingA.cards.count)
        for step in 1...openingB.cards.count {
            _ = try await store.setRevealedCount(openingID: openingB.id, count: step)
        }

        let fast = try #require(try await store.opening(id: openingA.id))
        let stepwise = try #require(try await store.opening(id: openingB.id))
        #expect(fast.cards == stepwise.cards)
        #expect(fast.isComplete == stepwise.isComplete)

        let owned = try await store.ownedCardInstances()
        #expect(owned.count == openingA.cards.count * 2)
    }

    @Test("두 팩을 열면 소유 카드가 20장 쌓인다")
    func twoPacksAccumulate() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        let packA = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 3).packInstance
        let packB = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 4).packInstance

        _ = try await store.openPack(instanceID: packA.id, seed: 30)
        _ = try await store.openPack(instanceID: packB.id, seed: 40)

        let owned = try await store.ownedCardInstances()
        let openings = try await store.openings()
        #expect(owned.count == 12)
        #expect(openings.count == 2)
        #expect(Set(openings.map(\.packInstanceID)) == Set([packA.id, packB.id]))
    }

    @Test("없는 팩을 열려 하면 팩 없음 오류가 난다")
    func openingUnknownPackFails() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let missing = PackInstanceID()
        let error = await captureError("없는 팩 개봉") {
            try await store.openPack(instanceID: missing, seed: 1)
        }
        #expect(error == .packNotFound(missing))
    }
}
