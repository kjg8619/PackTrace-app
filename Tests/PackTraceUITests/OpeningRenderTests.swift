import AppKit
import Foundation
import PackTraceTestSupport
import SwiftUI
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The primary input table, the autoplay safety rule, and offscreen renders of
/// the opening's representative moments.
///
/// The renders use the real views with a synthetic preview result in a
/// throwaway demo profile; nothing reads or writes a real collection. They check
/// that every stage builds and draws something at the sheet's size — not taste.
/// With `PACKTRACE_RENDER_PROBE_DIR` set, the same frames are written as PNGs
/// for looking at by eye (`RenderProbeTests`).
@Suite("개봉 장면 렌더와 입력 규칙")
@MainActor
struct OpeningRenderTests {
    // MARK: - Input

    @Test("클릭·키·접근성은 같은 주 동작 표를 따른다")
    func primaryActionTable() {
        typealias State = PackOpeningEngine.State
        #expect(OpeningPrimaryAction.for(.packReady, acceptsTear: true, acceptsAdvance: false) == .tear)
        #expect(OpeningPrimaryAction.for(.cardWaiting(nextIndex: 2), acceptsTear: false, acceptsAdvance: true) == .advance)
        #expect(OpeningPrimaryAction.for(.summary, acceptsTear: false, acceptsAdvance: false) == .close)
        #expect(OpeningPrimaryAction.for(.complete, acceptsTear: false, acceptsAdvance: false) == .close)
        // Anything playing takes no input, so a held key or a double click
        // cannot skip a stage.
        for playing: State in [.idle, .packEnter, .packOpening, .cardsRise, .cardRevealing(index: 1)] {
            #expect(OpeningPrimaryAction.for(playing, acceptsTear: false, acceptsAdvance: false) == .none, "\(playing.name)")
        }
    }

    @Test("자동 재생은 미리보기 결과 + 두 플래그일 때만이고, 저장된 팩에서는 절대 켜지지 않는다")
    func autoplayOnlyForThePreview() {
        let both = [PackOpeningPreview.environmentKey: "1", PackOpeningPreview.autoplayEnvironmentKey: "1"]
        #expect(PackOpeningPreview.autoplayAllowed(isPreviewSource: true, environment: both))
        #expect(PackOpeningPreview.autoplayAllowed(
            isPreviewSource: true,
            environment: [PackOpeningPreview.autoplayEnvironmentKey: "1"]
        ) == false, "자동 재생 플래그만으로는 켜지지 않습니다")
        #expect(PackOpeningPreview.autoplayAllowed(
            isPreviewSource: true,
            environment: [PackOpeningPreview.environmentKey: "1"]
        ) == false, "미리보기 플래그만으로는 켜지지 않습니다")
        #expect(PackOpeningPreview.autoplayAllowed(isPreviewSource: false, environment: both) == false,
                "저장된 팩은 어떤 환경에서도 스스로 열리지 않습니다")
    }

    // MARK: - Spotlight

    @Test("무대 규칙: 모션 줄이기에서는 방금 공개한 카드를 앞면으로 붙잡고, 모션이 있으면 다음 카드 뒷면을 둔다")
    func spotlightHoldsTheRevealedCardWithReducedMotion() throws {
        let library = try CatalogLoader.bundledLibrary()
        let result = try #require(PackOpeningPreview.makeResult(library: library))
        let cards = result.cards.compactMap { entry -> PackOpeningCard? in
            guard let card = library.card(for: entry.cardKey) else { return nil }
            return PackOpeningCard(position: entry.position, card: card, variant: entry.variant, isNew: entry.isNew)
        }
        typealias S = SpotlightSubject
        // Nothing revealed yet: the first card's back, either way.
        #expect(S.make(state: .cardWaiting(nextIndex: 0), cards: cards, skipsAnimations: true) == .waiting(cards[0]))
        #expect(S.make(state: .cardWaiting(nextIndex: 0), cards: cards, skipsAnimations: false) == .waiting(cards[0]))
        // After three cards: reduced motion keeps the third face up; motion has
        // already moved it into the fan and offers the fourth.
        #expect(S.make(state: .cardWaiting(nextIndex: 3), cards: cards, skipsAnimations: true) == .shown(cards[2]))
        #expect(S.make(state: .cardWaiting(nextIndex: 3), cards: cards, skipsAnimations: false) == .waiting(cards[3]))
        #expect(S.make(state: .cardRevealing(index: 4), cards: cards, skipsAnimations: true) == .revealing(cards[4]))
        #expect(S.make(state: .summary, cards: cards, skipsAnimations: true) == .empty)
        // The held card is on stage, so the fan leaves it out: never drawn twice.
        #expect(S.shown(cards[2]).holdsRevealedCard)
        #expect(S.waiting(cards[3]).holdsRevealedCard == false)
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 3, isRevealing: true) == [0, 1])
    }

    // MARK: - Frames

    /// Holds every non-zero engine delay until the test lets it go, so the
    /// scene can be stopped in each state.
    @MainActor
    final class Holds {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var pending: Int { waiters.count }

        func wait() async {
            await withCheckedContinuation { waiters.append($0) }
        }

        func releaseOne() {
            guard !waiters.isEmpty else { return }
            waiters.removeFirst().resume()
        }
    }

    /// One moment, rendered the moment the scene reaches it: the stage reads the
    /// live engine, so a view kept for later would show whatever state the
    /// engine had moved on to by then.
    struct Frame {
        var name: String
        var image: CGImage
    }

    static func render(_ view: AnyView, scale: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try #require(renderer.cgImage)
    }

    static let stageSize = CGSize(width: 780, height: 585)

    private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// The representative moments, in order. `environment` supplies the image
    /// cache the card views read from (a throwaway demo profile).
    static func frames(environment: AppEnvironment, scale: CGFloat = 1) async throws -> [Frame] {
        let library = try CatalogLoader.bundledLibrary()
        let result = try #require(PackOpeningPreview.makeResult(library: library))
        let cards = result.cards.compactMap { entry -> PackOpeningCard? in
            guard let card = library.card(for: entry.cardKey) else { return nil }
            return PackOpeningCard(position: entry.position, card: card, variant: entry.variant, isNew: entry.isNew)
        }
        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: nil,
                productName: result.product?.name ?? "미리보기",
                catalogVersion: result.catalogVersion,
                recipeVersion: result.recipeVersion,
                product: result.product,
                cards: cards,
                revealedCount: 0,
                isPreview: true
            ),
            openPack: nil,
            resolveCards: { _ in cards },
            reveal: PreviewOpeningReveal(total: cards.count),
            timing: .standard
        )
        let holds = Holds()
        engine.sleep = { duration in
            guard duration > .zero else { return }
            await holds.wait()
        }

        func stage() -> AnyView {
            AnyView(
                PackOpeningStageHost(
                    engine: engine,
                    skipsAnimations: false,
                    onClose: {},
                    onShowBinder: {},
                    preload: { _ in }
                )
                .environmentObject(environment)
                .frame(width: stageSize.width, height: stageSize.height)
            )
        }
        func onStage<V: View>(_ view: V) -> AnyView {
            AnyView(
                ZStack {
                    OpeningBackground(dimmed: false)
                    view
                }
                .environmentObject(environment)
                .frame(width: stageSize.width, height: stageSize.height)
            )
        }
        func card(_ rarity: String) throws -> PackOpeningCard {
            try #require(cards.first { $0.rarity.rawValue == rarity }, "미리보기에 \(rarity) 카드가 있어야 합니다")
        }
        func card(tier: Int) throws -> PackOpeningCard {
            try #require(cards.first { RarityAnimationProfile.tier(for: $0.rarity) == tier }, "미리보기에 \(tier)단계 카드가 있어야 합니다")
        }

        var frames: [Frame] = []
        func capture(_ name: String, _ view: AnyView) throws {
            frames.append(Frame(name: name, image: try render(view, scale: scale)))
        }

        engine.start()
        await waitUntil { holds.pending == 1 }
        holds.releaseOne()
        await waitUntil { engine.state == .packReady }
        try capture("01-pack-ready", stage())

        // The bundle's rise, from inside the pack to its column.
        let hidden = DeckRiseModel()
        hidden.reset()
        let settled = DeckRiseModel()
        engine.tear()
        await waitUntil { holds.pending == 1 }
        holds.releaseOne()
        await waitUntil { engine.state == .cardsRise }
        // Laid out like the reveal stage (fan, spotlight, deck), with the sealed
        // pack drawn translucent on top: at the start of the rise the bundle has
        // to sit inside the pack's body.
        func riseStage(_ rise: DeckRiseModel, packOpacity: Double) -> AnyView {
            onStage(
                ZStack {
                    VStack(alignment: .leading, spacing: 14) {
                        Spacer(minLength: 0)
                        HStack(alignment: .top, spacing: 20) {
                            Color.clear.frame(width: 84, height: 130)
                            Color.clear.frame(width: 320, height: 412)
                            CardStackView(engine: engine, deckRise: rise, skipsAnimations: false)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    PackWrapView(product: engine.productForDisplay, dragOffset: 0, threshold: 150, cleared: false, stillSurface: true)
                        .opacity(packOpacity)
                }
            )
        }
        try capture("02-cards-rise-start", riseStage(hidden, packOpacity: 0.45))
        try capture("03-cards-rise-end", riseStage(settled, packOpacity: 0))

        await waitUntil { holds.pending == 1 }
        holds.releaseOne()
        await waitUntil { engine.state == .cardWaiting(nextIndex: 0) }
        try capture("04-waiting-card-back", stage())

        // The turn itself: back at the edge, then the front just past it.
        let rare = try card("Rare")
        func face(_ card: PackOpeningCard) -> AnyView {
            AnyView(CardFaceView(card: card.card, variant: card.variant, quality: .full, isNew: card.isNew).frame(width: 300))
        }
        try capture("05-mid-flip", onStage(
            HStack(spacing: 40) {
                ForEach([0.8, 0.55, 0.35], id: \.self) { turn in
                    Color.clear
                        .frame(width: 300, height: 412)
                        .modifier(CardFlip(
                            turn: turn,
                            front: { face(rare) },
                            back: { AnyView(CardBackView().frame(width: 300)) }
                        ))
                        .scaleEffect(0.55)
                        .frame(width: 180)
                }
            }
        ))
        try capture("06-front-rare", onStage(
            ZStack {
                EffectLayerView(
                    profile: rare.rarityProfile,
                    glowColor: Palette.rarityColor(rare.rarity),
                    frontVisible: true,
                    isAnticipating: false,
                    skipsAnimations: false
                )
                face(rare)
            }
        ))
        let midway = CardTransferProgress(progress: 0.5)
        try capture("07-transfer-mid", onStage(
            face(rare)
                .scaleEffect(midway.scale)
                .rotationEffect(.degrees(midway.rotation))
                .opacity(midway.opacity)
                .offset(midway.offset)
        ))

        // Five cards out: the fan, the next back and the rest of the bundle.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while engine.state != .cardWaiting(nextIndex: 5), ContinuousClock.now < deadline {
            await waitUntil { engine.acceptsAdvanceInput || holds.pending > 0 }
            // Released holds finish their transition asynchronously: stop the
            // moment the fifth card has landed, before advancing again.
            if engine.state == .cardWaiting(nextIndex: 5) { break }
            if holds.pending > 0 {
                holds.releaseOne()
            } else if engine.acceptsAdvanceInput {
                engine.advance()
            }
        }
        #expect(engine.state == .cardWaiting(nextIndex: 5))
        try capture("08-revealed-stack", stage())

        let top = try card(tier: 5)
        try capture("09-top-rare-fx", onStage(
            ZStack {
                EffectLayerView(
                    profile: top.rarityProfile,
                    glowColor: Palette.rarityColor(top.rarity),
                    frontVisible: true,
                    isAnticipating: false,
                    skipsAnimations: false
                )
                CardFaceView(
                    card: top.card,
                    variant: top.variant,
                    quality: .full,
                    isNew: top.isNew,
                    sweep: CardSweepBand(progress: 0.5, foil: true)
                )
                .frame(width: 300, height: 412)
                    .modifier(RevealFXModifier(
                        progress: 0.35,
                        sparkles: RevealFX.sparkles(count: top.rarityProfile.sparkleCount),
                        burst: true,
                        color: Palette.rarityColor(top.rarity)
                    ))
            }
        ))

        engine.revealAll()
        await waitUntil { engine.state == .summary && engine.revealedCount == cards.count }
        try capture("10-summary", stage())
        engine.cancelAll()
        return frames
    }

    static func makeEnvironment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-opening-render").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        return (environment, root)
    }

    @Test("대표 장면 10개가 시트 크기로 렌더되고, 빈 화면이 아니다")
    func everyMomentRenders() async throws {
        let (environment, root) = try await Self.makeEnvironment()
        defer { TestOwnedRoot.remove(root.deletingLastPathComponent()) }
        let frames = try await Self.frames(environment: environment)
        #expect(frames.map(\.name) == [
            "01-pack-ready", "02-cards-rise-start", "03-cards-rise-end", "04-waiting-card-back", "05-mid-flip",
            "06-front-rare", "07-transfer-mid", "08-revealed-stack", "09-top-rare-fx", "10-summary",
        ])
        for frame in frames {
            let image = frame.image
            #expect(image.width == Int(Self.stageSize.width) && image.height == Int(Self.stageSize.height), "\(frame.name)")
            // Something is drawn on the backdrop: the brightest sample is well
            // above the darkest.
            let pixels = try Pixels(image)
            var values: [Double] = []
            for y in stride(from: 0, to: image.height, by: 15) {
                for x in stride(from: 0, to: image.width, by: 15) {
                    values.append(pixels.luminance(x: x, y: y))
                }
            }
            #expect((values.max() ?? 0) - (values.min() ?? 0) > 0.2, "\(frame.name): 거의 빈 화면입니다")
        }
    }
}
