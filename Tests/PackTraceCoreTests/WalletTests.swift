import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("지갑과 팩 교환")
struct WalletTests {
    @Test("개발용 포인트는 데이터베이스당 한 번만 지급된다")
    func demoGrantHappensOnce() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let first = try await store.grantInitialDemoPoints()
        let second = try await store.grantInitialDemoPoints()

        #expect(first == PackEconomy.v1.initialDemoGrantPoints)
        #expect(second == nil)
        let balance = try await store.balance()
        #expect(balance == 500)
        let ledger = try await store.ledger()
        #expect(ledger.count == 1)
        #expect(ledger.first?.reason == .demoInitialGrant)
    }

    @Test("실사용(production) 지갑에는 개발용 지급이 발생하지 않는다")
    func productionRealmGetsNoDemoGrant() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog(), realm: .production)
        let granted = try await store.grantInitialDemoPoints()
        let balance = try await store.balance()

        #expect(granted == nil)
        #expect(balance == 0)
        let entries = try await store.ledger()
        #expect(entries.isEmpty)
    }

    @Test("잔액이 부족하면 차감도 팩 지급도 일어나지 않는다")
    func insufficientBalanceLeavesNoTrace() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let error = await captureError("잔액 부족 교환") {
            try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 1)
        }

        #expect(error == .insufficientBalance(required: 100, available: 0))
        let balance = try await store.balance()
        let packs = try await store.packInstances()
        let ledger = try await store.ledger()
        #expect(balance == 0)
        #expect(packs.isEmpty)
        #expect(ledger.isEmpty)
    }

    @Test("같은 교환 요청 ID는 한 번만 차감하고 같은 팩을 돌려준다")
    func repeatedRequestIdChargesOnce() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        let requestID = ExchangeRequestID()

        let first = try await store.exchangePack(pool: try store.testPool(), requestID: requestID, seed: 11)
        let second = try await store.exchangePack(pool: try store.testPool(), requestID: requestID, seed: 999)

        #expect(first.packInstance.id == second.packInstance.id)
        #expect(first.reusedExistingRequest == false)
        #expect(second.reusedExistingRequest == true)
        let balance = try await store.balance()
        #expect(balance == 400)
        let packs = try await store.packInstances()
        #expect(packs.count == 1)
        // The second call must not have re-rolled the pack product.
        #expect(packs.first?.productID == first.packInstance.productID)
    }

    @Test("거의 동시에 같은 교환 요청이 와도 한 번만 처리된다")
    func concurrentSameRequestChargesOnce() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        let requestID = ExchangeRequestID()

        let outcomes = await withTaskGroup(of: PackInstanceID?.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await store.exchangePack(pool: try store.testPool(), requestID: requestID, seed: SeedSource.randomSeed()).packInstance.id
                }
            }
            var ids: [PackInstanceID?] = []
            for await id in group { ids.append(id) }
            return ids
        }

        let unique = Set(outcomes.compactMap { $0?.rawValue })
        #expect(unique.count == 1)
        let balance = try await store.balance()
        let packs = try await store.packInstances()
        #expect(balance == 400)
        #expect(packs.count == 1)
    }

    @Test("서로 다른 요청이 동시에 와도 잔액을 넘겨 차감하지 않는다")
    func concurrentDistinctRequestsRespectBalance() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    do {
                        _ = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: SeedSource.randomSeed())
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var outcomes: [Bool] = []
            for await result in group { outcomes.append(result) }
            return outcomes
        }

        let succeeded = results.filter { $0 }.count
        let balance = try await store.balance()
        let packs = try await store.packInstances()
        let ledger = try await store.ledger()
        let ledgerSum = ledger.reduce(0) { $0 + $1.deltaPoints }

        #expect(succeeded == 5, "500 P로는 100 P 팩을 5번까지만 받을 수 있습니다")
        #expect(balance == 0)
        #expect(packs.count == 5)
        #expect(ledgerSum == balance)
    }

    @Test("저장 직전 실패하면 차감과 팩 지급이 모두 남지 않는다")
    func exchangeFailureRollsBack() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        await store.setInjectedFailureForTesting(.beforeExchangeCommit)

        let error = await captureError("주입된 교환 실패") {
            try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 3)
        }
        #expect(error == .injectedFailure("exchange.before-commit"))

        let balanceAfterFailure = try await store.balance()
        let packsAfterFailure = try await store.packInstances()
        let ledgerAfterFailure = try await store.ledger()
        #expect(balanceAfterFailure == 500)
        #expect(packsAfterFailure.isEmpty)
        #expect(ledgerAfterFailure.count == 1)

        await store.setInjectedFailureForTesting(nil)
        let outcome = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 3)
        let balance = try await store.balance()
        #expect(outcome.balanceAfter == 400)
        #expect(balance == 400)
    }

    @Test("잔액은 장부 합계와 항상 같고 음수가 되지 않는다")
    func balanceMatchesLedger() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        for seed in 0..<3 {
            _ = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: UInt64(seed))
        }
        let balance = try await store.balance()
        let ledger = try await store.ledger()
        let packs = try await store.packInstances()
        let spent = packs.count * PackEconomy.v1.packCostPoints

        #expect(balance == 200)
        #expect(balance == ledger.reduce(0) { $0 + $1.deltaPoints })
        #expect(balance + spent == 500)
        #expect(balance >= 0)
    }
}
