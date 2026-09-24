import CryptoKit
import Foundation

/// Loads a pinned catalogue snapshot from disk and proves it is the snapshot
/// it claims to be. Everything the app draws from is hash-checked, so a
/// catalogue edited by hand fails loudly instead of silently changing packs.
public enum CatalogLoader {
    public struct HashPayload: Encodable {
        public var catalogVersion: String
        public var set: CardSetInfo
        /// Omitted when nil, so catalogues without subsets hash as before.
        public var subsets: [CardSetInfo]?
        public var products: [PackProduct]
        public var recipes: [PackRecipe]
        public var cards: [CardDefinition]
    }

    public static func contentHash(for catalog: PackCatalog) -> String {
        contentHash(
            HashPayload(
                catalogVersion: catalog.catalogVersion,
                set: catalog.set,
                subsets: catalog.subsets,
                products: catalog.products,
                recipes: catalog.recipes,
                cards: catalog.cards
            )
        )
    }

    public static func contentHash(_ payload: HashPayload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return "unhashable" }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func load(contentsOf url: URL) throws -> PackCatalog {
        let data = try Data(contentsOf: url)
        let catalog: PackCatalog
        do {
            catalog = try JSONDecoder().decode(PackCatalog.self, from: data)
        } catch {
            throw PackTraceError.storage("catalog decode failed for \(url.lastPathComponent): \(error)")
        }
        let actual = contentHash(for: catalog)
        guard actual == catalog.contentHash else {
            throw PackTraceError.catalogHashMismatch(expected: catalog.contentHash, actual: actual)
        }
        return catalog
    }

    /// A snapshot shipped in the app bundle, decoded and hash-checked once.
    static func loadBundledCatalog(at url: URL) throws -> PackCatalog {
        if let cached = bundledCache.catalog(at: url) { return cached }
        let catalog = try load(contentsOf: url)
        bundledCache.store(catalog, at: url)
        return catalog
    }

    /// Snapshots inside the app bundle cannot change while it runs, so each is
    /// decoded and hash-checked once per process. With every era shipped that
    /// is ~150 files; profile-local snapshots are always read fresh.
    private static let bundledCache = BundledCatalogCache()

    private final class BundledCatalogCache: @unchecked Sendable {
        private let lock = NSLock()
        private var catalogs: [String: PackCatalog] = [:]
        private var library: CatalogLibrary?

        func catalog(at url: URL) -> PackCatalog? {
            lock.lock(); defer { lock.unlock() }
            return catalogs[url.standardizedFileURL.path]
        }

        func store(_ catalog: PackCatalog, at url: URL) {
            lock.lock(); defer { lock.unlock() }
            catalogs[url.standardizedFileURL.path] = catalog
        }

        func bundledLibrary(_ make: () throws -> CatalogLibrary) rethrows -> CatalogLibrary {
            lock.lock()
            if let library { lock.unlock(); return library }
            lock.unlock()
            let made = try make()
            lock.lock(); defer { lock.unlock() }
            library = library ?? made
            return library!
        }
    }

    /// Catalogue snapshots shipped with the app, ordered by file name.
    public static func bundledCatalogURLs() -> [URL] {
        let directory = Bundle.module.url(forResource: "catalog", withExtension: nil)
        guard let directory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func loadBundled() throws -> PackCatalog {
        try bundledLibrary().primary
    }

    public static func bundledLibrary() throws -> CatalogLibrary {
        try bundledCache.bundledLibrary {
            let catalogs = try bundledCatalogURLs().map { try loadBundledCatalog(at: $0) }
            guard !catalogs.isEmpty else {
                throw PackTraceError.catalogNotFound("bundled")
            }
            return try CatalogLibrary(catalogs: catalogs)
        }
    }

    /// The bundled snapshot whose contents declare `version`, or nil when the
    /// app does not ship that version. Bundled file names do not have to match
    /// the version they contain.
    public static func bundledCatalogURL(version: String) -> URL? {
        for url in bundledCatalogURLs() {
            guard let catalog = try? loadBundledCatalog(at: url) else { continue }
            if catalog.catalogVersion == version { return url }
        }
        return nil
    }

    /// Snapshot files installed inside a profile directory (a restore can put
    /// a catalogue there that the app no longer bundles).
    public static func localCatalogURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Bundled snapshots plus the profiles' own, so a restored profile can open
    /// packs that are pinned to a snapshot the app has moved past. The bundled
    /// snapshot wins when a version appears in both.
    public static func library(includingLocalDirectories directories: [URL] = []) throws -> CatalogLibrary {
        let bundled = try bundledLibrary()
        var seen = Set(bundled.catalogs.keys)
        var extra: [PackCatalog] = []
        for directory in directories {
            for url in localCatalogURLs(in: directory) {
                guard let catalog = try? load(contentsOf: url), seen.insert(catalog.catalogVersion).inserted else {
                    continue
                }
                extra.append(catalog)
            }
        }
        // Usually nothing extra: then the library built once per process is
        // reused (every era is ~140 catalogues and 20k cards to index).
        return extra.isEmpty ? bundled : try bundled.adding(extra)
    }

    public static func loadBundled(version: String) throws -> PackCatalog {
        guard let url = bundledCatalogURLs().first(where: { $0.deletingPathExtension().lastPathComponent == version }) else {
            throw PackTraceError.catalogNotFound(version)
        }
        return try loadBundledCatalog(at: url)
    }
}

/// Every catalogue snapshot the app knows about, keyed by version. Packs pin
/// the version they were handed out with, so a refreshed catalogue cannot
/// change how an already-owned pack opens. Old snapshots stay on disk as long
/// as packs or openings reference them.
public struct CatalogLibrary: Sendable {
    public let catalogs: [String: PackCatalog]
    public let primaryVersion: String

    // Derived from `catalogs`, which never changes after init. These were
    // computed properties, so every `card(for:)` rebuilt a dictionary of every
    // card in every set; with ten sets that made each screen refresh ~3x slower.
    public let cardsByKey: [CardKey: CardDefinition]
    public let cards: [CardDefinition]
    /// Set ids in a stable order.
    public let setIDs: [String]
    private let cardsBySet: [String: [CardDefinition]]
    private let setInfoByID: [String: CardSetInfo]
    /// Subset id → the set whose catalogue carries it.
    private let parentByID: [String: String]

    public init(catalogs: [PackCatalog]) throws {
        guard !catalogs.isEmpty else { throw PackTraceError.catalogNotFound("empty library") }
        var map: [String: PackCatalog] = [:]
        for catalog in catalogs {
            guard map[catalog.catalogVersion] == nil else {
                throw PackTraceError.storage("duplicate catalogue version \(catalog.catalogVersion)")
            }
            map[catalog.catalogVersion] = catalog
        }
        self.catalogs = map
        self.primaryVersion = catalogs.map(\.catalogVersion).sorted().last ?? ""

        // Every set present in any snapshot, with the newest snapshot winning
        // for metadata. Cards are keyed by their stable `cardKey`, so a
        // catalogue version bump cannot duplicate a print the user already owns.
        var byKey: [CardKey: CardDefinition] = [:]
        for catalog in map.values.sorted(by: { $0.catalogVersion < $1.catalogVersion }) {
            for card in catalog.cards {
                byKey[card.key] = card
            }
        }
        let sorted = byKey.values.sorted {
            $0.setID == $1.setID ? $0.localID < $1.localID : $0.setID < $1.setID
        }
        self.cardsByKey = byKey
        self.cards = sorted
        self.cardsBySet = Dictionary(grouping: sorted, by: \.setID)
        self.setIDs = Array(Set(map.values.flatMap { $0.cards.map(\.setID) })).sorted()

        // Newest snapshot wins; a set's own catalogue wins over one that
        // carries it as a subset.
        let ordered = map.values.sorted { $0.catalogVersion < $1.catalogVersion }
        var infos: [String: CardSetInfo] = [:]
        var parents: [String: String] = [:]
        for catalog in ordered {
            for subset in catalog.subsets ?? [] {
                infos[subset.externalSetID] = subset
                parents[subset.externalSetID] = catalog.set.externalSetID
            }
        }
        for catalog in ordered {
            infos[catalog.set.externalSetID] = catalog.set
        }
        self.setInfoByID = infos
        self.parentByID = parents
    }

    public var primary: PackCatalog {
        // `primaryVersion` is always present: the initializer requires a non-empty list.
        catalogs[primaryVersion] ?? catalogs.values.first!
    }

    public func catalog(version: String) -> PackCatalog? {
        catalogs[version]
    }

    /// This library plus the given snapshots. Snapshots already known win, so a
    /// backup cannot replace what the app ships.
    public func adding(_ extra: [PackCatalog]) throws -> CatalogLibrary {
        var merged = Array(catalogs.values)
        var seen = Set(catalogs.keys)
        for catalog in extra where seen.insert(catalog.catalogVersion).inserted {
            merged.append(catalog)
        }
        return try CatalogLibrary(catalogs: merged)
    }

    /// Version that should be handed out for new exchanges.
    public func rewardCatalog() -> PackCatalog {
        primary
    }

    // MARK: - Set-aware reads

    public func cards(inSet setID: String) -> [CardDefinition] {
        cardsBySet[setID] ?? []
    }

    public func card(for key: CardKey) -> CardDefinition? {
        cardsByKey[key]
    }

    /// Set metadata from the newest snapshot that ships it.
    public func setInfo(for setID: String) -> CardSetInfo? {
        setInfoByID[setID]
    }

    /// The set whose catalogue carries `setID` as a subset, if any.
    public func parentSetID(of setID: String) -> String? {
        parentByID[setID]
    }

    /// Products across every snapshot, newest version first.
    public var products: [PackProduct] {
        catalogs.values
            .sorted { $0.catalogVersion < $1.catalogVersion }
            .flatMap(\.products)
    }

    public func product(id packID: String) -> PackProduct? {
        products.last { $0.packID == packID }
    }
}

/// Reads the human-reviewed product and recipe definitions that the fetch tool
/// merges with freshly fetched card data.
public struct ProductSourceFile: Sendable, Decodable {
    public struct Fetch: Sendable, Decodable {
        public var sourceName: String
        public var sourceURL: String
        public var language: String
        public var setID: String
        /// Subsets fetched into the same catalogue (their cards keep their own
        /// set id).
        public var extraSetIDs: [String]?
        /// Source card ids (e.g. `base1-102`) in the set's numbering that were
        /// never in its boosters (deck-only, promo). Left out of the catalogue
        /// so the binder never asks for a card a pack cannot give.
        public var excludedCardIDs: [String]?
        /// Single prints (`lc-3:normal`) the source lists but no booster held
        /// (theme-deck or jumbo-only). The card stays; that print does not.
        public var excludedPrints: [String]?
        /// For cards whose source variant list is a placeholder
        /// (`variantId: "generated"`), take the prints from the source's
        /// TCGplayer price keys instead. Recorded per card as `printEvidence`.
        public var pricingForPlaceholderVariants: Bool?
        /// Placeholder cards with no price keys either: the one print the
        /// research found, keyed by set (every Shiny Vault card is holo) or by
        /// `set:rarity` (Black & White EX and full-art cards are foil), the
        /// rarity key winning.
        public var placeholderPrints: [String: CardVariant]?
        /// Sets whose reverse holos the source records only as a stamped print
        /// in its detailed variants (EX Delta Species → Power Keepers carry the
        /// set logo): a standard-size print with this stamp counts as reverse.
        public var reverseFromStamp: String?
        /// Accept cards the source lists without artwork (stored with an empty
        /// image base; screens show the text placeholder). The fetch log names
        /// them. Off by default so a broken fetch still fails loudly.
        public var allowMissingImages: Bool?
    }

    public struct RecipeSlotSource: Sendable, Decodable {
        public var count: Int
        public var rarities: [String]
        public var requiresVariant: CardVariant?
        public var variantRule: VariantRule
        /// Sets this slot draws from; the product's own set when absent.
        public var setIDs: [String]?
        /// Also every card of those sets that has this print, whatever its rarity.
        public var anyRarityWithVariant: CardVariant?
        /// Also every card of these subsets.
        public var wholeSetIDs: [String]?
        /// Only / never cards whose number starts with one of these.
        public var localIDPrefixes: [String]?
        public var excludedLocalIDPrefixes: [String]?
    }

    public struct RecipeSource: Sendable, Decodable {
        public var recipeID: String
        public var version: Int
        public var packSize: Int
        public var duplicatesAllowed: Bool
        public var disclaimer: String
        public var slots: [RecipeSlotSource]
    }

    public struct ProductArtwork: Sendable, Decodable {
        public var note: String
    }

    public struct ProductSource: Sendable, Decodable {
        public var packID: String
        public var name: String
        public var region: String
        public var language: String
        public var recipeID: String
        public var artwork: ProductArtwork
        public var verification: ProductVerification
    }

    public var catalogVersionPrefix: String
    public var fetch: Fetch
    public var recipes: [RecipeSource]
    public var products: [ProductSource]

    public static func load(contentsOf url: URL) throws -> ProductSourceFile {
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(ProductSourceFile.self, from: data)
        } catch {
            throw PackTraceError.storage("product source decode failed for \(url.lastPathComponent): \(error)")
        }
    }

    public func recipesCatalog() -> [PackRecipe] {
        recipes.map { recipe in
            PackRecipe(
                recipeID: recipe.recipeID,
                version: recipe.version,
                setID: fetch.setID,
                packSize: recipe.packSize,
                duplicatesAllowed: recipe.duplicatesAllowed,
                slots: recipe.slots.map { slot in
                    RecipeSlot(
                        count: slot.count,
                        selector: PoolSelector(
                            rarities: slot.rarities.map(CardRarity.init(rawValue:)),
                            requiresVariant: slot.requiresVariant,
                            setIDs: slot.setIDs,
                            anyRarityWithVariant: slot.anyRarityWithVariant,
                            wholeSetIDs: slot.wholeSetIDs,
                            localIDPrefixes: slot.localIDPrefixes,
                            excludedLocalIDPrefixes: slot.excludedLocalIDPrefixes
                        ),
                        variantRule: slot.variantRule
                    )
                },
                disclaimer: recipe.disclaimer,
                evidence: products.flatMap(\.verification.evidence)
            )
        }
    }
}
