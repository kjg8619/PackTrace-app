import Foundation
import PackTraceCore
import SwiftUI

/// The opening animation's state machine.
///
/// It owns only ephemeral presentation state (which stage is on screen, how far
/// the pack has been dragged, which card is flipping). The cards themselves come
/// from the stored opening, are handed in once, and are never re-drawn here: the
/// store commits the result before the scene starts, so skipping, closing the
/// sheet or quitting the app cannot change what was obtained.
///
/// Input is accepted per state, so held keys, double clicks and repeated taps
/// cannot skip a card or land on the summary twice.
@MainActor
public final class PackOpeningEngine: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle
        case packEnter
        case packReady
        case packOpening
        case cardsRise
        case cardWaiting(nextIndex: Int)
        case cardRevealing(index: Int)
        case summary
        case complete

        /// Names used for state logging and tests.
        public var name: String {
            switch self {
            case .idle: "idle"
            case .packEnter: "pack-enter"
            case .packReady: "pack-ready"
            case .packOpening: "pack-opening"
            case .cardsRise: "cards-rise"
            case .cardWaiting: "card-waiting"
            case .cardRevealing: "card-revealing"
            case .summary: "summary"
            case .complete: "complete"
            }
        }
    }

    // MARK: - Published state

    @Published public private(set) var state: State = .idle
    @Published public private(set) var cards: [PackOpeningCard]
    @Published public private(set) var revealedCount: Int
    @Published public private(set) var errorMessage: String?
    /// Tear gesture position. Ephemeral, never persisted.
    @Published public var dragOffset: CGFloat = 0

    public let tearThreshold: CGFloat = 150
    public let timing: PackOpeningTiming
    public let isPreview: Bool

    // MARK: - Dependencies

    private let productName: String
    private let catalogVersion: String
    private let recipeVersion: Int
    private let product: PackProduct?
    /// Domain call that commits the draw; nil for the preview.
    private let openPack: (() async -> OpeningRecord?)?
    /// Turns the committed result into cards the views can draw.
    private let resolveCards: (OpeningRecord) async -> [PackOpeningCard]
    private var reveal: PackOpeningRevealing
    /// A sealed pack has no opening yet, so the real sink is created right after
    /// the draw commits.
    private let revealAfterOpen: ((OpeningRecord) -> PackOpeningRevealing)?

    /// Delay hook. Tests replace it to hold a state open and observe the input
    /// lock; the product uses real sleeps.
    var sleep: (Duration) async -> Void = { duration in
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }
    /// Called on every transition; used by tests to record the sequence.
    var onStateChange: ((State) -> Void)?

    private var work: Task<Void, Never>?
    private var opener: Task<Void, Never>?

    public init(
        presentation: PackOpeningPresentation,
        openPack: (() async -> OpeningRecord?)? = nil,
        resolveCards: @escaping (OpeningRecord) async -> [PackOpeningCard],
        reveal: PackOpeningRevealing,
        revealAfterOpen: ((OpeningRecord) -> PackOpeningRevealing)? = nil,
        timing: PackOpeningTiming
    ) {
        self.cards = presentation.cards
        self.revealedCount = presentation.revealedCount
        self.productName = presentation.productName
        self.catalogVersion = presentation.catalogVersion
        self.recipeVersion = presentation.recipeVersion
        self.product = presentation.product
        self.isPreview = presentation.isPreview
        self.openPack = openPack
        self.resolveCards = resolveCards
        self.reveal = reveal
        self.revealAfterOpen = revealAfterOpen
        self.timing = timing
    }

    // MARK: - Derived values for the views

    public var productForDisplay: PackProduct? { product }
    public var displayName: String { productName }
    public var displayCatalogVersion: String { catalogVersion }
    public var displayRecipeVersion: Int { recipeVersion }
    public var totalCards: Int { cards.count }
    public var isComplete: Bool { state == .complete }

    /// The card currently being revealed, or the next one waiting to be.
    public var currentIndex: Int? {
        switch state {
        case let .cardRevealing(index): index
        case let .cardWaiting(nextIndex): nextIndex < cards.count ? nextIndex : nil
        default: nil
        }
    }

    public var currentCard: PackOpeningCard? {
        guard let currentIndex, cards.indices.contains(currentIndex) else { return nil }
        return cards[currentIndex]
    }

    public var revealedCards: [PackOpeningCard] {
        Array(cards.prefix(min(revealedCount, cards.count)))
    }

    /// The card currently turning over, if any. While a card is waiting this is
    /// nil on purpose: the spotlight shows the *next* card's back through
    /// `currentCard`, and no face is drawn until it has been earned.
    public var revealingCard: PackOpeningCard? {
        isRevealingCard ? currentCard : nil
    }

    public var hasPendingWork: Bool { work != nil || opener != nil }

    public var isRevealingCard: Bool {
        if case .cardRevealing = state { return true }
        return false
    }

    /// True while a stage is playing, so the views can disable their buttons.
    public var isBusy: Bool {
        switch state {
        case .packEnter, .packOpening, .cardsRise, .cardRevealing: true
        default: false
        }
    }

    public var acceptsTearInput: Bool {
        state == .packReady
    }

    public var acceptsAdvanceInput: Bool {
        if case .cardWaiting = state { return true }
        return false
    }

    /// Skipping needs cards to reveal: before the draw there is nothing to show.
    public var acceptsSkipInput: Bool {
        guard !cards.isEmpty else { return false }
        switch state {
        case .complete, .summary: return false
        default: return true
        }
    }

    // MARK: - Lifecycle

    /// Entry point: either resumes an opening that already has cards, or runs the
    /// pack's entrance and waits for the user to tear it.
    public func start() {
        guard state == .idle else { return }
        if !cards.isEmpty, revealedCount > 0 {
            // Resuming: the draw already happened, so go straight to the reveal.
            transition(revealedCount >= cards.count ? .summary : .cardWaiting(nextIndex: revealedCount))
            return
        }
        transition(.packEnter)
        run { [weak self] in
            guard let self else { return }
            await self.sleep(self.timing.packEnter)
            guard !Task.isCancelled else { return }
            self.transition(.packReady)
        }
    }

    /// Opens the pack: commits the draw, then raises the card stack.
    public func tear() {
        guard acceptsTearInput else { return }
        transition(.packOpening)
        opener = Task { [weak self] in
            guard let self else { return }
            defer { self.opener = nil }
            await self.sleep(self.timing.packShake)
            guard !Task.isCancelled else { return }

            if let openPack = self.openPack {
                guard let record = await openPack() else {
                    self.failAndReturnToSealed()
                    return
                }
                guard !Task.isCancelled else { return }
                let resolved = await self.resolveCards(record)
                guard !Task.isCancelled else { return }
                if let revealAfterOpen = self.revealAfterOpen {
                    self.reveal = revealAfterOpen(record)
                }
                self.cards = resolved
                self.revealedCount = record.revealedCount
            }
            guard !Task.isCancelled else { return }

            if self.cards.isEmpty {
                // Nothing to reveal: an empty result must not strand the scene.
                self.transition(.summary)
                return
            }
            self.transition(.cardsRise)
            await self.sleep(self.timing.cardsRise)
            guard !Task.isCancelled, self.state == .cardsRise else { return }
            self.transition(.cardWaiting(nextIndex: self.revealedCount))
        }
    }

    /// Reveals the next card. Ignored while a reveal is playing.
    public func advance() {
        guard acceptsAdvanceInput, let index = currentIndex, index < cards.count else { return }
        let target = index + 1
        transition(.cardRevealing(index: index))
        run { [weak self] in
            guard let self else { return }
            let stored = await self.reveal.reveal(upTo: target)
            guard !Task.isCancelled else { return }
            if !stored {
                self.errorMessage = "공개 진행도를 저장하지 못했습니다. 저장된 위치에서 다시 이어갑니다."
                self.transition(.cardWaiting(nextIndex: self.revealedCount))
                return
            }
            self.revealedCount = target
            // The front is held, then the card moves into the stack. The wait is
            // the view's own timeline (`CardRevealTimeline`), so the state cannot
            // advance past an animation that is still running — and reduced
            // motion keeps the order while dropping the padding.
            let timeline = CardRevealTimeline.make(
                profile: self.cards[index].rarityProfile,
                timing: self.timing
            )
            await self.sleep(timeline.total)
            guard !Task.isCancelled, self.state == .cardRevealing(index: index) else { return }
            let isLast = target >= self.cards.count
            if isLast {
                // The last card lands in the stack before the summary replaces
                // the stage, so the reveal is never cut off.
                await self.sleep(self.timing.summarySettle)
                guard !Task.isCancelled, self.state == .cardRevealing(index: index) else { return }
            }
            self.transition(isLast ? .summary : .cardWaiting(nextIndex: target))
        }
    }

    /// Shows every remaining card at once and goes to the summary.
    public func revealAll() {
        guard acceptsSkipInput else { return }
        // Cancel both the reveal task and the pack-opening task: skipping during
        // the rise must not let the opener move the state out of the summary.
        work?.cancel()
        work = nil
        opener?.cancel()
        opener = nil
        let target = cards.count
        transition(.summary)
        run { [weak self] in
            guard let self else { return }
            let stored = await self.reveal.reveal(upTo: target)
            guard !Task.isCancelled else { return }
            if stored {
                self.revealedCount = target
            } else {
                // The stored progress stays the truth; go back to it rather than
                // showing cards the profile thinks are still hidden.
                self.errorMessage = "공개 진행도를 저장하지 못했습니다. 저장된 위치에서 다시 이어갑니다."
                self.transition(.cardWaiting(nextIndex: min(self.revealedCount, self.cards.count)))
            }
        }
    }

    /// Cancels whatever is playing and jumps to the summary. Storage is not
    /// touched beyond marking the remaining cards as revealed.
    public func skip() {
        guard acceptsSkipInput else { return }
        revealAll()
    }

    /// Summary → complete, once the result has been seen.
    public func finishSummary() {
        guard state == .summary else { return }
        transition(.complete)
    }

    /// Cancels pending work. Called when the sheet goes away so no timer or task
    /// outlives the scene.
    public func cancelAll() {
        work?.cancel()
        opener?.cancel()
        work = nil
        opener = nil
    }

    deinit {
        work?.cancel()
        opener?.cancel()
    }

    // MARK: - Internals

    private func run(_ body: @escaping @MainActor () async -> Void) {
        work?.cancel()
        work = Task { [weak self] in
            await body()
            guard let self, !Task.isCancelled else { return }
            self.work = nil
        }
    }

    private func failAndReturnToSealed() {
        errorMessage = "개봉 결과를 저장하지 못해 팩을 미개봉으로 되돌렸습니다."
        dragOffset = 0
        transition(.packReady)
    }

    private func transition(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}

/// What the one primary input — Space/Return, the HUD's main button, the
/// accessibility action — does in each state.
///
/// One table for all of them, so a click, a key and VoiceOver can never
/// disagree, and a state that is playing accepts none of them.
public enum OpeningPrimaryAction: Equatable, Sendable {
    case tear
    case advance
    case close
    case none

    static func `for`(_ state: PackOpeningEngine.State, acceptsTear: Bool, acceptsAdvance: Bool) -> OpeningPrimaryAction {
        if acceptsTear { return .tear }
        if acceptsAdvance { return .advance }
        if state == .summary || state == .complete { return .close }
        return .none
    }

    @MainActor
    static func `for`(_ engine: PackOpeningEngine) -> OpeningPrimaryAction {
        self.for(engine.state, acceptsTear: engine.acceptsTearInput, acceptsAdvance: engine.acceptsAdvanceInput)
    }
}
