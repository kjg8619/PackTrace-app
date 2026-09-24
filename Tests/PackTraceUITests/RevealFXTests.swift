import CoreGraphics
import Foundation
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The post-reveal effects: which tier gets what, that nothing rarity-specific
/// shows before the front, that reduced motion keeps only the static glow, and
/// that the one-shot pieces are bounded and deterministic.
@Suite("등급 공개 효과")
struct RevealFXTests {
    private func profile(_ rarity: String) -> RarityAnimationProfile {
        RarityAnimationProfile(rarity: CardRarity(rawValue: rarity))
    }

    private func plan(_ rarity: String, frontVisible: Bool, animates: Bool = true) -> RarityEffectPlan {
        RarityEffectPlan.make(
            profile: profile(rarity),
            frontVisible: frontVisible,
            isAnticipating: false,
            animates: animates
        )
    }

    static let allRarities = [
        "Common", "Uncommon", "Rare", "Double rare", "Ultra Rare", "Illustration rare",
        "Special illustration rare", "Hyper rare",
    ]

    @Test("앞면 전에는 어느 등급도 등급 효과가 없다")
    func nothingBeforeTheFront() {
        for rarity in Self.allRarities {
            let hidden = plan(rarity, frontVisible: false)
            #expect(hidden.showsRarityGlow == false, "\(rarity)")
            #expect(hidden.sparkleCount == 0, "\(rarity)")
            #expect(hidden.showsBurst == false, "\(rarity)")
        }
    }

    @Test("앞면 뒤 효과는 tier를 따른다: 레어 glow, 더블 레어 반짝임, 최상위 halo")
    func tiersAfterTheFront() {
        let common = plan("Common", frontVisible: true)
        #expect(common.showsRarityGlow == false && common.sparkleCount == 0 && !common.showsBurst)

        let rare = plan("Rare", frontVisible: true)
        #expect(rare.showsRarityGlow && rare.sparkleCount == 0 && !rare.showsBurst)

        let doubleRare = plan("Double rare", frontVisible: true)
        #expect(doubleRare.showsRarityGlow && doubleRare.sparkleCount == 4 && !doubleRare.showsBurst)

        for rarity in ["Ultra Rare", "Illustration rare"] {
            let ultra = plan(rarity, frontVisible: true)
            #expect(ultra.showsRarityGlow && ultra.sparkleCount == 6 && !ultra.showsBurst, "\(rarity)")
            #expect(profile(rarity).ultraSweep && !profile(rarity).foilSweep, "\(rarity): 흰 빛 한 번")
        }
        for rarity in ["Special illustration rare", "Hyper rare"] {
            let top = plan(rarity, frontVisible: true)
            #expect(top.showsRarityGlow && top.sparkleCount == RevealFX.maxSparkles && top.showsBurst, "\(rarity)")
            #expect(profile(rarity).ultraSweep && profile(rarity).foilSweep, "\(rarity): 홀로그램 빛")
        }
        // Sparkles and the flag agree, and never exceed the bound.
        for rarity in Self.allRarities {
            let shown = plan(rarity, frontVisible: true)
            #expect(shown.showsSparkles == (shown.sparkleCount > 0), "\(rarity)")
            #expect(shown.sparkleCount <= RevealFX.maxSparkles, "\(rarity)")
        }
    }

    @Test("모션 줄이기는 움직이는 효과를 모두 끄고 정지된 glow만 남긴다")
    func reducedMotionKeepsOnlyTheGlow() {
        for rarity in ["Rare", "Double rare", "Ultra Rare", "Hyper rare"] {
            let still = plan(rarity, frontVisible: true, animates: false)
            #expect(still.showsRarityGlow, "\(rarity): 등급 정보는 남습니다")
            #expect(still.sparkleCount == 0 && !still.showsSparkles, "\(rarity)")
            #expect(still.showsBurst == false, "\(rarity)")
            let timeline = CardRevealTimeline.make(profile: profile(rarity), timing: .instant)
            #expect(timeline.sweep == false && timeline.fx == .zero && timeline.foil == false, "\(rarity)")
        }
    }

    @Test("반짝임은 고정 위치·8개 이하·한 번씩만 보인다")
    func sparklesAreFixedAndOneShot() {
        #expect(RevealFX.sparkles(count: 20).count == RevealFX.maxSparkles)
        #expect(RevealFX.sparkles(count: -1).isEmpty)
        // Deterministic: the same count gives the same layout, and a smaller
        // count is a prefix of a larger one.
        #expect(RevealFX.sparkles(count: 8) == RevealFX.sparkles(count: 8))
        #expect(Array(RevealFX.sparkles(count: 8).prefix(4)) == RevealFX.sparkles(count: 4))
        for sparkle in RevealFX.sparkles(count: 8) {
            // Each window closes inside the play, and nothing shows at either end.
            #expect(sparkle.start + RevealFX.sparkleWindow <= 1)
            #expect(RevealFX.sparkleOpacity(sparkle, progress: 0) == 0)
            #expect(RevealFX.sparkleOpacity(sparkle, progress: 1) == 0)
            #expect(RevealFX.sparkleOpacity(sparkle, progress: sparkle.start + RevealFX.sparkleWindow / 2) > 0.99)
            // Outside the card's centre: sparkles frame the card, not its art.
            #expect(abs(sparkle.offset.width) > 50 || abs(sparkle.offset.height) > 190)
        }
    }

    @Test("halo는 0.75→1.2로 커지며 0.45→0으로 사라지고, 끝나면 그리지 않는다")
    func burstIsOneShot() {
        #expect(abs(RevealFX.burstScale(progress: 0) - 0.75) < 0.0001)
        #expect(abs(RevealFX.burstScale(progress: 1) - 1.2) < 0.0001)
        #expect(abs(RevealFX.burstOpacity(progress: 0) - 0.45) < 0.0001)
        #expect(RevealFX.burstOpacity(progress: 1) == 0)
        #expect(RevealFX.burstScale(progress: 0.3) < RevealFX.burstScale(progress: 0.6))
        #expect(RevealFX.isPlaying(0) == false)
        #expect(RevealFX.isPlaying(1) == false)
        #expect(RevealFX.isPlaying(0.5))
    }

    @Test("효과는 앞면이 보인 뒤 시작해 카드가 떠나기 전에 끝난다")
    func fxFitsBeforeTheTransfer() {
        for rarity in Self.allRarities {
            let p = profile(rarity)
            let timeline = CardRevealTimeline.make(profile: p, timing: .standard)
            if p.sparkleCount > 0 || p.burst {
                #expect(timeline.fx > .zero, "\(rarity)")
            } else {
                #expect(timeline.fx == .zero, "\(rarity)")
            }
            // Starts at flip / 2 (front on screen); the card leaves at flip + settle.
            #expect(timeline.flip / 2 + timeline.fx <= timeline.flip + timeline.settle, "\(rarity)")
            #expect(timeline.fx <= RevealFX.duration)
        }
    }

    @Test("홀로그램 빛은 흰 빛보다 옅고, 양 끝에서는 보이지 않는다")
    func foilSweepIsFainter() {
        #expect(CardLightSweep.opacity(progress: 0.5, foil: true) < CardLightSweep.opacity(progress: 0.5, foil: false))
        #expect(CardLightSweep.opacity(progress: 0.5, foil: true) > 0.2)
        #expect(CardLightSweep.opacity(progress: 0, foil: true) < 0.001)
        #expect(CardLightSweep.opacity(progress: 1, foil: true) < 0.001)
    }

    @Test("다음 카드가 기다리는 동안은 이전 카드의 앞면·효과 값이 남아 있어도 뒷면으로 본다")
    func waitingCardNeverBorrowsThePreviousFront() {
        // The model still holds the last card's finished reveal.
        let stale = RevealStagePhase.make(
            isRevealing: false,
            turn: 0,
            transferProgress: 1,
            frontVisible: true,
            anticipating: true,
            sweep: 0.5,
            fx: 0.5
        )
        #expect(stale == .faceDown)
        #expect(stale.turn == 1 && stale.frontVisible == false && stale.fx == 0 && stale.sweep == 0)
        // While revealing, the model's values are used as they are.
        let live = RevealStagePhase.make(
            isRevealing: true,
            turn: 0.2,
            transferProgress: 0.1,
            frontVisible: true,
            anticipating: false,
            sweep: 0.3,
            fx: 0.4
        )
        #expect(live.turn == 0.2 && live.frontVisible && live.fx == 0.4 && live.sweep == 0.3)
    }
}

/// The reveal model's one-shot effect progress.
@Suite("공개 효과 진행")
@MainActor
struct RevealFXModelTests {
    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private let timing = PackOpeningTiming(
        packEnter: .zero,
        packShake: .zero,
        cardsRise: .zero,
        cardFlip: .milliseconds(120),
        cardSettle: .milliseconds(40),
        cardTransfer: .milliseconds(40),
        summarySettle: .zero
    )

    @Test("효과 진행은 앞면이 보인 뒤에만 움직이고, 리셋하면 0으로 돌아간다")
    func fxStartsWithTheFrontAndResets() async {
        let hyper = RarityAnimationProfile(rarity: CardRarity(rawValue: "Hyper rare"))
        let model = CardRevealModel()
        model.reveal(CardRevealTimeline.make(profile: hyper, timing: timing), instant: false)
        #expect(model.fx == 0, "뒷면일 때는 효과가 없습니다")
        await waitUntil { model.frontVisible }
        await waitUntil { model.fx > 0 }
        #expect(model.fx == 1)
        model.reset()
        #expect(model.fx == 0)
        #expect(model.phase(isRevealing: true).fx == 0)
    }

    @Test("효과가 없는 등급과 모션 줄이기는 효과 진행이 0에 머문다")
    func noFXForPlainTiersOrReducedMotion() async {
        let common = RarityAnimationProfile(rarity: CardRarity(rawValue: "Common"))
        let model = CardRevealModel()
        model.reveal(CardRevealTimeline.make(profile: common, timing: timing), instant: false)
        await waitUntil { model.transferProgress > 0 }
        #expect(model.fx == 0)

        let hyper = RarityAnimationProfile(rarity: CardRarity(rawValue: "Hyper rare"))
        let still = CardRevealModel()
        still.reveal(CardRevealTimeline.make(profile: hyper, timing: .instant), instant: true)
        #expect(still.frontVisible)
        #expect(still.fx == 0, "Reduced Motion에서는 halo·반짝임이 움직이지 않습니다")
        #expect(still.sweep == 0)
    }
}
