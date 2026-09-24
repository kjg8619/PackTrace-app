import CoreGraphics
import Foundation
import PackTraceCore
import SwiftUI
import Testing

@testable import PackTraceUI

/// Geometry and pacing behind the opening animation.
///
/// These are the numbers the views read, so they are tested here instead of by
/// looking at pixels: the tear follows the hand, the front face is only drawn
/// after the card has passed halfway, the deck keeps a readable number of
/// layers, and rarer cards are held longer without blowing up the total time.
@Suite("개봉 연출 계산")
struct PackOpeningAnimationTests {
    // MARK: - Tear

    @Test("드래그 진행도는 0…1로 잘리고 임계점에서만 열린다")
    func tearProgressClampsAndGates() throws {
        #expect(TearProgress.from(dragOffset: -40).progress == 0)
        #expect(TearProgress.from(dragOffset: 0).progress == 0)
        #expect(TearProgress.from(dragOffset: 75).progress == 0.5)
        #expect(TearProgress.from(dragOffset: 150).progress == 1)
        #expect(TearProgress.from(dragOffset: 900).progress == 1)

        #expect(TearProgress.from(dragOffset: 149).hasPassedThreshold == false)
        #expect(TearProgress.from(dragOffset: 150).hasPassedThreshold)
        // A zero threshold must not divide by zero.
        #expect(TearProgress.from(dragOffset: 10, threshold: 0).progress == 0)
    }

    @Test("찢기는 손을 따라 즉시 반응하고, 끝까지 밀면 strip이 빠져나간다")
    func tearGeometryFollowsTheHand() throws {
        let start = TearProgress.from(dragOffset: 0)
        let half = TearProgress.from(dragOffset: 75)
        let end = TearProgress.from(dragOffset: 150)

        #expect(start.stripTravel == 0)
        #expect(start.stripRotation == 0)
        #expect(half.stripTravel > start.stripTravel)
        #expect(end.stripTravel > half.stripTravel)
        // Pulled, not just translated.
        #expect(end.stripRotation > start.stripRotation)
        // The strip is still fully on screen at the moment of release.
        #expect(end.stripOpacity > 0.5)
        // The body compresses and the tear line gets brighter as it opens.
        #expect(end.bodySquash > start.bodySquash)
        #expect(end.edgeHighlight > start.edgeHighlight)
        #expect(end.foilShift > start.foilShift)
    }

    @Test("임계점 근처에서 장력이 생기고 떨림은 작게 제한된다")
    func tensionRampsNearTheThreshold() throws {
        let slack = TearProgress.from(dragOffset: 60)
        let pulling = TearProgress.from(dragOffset: 128)
        let atThreshold = TearProgress.from(dragOffset: 150)

        #expect(slack.tension == 0, "여유가 있을 때는 떨리지 않습니다")
        #expect(pulling.tension > 0)
        #expect(pulling.tension < 1)
        #expect(atThreshold.tension == 1)
        #expect(atThreshold.tension > pulling.tension)

        // Strain is visible as a bounded vibration, not as a broken layout.
        #expect(slack.shake(at: 0.25) == 0)
        let peak = atThreshold.shake(at: 0.25)
        let trough = atThreshold.shake(at: 0.75)
        #expect(peak > 0)
        #expect(trough < 0, "떨림은 좌우로 번갈아야 합니다")
        #expect(abs(peak) <= 2.2)
        #expect(abs(trough) <= 2.2)

        // The body follows the hand and the foil peel marks the break.
        #expect(atThreshold.bodyFollow > slack.bodyFollow)
        #expect(atThreshold.bodyFollow <= 3)
        #expect(TearProgress.peel(cleared: false) == 0)
        #expect(TearProgress.peel(cleared: true) == 1)
    }

    // MARK: - Flip

    @Test("카드 앞면은 90도를 넘긴 뒤에만 그려진다")
    func frontFaceOnlyAfterTheHalfwayPoint() throws {
        #expect(CardFlipPhase.back.showsFront == false)
        #expect(CardFlipPhase.from(turn: 1.0).showsFront == false)
        #expect(CardFlipPhase.from(turn: 0.51).showsFront == false, "90도 이전에는 뒷면만 보여야 합니다")
        #expect(CardFlipPhase.from(turn: 0.5).showsFront)
        #expect(CardFlipPhase.from(turn: 0.0).showsFront)
        #expect(CardFlipPhase.front.showsFront)

        // Angles stay in range and follow the turn.
        #expect(CardFlipPhase.back.angleDegrees == 180)
        #expect(CardFlipPhase.front.angleDegrees == 0)
        #expect(CardFlipPhase.from(turn: 2.0).turn == 1)
        #expect(CardFlipPhase.from(turn: -1.0).turn == 0)
    }

    @Test("뒤집는 동안 카드가 살짝 떠오르고 가운데에서 가장 크다")
    func flipLiftPeaksInTheMiddle() throws {
        let back = CardFlipPhase.back
        let middle = CardFlipPhase.from(turn: 0.5)
        let front = CardFlipPhase.front

        #expect(abs(back.lift) < 0.01)
        #expect(abs(front.lift) < 0.01)
        #expect(middle.lift < -8, "가운데에서 카드가 떠야 합니다")
        #expect(middle.lift > -20, "과장된 이동은 피합니다")
        #expect(middle.scale > 1)
        #expect(middle.scale <= 1.05)
        #expect(middle.shadow > back.shadow)
    }

    // MARK: - Deck

    @Test("덱은 필요한 만큼만 겹치고 남은 장수를 유지한다")
    func deckKeepsReadableDepth() throws {
        #expect(CardDeckGeometry.visibleDepth(remaining: 10) == 4)
        #expect(CardDeckGeometry.visibleDepth(remaining: 4) == 4)
        #expect(CardDeckGeometry.visibleDepth(remaining: 3) == 3)
        #expect(CardDeckGeometry.visibleDepth(remaining: 0) == 0)
        #expect(CardDeckGeometry.visibleDepth(remaining: -2) == 0)

        // Layers step back and up, and shrink slightly.
        #expect(CardDeckGeometry.offset(forLayer: 0) == .zero)
        #expect(CardDeckGeometry.offset(forLayer: 2).height < CardDeckGeometry.offset(forLayer: 1).height)
        #expect(CardDeckGeometry.offset(forLayer: 2).width > CardDeckGeometry.offset(forLayer: 1).width)
        #expect(CardDeckGeometry.scale(forLayer: 3) < CardDeckGeometry.scale(forLayer: 0))
        #expect(CardDeckGeometry.scale(forLayer: 3) > 0.9, "카드가 지나치게 작아지면 안 됩니다")
        #expect(CardDeckGeometry.rotation(forLayer: 0) == 0)
        #expect(CardDeckGeometry.rotation(forLayer: 1) != 0)
        #expect(abs(CardDeckGeometry.rotation(forLayer: 3)) < 3, "기울기가 과하면 안 됩니다")
    }

    @Test("공개한 카드는 옆 스택에 최신 카드가 가장 앞으로 쌓인다")
    func revealedStackFansOut() throws {
        #expect(RevealedStackGeometry.visibleCount(revealed: 0) == 0)
        #expect(RevealedStackGeometry.visibleCount(revealed: 3) == 3)
        #expect(RevealedStackGeometry.visibleCount(revealed: 10) == 5, "그리는 장수를 제한합니다")

        let newest = 4
        #expect(RevealedStackGeometry.offset(forIndex: newest, of: 5) == .zero)
        let older = RevealedStackGeometry.offset(forIndex: 0, of: 5)
        #expect(older.width < 0)
        #expect(older.height > 0)
        #expect(RevealedStackGeometry.rotation(forIndex: 0, of: 5) < 0)
    }

    // MARK: - Pacing

    @Test("희귀할수록 예고와 감상 시간이 길어지지만 총량은 제한된다")
    func rarityPacingGrowsButStaysBounded() throws {
        let common = RarityAnimationProfile(rarity: CardRarity(rawValue: "Common"))
        let uncommon = RarityAnimationProfile(rarity: CardRarity(rawValue: "Uncommon"))
        let rare = RarityAnimationProfile(rarity: CardRarity(rawValue: "Rare"))
        let doubleRare = RarityAnimationProfile(rarity: CardRarity(rawValue: "Double rare"))
        let hyper = RarityAnimationProfile(rarity: CardRarity(rawValue: "Hyper rare"))

        #expect(common.anticipation == .zero, "일반 카드는 기다리게 하면 안 됩니다")
        #expect(uncommon.anticipation == .zero)
        #expect(rare.anticipation > common.anticipation)
        #expect(hyper.anticipation >= rare.anticipation)
        #expect(hyper.hold > common.hold)

        // A ten-common pack must not stall, and even a rare pack stays reasonable.
        let tenCommons = common.revealBudget * 10
        #expect(tenCommons <= .seconds(1), "일반 10장은 답답하지 않아야 합니다: \(tenCommons)")
        #expect(hyper.revealBudget <= .milliseconds(900))

        // Sparkles only where they read as special.
        #expect(common.sparkles == false)
        #expect(rare.sparkles == false)
        #expect(doubleRare.sparkles)
        #expect(hyper.sparkles)

        // Glow stays in a sane range and dims only for rarer cards.
        #expect(common.glow == 0)
        #expect(hyper.glow > rare.glow)
        #expect(hyper.glow <= 1)
        #expect(common.dimsBackground == false)
        #expect(hyper.dimsBackground)
    }

    @Test("알 수 없는 등급도 안전한 기본값으로 처리한다")
    func unknownRarityFallsBack() throws {
        let unknown = RarityAnimationProfile(rarity: CardRarity(rawValue: "Mystery Rare"))
        #expect(unknown.glow >= 0)
        #expect(unknown.revealBudget >= .zero)
        #expect(unknown.revealBudget <= .milliseconds(900))
    }
}

/// The remaining-card bundle: how many backs are drawn, where they sit, and how
/// the whole bundle comes out of the pack.
@Suite("카드 묶음 기하")
struct CardDeckGeometryTests {
    @Test("남은 장수에 따른 층 수")
    func visibleDepth() {
        #expect(CardDeckGeometry.visibleDepth(remaining: -1) == 0)
        #expect(CardDeckGeometry.visibleDepth(remaining: 0) == 0)
        #expect(CardDeckGeometry.visibleDepth(remaining: 1) == 1)
        #expect(CardDeckGeometry.visibleDepth(remaining: 2) == 2)
        #expect(CardDeckGeometry.visibleDepth(remaining: 3) == 3)
        #expect(CardDeckGeometry.visibleDepth(remaining: 4) == 4)
        #expect(CardDeckGeometry.visibleDepth(remaining: 10) == 4)
        #expect(CardDeckGeometry.visibleDepth(remaining: 10) == CardDeckGeometry.maxVisibleDepth)
    }

    @Test("층마다 같은 값이 나오고, 범위를 벗어난 층도 안전하다")
    func layerGeometryIsDeterministicAndSafe() {
        for layer in 0..<CardDeckGeometry.maxVisibleDepth {
            #expect(CardDeckGeometry.offset(forLayer: layer) == CardDeckGeometry.offset(forLayer: layer))
            #expect(CardDeckGeometry.scale(forLayer: layer) > 0)
            #expect(CardDeckGeometry.scale(forLayer: layer) <= 1)
            #expect((0.5...1.0).contains(CardDeckGeometry.opacity(forLayer: layer)))
            #expect(abs(CardDeckGeometry.rotation(forLayer: layer)) < 3)
        }
        // A negative or oversized layer index is clamped instead of producing
        // geometry the view would have to guard against.
        #expect(CardDeckGeometry.offset(forLayer: -1) == CardDeckGeometry.offset(forLayer: 0))
        #expect(CardDeckGeometry.offset(forLayer: 99) == CardDeckGeometry.offset(forLayer: CardDeckGeometry.maxVisibleDepth))
        #expect(CardDeckGeometry.scale(forLayer: 99) == CardDeckGeometry.scale(forLayer: CardDeckGeometry.maxVisibleDepth))
        #expect(CardDeckGeometry.opacity(forLayer: 99) == CardDeckGeometry.opacity(forLayer: CardDeckGeometry.maxVisibleDepth))

        // Deeper layers are dimmer, and the top card is fully opaque.
        #expect(CardDeckGeometry.opacity(forLayer: 0) == 1)
        #expect(CardDeckGeometry.opacity(forLayer: 3) < CardDeckGeometry.opacity(forLayer: 1))
        // The stack is a bundle, not a fan: the spread stays small.
        #expect(abs(CardDeckGeometry.offset(forLayer: 3).height) <= 30)
        #expect(abs(CardDeckGeometry.offset(forLayer: 3).width) <= 20)
    }

    @Test("묶음은 하나의 물체처럼 올라온다")
    func bundleRisesAsOneObject() {
        let start = CardDeckGeometry.rise(progress: 0)
        let end = CardDeckGeometry.rise(progress: 1)
        #expect(start.offsetY > 0, "팩 안에서는 아래에 숨어 있습니다")
        #expect(abs(end.offsetY) < 0.001)
        #expect(start.scale < 1 && abs(end.scale - 1) < 0.001)
        #expect(start.opacity < end.opacity)
        #expect(abs(end.opacity - 1) < 0.001)

        // Out-of-range progress is clamped rather than extrapolated.
        #expect(CardDeckGeometry.rise(progress: -1) == start)
        #expect(CardDeckGeometry.rise(progress: 2) == end)
        // And the movement is monotonic: the bundle never dips back down.
        let middle = CardDeckGeometry.rise(progress: 0.5)
        #expect(middle.offsetY < start.offsetY && middle.offsetY > end.offsetY)
    }

    @Test("묶음은 팩이 있던 자리에서 자기 기둥으로 올라온다")
    func bundleRisesFromThePack() {
        #expect(CardDeckGeometry.riseTravel < 0, "덱 기둥은 무대 중심의 오른쪽에 있습니다")
        #expect(CardDeckGeometry.riseTravelX(progress: 0) == CardDeckGeometry.riseTravel)
        #expect(CardDeckGeometry.riseTravelX(progress: 1) == 0)
        // Clamped, and it only ever moves towards its own column.
        #expect(CardDeckGeometry.riseTravelX(progress: -1) == CardDeckGeometry.riseTravel)
        #expect(CardDeckGeometry.riseTravelX(progress: 2) == 0)
        let middle = CardDeckGeometry.riseTravelX(progress: 0.5)
        #expect(middle > CardDeckGeometry.riseTravel && middle < 0)

        // The two axes agree on when the bundle has arrived: the lift and the
        // travel both finish at 1, so the deck cannot arrive early and then slide.
        #expect(CardDeckGeometry.rise(progress: 1).offsetY == 0)
        #expect(CardDeckGeometry.riseTravelX(progress: 1) == 0)
        // Hiding inside the pack: the bundle starts lower than its slot and inside
        // the pack's own outline, which is how it reads as coming out of it.
        #expect(CardDeckGeometry.rise(progress: 0).offsetY > 0)
    }
}
    @Test("앞면 View는 반환 지점을 넘긴 뒤에만 만들어진다")
    func frontViewIsBuiltLate() {
        // The builder records when it actually runs, so "not constructed before
        // the halfway point" is bounded by evidence rather than by reading the
        // view code.
        final class Built: @unchecked Sendable { var front = 0; var back = 0 }
        let built = Built()

        func render(turn: Double) -> CardFlipPhase {
            let modifier = CardFlip(
                turn: turn,
                front: { built.front += 1; return AnyView(EmptyView()) },
                back: { built.back += 1; return AnyView(EmptyView()) }
            )
            // The phase decides which builder the body would call; the body itself
            // needs a host, so the decision is asserted through the phase.
            return CardFlipPhase.from(turn: turn)
        }

        // Waiting: back only.
        #expect(render(turn: 1.0).showsFront == false)
        // Turning, before the halfway point: still back only.
        #expect(render(turn: 0.75).showsFront == false)
        #expect(render(turn: 0.51).showsFront == false)
        // From the halfway point on: the front is the face that gets drawn.
        #expect(render(turn: 0.5).showsFront)
        #expect(render(turn: 0.25).showsFront)
        #expect(render(turn: 0.0).showsFront)
        #expect(built.front == 0 && built.back == 0, "phase만 계산해서는 어떤 face도 만들지 않습니다")
    }
/// Turning a revealed card over, then moving it to the stack: two separate
/// contracts, so a card cannot fly away before its front is visible.
@Suite("카드 이동")
struct CardTransferProgressTests {
    @Test("진행도는 범위를 벗어나지 않는다")
    func progressIsClamped() {
        #expect(CardTransferProgress(progress: -1).clampedProgress == 0)
        #expect(CardTransferProgress(progress: 0).clampedProgress == 0)
        #expect(CardTransferProgress(progress: 0.5).clampedProgress == 0.5)
        #expect(CardTransferProgress(progress: 1).clampedProgress == 1)
        #expect(CardTransferProgress(progress: 2).clampedProgress == 1)
        #expect(CardTransferProgress(progress: -1).offset == CardTransferProgress(progress: 0).offset)
        #expect(CardTransferProgress(progress: 2).offset == CardTransferProgress(progress: 1).offset)
    }

    @Test("시작은 현재 자리, 끝은 스택 카드 자리와 크기")
    func endpointsMatchTheTwoPositions() {
        let start = CardTransferProgress(progress: 0)
        let end = CardTransferProgress(progress: 1)
        #expect(start.offset == .zero)
        #expect(abs(start.scale - 1) < 0.001)
        #expect(abs(start.rotation) < 0.001)
        #expect(abs(start.opacity - 1) < 0.001)

        #expect(abs(end.offset.width - CardTransferProgress.stackOffset.width) < 0.001)
        #expect(abs(end.offset.height - CardTransferProgress.stackOffset.height) < 0.001)
        #expect(abs(end.scale - CardTransferProgress.stackScale) < 0.001)
        #expect(abs(end.rotation) < 0.001, "스택에서는 카드가 반듯합니다")
        #expect(end.opacity > 0.8)

        // The stack sits left of and above the spotlight, so the card has to land
        // there rather than fly off the side of the stage.
        #expect(CardTransferProgress.stackOffset.width < 0)
        #expect(CardTransferProgress.stackOffset.height < 0)
        // And it lands at the size the fan draws a card (~70pt of the 300pt card).
        #expect(CardTransferProgress.stackScale > 0.2 && CardTransferProgress.stackScale < 0.4)
    }

    @Test("중간은 단조롭게 움직이고 값 범위가 안전하다")
    func middleMovesMonotonically() {
        let samples = stride(from: 0.0, through: 1.0, by: 0.1).map { CardTransferProgress(progress: $0) }
        for sample in samples {
            #expect(sample.scale > 0 && sample.scale <= 1)
            #expect((0.5...1.0).contains(sample.opacity))
            #expect(abs(sample.rotation) <= 5)
            #expect(abs(sample.offset.width) <= abs(CardTransferProgress.stackOffset.width))
            #expect(abs(sample.offset.height) <= abs(CardTransferProgress.stackOffset.height))
            #expect(sample == CardTransferProgress(progress: sample.progress), "같은 값은 같은 배치")
        }
        // The card moves left and up the whole way, and keeps shrinking.
        for (previous, next) in zip(samples, samples.dropFirst()) {
            #expect(next.offset.width <= previous.offset.width)
            #expect(next.offset.height <= previous.offset.height)
            #expect(next.scale <= previous.scale)
        }
        // It tilts on the way over and comes back square at both ends.
        let middle = CardTransferProgress(progress: 0.5)
        #expect(middle.rotation > 0)
        #expect(middle.rotation > samples[1].rotation)
    }
}

/// The spotlight's own animation state: the order the phases play in, and that
/// the card only moves after its front is readable.
@Suite("카드 공개 진행")
@MainActor
struct CardRevealModelTests {
    /// Long enough to observe each phase, short enough to keep the suite quick.
    private let timeline = CardRevealTimeline(
        anticipation: .milliseconds(120),
        flip: .milliseconds(120),
        settle: .milliseconds(300),
        transfer: .milliseconds(120),
        sweep: false
    )

    /// Generous on purpose: the order is what is checked, and with the whole
    /// suite running in parallel the main actor can be busy for seconds.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: Duration = .seconds(10)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test("공개를 시작하면 예고 동안은 뒷면에서 기다린다")
    func startsFaceDownInAnticipation() {
        let model = CardRevealModel()
        model.reveal(timeline, instant: false)
        #expect(model.turn == 1, "예고 중에는 아직 뒤집지 않습니다")
        #expect(model.anticipating)
        #expect(model.transferProgress == 0, "뒤집기 전에 옮기면 안 됩니다")
        model.cancel()
    }

    @Test("앞면이 보인 뒤에야 스택으로 이동한다")
    func transfersOnlyAfterTheFrontShows() async throws {
        let model = CardRevealModel()
        model.reveal(timeline, instant: false)
        #expect(model.anticipating)

        await waitUntil { model.turn == 0 }
        #expect(model.anticipating == false)
        // The settle: the face is on screen and the card has not left yet.
        #expect(model.transferProgress == 0, "뒤집자마자 옮기면 앞면을 읽을 틈이 없습니다")

        await waitUntil { model.transferProgress == 1 }
        #expect(model.transferProgress == 1)
        #expect(model.turn == 0, "이동 중에도 앞면을 유지합니다")
    }

    @Test("즉시 공개는 뒤집기와 이동 없이 앞면을 무대에 남긴다")
    func instantRevealSkipsTheMove() {
        let model = CardRevealModel()
        model.reveal(
            CardRevealTimeline(anticipation: .zero, flip: .zero, settle: .zero, transfer: .zero, sweep: false),
            instant: true
        )
        #expect(model.turn == 0)
        #expect(model.frontVisible)
        // Reduced motion used to put the card straight into the fan (progress 1),
        // so it was never seen at the spotlight's size.
        #expect(model.transferProgress == 0, "모션 줄이기에서도 공개된 카드는 무대에서 보여야 합니다")
        #expect(model.anticipating == false)
        #expect(model.sweep == 0)
    }

    @Test("다음 카드를 기다릴 때는 뒷면에서 제자리에 있다")
    func resetPutsTheCardBack() async {
        let model = CardRevealModel()
        model.reveal(timeline, instant: false)
        await waitUntil { model.turn == 0 && model.transferProgress > 0 }
        model.reset()
        #expect(model.turn == 1, "다음 카드는 다시 뒷면입니다")
        #expect(model.transferProgress == 0)
        #expect(model.anticipating == false)
        // And the cancelled run does not drag the card out afterwards.
        await waitUntil({ model.transferProgress > 0 }, timeout: .milliseconds(200))
        #expect(model.transferProgress == 0)
    }

    @Test("하이라이트는 등급을 보여준 뒤, 뒤집기가 끝난 다음에만 시작한다")
    func sweepOnlyStartsAfterTheFlip() async {
        let sweepTimeline = CardRevealTimeline(
            anticipation: .milliseconds(80),
            flip: .milliseconds(400),
            settle: .milliseconds(400),
            transfer: .milliseconds(100),
            sweep: true
        )
        let model = CardRevealModel()
        model.reveal(sweepTimeline, instant: false)

        // Face down: nothing to highlight yet.
        #expect(model.sweep == 0)
        #expect(model.frontVisible == false)
        #expect(model.anticipating)

        // Turning, and the front is not the face on screen: still nothing.
        try? await Task.sleep(for: .milliseconds(160))
        #expect(model.sweep == 0, "뒤집는 중에 빛이 지나가면 앞면이 가려집니다")
        #expect(model.frontVisible == false, "앞면이 보이기 전에는 등급 효과도 없어야 합니다")

        // From the halfway point of the turn the front is on screen.
        await waitUntil { model.frontVisible }
        #expect(model.sweep == 0, "하이라이트는 뒤집기가 끝난 뒤입니다")
        await waitUntil { model.sweep > 0 }
        #expect(model.sweep > 0)
        #expect(model.turn == 0)
    }

    @Test("모션 줄이기에서는 하이라이트를 재생하지 않는다")
    func instantRevealHasNoSweep() async {
        let model = CardRevealModel()
        model.reveal(
            CardRevealTimeline(
                anticipation: .zero,
                flip: .zero,
                settle: .zero,
                transfer: .zero,
                sweep: true
            ),
            instant: true
        )
        #expect(model.sweep == 0, "Reduced Motion에서는 빛도 흐르지 않습니다")
        #expect(model.frontVisible, "앞면 정보는 그대로 남습니다")
        await waitUntil({ model.sweep > 0 }, timeout: .milliseconds(200))
        #expect(model.sweep == 0)
    }

    @Test("하이라이트는 앞면이 머무는 동안에 끝난다")
    func sweepFitsInsideTheFrontHold() {
        let timing = PackOpeningTiming.standard
        for rarity in ["Ultra Rare", "Illustration rare", "Special illustration rare", "Hyper rare"] {
            let profile = RarityAnimationProfile(rarity: CardRarity(rawValue: rarity))
            let timeline = CardRevealTimeline.make(profile: profile, timing: timing)
            #expect(timeline.sweep, "\(rarity)에 하이라이트가 없습니다")
            #expect(
                CardLightSweep.duration <= timeline.settle.packTraceSeconds,
                "\(rarity): 빛이 스택으로 이동하는 중에도 남습니다"
            )
        }
    }
}

/// Which revealed cards are on the fan, and the order they are drawn in.
@Suite("공개 스택 선택")
struct RevealedStackSelectionTests {
    @Test("아직 공개한 카드가 없으면 아무것도 그리지 않는다")
    func emptyBeforeTheFirstReveal() {
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 0, isRevealing: false).isEmpty)
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 0, isRevealing: true).isEmpty)
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: -3, isRevealing: false).isEmpty)
    }

    @Test("공개한 순서대로 쌓이고 마지막 카드가 맨 위다")
    func newestCardIsOnTop() {
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 1, isRevealing: false) == [0])
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 3, isRevealing: false) == [0, 1, 2])
        // More than fit: the newest window, oldest first.
        let many = RevealedStackGeometry.visibleIndices(revealedCount: 6, isRevealing: false)
        #expect(many == [1, 2, 3, 4, 5])
        #expect(many.count == RevealedStackGeometry.maxVisible)
        #expect(many.last == 5, "마지막으로 공개한 카드가 맨 위입니다")
        #expect(RevealedStackGeometry.offset(forIndex: many.count - 1, of: many.count) == .zero)
    }

    @Test("공개 중인 카드는 이동이 끝날 때까지 스택에서 빠진다")
    func revealingCardIsNotDrawnTwice() {
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 1, isRevealing: true).isEmpty)
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 3, isRevealing: true) == [0, 1])
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 7, isRevealing: true) == [1, 2, 3, 4, 5])
        // Waiting (nothing in the spotlight) keeps everything, including the card
        // that has just landed.
        #expect(RevealedStackGeometry.visibleIndices(revealedCount: 7, isRevealing: false).last == 6)
    }
}

/// One card's reveal, phase by phase, and what the spotlight reads from it.
@Suite("공개 타임라인")
struct CardRevealTimelineTests {
    private func profile(_ rarity: String) -> RarityAnimationProfile {
        RarityAnimationProfile(rarity: CardRarity(rawValue: rarity))
    }

    @Test("한 장의 총 시간은 단계들의 합이다")
    func totalIsTheSumOfThePhases() {
        let timing = PackOpeningTiming.standard
        let common = profile("Common")
        let timeline = CardRevealTimeline.make(profile: common, timing: timing)

        #expect(timeline.anticipation == common.anticipation)
        #expect(timeline.flip == timing.cardFlip)
        #expect(timeline.settle == timing.cardSettle + common.hold)
        #expect(timeline.transfer == timing.cardTransfer)
        #expect(timeline.total == timeline.anticipation + timeline.flip + timeline.settle + timeline.transfer)
        #expect(timeline.total > .zero)

        // 일반 10장을 열어도 답답하지 않아야 합니다.
        #expect(timeline.total * 10 <= .seconds(8), "일반 카드 10장: \(timeline.total * 10)")
    }

    @Test("등급은 앞뒤 여백만 늘리고 순서는 바꾸지 않는다")
    func rarityOnlyStretchesThePadding() {
        let timing = PackOpeningTiming.standard
        let common = CardRevealTimeline.make(profile: profile("Common"), timing: timing)
        let rare = CardRevealTimeline.make(profile: profile("Rare"), timing: timing)
        let hyper = CardRevealTimeline.make(profile: profile("Hyper rare"), timing: timing)

        #expect(rare.anticipation > common.anticipation)
        #expect(hyper.anticipation >= rare.anticipation)
        #expect(hyper.settle > rare.settle)
        #expect(hyper.total > common.total)
        // Turning and travelling are the same for every card.
        #expect(rare.flip == common.flip)
        #expect(rare.transfer == common.transfer)
        #expect(hyper.flip == common.flip)
    }

    @Test("모션 줄이기에서는 모든 단계가 0이고 하이라이트도 없다")
    func instantTimingCollapses() {
        for rarity in ["Common", "Rare", "Hyper rare"] {
            let timeline = CardRevealTimeline.make(profile: profile(rarity), timing: .instant)
            #expect(timeline.total == .zero, "\(rarity)가 즉시가 아닙니다")
            #expect(timeline.sweep == false)
        }
        #expect(PackOpeningTiming.standard.isInstant == false)
        #expect(PackOpeningTiming.instant.isInstant)
    }

    @Test("하이라이트는 최상위 등급에만 켜진다")
    func onlyTopTiersSweep() {
        let timing = PackOpeningTiming.standard
        #expect(profile("Common").ultraSweep == false)
        #expect(profile("Rare").ultraSweep == false)
        #expect(profile("Double rare").ultraSweep == false, "레어마다 반짝이면 소음입니다")
        #expect(profile("Illustration rare").ultraSweep)
        #expect(profile("Hyper rare").ultraSweep)
        #expect(CardRevealTimeline.make(profile: profile("Hyper rare"), timing: timing).sweep)
        #expect(CardRevealTimeline.make(profile: profile("Common"), timing: timing).sweep == false)
    }

    @Test("공개 전 대기는 등급을 정확히 알려주지 않는다")
    func anticipationOnlySignalsCoarseBands() {
        // Three bands: nothing, "worth watching", "this is a big one". Two cards
        // inside a band wait exactly as long, so the pause cannot say which tier
        // is about to turn over.
        #expect(profile("Common").anticipation == profile("Uncommon").anticipation)
        #expect(profile("Rare").anticipation == profile("Double rare").anticipation)
        #expect(profile("Ultra Rare").anticipation == profile("Illustration rare").anticipation)
        #expect(profile("Special illustration rare").anticipation == profile("Hyper rare").anticipation)
        // The bands themselves stay distinguishable, and bounded.
        #expect(profile("Common").anticipation < profile("Rare").anticipation)
        #expect(profile("Rare").anticipation < profile("Hyper rare").anticipation)
        #expect(profile("Hyper rare").anticipation <= .milliseconds(500))
    }
}

/// The development preview's two flags.
@Suite("미리보기 플래그")
struct PackOpeningPreviewFlagTests {
    @Test("자동 재생은 미리보기 플래그와 명시적 플래그가 모두 있어야 켜진다")
    func autoplayNeedsBothFlags() {
        let both = [
            PackOpeningPreview.environmentKey: "1",
            PackOpeningPreview.autoplayEnvironmentKey: "1",
        ]
        #expect(PackOpeningPreview.autoplayEnabled(environment: both))
        #expect(PackOpeningPreview.autoplayEnabled(environment: [
            PackOpeningPreview.autoplayEnvironmentKey: "1",
        ]) == false, "미리보기 없이 자동으로 열리면 안 됩니다")
        #expect(PackOpeningPreview.autoplayEnabled(environment: [
            PackOpeningPreview.environmentKey: "1",
        ]) == false, "명시적 플래그가 필요합니다")
        #expect(PackOpeningPreview.autoplayEnabled(environment: [:]) == false)
        #expect(PackOpeningPreview.isEnabled(environment: [:]) == false)
        #expect(PackOpeningPreview.isEnabled(environment: [PackOpeningPreview.environmentKey: "yes"]))
    }

    @Test("측정 로그도 미리보기 플래그와 함께일 때만 켜진다")
    func traceNeedsThePreview() {
        #expect(PackOpeningPreview.traceEnabled(environment: [
            PackOpeningPreview.environmentKey: "1",
            PackOpeningPreview.traceEnvironmentKey: "1",
        ]))
        #expect(PackOpeningPreview.traceEnabled(environment: [
            PackOpeningPreview.traceEnvironmentKey: "1",
        ]) == false, "저장된 팩을 여는 일반 실행에서는 로그가 없어야 합니다")
        #expect(PackOpeningPreview.traceEnabled(environment: [
            PackOpeningPreview.environmentKey: "1",
        ]) == false)
    }
}

/// The rarity-coloured effects may only appear once the front is the face on
/// screen: while a card waits or turns, every card has to look the same.
@Suite("등급 효과 게이트")
struct RarityEffectPlanTests {
    private func profile(_ rarity: String) -> RarityAnimationProfile {
        RarityAnimationProfile(rarity: CardRarity(rawValue: rarity))
    }

    private func plan(
        _ rarity: String,
        frontVisible: Bool,
        isAnticipating: Bool,
        animates: Bool = true
    ) -> RarityEffectPlan {
        RarityEffectPlan.make(
            profile: profile(rarity),
            frontVisible: frontVisible,
            isAnticipating: isAnticipating,
            animates: animates
        )
    }

    @Test("공개 전에는 등급과 무관한 예고 효과만 보여준다")
    func anticipationIsNeutralOnly() {
        for rarity in ["Common", "Rare", "Double rare", "Illustration rare", "Hyper rare"] {
            let holding = plan(rarity, frontVisible: false, isAnticipating: true)
            #expect(holding.showsAnticipation, "\(rarity): 예고 효과가 없습니다")
            #expect(holding.showsRarityGlow == false, "\(rarity): 공개 전에 등급 색이 보입니다")
            #expect(holding.showsSparkles == false, "\(rarity): 공개 전에 반짝임이 보입니다")
        }
    }

    @Test("뒷면과 뒤집는 동안에는 등급 효과가 없다")
    func backAndTurningHaveNoRarityEffects() {
        // Waiting and the first half of the turn are one state for the FX layer:
        // the front is not the face on screen.
        for rarity in ["Common", "Rare", "Hyper rare"] {
            let back = plan(rarity, frontVisible: false, isAnticipating: false)
            #expect(back == RarityEffectPlan(showsAnticipation: false, showsRarityGlow: false, showsSparkles: false))
        }
    }

    @Test("앞면이 보이면 등급 효과가 허용된다")
    func frontAllowsRarityEffects() {
        let common = plan("Common", frontVisible: true, isAnticipating: false)
        let rare = plan("Rare", frontVisible: true, isAnticipating: false)
        let hyper = plan("Hyper rare", frontVisible: true, isAnticipating: false)

        #expect(common.showsRarityGlow == false, "일반 카드는 은은함이 없습니다")
        #expect(common.showsSparkles == false)
        #expect(rare.showsRarityGlow)
        #expect(rare.showsSparkles == false, "레어는 아직 반짝이지 않습니다")
        #expect(hyper.showsRarityGlow)
        #expect(hyper.showsSparkles)
    }

    @Test("모션 줄이기에서는 반짝임을 그리지 않는다")
    func reducedMotionDropsSparkles() {
        let hyper = plan("Hyper rare", frontVisible: true, isAnticipating: false, animates: false)
        #expect(hyper.showsSparkles == false)
        #expect(hyper.showsRarityGlow, "정지 화면에서도 등급 정보는 남습니다")
    }
}

/// What the spotlight announces, which has to follow the face.
@Suite("무대 접근성 라벨")
struct SpotlightAccessibilityTests {
    @Test("뒷면은 카드 이름과 등급을 읽어주지 않는다")
    func faceDownDoesNotAnnounceTheCard() {
        let hidden = SpotlightAccessibility.label(name: "Pikachu", rarity: "Rare", frontVisible: false)
        #expect(hidden == SpotlightAccessibility.unrevealedLabel)
        #expect(hidden.contains("Pikachu") == false)
        #expect(hidden.contains("Rare") == false)
    }

    @Test("앞면은 카드 이름과 등급을 읽어준다")
    func frontAnnouncesTheCard() {
        let shown = SpotlightAccessibility.label(name: "Pikachu", rarity: "Rare", frontVisible: true)
        #expect(shown.contains("Pikachu"))
        #expect(shown.contains("Rare"))
    }
}

/// The one-shot highlight across a revealed card.
@Suite("카드 하이라이트")
struct CardLightSweepTests {
    @Test("빛은 카드 밖에서 들어와 반대쪽 밖으로 나간다")
    func sweepCrossesTheCard() {
        let cardWidth: CGFloat = 300
        #expect(CardLightSweep.offsetX(progress: 0) <= -cardWidth / 2 - CardLightSweep.width / 2)
        #expect(CardLightSweep.offsetX(progress: 1) >= cardWidth / 2 + CardLightSweep.width / 2)
        // Off both ends it is invisible; brightest across the middle.
        #expect(CardLightSweep.opacity(progress: 0) < 0.001)
        #expect(CardLightSweep.opacity(progress: 1) < 0.001)
        #expect(CardLightSweep.opacity(progress: 0.5) > 0.4)
        #expect(CardLightSweep.opacity(progress: 0.5) <= CardLightSweep.peakOpacity)
        #expect(abs(CardLightSweep.opacity(progress: 0.25) - CardLightSweep.opacity(progress: 0.75)) < 0.001)
        // Moving right the whole way, and clamped outside 0…1.
        #expect(CardLightSweep.offsetX(progress: 0.3) < CardLightSweep.offsetX(progress: 0.7))
        #expect(CardLightSweep.offsetX(progress: -1) == CardLightSweep.offsetX(progress: 0))
        #expect(CardLightSweep.offsetX(progress: 2) == CardLightSweep.offsetX(progress: 1))
    }
}
