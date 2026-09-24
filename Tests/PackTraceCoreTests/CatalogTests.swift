import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("실제 카탈로그와 레시피")
struct CatalogTests {
    /// Every booster set shipped: SV01–SV10 (packs-v1/v2) and the all-era
    /// expansion (packs-v3). Subsets travel inside their set's catalogue.
    static let allEraSets = 138
    static let subsets: Set<String> = ["30th-c", "cel25cc", "exu", "sma", "swsh4.5sv", "swsh9tg", "swsh10tg", "swsh11tg", "swsh12tg", "swsh12.5gg"]

    @Test("번들 카탈로그는 해시가 맞고 SV01~SV10과 전 시대 부스터 세트를 담고 있다")
    func bundledCatalogIsIntact() throws {
        let urls = CatalogLoader.bundledCatalogURLs()
        #expect(urls.count == Self.allEraSets)
        let library = try CatalogLoader.bundledLibrary()
        let mainSets = Set(library.catalogs.values.map(\.set.externalSetID))
        #expect(mainSets.count == Self.allEraSets, "세트마다 카탈로그 하나")
        #expect(Set(library.setIDs) == mainSets.union(Self.subsets))
        for id in ["sv01", "sv10", "base1", "neo4", "ecard3", "ex16", "dp1", "hgss4", "col1", "bw11", "xy12", "g1", "sm12", "swsh12.5", "me05", "30th"] {
            #expect(mainSets.contains(id), "\(id) 없음")
        }
        // Not booster products: starter decks, prize and promo sets, deck kits.
        for id in ["si1", "sp", "bog", "ex5.5", "ru1", "xy0", "xya", "rc", "mfb"] {
            #expect(!library.setIDs.contains(id), "\(id)는 부스터가 아닙니다")
        }
        for catalog in library.catalogs.values {
            #expect(catalog.products.count == 1)
            #expect(catalog.products.allSatisfy { $0.isRewardEligible && $0.language == "en" })
        }

        // sv01 keeps the exact snapshot and hash it shipped with in M2.
        let sv01 = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        #expect(sv01.catalogVersion.hasPrefix("tcgdex-en-sv01-"))
        #expect(sv01.set.source == "tcgdex")
        #expect(sv01.set.language == "en")
        #expect(sv01.set.externalSetID == "sv01")
        #expect(sv01.set.name == "Scarlet & Violet")
        #expect(sv01.set.releaseDate == "2023-03-31")
        #expect(sv01.cards.count == 258)
        #expect(sv01.set.officialCardCount == 198)
        #expect(sv01.set.totalCardCount == 258)
        #expect(sv01.contentHash.hasPrefix("sha256:"))

        let sv02 = try #require(library.catalog(version: "tcgdex-en-sv02-20260922"))
        #expect(sv02.set.name == "Paldea Evolved")
        #expect(sv02.cards.count == 279)
        let sv03 = try #require(library.catalog(version: "tcgdex-en-sv03-20260922"))
        #expect(sv03.set.name == "Obsidian Flames")
        #expect(sv03.cards.count == 230)

        // SV04–SV10, added with pool packs-v2.
        let added: [(String, String, Int)] = [
            ("tcgdex-en-sv04-20260923", "Paradox Rift", 266),
            ("tcgdex-en-sv05-20260923", "Temporal Forces", 218),
            ("tcgdex-en-sv06-20260923", "Twilight Masquerade", 226),
            ("tcgdex-en-sv07-20260923", "Stellar Crown", 175),
            ("tcgdex-en-sv08-20260923", "Surging Sparks", 252),
            ("tcgdex-en-sv09-20260923", "Journey Together", 190),
            ("tcgdex-en-sv10-20260923", "Destined Rivals", 244),
        ]
        for (version, name, count) in added {
            let catalog = try #require(library.catalog(version: version), "\(version) 없음")
            #expect(catalog.set.name == name)
            #expect(catalog.cards.count == count)
            #expect(catalog.set.language == "en")
            #expect(catalog.products.count == 1)
            #expect(catalog.products.allSatisfy { $0.isRewardEligible })
        }
    }

    @Test("SV05~SV08은 ACE SPEC 레어를 첫 번째 리버스 칸에서만 내고, 다른 SV 본편 슬롯은 기존 구성과 같다")
    func aceSpecSlot() throws {
        let library = try CatalogLoader.bundledLibrary()
        let ace = CardRarity(rawValue: "ACE SPEC Rare")
        let main: Set<String> = ["sv01", "sv02", "sv03", "sv04", "sv05", "sv06", "sv07", "sv08", "sv09", "sv10"]
        for catalog in library.catalogs.values where main.contains(catalog.set.externalSetID) {
            let recipe = try #require(catalog.recipes.first)
            let hasAce = catalog.cards.contains { $0.rarity == ace }
            let aceSlots = recipe.slots.indices.filter { recipe.slots[$0].selector.rarities.contains(ace) }
            if hasAce {
                #expect(["sv05", "sv06", "sv07", "sv08"].contains(catalog.set.externalSetID))
                #expect(aceSlots == [2], "\(catalog.set.externalSetID): ACE SPEC은 첫 번째 리버스 칸에만")
                #expect(recipe.slots[2].variantRule == .reverseIfAvailableElsePrimary)
            } else {
                #expect(aceSlots.isEmpty)
                #expect(recipe.slots[2].selector.requiresVariant == .reverse)
            }
            #expect(recipe.packSize == 10)
            #expect(recipe.slots.map(\.count) == [4, 3, 1, 1, 1])
        }
    }

    @Test("카드 번호는 1..258이 빠짐없이 있고 변형 정보가 실제 값이다")
    func cardNumberingAndVariants() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let localIDs = catalog.cards.map(\.localID)
        #expect(Set(localIDs).count == 258)

        var expected: [String] = []
        for number in 1...258 {
            expected.append(String(format: "%03d", number))
        }
        #expect(localIDs.sorted() == expected)

        for card in catalog.cards {
            #expect(!card.variants.isEmpty, "\(card.localID) 변형 정보 없음")
            #expect(card.variants.contains(.normal) || card.variants.contains(.holo), "\(card.localID) 기본 인쇄 없음")
            #expect(!card.imageBaseURL.isEmpty)
        }
        let reverseEligible = catalog.cards.filter { $0.variants.contains(.reverse) }
        #expect(reverseEligible.count == 186)
        let common = catalog.cards.filter { $0.rarity == CardRarity(rawValue: "Common") }
        let uncommon = catalog.cards.filter { $0.rarity == CardRarity(rawValue: "Uncommon") }
        let rare = catalog.cards.filter { $0.rarity == CardRarity(rawValue: "Rare") }
        #expect(common.count == 105)
        #expect(uncommon.count == 60)
        #expect(rare.count == 21)
        #expect(common.count + uncommon.count + rare.count == 186)
    }

    @Test("레시피 슬롯 구성이 문서화한 실제 팩 구성과 일치한다")
    func recipeSlotsMatchDocumentedStructure() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let recipe = try #require(catalog.recipe(id: "sv01-booster-sim-v1"))

        #expect(recipe.version == 1)
        #expect(recipe.packSize == 10)
        #expect(recipe.slots.map(\.count) == [4, 3, 1, 1, 1])
        #expect(recipe.slots.map(\.variantRule) == [
            .primary,
            .primary,
            .reverse,
            .reverseIfAvailableElsePrimary,
            .primary,
        ])

        let poolSizes = recipe.slots.enumerated().map { index, slot in
            recipe.pool(for: slot, in: catalog).count
        }
        #expect(poolSizes == [105, 60, 186, 226, 53])
        _ = try recipe.slots.enumerated().map { index, _ in index }
    }

    @Test("카탈로그 해시가 맞지 않으면 로드가 실패한다")
    func tamperedCatalogIsRejected() async throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        var tampered = catalog
        tampered.cards[0].name = "조작된 카드"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(tampered)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tampered-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let thrown = await captureError("해시 불일치 카탈로그") {
            try CatalogLoader.load(contentsOf: url)
        }
        guard case .catalogHashMismatch = thrown else {
            Issue.record("catalogHashMismatch를 기대했습니다: \(String(describing: thrown))")
            return
        }
    }

    @Test("추첨은 같은 팩 안에서도 실제 존재하는 카드·변형만 사용한다")
    func drawOnlyUsesRealCardsAndVariants() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let recipe = try #require(catalog.recipe(id: "sv01-booster-sim-v1"))
        let byKey = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.key, $0) })

        for seed in 0..<UInt64(200) {
            let cards = try PackDrawer.draw(recipe: recipe, catalog: catalog, seed: seed)
            #expect(cards.count == 10)
            for drawn in cards {
                let card = try #require(byKey[drawn.cardKey])
                #expect(card.setID == "sv01")
                #expect(card.variants.contains(drawn.variant), "\(card.localID)에 없는 변형 \(drawn.variant)")

                let slot = recipe.slots[drawn.slotIndex]
                #expect(slot.selector.rarities.contains(card.rarity), "슬롯 등급 불일치 \(card.localID)")
                switch slot.variantRule {
                case .primary:
                    #expect(drawn.variant == card.primaryVariant)
                case .reverse:
                    #expect(drawn.variant == .reverse)
                case .reverseIfAvailableElsePrimary:
                    #expect(drawn.variant == (card.variants.contains(.reverse) ? .reverse : card.primaryVariant))
                }
            }
        }
    }

    @Test("같은 시드는 같은 팩을, 다른 시드는 다른 팩을 만든다")
    func drawIsDeterministic() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let recipe = try #require(catalog.recipe(id: "sv01-booster-sim-v1"))

        let first = try PackDrawer.draw(recipe: recipe, catalog: catalog, seed: 12345)
        let repeatDraw = try PackDrawer.draw(recipe: recipe, catalog: catalog, seed: 12345)
        #expect(first == repeatDraw)

        var distinct = Set<String>()
        for seed in 0..<UInt64(20) {
            let cards = try PackDrawer.draw(recipe: recipe, catalog: catalog, seed: seed)
            distinct.insert(cards.map { "\($0.cardKey)#\($0.variant)" }.joined(separator: ","))
        }
        #expect(distinct.count == 20)
    }

    @Test("검증에서 빈 풀·장수 불일치·불가능한 변형을 잡아낸다")
    func validationRejectsBrokenRecipes() async throws {
        let base = Fixtures.syntheticCatalog()

        var wrongSize = base
        wrongSize.recipes[0].packSize = 99
        let sizeError = await captureError("장수 불일치") { try CatalogBuilder.validate(wrongSize) }
        guard case .recipeSizeMismatch? = sizeError else {
            Issue.record("recipeSizeMismatch를 기대했습니다: \(String(describing: sizeError))")
            return
        }

        var emptyPool = base
        emptyPool.recipes[0].slots = [
            RecipeSlot(
                count: emptyPool.recipes[0].packSize,
                selector: PoolSelector(rarities: [CardRarity(rawValue: "Hyper rare")], requiresVariant: .reverse),
                variantRule: .primary
            )
        ]
        let poolError = await captureError("빈 풀") { try CatalogBuilder.validate(emptyPool) }
        guard case .poolEmpty? = poolError else {
            Issue.record("poolEmpty를 기대했습니다: \(String(describing: poolError))")
            return
        }

        var badReverse = base
        badReverse.recipes[0].slots = [
            RecipeSlot(
                count: badReverse.recipes[0].packSize,
                selector: PoolSelector(rarities: [CardRarity(rawValue: "Double rare")]),
                variantRule: .reverse
            )
        ]
        let variantError = await captureError("불가능한 변형") { try CatalogBuilder.validate(badReverse) }
        guard case .variantUnavailable? = variantError else {
            Issue.record("variantUnavailable을 기대했습니다: \(String(describing: variantError))")
            return
        }

        var missingRecipe = base
        missingRecipe.products[0].recipeID = "does-not-exist"
        let productError = await captureError("없는 레시피") { try CatalogBuilder.validate(missingRecipe) }
        guard case .storage? = productError else {
            Issue.record("storage 오류를 기대했습니다: \(String(describing: productError))")
            return
        }
    }

    @Test("출시 상품은 검증 등급·근거·미확인 항목을 함께 남긴다")
    func productCarriesVerificationEvidence() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let product = try #require(catalog.products.first)

        #expect(product.packID == "tpcgi-en-sv01-booster")
        // Primary publisher evidence exists for the pack contents, so this
        // product may be handed out; simulated odds and substitute artwork are
        // still listed as unverified below.
        #expect(product.verification.status == .readyForReward)
        #expect(product.isRewardEligible)
        #expect(product.verification.evidence.contains { $0.kind == "primary" && $0.url.contains("support.pokemoncenter.com") })
        #expect(product.verification.unverified.contains { $0.item.contains("확률") })
        #expect(product.verification.unverified.contains { $0.item.contains("에너지") })
        #expect(product.artworkSubstitute.note.contains("대체"))
        #expect(product.artworkSubstitute.logoURL != nil)
    }

    @Test("레시피의 포일 구성이 공식 안내와 일치한다")
    func recipeFoilStructureMatchesPublisherStatement() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let recipe = try #require(catalog.recipe(id: "sv01-booster-sim-v1"))

        // Publisher (Pokemon Center Support): 10 game cards = 4 commons,
        // 3 uncommons, 3 foils with at least one rare or higher, plus an energy
        // card and a code card. The app models the 10 numbered cards.
        let commons = recipe.slots.filter { $0.selector.rarities == [CardRarity(rawValue: "Common")] }
        let uncommons = recipe.slots.filter { $0.selector.rarities == [CardRarity(rawValue: "Uncommon")] }
        let foilSlots = recipe.slots.filter { $0.variantRule != .primary || $0.selector.rarities.contains { $0.isFoilByDefault } }

        #expect(commons.reduce(0) { $0 + $1.count } == 4)
        #expect(uncommons.reduce(0) { $0 + $1.count } == 3)
        #expect(foilSlots.reduce(0) { $0 + $1.count } == 3)

        let rareOrBetter = recipe.slots.filter { slot in
            slot.selector.rarities.allSatisfy { $0.isFoilByDefault } && slot.variantRule == .primary
        }
        #expect(rareOrBetter.reduce(0) { $0 + $1.count } >= 1, "레어 이상 슬롯이 최소 1장 있어야 합니다")

        // 커먼·언커먼 슬롯은 리버스를 낼 수 없고, 리버스 슬롯은 리버스 전용이다.
        for slot in commons + uncommons {
            #expect(slot.variantRule == .primary)
            #expect(!slot.selector.requiresVariant.isReverse)
        }
    }

    @Test("카드 이미지 URL은 TCGdex 자산 규칙을 따른다")
    func imageURLsFollowAssetRule() throws {
        let catalog = try CatalogLoader.loadBundled(version: "tcgdex-en-sv01-20260922")
        let card = try #require(catalog.cards.first)
        #expect(
            CardImageURL.url(for: card, quality: .thumbnail)
                == "https://assets.tcgdex.net/en/sv/sv01/001/low.webp"
        )
        #expect(
            CardImageURL.url(for: card, quality: .full)
                == "https://assets.tcgdex.net/en/sv/sv01/001/high.webp"
        )
    }

    @Test("모든 세트는 앱이 모으는 프린트를 전부 팩에서 얻을 수 있고, 다른 세트 카드를 섞지 않는다")
    func everyPrintIsReachable() throws {
        let library = try CatalogLoader.bundledLibrary()
        for catalog in library.catalogs.values {
            let recipe = try #require(catalog.recipes.first)
            #expect(recipe.slots.reduce(0) { $0 + $1.count } == recipe.packSize)
            var reachable = Set<String>()
            for slot in recipe.slots {
                let pool = recipe.pool(for: slot, in: catalog)
                #expect(!pool.isEmpty, "\(recipe.recipeID) 빈 칸")
                for card in pool {
                    let variant = try PackDrawer.variant(for: card, rule: slot.variantRule)
                    #expect(card.variants.contains(variant), "\(card.key.rawValue) 원본에 없는 \(variant.rawValue)")
                    reachable.insert("\(card.key.rawValue)#\(variant.rawValue)")
                }
            }
            let targets = catalog.cards.flatMap { card in card.supportedVariants.map { "\(card.key.rawValue)#\($0.rawValue)" } }
            let unreachable = targets.filter { !reachable.contains($0) }
            #expect(unreachable.isEmpty, "\(catalog.set.externalSetID): \(unreachable.prefix(3))")
            #expect(catalog.cards.allSatisfy { recipe.setIDs.contains($0.setID) }, "\(catalog.set.externalSetID): 선언하지 않은 세트 카드")
        }
    }
}

private extension Optional where Wrapped == CardVariant {
    var isReverse: Bool { self == .reverse }
}
