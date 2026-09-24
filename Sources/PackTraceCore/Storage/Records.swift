import Foundation

public enum PackState: String, Sendable, Codable {
    case sealed
    case opened

    public var displayName: String {
        switch self {
        case .sealed: "미개봉"
        case .opened: "개봉됨"
        }
    }
}

public struct WalletLedgerEntry: Sendable, Hashable, Identifiable {
    public var id: WalletEntryID
    public var idempotencyKey: String
    public var deltaPoints: Int
    public var reason: WalletReason
    public var reference: String?
    public var createdAt: Date
}

/// One set as shown in the collection screens.
public struct SetSummary: Sendable, Hashable, Identifiable {
    public var id: String { setID }
    public var setID: String
    public var name: String
    public var cards: Int
    /// Prints the app collects for this set (primary + reverse where available).
    public var prints: Int

    public init(setID: String, name: String, cards: Int, prints: Int) {
        self.setID = setID
        self.name = name
        self.cards = cards
        self.prints = prints
    }
}

public struct PackInstanceRecord: Sendable, Hashable, Identifiable {
    public var id: PackInstanceID
    public var productID: String
    public var catalogVersion: String
    public var recipeVersion: Int
    /// Pool that produced this pack. `nil` for packs received before the pool
    /// existed (legacy); such a pack keeps its original product and recipe.
    public var poolVersion: String?
    public var acquiredAt: Date
    public var state: PackState
    public var exchangeEntryID: WalletEntryID
}

public struct OpeningRecord: Sendable, Hashable, Identifiable {
    public var id: OpeningID
    public var packInstanceID: PackInstanceID
    public var createdAt: Date
    public var completedAt: Date?
    public var revealedCount: Int
    public var cards: [DrawnCard]

    public var isComplete: Bool { revealedCount >= cards.count }
}

public struct OwnedCardRecord: Sendable, Hashable, Identifiable {
    public var id: OwnedCardID
    public var cardKey: CardKey
    public var variant: CardVariant
    public var openingID: OpeningID
    public var acquiredAt: Date
    public var setID: String
}

/// One row of the binder: a print plus how many copies the user owns.
public struct BinderEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(card.key.rawValue)#\(variant.rawValue)" }
    public var card: CardDefinition
    public var variant: CardVariant
    public var quantity: Int
    public var firstAcquiredAt: Date

    public var isOwned: Bool { quantity > 0 }
}

public struct ExchangeOutcome: Sendable, Hashable {
    public var packInstance: PackInstanceRecord
    public var ledgerEntry: WalletLedgerEntry
    public var balanceAfter: Int
    /// True when this call reused an earlier request instead of charging again.
    public var reusedExistingRequest: Bool
}

public struct BinderProgress: Sendable, Hashable {
    public var ownedUniquePrints: Int
    public var totalPrints: Int
    public var totalCopies: Int

    public init(ownedUniquePrints: Int, totalPrints: Int, totalCopies: Int) {
        self.ownedUniquePrints = ownedUniquePrints
        self.totalPrints = totalPrints
        self.totalCopies = totalCopies
    }
}
