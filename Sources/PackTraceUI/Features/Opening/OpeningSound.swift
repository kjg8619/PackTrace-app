import AVFoundation
import Combine
import Foundation
import PackTraceCore

/// Sounds the opening can make.
///
/// Cues are semantic — "a card turned over" — and never file names: the views
/// and the engine only ever say which moment happened, and `resourceName` is the
/// single place that knows which bundled file goes with it. Every file is an
/// original, synthesised by `scripts/generate-opening-sounds.py`.
public enum OpeningSoundCue: String, CaseIterable, Sendable {
    case tear = "pack-tear"
    case cardSlide = "card-slide"
    case cardFlip = "card-flip"
    case rareReveal = "rare-reveal"
    case specialReveal = "special-reveal"
    case summary

    var resourceName: String { rawValue }
}

extension RarityAnimationProfile {
    /// The sound a card makes once its front is on screen, if its tier has one.
    ///
    /// `soundKey` is the override seam: a profile that names a cue plays that
    /// one. Otherwise the tier decides — rares chime, the top tiers get the wider
    /// chime, and commons and uncommons only make the flip itself.
    var revealSoundCue: OpeningSoundCue? {
        if let soundKey, let cue = OpeningSoundCue(rawValue: soundKey) {
            return cue
        }
        switch Self.tier(for: rarity) {
        case 0, 1: return nil
        case 2, 3: return .rareReveal
        default: return .specialReveal
        }
    }
}

/// One sound, and when it plays relative to the transition that caused it.
struct PlannedSoundCue: Equatable, Sendable {
    var cue: OpeningSoundCue
    var delay: Duration
    var volume: Float
}

/// Which sounds a state change makes. Pure, so the mapping can be tested
/// without an audio device.
///
/// Sounds follow the same timeline the view plays (`CardRevealTimeline`): the
/// flip sound when the card starts turning, the rarity chime when the front is
/// on screen, the slide when it moves into the stack. With reduced motion the
/// reveal is instant, so each card makes one sound, a little quieter, instead of
/// three on top of each other.
enum OpeningSoundPlan {
    /// Chimes are softened when motion is reduced: the information stays, the
    /// emphasis does not.
    static let reducedMotionVolume: Float = 0.7

    static func cues(
        from previous: PackOpeningEngine.State,
        to next: PackOpeningEngine.State,
        card: PackOpeningCard?,
        timing: PackOpeningTiming
    ) -> [PlannedSoundCue] {
        let instant = timing.isInstant
        switch next {
        case .packOpening:
            return [PlannedSoundCue(cue: .tear, delay: .zero, volume: 1)]

        case .cardsRise:
            // The bundle coming out of the pack. Nothing moves with reduced motion.
            return instant ? [] : [PlannedSoundCue(cue: .cardSlide, delay: .zero, volume: 1)]

        case .cardRevealing:
            guard let card else { return [] }
            let profile = card.rarityProfile
            let chime = profile.revealSoundCue
            if instant {
                return [
                    PlannedSoundCue(
                        cue: chime ?? .cardFlip,
                        delay: .zero,
                        volume: chime == nil ? 1 : reducedMotionVolume
                    ),
                ]
            }
            let timeline = CardRevealTimeline.make(profile: profile, timing: timing)
            var cues = [PlannedSoundCue(cue: .cardFlip, delay: timeline.anticipation, volume: 1)]
            if let chime {
                // The front is the face on screen from the halfway point of the turn
                // (`CardRevealModel.frontVisible`), never before.
                cues.append(PlannedSoundCue(cue: chime, delay: timeline.anticipation + timeline.flip / 2, volume: 1))
            }
            cues.append(
                PlannedSoundCue(
                    cue: .cardSlide,
                    delay: timeline.anticipation + timeline.flip + timeline.settle,
                    volume: 1
                )
            )
            return cues

        case .summary:
            // Only the end of an opening that played here: reopening a finished
            // pack goes straight to its summary and makes no sound.
            guard previous != .idle else { return [] }
            return [PlannedSoundCue(cue: .summary, delay: .zero, volume: 1)]

        case .idle, .packEnter, .packReady, .cardWaiting, .complete:
            return []
        }
    }
}

/// Where cues end up. The app plays bundled files; tests record what was asked.
@MainActor
protocol OpeningSoundOutput: AnyObject {
    func play(_ cue: OpeningSoundCue, volume: Float)
}

/// Plays the bundled cue files.
///
/// Nothing is loaded until the first cue is actually played, so with sound
/// turned off the audio stack is never touched. One player per cue is kept and
/// restarted, which is enough for sounds this short.
@MainActor
final class OpeningSoundPlayer: OpeningSoundOutput {
    static let shared = OpeningSoundPlayer()

    private var players: [OpeningSoundCue: AVAudioPlayer] = [:]
    private var missing: Set<OpeningSoundCue> = []

    static func url(for cue: OpeningSoundCue) -> URL? {
        Bundle.module.url(forResource: cue.resourceName, withExtension: "wav", subdirectory: "sounds")
    }

    func play(_ cue: OpeningSoundCue, volume: Float) {
        guard let player = player(for: cue) else { return }
        player.volume = volume
        player.currentTime = 0
        player.play()
    }

    private func player(for cue: OpeningSoundCue) -> AVAudioPlayer? {
        if let player = players[cue] { return player }
        guard !missing.contains(cue) else { return nil }
        // A missing or unreadable file only silences that cue; the opening
        // itself never depends on sound.
        guard let url = Self.url(for: cue), let player = try? AVAudioPlayer(contentsOf: url) else {
            missing.insert(cue)
            return nil
        }
        player.prepareToPlay()
        players[cue] = player
        return player
    }
}

/// Turns the engine's state changes into sounds.
///
/// It listens to the semantic state only — never to view updates — so a
/// re-render cannot play anything twice, and each transition is planned once.
/// Any sound still waiting for its moment is dropped when the state moves on:
/// skipping mid-card or closing the sheet leaves nothing queued behind.
@MainActor
final class OpeningSoundDirector {
    private let timing: PackOpeningTiming
    private let isEnabled: () -> Bool
    private let makeOutput: () -> OpeningSoundOutput
    private var output: OpeningSoundOutput?
    private var cardAt: (Int) -> PackOpeningCard?
    private var lastState: PackOpeningEngine.State = .idle
    private var pending: [Task<Void, Never>] = []
    private var subscription: AnyCancellable?

    /// Delay hook, like the engine's: tests replace it to hold a cue.
    var sleep: (Duration) async -> Void = { duration in
        guard duration > .zero else { return }
        try? await Task.sleep(for: duration)
    }

    init(
        timing: PackOpeningTiming,
        isEnabled: @escaping () -> Bool,
        output: @escaping () -> OpeningSoundOutput,
        card: @escaping (Int) -> PackOpeningCard? = { _ in nil }
    ) {
        self.timing = timing
        self.isEnabled = isEnabled
        self.makeOutput = output
        self.cardAt = card
    }

    /// Follows one engine for the rest of its life.
    func attach(to engine: PackOpeningEngine) {
        cardAt = { [weak engine] index in
            guard let engine, engine.cards.indices.contains(index) else { return nil }
            return engine.cards[index]
        }
        lastState = engine.state
        // `$state` publishes before the property changes, with the new value;
        // the engine never publishes the same state twice in a row.
        subscription = engine.$state
            .dropFirst()
            .sink { [weak self] next in
                MainActor.assumeIsolated { self?.handle(next) }
            }
    }

    /// One state change: drops what the previous one still had queued, then
    /// schedules this one's sounds.
    func handle(_ next: PackOpeningEngine.State) {
        guard next != lastState else { return }
        let previous = lastState
        lastState = next
        cancelPending()
        guard isEnabled() else { return }

        let card: PackOpeningCard? = if case let .cardRevealing(index) = next { cardAt(index) } else { nil }
        let planned = OpeningSoundPlan.cues(from: previous, to: next, card: card, timing: timing)
            .enumerated()
            .sorted { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }
            .map(\.element)
        let immediate = planned.prefix { $0.delay == .zero }
        let later = Array(planned.dropFirst(immediate.count))
        for cue in immediate { emit(cue) }
        guard !later.isEmpty else { return }
        // One task plays the rest in order, so two cues close together can never
        // swap places. Each waits until its own moment measured from the
        // transition, not from the cue before it: waking late for one cue would
        // otherwise push every later one back too, until the last of a card fell
        // after the engine had moved on and was dropped.
        let started = ContinuousClock.now
        let task = Task { [weak self] in
            for cue in later {
                // Nothing holds the director across the wait.
                guard let sleep = self?.sleep else { return }
                let remaining = started.advanced(by: cue.delay) - ContinuousClock.now
                await sleep(max(remaining, .zero))
                guard !Task.isCancelled, let self else { return }
                self.emit(cue)
            }
        }
        pending.append(task)
    }

    /// Stops everything still waiting. Called on every transition and when the
    /// scene goes away.
    func cancelPending() {
        for task in pending { task.cancel() }
        pending.removeAll()
    }

    func detach() {
        cancelPending()
        subscription?.cancel()
        subscription = nil
    }

    private func emit(_ planned: PlannedSoundCue) {
        // Checked again at the moment of playing: turning sound off mid-opening
        // silences the rest of it.
        guard isEnabled() else { return }
        if output == nil { output = makeOutput() }
        output?.play(planned.cue, volume: planned.volume)
    }
}
