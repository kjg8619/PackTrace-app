import Foundation
import Testing

@testable import PackTraceCore

/// Building a catalogue from source data with a subset set in the same pack
/// and prints the boosters never held. Synthetic source data only.
@Suite("카탈로그 서브세트·제외 카드")
struct CatalogSubsetTests {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private static func set(_ id: String, cards: [String]) throws -> TCGdexSchema.SetResponse {
        let briefs = cards.map { #"{"id":"\#(id)-\#($0)","localId":"\#($0)","name":"Card \#($0)"}"# }.joined(separator: ",")
        return try decode(
            TCGdexSchema.SetResponse.self,
            #"{"id":"\#(id)","name":"Set \#(id)","releaseDate":"2000-01-01","cardCount":{"official":\#(cards.count),"total":\#(cards.count)},"cards":[\#(briefs)]}"#
        )
    }

    private static func card(_ set: String, _ local: String, rarity: String, normal: Bool = true, holo: Bool = false, reverse: Bool = false) throws -> TCGdexSchema.CardResponse {
        try decode(
            TCGdexSchema.CardResponse.self,
            #"{"id":"\#(set)-\#(local)","localId":"\#(local)","name":"Card \#(local)","category":"Pokemon","rarity":"\#(rarity)","image":"https://assets.example/\#(set)/\#(local)","variants":{"normal":\#(normal),"holo":\#(holo),"reverse":\#(reverse)}}"#
        )
    }

    private static func source(extra: [String]? = nil, excludedCards: [String]? = nil, excludedPrints: [String]? = nil) throws -> ProductSourceFile {
        func list(_ values: [String]?) -> String {
            values.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        }
        return try decode(
            ProductSourceFile.self,
            #"""
            {"catalogVersionPrefix":"test","fetch":{"sourceName":"TCGdex","sourceURL":"https://api.example","language":"en","setID":"main",
              "extraSetIDs":\#(list(extra)),"excludedCardIDs":\#(list(excludedCards)),"excludedPrints":\#(list(excludedPrints))},
             "recipes":[{"recipeID":"main-sim","version":1,"packSize":3,"duplicatesAllowed":true,"disclaimer":"test","slots":[
               {"count":1,"rarities":["Common"],"variantRule":"primary"},
               {"count":1,"rarities":["Rare"],"variantRule":"primary"},
               {"count":1,"rarities":["Rare","Holo Rare"],"variantRule":"primary","setIDs":["main","gallery"]}]}],
             "products":[{"packID":"test-main-booster","name":"Test","region":"US","language":"en","recipeID":"main-sim","artwork":{"note":"n"},
               "verification":{"status":"ready-for-reward","evidence":[],"unverified":[]}}]}
            """#
        )
    }

    private static func parts() throws -> (TCGdexSchema.SetResponse, [TCGdexSchema.CardResponse], TCGdexSchema.SetResponse, [TCGdexSchema.CardResponse]) {
        let main = try set("main", cards: ["1", "2", "3", "4"])
        let mainCards = [
            try card("main", "1", rarity: "Common", reverse: true),
            try card("main", "2", rarity: "Rare", normal: true, holo: true),
            try card("main", "3", rarity: "Rare"),
            try card("main", "4", rarity: "Common"),
        ]
        let gallery = try set("gallery", cards: ["GG01", "GG02"])
        let galleryCards = [
            try card("gallery", "GG01", rarity: "Holo Rare", normal: false, holo: true),
            try card("gallery", "GG02", rarity: "Holo Rare", normal: false, holo: true),
        ]
        return (main, mainCards, gallery, galleryCards)
    }

    @Test("서브세트 카드는 자기 세트 ID를 지키고, 그 세트를 적은 칸에서만 나온다")
    func subsetSlots() throws {
        let (main, mainCards, gallery, galleryCards) = try Self.parts()
        let catalog = try CatalogBuilder.build(
            productSource: try Self.source(extra: ["gallery"]),
            set: main, cards: mainCards, extraSets: [(gallery, galleryCards)],
            fetchedAt: Date(timeIntervalSince1970: 0), catalogVersion: "test-1"
        )
        #expect(catalog.cards.count == 6)
        #expect(catalog.cards.map(\.setID) == ["main", "main", "main", "main", "gallery", "gallery"], "본 세트가 먼저")
        #expect(catalog.subsets?.map(\.externalSetID) == ["gallery"])
        let recipe = try #require(catalog.recipes.first)
        #expect(recipe.setIDs == ["main", "gallery"])
        #expect(recipe.pool(for: recipe.slots[1], in: catalog).allSatisfy { $0.setID == "main" }, "세트를 적지 않은 칸은 본 세트만")
        let hit = recipe.pool(for: recipe.slots[2], in: catalog)
        #expect(Set(hit.map(\.setID)) == ["main", "gallery"])
        #expect(hit.map(\.localID) == ["GG01", "GG02", "2", "3"], "세트, 번호 순으로 정렬")

        // The subset's metadata is found through the library as well.
        let library = try CatalogLibrary(catalogs: [catalog])
        #expect(library.setInfo(for: "gallery")?.name == "Set gallery")
        #expect(library.setIDs.contains("gallery"))

        // Screens list the subset right after its set.
        #expect(library.parentSetID(of: "gallery") == "main")
        #expect(library.seriesGroups(pool: nil).map(\.setIDs) == [["main", "gallery"]])

        // Hash round-trips with the subset list included.
        #expect(CatalogLoader.contentHash(for: catalog) == catalog.contentHash)
    }

    @Test("받아 온 서브세트가 선언과 다르면 만들지 않는다")
    func subsetMismatch() throws {
        let (main, mainCards, gallery, galleryCards) = try Self.parts()
        #expect(throws: PackTraceError.self) {
            _ = try CatalogBuilder.build(productSource: try Self.source(), set: main, cards: mainCards,
                                         extraSets: [(gallery, galleryCards)], fetchedAt: Date(), catalogVersion: "t")
        }
        #expect(throws: PackTraceError.self) {
            _ = try CatalogBuilder.build(productSource: try Self.source(extra: ["gallery"]), set: main, cards: mainCards,
                                         fetchedAt: Date(), catalogVersion: "t")
        }
    }

    @Test("부스터에 없던 카드와 인쇄는 빠지고, 틀린 제외 목록은 거절된다")
    func exclusions() throws {
        let (main, mainCards, _, _) = try Self.parts()
        let catalog = try CatalogBuilder.build(
            productSource: try Self.source(excludedCards: ["main-4"], excludedPrints: ["main-1:reverse"]),
            set: main, cards: mainCards, fetchedAt: Date(), catalogVersion: "t"
        )
        #expect(catalog.cards.map(\.localID) == ["1", "2", "3"])
        let first = try #require(catalog.cards.first)
        #expect(first.variants == [.normal])
        #expect(first.supportedVariants == [.normal], "리버스는 모을 대상에서도 빠진다")

        for bad in [
            try Self.source(excludedCards: ["main-99"]),
            try Self.source(excludedPrints: ["main-9:normal"]),
            try Self.source(excludedPrints: ["main-3:reverse"]),
            try Self.source(excludedPrints: ["main-3"]),
            try Self.source(excludedPrints: ["main-3:normal"]),
        ] {
            #expect(throws: PackTraceError.self) {
                _ = try CatalogBuilder.build(productSource: bad, set: main, cards: mainCards, fetchedAt: Date(), catalogVersion: "t")
            }
        }
    }

    private static func placeholderCard(_ set: String, _ local: String, rarity: String, priceKeys: [String]?) throws -> TCGdexSchema.CardResponse {
        let pricing = priceKeys.map { keys in
            let entries = (["\"updated\":\"2026-01-01\""] + keys.map { "\"\($0)\":{\"marketPrice\":1}" }).joined(separator: ",")
            return ",\"pricing\":{\"tcgplayer\":{\(entries)}}"
        } ?? ""
        return try decode(
            TCGdexSchema.CardResponse.self,
            #"{"id":"\#(set)-\#(local)","localId":"\#(local)","name":"Card \#(local)","category":"Pokemon","rarity":"\#(rarity)","image":"https://assets.example/\#(set)/\#(local)","variants":{"normal":true,"holo":false,"reverse":false},"variants_detailed":[{"type":"normal","size":"standard","variantId":"generated"}]\#(pricing)}"#
        )
    }

    private static func pricedSource(flag: Bool, placeholder: String? = nil) throws -> ProductSourceFile {
        try decode(
            ProductSourceFile.self,
            #"""
            {"catalogVersionPrefix":"test","fetch":{"sourceName":"TCGdex","sourceURL":"https://api.example","language":"en","setID":"main",
              "pricingForPlaceholderVariants":\#(flag),"placeholderPrints":\#(placeholder.map { #"{"main":"\#($0)"}"# } ?? "null")},
             "recipes":[{"recipeID":"main-sim","version":1,"packSize":3,"duplicatesAllowed":true,"disclaimer":"test","slots":[
               {"count":1,"rarities":["Common"],"variantRule":"primary"},
               {"count":1,"rarities":["Rare","Ultra Rare"],"variantRule":"primary"},
               {"count":1,"rarities":[],"anyRarityWithVariant":"reverse","variantRule":"reverse"}]}],
             "products":[{"packID":"test-main-booster","name":"Test","region":"US","language":"en","recipeID":"main-sim","artwork":{"note":"n"},
               "verification":{"status":"ready-for-reward","evidence":[],"unverified":[]}}]}
            """#
        )
    }

    @Test("원본 변형이 자리표시값이면 TCGplayer 가격 키로 인쇄를 정하고, 그 근거를 카드에 남긴다")
    func placeholderVariantsFromPriceKeys() throws {
        let main = try Self.set("main", cards: ["1", "2", "3", "4", "5"])
        let cards = [
            try Self.placeholderCard("main", "1", rarity: "Common", priceKeys: ["normal", "reverse-holofoil"]),
            try Self.placeholderCard("main", "2", rarity: "Rare", priceKeys: ["holofoil", "reverse-holofoil"]),
            try Self.placeholderCard("main", "3", rarity: "Ultra Rare", priceKeys: ["holofoil"]),
            try Self.placeholderCard("main", "4", rarity: "Ultra Rare", priceKeys: nil),
        ]
        var source = try Self.pricedSource(flag: true, placeholder: "holo")
        source.fetch.placeholderPrints?["main:Common"] = .normal
        let catalog = try CatalogBuilder.build(productSource: source, set: main, cards: cards + [
            try Self.placeholderCard("main", "5", rarity: "Common", priceKeys: nil),
        ], fetchedAt: Date(), catalogVersion: "t")
        let byID = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.localID, $0) })
        #expect(byID["1"]?.variants == [.normal, .reverse] && byID["1"]?.printEvidence == "tcgplayer-pricing")
        #expect(byID["2"]?.variants == [.holo, .reverse] && byID["2"]?.primaryVariant == .holo)
        #expect(byID["3"]?.variants == [.holo])
        #expect(byID["4"]?.variants == [.holo] && byID["4"]?.printEvidence == "research", "가격 키도 없으면 조사로 정한 인쇄")
        #expect(byID["5"]?.variants == [.normal] && byID["5"]?.printEvidence == "research", "세트:등급 키가 세트 키보다 먼저")

        // The reverse slot takes every reverse print, whatever the rarity.
        let recipe = try #require(catalog.recipes.first)
        #expect(recipe.pool(for: recipe.slots[2], in: catalog).map(\.localID) == ["1", "2"])

        #expect(CatalogLoader.contentHash(for: catalog) == catalog.contentHash)

        // Without the flag the source's own placeholder list (normal only)
        // stands, so there is no reverse print and the build refuses the
        // empty reverse slot instead of inventing one.
        #expect(throws: PackTraceError.self) {
            _ = try CatalogBuilder.build(productSource: try Self.pricedSource(flag: false), set: main, cards: cards,
                                         fetchedAt: Date(), catalogVersion: "t")
        }
    }

    @Test("서브세트 전체를 한 칸에 태우면 본 세트의 같은 등급 카드는 따라오지 않는다")
    func wholeSubsetSlot() throws {
        let (main, mainCards, gallery, _) = try Self.parts()
        // A gallery whose rarity names repeat the main set's.
        let galleryCards = [
            try Self.card("gallery", "GG01", rarity: "Rare", normal: false, holo: true),
            try Self.card("gallery", "GG02", rarity: "Ultra Rare", normal: false, holo: true),
        ]
        var source = try Self.source(extra: ["gallery"])
        source.recipes[0].slots[2] = try Self.decode(
            ProductSourceFile.RecipeSlotSource.self,
            #"{"count":1,"rarities":[],"anyRarityWithVariant":"reverse","wholeSetIDs":["gallery"],"variantRule":"reverseIfAvailableElsePrimary"}"#
        )
        let catalog = try CatalogBuilder.build(productSource: source, set: main, cards: mainCards, extraSets: [(gallery, galleryCards)],
                                               fetchedAt: Date(), catalogVersion: "t")
        let recipe = try #require(catalog.recipes.first)
        let pool = recipe.pool(for: recipe.slots[2], in: catalog)
        #expect(pool.map { "\($0.setID)-\($0.localID)" } == ["gallery-GG01", "gallery-GG02", "main-1"], "리버스 인쇄(main-1) + 갤러리 전체, 본 세트 레어는 아님")
        #expect(recipe.setIDs == ["main", "gallery"])
    }

    @Test("리버스만 있는 카드는 리버스가 기본 인쇄이고, 도장 찍힌 인쇄를 리버스로 읽을 수 있다")
    func reverseOnlyAndStampedReverse() throws {
        let only = CardDefinition(
            key: CardKey(source: "tcgdex", language: "en", setID: "pl1", localID: "SH4"),
            source: "tcgdex", language: "en", setID: "pl1", localID: "SH4", name: "Shiny",
            rarity: CardRarity(rawValue: "Rare"), category: .pokemon, variants: [.reverse], imageBaseURL: "https://assets.example/x"
        )
        #expect(only.primaryVariant == .reverse)
        #expect(only.supportedVariants == [.reverse])

        let main = try Self.set("main", cards: ["1", "2"])
        let stamped = try Self.decode(
            TCGdexSchema.CardResponse.self,
            #"{"id":"main-1","localId":"1","name":"A","category":"Pokemon","rarity":"Common","image":"https://assets.example/main/1","variants":{"normal":true,"reverse":false},"variants_detailed":[{"type":"normal","size":"standard"},{"type":"normal","size":"standard","stamp":["set-logo"]}]}"#
        )
        let jumbo = try Self.decode(
            TCGdexSchema.CardResponse.self,
            #"{"id":"main-2","localId":"2","name":"B","category":"Pokemon","rarity":"Rare","image":"https://assets.example/main/2","variants":{"normal":true,"reverse":false},"variants_detailed":[{"type":"normal","size":"standard"},{"type":"normal","size":"jumbo","stamp":["set-logo"]}]}"#
        )
        var source = try Self.source()
        source.fetch.reverseFromStamp = "set-logo"
        source.recipes[0].slots[2] = try Self.decode(ProductSourceFile.RecipeSlotSource.self, #"{"count":1,"rarities":[],"anyRarityWithVariant":"reverse","variantRule":"reverse"}"#)
        let catalog = try CatalogBuilder.build(productSource: source, set: main, cards: [stamped, jumbo], fetchedAt: Date(), catalogVersion: "t")
        #expect(catalog.cards[0].variants == [.normal, .reverse] && catalog.cards[0].printEvidence == "tcgdex-stamp:set-logo")
        #expect(catalog.cards[1].variants == [.normal] && catalog.cards[1].printEvidence == nil, "점보 인쇄는 부스터 카드가 아닙니다")
    }

    @Test("원본 ID를 URL 경로 한 칸으로 만든다 (물음표·슬래시도 안전하게)")
    func sourceIDsArePathSafe() {
        #expect(CatalogFetcher.pathComponent("exu-?") == "exu-%3F")
        #expect(CatalogFetcher.pathComponent("sv03.5-001") == "sv03.5-001")
        #expect(CatalogFetcher.pathComponent("ecard2-H21") == "ecard2-H21")
        #expect(CatalogFetcher.pathComponent("a/b#c") == "a%2Fb%23c")
    }

    @Test("세트 안 번호로 나뉜 서브세트(RC…)는 번호 앞머리로 칸을 가른다")
    func numberPrefixSlots() throws {
        let main = try Self.set("main", cards: ["1", "2", "RC1", "RC2"])
        let cards = [
            try Self.card("main", "1", rarity: "Common"),
            try Self.card("main", "2", rarity: "Rare"),
            try Self.card("main", "RC1", rarity: "Common"),
            try Self.card("main", "RC2", rarity: "Rare"),
        ]
        var source = try Self.source()
        source.recipes[0].slots = try [
            #"{"count":1,"rarities":["Common"],"variantRule":"primary","excludedLocalIDPrefixes":["RC"]}"#,
            #"{"count":1,"rarities":["Common"],"variantRule":"primary","localIDPrefixes":["RC"]}"#,
            #"{"count":1,"rarities":["Rare"],"variantRule":"primary","localIDPrefixes":["RC"]}"#,
        ].map { try Self.decode(ProductSourceFile.RecipeSlotSource.self, $0) }
        let catalog = try CatalogBuilder.build(productSource: source, set: main, cards: cards, fetchedAt: Date(), catalogVersion: "t")
        let recipe = try #require(catalog.recipes.first)
        #expect(recipe.slots.map { recipe.pool(for: $0, in: catalog).map(\.localID) } == [["1"], ["RC1"], ["RC2"]])
    }
}
