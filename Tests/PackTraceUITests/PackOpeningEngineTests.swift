import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The opening presentation's state machine.
///
/// The cards are committed by the store before any of this runs, so these tests
/// check the things the animation is responsible for: the state order, the input
/// lock, skip, and that the stored result is never touched by presentation.
@Suite("팩 개봉 연출 상태 기계")
@MainActor
struct PackOpeningEngineTests {
    // MARK: - Fixtures

    private func makeEnvironment(seed: UInt64 = 7) async throws -> (AppEnvironment, URL, PackInstanceRecord) {
        let root = try StoreLocation.temporary(label: "packtrace-opening-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = seed
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        let pack = try #require(await environment.exchangeRandomPack())
        return (environment, root, pack)
    }

    /// Game cards in the pack the seed drew: packs differ in size by era.
    private func packSize(_ pack: PackInstanceRecord, in environment: AppEnvironment) -> Int? {
        guard let product = environment.product(for: pack) else { return nil }
        return environment.library?.catalog(version: pack.catalogVersion)?.recipe(id: product.recipeID)?.packSize
    }

    /// Engine wired to the real store, with a controllable delay hook.
    private func makeStoredEngine(
        environment: AppEnvironment,
        pack: PackInstanceRecord,
        timing: PackOpeningTiming = .instant
    ) -> PackOpeningEngine {
        PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: pack.id,
                productName: environment.product(for: pack)?.name ?? pack.productID,
                catalogVersion: pack.catalogVersion,
                recipeVersion: pack.recipeVersion,
                product: environment.product(for: pack),
                cards: [],
                revealedCount: 0
            ),
            openPack: { [environment] in try? await environment.openPack(pack.id) },
            resolveCards: { record in
                await PackOpeningSceneModel.resolve(record, environment: environment)
            },
            reveal: PreviewOpeningReveal(total: 0),
            revealAfterOpen: { [environment] record in
                StoreOpeningReveal(environment: environment, openingID: record.id)
            },
            timing: timing
        )
    }

    /// Records the state sequence and lets a test hold a state open.
    private func recorder(_ engine: PackOpeningEngine) -> Recorder {
        let recorder = Recorder()
        engine.onStateChange = { [weak recorder] state in recorder?.states.append(state.name) }
        return recorder
    }

    @MainActor
    private final class Recorder {
        var states: [String] = []
    }

    /// A gate that keeps the engine inside a state until the test releases it.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    /// Waits until the engine accepts the next reveal, which is the documented
    /// contract for input (anything mid-stage is ignored on purpose).
    private func waitForAdvance(_ engine: PackOpeningEngine) async {
        await waitUntil { engine.acceptsAdvanceInput }
    }

    private func waitForCards(_ engine: PackOpeningEngine) async {
        await waitUntil { !engine.cards.isEmpty }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Normal flow

    @Test("팩 등장 → 개봉 → 카드 등장 → 순차 공개 → Summary 순서로 진행된다")
    func normalFlowReachesSummaryInOrder() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        let recorder = recorder(engine)

        engine.start()
        await waitUntil { engine.state == .packReady }
        #expect(recorder.states == ["pack-enter", "pack-ready"])

        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
        #expect(recorder.states == [
            "pack-enter", "pack-ready", "pack-opening", "cards-rise", "card-waiting",
        ])
        #expect(engine.totalCards == size)
        #expect(engine.revealedCount == 0)
        #expect(environment.sealedPacks.isEmpty, "개봉이 저장되어야 합니다")

        for expected in 1...size {
            await waitForAdvance(engine)
            engine.advance()
            await waitUntil { engine.revealedCount == expected }
            #expect(engine.revealedCount == expected, "저장된 공개 수가 순서대로 올라가야 합니다")
        }
        await waitUntil { engine.state == .summary }
        #expect(engine.state == .summary)
        #expect(recorder.states.filter { $0 == "summary" }.count == 1, "Summary는 한 번만 열립니다")

        // Every reveal went through the store, in order.
        let stored = try #require(environment.openings.first)
        #expect(stored.revealedCount == size)
        #expect(stored.isComplete)

        engine.finishSummary()
        #expect(engine.state == .complete)
        #expect(engine.isComplete)
    }

    @Test("저장된 결과는 연출 전후로 같고 소유 카드는 한 번만 저장된다")
    func animationDoesNotChangeTheResult() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }

        let storedCards = try #require(environment.openings.first).cards
        let presentedCards = engine.cards.map { "\($0.card.key.rawValue)#\($0.variant.rawValue)" }
        #expect(presentedCards == storedCards.map { "\($0.cardKey.rawValue)#\($0.variant.rawValue)" })

        for _ in 0..<size {
            await waitForAdvance(engine)
            engine.advance()
        }
        await waitUntil { engine.state == .summary }
        let afterCards = try #require(environment.openings.first).cards
        #expect(afterCards == storedCards, "연출이 저장된 결과를 바꾸면 안 됩니다")
        #expect(engine.cards.count == size)
        #expect(try await environment.store?.ownedCardInstances().count == size)
    }

    @Test("마지막 카드 뒤에는 Summary로 정확히 한 번 이동한다")
    func lastCardReachesSummaryOnce() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        let recorder = recorder(engine)
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }

        for _ in 0..<size {
            await waitForAdvance(engine)
            engine.advance()
            await waitUntil { engine.revealedCount > 0 && engine.revealedCount <= size }
        }
        await waitUntil { engine.state == .summary }
        #expect(engine.revealedCount == size)
        #expect(recorder.states.filter { $0 == "summary" }.count == 1)

        // Further input after the summary does not re-open or re-draw anything.
        engine.advance()
        engine.tear()
        await Task.yield()
        #expect(recorder.states.filter { $0 == "summary" }.count == 1)
        #expect(engine.revealedCount == size)
    }

    @Test("엔진이 기다리는 시간은 View의 공개 타임라인과 정확히 같다")
    func engineWaitsForTheViewTimeline() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        // Distinct durations, so a wrong phase cannot pass by summing to the same
        // number, and none of them are zero.
        let timing = PackOpeningTiming(
            packEnter: .milliseconds(5),
            packShake: .milliseconds(5),
            cardsRise: .milliseconds(5),
            cardFlip: .milliseconds(30),
            cardSettle: .milliseconds(10),
            cardTransfer: .milliseconds(20),
            summarySettle: .milliseconds(15)
        )
        let engine = makeStoredEngine(environment: environment, pack: pack, timing: timing)
        let waits = SleepRecorder()
        engine.sleep = { waits.record($0) }

        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }

        // A normal card: exactly its own timeline, nothing more.
        waits.clear()
        engine.advance()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
        let card = engine.cards[0].rarityProfile
        let expected = CardRevealTimeline.make(profile: card, timing: timing)
        #expect(waits.durations == [expected.total])
        #expect(
            expected.total == card.anticipation + timing.cardFlip
                + timing.cardSettle + card.hold + timing.cardTransfer,
            "View가 재생하는 단계들의 합과 달라졌습니다"
        )

        // Walk up to the last card.
        while engine.revealedCount < engine.totalCards - 1 {
            await waitForAdvance(engine)
            let before = engine.revealedCount
            engine.advance()
            await waitUntil { engine.revealedCount == before + 1 && engine.acceptsAdvanceInput }
        }
        #expect(engine.revealedCount == engine.totalCards - 1, "마지막 한 장만 남겨야 합니다")

        // The last card: its timeline, then the beat before the summary, so the
        // stage is never replaced while the card is still arriving.
        waits.clear()
        await waitForAdvance(engine)
        let last = CardRevealTimeline.make(profile: engine.cards[engine.totalCards - 1].rarityProfile, timing: timing)
        engine.advance()
        await waitUntil { engine.state == .summary }
        #expect(waits.durations == [last.total, timing.summarySettle])
        #expect(engine.revealedCount == engine.totalCards)
    }

    /// Records what the engine waited for, instead of actually waiting.
    @MainActor
    private final class SleepRecorder {
        private(set) var durations: [Duration] = []

        func record(_ duration: Duration) {
            durations.append(duration)
        }

        func clear() {
            durations.removeAll()
        }
    }

    // MARK: - Skip

    @Test("Skip은 어느 단계에서든 저장된 결과를 바꾸지 않고 Summary로 간다")
    func skipFromEachStageIsSafe() async throws {
        // Before the pack is opened there is nothing to reveal, so skip does nothing.
        let (environmentA, rootA, packA) = try await makeEnvironment(seed: 11)
        defer { try? FileManager.default.removeItem(at: rootA) }
        let engineA = makeStoredEngine(environment: environmentA, pack: packA)
        engineA.start()
        await waitUntil { engineA.state == .packReady }
        engineA.skip()
        await Task.yield()
        #expect(engineA.state == .packReady, "개봉 전 Skip은 팩을 열지 않습니다")

        // After the cards rise, and in the middle of a reveal.
        for stage in ["cards-rise", "card-waiting", "card-revealing"] {
            let (environment, root, pack) = try await makeEnvironment(seed: 11)
            let size = try #require(packSize(pack, in: environment))
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = makeStoredEngine(environment: environment, pack: pack)
            let gate = Gate()
            if stage == "card-revealing" {
                // Hold the first flip open so Skip lands mid-animation.
                engine.sleep = { duration in
                    if duration > .zero { await gate.wait() }
                }
            }
            engine.start()
            await waitUntil { engine.state == .packReady }
            engine.tear()
            await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
            let storedCards = try #require(environment.openings.first).cards

            switch stage {
            case "cards-rise":
                // A fresh engine, skipped as soon as the cards exist.
                let rising = makeStoredEngine(environment: environment, pack: pack)
                rising.start()
                await waitUntil { rising.state == .packReady }
                rising.tear()
                await waitForCards(rising)
                #expect(rising.state == .cardsRise || rising.acceptsSkipInput)
                rising.skip()
                await waitUntil { rising.state == .summary && rising.revealedCount == rising.totalCards }
                #expect(rising.state == .summary)
                #expect(rising.revealedCount == rising.totalCards)
            default:
                if stage == "card-revealing" {
                    engine.advance()
                    await waitUntil { engine.isRevealingCard }
                    #expect(engine.isRevealingCard)
                    engine.skip()
                } else {
                    engine.skip()
                }
                await waitUntil { engine.state == .summary }
                gate.open()
                await waitUntil { engine.revealedCount == engine.totalCards }
                #expect(engine.state == .summary)
                #expect(engine.revealedCount == engine.totalCards)
            }

            // The cards themselves never changed, and the store agrees.
            let stored = try #require(environment.openings.first)
            #expect(stored.cards == storedCards)
            #expect(stored.revealedCount == stored.cards.count)
            #expect(try await environment.store?.ownedCardInstances().count == size)
        }
    }

    @Test("무대는 아직 공개하지 않은 카드를 앞면으로 내놓지 않는다")
    func spotlightOnlyEverOffersTheNextCard() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        // Each reveal is held until the test has looked at it. With instant
        // timing the engine otherwise moved on to the next card before the
        // checks below ran, about one run in five.
        let hold = Gate()
        engine.sleep = { [weak engine] _ in
            if case .cardRevealing = engine?.state { await hold.wait() }
        }
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }

        // Waiting for the first card: the spotlight holds that card's back (the
        // view draws `currentCard` face down), and nothing is turning over yet.
        #expect(engine.revealedCards.isEmpty)
        #expect(engine.currentCard?.position == 0)
        #expect(engine.revealingCard == nil)

        await waitForAdvance(engine)
        engine.advance()
        await waitUntil { engine.revealedCount == 1 }
        // The card that was waiting is the one that turned, and the engine's
        // reveal is scoped to it until it lands.
        #expect(engine.currentCard?.position == 0)
        #expect(engine.revealingCard?.position == 0)
        #expect(engine.revealedCards.map(\.position) == [0])
        hold.open()

        // The next card is offered as the waiting card only after that; it is
        // never handed over as revealed.
        await waitForAdvance(engine)
        #expect(engine.revealingCard == nil)
        #expect(engine.currentCard?.position == 1)
        #expect(engine.revealedCards.map(\.position) == [0])
        engine.advance()
        #expect(engine.revealingCard?.position == 1)
        await waitUntil { engine.revealedCount == 2 }
        #expect(engine.revealedCards.map(\.position) == [0, 1])
    }

    // MARK: - Input lock

    @Test("연속 입력이 카드 순서를 건너뛰거나 두 번 처리하지 않는다")
    func rapidInputAdvancesOneCardAtATime() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        let gate = Gate()
        engine.sleep = { duration in
            if duration > .zero { await gate.wait() }
        }
        engine.start()
        await waitUntil { engine.state == .packReady }

        // Held key on the pack: the draw must happen once.
        engine.tear()
        engine.tear()
        engine.tear()
        gate.open()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
        #expect(environment.openings.count == 1, "개봉이 두 번 저장되면 안 됩니다")
        #expect(try await environment.store?.ownedCardInstances().count == size)

        // Repeated input during a flip is ignored until that flip finishes.
        engine.advance()
        await waitUntil { engine.isRevealingCard }
        engine.advance()
        engine.advance()
        #expect(engine.revealedCount <= 1)
        let duringReveal = engine.revealedCount
        await waitUntil { engine.revealedCount == 1 }
        #expect(engine.revealedCount == 1, "진행 중 입력이 카드를 두 장 넘겼습니다: \(duringReveal)")

        // And the next input continues from the stored position, not from a skip.
        await waitForAdvance(engine)
        engine.advance()
        await waitUntil { engine.revealedCount == 2 }
        #expect(engine.revealedCount == 2)
    }

    @Test("저장에 실패하면 저장된 위치로 되돌아가고 결과는 그대로다")
    func revealFailureKeepsStoredTruth() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = FailingReveal()
        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: pack.id,
                productName: "test",
                catalogVersion: pack.catalogVersion,
                recipeVersion: pack.recipeVersion,
                product: nil,
                cards: [],
                revealedCount: 0
            ),
            openPack: { [environment] in try? await environment.openPack(pack.id) },
            resolveCards: { record in
                await PackOpeningSceneModel.resolve(record, environment: environment)
            },
            reveal: failing,
            revealAfterOpen: { _ in failing },
            timing: .instant
        )
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }

        engine.advance()
        await waitUntil { engine.errorMessage != nil }
        #expect(engine.errorMessage != nil)
        #expect(engine.revealedCount == 0, "저장되지 않은 진행도를 보여주면 안 됩니다")
        if case .cardWaiting = engine.state {} else {
            Issue.record("저장 실패 뒤에는 저장된 위치에서 기다려야 합니다: \(engine.state)")
        }
        #expect(try await environment.store?.ownedCardInstances().count == size)
    }

    // MARK: - Resume, empty result, cleanup

    @Test("복원된 진행 위치에서 이어서 열고, 완료된 팩은 바로 Summary다")
    func resumeContinuesFromStoredProgress() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let opening = try await environment.openPack(pack.id)
        let completed = try #require(await environment.revealAll(opening))
        #expect(completed.revealedCount == completed.cards.count)

        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: opening.id,
                packID: pack.id,
                productName: "test",
                catalogVersion: pack.catalogVersion,
                recipeVersion: pack.recipeVersion,
                product: nil,
                cards: engineCards(environment, completed),
                revealedCount: completed.revealedCount
            ),
            openPack: nil,
            resolveCards: { record in await PackOpeningSceneModel.resolve(record, environment: environment) },
            reveal: StoreOpeningReveal(environment: environment, openingID: completed.id),
            timing: .instant
        )
        engine.start()
        #expect(engine.state == .summary, "완료된 개봉은 바로 결과를 보여줍니다")

        // Half-revealed pack resumes at the waiting state, not from the pack.
        let (environment2, root2, pack2) = try await makeEnvironment(seed: 12)
        defer { try? FileManager.default.removeItem(at: root2) }
        var half = try await environment2.openPack(pack2.id)
        for _ in 0..<3 { half = try #require(await environment2.revealNext(half)) }
        let resumed = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: half.id,
                packID: pack2.id,
                productName: "test",
                catalogVersion: pack2.catalogVersion,
                recipeVersion: pack2.recipeVersion,
                product: nil,
                cards: engineCards(environment2, half),
                revealedCount: half.revealedCount
            ),
            openPack: nil,
            resolveCards: { record in await PackOpeningSceneModel.resolve(record, environment: environment2) },
            reveal: StoreOpeningReveal(environment: environment2, openingID: half.id),
            timing: .instant
        )
        await resumed.startAsync()
        #expect(resumed.revealedCount == 3)
        #expect(resumed.acceptsAdvanceInput)
        #expect(resumed.revealedCount == 3)
    }

    @Test("카드가 없는 결과는 Summary로 안전하게 끝난다")
    func emptyResultEndsInSummary() async throws {
        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: nil,
                productName: "empty",
                catalogVersion: "test",
                recipeVersion: 1,
                product: nil,
                cards: [],
                revealedCount: 0
            ),
            openPack: nil,
            resolveCards: { _ in [] },
            reveal: PreviewOpeningReveal(total: 0),
            timing: .instant
        )
        await engine.startAsync()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { engine.state == .summary }
        #expect(engine.state == .summary)
        #expect(engine.revealedCount == 0)
        #expect(!engine.acceptsSkipInput, "공개할 카드가 없으면 Skip도 받지 않습니다")
    }

    @Test("화면이 사라지면 남은 작업이 없고 상태가 더 진행되지 않는다")
    func cancelLeavesNoPendingWork() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack)
        let gate = Gate()
        engine.sleep = { duration in
            if duration > .zero { await gate.wait() }
        }
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
        engine.advance()
        await waitUntil { engine.isRevealingCard }
        #expect(engine.hasPendingWork)

        engine.cancelAll()
        #expect(!engine.hasPendingWork)
        gate.open()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.isRevealingCard, "취소 뒤에는 상태가 더 진행되지 않습니다")
        #expect(!engine.hasPendingWork)
    }

    @Test("모션 줄이기 경로도 같은 순서와 같은 결과를 남긴다")
    func reducedMotionKeepsOrderAndResult() async throws {
        let (environment, root, pack) = try await makeEnvironment()
        let size = try #require(packSize(pack, in: environment))
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = makeStoredEngine(environment: environment, pack: pack, timing: .instant)
        let recorder = recorder(engine)
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { engine.revealedCount == 0 && engine.acceptsAdvanceInput }
        engine.revealAll()
        await waitUntil { engine.state == .summary && engine.revealedCount == size }

        #expect(recorder.states.prefix(5) == [
            "pack-enter", "pack-ready", "pack-opening", "cards-rise", "card-waiting",
        ])
        #expect(engine.revealedCount == size)
        let stored = try #require(environment.openings.first)
        #expect(stored.revealedCount == size)
        #expect(stored.cards.count == size)
    }

    @Test("미리보기는 저장소 없이 같은 상태 흐름을 돈다")
    func previewRunsWithoutStore() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let result = try #require(PackOpeningPreview.makeResult(library: library))
        let resolved = result.cards.compactMap { entry -> PackOpeningCard? in
            guard let card = library.card(for: entry.cardKey) else { return nil }
            return PackOpeningCard(position: entry.position, card: card, variant: entry.variant, isNew: entry.isNew)
        }
        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil,
                packID: nil,
                productName: "미리보기",
                catalogVersion: result.catalogVersion,
                recipeVersion: result.recipeVersion,
                product: result.product,
                cards: resolved,
                revealedCount: 0,
                isPreview: true
            ),
            openPack: nil,
            resolveCards: { _ in resolved },
            reveal: PreviewOpeningReveal(total: resolved.count),
            timing: .instant
        )
        let recorder = recorder(engine)
        engine.start()
        await waitUntil { engine.state == .packReady }
        engine.tear()
        await waitUntil { if case .cardWaiting = engine.state { return true }; return false }
        #expect(recorder.states == ["pack-enter", "pack-ready", "pack-opening", "cards-rise", "card-waiting"])
        engine.revealAll()
        await waitUntil { engine.state == .summary && engine.revealedCount == resolved.count }
        #expect(engine.revealedCount == resolved.count)
        #expect(engine.isPreview)
    }

    // MARK: - Helpers

    private func engineCards(_ environment: AppEnvironment, _ record: OpeningRecord) -> [PackOpeningCard] {
        record.cards.compactMap { drawn in
            guard let card = environment.card(for: drawn.cardKey) else { return nil }
            return PackOpeningCard(position: drawn.position, card: card, variant: drawn.variant, isNew: false)
        }
    }
}

/// Reveal sink that always fails, for the storage-failure path.
@MainActor
private final class FailingReveal: PackOpeningRevealing {
    func reveal(upTo count: Int) async -> Bool { false }
}

private extension PackOpeningEngine {
    /// `start()` schedules work; this waits for the state it settles on.
    func startAsync() async {
        start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if state != .idle { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Summary grid geometry: ten cards must fit without cutting the last row.
@Suite("개봉 결과 그리드")
struct OpeningGridLayoutTests {
    @Test("시트 크기에서 10장이 잘리지 않고 들어간다")
    func tenCardsFitTheSheet() throws {
        // The sheet is 780×660 and the grid gets what the header, panel and HUD
        // leave behind (measured ~732×470).
        let layout = GridLayout.fitting(count: 10, in: CGSize(width: 732, height: 470))
        #expect(layout.columns == 5)
        let rows = Int((10.0 / Double(layout.columns)).rounded(.up))
        let usedHeight = CGFloat(rows) * (layout.tile * GridLayout.cardAspect + GridLayout.labelHeight)
            + CGFloat(rows - 1) * GridLayout.spacing
        #expect(usedHeight <= 470 + 1, "그리드가 시트 높이를 넘습니다: \(usedHeight)")
        #expect(layout.tile >= GridLayout.minTile)
    }

    @Test("아주 작은 공간에서는 읽을 수 있는 크기를 지키고 스크롤로 넘긴다")
    func smallSpaceKeepsTilesReadable() throws {
        // Nothing can fit ten cards in 900×220 at a readable size, so the grid
        // keeps its minimum tile and scrolls instead of shrinking into noise.
        let short = GridLayout.fitting(count: 10, in: CGSize(width: 900, height: 220))
        #expect(short.tile >= GridLayout.minTile)
        #expect(short.columns >= 3)

        let narrow = GridLayout.fitting(count: 10, in: CGSize(width: 300, height: 200))
        #expect(narrow.columns >= 3)
        #expect(narrow.tile >= GridLayout.minTile)

        // A degenerate size must not produce a zero-size grid.
        let empty = GridLayout.fitting(count: 10, in: .zero)
        #expect(empty.columns == 1)
        #expect(empty.tile >= GridLayout.minTile)
    }

    @Test("카드 수가 적으면 타일이 커진다")
    func fewerCardsGetLargerTiles() throws {
        let ten = GridLayout.fitting(count: 10, in: CGSize(width: 732, height: 470))
        let two = GridLayout.fitting(count: 2, in: CGSize(width: 732, height: 470))
        #expect(two.tile >= ten.tile)
        #expect(two.tile <= GridLayout.maxTile)
    }
}
