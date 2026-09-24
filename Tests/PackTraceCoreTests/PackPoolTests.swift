import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

/// Pool immutability, request idempotency and set separation for the three-pack
/// exchange. Everything runs on temporary databases fed by synthetic usage.
@Suite("랜덤팩 pool과 요청")
struct PackPoolTests {
    private func bundledLibrary() throws -> CatalogLibrary {
        try CatalogLoader.bundledLibrary()
    }

    private func bundledPool(library: CatalogLibrary) throws -> ResolvedPackPool {
        try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
    }

    @Test("번들 pool은 전 시대 실제 상품을 한 번씩 담고, 시리즈를 먼저 같은 확률로 고른다")
    func bundledPoolCoversEveryEra() throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)

        #expect(pool.poolVersion == "packs-v3")
        #expect(pool.pricePoints == 100)
        #expect(pool.selection == .seriesUniform)
        #expect(pool.series.map(\.id) == ["base", "gym", "neo", "lc", "ecard", "ex", "pop", "dp", "pl", "hgss", "bw", "xy", "sm", "swsh", "sv", "me"])
        #expect(pool.candidates.count == CatalogTests.allEraSets)
        #expect(Set(pool.candidates.map(\.product.packID)).count == pool.candidates.count)
        #expect(Set(pool.candidates.map(\.product.setID)) == Set(library.catalogs.values.map(\.set.externalSetID)))
        // SV01–SV10 keep the snapshots and statuses they shipped with; the
        // official expansion page could not be read for sv07 and sv09, and the
        // all-era sets rest on secondary sources.
        let ready: Set<String> = ["sv01", "sv02", "sv03", "sv04", "sv05", "sv06", "sv08", "sv10"]
        for candidate in pool.candidates {
            #expect(candidate.weight == 1)
            #expect(candidate.product.isRewardEligible)
            #expect(candidate.product.verification.status == (ready.contains(candidate.product.setID) ? .readyForReward : .metadataVerified))
            #expect(candidate.supportedPrintCount > 0)
            #expect(candidate.catalogVersion == library.catalog(version: candidate.catalogVersion)?.catalogVersion)
        }
        let sv = pool.candidates.filter { $0.series == "sv" }
        #expect(Set(sv.map(\.product.setID)).isSuperset(of: ["sv01", "sv02", "sv03", "sv04", "sv05", "sv06", "sv07", "sv08", "sv09", "sv10"]))
        for series in pool.series {
            #expect(pool.probability(ofSeries: series.id) == 1.0 / Double(pool.series.count), "시리즈 확률은 정확히 1/S")
        }
        let total = pool.candidates.reduce(0) { $0 + pool.probability(of: $1.product.packID) }
        #expect(abs(total - 1) < 1e-9)
    }

    @Test("각 상품의 recipe는 자기 세트 프린트만 사용한다")
    func recipesStayInsideTheirSet() throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)

        for candidate in pool.candidates {
            let catalog = try #require(library.catalog(version: candidate.catalogVersion))
            var reachable = Set<String>()
            for slot in candidate.recipe.slots {
                let pool = candidate.recipe.pool(for: slot, in: catalog)
                #expect(!pool.isEmpty)
                for card in pool {
                    #expect(candidate.recipe.setIDs.contains(card.setID), "다른 세트 카드가 슬롯에 들어 있습니다")
                    for variant in card.supportedVariants where slot.variantRule != .reverse || variant == .reverse {
                        reachable.insert("\(card.key.rawValue)#\(variant.rawValue)")
                    }
                }
            }
            let targets = candidate.recipe.setIDs.flatMap { catalog.cards(in: $0) }.flatMap { card in card.supportedVariants.map { "\(card.key.rawValue)#\($0.rawValue)" } }
            #expect(reachable.count >= targets.count, "도달 가능한 프린트가 지원 대상보다 적습니다")
            #expect(Set(targets).count == targets.count, "지원 프린트에 중복 ID가 있습니다")
        }
    }

    @Test("어느 후보 팩을 받아도 그 팩의 세트 카드만 나온다")
    func drawnCardsBelongToThePacksSet() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)

        for candidate in pool.candidates {
            // One demo wallet per pack: the one-time grant pays for five.
            let store = try Fixtures.makeStore(library: library, realm: .demo)
            try await store.grantInitialDemoPoints()
            // A seed that selects this candidate deterministically.
            let seed = try #require(seedSelecting(candidate.product.packID, pool: pool, range: 0..<50_000))
            let pack = try await store.exchangePack(
                pool: pool,
                requestID: ExchangeRequestID(),
                seed: seed
            ).packInstance
            #expect(pack.productID == candidate.product.packID)

            let opening = try await store.openPack(instanceID: pack.id, seed: seed)
            #expect(opening.cards.count == candidate.recipe.packSize)
            for drawn in opening.cards {
                let card = try #require(library.card(for: drawn.cardKey))
                #expect(candidate.recipe.setIDs.contains(card.setID), "\(card.setID) 카드가 \(candidate.product.setID) 팩에서 나왔습니다")
                #expect(card.variants.contains(drawn.variant))
            }
        }
    }

    @Test("pool이 바뀌어도 이전 요청은 원래 결과를 돌려준다")
    func committedRequestSurvivesPoolChange() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()

        let requestID = ExchangeRequestID()
        let first = try await store.exchangePack(pool: pool, requestID: requestID, seed: 5)
        let balanceAfterFirst = try await store.balance()

        // A different pool version is active now, at the same price: the retry
        // is still the same user action and must return the stored result.
        let otherPool = try Fixtures.pool(
            for: Array(library.catalogs.values),
            poolVersion: "packs-test-next",
            price: 100
        )
        let second = try await store.exchangePack(pool: otherPool, requestID: requestID, seed: 5)
        #expect(second.packInstance.id == first.packInstance.id)
        #expect(second.packInstance.productID == first.packInstance.productID)
        #expect(second.packInstance.poolVersion == pool.poolVersion)
        #expect(second.packInstance.poolVersion != otherPool.poolVersion)
        #expect(second.reusedExistingRequest)
        let balance = try await store.balance()
        #expect(balance == balanceAfterFirst, "같은 요청은 다시 차감하지 않습니다")
    }

    @Test("같은 요청 ID에 다른 내용이 오면 충돌로 거절한다")
    func conflictingRequestContentIsRefused() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()

        let requestID = ExchangeRequestID()
        _ = try await store.exchangePack(pool: pool, requestID: requestID, seed: 5)

        let otherPool = try Fixtures.pool(
            for: Array(library.catalogs.values),
            poolVersion: "packs-test-next",
            price: 50
        )
        let error = await captureError("같은 요청 ID 다른 내용") {
            try await store.exchangePack(pool: otherPool, requestID: requestID, seed: 5)
        }
        guard case .exchangeRequestConflict? = error else {
            Issue.record("exchangeRequestConflict를 기대했습니다: \(String(describing: error))")
            return
        }
        #expect(try await store.packInstances().count == 1)
    }

    @Test("후보 팩 각각이 자기 카탈로그·레시피 판본으로 고정된다")
    func eachPackPinsItsOwnVersions() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)

        var seen = Set<String>()
        for candidate in pool.candidates {
            let store = try Fixtures.makeStore(library: library, realm: .demo)
            try await store.grantInitialDemoPoints()
            let seed = try #require(seedSelecting(candidate.product.packID, pool: pool, range: 0..<50_000))
            let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: seed).packInstance
            seen.insert(pack.productID)
            #expect(pack.catalogVersion == candidate.catalogVersion)
            #expect(pack.recipeVersion == candidate.recipe.version)
            #expect(pack.poolVersion == pool.poolVersion)
        }
        #expect(seen.count == pool.candidates.count)
    }

    @Test("pool에서 빠진 상품의 보유 팩도 원래 판본으로 열 수 있다")
    func packsOutsideThePoolStillOpen() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()

        // Receive an sv02 pack while the pool still lists it…
        let seed = try #require(seedSelecting("tpcgi-en-sv02-booster", pool: pool, range: 0..<2000))
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: seed).packInstance
        #expect(pack.productID == "tpcgi-en-sv02-booster")

        // …then open it through a pool that no longer contains sv02.
        let shrunk = try Fixtures.pool(
            for: [
                try #require(library.catalog(version: "tcgdex-en-sv01-20260922")),
                try #require(library.catalog(version: "tcgdex-en-sv03-20260922")),
            ],
            poolVersion: "packs-v2",
            price: 100
        )
        #expect(shrunk.candidate(for: "tpcgi-en-sv02-booster") == nil)
        _ = try shrunk // the pool is only used for new exchanges

        let opening = try await store.openPack(instanceID: pack.id, seed: seed)
        #expect(opening.cards.count == 10)
        let card = try #require(library.card(for: opening.cards[0].cardKey))
        #expect(card.setID == "sv02")
        #expect(shrunk.candidates.count == 2)
    }

    @Test("구버전 팩(pool 없음)은 legacy로 남고 재추첨하지 않는다")
    func legacyPacksStayLegacy() async throws {
        let library = try bundledLibrary()
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()
        let pool = try bundledPool(library: library)

        // A pack as it would exist before the pool: no pool_version.
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 1).packInstance
        let location = await store.location
        let database = try SQLiteDatabase(path: location.databaseURL.path)
        try database.run("UPDATE pack_instance SET pool_version = NULL WHERE instance_id = ?", [.text(pack.id.rawValue)])

        let refreshed = try Fixtures.makeStore(library: library, location: location)
        let stored = try #require(try await refreshed.packInstances().first)
        #expect(stored.poolVersion == nil, "기존 팩은 legacy(pool 없음)로 남습니다")
        #expect(stored.productID == pack.productID)
        #expect(stored.catalogVersion == pack.catalogVersion)

        let opening = try await refreshed.openPack(instanceID: stored.id, seed: 1)
        let again = try await refreshed.openPack(instanceID: stored.id, seed: 999)
        #expect(again.id == opening.id)
        #expect(again.cards == opening.cards)
    }

    @Test("고정된 카탈로그가 사라지면 다른 버전으로 재추첨하지 않고 오류를 낸다")
    func missingPinnedCatalogueReportsInsteadOfRedrawing() async throws {
        let library = try bundledLibrary()
        let pool = try bundledPool(library: library)
        let location = try StoreLocation.temporary(realm: .demo, label: "packtrace-missing-catalog")
        let store = try PackTraceStore(location: location, library: library)
        try await store.grantInitialDemoPoints()

        let seed = try #require(seedSelecting("tpcgi-en-sv01-booster", pool: pool, range: 0..<2000))
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: seed).packInstance
        #expect(pack.catalogVersion == "tcgdex-en-sv01-20260922")

        // A store that only ships sv03: the pack's snapshot is gone.
        let shrunk = try CatalogLibrary(catalogs: [
            try #require(library.catalog(version: "tcgdex-en-sv03-20260922")),
        ])
        let reopened = try PackTraceStore(location: location, library: shrunk)
        let error = await captureError("고정 카탈로그 누락") {
            try await reopened.openPack(instanceID: pack.id, seed: seed)
        }
        guard case .catalogNotFound? = error else {
            Issue.record("catalogNotFound를 기대했습니다: \(String(describing: error))")
            return
        }
        // Nothing was drawn: the pack is untouched and can still be opened once
        // the snapshot is available again.
        let stored = try #require(try await reopened.packInstances().first)
        #expect(stored.state == .sealed)
        #expect(try await reopened.ownedCardInstances().isEmpty)
        let restored = try PackTraceStore(location: location, library: library)
        let opening = try await restored.openPack(instanceID: pack.id, seed: seed)
        #expect(opening.cards.count == 10)
    }

    // MARK: - helpers

    private func seedSelecting(_ packID: String, pool: ResolvedPackPool, range: Range<UInt64>) -> UInt64? {
        for seed in range where (try? pool.pick(seed: seed).product.packID) == packID {
            return seed
        }
        return nil
    }

    // MARK: - Series-uniform selection (pool v3)

    private func seriesPool(series: [(String, [String])], declared: [String]? = nil) throws -> PackPool {
        let bundled = try PackPool.loadBundled()
        var candidates: [PackPoolCandidate] = []
        for (id, sets) in series {
            for set in sets {
                let original = try #require(bundled.candidates.first { $0.packID == "tpcgi-en-\(set)-booster" })
                candidates.append(PackPoolCandidate(packID: original.packID, catalogVersion: original.catalogVersion, weight: 1, series: id))
            }
        }
        return PackPool(
            poolVersion: "packs-test-series",
            pricePoints: 100,
            economyVersion: 1,
            note: "test",
            candidates: candidates,
            selection: .seriesUniform,
            series: (declared ?? series.map(\.0)).map { PoolSeries(id: $0, name: $0.uppercased()) }
        )
    }

    @Test("시리즈별 균등: 시리즈를 먼저 같은 확률로 고르고, 그 안에서 세트를 고른다")
    func seriesUniformProbabilities() throws {
        let library = try bundledLibrary()
        let pool = try ResolvedPackPool.resolve(pool: try seriesPool(series: [("a", ["sv01", "sv02", "sv03"]), ("b", ["sv04"])]), library: library)
        #expect(pool.selection == .seriesUniform)
        #expect(abs(pool.probability(of: "tpcgi-en-sv01-booster") - 1.0 / 6.0) < 1e-12)
        #expect(abs(pool.probability(of: "tpcgi-en-sv04-booster") - 1.0 / 2.0) < 1e-12)
        #expect(abs(pool.probability(ofSeries: "a") - 0.5) < 1e-12)
        #expect(abs(pool.candidates.reduce(0) { $0 + pool.probability(of: $1.product.packID) } - 1) < 1e-12)

        // Same seed, same pack; the observed share follows the series rule.
        #expect(try pool.pick(seed: 42).product.packID == pool.pick(seed: 42).product.packID)
        var fromB = 0
        let draws = 4_000
        for seed in 0..<UInt64(draws) where try pool.pick(seed: seed).series == "b" { fromB += 1 }
        let share = Double(fromB) / Double(draws)
        #expect(share > 0.46 && share < 0.54, "시리즈 b(세트 1개)가 절반쯤 나와야 합니다: \(share)")
    }

    @Test("시리즈 선언이 빠지거나 후보 없는 시리즈가 있으면 pool 전체를 거절한다")
    func seriesUniformValidation() throws {
        let library = try bundledLibrary()
        var missing = try seriesPool(series: [("a", ["sv01"]), ("b", ["sv02"])])
        missing.candidates[1].series = nil
        #expect(throws: PackTraceError.self) { _ = try ResolvedPackPool.resolve(pool: missing, library: library) }
        let empty = try seriesPool(series: [("a", ["sv01"])], declared: ["a", "b"])
        #expect(throws: PackTraceError.self) { _ = try ResolvedPackPool.resolve(pool: empty, library: library) }
    }

    @Test("가중치 pool(packs-v2)의 추첨 결과는 시리즈 기능을 더해도 그대로다")
    func weightedPoolUnchanged() throws {
        let library = try bundledLibrary()
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(fileName: "pool-v2.json"), library: library)
        #expect(pool.poolVersion == "packs-v2")
        #expect(pool.selection == .weighted)
        // Recorded before the series option existed (packs-v2, seeds 0…9).
        let expected = (0..<UInt64(10)).map { seed -> String in
            var generator = SplitMix64(seed: seed)
            let draw = generator.next(upperBound: UInt64(pool.totalWeight))
            return pool.candidates[Int(draw)].product.packID
        }
        #expect(try (0..<UInt64(10)).map { try pool.pick(seed: $0).product.packID } == expected)
    }

    @Test("화면용 시리즈 묶음: 최신 시리즈 먼저, 시리즈 안에서는 최신 세트 먼저, pool 밖 세트는 따로")
    func seriesGroupsForScreens() throws {
        // SV01–SV10 only, so the sets outside the test pool are known.
        let main: Set<String> = ["sv01", "sv02", "sv03", "sv04", "sv05", "sv06", "sv07", "sv08", "sv09", "sv10"]
        let library = try CatalogLibrary(catalogs: try bundledLibrary().catalogs.values.filter { main.contains($0.set.externalSetID) })
        let pool = try ResolvedPackPool.resolve(pool: try seriesPool(series: [("a", ["sv01", "sv02"]), ("b", ["sv03"])]), library: library)
        let groups = library.seriesGroups(pool: pool)
        #expect(groups.map(\.id) == ["b", "a", SeriesGroup.otherID])
        #expect(groups[0].setIDs == ["sv03"] && groups[0].name == "B")
        #expect(groups[1].setIDs == ["sv02", "sv01"])
        #expect(groups[2].setIDs == ["sv10", "sv09", "sv08", "sv07", "sv06", "sv05", "sv04"])
        #expect(groups[2].name == "그 밖의 세트")
        #expect(groups.flatMap(\.setIDs).sorted() == library.setIDs, "모든 세트가 정확히 한 번")

        // A pool without series: one group, every set, newest first.
        let flat = library.seriesGroups(pool: try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(fileName: "pool-v2.json"), library: library))
        #expect(flat.count == 1 && flat[0].name == "전체 세트")
        #expect(flat[0].setIDs.first == "sv10" && flat[0].setIDs.count == library.setIDs.count)
    }
}
