import Foundation
import PackTraceCore
import PackTraceTestSupport
import Testing

/// Purchase flow at the shipping economy: 100 P per pack, in a temporary
/// production database fed by synthetic usage. No user data and no network.
@Suite("실사용 가격(100 P) 구매 통합")
struct UsagePurchaseAtRealPriceTests {
    /// Gives the production wallet exactly `points` by collecting one synthetic
    /// usage record of `points * 10_000` accepted tokens.
    @discardableResult
    private func earn(_ points: Int, harness: UsageTestSupport.Harness, path: String) async throws -> UsageTotals {
        let tokens = points * UsageRewardRule.ompNonCacheV1.tokensPerPoint
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(points),
                input: tokens,
                output: 0,
                occurredAt: Int(Date().timeIntervalSince1970 * 1000),
                completedAt: Int(Date().timeIntervalSince1970 * 1000) + 1_000
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()
        return try await harness.store.usageTotals()
    }

    private func makeHarness() async throws -> (UsageTestSupport.Harness, String) {
        let harness = try UsageTestSupport.harness()
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        return (harness, path)
    }

    @Test("99 P에서는 교환이 거절되고 아무것도 바뀌지 않는다")
    func ninetyNinePointsIsRefused() async throws {
        let (harness, path) = try await makeHarness()
        defer { harness.tree.remove() }
        let earned = try await earn(99, harness: harness, path: path)
        #expect(earned.awardedPoints == 99)

        let error = await captureError("99 P 구매") {
            try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 1)
        }
        #expect(error == .insufficientBalance(required: 100, available: 99))
        let balance = try await harness.store.balance()
        let ledger = try await harness.store.ledger(limit: 100)
        let packs = try await harness.store.packInstances()
        #expect(balance == 99)
        #expect(ledger.filter { $0.reason == .packExchange }.isEmpty)
        #expect(packs.isEmpty)
    }

    @Test("100 P에서 팩 1개를 받고 잔액이 0 P가 된다")
    func hundredPointsBuysOnePack() async throws {
        let (harness, path) = try await makeHarness()
        defer { harness.tree.remove() }
        let earned = try await earn(100, harness: harness, path: path)
        #expect(earned.awardedPoints == 100)

        let pool = try harness.store.testPool()
        let outcome = try await harness.store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 7)
        #expect(try await harness.store.balance() == 0)
        #expect(try await harness.store.packInstances().count == 1)
        #expect(outcome.packInstance.state == .sealed)
        // The pack is pinned to the catalogue of the product that was drawn.
        let candidate = try #require(pool.candidate(for: outcome.packInstance.productID))
        #expect(outcome.packInstance.catalogVersion == candidate.catalogVersion)
        #expect(outcome.packInstance.recipeVersion == candidate.recipe.version)
        #expect(outcome.packInstance.poolVersion == pool.poolVersion)
    }

    @Test("101 P에서 팩 1개를 받고 1 P가 남는다")
    func hundredOnePointsLeavesOne() async throws {
        let (harness, path) = try await makeHarness()
        defer { harness.tree.remove() }
        _ = try await earn(101, harness: harness, path: path)

        _ = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 8)
        let balance = try await harness.store.balance()
        let ledger = try await harness.store.ledger(limit: 100)
        #expect(balance == 1)
        #expect(ledger.reduce(0) { $0 + $1.deltaPoints } == balance)
        #expect(try await harness.store.packInstances().count == 1)
    }

    @Test("같은 구매 요청을 다시 보내도 팩이 중복 지급되지 않는다")
    func repeatedPurchaseRequestIsIdempotent() async throws {
        let (harness, path) = try await makeHarness()
        defer { harness.tree.remove() }
        _ = try await earn(200, harness: harness, path: path)
        let requestID = ExchangeRequestID()

        let first = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: requestID, seed: 11)
        let second = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: requestID, seed: 999)
        #expect(first.packInstance.id == second.packInstance.id)
        #expect(second.reusedExistingRequest)
        #expect(try await harness.store.packInstances().count == 1)
        #expect(try await harness.store.balance() == 100, "한 번만 차감되어야 합니다")

        // A second pack with the remaining balance is a different request.
        _ = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 12)
        #expect(try await harness.store.packInstances().count == 2)
        #expect(try await harness.store.balance() == 0)

        // With no balance left the next purchase is refused.
        let error = await captureError("잔액 소진 후 구매") {
            try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 13)
        }
        #expect(error == .insufficientBalance(required: 100, available: 0))
        #expect(try await harness.store.packInstances().count == 2)
    }

    @Test("사용량 적립 → 100 P 구매 → 개봉 → 저장소 재개방까지 한 흐름으로 유지된다")
    func fullLoopSurvivesReopen() async throws {
        let (harness, path) = try await makeHarness()
        defer { harness.tree.remove() }
        // 1,000,000 accepted tokens = 100 P.
        let earned = try await earn(100, harness: harness, path: path)
        #expect(earned.acceptedTokens == 1_000_000)
        #expect(earned.awardedPoints == 100)
        #expect(earned.remainderTokens == 0)

        let pack = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 21).packInstance
        #expect(try await harness.store.balance() == 0)
        let opening = try await harness.store.openPack(instanceID: pack.id, seed: 21)
        let catalog = try #require(harness.store.library.catalog(version: pack.catalogVersion))
        let product = try #require(catalog.products.first { $0.packID == pack.productID })
        #expect(opening.cards.count == catalog.recipe(id: product.recipeID)?.packSize)
        _ = try await harness.store.setRevealedCount(openingID: opening.id, count: 4)

        // Reopen the same directory: a new store instance over the same file.
        let reopened = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        #expect(try await reopened.balance() == 0)
        #expect(try await reopened.packInstances().count == 1)
        #expect(try await reopened.ownedCardInstances().count == opening.cards.count)
        let restored = try #require(try await reopened.opening(forPack: pack.id))
        #expect(restored.cards == opening.cards)
        #expect(restored.revealedCount == 4)

        // Usage state survives too, and re-scanning does not pay again.
        let totals = try await reopened.usageTotals()
        #expect(totals.awardedPoints == 100)
        let collector = OMPUsageCollector(store: reopened, limits: .standard)
        _ = try await collector.scan(trigger: .manual)
        #expect(try await reopened.usageTotals().awardedPoints == 100)
        #expect(try await reopened.balance() == 0)

        // The development grant is still refused in this realm.
        let granted = try await reopened.grantInitialDemoPoints()
        #expect(granted == nil)
        #expect(try await reopened.balance() == 0)
    }
}
