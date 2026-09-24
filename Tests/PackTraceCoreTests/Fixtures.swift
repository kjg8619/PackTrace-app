import Foundation
@testable import PackTraceCore

/// Synthetic catalogues and stores for tests. These are fixtures: they never
/// represent a real product, and they live in a temporary directory.
enum Fixtures {
    static let syntheticRarities: [String: (count: Int, variants: [CardVariant])] = [
        "Common": (6, [.normal, .reverse]),
        "Uncommon": (4, [.normal, .reverse]),
        "Rare": (2, [.holo, .reverse]),
        "Double rare": (1, [.holo]),
        "Illustration rare": (1, [.holo]),
        "Hyper rare": (1, [.holo]),
    ]

    /// Mirror of the reviewed sv01 slot layout, scaled down to a 6-card pack so
    /// tests stay fast while still exercising every slot rule.
    static func syntheticRecipe(
        recipeID: String = "synth-booster-sim-v1",
        version: Int = 1,
        packSize: Int = 6
    ) -> PackRecipe {
        PackRecipe(
            recipeID: recipeID,
            version: version,
            setID: "synth",
            packSize: packSize,
            duplicatesAllowed: true,
            slots: [
                RecipeSlot(
                    count: 2,
                    selector: PoolSelector(rarities: [CardRarity(rawValue: "Common")]),
                    variantRule: .primary
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(rarities: [CardRarity(rawValue: "Uncommon")]),
                    variantRule: .primary
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(
                        rarities: [
                            CardRarity(rawValue: "Common"),
                            CardRarity(rawValue: "Uncommon"),
                            CardRarity(rawValue: "Rare"),
                        ],
                        requiresVariant: .reverse
                    ),
                    variantRule: .reverse
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(rarities: [
                        CardRarity(rawValue: "Common"),
                        CardRarity(rawValue: "Uncommon"),
                        CardRarity(rawValue: "Rare"),
                        CardRarity(rawValue: "Illustration rare"),
                        CardRarity(rawValue: "Hyper rare"),
                    ]),
                    variantRule: .reverseIfAvailableElsePrimary
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(rarities: [
                        CardRarity(rawValue: "Rare"),
                        CardRarity(rawValue: "Double rare"),
                    ]),
                    variantRule: .primary
                ),
            ],
            disclaimer: "fixture recipe, not a real product",
            evidence: []
        )
    }

    /// Same recipe id, version 2, four cards: stands in for a catalogue update
    /// that must not change how an already-owned pack opens.
    static func syntheticRecipeV2() -> PackRecipe {
        PackRecipe(
            recipeID: "synth-booster-sim-v1",
            version: 2,
            setID: "synth",
            packSize: 4,
            duplicatesAllowed: true,
            slots: [
                RecipeSlot(
                    count: 2,
                    selector: PoolSelector(rarities: [CardRarity(rawValue: "Common")]),
                    variantRule: .primary
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(rarities: [CardRarity(rawValue: "Uncommon")]),
                    variantRule: .primary
                ),
                RecipeSlot(
                    count: 1,
                    selector: PoolSelector(rarities: [
                        CardRarity(rawValue: "Rare"),
                        CardRarity(rawValue: "Double rare"),
                    ]),
                    variantRule: .primary
                ),
            ],
            disclaimer: "fixture recipe v2, not a real product",
            evidence: []
        )
    }

    static func syntheticCatalog(
        productCount: Int = 1,
        catalogVersion: String = "synthetic-v1",
        statuses: [VerificationStatus]? = nil,
        includeRecipe: Bool = true,
        recipe: PackRecipe? = nil
    ) -> PackCatalog {
        var cards: [CardDefinition] = []
        var localID = 1
        for (rarity, spec) in syntheticRarities.sorted(by: { $0.key < $1.key }) {
            for index in 1...spec.count {
                let local = String(format: "%03d", localID)
                cards.append(
                    CardDefinition(
                        key: CardKey(source: "fixture", language: "en", setID: "synth", localID: local),
                        source: "fixture",
                        language: "en",
                        setID: "synth",
                        localID: local,
                        name: "\(rarity) card \(index) #\(localID)",
                        rarity: CardRarity(rawValue: rarity),
                        category: .pokemon,
                        variants: spec.variants,
                        imageBaseURL: "https://example.invalid/synth/\(local)"
                    )
                )
                localID += 1
            }
        }

        let recipe = recipe ?? syntheticRecipe()
        let statusList = statuses ?? Array(repeating: .readyForReward, count: max(productCount, 1))
        var products: [PackProduct] = []
        for index in 0..<max(productCount, 1) {
            let status = index < statusList.count ? statusList[index] : .readyForReward
            products.append(
                PackProduct(
                    packID: "synthetic-pack-\(index + 1)",
                    name: "합성 팩 \(index + 1)",
                    region: "fixture",
                    language: "en",
                    setID: "synth",
                    recipeID: recipe.recipeID,
                    artworkSubstitute: ArtworkSubstitute(note: "fixture artwork", logoURL: nil, symbolURL: nil),
                    verification: ProductVerification(status: status, evidence: [], unverified: [])
                )
            )
        }

        var catalog = PackCatalog(
            catalogVersion: catalogVersion,
            generatedAt: "2026-09-22T00:00:00Z",
            sourceName: "fixture",
            sourceURL: "https://example.invalid",
            sourceEndpoint: "/sets/synth",
            fetchedAt: "2026-09-22T00:00:00Z",
            contentHash: "",
            set: CardSetInfo(
                source: "fixture",
                language: "en",
                externalSetID: "synth",
                name: "Synthetic Set",
                releaseDate: "2026-01-01",
                officialCardCount: cards.count,
                totalCardCount: cards.count,
                logoURL: nil,
                symbolURL: nil
            ),
            products: products,
            recipes: includeRecipe ? [recipe] : [],
            cards: cards
        )
        catalog.contentHash = CatalogLoader.contentHash(for: catalog)
        return catalog
    }

    /// A resolved pool over the given catalogues, all candidates weight 1.
    static func pool(
        for catalogs: [PackCatalog],
        poolVersion: String = "test-pool",
        price: Int = 100
    ) throws -> ResolvedPackPool {
        let library = try CatalogLibrary(catalogs: catalogs)
        let pool = PackPool(
            poolVersion: poolVersion,
            pricePoints: price,
            economyVersion: 1,
            note: "fixture pool",
            candidates: catalogs.flatMap { catalog in
                catalog.products.map {
                    PackPoolCandidate(packID: $0.packID, catalogVersion: catalog.catalogVersion, weight: 1)
                }
            }
        )
        return try ResolvedPackPool.resolve(pool: pool, library: library)
    }

    /// Store in a fresh temporary directory. Tests must never touch a real
    /// collection, so every store in this suite is built from this helper.
    static func makeStore(
        catalog: PackCatalog? = nil,
        library: CatalogLibrary? = nil,
        realm: Realm = .demo,
        economy: PackEconomy = .v1,
        location: StoreLocation? = nil
    ) throws -> PackTraceStore {
        let resolvedLibrary = try library ?? CatalogLibrary(catalogs: [catalog ?? CatalogLoader.loadBundled()])
        let resolvedLocation = try location ?? StoreLocation.temporary(realm: realm)
        return try PackTraceStore(location: resolvedLocation, library: resolvedLibrary, economy: economy)
    }

    static func temporaryLocation(realm: Realm = .demo) throws -> StoreLocation {
        let location = try StoreLocation.temporary(realm: realm)
        try location.prepareDirectories()
        return location
    }
}
