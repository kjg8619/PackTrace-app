import Foundation
import PackTraceCore
import SwiftUI

/// Presentation-side view of one stored card.
///
/// The opening result is decided by the store before any animation runs; this
/// type only carries what a view needs to draw it. It is built once per opening
/// and never recomputed while the animation plays, so the visible result cannot
/// drift from the stored one.
public struct PackOpeningCard: Sendable, Hashable, Identifiable {
    public var id: Int { position }
    /// 0-based position in the pack, matching `DrawnCard.position`.
    public var position: Int
    public var card: CardDefinition
    public var variant: CardVariant
    /// First time this exact print is owned, for the "새 카드" badge.
    public var isNew: Bool

    public init(position: Int, card: CardDefinition, variant: CardVariant, isNew: Bool) {
        self.position = position
        self.card = card
        self.variant = variant
        self.isNew = isNew
    }

    public var rarity: CardRarity { card.rarity }
    public var rarityProfile: RarityAnimationProfile { RarityAnimationProfile(rarity: card.rarity) }
}

/// Everything the opening scene shows, derived from one stored opening.
///
/// `openingID` is nil for the development preview, which never touches a store.
public struct PackOpeningPresentation: Sendable {
    public var openingID: OpeningID?
    public var packID: PackInstanceID?
    public var productName: String
    public var catalogVersion: String
    public var recipeVersion: Int
    /// Artwork shown before the pack is opened (substitute art today).
    public var product: PackProduct?
    public var cards: [PackOpeningCard]
    /// Reveal progress already stored for this opening.
    public var revealedCount: Int
    public var isPreview: Bool

    public init(
        openingID: OpeningID?,
        packID: PackInstanceID?,
        productName: String,
        catalogVersion: String,
        recipeVersion: Int,
        product: PackProduct?,
        cards: [PackOpeningCard],
        revealedCount: Int,
        isPreview: Bool = false
    ) {
        self.openingID = openingID
        self.packID = packID
        self.productName = productName
        self.catalogVersion = catalogVersion
        self.recipeVersion = recipeVersion
        self.product = product
        self.cards = cards
        self.revealedCount = revealedCount
        self.isPreview = isPreview
    }

    public var isComplete: Bool { !cards.isEmpty && revealedCount >= cards.count }
}

/// Per-rarity knobs for the reveal.
///
/// The reveal uses `glow`, `dimsBackground` and the pacing in
/// `PackOpeningAnimation.swift` (anticipation, hold, sparkles). `soundKey`
/// overrides the tier's reveal sound (`revealSoundCue`); `particleKey` is still
/// only a seam.
public struct RarityAnimationProfile: Sendable, Hashable {
    public var rarity: CardRarity
    public var glow: Double
    public var dimsBackground: Bool
    /// Future hooks: asset keys, not behaviour.
    public var particleKey: String?
    public var soundKey: String?

    public init(
        rarity: CardRarity,
        glow: Double? = nil,
        dimsBackground: Bool? = nil,
        particleKey: String? = nil,
        soundKey: String? = nil
    ) {
        self.rarity = rarity
        let tier = Self.tier(for: rarity)
        self.glow = glow ?? Self.glow(for: tier)
        self.dimsBackground = dimsBackground ?? (tier >= 2)
        self.particleKey = particleKey
        self.soundKey = soundKey
    }

    public static let none = RarityAnimationProfile(
        rarity: CardRarity(rawValue: "Common"),
        glow: 0,
        dimsBackground: false
    )

    /// Animation tier for a rarity. Rarity values are source strings, so an
    /// unknown one falls back to how it prints (foil or not) instead of
    /// guessing a new tier.
    /// Animation tier of a rarity: 0 common … 5 hyper. Internal so the pacing
    /// extension and the reveal view agree on one table.
    static func tier(for rarity: CardRarity) -> Int {
        switch rarity.rawValue {
        case "Common": 0
        case "Uncommon": 1
        case "Rare": 2
        // One per deck, printed foil with its own frame (SV05–SV08).
        case "Double rare", "ACE SPEC Rare": 3
        case "Ultra Rare", "Illustration rare": 4
        case "Special illustration rare", "Hyper rare": 5
        // Earlier eras, by how rare the hit was in its own packs.
        case "Holo Rare", "Rare Holo": 2
        case "Rare Holo LV.X", "Rare PRIME", "LEGEND", "Holo Rare V", "Holo Rare VSTAR", "Amazing Rare", "Radiant Rare",
             "Shiny rare", "Classic Collection", "Pikachu Rare": 3
        case "Holo Rare VMAX", "Shiny rare V", "Shiny rare VMAX", "Shiny Ultra Rare", "Full Art Trainer", "Black White Rare",
             "Futuristic Rare": 4
        case "Secret Rare", "Mega Hyper Rare": 5
        default: rarity.isFoilByDefault ? 3 : 0
        }
    }

    static func glow(for tier: Int) -> Double {
        switch tier {
        case 0, 1: 0
        case 2, 3: 0.45
        default: 0.85
        }
    }
}

/// What the effect layer may draw for one card, from one phase value.
///
/// Every rarity-coloured effect hangs off `frontVisible` and nothing else, so a
/// card that is still face down — waiting, or turning, before it has passed the
/// halfway point — cannot show which tier it is. While it waits every card gets
/// the same neutral glow instead.
///
/// With motion reduced only the static glow is left: the tier is still shown,
/// nothing moves.
struct RarityEffectPlan: Equatable, Sendable {
    /// The neutral hold before the turn. Never rarity-coloured.
    var showsAnticipation: Bool
    /// The card's own glow, once its face is on screen.
    var showsRarityGlow: Bool
    var showsSparkles: Bool
    /// How many one-shot sparkles (0 when `showsSparkles` is false).
    var sparkleCount: Int = 0
    /// The one-shot halo behind the card, top tier only.
    var showsBurst: Bool = false

    static func make(
        profile: RarityAnimationProfile,
        frontVisible: Bool,
        isAnticipating: Bool,
        animates: Bool
    ) -> RarityEffectPlan {
        let moving = frontVisible && animates
        let sparkles = moving ? profile.sparkleCount : 0
        return RarityEffectPlan(
            showsAnticipation: isAnticipating,
            showsRarityGlow: frontVisible && profile.glow > 0,
            showsSparkles: sparkles > 0,
            sparkleCount: sparkles,
            showsBurst: moving && profile.burst
        )
    }
}

/// What the stage may take from `CardRevealModel` for the engine's current state.
///
/// The model's values belong to the card that was last revealed, and they are
/// only reset after the engine has already moved on. While no card is being
/// revealed the stage therefore reads a face-down card instead — so the next
/// card never borrows the previous one's turned-over front, glow or highlight,
/// not even for the one frame before the reset.
struct RevealStagePhase: Equatable, Sendable {
    var turn: Double
    var transferProgress: Double
    var frontVisible: Bool
    var anticipating: Bool
    var sweep: Double
    var fx: Double

    static let faceDown = RevealStagePhase(
        turn: 1,
        transferProgress: 0,
        frontVisible: false,
        anticipating: false,
        sweep: 0,
        fx: 0
    )

    /// Reduced motion's revealed card: face up, in the spotlight, not moving.
    static let heldFront = RevealStagePhase(
        turn: 0,
        transferProgress: 0,
        frontVisible: true,
        anticipating: false,
        sweep: 0,
        fx: 0
    )

    static func make(
        isRevealing: Bool,
        turn: Double,
        transferProgress: Double,
        frontVisible: Bool,
        anticipating: Bool,
        sweep: Double,
        fx: Double
    ) -> RevealStagePhase {
        guard isRevealing else { return .faceDown }
        return RevealStagePhase(
            turn: turn,
            transferProgress: transferProgress,
            frontVisible: frontVisible,
            anticipating: anticipating,
            sweep: sweep,
            fx: fx
        )
    }
}

/// What the spotlight reads out for the card on stage.
///
/// A card that has not been turned over must not announce what it is, in the same
/// way it does not draw its face: the label changes with the face, not with the
/// card the view happens to be holding.
enum SpotlightAccessibility {
    /// Face down: waiting for the turn, or on the back side of it.
    static let unrevealedLabel = "미공개 카드"

    static func label(name: String, rarity: String, frontVisible: Bool) -> String {
        frontVisible ? "\(name) \(rarity)" : unrevealedLabel
    }
}

/// Animation durations for the scene. `.instant` is used for reduced motion and
/// for tests that only care about the state sequence.
public struct PackOpeningTiming: Sendable, Hashable {
    /// True when every stage is immediate (reduced motion, tests).
    public var isInstant: Bool {
        packEnter == .zero && packShake == .zero && cardsRise == .zero
            && cardFlip == .zero && cardSettle == .zero && cardTransfer == .zero
            && summarySettle == .zero
    }

    public var packEnter: Duration
    public var packShake: Duration
    public var cardsRise: Duration
    public var cardFlip: Duration
    /// The revealed front rests in the spotlight before it moves. Rarity adds its
    /// own `hold` on top (see `CardRevealTimeline`).
    public var cardSettle: Duration
    /// The card's move from the spotlight into the revealed stack.
    public var cardTransfer: Duration
    /// Beat between the last card landing and the summary.
    public var summarySettle: Duration

    public init(
        packEnter: Duration,
        packShake: Duration,
        cardsRise: Duration,
        cardFlip: Duration,
        cardSettle: Duration,
        cardTransfer: Duration,
        summarySettle: Duration
    ) {
        self.packEnter = packEnter
        self.packShake = packShake
        self.cardsRise = cardsRise
        self.cardFlip = cardFlip
        self.cardSettle = cardSettle
        self.cardTransfer = cardTransfer
        self.summarySettle = summarySettle
    }

    /// Roughly 400–700ms for the pack's entrance, as specified. One common card
    /// takes about 650ms end to end, so ten of them still flow.
    public static let standard = PackOpeningTiming(
        packEnter: .milliseconds(520),
        packShake: .milliseconds(220),
        cardsRise: .milliseconds(420),
        cardFlip: .milliseconds(300),
        cardSettle: .milliseconds(90),
        cardTransfer: .milliseconds(200),
        summarySettle: .milliseconds(160)
    )

    public static let instant = PackOpeningTiming(
        packEnter: .zero,
        packShake: .zero,
        cardsRise: .zero,
        cardFlip: .zero,
        cardSettle: .zero,
        cardTransfer: .zero,
        summarySettle: .zero
    )
}
