import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

/// End-to-end flow on a temporary database: synthetic usage pays for one pack
/// of every candidate product, each from a different set, one review is
/// interrupted, and everything must survive reopening the store.
@Suite("후보 팩 전체 흐름 (임시 DB)")
struct PackFlowIntegrationTests {
    private func bundledPool() throws -> ResolvedPackPool {
        try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: try CatalogLoader.bundledLibrary())
    }

    private func seedSelecting(_ packID: String, pool: ResolvedPackPool) -> UInt64? {
        for seed in 0..<UInt64(50_000) where (try? pool.pick(seed: seed).product.packID) == packID {
            return seed
        }
        return nil
    }

    @Test("usage로 후보마다 한 팩씩 → 개봉 → 재개방까지 유지된다")
    func everyCandidateFromUsageToReopen() async throws {
        let pool = try bundledPool()
        let packCount = pool.candidates.count
        let points = packCount * pool.pricePoints
        #expect(packCount == CatalogTests.allEraSets)

        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // 1,000,000 accepted tokens = 100 P per call, through the real reward
        // path: one call per pack.
        let now = Int(Date().timeIntervalSince1970 * 1000)
        for call in 1...packCount {
            try harness.tree.append(
                OMPFixture.assistant(
                    responseID: OMPFixture.responseID(call),
                    input: 1_000_000,
                    output: 0,
                    occurredAt: now + call * 10,
                    completedAt: now + call * 10 + 5
                ) + "\n",
                to: path
            )
        }
        _ = try await harness.drain()
        let earned = try await harness.store.usageTotals()
        #expect(earned.acceptedTokens == packCount * 1_000_000)
        #expect(earned.awardedPoints == points)
        #expect(try await harness.store.balance() == points)

        let store = harness.store

        // One pack per product, each chosen by an injected deterministic seed.
        var packs: [PackInstanceRecord] = []
        var requestIDs: [ExchangeRequestID] = []
        for candidate in pool.candidates {
            let seed = try #require(seedSelecting(candidate.product.packID, pool: pool))
            let requestID = ExchangeRequestID()
            requestIDs.append(requestID)
            let pack = try await store.exchangePack(pool: pool, requestID: requestID, seed: seed).packInstance
            #expect(pack.productID == candidate.product.packID)
            packs.append(pack)
        }
        #expect(Set(packs.map(\.productID)).count == packCount, "후보마다 서로 다른 팩을 받아야 합니다")
        #expect(try await store.balance() == 0)

        // Open them all; the third is interrupted after two cards.
        var openings: [OpeningRecord] = []
        for (index, pack) in packs.enumerated() {
            let opening = try await store.openPack(instanceID: pack.id, seed: UInt64(index) + 1)
            openings.append(opening)
            let revealed = index == 2 ? 2 : opening.cards.count
            _ = try await store.setRevealedCount(openingID: opening.id, count: revealed)
        }
        #expect(try await store.balance() == 0, "개봉은 포인트를 쓰지 않습니다")

        // Every card landed in its own pack's sets, and each pack is its
        // recipe's size (2 for POP … 11 for Wizards-era sets).
        let library = try CatalogLoader.bundledLibrary()
        for (index, opening) in openings.enumerated() {
            let recipe = try #require(pool.candidate(for: packs[index].productID)?.recipe)
            #expect(opening.cards.count == recipe.packSize)
            for drawn in opening.cards {
                let card = try #require(library.card(for: drawn.cardKey))
                #expect(recipe.setIDs.contains(card.setID))
            }
        }
        let openedCards = openings.reduce(0) { $0 + $1.cards.count }

        // Reopen the same directory.
        let reopened = try PackTraceStore(location: harness.location, library: try CatalogLoader.bundledLibrary())
        #expect(try await reopened.balance() == 0)
        #expect(try await reopened.packInstances().count == packCount)
        #expect(try await reopened.ownedCardInstances().count == openedCards)
        let unfinished = try await reopened.unfinishedOpenings()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.revealedCount == 2)
        #expect(unfinished.first?.cards == openings[2].cards)

        // Retrying the same requests pays nothing and returns the same packs.
        for (index, requestID) in requestIDs.enumerated() {
            let again = try await reopened.exchangePack(
                pool: pool,
                requestID: requestID,
                seed: seedSelecting(pool.candidates[index].product.packID, pool: pool) ?? 1
            )
            #expect(again.packInstance.id == packs[index].id)
            #expect(again.reusedExistingRequest)
        }
        #expect(try await reopened.packInstances().count == packCount)
        #expect(try await reopened.balance() == 0)

        // Rescanning usage adds nothing.
        let collector = OMPUsageCollector(store: reopened, limits: .standard)
        _ = try await collector.scan(trigger: .manual)
        let totals = try await reopened.usageTotals()
        #expect(totals.awardedPoints == points)
        #expect(try await reopened.balance() == 0)

        // Per-set binder counts add up to the opened cards, and stay separate.
        for candidate in pool.candidates {
            let entries = try await reopened.binderEntries(setID: candidate.product.setID)
            let opened = openings.filter { $0.packInstanceID != packs[2].id || true }
                .flatMap(\.cards)
                .filter { $0.cardKey.setID == candidate.product.setID }
            let ownedInSet = try await reopened.ownedCardInstances().filter { $0.setID == candidate.product.setID }
            #expect(entries.reduce(0) { $0 + $1.quantity } == ownedInSet.count)
            #expect(ownedInSet.count == opened.count)
        }
        let totalOwned = try await reopened.ownedCardInstances().count
        #expect(totalOwned == openedCards)
    }

    @Test("다른 세트의 같은 번호 카드는 합쳐지지 않는다")
    func sameNumberDifferentSetsStaySeparate() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()
        let pool = try bundledPool()

        // Collect a real card from each set (sv01 and sv02 both have 001).
        var keys: [String: CardKey] = [:]
        for setID in ["sv01", "sv02"] {
            let card = try #require(library.cards(inSet: setID).first { $0.localID == "001" })
            keys[setID] = card.key
        }
        #expect(keys["sv01"] != keys["sv02"])
        #expect(keys["sv01"]?.rawValue.contains(":sv01:") == true)
        #expect(keys["sv02"]?.rawValue.contains(":sv02:") == true)

        // Catalogues are per set: a binder row only ever comes from its own set.
        for setID in ["sv01", "sv02", "sv03"] {
            let entries = try await store.binderEntries(setID: setID)
            #expect(entries.allSatisfy { $0.card.setID == setID })
            #expect(!entries.isEmpty)
        }
        _ = pool
    }

    @Test("이미지 로딩 실패는 카드 결과나 확률을 바꾸지 않는다")
    func imageFailureDoesNotChangeResults() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let store = try Fixtures.makeStore(library: library, realm: .demo)
        try await store.grantInitialDemoPoints()
        let pool = try bundledPool()

        let seed = try #require(seedSelecting("tpcgi-en-sv01-booster", pool: pool))
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: seed).packInstance
        let opening = try await store.openPack(instanceID: pack.id, seed: seed)

        // An unreachable image source: every fetch fails, and the cache reports it.
        let location = try StoreLocation.temporary(label: "packtrace-image-failure")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let cache = ImageCache(
            directory: location.imageDirectory,
            session: URLSession(configuration: .ephemeral)
        )
        let card = try #require(library.card(for: opening.cards[0].cardKey))
        let url = CardImageURL.url(for: card, quality: .thumbnail)
        let remote = url.replacingOccurrences(of: "https://", with: "https://127.0.0.1:9/")
        let data = await cache.data(for: remote, quality: .thumbnail)
        #expect(data == nil, "연결할 수 없는 주소는 실패로 남습니다")
        #expect(await cache.isKnownFailure(remote, quality: .thumbnail))

        // The draw is untouched: same cards, same quantities.
        let after = try #require(try await store.opening(id: opening.id))
        #expect(after.cards == opening.cards)
        #expect(try await store.ownedCardInstances().count == 10)

        // Once the asset is cached, the same URL resolves without the network.
        let cachedKey = ImageCache.cacheKey(urlString: remote, quality: .thumbnail)
        try FileManager.default.createDirectory(at: location.imageDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 64).write(to: location.imageDirectory.appendingPathComponent(cachedKey))
        let retried = await cache.data(for: remote, quality: .thumbnail)
        #expect(retried?.count == 64, "캐시가 채워지면 다시 시도에서 성공합니다")
    }
}
