import Foundation

/// Raw TCGdex payloads, reduced to the fields PackTrace stores. Anything the
/// app does not use is dropped at fetch time rather than kept around.
public enum TCGdexSchema {
    public struct SetResponse: Decodable, Sendable {
        public struct CardCount: Decodable, Sendable {
            public var official: Int
            public var total: Int
        }

        public struct Brief: Decodable, Sendable {
            public var id: String
            public var localId: String
            public var name: String
            public var image: String?
        }

        public struct Serie: Decodable, Sendable {
            public var id: String
        }

        public var id: String
        public var name: String
        public var releaseDate: String?
        public var serie: Serie?
        public var cardCount: CardCount
        public var logo: String?
        public var symbol: String?
        public var cards: [Brief]
    }

    public struct CardResponse: Decodable, Sendable {
        public struct Variants: Decodable, Sendable {
            public var normal: Bool?
            public var holo: Bool?
            public var reverse: Bool?
        }

        /// One print as the source details it. `variantId: "generated"` marks
        /// a placeholder the source filled in without data.
        public struct VariantDetail: Decodable, Sendable {
            public var type: String?
            public var size: String?
            public var variantId: String?
            public var stamp: [String]?
        }

        /// Only which TCGplayer price keys exist (`normal`, `holofoil`,
        /// `reverse-holofoil` …): a price is listed only for a print that exists.
        public struct Pricing: Decodable, Sendable {
            public struct KeysOnly: Decodable, Sendable {
                public var keys: [String]

                private struct AnyKey: CodingKey {
                    var stringValue: String
                    var intValue: Int? { nil }
                    init?(stringValue: String) { self.stringValue = stringValue }
                    init?(intValue: Int) { nil }
                }

                public init(keys: [String]) { self.keys = keys }

                public init(from decoder: Decoder) throws {
                    keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue).sorted()
                }
            }

            public var tcgplayer: KeysOnly?
        }

        public var id: String
        public var localId: String
        public var name: String
        public var category: String?
        public var rarity: String?
        public var image: String?
        public var variants: Variants?
        public var variantsDetailed: [VariantDetail]?
        public var pricing: Pricing?

        enum CodingKeys: String, CodingKey {
            case id, localId, name, category, rarity, image, variants, pricing
            case variantsDetailed = "variants_detailed"
        }

        /// The source has no variant data of its own for this card.
        public var hasPlaceholderVariants: Bool {
            guard let details = variantsDetailed, !details.isEmpty else { return false }
            return details.allSatisfy { $0.variantId == "generated" }
        }
    }
}

/// Merges fetched card data with the reviewed product/recipe definitions and
/// checks the result before it is written into the app's resources.
public enum CatalogBuilder {
    public static func build(
        productSource: ProductSourceFile,
        set: TCGdexSchema.SetResponse,
        cards: [TCGdexSchema.CardResponse],
        extraSets: [(set: TCGdexSchema.SetResponse, cards: [TCGdexSchema.CardResponse])] = [],
        fetchedAt: Date,
        catalogVersion: String
    ) throws -> PackCatalog {
        let source = productSource.fetch.sourceName.lowercased()
        let language = productSource.fetch.language
        let setID = productSource.fetch.setID

        guard set.id == setID else {
            throw PackTraceError.storage("source set \(set.id) does not match requested set \(setID)")
        }
        let expectedExtras = productSource.fetch.extraSetIDs ?? []
        guard extraSets.map(\.set.id) == expectedExtras else {
            throw PackTraceError.storage("fetched subsets \(extraSets.map(\.set.id)) do not match \(expectedExtras)")
        }

        var definitions: [CardDefinition] = []
        var seen = Set<CardKey>()
        let excluded = Set(productSource.fetch.excludedCardIDs ?? [])
        var excludedPrints: [String: Set<CardVariant>] = [:]
        for print in productSource.fetch.excludedPrints ?? [] {
            let parts = print.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let variant = CardVariant(rawValue: parts[1]) else {
                throw PackTraceError.storage("excluded print \(print) is not <card id>:<normal|holo|reverse>")
            }
            excludedPrints[parts[0], default: []].insert(variant)
        }
        // Every exclusion must name something the source actually lists, so a
        // typo cannot quietly leave a deck-only card in the binder.
        var unusedExclusions = excluded.union(excludedPrints.keys.map { $0 + ":print" })
        for (part, partCards) in [(set, cards)] + extraSets.map({ ($0.set, $0.cards) }) {
            var partDefinitions: [CardDefinition] = []
            var skipped = 0
            for card in partCards {
                if excluded.contains(card.id) {
                    unusedExclusions.remove(card.id)
                    skipped += 1
                    continue
                }
                var cardVariants = variants(from: card.variants)
                var printEvidence: String?
                if productSource.fetch.pricingForPlaceholderVariants == true, card.hasPlaceholderVariants {
                    let priced = variants(fromPriceKeys: card.pricing?.tcgplayer?.keys ?? [])
                    if !priced.isEmpty {
                        cardVariants = priced
                        printEvidence = "tcgplayer-pricing"
                    } else if let declared = productSource.fetch.placeholderPrints?["\(part.id):\(card.rarity ?? "")"]
                                ?? productSource.fetch.placeholderPrints?[part.id] {
                        cardVariants = [declared]
                        printEvidence = "research"
                    }
                }
                if let stamp = productSource.fetch.reverseFromStamp, !cardVariants.contains(.reverse),
                   card.variantsDetailed?.contains(where: { $0.stamp?.contains(stamp) == true && ($0.size ?? "standard") == "standard" }) == true {
                    cardVariants.append(.reverse)
                    printEvidence = "tcgdex-stamp:\(stamp)"
                }
                if let removed = excludedPrints[card.id] {
                    guard removed.isSubset(of: Set(cardVariants)) else {
                        throw PackTraceError.storage("excluded print of \(card.id) names a variant the source does not list")
                    }
                    unusedExclusions.remove(card.id + ":print")
                    cardVariants.removeAll { removed.contains($0) }
                }
                guard !cardVariants.isEmpty else {
                    throw PackTraceError.storage("card \(card.id) has no normal, holo or reverse print in the source")
                }
                guard let rarity = card.rarity else {
                    throw PackTraceError.storage("card \(card.id) has no rarity in the source")
                }
                let image: String
                if let url = card.image {
                    image = url
                } else if productSource.fetch.allowMissingImages == true {
                    image = ""
                } else {
                    throw PackTraceError.storage("card \(card.id) has no image base URL in the source")
                }
                let key = CardKey(source: source, language: language, setID: part.id, localID: card.localId)
                guard seen.insert(key).inserted else {
                    throw PackTraceError.storage("duplicate card id \(key)")
                }
                partDefinitions.append(
                    CardDefinition(
                        key: key,
                        source: source,
                        language: language,
                        setID: part.id,
                        localID: card.localId,
                        name: card.name,
                        rarity: CardRarity(rawValue: rarity),
                        category: CardCategory(sourceValue: card.category ?? ""),
                        variants: cardVariants,
                        imageBaseURL: image,
                        printEvidence: printEvidence
                    )
                )
            }
            guard partDefinitions.count + skipped == part.cards.count else {
                throw PackTraceError.storage(
                    "fetched \(partDefinitions.count) card details (+\(skipped) excluded) for \(part.cards.count) cards in set \(part.id)"
                )
            }
            definitions += partDefinitions
        }
        guard unusedExclusions.isEmpty else {
            throw PackTraceError.storage("exclusions match no card in the source: \(unusedExclusions.sorted())")
        }
        definitions.sort { ($0.setID == setID ? 0 : 1, $0.setID, $0.localID) < ($1.setID == setID ? 0 : 1, $1.setID, $1.localID) }

        func info(_ part: TCGdexSchema.SetResponse) -> CardSetInfo {
            CardSetInfo(
                source: source,
                language: language,
                externalSetID: part.id,
                name: part.name,
                releaseDate: part.releaseDate ?? "unknown",
                officialCardCount: part.cardCount.official,
                totalCardCount: part.cardCount.total,
                logoURL: part.logo.map { $0 + ".webp" },
                symbolURL: part.symbol.map { $0 + ".webp" }
            )
        }
        let setInfo = info(set)
        let subsets = extraSets.isEmpty ? nil : extraSets.map { info($0.set) }

        let recipes = productSource.recipesCatalog()
        let products = productSource.products.map { product in
            PackProduct(
                packID: product.packID,
                name: product.name,
                region: product.region,
                language: product.language,
                setID: setID,
                recipeID: product.recipeID,
                artworkSubstitute: ArtworkSubstitute(
                    note: product.artwork.note,
                    logoURL: setInfo.logoURL,
                    symbolURL: setInfo.symbolURL
                ),
                verification: product.verification
            )
        }

        var catalog = PackCatalog(
            catalogVersion: catalogVersion,
            generatedAt: fetchedAt.packTraceTimestamp,
            sourceName: productSource.fetch.sourceName,
            sourceURL: productSource.fetch.sourceURL,
            sourceEndpoint: "/sets/\(setID)",
            fetchedAt: fetchedAt.packTraceTimestamp,
            contentHash: "",
            set: setInfo,
            subsets: subsets,
            products: products,
            recipes: recipes,
            cards: definitions
        )
        try validate(catalog)
        catalog.contentHash = CatalogLoader.contentHash(for: catalog)
        return catalog
    }

    /// Prints named by TCGplayer price keys. First-edition keys are left out:
    /// the app models unlimited prints only.
    static func variants(fromPriceKeys keys: [String]) -> [CardVariant] {
        var variants: [CardVariant] = []
        if keys.contains("normal") || keys.contains("unlimited") { variants.append(.normal) }
        if keys.contains("holofoil") || keys.contains("unlimited-holofoil") { variants.append(.holo) }
        if keys.contains("reverse-holofoil") { variants.append(.reverse) }
        return variants
    }

    static func variants(from raw: TCGdexSchema.CardResponse.Variants?) -> [CardVariant] {
        var variants: [CardVariant] = []
        if raw?.normal == true { variants.append(.normal) }
        if raw?.holo == true { variants.append(.holo) }
        if raw?.reverse == true { variants.append(.reverse) }
        return variants
    }

    /// Fails the fetch when a product points at an empty pool, a wrong pack
    /// size, or a card whose only variant cannot satisfy the slot rule.
    public static func validate(_ catalog: PackCatalog) throws {
        for product in catalog.products {
            guard catalog.recipe(id: product.recipeID) != nil else {
                throw PackTraceError.storage("product \(product.packID) references missing recipe \(product.recipeID)")
            }
        }
        for recipe in catalog.recipes {
            let total = recipe.slots.reduce(0) { $0 + $1.count }
            guard total == recipe.packSize else {
                throw PackTraceError.recipeSizeMismatch(
                    recipeID: recipe.recipeID,
                    declared: recipe.packSize,
                    actual: total
                )
            }
            for (index, slot) in recipe.slots.enumerated() {
                let pool = recipe.pool(for: slot, in: catalog)
                guard !pool.isEmpty else {
                    throw PackTraceError.poolEmpty(recipeID: recipe.recipeID, slotIndex: index)
                }
                if slot.variantRule == .reverse {
                    let unavailable = pool.filter { !$0.variants.contains(.reverse) }
                    guard unavailable.isEmpty else {
                        throw PackTraceError.variantUnavailable(cardKey: unavailable[0].key, variant: .reverse)
                    }
                }
            }
        }
    }
}

extension Date {
    /// Second-resolution UTC timestamp used in catalogue snapshots.
    var packTraceTimestamp: String {
        ISO8601FormatStyle().format(self)
    }
}

/// Fetches the set, its card details and the asset URLs, then writes a pinned
/// catalogue snapshot. Network use is limited to the JSON API and the asset
/// host; no credentials, cookies or logins are involved.
public struct CatalogFetcher: Sendable {
    public struct Options: Sendable {
        public var productsFile: URL
        public var outputURL: URL
        public var catalogVersion: String
        public var concurrency: Int
        public var verifyAssets: Bool

        public init(
            productsFile: URL,
            outputURL: URL,
            catalogVersion: String,
            concurrency: Int = 6,
            verifyAssets: Bool = true
        ) {
            self.productsFile = productsFile
            self.outputURL = outputURL
            self.catalogVersion = catalogVersion
            self.concurrency = concurrency
            self.verifyAssets = verifyAssets
        }
    }

    public struct Result: Sendable {
        public var catalog: PackCatalog
        public var outputURL: URL
        public var cardCount: Int
        public var assetChecks: [String: Int]
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func run(options: Options, log: @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let productSource = try ProductSourceFile.load(contentsOf: options.productsFile)
        let base = productSource.fetch.sourceURL
        let setID = productSource.fetch.setID
        let language = productSource.fetch.language

        log("fetching set \(setID) (\(language)) from \(base)")
        let set: TCGdexSchema.SetResponse = try await get(url: "\(base)/sets/\(Self.pathComponent(setID))")
        log("set \(set.name): \(set.cards.count) cards listed, official \(set.cardCount.official), total \(set.cardCount.total)")

        let cardURLs = set.cards.map { "\(base)/cards/\(Self.pathComponent($0.id))" }
        let cards = try await fetchAll(urls: cardURLs, concurrency: options.concurrency, log: log)

        var extraSets: [(set: TCGdexSchema.SetResponse, cards: [TCGdexSchema.CardResponse])] = []
        for extraID in productSource.fetch.extraSetIDs ?? [] {
            let extra: TCGdexSchema.SetResponse = try await get(url: "\(base)/sets/\(Self.pathComponent(extraID))")
            log("subset \(extra.name): \(extra.cards.count) cards")
            let extraCards = try await fetchAll(urls: extra.cards.map { "\(base)/cards/\(Self.pathComponent($0.id))" }, concurrency: options.concurrency, log: log)
            extraSets.append((extra, extraCards))
        }

        var catalog = try CatalogBuilder.build(
            productSource: productSource,
            set: set,
            cards: cards,
            extraSets: extraSets,
            fetchedAt: Date(),
            catalogVersion: options.catalogVersion
        )
        log("catalog \(catalog.catalogVersion) built with \(catalog.cards.count) cards, hash \(catalog.contentHash)")

        var assetChecks: [String: Int] = [:]
        if options.verifyAssets {
            // The API reports some set assets under a language-neutral path
            // that the asset host does not serve; resolve against candidates
            // and record which URL actually answered.
            catalog.set.logoURL = await resolveAsset(candidates: candidates(for: set.logo), label: "logo", checks: &assetChecks)
            catalog.set.symbolURL = await resolveAsset(candidates: candidates(for: set.symbol), label: "symbol", checks: &assetChecks)
            catalog.products = catalog.products.map { product in
                var updated = product
                updated.artworkSubstitute.logoURL = catalog.set.logoURL
                updated.artworkSubstitute.symbolURL = catalog.set.symbolURL
                return updated
            }

            // The source leaves some subset cards without an image link while
            // the asset host serves them under the subset's own folder or the
            // parent set's (Trainer Gallery art lives under swsh9/TG01). Only a
            // URL that answers 200 is kept; the rest stay text placeholders.
            // Some sets have no image link at all while the host serves them
            // under the set id without its dot (Shining Legends is sm35).
            let seriesFolder = catalog.cards.first(where: CardImageURL.hasImage)
                .flatMap { URL(string: $0.imageBaseURL)?.deletingLastPathComponent().deletingLastPathComponent().absoluteString }
                .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                ?? set.serie.map { "https://assets.tcgdex.net/\(catalog.set.language)/\($0.id)" }
            if let seriesFolder {
                let numbers = Dictionary(grouping: catalog.cards, by: \.localID).mapValues(\.count)
                for index in catalog.cards.indices where !CardImageURL.hasImage(catalog.cards[index]) {
                    let card = catalog.cards[index]
                    let local = Self.pathComponent(card.localID)
                    var folders = [card.setID, card.setID.replacingOccurrences(of: ".", with: "")]
                    // The parent's folder only when no other card has this
                    // number: 30th-c "001" would otherwise get 30th's card 001.
                    if numbers[card.localID] == 1, card.setID != catalog.set.externalSetID {
                        folders += [catalog.set.externalSetID, catalog.set.externalSetID.replacingOccurrences(of: ".", with: "")]
                    }
                    var seen = Set<String>()
                    let candidates = folders.filter { seen.insert($0).inserted }.map { "\(seriesFolder)/\($0)/\(local)" }
                    for candidate in candidates where await probe(url: candidate + "/low.webp") == 200 {
                        catalog.cards[index].imageBaseURL = candidate
                        assetChecks[candidate + "/low.webp"] = 200
                        break
                    }
                }
            }
            let withImage = catalog.cards.filter(CardImageURL.hasImage)
            let sampled = [withImage.first, withImage.last].compactMap { $0 }
            var sampleFailed = false
            for card in sampled {
                let url = card.imageBaseURL + "/low.webp"
                let status = await probe(url: url)
                assetChecks[url] = status
                if status != 200 {
                    guard productSource.fetch.allowMissingImages == true else {
                        throw PackTraceError.storage("card image check failed (\(status)) for \(url)")
                    }
                    sampleFailed = true
                }
            }
            // Some sets list image links the asset host does not serve (Double
            // Crisis). Then every card is checked and only the links that
            // answer 200 are kept; the rest become text placeholders.
            if sampleFailed {
                for index in catalog.cards.indices where CardImageURL.hasImage(catalog.cards[index]) {
                    let url = catalog.cards[index].imageBaseURL + "/low.webp"
                    if await probe(url: url) != 200 {
                        catalog.cards[index].imageBaseURL = ""
                    }
                }
            }
            let missing = catalog.cards.filter { !CardImageURL.hasImage($0) }
            if !missing.isEmpty {
                log("cards without artwork in the source (\(missing.count)): \(missing.map { "\($0.setID)-\($0.localID)" }.joined(separator: " "))")
            }
            log("asset checks: \(assetChecks.map { "\($0.key.suffix(26))=\($0.value)" }.sorted().joined(separator: " "))")
            catalog.contentHash = CatalogLoader.contentHash(for: catalog)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(catalog)
        try FileManager.default.createDirectory(
            at: options.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: options.outputURL, options: .atomic)
        log("wrote \(options.outputURL.path) (\(data.count) bytes)")

        return Result(
            catalog: catalog,
            outputURL: options.outputURL,
            cardCount: catalog.cards.count,
            assetChecks: assetChecks
        )
    }

    /// A source id as one URL path segment. Ids are not all URL-safe: the
    /// Unseen Forces Unown "?" is `exu-?`, which would otherwise start a query.
    static func pathComponent(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    private func fetchAll(
        urls: [String],
        concurrency: Int,
        log: @Sendable (String) -> Void
    ) async throws -> [TCGdexSchema.CardResponse] {
        var results: [TCGdexSchema.CardResponse] = []
        results.reserveCapacity(urls.count)
        try await withThrowingTaskGroup(of: (Int, TCGdexSchema.CardResponse).self) { group in
            var next = 0
            let window = max(1, min(concurrency, 12))
            while next < window, next < urls.count {
                let index = next
                group.addTask { (index, try await self.get(url: urls[index])) }
                next += 1
            }
            var completed = 0
            while let (index, card) = try await group.next() {
                results.append(card)
                completed += 1
                if completed % 50 == 0 {
                    log("fetched \(completed)/\(urls.count) card details")
                }
                if next < urls.count {
                    let upcoming = next
                    group.addTask { (upcoming, try await self.get(url: urls[upcoming])) }
                    next += 1
                }
                _ = index
            }
        }
        return results
    }

    private func get<T: Decodable>(url: String) async throws -> T {
        let data = try await request(url: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PackTraceError.storage("decode failed for \(url): \(error)")
        }
    }

    private func request(url: String, attempts: Int = 4) async throws -> Data {
        guard let parsed = URL(string: url) else {
            throw PackTraceError.storage("invalid URL \(url)")
        }
        var lastError: Error = PackTraceError.storage("no attempt made for \(url)")
        for attempt in 1...attempts {
            do {
                var request = URLRequest(url: parsed)
                request.timeoutInterval = 30
                request.setValue("PackTrace/0.1 (local collection app)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PackTraceError.storage("no HTTP response for \(url)")
                }
                if http.statusCode == 200 {
                    return data
                }
                if http.statusCode == 404 {
                    throw PackTraceError.storage("404 for \(url)")
                }
                lastError = PackTraceError.storage("HTTP \(http.statusCode) for \(url)")
            } catch {
                lastError = error
            }
            if attempt < attempts {
                let delay = UInt64(attempt) * 1_500_000_000
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError
    }

    /// Candidate URLs for a set asset: the API path first, then the
    /// language-scoped variant the asset host actually serves.
    private func candidates(for base: String?) -> [String] {
        guard let base else { return [] }
        var urls = [base + ".webp", base + ".png"]
        if base.contains("/univ/") {
            urls.append(base.replacingOccurrences(of: "/univ/", with: "/en/") + ".webp")
        }
        return urls
    }

    private func resolveAsset(
        candidates: [String],
        label: String,
        checks: inout [String: Int]
    ) async -> String? {
        for url in candidates {
            let status = await probe(url: url)
            checks[url] = status
            if status == 200 {
                return url
            }
        }
        return nil
    }

    /// Status code, or -1 when the request itself failed. Used for asset
    /// probing where a missing file is a reportable fact, not a crash.
    /// A 5xx or a failed request is retried: a card must not lose its art
    /// because the asset host was briefly busy (the same set fetched three
    /// times came back with 3, 3 and 11 cards "missing").
    private func probe(url: String, attempts: Int = 4) async -> Int {
        guard let parsed = URL(string: url) else { return -1 }
        var request = URLRequest(url: parsed)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        var status = -1
        for attempt in 1...attempts {
            if let (_, response) = try? await session.data(for: request) {
                status = (response as? HTTPURLResponse)?.statusCode ?? -1
            } else {
                status = -1
            }
            if status != -1, status < 500 { return status }
            if attempt < attempts { try? await Task.sleep(for: .milliseconds(400 * attempt)) }
        }
        return status
    }
}
