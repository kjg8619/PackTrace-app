import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

@Suite("랜덤팩 후보와 가중치")
struct ExchangeTests {
    /// Three catalogues whose card counts differ a lot, so a bias toward bigger
    /// sets would show up immediately.
    private func threeCatalogs() -> [PackCatalog] {
        var catalogs: [PackCatalog] = []
        for (index, version) in ["pool-a-v1", "pool-b-v1", "pool-c-v1"].enumerated() {
            var catalog = Fixtures.syntheticCatalog(productCount: 1, catalogVersion: version)
            // Distinct pack ids: a pool may not list the same product twice.
            catalog.products = catalog.products.map { product in
                var updated = product
                updated.packID = "\(product.packID)-\(version)"
                return updated
            }
            if index > 0 {
                // Duplicate the card list differently per catalogue: the third
                // one has by far the most cards.
                let extra = (0..<(index * 40)).map { offset in
                    var card = catalog.cards[offset % catalog.cards.count]
                    card.key = CardKey(rawValue: "\(card.key.rawValue)-x\(offset)")
                    card.localID = String(format: "%03d", 900 + offset)
                    card.name = "extra \(offset)"
                    return card
                }
                catalog.cards.append(contentsOf: extra)
                catalog.contentHash = CatalogLoader.contentHash(for: catalog)
            }
            catalogs.append(catalog)
        }
        return catalogs
    }

    @Test("후보 3종은 같은 가중치를 갖고 모두 선택 범위에 들어간다")
    func threeCandidatesAreUniform() throws {
        let catalogs = threeCatalogs()
        let pool = try Fixtures.pool(for: catalogs)

        #expect(pool.candidates.count == 3)
        for candidate in pool.candidates {
            #expect(abs(pool.probability(of: candidate.product.packID) - 1.0 / 3.0) < 1e-12)
        }

        // Deterministic boundary sweep: every candidate must be reachable, and
        // the selection must not depend on how many cards a set has.
        var counts: [String: Int] = [:]
        for seed in 0..<UInt64(600) {
            let picked = try pool.pick(seed: seed).product.packID
            counts[picked, default: 0] += 1
        }
        #expect(Set(counts.keys) == Set(pool.candidates.map(\.product.packID)))
        for (packID, count) in counts {
            #expect(count > 140 && count < 260, "\(packID) 선택 횟수 \(count)")
        }
    }

    @Test("경계 시드는 후보 범위 안에서 결정적이다")
    func boundarySeedsAreDeterministic() throws {
        let pool = try Fixtures.pool(for: threeCatalogs())
        let productIDs = Set(pool.candidates.map(\.product.packID))

        for seed in [UInt64(0), 1, UInt64.max, UInt64.max - 1] {
            let first = try pool.pick(seed: seed).product.packID
            let second = try pool.pick(seed: seed).product.packID
            #expect(productIDs.contains(first))
            #expect(first == second, "같은 시드는 같은 후보를 골라야 합니다")
        }
        #expect(pool.orderedPackIDs == pool.candidates.map(\.product.packID), "후보 순서는 안정적입니다")
    }

    @Test("같은 팩이 연속으로 나와도 재추첨하지 않는다")
    func repeatedProductIsAllowed() throws {
        let pool = try Fixtures.pool(for: threeCatalogs())
        // Find two seeds that pick the same product and confirm both stand.
        var seen: [String: UInt64] = [:]
        var pair: (UInt64, UInt64, String)?
        for seed in 0..<UInt64(200) {
            let picked = try pool.pick(seed: seed).product.packID
            if let first = seen[picked] {
                pair = (first, seed, picked)
                break
            }
            seen[picked] = seed
        }
        let (first, second, product) = try #require(pair)
        #expect(try pool.pick(seed: first).product.packID == product)
        #expect(try pool.pick(seed: second).product.packID == product)
    }

    @Test("준비되지 않은 상품이 섞이면 pool 전체가 무효다")
    func unpreparedProductInvalidatesTheWholePool() throws {
        var catalog = Fixtures.syntheticCatalog(productCount: 3, statuses: [.readyForReward, .demo, .readyForReward])
        catalog.contentHash = CatalogLoader.contentHash(for: catalog)
        let library = try CatalogLibrary(catalogs: [catalog])
        let pool = PackPool(
            poolVersion: "invalid-pool",
            pricePoints: 100,
            economyVersion: 1,
            note: "fixture",
            candidates: catalog.products.map {
                PackPoolCandidate(packID: $0.packID, catalogVersion: catalog.catalogVersion, weight: 1)
            }
        )
        let error = #expect(throws: PackTraceError.self) {
            _ = try ResolvedPackPool.resolve(pool: pool, library: library)
        }
        guard case .poolInvalid? = error else {
            Issue.record("poolInvalid를 기대했습니다: \(String(describing: error))")
            return
        }
    }

    @Test("카탈로그가 없으면 pool은 무효다")
    func missingCatalogInvalidatesThePool() throws {
        let catalog = Fixtures.syntheticCatalog(catalogVersion: "present-v1")
        let library = try CatalogLibrary(catalogs: [catalog])
        let pool = PackPool(
            poolVersion: "dangling-pool",
            pricePoints: 100,
            economyVersion: 1,
            note: "fixture",
            candidates: [
                PackPoolCandidate(packID: "synthetic-pack-1", catalogVersion: "absent-v1", weight: 1),
            ]
        )
        let error = #expect(throws: PackTraceError.self) {
            _ = try ResolvedPackPool.resolve(pool: pool, library: library)
        }
        guard case .poolInvalid? = error else {
            Issue.record("poolInvalid를 기대했습니다: \(String(describing: error))")
            return
        }
    }

    @Test("중복 후보와 0 가중치는 거부한다")
    func duplicateOrZeroWeightIsRejected() throws {
        let catalog = Fixtures.syntheticCatalog(catalogVersion: "dup-v1")
        let library = try CatalogLibrary(catalogs: [catalog])
        let packID = catalog.products[0].packID

        for candidates in [
            [
                PackPoolCandidate(packID: packID, catalogVersion: catalog.catalogVersion, weight: 1),
                PackPoolCandidate(packID: packID, catalogVersion: catalog.catalogVersion, weight: 1),
            ],
            [PackPoolCandidate(packID: packID, catalogVersion: catalog.catalogVersion, weight: 0)],
        ] {
            let pool = PackPool(
                poolVersion: "bad-pool",
                pricePoints: 100,
                economyVersion: 1,
                note: "fixture",
                candidates: candidates
            )
            let error = #expect(throws: PackTraceError.self) {
                _ = try ResolvedPackPool.resolve(pool: pool, library: library)
            }
            guard case .poolInvalid? = error else {
                Issue.record("poolInvalid를 기대했습니다: \(String(describing: error))")
                return
            }
        }
    }

    @Test("같은 요청을 다시 보내면 첫 교환과 같은 장부 기록과 잔액을 돌려준다")
    func replayReturnsTheSameOutcome() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        let pool = try store.testPool()
        let request = ExchangeRequestID()

        let first = try await store.exchangePack(pool: pool, requestID: request, seed: 5)
        let replay = try await store.exchangePack(pool: pool, requestID: request, seed: 99)
        #expect(first.reusedExistingRequest == false)
        #expect(replay.reusedExistingRequest)
        // Dates go through the database as seconds, so they are compared to the
        // millisecond; every other field has to be identical.
        func sameMoment(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }
        var pack = replay.packInstance
        #expect(sameMoment(pack.acquiredAt, first.packInstance.acquiredAt))
        pack.acquiredAt = first.packInstance.acquiredAt
        #expect(pack == first.packInstance)
        var entry = replay.ledgerEntry
        #expect(sameMoment(entry.createdAt, first.ledgerEntry.createdAt))
        entry.createdAt = first.ledgerEntry.createdAt
        #expect(entry == first.ledgerEntry, "재요청의 장부 기록이 첫 교환과 달라지면 안 됩니다")
        #expect(replay.ledgerEntry.idempotencyKey == "exchange:\(request.rawValue)")
        #expect(replay.ledgerEntry.deltaPoints == -pool.pricePoints)
        #expect(replay.balanceAfter == first.balanceAfter)
        #expect(replay.balanceAfter == (try await store.balance()))
    }

    @Test("팩에는 교환 시점의 pool·카탈로그·레시피 판본이 고정된다")
    func packPinsPoolCatalogAndRecipe() async throws {
        let catalog = Fixtures.syntheticCatalog(catalogVersion: "pinned-v1")
        let store = try Fixtures.makeStore(catalog: catalog)
        try await store.grantInitialDemoPoints()
        let pool = try store.testPool(poolVersion: "pinned-pool-v1")

        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 5).packInstance
        let candidate = try #require(pool.candidate(for: pack.productID))
        #expect(pack.poolVersion == "pinned-pool-v1")
        #expect(pack.catalogVersion == "pinned-v1")
        #expect(pack.recipeVersion == candidate.recipe.version)
        let stored = try await store.packRequest(requestID: ExchangeRequestID())
        #expect(stored == nil, "다른 요청 ID는 기록되지 않습니다")
    }
}
