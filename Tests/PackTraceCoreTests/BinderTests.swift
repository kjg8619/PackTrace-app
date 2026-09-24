import Foundation
import Testing

@testable import PackTraceCore

@Suite("바인더 집계")
struct BinderTests {
    @Test("미보유 카드도 목록에 남고 수량은 0이다")
    func missingPrintsStayListed() async throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let store = try Fixtures.makeStore(catalog: catalog)
        try await store.grantInitialDemoPoints()

        let entries = try await store.binderEntries(setID: catalog.set.externalSetID)
        let expectedPrints = catalog.cards.count + catalog.cards.filter { $0.variants.contains(.reverse) }.count
        #expect(entries.count == expectedPrints)
        #expect(entries.allSatisfy { $0.quantity == 0 })
        #expect(entries.filter { $0.quantity == 0 }.count == expectedPrints)

        let progress = try await store.binderProgress(setID: catalog.set.externalSetID)
        #expect(progress.ownedUniquePrints == 0)
        #expect(progress.totalPrints == expectedPrints)
        #expect(progress.totalCopies == 0)
    }

    @Test("개봉하면 수량·고유 프린트·누적 장수가 소유 기록과 일치한다")
    func binderMatchesOwnedInstances() async throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let store = try Fixtures.makeStore(catalog: catalog)
        try await store.grantInitialDemoPoints()
        let pack = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 2024).packInstance
        let opening = try await store.openPack(instanceID: pack.id, seed: 99)

        let owned = try await store.ownedCardInstances()
        let entries = try await store.binderEntries(setID: catalog.set.externalSetID)
        let progress = try await store.binderProgress(setID: catalog.set.externalSetID)

        let distinctPrints = Set(opening.cards.map { "\($0.cardKey.rawValue)#\($0.variant.rawValue)" })
        #expect(owned.count == 10)
        #expect(progress.totalCopies == owned.count)
        #expect(progress.ownedUniquePrints == distinctPrints.count)
        #expect(entries.reduce(0) { $0 + $1.quantity } == owned.count)
        #expect(entries.filter { $0.quantity > 0 }.count == distinctPrints.count)

        for entry in entries where entry.quantity > 0 {
            let key = "\(entry.card.key.rawValue)#\(entry.variant.rawValue)"
            #expect(distinctPrints.contains(key))
            // Same instant as the opening; compared with a tolerance because
            // epoch <-> reference-date conversion is not bit-exact.
            #expect(abs(entry.firstAcquiredAt.timeIntervalSince(opening.createdAt)) < 0.001)
        }

        // 홀로 전용 카드는 홀로 한 줄, 리버스 가능 카드는 노멀/리버스 두 줄이다.
        for entry in entries {
            let hasReverseRow = entry.variant == .reverse
            #expect(entry.card.variants.contains(entry.variant) || !entry.card.variants.isEmpty)
            if hasReverseRow {
                #expect(entry.card.variants.contains(.reverse))
            }
        }
    }

    @Test("같은 카드가 여러 장이면 수량으로 합쳐진다")
    func duplicateCopiesAggregate() async throws {
        var catalog = Fixtures.syntheticCatalog()
        catalog.cards = [catalog.cards.first { $0.rarity == CardRarity(rawValue: "Common") }!]
        catalog.recipes[0].slots = [
            RecipeSlot(
                count: catalog.recipes[0].packSize,
                selector: PoolSelector(rarities: [CardRarity(rawValue: "Common")]),
                variantRule: .primary
            )
        ]
        catalog.contentHash = CatalogLoader.contentHash(for: catalog)

        let store = try Fixtures.makeStore(catalog: catalog)
        try await store.grantInitialDemoPoints()
        let pack = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 1).packInstance
        _ = try await store.openPack(instanceID: pack.id, seed: 1)

        let entries = try await store.binderEntries(setID: catalog.set.externalSetID)
        let normalRow = try #require(entries.first { $0.variant == .normal })
        let reverseRow = try #require(entries.first { $0.variant == .reverse })
        #expect(normalRow.quantity == catalog.recipes[0].packSize)
        #expect(reverseRow.quantity == 0)
        #expect(entries.reduce(0) { $0 + $1.quantity } == catalog.recipes[0].packSize)

        let progress = try await store.binderProgress(setID: catalog.set.externalSetID)
        #expect(progress.ownedUniquePrints == 1)
        #expect(progress.totalCopies == catalog.recipes[0].packSize)
    }

    @Test("첫 획득 카드만 새 카드로 표시된다")
    func firstTimePrintsOnlyFlagsNewCopies() async throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let store = try Fixtures.makeStore(catalog: catalog)
        try await store.grantInitialDemoPoints()

        let first = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 11).packInstance
        let firstOpening = try await store.openPack(instanceID: first.id, seed: 11)
        let firstNew = try await store.firstTimePrints(openingID: firstOpening.id)
        #expect(firstNew.count == Set(firstOpening.cards.map { "\($0.cardKey.rawValue)#\($0.variant.rawValue)" }).count)

        let second = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 12).packInstance
        let secondOpening = try await store.openPack(instanceID: second.id, seed: 12)
        let secondNew = try await store.firstTimePrints(openingID: secondOpening.id)

        let earlierPrints = Set(firstOpening.cards.map { "\($0.cardKey.rawValue)#\($0.variant.rawValue)" })
        for key in secondNew {
            #expect(!earlierPrints.contains(key), "이미 보유한 프린트가 새 카드로 표시되었습니다")
        }
        #expect(secondNew.count <= secondOpening.cards.count)
    }

    @Test("모든 세트 진행률을 한 번에 구해도 세트별로 구한 값과 같다")
    func progressBySetMatchesPerSet() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let store = try Fixtures.makeStore(library: library)
        try await store.grantInitialDemoPoints()
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        var opened = 0
        for seed in UInt64(1)...4 {
            let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: seed * 17).packInstance
            opened += try await store.openPack(instanceID: pack.id, seed: seed).cards.count
        }
        let all = try await store.binderProgressBySet()
        #expect(Set(all.keys) == Set(library.setIDs))
        #expect(all.values.reduce(0) { $0 + $1.totalCopies } == opened)
        for setID in library.setIDs {
            let one = try await store.binderProgress(setID: setID)
            #expect(all[setID] == one, "\(setID)")
        }
    }

    @Test("카드 검색은 모든 세트에서 이름·세트·번호로 찾고, 보유 수를 함께 보여 준다")
    func searchAcrossSets() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let store = try Fixtures.makeStore(library: library)
        try await store.grantInitialDemoPoints()

        let pikachu = try await store.searchBinder(query: "pikachu")
        #expect(pikachu.total > 0)
        // By card name, or by set name (every Detective Pikachu card).
        #expect(pikachu.entries.allSatisfy {
            $0.card.name.lowercased().contains("pikachu")
                || (library.setInfo(for: $0.card.setID)?.name.lowercased().contains("pikachu") ?? false)
        })
        #expect(pikachu.entries.contains { $0.card.setID != "det1" && $0.card.name.contains("Pikachu") })
        #expect(Set(pikachu.entries.map(\.card.setID)).count > 5, "여러 세트에서 찾아야 합니다")

        // Accents and case do not matter.
        let folded = try await store.searchBinder(query: "POKEMON")
        #expect(folded.entries.contains { $0.card.name.contains("Pokémon") })

        // A set id and a number narrow it to one card.
        let exact = try await store.searchBinder(query: "sv01 025")
        #expect(!exact.entries.isEmpty)
        #expect(exact.entries.allSatisfy { $0.card.setID == "sv01" && $0.card.localID == "025" })

        // The limit caps the rows, not the count.
        let many = try await store.searchBinder(query: "e", limit: 50)
        #expect(many.entries.count == 50 && many.total > 50)
        #expect(try await store.searchBinder(query: "   ").total == 0)

        // Owned prints show their quantity.
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 3).packInstance
        let opening = try await store.openPack(instanceID: pack.id, seed: 3)
        let drawn = try #require(opening.cards.first)
        let card = try #require(library.card(for: drawn.cardKey))
        let found = try await store.searchBinder(query: "\(card.setID) \(card.localID) \(card.name)")
        let row = try #require(found.entries.first { $0.card.key == card.key && $0.variant == drawn.variant })
        #expect(row.quantity == opening.cards.filter { $0.cardKey == card.key && $0.variant == drawn.variant }.count)
    }
}
