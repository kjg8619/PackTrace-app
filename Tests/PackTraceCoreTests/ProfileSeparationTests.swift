import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("demo 보존과 production 분리")
struct ProfileSeparationTests {
    /// Builds a demo collection (grant, one pack, one opening) and returns the
    /// store plus its location.
    private func makeDemoCollection() async throws -> (PackTraceStore, StoreLocation) {
        let location = try StoreLocation.temporary(realm: .demo, label: "packtrace-profile")
        let store = try PackTraceStore(location: location, catalog: CatalogLoader.loadBundled())
        try await store.grantInitialDemoPoints()
        let pack = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 5).packInstance
        _ = try await store.openPack(instanceID: pack.id, seed: 5)
        _ = try await store.setRevealedCount(
            openingID: try #require(try await store.opening(forPack: pack.id)).id,
            count: 4
        )
        return (store, location)
    }

    @Test("실사용 적립은 demo 지갑·팩·카드에 영향을 주지 않는다")
    func usageRewardsDoNotTouchDemo() async throws {
        let (demo, _) = try await makeDemoCollection()
        let demoBalanceBefore = try await demo.balance()
        let demoPacksBefore = try await demo.packInstances().count
        let demoCardsBefore = try await demo.ownedCardInstances().count

        // Usage collection lives in the production realm.
        let harness = try UsageTestSupport.harness(realm: .production)
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)
        _ = try await harness.drain()

        let productionBalance = try await harness.store.balance()
        let demoBalanceAfter = try await demo.balance()
        #expect(productionBalance == 1)
        #expect(demoBalanceAfter == demoBalanceBefore)
        #expect(try await demo.packInstances().count == demoPacksBefore)
        #expect(try await demo.ownedCardInstances().count == demoCardsBefore)
        let ledger = try await demo.ledger()
        #expect(ledger.allSatisfy { $0.reason != .usageReward })
    }

    @Test("production 지갑은 0 P로 시작하고 개발용 지급을 저장 계층에서 거부한다")
    func productionRefusesDemoGrant() async throws {
        let location = try StoreLocation.temporary(realm: .production, label: "packtrace-profile")
        let store = try PackTraceStore(location: location, catalog: CatalogLoader.loadBundled())

        #expect(try await store.balance() == 0)
        let granted = try await store.grantInitialDemoPoints()
        #expect(granted == nil, "저장 계층이 개발용 지급을 거부해야 합니다")
        #expect(try await store.balance() == 0)
        let ledger = try await store.ledger()
        #expect(ledger.isEmpty)
        let demoLocation = try StoreLocation.applicationSupport(realm: .demo)
        let productionLocation = try StoreLocation.applicationSupport(realm: .production)
        #expect(demoLocation != productionLocation)
    }

    @Test("적립한 production 포인트로 production 팩을 사고 demo는 그대로다")
    func productionPacksArePaidFromUsagePoints() async throws {
        let (demo, _) = try await makeDemoCollection()
        let demoPacksBefore = try await demo.packInstances().count

        let harness = try UsageTestSupport.harness(realm: .production)
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        // 1,000,000 accepted tokens = 100 P = one pack.
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(1),
                input: 1_000_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(1),
                completedAt: OMPFixture.timestamp(2)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let earned = try await harness.store.usageTotals()
        #expect(earned.awardedPoints == 100)
        #expect(try await harness.store.balance() == 100)

        let pack = try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 7).packInstance
        #expect(try await harness.store.balance() == 0)
        #expect(try await harness.store.packInstances().count == 1)

        let opening = try await harness.store.openPack(instanceID: pack.id, seed: 7)
        #expect(opening.cards.count == 10)
        let pool = try harness.store.testPool()
        let storedPack = try #require(try await harness.store.packInstances().first)
        let storedCandidate = try #require(pool.candidate(for: storedPack.productID))
        #expect(storedPack.catalogVersion == storedCandidate.catalogVersion)
        #expect(storedPack.poolVersion == pool.poolVersion)

        // Demo wallet and collection are untouched by any of it.
        #expect(try await demo.packInstances().count == demoPacksBefore)
        let demoBalance = try await demo.balance()
        #expect(demoBalance == 400)
    }

    @Test("잔액이 부족하면 production 교환은 정상적으로 막힌다")
    func productionExchangeRequiresBalance() async throws {
        let harness = try UsageTestSupport.harness(realm: .production)
        defer { harness.tree.remove() }
        let error = await captureError("production 잔액 부족") {
            try await harness.store.exchangePack(pool: try harness.store.testPool(), requestID: ExchangeRequestID(), seed: 1)
        }
        #expect(error == .insufficientBalance(required: 100, available: 0))
        #expect(try await harness.store.packInstances().isEmpty)
    }

    @Test("프로필별 저장소는 동시 작업에서도 서로의 기록을 섞지 않는다")
    func concurrentRealmsStaySeparate() async throws {
        let (demo, _) = try await makeDemoCollection()
        let production = try Fixtures.makeStore(catalog: CatalogLoader.loadBundled(), realm: .production)

        async let demoPurchase: Void = {
            for seed in 0..<3 {
                _ = try? await demo.exchangePack(pool: try demo.testPool(), requestID: ExchangeRequestID(), seed: UInt64(seed))
            }
        }()
        async let productionPurchase: Void = {
            for seed in 0..<3 {
                _ = try? await production.exchangePack(pool: try production.testPool(), requestID: ExchangeRequestID(), seed: UInt64(seed))
            }
        }()
        _ = await (demoPurchase, productionPurchase)

        let demoPacks = try await demo.packInstances()
        let productionPacks = try await production.packInstances()
        #expect(demoPacks.count == 4, "demo는 최초 1팩 + 3팩")
        #expect(productionPacks.isEmpty, "잔액 없는 production은 팩을 만들지 않습니다")
        let demoLocation = await demo.location
        let productionLocation = await production.location
        #expect(demoLocation.databaseURL != productionLocation.databaseURL)
    }
}
