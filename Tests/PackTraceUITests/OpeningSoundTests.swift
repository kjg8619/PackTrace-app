import AVFoundation
import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Opening sounds: which moment makes which sound, that nothing plays when sound
/// is off, and that skipping leaves nothing queued. No audio device is used — the
/// output is a recorder — except for decoding the bundled files.
@Suite("개봉 효과음")
@MainActor
struct OpeningSoundTests {
    // MARK: - Fixtures

    /// Records what the director asked to play, and whether it was ever created.
    @MainActor
    final class Recorder: OpeningSoundOutput {
        var played: [OpeningSoundCue] = []
        var volumes: [Float] = []
        func play(_ cue: OpeningSoundCue, volume: Float) {
            played.append(cue)
            volumes.append(volume)
        }
    }

    @MainActor
    final class Switch {
        var on: Bool
        var outputsMade = 0
        init(_ on: Bool) { self.on = on }
    }

    /// Holds a delayed cue until the test lets it go.
    @MainActor
    final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    static let library: CatalogLibrary = try! CatalogLoader.bundledLibrary()

    static func card(_ rarity: String, position: Int = 0) throws -> PackOpeningCard {
        // Scarlet & Violet main sets, whose rarity names the cue plan was
        // written against (other eras have their own rarity names).
        let definition = try #require(
            library.catalogs.keys.sorted()
                .compactMap { library.catalog(version: $0) }
                .filter { $0.set.externalSetID.range(of: #"^sv\d+$"#, options: .regularExpression) != nil }
                .flatMap(\.cards)
                .first { $0.rarity.rawValue == rarity },
            "번들 카탈로그에 \(rarity) 카드가 있어야 합니다"
        )
        return PackOpeningCard(position: position, card: definition, variant: definition.primaryVariant, isNew: false)
    }

    /// A short timing so a full animated run takes about a second. Rarity still
    /// adds its own anticipation and hold on top.
    static let quick = PackOpeningTiming(
        packEnter: .milliseconds(5),
        packShake: .milliseconds(5),
        cardsRise: .milliseconds(5),
        cardFlip: .milliseconds(10),
        cardSettle: .milliseconds(5),
        // Wide enough that the slide (due when the transfer starts) is never
        // raced by the engine leaving the card, even with the whole suite running
        // in parallel (40 ms was not, under verify.sh's load).
        cardTransfer: .milliseconds(150),
        summarySettle: .milliseconds(5)
    )

    /// Generous: every UI suite shares the main actor, and with the whole
    /// suite running another test's set-up can hold it for seconds. What is
    /// checked is the order of cues, not how fast they come.
    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func previewEngine(_ cards: [PackOpeningCard], timing: PackOpeningTiming) -> PackOpeningEngine {
        PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: nil,
                productName: "미리보기",
                catalogVersion: "test",
                recipeVersion: 1,
                product: nil,
                cards: cards,
                revealedCount: 0,
                isPreview: true
            ),
            openPack: nil,
            resolveCards: { _ in cards },
            reveal: PreviewOpeningReveal(total: cards.count),
            timing: timing
        )
    }

    /// Plays one whole opening — tear, every card, summary — and returns what was
    /// heard and what was obtained.
    private func runOpening(
        cards: [PackOpeningCard],
        timing: PackOpeningTiming,
        soundOn: Bool
    ) async -> (played: [OpeningSoundCue], volumes: [Float], outputsMade: Int, result: [String], revealed: Int) {
        let engine = previewEngine(cards, timing: timing)
        let recorder = Recorder()
        let sound = Switch(soundOn)
        let director = OpeningSoundDirector(
            timing: timing,
            isEnabled: { sound.on },
            output: {
                sound.outputsMade += 1
                return recorder
            }
        )
        director.attach(to: engine)
        engine.start()
        await waitUntil { engine.acceptsTearInput }
        #expect(engine.acceptsTearInput, "팩이 뜯을 수 있는 상태가 되지 않았습니다: \(engine.state.name)")
        engine.tear()
        // Generous: the cue order is what is checked, not the speed, and the
        // main actor is shared with the rest of the suite.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while engine.state != .summary, ContinuousClock.now < deadline {
            await waitUntil { engine.acceptsAdvanceInput || engine.state == .summary }
            if engine.acceptsAdvanceInput { engine.advance() }
        }
        // Let anything still queued have its chance to (wrongly) play.
        try? await Task.sleep(for: .milliseconds(60))
        director.detach()
        let result = engine.cards.map { "\($0.position):\($0.card.key.rawValue)#\($0.variant.rawValue)" }
        return (recorder.played, recorder.volumes, sound.outputsMade, result, engine.revealedCount)
    }

    // MARK: - Mapping

    @Test("공개 소리는 등급 tier로 정해지고, 앞면 전에는 없다")
    func rarityToCue() throws {
        #expect(RarityAnimationProfile(rarity: CardRarity(rawValue: "Common")).revealSoundCue == nil)
        #expect(RarityAnimationProfile(rarity: CardRarity(rawValue: "Uncommon")).revealSoundCue == nil)
        #expect(RarityAnimationProfile(rarity: CardRarity(rawValue: "Rare")).revealSoundCue == .rareReveal)
        #expect(RarityAnimationProfile(rarity: CardRarity(rawValue: "Double rare")).revealSoundCue == .rareReveal)
        for top in ["Ultra Rare", "Illustration rare", "Special illustration rare", "Hyper rare"] {
            #expect(RarityAnimationProfile(rarity: CardRarity(rawValue: top)).revealSoundCue == .specialReveal, "\(top)")
        }
        // `soundKey` is the override seam.
        let overridden = RarityAnimationProfile(rarity: CardRarity(rawValue: "Common"), soundKey: "rare-reveal")
        #expect(overridden.revealSoundCue == .rareReveal)
    }

    @Test("카드 한 장의 소리는 연출 타임라인을 따르고, 등급 소리는 앞면이 보인 뒤에만 난다")
    func cardCuesFollowTheTimeline() throws {
        for rarity in ["Common", "Rare", "Double rare", "Ultra Rare", "Hyper rare"] {
            let card = try Self.card(rarity)
            let timeline = CardRevealTimeline.make(profile: card.rarityProfile, timing: .standard)
            let cues = OpeningSoundPlan.cues(
                from: .cardWaiting(nextIndex: 0),
                to: .cardRevealing(index: 0),
                card: card,
                timing: .standard
            )
            #expect(cues.first == PlannedSoundCue(cue: .cardFlip, delay: timeline.anticipation, volume: 1), "\(rarity)")
            #expect(cues.last?.cue == .cardSlide, "\(rarity)")
            if let chime = card.rarityProfile.revealSoundCue {
                let planned = try #require(cues.first { $0.cue == chime })
                #expect(planned.delay >= timeline.anticipation + timeline.flip / 2, "\(rarity): 등급 소리가 앞면보다 먼저입니다")
            } else {
                #expect(!cues.contains { $0.cue == .rareReveal || $0.cue == .specialReveal }, "\(rarity)")
            }
            // Everything a card plays happens while that card is still on stage.
            for planned in cues {
                #expect(planned.delay < timeline.total, "\(rarity): \(planned.cue) 가 카드가 떠난 뒤에 납니다")
            }
        }
    }

    @Test("모션 줄이기에서는 카드마다 소리 하나, 등급 소리는 작게 유지된다")
    func reducedMotionPlaysOneQuieterCuePerCard() throws {
        let common = try Self.card("Common")
        let hyper = try Self.card("Hyper rare")
        #expect(OpeningSoundPlan.cues(from: .cardWaiting(nextIndex: 0), to: .cardRevealing(index: 0), card: common, timing: .instant)
            == [PlannedSoundCue(cue: .cardFlip, delay: .zero, volume: 1)])
        #expect(OpeningSoundPlan.cues(from: .cardWaiting(nextIndex: 0), to: .cardRevealing(index: 0), card: hyper, timing: .instant)
            == [PlannedSoundCue(cue: .specialReveal, delay: .zero, volume: OpeningSoundPlan.reducedMotionVolume)])
        // Nothing rises with reduced motion, so the bundle makes no sound.
        #expect(OpeningSoundPlan.cues(from: .packOpening, to: .cardsRise, card: nil, timing: .instant).isEmpty)
        #expect(OpeningSoundPlan.cues(from: .packOpening, to: .cardsRise, card: nil, timing: .standard).map(\.cue) == [.cardSlide])
    }

    @Test("뜯기와 요약만 소리가 나고, 끝난 팩을 다시 열 때는 요약 소리가 없다")
    func stageCues() {
        #expect(OpeningSoundPlan.cues(from: .packReady, to: .packOpening, card: nil, timing: .standard).map(\.cue) == [.tear])
        #expect(OpeningSoundPlan.cues(from: .cardRevealing(index: 9), to: .summary, card: nil, timing: .standard).map(\.cue) == [.summary])
        // Skip from a waiting card still ends the opening.
        #expect(OpeningSoundPlan.cues(from: .cardWaiting(nextIndex: 3), to: .summary, card: nil, timing: .standard).map(\.cue) == [.summary])
        // A finished opening reopened from storage: straight to the summary, silent.
        #expect(OpeningSoundPlan.cues(from: .idle, to: .summary, card: nil, timing: .standard).isEmpty)
        for silent: PackOpeningEngine.State in [.packEnter, .packReady, .cardWaiting(nextIndex: 1), .complete, .idle] {
            #expect(OpeningSoundPlan.cues(from: .packEnter, to: silent, card: nil, timing: .standard).isEmpty, "\(silent.name)")
        }
    }

    // MARK: - Director

    @Test("소리를 끄면 오디오 출력이 만들어지지도 않고 아무 소리도 나지 않는다")
    func soundOffNeverTouchesAudio() async throws {
        let cards = [try Self.card("Common", position: 0), try Self.card("Hyper rare", position: 1)]
        let run = await runOpening(cards: cards, timing: .instant, soundOn: false)
        #expect(run.played.isEmpty)
        #expect(run.outputsMade == 0, "소리가 꺼져 있으면 오디오를 초기화하지 않습니다")
        #expect(run.revealed == cards.count)
    }

    @Test("모션·소리 네 조합 모두 같은 카드 결과를 남기고, 소리는 설정대로만 난다")
    func motionAndSoundMatrix() async throws {
        let cards = [
            try Self.card("Common", position: 0),
            try Self.card("Rare", position: 1),
            try Self.card("Hyper rare", position: 2),
        ]
        var results: [[String]] = []
        for (timing, motionLabel) in [(Self.quick, "motion on"), (PackOpeningTiming.instant, "motion off")] {
            for soundOn in [true, false] {
                let run = await runOpening(cards: cards, timing: timing, soundOn: soundOn)
                results.append(run.result)
                #expect(run.revealed == cards.count, "\(motionLabel) sound \(soundOn)")
                guard soundOn else {
                    #expect(run.played.isEmpty, "\(motionLabel): 소리 끔")
                    continue
                }
                if timing.isInstant {
                    // One cue per card, no rise, and the chimes quieter.
                    #expect(run.played == [.tear, .cardFlip, .rareReveal, .specialReveal, .summary], "\(motionLabel)")
                    #expect(run.volumes == [1, 1, OpeningSoundPlan.reducedMotionVolume, OpeningSoundPlan.reducedMotionVolume, 1])
                } else {
                    #expect(run.played == [
                        .tear, .cardSlide,
                        .cardFlip, .cardSlide,
                        .cardFlip, .rareReveal, .cardSlide,
                        .cardFlip, .specialReveal, .cardSlide,
                        .summary,
                    ], "\(motionLabel)")
                }
            }
        }
        #expect(Set(results.map { $0.joined(separator: ",") }).count == 1, "설정 조합과 무관하게 같은 결과여야 합니다")
    }

    @Test("건너뛰면 대기 중이던 소리는 버려지고 요약 소리만 난다")
    func skipDropsQueuedCues() async throws {
        let rare = try Self.card("Rare")
        let recorder = Recorder()
        let gate = Gate()
        let director = OpeningSoundDirector(
            timing: .standard,
            isEnabled: { true },
            output: { recorder },
            card: { _ in rare }
        )
        director.sleep = { _ in await gate.wait() }
        director.handle(.cardWaiting(nextIndex: 0))
        director.handle(.cardRevealing(index: 0))
        // The rare card holds before the turn, so every one of its cues is queued.
        #expect(recorder.played.isEmpty)
        director.handle(.summary)
        gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(recorder.played == [.summary], "건너뛴 카드의 소리가 뒤늦게 나면 안 됩니다")
    }

    @Test("같은 상태가 다시 들어와도 소리는 한 번만 난다")
    func repeatedStateDoesNotReplay() {
        let recorder = Recorder()
        let director = OpeningSoundDirector(timing: .standard, isEnabled: { true }, output: { recorder })
        director.handle(.packReady)
        director.handle(.packOpening)
        director.handle(.packOpening)
        #expect(recorder.played == [.tear])
    }

    @Test("재생 직전에 소리를 끄면 대기 중인 소리도 나지 않는다")
    func turningSoundOffSilencesQueuedCues() async throws {
        let rare = try Self.card("Rare")
        let recorder = Recorder()
        let gate = Gate()
        let sound = Switch(true)
        let director = OpeningSoundDirector(
            timing: .standard,
            isEnabled: { sound.on },
            output: { recorder },
            card: { _ in rare }
        )
        director.sleep = { _ in await gate.wait() }
        director.handle(.cardWaiting(nextIndex: 0))
        director.handle(.cardRevealing(index: 0))
        sound.on = false
        gate.open()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(recorder.played.isEmpty)
    }

    // MARK: - Bundled files

    @Test("모든 소리 파일이 번들에 있고 짧은 모노 오디오로 디코딩된다")
    func bundledFilesDecode() throws {
        for cue in OpeningSoundCue.allCases {
            let url = try #require(OpeningSoundPlayer.url(for: cue), "\(cue.resourceName).wav 가 번들에 없습니다")
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect(file.fileFormat.channelCount == 1, "\(cue)")
            #expect(file.fileFormat.sampleRate == 44_100, "\(cue)")
            #expect(seconds > 0.05 && seconds < 1.5, "\(cue): \(seconds)s")
            // Not silence: the loudest sample is well above the noise floor.
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try #require(buffer.floatChannelData?[0])
            var peak: Float = 0
            for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[index])) }
            #expect(peak > 0.1 && peak < 1.0, "\(cue): peak \(peak)")
        }
    }
}
