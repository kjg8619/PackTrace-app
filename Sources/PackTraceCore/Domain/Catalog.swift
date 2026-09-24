import Foundation

/// Where a card print lives in the source data. Reverse/variant availability
/// comes from the source, so the app can only ever emit combinations the
/// catalogue says exist.
public enum CardVariant: String, Sendable, Codable, CaseIterable {
    case normal
    case holo
    case reverse

    public var displayName: String {
        switch self {
        case .normal: "노멀"
        case .holo: "홀로"
        case .reverse: "리버스 홀로"
        }
    }
}

public enum CardCategory: String, Sendable, Codable {
    case pokemon = "Pokemon"
    case trainer = "Trainer"
    case energy = "Energy"
    case unknown

    public init(sourceValue: String) {
        self = CardCategory(rawValue: sourceValue) ?? .unknown
    }
}

/// Rarity is kept verbatim from the source so provenance survives; the set of
/// known values is only used for display and pool selection in a recipe.
public struct CardRarity: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    public var displayName: String {
        switch rawValue {
        case "Common": "커먼"
        case "Uncommon": "언커먼"
        case "Rare": "레어"
        case "Double rare": "더블 레어"
        case "Ultra Rare": "울트라 레어"
        case "Illustration rare": "일러스트 레어"
        case "Special illustration rare": "스페셜 일러스트 레어"
        case "Hyper rare": "하이퍼 레어"
        case "ACE SPEC Rare": "에이스 스펙 레어"
        case "Holo Rare", "Rare Holo": "홀로 레어"
        case "Rare Holo LV.X": "LV.X 레어"
        case "Rare PRIME": "프라임 레어"
        case "LEGEND": "레전드"
        case "Secret Rare": "시크릿 레어"
        case "Holo Rare V": "V 레어"
        case "Holo Rare VMAX": "VMAX 레어"
        case "Holo Rare VSTAR": "VSTAR 레어"
        case "Amazing Rare": "어메이징 레어"
        case "Radiant Rare": "레디언트 레어"
        case "Shiny rare": "샤이니 레어"
        case "Shiny rare V": "샤이니 V 레어"
        case "Shiny rare VMAX": "샤이니 VMAX 레어"
        case "Shiny Ultra Rare": "샤이니 울트라 레어"
        case "Full Art Trainer": "풀아트 트레이너"
        case "Classic Collection": "클래식 컬렉션"
        case "Black White Rare": "블랙 화이트 레어"
        case "Mega Hyper Rare": "메가 하이퍼 레어"
        case "Pikachu Rare": "피카츄 레어"
        case "Futuristic Rare": "퓨처리스틱 레어"
        case "None": "등급 표기 없음"
        default: rawValue
        }
    }

    /// Rarities printed as foil when the source lists a foil print. An older
    /// "Rare" with only a normal print stays normal (see `primaryVariant`).
    public var isFoilByDefault: Bool {
        rawValue != "Common" && rawValue != "Uncommon"
    }
}

public struct CardDefinition: Hashable, Sendable, Codable {
    public var key: CardKey
    public var source: String
    public var language: String
    public var setID: String
    public var localID: String
    public var name: String
    public var rarity: CardRarity
    public var category: CardCategory
    /// Variants the source says exist for this print.
    public var variants: [CardVariant]
    /// Image base URL; the quality and extension are appended at download time.
    public var imageBaseURL: String
    /// Where `variants` came from when it is not the source's own variant
    /// list: `tcgplayer-pricing` (the source's flags were placeholders and its
    /// TCGplayer price keys name the prints) or `research` (placeholders, no
    /// price keys; the print the source file's research names). Absent for the
    /// source's own flags, so earlier catalogues hash as before.
    public var printEvidence: String? = nil

    /// Variant used when a slot does not force reverse.
    ///
    /// Rarity decides the preference because the Scarlet & Violet era prints
    /// every card of Rare or higher as foil in boosters, while Commons and
    /// Uncommons are non-holo there. Some entries also list a foil print of a
    /// common card (a deck or promo printing): preferring the booster-correct
    /// print keeps draws inside the product's real configuration.
    public var primaryVariant: CardVariant {
        // A card printed only as a reverse holo (Platinum-era Shiny SH cards)
        // has no other print to fall back to.
        if variants == [.reverse] { return .reverse }
        if rarity.isFoilByDefault {
            return variants.contains(.holo) ? .holo : .normal
        }
        return variants.contains(.normal) ? .normal : .holo
    }

    /// Prints this app collects for the card: the primary print plus the
    /// reverse print when one exists. Drawable target, used for binder rows and
    /// for the reachability check in the catalogue tool.
    public var supportedVariants: [CardVariant] {
        var result = [primaryVariant]
        if variants.contains(.reverse), primaryVariant != .reverse {
            result.append(.reverse)
        }
        return result
    }
}

public struct CardSetInfo: Hashable, Sendable, Codable {
    public var source: String
    public var language: String
    public var externalSetID: String
    public var name: String
    public var releaseDate: String
    /// Number of cards in the officially numbered set.
    public var officialCardCount: Int
    /// Number of prints including secret rares, as reported by the source.
    public var totalCardCount: Int
    public var logoURL: String?
    public var symbolURL: String?
}

/// How well the product itself (not the card data) has been checked against
/// real-world sources.
public enum VerificationStatus: String, Sendable, Codable, CaseIterable {
    /// Placeholder product, not a real pack.
    case demo
    /// Product identity and contents come from documented sources but the
    /// official product page was not verified from this machine.
    case metadataVerified = "metadata-verified"
    /// Identity, contents and card pool all confirmed from primary sources.
    case readyForReward = "ready-for-reward"

    public var displayName: String {
        switch self {
        case .demo: "demo"
        case .metadataVerified: "metadata-verified"
        case .readyForReward: "ready-for-reward"
        }
    }
}

public struct Evidence: Hashable, Sendable, Codable {
    public var claim: String
    public var source: String
    public var url: String
    public var checkedAt: String
    /// `primary` when the source is the publisher of the product, otherwise
    /// the kind of secondary source it is.
    public var kind: String
}

public struct UnverifiedItem: Hashable, Sendable, Codable {
    public var item: String
    public var note: String
}

public struct ProductVerification: Hashable, Sendable, Codable {
    public var status: VerificationStatus
    public var evidence: [Evidence]
    public var unverified: [UnverifiedItem]
}

/// Pack artwork that is not the real printed wrap.
public struct ArtworkSubstitute: Hashable, Sendable, Codable {
    public var note: String
    public var logoURL: String?
    public var symbolURL: String?
}

public struct PackProduct: Hashable, Sendable, Codable {
    public var packID: String
    public var name: String
    public var region: String
    public var language: String
    public var setID: String
    public var recipeID: String
    public var artworkSubstitute: ArtworkSubstitute
    public var verification: ProductVerification

    /// Only products that cleared verification may be handed out.
    public var isRewardEligible: Bool {
        verification.status == .readyForReward || verification.status == .metadataVerified
    }
}

public struct PackCatalog: Sendable, Codable, Identifiable {
    public var id: String { catalogVersion }
    public var catalogVersion: String
    public var generatedAt: String
    public var sourceName: String
    public var sourceURL: String
    public var sourceEndpoint: String
    public var fetchedAt: String
    public var contentHash: String
    public var set: CardSetInfo
    /// Sets the source keeps separately but that come in this set's packs
    /// (Trainer Gallery, Shiny Vault …). Their cards keep their own set id.
    public var subsets: [CardSetInfo]?
    public var products: [PackProduct]
    public var recipes: [PackRecipe]
    public var cards: [CardDefinition]

    public func recipe(id: String) -> PackRecipe? {
        recipes.first { $0.recipeID == id }
    }

    public func product(id: String) -> PackProduct? {
        products.first { $0.packID == id }
    }

    public func cards(in setID: String) -> [CardDefinition] {
        cards.filter { $0.setID == setID }
    }
}
