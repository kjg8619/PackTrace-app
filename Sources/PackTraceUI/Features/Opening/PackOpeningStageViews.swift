import PackTraceCore
import SwiftUI

/// Backdrop for the opening scene. Kept separate so a later pass can add
/// per-set art or a rarity-driven backdrop without touching the stages.
struct OpeningBackground: View {
    var dimmed: Bool

    var body: some View {
        ZStack {
            Palette.backdrop
            RadialGradient(
                colors: [Palette.panelRaised.opacity(dimmed ? 0.28 : 0.55), Palette.backdrop],
                center: .center,
                startRadius: 40,
                endRadius: 420
            )
        }
        .animation(.easeInOut(duration: 0.25), value: dimmed)
        .ignoresSafeArea()
    }
}

/// Drives the wrapper's strain vibration while the hand is on it.
///
/// `@State` is not available in this toolchain, so the phase lives in a small
/// observable object and only ticks while a drag is in progress.
@MainActor
final class TearShakeModel: ObservableObject {
    @Published private(set) var phase: Double = 0
    private var task: Task<Void, Never>?

    func run(active: Bool) {
        task?.cancel()
        guard active else {
            phase = 0
            return
        }
        task = Task { [weak self] in
            var step = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                step += 0.22
                self.phase = step
            }
        }
    }

    deinit { task?.cancel() }
}

// MARK: - Pack

/// The sealed pack: entrance, readiness and the tear itself.
///
/// This is the only place that reacts to the tear gesture; everything it shows
/// comes from the engine's state, never from a draw.
struct PackDisplayView: View {
    @ObservedObject var engine: PackOpeningEngine
    var skipsAnimations: Bool

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var shake = TearShakeModel()

    private var isEntering: Bool { engine.state == .packEnter }
    private var isOpening: Bool { engine.state == .packOpening }
    private var wrapperGone: Bool {
        switch engine.state {
        case .idle, .packEnter, .packReady, .packOpening: false
        default: true
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            ZStack {
                PackWrapView(
                    product: engine.productForDisplay,
                    dragOffset: engine.dragOffset,
                    threshold: engine.tearThreshold,
                    cleared: wrapperGone,
                    stillSurface: skipsAnimations,
                    shakePhase: shake.phase
                )
                // Entrance: 0.88 → overshoot → settle, with a slight tilt.
                .scaleEffect(isEntering ? 0.88 : (isOpening ? 1.045 : 1))
                .opacity(isEntering ? 0 : 1)
                .offset(y: isEntering ? 24 : 0)
                .rotationEffect(.degrees(isEntering ? -0.8 : 0))
                .shadow(
                    color: .black.opacity(isEntering ? 0.18 : 0.42),
                    radius: isEntering ? 6 : 22,
                    y: isEntering ? 3 : 12
                )
                .gesture(tearGesture)
                .allowsHitTesting(engine.acceptsTearInput)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("미개봉 팩. 오른쪽으로 끌어 뜯거나 Space 키 또는 뜯기 버튼으로 엽니다.")
                .accessibilityAddTraits(.isButton)
                // VoiceOver and Switch Control cannot drag: the same tear, as an action.
                .accessibilityAction(named: "뜯기") {
                    if OpeningPrimaryAction.for(engine) == .tear { engine.tear() }
                }
            }
            .animation(enterAnimation, value: engine.state)
            .animation(openAnimation, value: isOpening)
            // Strain vibration only while the wrapper is actually being pulled.
            .task(id: pullKey) {
                await shake.run(active: engine.acceptsTearInput && engine.dragOffset > 0)
            }

            // The tear's progress and hints are in the HUD: drawn here, under the
            // pack, they sat in the HUD's own space, and dropping them when the
            // pack opened moved the pack down just as the cards began to rise.
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// ~520ms: fade, rise and a small overshoot settle.
    private var enterAnimation: Animation? {
        skipsAnimations ? nil : .spring(response: 0.5, dampingFraction: 0.66)
    }

    private var openAnimation: Animation? {
        skipsAnimations ? nil : .spring(response: 0.26, dampingFraction: 0.6)
    }

    private var pullKey: String {
        engine.acceptsTearInput && engine.dragOffset > 0 ? "pulling" : "idle"
    }

    private var tearGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard engine.acceptsTearInput else { return }
                let raw = value.translation.width + value.translation.height * 0.35
                engine.dragOffset = min(max(0, raw), engine.tearThreshold * 1.7)
                NSCursor.closedHand.set()
            }
            .onEnded { _ in
                guard engine.acceptsTearInput else { return }
                NSCursor.openHand.set()
                if engine.dragOffset >= engine.tearThreshold {
                    engine.tear()
                } else {
                    withAnimation(skipsAnimations ? nil : .spring(response: 0.34, dampingFraction: 0.7)) {
                        engine.dragOffset = 0
                    }
                }
            }
    }
}

// MARK: - Deck

/// How far the deck has come out of the pack.
///
/// `@State` is not available in this toolchain, so the progress lives in a small
/// observable object: the stage starts the rise when the cards come out and the
/// deck view only reads the value. Reduced motion jumps straight to the end, so
/// the bundle is simply in its place.
@MainActor
final class DeckRiseModel: ObservableObject {
    /// Starts settled: a resumed opening already has the bundle in its column, and
    /// the pack stage resets this to 0 long before a real rise needs it.
    @Published private(set) var progress: Double = 1

    /// Starts the rise from inside the pack. `instant` (reduced motion) puts the
    /// bundle in its column at once, without any movement.
    func rise(duration: Duration, instant: Bool) {
        guard !instant else {
            progress = 1
            return
        }
        progress = 0
        withAnimation(.easeOut(duration: duration.packTraceSeconds)) { progress = 1 }
    }

    /// The bundle is already out: a resumed opening, or a rise that ended.
    func settle() {
        progress = 1
    }

    func reset() {
        progress = 0
    }
}

/// The cards still inside the pack, drawn as a deck rather than a grid.
///
/// Only `CardDeckGeometry.maxVisibleDepth` backs are rendered: the rest would be
/// covered anyway, and this keeps ten cards cheap.
struct CardStackView: View {
    @ObservedObject var engine: PackOpeningEngine
    /// How far the bundle has come out of the pack: 0 hidden inside it, 1 in its
    /// own column. Owned by the stage, so it survives this view being rebuilt.
    @ObservedObject var deckRise: DeckRiseModel
    var skipsAnimations: Bool

    private var remaining: Int { max(engine.totalCards - engine.revealedCount, 0) }

    var body: some View {
        let depth = CardDeckGeometry.visibleDepth(remaining: remaining)
        let rise = CardDeckGeometry.rise(progress: deckRise.progress)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("팩 안 카드")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                BadgeView(text: "남은 \(remaining)장", color: remaining == 0 ? Palette.success : Palette.accent)
            }
            ZStack(alignment: .bottom) {
                if depth == 0 {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 150, height: 206)
                        .overlay(
                            Text("모두 공개했습니다")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inkMuted)
                        )
                } else {
                    ForEach(0..<depth, id: \.self) { layer in
                        CardBackView()
                            .frame(width: 150)
                            // One "unrevealed card" for the bundle, not one per layer.
                            .accessibilityHidden(layer > 0)
                            .offset(CardDeckGeometry.offset(forLayer: layer))
                            .rotationEffect(.degrees(CardDeckGeometry.rotation(forLayer: layer)))
                            .scaleEffect(CardDeckGeometry.scale(forLayer: layer))
                            .opacity(CardDeckGeometry.opacity(forLayer: layer))
                            .shadow(
                                color: .black.opacity(0.45),
                                radius: CardDeckGeometry.shadowRadius(forLayer: layer),
                                y: 6
                            )
                            .zIndex(Double(-layer))
                    }
                }
            }
            // Comes out of the pack as one object: the bundle starts behind the
            // wrapper, where the pack was, and climbs into its own column as the
            // wrapper falls away. The progress itself is animated by `deckRise`,
            // so reduced motion arrives here already at 1. Scaling before the
            // offset keeps the start distance exact: the other order would shrink
            // the travel along with the bundle.
            .scaleEffect(rise.scale, anchor: .bottom)
            .opacity(rise.opacity)
            .offset(x: CardDeckGeometry.riseTravelX(progress: deckRise.progress), y: rise.offsetY)
            .frame(width: 190, height: 300, alignment: .bottom)

            Text("공개 순서와 결과는 저장된 값입니다. 다시 열어도 같은 카드가 나옵니다.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 190, alignment: .leading)
        }
        .frame(width: 190)
    }
}

/// The cards already turned over, fanned on the side so progress is visible
/// without reading the counter.
struct RevealedStackView: View {
    @ObservedObject var engine: PackOpeningEngine
    var skipsAnimations: Bool
    /// The newest revealed card is in the spotlight (`SpotlightSubject`).
    var spotlightHoldsNewest: Bool

    var body: some View {
        let revealed = engine.revealedCards
        // The card being revealed stays in the spotlight — and so does one that is
        // still moving into the stack, or one held there with reduced motion — so
        // it is left out of the fan until it leaves it, and never drawn in two
        // places at once.
        let indices = RevealedStackGeometry.visibleIndices(
            revealedCount: revealed.count,
            isRevealing: spotlightHoldsNewest
        )
        let settled = indices.map { revealed[$0] }
        return VStack(alignment: .leading, spacing: 8) {
            Text("공개함 \(settled.count)장")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(settled.isEmpty ? Palette.inkMuted : Palette.ink)
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(settled.enumerated()), id: \.element.id) { index, card in
                    CardArtworkView(card: card.card, quality: .thumbnail, cornerRadius: 5)
                        .frame(width: 70)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Palette.rarityColor(card.rarity).opacity(0.6), lineWidth: 1)
                        )
                        .offset(RevealedStackGeometry.offset(forIndex: index, of: settled.count))
                        .rotationEffect(.degrees(RevealedStackGeometry.rotation(forIndex: index, of: settled.count)))
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                        .zIndex(Double(index))
                        .transition(skipsAnimations ? .identity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(width: 84, height: 130, alignment: .bottomLeading)
            .animation(skipsAnimations ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: settled.count)
            Spacer(minLength: 0)
        }
        .frame(width: 84, alignment: .topLeading)
    }
}

// MARK: - Flip

/// Turns one card over.
///
/// `turn` is animated by SwiftUI (it is the modifier's `animatableData`), and the
/// face shown is derived from the *interpolated* value, so the front can only
/// appear after the card has passed halfway. Nothing renders the front early.
struct CardFlip: AnimatableModifier {
    var turn: Double
    /// Built only once the card has passed the halfway point, so the front is
    /// never part of the view tree (or its accessibility tree) early.
    var front: () -> AnyView
    var back: () -> AnyView

    nonisolated var animatableData: Double {
        get { turn }
        set { turn = newValue }
    }

    func body(content: Content) -> some View {
        let phase = CardFlipPhase.from(turn: turn)
        return ZStack {
            if phase.showsFront {
                front()
            } else {
                back().rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(
            .degrees(phase.angleDegrees),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.35
        )
        .offset(y: phase.lift)
        .scaleEffect(phase.scale)
        .shadow(color: .black.opacity(phase.shadow), radius: 16, y: 8)
        .frame(width: 300)
    }
}

/// The one-shot band of light across a revealed front, clipped to the card.
///
/// An animatable modifier on purpose: the band's position and brightness are
/// functions of the progress, so they have to be evaluated on every frame of the
/// animation. Computed once from the end value instead, the band would be drawn
/// at its final, fully faded position and never be seen.
struct CardSweepBand: AnimatableModifier {
    var progress: Double
    /// Holographic tint for the top tier, plain light otherwise.
    var foil: Bool

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    static let foilColors: [Color] = [
        .clear,
        Color(red: 0.55, green: 0.85, blue: 1.0),
        Color(red: 1.0, green: 0.7, blue: 0.95),
        Color(red: 1.0, green: 0.95, blue: 0.6),
        .clear,
    ]

    /// Applied to the card image itself (`CardFaceView.sweep`), so the light
    /// stays on the print and off the name and rarity rows under it.
    func body(content: Content) -> some View {
        content.overlay {
            if RevealFX.isPlaying(progress) {
                band
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    private var band: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: foil ? Self.foilColors : [.clear, .white, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: CardLightSweep.width)
            // Taller than the card, so the tilted band's ends fall outside the
            // clip instead of showing as slanted edges across the print.
            .scaleEffect(x: 1, y: 1.6)
            .rotationEffect(.degrees(CardLightSweep.tilt))
            .offset(x: CardLightSweep.offsetX(progress: progress))
            .opacity(CardLightSweep.opacity(progress: progress, foil: foil))
            .blendMode(.plusLighter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sparkles around the spotlight and the halo behind it, from one progress.
///
/// Animatable for the same reason as `CardSweepBand`. Nothing is drawn outside
/// the play (progress 0 or 1), so a card that has none, or has finished, costs
/// nothing; at most `RevealFX.maxSparkles` images and one gradient are drawn.
struct RevealFXModifier: AnimatableModifier {
    var progress: Double
    var sparkles: [RevealFX.Sparkle]
    var burst: Bool
    var color: Color

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let playing = RevealFX.isPlaying(progress)
        return content
            .background {
                if playing, burst {
                    RadialGradient(
                        colors: [color.opacity(0.9), color.opacity(0.35), .clear],
                        center: .center,
                        startRadius: 30,
                        endRadius: 260
                    )
                    .frame(width: 520, height: 520)
                    .scaleEffect(RevealFX.burstScale(progress: progress))
                    .opacity(RevealFX.burstOpacity(progress: progress))
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if playing, !sparkles.isEmpty {
                    ZStack {
                        ForEach(Array(sparkles.enumerated()), id: \.offset) { _, sparkle in
                            Image(systemName: "sparkle")
                                .font(.system(size: sparkle.size, weight: .semibold))
                                .foregroundStyle(color.opacity(0.95))
                                .scaleEffect(RevealFX.sparkleScale(sparkle, progress: progress))
                                .opacity(RevealFX.sparkleOpacity(sparkle, progress: progress))
                                .offset(sparkle.offset)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

/// Holds the turn, the settle and the move for the card currently being revealed.
///
/// `@State` is not available in this toolchain, so the visual progress lives in
/// this small observable object rather than in the engine: the engine keeps the
/// semantic state (`card-revealing`) and this keeps the animation's own values.
/// The order is fixed — anticipation, flip, settle, transfer — so the card can
/// never start moving before its front is on screen.
@MainActor
final class CardRevealModel: ObservableObject {
    @Published private(set) var turn: Double = 1
    /// 0 while the front is in the spotlight, 1 once the card has reached its
    /// slot in the revealed stack.
    @Published private(set) var transferProgress: Double = 0
    /// True once the front is the face on screen. The flip's presentation crosses
    /// the halfway point at `flip / 2` (see `CardFlipPhase.showsFront`), so this
    /// marks the same moment the card turns over — and it is the only value the
    /// rarity effects, the accessibility label and the highlight key off.
    @Published private(set) var frontVisible = false
    @Published private(set) var anticipating = false
    /// 0…1 once across the card, for the top-tier highlight. Stays 0 until the
    /// turn has finished, so the light never crosses a card mid-flip.
    @Published private(set) var sweep: Double = 0
    /// 0…1 once, for the sparkles and the halo (`RevealFX`). Starts with the
    /// front, never before it, and never with reduced motion.
    @Published private(set) var fx: Double = 0

    private var task: Task<Void, Never>?

    /// Runs one card's reveal: the pause, the turn, the front, the highlight, the
    /// settle, then the move.
    func reveal(_ timeline: CardRevealTimeline, instant: Bool) {
        task?.cancel()
        turn = 1
        transferProgress = 0
        frontVisible = false
        sweep = 0
        fx = 0
        guard !instant else {
            // Reduced motion: the card is simply already face up. It stays in the
            // spotlight (the stage keeps it there until the next card), rather
            // than being put straight into the fan where it was never seen.
            turn = 0
            transferProgress = 0
            frontVisible = true
            anticipating = false
            return
        }
        anticipating = timeline.anticipation > .zero
        task = Task { [weak self] in
            if timeline.anticipation > .zero {
                try? await Task.sleep(for: timeline.anticipation)
                guard !Task.isCancelled else { return }
            }
            guard let self, !Task.isCancelled else { return }
            self.anticipating = false
            withAnimation(.easeInOut(duration: timeline.flip.packTraceSeconds)) {
                self.turn = 0
            }
            // The front is on screen from the halfway point of the turn.
            try? await Task.sleep(for: timeline.flip / 2)
            guard !Task.isCancelled else { return }
            self.frontVisible = true
            if timeline.fx > .zero {
                withAnimation(.easeOut(duration: timeline.fx.packTraceSeconds)) { self.fx = 1 }
            }
            // And the highlight waits for the turn to finish, so it reads as light
            // crossing a card that has already landed face up.
            try? await Task.sleep(for: timeline.flip / 2)
            guard !Task.isCancelled else { return }
            if timeline.sweep {
                self.playSweep()
            }
            // The front rests in the spotlight: the card only moves once the face
            // has been readable.
            try? await Task.sleep(for: timeline.settle)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: timeline.transfer.packTraceSeconds)) {
                self.transferProgress = 1
            }
        }
    }

    /// Single band of light across a top-tier front. One shot per card.
    private func playSweep() {
        sweep = 0
        withAnimation(.easeOut(duration: CardLightSweep.duration)) { sweep = 1 }
    }

    /// Back to face down, in the spotlight, for the next card.
    func reset() {
        task?.cancel()
        task = nil
        turn = 1
        transferProgress = 0
        frontVisible = false
        anticipating = false
        sweep = 0
        fx = 0
    }

    /// The values the stage may draw right now (see `RevealStagePhase`).
    func phase(isRevealing: Bool) -> RevealStagePhase {
        RevealStagePhase.make(
            isRevealing: isRevealing,
            turn: turn,
            transferProgress: transferProgress,
            frontVisible: frontVisible,
            anticipating: anticipating,
            sweep: sweep,
            fx: fx
        )
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

extension Duration {
    /// Seconds as a `Double`, for SwiftUI's animation curves.
    var packTraceSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The card in the spotlight.
///
/// `revealing` is the card turning over (and then moving into the stack);
/// `waiting` is the next one, shown face down so the spotlight always holds the
/// card the user is about to open — never a face that has not been earned.
struct CardRevealView: View {
    var subject: SpotlightSubject
    var timeline: CardRevealTimeline
    var skipsAnimations: Bool
    /// Owned by the stage, so the background and the effect layer can react to the
    /// same animation the card is playing.
    @ObservedObject var model: CardRevealModel

    private var card: PackOpeningCard? { subject.card }

    private var revealing: PackOpeningCard? {
        if case let .revealing(card) = subject { return card }
        return nil
    }

    private var key: String {
        switch subject {
        case let .revealing(card): "revealing-\(card.position)"
        case let .shown(card): "shown-\(card.position)"
        case let .waiting(card): "waiting-\(card.position)"
        case .empty: "empty"
        }
    }

    var body: some View {
        // A waiting card is face down whatever the model still holds from the
        // card before it; a card held with reduced motion is simply face up.
        let phase: RevealStagePhase = switch subject {
        case .revealing: model.phase(isRevealing: true)
        case .shown: .heldFront
        case .waiting, .empty: .faceDown
        }
        let transfer = CardTransferProgress(progress: phase.transferProgress)
        return VStack(spacing: 10) {
            ZStack {
                if let card {
                    Color.clear
                        .frame(width: 300, height: 412)
                        .modifier(
                            CardFlip(
                                turn: phase.turn,
                                front: { AnyView(frontFace(card, phase: phase)) },
                                back: { AnyView(backFace()) }
                            )
                        )
                        // The move into the stack happens outside the flip, so the
                        // turn keeps its own axis while the card travels. The
                        // shrink comes before the offset: an offset applied first
                        // would be scaled down with the card and the card would
                        // land short of the fan.
                        .scaleEffect(transfer.scale)
                        .rotationEffect(.degrees(transfer.rotation))
                        .opacity(transfer.opacity)
                        .offset(transfer.offset)
                        .id(card.position)
                        // One element whose label follows the face: a card that
                        // has not been turned over does not say what it is.
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            SpotlightAccessibility.label(
                                name: card.card.name,
                                rarity: card.rarity.displayName,
                                frontVisible: phase.frontVisible
                            )
                        )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 30))
                            .foregroundStyle(Palette.inkMuted)
                        Text("카드를 한 장씩 공개하세요")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .frame(width: 300, height: 412)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panel))
                }
            }
            .frame(width: 300, height: 412)
            // Halo behind the card and sparkles around it, played once from the
            // front appearing. They stay with the spotlight while the card
            // itself moves on to the stack.
            .modifier(fxModifier(phase: phase))
            .task(id: key) { await react() }
        }
        .frame(width: 320)
    }

    private func fxModifier(phase: RevealStagePhase) -> RevealFXModifier {
        let profile = revealing?.rarityProfile ?? RarityAnimationProfile.none
        let plan = RarityEffectPlan.make(
            profile: profile,
            frontVisible: phase.frontVisible,
            isAnticipating: phase.anticipating,
            animates: !skipsAnimations
        )
        return RevealFXModifier(
            progress: phase.fx,
            sparkles: RevealFX.sparkles(count: plan.sparkleCount),
            burst: plan.showsBurst,
            color: Palette.rarityColor(revealing?.rarity ?? CardRarity(rawValue: "Common"))
        )
    }

    private func react() async {
        if revealing != nil {
            model.reveal(timeline, instant: skipsAnimations)
        } else {
            // Waiting for the next card, holding the last one (reduced motion),
            // or an empty spotlight: nothing plays, so the model is at rest.
            model.reset()
        }
    }

    private func frontFace(_ card: PackOpeningCard, phase: RevealStagePhase) -> some View {
        // The thumbnail is warmed with the full image; if the full one is still
        // on its way, the front turns over onto the thumbnail, not a spinner.
        // The band rides with the face, so it cannot show before the turn; the
        // model clears it after each card.
        CardFaceView(
            card: card.card,
            variant: card.variant,
            quality: .full,
            fallbackQuality: .thumbnail,
            isNew: card.isNew,
            sweep: CardSweepBand(progress: phase.sweep, foil: card.rarityProfile.foilSweep)
        )
        .frame(width: 300)
    }

    private func backFace() -> some View {
        CardBackView()
            .frame(width: 300)
    }
}

/// Rarity glow and the pause before the turn, over the whole stage.
///
/// Kept light: two gradients, no particle system. The one-shot sparkles and the
/// halo sit with the spotlight card instead (`RevealFXModifier`).
///
/// Everything rarity-coloured goes through `RarityEffectPlan`, so the only thing
/// that decides whether a card may look special is `frontVisible`: while it waits
/// it gets the same neutral glow as every other card, and while it turns it gets
/// nothing rarity-specific until its face is the one on screen.
struct EffectLayerView: View {
    var profile: RarityAnimationProfile
    var glowColor: Color
    /// The front is on screen: only then may the card's own rarity show.
    var frontVisible: Bool
    /// Face down, being held before the turn.
    var isAnticipating: Bool
    var skipsAnimations: Bool

    private var plan: RarityEffectPlan {
        RarityEffectPlan.make(
            profile: profile,
            frontVisible: frontVisible,
            isAnticipating: isAnticipating,
            animates: !skipsAnimations
        )
    }

    var body: some View {
        let plan = plan
        return ZStack {
            if plan.showsAnticipation {
                RadialGradient(
                    colors: [
                        Palette.accent.opacity(Self.anticipationGlow),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 260
                )
                .transition(.opacity)
            }
            if plan.showsRarityGlow {
                RadialGradient(
                    colors: [
                        glowColor.opacity(profile.glow * 0.55),
                        Color.clear,
                    ],
                    center: .center,
                    startRadius: 20,
                    endRadius: 300
                )
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        // With reduced motion the glow simply is there or not.
        .animation(skipsAnimations ? nil : .easeOut(duration: 0.4), value: frontVisible)
        .animation(skipsAnimations ? nil : .easeInOut(duration: 0.25), value: isAnticipating)
    }

    /// One fixed strength, so every rarer card looks the same while it waits.
    static let anticipationGlow: Double = 0.2
}

// MARK: - HUD and summary

/// Progress, skip and the input hint.
struct OpeningHUDView: View {
    @ObservedObject var engine: PackOpeningEngine
    var skipsAnimations: Bool
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorMessage = engine.errorMessage {
                NoticeBanner(
                    title: "개봉 알림",
                    message: errorMessage,
                    color: Palette.danger,
                    icon: "exclamationmark.triangle"
                )
            }
            if engine.state == .summary || engine.state == .complete {
                HStack(spacing: 12) {
                    Text("공개 \(engine.revealedCount)/\(engine.totalCards)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Button("닫기") { onClose() }
                }
            } else {
                HStack(spacing: 12) {
                    if isSealed {
                        // Before the pack is open the bar follows the tear itself.
                        Text("뜯기")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        ProgressView(value: TearProgress.from(
                            dragOffset: engine.dragOffset,
                            threshold: engine.tearThreshold
                        ).progress)
                        .frame(maxWidth: 200)
                    } else {
                        Text("공개 \(engine.revealedCount)/\(engine.totalCards)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()
                        ProgressView(
                            value: Double(engine.revealedCount),
                            total: Double(max(engine.totalCards, 1))
                        )
                        .frame(maxWidth: 200)
                    }
                    Spacer(minLength: 0)
                    // Before the pack is open the main button tears it, so a
                    // single click opens a pack as well as a drag or a key does.
                    if engine.acceptsTearInput {
                        Button("팩 뜯기 (Space)") {
                            if OpeningPrimaryAction.for(engine) == .tear { engine.tear() }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("다음 카드 (Space)") { engine.advance() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!engine.acceptsAdvanceInput)
                    }
                    Button("모두 공개") { engine.skip() }
                        .disabled(!engine.acceptsSkipInput)
                }
                Text(instruction)
                    .font(.system(size: 11))
                    .foregroundStyle(engine.state == .packOpening ? Palette.accent : Palette.inkMuted)
            }
        }
        .padding(16)
    }

    /// The pack has not been opened yet (or is being saved as opened).
    private var isSealed: Bool {
        switch engine.state {
        case .idle, .packEnter, .packReady, .packOpening: true
        default: false
        }
    }

    private var instruction: String {
        switch engine.state {
        case .packReady:
            return "포장 상단을 잡고 오른쪽으로 \(Int(engine.tearThreshold))pt 넘게 끌어 뜯습니다(덜 끌면 원래대로). Space 키나 '팩 뜯기' 버튼으로도 뜯습니다."
        case .packOpening:
            return "개봉 결과를 저장하는 중입니다 · 저장이 끝나면 포장이 열립니다."
        case .cardsRise:
            return "카드 묶음이 올라오는 중입니다."
        case .cardWaiting:
            return skipsAnimations
                ? "Space 키로 다음 카드를 엽니다. 연출을 건너뛰어도 저장되는 결과는 같습니다."
                : "Space 키 또는 버튼으로 다음 카드를 한 장씩 엽니다."
        case .cardRevealing:
            return "카드를 넘기는 중입니다."
        case .idle, .packEnter:
            return "팩을 준비하는 중입니다."
        case .summary, .complete:
            return "저장된 결과입니다. 다시 열어도 같은 카드가 나옵니다."
        }
    }
}

/// Column/tile geometry for the summary grid.
///
/// Chooses the largest tile that keeps every card fully visible, preferring more
/// columns (shorter rows) when height is the binding constraint.
struct GridLayout: Equatable {
    static let spacing: CGFloat = 12
    /// Art (600×825) plus the name and rarity badges underneath.
    static let labelHeight: CGFloat = 38
    static let cardAspect: CGFloat = 825.0 / 600.0
    static let minTile: CGFloat = 88
    static let maxTile: CGFloat = 210

    var columns: Int
    var tile: CGFloat

    static func fitting(count: Int, in size: CGSize) -> GridLayout {
        guard count > 0, size.width > 0, size.height > 0 else {
            return GridLayout(columns: 1, tile: minTile)
        }
        var best = GridLayout(columns: 0, tile: 0)
        for columns in stride(from: min(maxColumns, count), through: 1, by: -1) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let byWidth = (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let rowHeight = (size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows)
            let byHeight = (rowHeight - labelHeight) / cardAspect
            let tile = min(byWidth, byHeight, maxTile)
            if tile >= minTile, tile > best.tile {
                best = GridLayout(columns: columns, tile: tile)
            }
        }
        if best.columns == 0 {
            // Space too small for the whole set: show the most columns that fit by
            // width and let the grid scroll.
            let columns = min(maxColumns, count)
            let tile = max(minTile, (size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            best = GridLayout(columns: columns, tile: tile)
        }
        return best
    }

    private static let maxColumns = 5
}

/// All obtained cards, shown once the reveal finishes.
struct OpeningSummaryView: View {
    @ObservedObject var engine: PackOpeningEngine
    var skipsAnimations: Bool
    var onShowBinder: () -> Void
    /// The preview never writes, so its cards are not in the binder.
    var showsBinderButton: Bool = true

    private var newCount: Int { engine.cards.filter(\.isNew).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.accentWarm)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("개봉 완료 · \(engine.totalCards)장 저장됨")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("새 카드 \(newCount)장 · 중복 \(engine.totalCards - newCount)장 · 바인더에 반영되었습니다")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                    if showsBinderButton {
                        Button("바인더에서 보기") { onShowBinder() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Text("미리보기 결과는 바인더에 반영되지 않습니다")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                    }
                }
            }
            // The grid takes the sheet's remaining height and fits the cards by
            // width, so all ten are visible without a fixed cap cutting the last
            // row in half. A smaller sheet still scrolls.
            GeometryReader { proxy in
                let layout = GridLayout.fitting(count: engine.cards.count, in: proxy.size)
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.fixed(layout.tile), spacing: GridLayout.spacing),
                            count: layout.columns
                        ),
                        spacing: GridLayout.spacing
                    ) {
                        ForEach(engine.cards) { card in
                            summaryTile(card)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(skipsAnimations ? .identity : .opacity)
    }

    private func summaryTile(_ card: PackOpeningCard) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CardArtworkView(card: card.card, quality: .thumbnail, cornerRadius: 6)
            Text(card.card.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            HStack(spacing: 3) {
                BadgeView(
                    text: card.rarity.displayName,
                    color: Palette.rarityColor(card.rarity)
                )
                if card.isNew {
                    BadgeView(text: "새 카드", color: Palette.success)
                }
            }
        }
    }
}

// MARK: - Stage host

/// The stage itself: observes the engine, so every state change redraws the
/// right stage, the effect layer and the HUD.
///
/// The rise, the reveal and the summary all come from the engine's state; the two
/// animation models (`deckRise`, `revealModel`) live here so the deck, the
/// spotlight, the background and the effect layer all read the same progress
/// while a card is playing.
struct PackOpeningStageHost: View {
    @ObservedObject var engine: PackOpeningEngine
    var skipsAnimations: Bool
    var onClose: () -> Void
    var onShowBinder: () -> Void
    var preload: (PackOpeningEngine) async -> Void

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var deckRise = DeckRiseModel()
    @StateObject private var revealModel = CardRevealModel()

    var body: some View {
        ZStack {
            OpeningBackground(dimmed: backgroundDimmed)
            Group {
                switch engine.state {
                case .idle, .packEnter, .packReady, .packOpening:
                    Color.clear
                case .cardsRise, .cardWaiting, .cardRevealing:
                    revealStage.transition(stageTransition)
                case .summary, .complete:
                    OpeningSummaryView(
                        engine: engine,
                        skipsAnimations: skipsAnimations,
                        onShowBinder: onShowBinder,
                        showsBinderButton: !engine.isPreview
                    )
                }
            }
            .animation(stageAnimation, value: engine.state.name)
            // Drawn over the reveal stage while the cards come out, so the bundle
            // rises from behind the pack and the wrapper can fall away in front of
            // it instead of the stage being swapped in one frame. It stays mounted
            // from the entrance to the rise, which is what keeps its own peel
            // animation running across the state change.
            if showsPackStage {
                PackDisplayView(engine: engine, skipsAnimations: skipsAnimations)
            }
            EffectLayerView(
                profile: spotlight.card?.rarityProfile ?? RarityAnimationProfile.none,
                glowColor: Palette.rarityColor(spotlight.card?.rarity ?? CardRarity(rawValue: "Common")),
                // A card held face up with reduced motion keeps its (static) glow.
                frontVisible: stagePhase.frontVisible || spotlight.isShown,
                isAnticipating: stagePhase.anticipating,
                skipsAnimations: skipsAnimations
            )
        }
        .overlay(alignment: .bottom) {
            OpeningHUDView(engine: engine, skipsAnimations: skipsAnimations, onClose: onClose)
        }
        // Warm the images the next cards need so a reveal never waits on the network.
        .task(id: engine.state.name) {
            // First, so the deck starts moving on the state change itself and not
            // after the image prefetch.
            syncAnimations()
            await preload(engine)
        }
    }

    /// The pack is on stage before it is opened and while the bundle comes out of
    /// it; after that the reveal has the stage to itself.
    private var showsPackStage: Bool {
        switch engine.state {
        case .idle, .packEnter, .packReady, .packOpening, .cardsRise: true
        case .cardWaiting, .cardRevealing, .summary, .complete: false
        }
    }

    /// The staged cross fades: the wrapper gives way while the deck rises, and the
    /// summary fades in over the last card instead of cutting to it.
    private var stageTransition: AnyTransition {
        skipsAnimations ? .identity : .opacity
    }

    private var stageAnimation: Animation? {
        skipsAnimations ? nil : .easeInOut(duration: engine.timing.summarySettle.packTraceSeconds)
    }

    /// Reduced motion: the backdrop is dimmed but never animated by the reveal.
    /// The rarity-driven dim also waits for the front: dimming harder while a card
    /// is still face down would say "this one is rare" before it turns.
    private var backgroundDimmed: Bool {
        if skipsAnimations { return false }
        return stagePhase.anticipating || (stagePhase.frontVisible && currentProfile.dimsBackground)
    }

    /// The reveal model as the current engine state allows it to be seen: while
    /// the next card waits, nothing of the previous card's front is left on stage.
    private var stagePhase: RevealStagePhase {
        revealModel.phase(isRevealing: engine.isRevealingCard)
    }

    private var spotlight: SpotlightSubject {
        SpotlightSubject.make(state: engine.state, cards: engine.cards, skipsAnimations: skipsAnimations)
    }

    private var currentProfile: RarityAnimationProfile {
        engine.currentCard?.rarityProfile ?? RarityAnimationProfile.none
    }

    /// Keeps the deck's rise in step with the engine's stage, so the bundle is
    /// never mid-flight when the state has already moved on, and drops any reveal
    /// animation that the stage it belonged to has left behind (skipping mid
    /// transfer, or closing the sheet).
    private func syncAnimations() {
        if !engine.isRevealingCard {
            revealModel.reset()
        }
        switch engine.state {
        case .cardsRise:
            deckRise.rise(duration: engine.timing.cardsRise, instant: skipsAnimations)
        case .cardWaiting, .cardRevealing, .summary, .complete:
            deckRise.settle()
        case .idle, .packEnter, .packReady, .packOpening:
            deckRise.reset()
        }
    }

    private var revealStage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 20) {
                RevealedStackView(
                    engine: engine,
                    skipsAnimations: skipsAnimations,
                    spotlightHoldsNewest: spotlight.holdsRevealedCard
                )
                CardRevealView(
                    subject: spotlight,
                    timeline: revealTimeline,
                    skipsAnimations: skipsAnimations,
                    model: revealModel
                )
                CardStackView(engine: engine, deckRise: deckRise, skipsAnimations: skipsAnimations)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }

    /// What the view will play for the current card, from the same numbers the
    /// engine waits on.
    private var revealTimeline: CardRevealTimeline {
        CardRevealTimeline.make(profile: currentProfile, timing: engine.timing)
    }
}
