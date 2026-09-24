import Foundation

/// Membership test for one slot of a recipe. A card qualifies only if its
/// rarity is listed and, when a variant is required, the source says that
/// variant exists for the print.
public struct PoolSelector: Hashable, Sendable, Codable {
    public var rarities: [CardRarity]
    public var requiresVariant: CardVariant?
    /// Sets the slot draws from, when it is not only the recipe's own set: a
    /// subset the source keeps as a separate set (Trainer Gallery, Shiny
    /// Vault, Classic Collection …) that comes in the same pack. Absent in
    /// every recipe written before subsets, so their hashes are unchanged.
    public var setIDs: [String]?
    /// Also any card of those sets that has this print, whatever its rarity:
    /// a reverse slot takes every reverse print there is, so a card the
    /// source files under an unexpected rarity is not left out.
    public var anyRarityWithVariant: CardVariant?
    /// Also every card of these subsets (a Trainer Gallery or Shiny Vault
    /// riding in this slot). Their rarity names repeat the main set's, so a
    /// rarity list could not single them out.
    public var wholeSetIDs: [String]?
    /// Only cards whose number starts with one of these (a subset numbered
    /// inside its set, such as Radiant Collection `RC1`…).
    public var localIDPrefixes: [String]?
    /// Never cards whose number starts with one of these.
    public var excludedLocalIDPrefixes: [String]?

    public init(
        rarities: [CardRarity],
        requiresVariant: CardVariant? = nil,
        setIDs: [String]? = nil,
        anyRarityWithVariant: CardVariant? = nil,
        wholeSetIDs: [String]? = nil,
        localIDPrefixes: [String]? = nil,
        excludedLocalIDPrefixes: [String]? = nil
    ) {
        self.rarities = rarities
        self.requiresVariant = requiresVariant
        self.setIDs = setIDs
        self.anyRarityWithVariant = anyRarityWithVariant
        self.wholeSetIDs = wholeSetIDs
        self.localIDPrefixes = localIDPrefixes
        self.excludedLocalIDPrefixes = excludedLocalIDPrefixes
    }

    public func matches(_ card: CardDefinition) -> Bool {
        guard rarities.contains(card.rarity) else { return false }
        guard let requiresVariant else { return true }
        return card.variants.contains(requiresVariant)
    }

    /// Membership with the set rules: `ruleSets` are the sets the rarity rule
    /// (and `anyRarityWithVariant`) applies to.
    func admits(_ card: CardDefinition, ruleSets: [String]) -> Bool {
        if wholeSetIDs?.contains(card.setID) == true { return true }
        guard ruleSets.contains(card.setID) else { return false }
        if let localIDPrefixes, !localIDPrefixes.contains(where: card.localID.hasPrefix) { return false }
        if let excludedLocalIDPrefixes, excludedLocalIDPrefixes.contains(where: card.localID.hasPrefix) { return false }
        if matches(card) { return true }
        if let anyRarityWithVariant { return card.variants.contains(anyRarityWithVariant) }
        return false
    }
}

/// Which print of the drawn card the slot produces.
public enum VariantRule: String, Sendable, Codable {
    /// Foil if the print is foil only, otherwise normal.
    case primary
    /// Always the reverse-holo print (slot pool guarantees availability).
    case reverse
    /// The second reverse-holo slot: reverse when the print has it, otherwise
    /// the foil print.
    case reverseIfAvailableElsePrimary
}

public struct RecipeSlot: Hashable, Sendable, Codable {
    public var count: Int
    public var selector: PoolSelector
    public var variantRule: VariantRule

    public init(count: Int, selector: PoolSelector, variantRule: VariantRule) {
        self.count = count
        self.selector = selector
        self.variantRule = variantRule
    }
}

public struct PackRecipe: Hashable, Sendable, Codable {
    public var recipeID: String
    public var version: Int
    public var setID: String
    public var packSize: Int
    public var duplicatesAllowed: Bool
    public var slots: [RecipeSlot]
    /// Stated in the app wherever a pack contents screen is shown: this is the
    /// app's own collation, not measured print odds.
    public var disclaimer: String
    public var evidence: [Evidence]

    public func pool(for slot: RecipeSlot, in catalog: PackCatalog) -> [CardDefinition] {
        let sets = slot.selector.setIDs ?? [setID]
        // Ordered by set, then number: for a one-set slot this is the order
        // every earlier recipe drew from, so stored packs replay unchanged.
        return catalog.cards
            .filter { slot.selector.admits($0, ruleSets: sets) }
            .sorted { ($0.setID, $0.localID) < ($1.setID, $1.localID) }
    }

    /// Every set the recipe can hand out cards from.
    public var setIDs: [String] {
        var result = [setID]
        for slot in slots {
            for id in (slot.selector.setIDs ?? []) + (slot.selector.wholeSetIDs ?? []) where !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }
}

public struct DrawnCard: Hashable, Sendable, Codable {
    public var position: Int
    public var slotIndex: Int
    public var cardKey: CardKey
    public var variant: CardVariant

    public init(position: Int, slotIndex: Int, cardKey: CardKey, variant: CardVariant) {
        self.position = position
        self.slotIndex = slotIndex
        self.cardKey = cardKey
        self.variant = variant
    }
}

public enum PackDrawer {
    /// Draws one pack worth of cards from a pinned recipe and catalogue.
    /// The result depends only on the recipe, the catalogue slice and `seed`,
    /// so a re-run with the same seed reproduces the pack exactly.
    public static func draw(
        recipe: PackRecipe,
        catalog: PackCatalog,
        seed: UInt64
    ) throws -> [DrawnCard] {
        var rng = SplitMix64(seed: seed)
        var drawn: [DrawnCard] = []
        var slotIndex = 0
        for slot in recipe.slots {
            let pool = recipe.pool(for: slot, in: catalog)
            guard !pool.isEmpty else {
                throw PackTraceError.poolEmpty(recipeID: recipe.recipeID, slotIndex: slotIndex)
            }
            for _ in 0..<slot.count {
                let card = pool[Int(rng.next(upperBound: UInt64(pool.count)))]
                let variant = try variant(for: card, rule: slot.variantRule)
                drawn.append(
                    DrawnCard(
                        position: drawn.count,
                        slotIndex: slotIndex,
                        cardKey: card.key,
                        variant: variant
                    )
                )
            }
            slotIndex += 1
        }
        guard drawn.count == recipe.packSize else {
            throw PackTraceError.recipeSizeMismatch(
                recipeID: recipe.recipeID,
                declared: recipe.packSize,
                actual: drawn.count
            )
        }
        return drawn
    }

    static func variant(for card: CardDefinition, rule: VariantRule) throws -> CardVariant {
        switch rule {
        case .primary:
            return card.primaryVariant
        case .reverse:
            guard card.variants.contains(.reverse) else {
                throw PackTraceError.variantUnavailable(cardKey: card.key, variant: .reverse)
            }
            return .reverse
        case .reverseIfAvailableElsePrimary:
            return card.variants.contains(.reverse) ? .reverse : card.primaryVariant
        }
    }
}
