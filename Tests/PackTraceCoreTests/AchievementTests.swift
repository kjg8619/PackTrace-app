import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("카드 별")
struct CardMasteryTests {
    @Test("같은 프린트 2·3·5·8·12장에서 별이 하나씩 늘고, 카드는 없어지지 않는다")
    func starsFollowCopies() {
        let expected = [0: 0, 1: 0, 2: 1, 3: 2, 4: 2, 5: 3, 7: 3, 8: 4, 11: 4, 12: 5, 40: 5]
        for (copies, stars) in expected {
            #expect(CardMastery.stars(copies: copies) == stars, "\(copies)장")
        }
        #expect(CardMastery.copiesToNextStar(copies: 1) == 1)
        #expect(CardMastery.copiesToNextStar(copies: 3) == 2)
        #expect(CardMastery.copiesToNextStar(copies: 12) == nil)
        #expect(CardMastery.maxStars == 5)
    }
}

@Suite("업적 판정 (순수)")
struct AchievementEvaluationTests {
    private let catalog = AchievementCatalog.v1(sets: [("sv01", "Scarlet & Violet"), ("sv05", "Temporal Forces")])

    private func card(_ number: Int, _ rarity: String = "Common", set: String = "sv01", variant: CardVariant = .normal) -> AchievementFacts.Card {
        AchievementFacts.Card(
            key: CardKey(rawValue: "tcgdex:en:\(set):\(String(format: "%03d", number))"),
            variant: variant,
            rarity: CardRarity(rawValue: rarity),
            setID: set
        )
    }

    private func day(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset * 86_400) }

    private func progress(_ facts: AchievementFacts, _ id: String) throws -> AchievementProgress {
        try #require(catalog.evaluate(facts).first { $0.id == id }, "\(id)")
    }

    @Test("개수 업적의 달성일은 그 개수째가 채워진 시점이다")
    func countsAreDatedByTheNthEvent() throws {
        var facts = AchievementFacts()
        // Given out of order on purpose: evaluation sorts by completion time.
        facts.openings = [
            .init(completedAt: day(2), setID: "sv05", cards: [card(1, set: "sv05")]),
            .init(completedAt: day(0), setID: "sv01", cards: [card(1)]),
            .init(completedAt: day(1), setID: "sv01", cards: [card(2)]),
        ]
        let first = try progress(facts, "packs.1")
        #expect(first.achievedAt == day(0))
        let ten = try progress(facts, "packs.10")
        #expect(ten.achievedAt == nil)
        #expect(ten.current == 3 && ten.target == 10)
        let sets = try progress(facts, "sets.5")
        #expect(sets.current == 2 && sets.achievedAt == nil)
    }

    @Test("첫 획득은 그 등급이 처음 공개된 팩의 시점, 대박 팩은 한 팩 안의 고등급 2장")
    func firstPullsAndLuckyPack() throws {
        var facts = AchievementFacts()
        facts.openings = [
            .init(completedAt: day(0), setID: "sv05", cards: [card(1, set: "sv05"), card(2, "Illustration rare", set: "sv05")]),
            .init(completedAt: day(1), setID: "sv05", cards: [card(3, "ACE SPEC Rare", set: "sv05"), card(4, "Ultra Rare", set: "sv05")]),
            .init(completedAt: day(2), setID: "sv05", cards: [card(5, "Ultra Rare", set: "sv05"), card(6, "Special illustration rare", set: "sv05")]),
        ]
        #expect(try progress(facts, "pull.illustration-rare").achievedAt == day(0))
        #expect(try progress(facts, "pull.ace-spec").achievedAt == day(1))
        #expect(try progress(facts, "pull.ultra-rare").achievedAt == day(1))
        #expect(try progress(facts, "pull.hyper-rare").achievedAt == nil)
        // ACE SPEC + Ultra Rare is one high card; Ultra Rare + SIR is two.
        let lucky = try progress(facts, "pull.lucky-pack")
        #expect(lucky.achievedAt == day(2))
    }

    @Test("세트 완성률은 앱 지원 프린트 수의 올림 비율로 판정하고, 다른 세트 카드는 세지 않는다")
    func setCompletion() throws {
        var facts = AchievementFacts()
        facts.setPrintTotals = ["sv01": 5, "sv05": 100]
        facts.openings = [
            .init(completedAt: day(0), setID: "sv01", cards: [card(1), card(2), card(1)]),
            .init(completedAt: day(1), setID: "sv05", cards: [card(1, set: "sv05")]),
            .init(completedAt: day(2), setID: "sv01", cards: [card(3), card(1, variant: .reverse)]),
        ]
        // 50% of 5 = 2.5 → 3 prints: reached at day 2 (001, 002, then 003 and 001 reverse).
        let half = try progress(facts, "set.sv01.50")
        #expect(half.target == 3)
        #expect(half.achievedAt == day(2))
        let full = try progress(facts, "set.sv01.100")
        #expect(full.current == 4 && full.target == 5 && full.achievedAt == nil)
    }

    @Test("별 업적은 같은 프린트의 사본 수로, 리버스는 다른 프린트로 센다")
    func starsAchievements() throws {
        var facts = AchievementFacts()
        facts.openings = [
            .init(completedAt: day(0), setID: "sv01", cards: [card(1), card(1, variant: .reverse)]),
            .init(completedAt: day(1), setID: "sv01", cards: [card(1), card(2)]),
        ]
        #expect(try progress(facts, "stars.first").achievedAt == day(1))
        let three = try progress(facts, "stars.3")
        #expect(three.current == 2 && three.achievedAt == nil)
    }

    @Test("연속 적립은 끊기면 다시 세고, 달성일은 N일째의 첫 적립 시각이다")
    func usageStreak() throws {
        var facts = AchievementFacts()
        facts.usageDays = [10, 11, 13, 14, 15, 16].map { AchievementFacts.UsageDay(day: $0, firstAt: day(Double($0))) }
        let three = try progress(facts, "usage.streak.3")
        #expect(three.achievedAt == day(15), "13·14·15일이 첫 3일 연속입니다")
        let seven = try progress(facts, "usage.streak.7")
        #expect(seven.current == 4 && seven.achievedAt == nil)
    }

    @Test("누적 토큰과 도구 수는 저장소가 찾은 시점을 그대로 쓴다")
    func tokensAndTools() throws {
        var facts = AchievementFacts()
        facts.totalAcceptedTokens = 12_000_000
        facts.tokenCrossings = [1_000_000: day(1), 10_000_000: day(5)]
        facts.toolFirstUse = ["omp": day(0), "codex": day(3), "claude-code": day(2)]
        #expect(try progress(facts, "usage.tokens.1m").achievedAt == day(1))
        #expect(try progress(facts, "usage.tokens.10m").achievedAt == day(5))
        let hundred = try progress(facts, "usage.tokens.100m")
        #expect(hundred.achievedAt == nil && hundred.current == 12_000_000)
        #expect(try progress(facts, "usage.tools.3").achievedAt == day(3))
    }

    @Test("예전 시대 등급의 첫 획득 업적은 그 등급이 있는 세트를 실었을 때만 나온다")
    func eraPullsNeedTheRarity() {
        let without = AchievementCatalog.v1(sets: [("sv01", "Scarlet & Violet")])
        #expect(!without.definitions.contains { $0.id == "pull.lv-x" })
        let with = AchievementCatalog.v1(sets: [("dp1", "Diamond & Pearl")], rarities: [CardRarity(rawValue: "Rare Holo LV.X")])
        let lvx = with.definitions.first { $0.id == "pull.lv-x" }
        #expect(lvx?.rule == .firstOfRarity(CardRarity(rawValue: "Rare Holo LV.X")))
        #expect(!with.definitions.contains { $0.id == "pull.prime" })
    }

    @Test("업적 ID는 겹치지 않고 보상은 팩 한 개(100 P) 이하가 대부분이다")
    func catalogShape() {
        let ids = catalog.definitions.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(catalog.definitions.allSatisfy { $0.rewardPoints >= 0 && $0.rewardPoints <= 200 })
        #expect(catalog.definitions.filter { $0.rewardPoints > 100 }.allSatisfy { $0.id.hasPrefix("set.") || $0.id.hasPrefix("prints.") })
        #expect(catalog.tokenThresholds == [1_000_000, 10_000_000, 100_000_000])
    }
}

@Suite("업적 기록과 보상 (임시 DB)")
struct AchievementStoreTests {
    private func store(realm: Realm = .demo) throws -> (PackTraceStore, ResolvedPackPool) {
        let library = try CatalogLoader.bundledLibrary()
        let store = try Fixtures.makeStore(library: library, realm: realm)
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        return (store, pool)
    }

    @Test("끝까지 공개하기 전에는 업적이 열리지 않고, 공개를 마치면 그 시각으로 한 번만 보상한다")
    func unlocksAfterRevealOnceWithReward() async throws {
        let (store, pool) = try store()
        try await store.grantInitialDemoPoints()
        let pack = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 3).packInstance
        let opening = try await store.openPack(instanceID: pack.id, seed: 3)
        _ = try await store.setRevealedCount(openingID: opening.id, count: 4)

        let before = try await store.balance()
        let halfway = try await store.evaluateAchievements()
        #expect(halfway.newlyUnlocked.isEmpty, "공개 중인 팩은 세지 않습니다")
        #expect(try await store.balance() == before)

        let revealedAt = Date(timeIntervalSince1970: 1_790_100_000)
        let completed = try await store.setRevealedCount(openingID: opening.id, count: opening.cards.count, now: revealedAt)
        let evaluation = try await store.evaluateAchievements()
        let first = try #require(evaluation.newlyUnlocked.first { $0.achievementID == "packs.1" })
        #expect(first.achievedAt == completed.completedAt)
        #expect(first.rewardPoints == 10)
        let paid = evaluation.newlyUnlocked.reduce(0) { $0 + $1.rewardPoints }
        #expect(try await store.balance() == before + paid)

        let rewards = try await store.ledger().filter { $0.reason == .achievementReward }
        #expect(rewards.count == evaluation.newlyUnlocked.filter { $0.rewardPoints > 0 }.count)
        #expect(Set(rewards.compactMap(\.reference)) == Set(evaluation.newlyUnlocked.map(\.achievementID)))

        // Evaluating again changes nothing.
        let again = try await store.evaluateAchievements()
        #expect(again.newlyUnlocked.isEmpty)
        #expect(try await store.balance() == before + paid)
        #expect(again.records.keys.contains("packs.1"))
    }

    @Test("사용량 업적: 누적 토큰과 연속 적립이 실제 적립 경로에서 판정된다")
    func usageAchievementsFromRealRewardPath() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // Three calls on three consecutive Seoul days, after the connection.
        let start = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        for index in 0..<3 {
            let at = start + index * 86_400_000
            try harness.tree.append(
                OMPFixture.assistant(
                    responseID: OMPFixture.responseID(index + 1),
                    input: 400_000,
                    output: 0,
                    occurredAt: at,
                    completedAt: at + 1_000
                ) + "\n",
                to: path
            )
        }
        _ = try await harness.drain()
        #expect(try await harness.store.usageTotals().acceptedTokens == 1_200_000)

        let evaluation = try await harness.store.evaluateAchievements()
        let unlocked = Set(evaluation.newlyUnlocked.map(\.achievementID))
        #expect(unlocked.contains("usage.tokens.1m"))
        #expect(unlocked.contains("usage.streak.3"))
        #expect(!unlocked.contains("usage.tools.3"), "OMP 하나뿐입니다")
        let tokens = try #require(evaluation.newlyUnlocked.first { $0.achievementID == "usage.tokens.1m" })
        // The third call crossed 1,000,000.
        #expect(abs(tokens.achievedAt.timeIntervalSince1970 - Double(start + 2 * 86_400_000) / 1000) < 1)
    }

    @Test("사용량 보정으로 되돌린 이벤트는 업적·도구별·일별 인정량에 세지 않는다")
    func correctedEventsDoNotCount() async throws {
        let (store, location, _) = try await UsageCorrectionTests.makeIncidentProfile(label: "packtrace-achievement-correction")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let sourceID = try await UsageCorrectionTests.incidentSourceID(store)
        // Before: 3 x 2,000 miscredited history + 6,000 genuine.
        let before = try await store.achievementFacts(tokenThresholds: [])
        #expect(before.totalAcceptedTokens == 12_000)
        #expect(before.usageDays.count == 2)

        let plan = try await store.usageCorrectionPlan(incidentID: "achievement-check", sourceID: sourceID)
        _ = try await store.applyUsageCorrection(plan)

        let after = try await store.achievementFacts(tokenThresholds: [])
        #expect(after.totalAcceptedTokens == 6_000, "되돌린 6,000은 빼고 셉니다")
        #expect(after.usageDays.count == 1, "되돌린 이벤트의 날은 적립한 날이 아닙니다")
        let opencode = try #require(try await store.usageToolTotals().first { $0.tool == .openCode })
        #expect(opencode.acceptedTokens == 6_000)
        #expect(opencode.acceptedEvents == 1)
        #expect(opencode.acceptedTokens == (try await store.usageTotals()).acceptedTokens, "도구별 합계 = 공통 계정")
    }
}
