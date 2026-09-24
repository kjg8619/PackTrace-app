import CoreGraphics
import Foundation
import PackTraceCore

/// Visual geometry for the opening scene.
///
/// These are pure functions of gesture/state values, kept out of the views so the
/// numbers behind the animation can be tested. The state machine stays semantic
/// (`PackOpeningEngine`); everything here is presentation only.

// MARK: - Tear

/// Where the wrapper is while the user drags it open.
///
/// `progress` is the clamped drag position; the strip, the pack body and the tear
/// edge are all derived from it, so the wrapper reacts to the hand and not to a
/// fixed animation.
struct TearProgress: Equatable {
    /// 0 (untouched) … 1 (threshold reached).
    var progress: Double

    static let threshold: CGFloat = 150

    static func from(dragOffset: CGFloat, threshold: CGFloat = threshold) -> TearProgress {
        guard threshold > 0 else { return TearProgress(progress: 0) }
        return TearProgress(progress: min(max(Double(dragOffset / threshold), 0), 1))
    }

    var hasPassedThreshold: Bool { progress >= 1 }

    /// The strip follows the hand, then keeps going as it leaves the pack.
    var stripTravel: CGFloat { CGFloat(progress) * 210 }

    /// A little rotation so the strip looks pulled, not translated.
    var stripRotation: Double { progress * 9 }

    /// The strip fades only as it actually leaves.
    var stripOpacity: Double { 1 - max(0, (progress - 0.55) / 0.45) * 0.35 }

    /// The pack body compresses slightly while being pulled.
    var bodySquash: Double { progress * 0.035 }

    /// The tear line gets brighter as it opens.
    var edgeHighlight: Double { 0.25 + progress * 0.75 }

    /// Foil band slides with the drag, so the surface looks alive.
    var foilShift: Double { progress * 0.6 }

    /// Tension in the last stretch before the tear: 0 until the wrapper is
    /// really being pulled, 1 at the threshold. Drives the shake and the
    /// brightening of the tear line.
    var tension: Double {
        let start = 0.78
        guard progress > start else { return 0 }
        return (progress - start) / (1 - start)
    }

    /// Small vibration near the threshold, in points. Bounded so it reads as
    /// strain rather than a broken layout.
    func shake(at phase: Double) -> CGFloat {
        guard tension > 0 else { return 0 }
        return CGFloat(sin(phase * 2 * .pi) * 2.2 * tension)
    }

    /// The wrapper body follows the hand a little, then springs back.
    var bodyFollow: Double { progress * 3 }

    /// Foil peel right after the wrapper gives way (0 before, 1 at the break).
    static func peel(cleared: Bool) -> Double { cleared ? 1 : 0 }
}

// MARK: - Flip

/// The state of one card turning over.
///
/// `turn` is a single 0…1 scalar: 0 is the front facing the viewer, 1 is the back.
/// Deriving both the angle and which face is visible from the same scalar is what
/// keeps the front from showing before the card has passed 90°.
struct CardFlipPhase: Equatable {
    /// 0 = front, 1 = back.
    var turn: Double

    static let back = CardFlipPhase(turn: 1)
    static let front = CardFlipPhase(turn: 0)

    static func from(turn: Double) -> CardFlipPhase {
        CardFlipPhase(turn: min(max(turn, 0), 1))
    }

    /// Above the halfway point only the back is drawn, below it only the front.
    var showsFront: Bool { turn <= 0.5 }

    var angleDegrees: Double { turn * 180 }

    /// The card lifts a little through the turn and settles back down.
    var lift: CGFloat { CGFloat(-14 * sin(Double.pi * turn)) }

    /// A short scale bump in the middle of the turn.
    var scale: CGFloat { 1 + CGFloat(sin(Double.pi * turn)) * 0.035 }

    /// Shadow grows through the turn and settles.
    var shadow: Double { 0.18 + sin(Double.pi * turn) * 0.22 }
}

// MARK: - Deck

/// Layer geometry for the stack of cards still inside the pack.
struct CardDeckGeometry: Equatable {
    /// At most this many backs are drawn: the rest would be hidden anyway.
    static let maxVisibleDepth = 4

    static func visibleDepth(remaining: Int) -> Int {
        min(max(remaining, 0), maxVisibleDepth)
    }

    /// Layer 0 is the top card. Layers step up and back to read as a stack.
    static func offset(forLayer layer: Int) -> CGSize {
        let step = CGFloat(clamped(layer))
        return CGSize(width: step * 3.5, height: step * -7)
    }

    static func rotation(forLayer layer: Int) -> Double {
        // Alternating, tiny: enough to see separate cards, not enough to look messy.
        let signs: [Double] = [0, 1.1, -0.8, 1.6]
        return signs[max(0, min(layer, signs.count - 1))]
    }

    static func scale(forLayer layer: Int) -> CGFloat {
        1 - CGFloat(clamped(layer)) * 0.018
    }

    static func shadowRadius(forLayer layer: Int) -> CGFloat {
        12 + CGFloat(clamped(layer)) * 3
    }

    /// Deeper layers sit very slightly back and dimmer. Subtle on purpose: the
    /// point is to read as separate cards in one bundle, not as a fan.
    static func opacity(forLayer layer: Int) -> Double {
        max(0.86, 1 - Double(clamped(layer)) * 0.045)
    }

    /// The whole bundle comes out of the pack as one object: `cards-rise` moves
    /// every layer together, so no card appears to rise on its own.
    ///
    /// The start depth keeps the bundle's bottom inside the pack's body. It was
    /// 96pt while the pack was drawn 46pt below its frame (`PackWrapView`); with
    /// the pack where its frame is, the same margin is 50pt.
    static let riseDepth: CGFloat = 50

    static func rise(progress: Double) -> (offsetY: CGFloat, scale: CGFloat, opacity: Double) {
        let t = min(max(progress, 0), 1)
        return (
            offsetY: (1 - CGFloat(t)) * riseDepth,
            scale: 0.94 + CGFloat(t) * 0.06,
            opacity: 0.25 + t * 0.75
        )
    }

    /// A layer index outside the visible range still produces safe geometry.
    private static func clamped(_ layer: Int) -> Int {
        max(0, min(layer, maxVisibleDepth))
    }

    /// Where the bundle comes out of the pack, in the stage's frame.
    ///
    /// The pack sits at the centre of the stage and the deck's column is right of
    /// centre, so the bundle starts `riseTravel` left of its slot — together with
    /// the layer offsets and the `rise(progress:)` lift, the bundle begins hidden
    /// behind the pack's body (its bottom lines up with the pack's) and climbs up
    /// into view as the wrapper falls away.
    static let riseTravel: CGFloat = -222

    /// Horizontal part of the rise: `-riseTravel` at 0, 0 once the bundle has
    /// reached its slot. Clamped, like `rise(progress:)`.
    static func riseTravelX(progress: Double) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return CGFloat(1 - t) * riseTravel
    }
}

/// A revealed card waiting on the side of the screen.
struct RevealedStackGeometry: Equatable {
    static let maxVisible = 5

    /// How many revealed cards are drawn (the rest are folded into the count).
    static func visibleCount(revealed: Int) -> Int {
        min(max(revealed, 0), maxVisible)
    }

    /// Older cards peek out from behind the newest one.
    static func offset(forIndex index: Int, of count: Int) -> CGSize {
        let fromTop = CGFloat(max(count - 1 - index, 0))
        return CGSize(width: fromTop * -4, height: fromTop * 3)
    }

    static func rotation(forIndex index: Int, of count: Int) -> Double {
        let fromTop = Double(max(count - 1 - index, 0))
        return fromTop * -2.2
    }

    /// Which revealed cards the stack draws, oldest first, so the last index is
    /// the card on top of the fan.
    ///
    /// The newest `maxVisible` settled cards are drawn, and while a card is still
    /// being revealed it is left out until it has finished moving, so the card in
    /// the spotlight is never also in the stack. Indices rather than cards: the
    /// selection is what is worth testing, and it needs no card fixtures.
    static func visibleIndices(revealedCount: Int, isRevealing: Bool) -> [Int] {
        let settled = max(revealedCount - (isRevealing ? 1 : 0), 0)
        let visible = visibleCount(revealed: settled)
        guard visible > 0 else { return [] }
        return Array((settled - visible)..<settled)
    }
}

/// Where a card sits between the spotlight and the revealed stack.
///
/// Sits next to `CardFlipPhase`: the flip owns the turn, this owns what happens
/// after it, so the view does not have to interpolate numbers itself. `progress`
/// 0 is the settled front in the spotlight, 1 is the card's slot in the stack —
/// the card shrinks to the size of a stack entry on the way over, so it lands
/// where the fan will draw it instead of flying off the side.
struct CardTransferProgress: Equatable {
    /// The newest stack entry relative to the spotlight's centre, in the reveal
    /// stage's own frame. The stack column sits left of and above the spotlight,
    /// by the width of the fan plus the row spacing, and up by the header the fan
    /// carries above its cards.
    static let stackOffset = CGSize(width: -230, height: -110)
    /// A stack entry is 70pt wide against the 300pt spotlight, so the card has to
    /// end at about that fraction.
    static let stackScale: CGFloat = 0.26

    let progress: Double

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    /// Eased so the card leaves the spotlight gently instead of snapping away.
    private var eased: Double {
        let t = clampedProgress
        return t * t * (3 - 2 * t)
    }

    var offset: CGSize {
        CGSize(
            width: Self.stackOffset.width * eased,
            height: Self.stackOffset.height * eased
        )
    }

    var scale: CGFloat {
        1 - CGFloat(eased) * (1 - Self.stackScale)
    }

    var rotation: Double {
        // A small tilt on the way over, then square in the stack.
        4.5 * sin(Double.pi * eased)
    }

    /// Just a hint of settling: the stack entry is drawn opaque.
    var opacity: Double {
        1 - eased * 0.06
    }
}

// MARK: - Reveal timeline

/// When each part of one card's reveal happens, for both the view and the engine.
///
/// The engine holds `card-revealing` open for `total` and the view plays the same
/// phases in the same order, so input is never accepted while a card is still
/// moving, and the state never advances past an animation that is still running.
/// Rarity only stretches the pad before and after the turn: the order never
/// changes, which is what reduced motion relies on.
struct CardRevealTimeline: Equatable {
    /// Held face down before the turn, for a rarer card.
    var anticipation: Duration
    /// The turn itself: back → edge → front.
    var flip: Duration
    /// The front rests in the spotlight, so the face is read before it leaves.
    var settle: Duration
    /// The card moves into the stack.
    var transfer: Duration
    /// Whether a top-tier front gets its one-shot highlight.
    var sweep: Bool
    /// How long the sparkles and the halo play, from the moment the front is on
    /// screen. Zero for tiers that have neither, and always over before the card
    /// starts moving to the stack.
    var fx: Duration = .zero
    /// The top tier's highlight is a holographic band rather than plain light.
    var foil: Bool = false

    /// Pacing from the card's own rarity, durations from the scene's timing.
    static func make(profile: RarityAnimationProfile, timing: PackOpeningTiming) -> CardRevealTimeline {
        guard !timing.isInstant else {
            return CardRevealTimeline(
                anticipation: .zero,
                flip: .zero,
                settle: .zero,
                transfer: .zero,
                sweep: false
            )
        }
        let settle = timing.cardSettle + profile.hold
        let hasFX = profile.sparkleCount > 0 || profile.burst
        return CardRevealTimeline(
            anticipation: profile.anticipation,
            flip: timing.cardFlip,
            settle: settle,
            transfer: timing.cardTransfer,
            sweep: profile.ultraSweep,
            // Starts when the front appears (half-way through the turn) and has
            // to be done by the time the card leaves: half the turn plus the
            // settle is all the room there is.
            fx: hasFX ? min(RevealFX.duration, timing.cardFlip / 2 + settle) : .zero,
            foil: profile.foilSweep
        )
    }

    var total: Duration { anticipation + flip + settle + transfer }
}

// MARK: - Pacing

extension RarityAnimationProfile {
    /// Pause before the card turns over: rarer cards are held longer so the
    /// moment lands. Small enough that ten commons still flow.
    var anticipation: Duration {
        switch Self.tier(for: rarity) {
        case 0, 1: .zero
        case 2, 3: .milliseconds(140)
        default: .milliseconds(320)
        }
    }

    /// Pause after the card has turned, before the next one is offered.
    var hold: Duration {
        switch Self.tier(for: rarity) {
        case 0, 1: .milliseconds(60)
        case 2, 3: .milliseconds(180)
        default: .milliseconds(340)
        }
    }

    /// Sparkles are only worth drawing from double rare up.
    var sparkles: Bool { sparkleCount > 0 }

    /// How many sparkles a revealed front gets: a few for a double rare, more as
    /// the tier rises, never more than `RevealFX.maxSparkles`.
    var sparkleCount: Int {
        switch Self.tier(for: rarity) {
        case 0, 1, 2: 0
        case 3: 4
        case 4: 6
        default: RevealFX.maxSparkles
        }
    }

    /// The short halo behind the card, for the top tier only.
    var burst: Bool {
        Self.tier(for: rarity) >= 5
    }

    /// The top tier's highlight carries a holographic tint.
    var foilSweep: Bool {
        Self.tier(for: rarity) >= 5
    }

    /// The one-shot highlight across the front is kept for the top tiers only:
    /// a band of light on every rare would read as noise.
    var ultraSweep: Bool {
        Self.tier(for: rarity) >= 4
    }

    /// Total time one reveal may take, so a pack cannot drag on.
    var revealBudget: Duration { anticipation + hold }

}

/// One highlight crossing a revealed card, once.
///
/// Pure geometry: `progress` 0 puts the band off the left edge, 1 off the right,
/// and the opacity peaks in the middle, so a single sweep reads as light passing
/// over the print rather than as a flash. Nothing here is rarity-specific — the
/// decision to play it at all lives on the profile.
enum CardLightSweep {
    static let width: CGFloat = 96
    static let tilt: Double = 14
    /// Brightest point of the band, before blending.
    static let peakOpacity: Double = 0.5
    /// How far the band travels: wide enough to clear the 300pt card on both sides.
    static let travel: CGFloat = 400
    /// How long the light takes to cross. Short enough to finish inside the hold
    /// of the tiers that get one, so the card is not still catching the light
    /// while it is on its way to the stack.
    static let duration: Double = 0.4

    static func offsetX(progress: Double) -> CGFloat {
        -travel / 2 + CGFloat(min(max(progress, 0), 1)) * travel
    }

    static func opacity(progress: Double) -> Double {
        sin(Double.pi * min(max(progress, 0), 1)) * peakOpacity
    }

    /// The holographic band is fainter than plain light, so it tints the print
    /// instead of washing it out.
    static let foilPeakOpacity: Double = 0.34

    static func opacity(progress: Double, foil: Bool) -> Double {
        let plain = opacity(progress: progress)
        return foil ? plain * foilPeakOpacity / peakOpacity : plain
    }
}

/// One-shot sparkles and halo around a revealed top-tier front.
///
/// Pure geometry, indexed and fixed: the same card always gets the same
/// sparkles in the same places, nothing is random, and nothing repeats — each
/// sparkle has one window inside `progress` 0…1 and is invisible outside it.
enum RevealFX {
    /// One play, from the front appearing. `CardRevealTimeline.fx` may shorten it
    /// so it ends before the card moves.
    static let duration: Duration = .milliseconds(550)
    /// Upper bound on sparkles for one card, so a reveal stays cheap to draw.
    static let maxSparkles = 8
    /// How much of the play one sparkle is visible for.
    static let sparkleWindow: Double = 0.5

    struct Sparkle: Equatable {
        /// From the spotlight card's centre (the card is 300×412).
        var offset: CGSize
        var size: CGFloat
        /// Where in 0…1 this sparkle's window opens.
        var start: Double
    }

    /// Around the card's edges, first the four corners so a double rare's four
    /// read as a frame, then the sides.
    private static let table: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [
        (-162, -150, 16), (158, -118, 12), (-150, 104, 12), (164, 72, 15),
        (-118, -218, 10), (104, 200, 12), (-64, 214, 10), (138, -212, 14),
    ]

    static func sparkles(count: Int) -> [Sparkle] {
        let n = min(max(count, 0), maxSparkles)
        return (0..<n).map { index in
            let entry = table[index]
            return Sparkle(
                offset: CGSize(width: entry.x, height: entry.y),
                size: entry.size,
                start: 0.06 * Double(index)
            )
        }
    }

    /// 0 outside the sparkle's window, one smooth rise and fall inside it.
    static func sparkleOpacity(_ sparkle: Sparkle, progress: Double) -> Double {
        let local = (min(max(progress, 0), 1) - sparkle.start) / sparkleWindow
        guard local > 0, local < 1 else { return 0 }
        return sin(Double.pi * local)
    }

    static func sparkleScale(_ sparkle: Sparkle, progress: Double) -> CGFloat {
        0.4 + CGFloat(sparkleOpacity(sparkle, progress: progress)) * 0.6
    }

    /// The halo grows from 0.75 to 1.2 of its size while it fades out.
    static func burstScale(progress: Double) -> CGFloat {
        let t = min(max(progress, 0), 1)
        return 0.75 + CGFloat(1 - (1 - t) * (1 - t)) * 0.45
    }

    /// Bright at once, then gone by the end: 0.45 → 0. Nothing is drawn before
    /// the play starts (see `isPlaying`).
    static func burstOpacity(progress: Double) -> Double {
        0.45 * (1 - min(max(progress, 0), 1))
    }

    /// Only strictly between the ends: at 0 it has not started, at 1 it is over.
    static func isPlaying(_ progress: Double) -> Bool {
        progress > 0 && progress < 1
    }
}

// MARK: - Image preload

/// Which card images to warm for the opening's current state.
///
/// The card in the spotlight is drawn at full size the moment its front turns
/// over (150 ms into the flip), and its thumbnail is what the revealed fan and
/// the summary use once it lands. As soon as the cards exist (the rise), every
/// remaining card's full image is asked for in reveal order, then the
/// thumbnails; each waiting card asks again for what is still missing (the
/// cache skips what it already has and joins what is in flight).
///
/// Measured on a cold cache, a full image took a median 273 ms to arrive when it
/// was first asked for at the turn, and up to ~1 s on a slow run — longer than a
/// card or two stays on stage, so warming only the next one or two was not
/// enough. The ten decoded full images (~2 MB each) are held by the image cache
/// either way once the opening has shown them.
enum OpeningImagePreload {
    static func requests(
        for state: PackOpeningEngine.State,
        cards: [PackOpeningCard],
        revealedCount: Int
    ) -> [ImageRequest] {
        let next: Int
        switch state {
        case .cardsRise: next = revealedCount
        case let .cardWaiting(nextIndex): next = nextIndex
        default: return []
        }
        let upcoming = cards.dropFirst(max(next, 0)).filter { CardImageURL.hasImage($0.card) }
        let full = upcoming.map { card -> ImageRequest in
            .remote(urlString: CardImageURL.url(for: card.card, quality: .full), quality: .full)
        }
        let thumbnails = upcoming.map { card -> ImageRequest in
            .remote(urlString: CardImageURL.url(for: card.card, quality: .thumbnail), quality: .thumbnail)
        }
        return full + thumbnails
    }
}

// MARK: - Spotlight

/// What the spotlight holds for the engine's state.
///
/// With motion, a revealed card plays its turn, rests, and moves into the fan
/// by itself. With reduced motion there is no such moment — the reveal is
/// instant and the engine is waiting for the next card straight away — so the
/// card revealed last stays face up in the spotlight until the next one, and
/// only then joins the fan. Without that, the only place a revealed card ever
/// appeared was the 70pt fan.
enum SpotlightSubject: Equatable {
    /// Being revealed: plays the turn (and, with motion, the move).
    case revealing(PackOpeningCard)
    /// Reduced motion: revealed last, face up and still until the next input.
    case shown(PackOpeningCard)
    /// The next card, face down.
    case waiting(PackOpeningCard)
    case empty

    static func make(
        state: PackOpeningEngine.State,
        cards: [PackOpeningCard],
        skipsAnimations: Bool
    ) -> SpotlightSubject {
        switch state {
        case let .cardRevealing(index):
            return cards.indices.contains(index) ? .revealing(cards[index]) : .empty
        case let .cardWaiting(next):
            if skipsAnimations, cards.indices.contains(next - 1) {
                return .shown(cards[next - 1])
            }
            return cards.indices.contains(next) ? .waiting(cards[next]) : .empty
        case .idle, .packEnter, .packReady, .packOpening, .cardsRise, .summary, .complete:
            return .empty
        }
    }

    var card: PackOpeningCard? {
        switch self {
        case let .revealing(card), let .shown(card), let .waiting(card): card
        case .empty: nil
        }
    }

    /// The newest revealed card is on stage, not in the fan: never drawn twice.
    var holdsRevealedCard: Bool {
        switch self {
        case .revealing, .shown: true
        case .waiting, .empty: false
        }
    }

    var isShown: Bool {
        if case .shown = self { return true }
        return false
    }
}
