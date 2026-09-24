import Foundation

/// Stars for holding more copies of one print. Duplicates are never consumed:
/// stars only describe how many copies the binder already holds, so they
/// change nothing about points, packs or draws.
public enum CardMastery {
    /// Copies of one print needed for one to five stars.
    public static let thresholds = [2, 3, 5, 8, 12]

    public static var maxStars: Int { thresholds.count }

    public static func stars(copies: Int) -> Int {
        thresholds.filter { copies >= $0 }.count
    }

    /// Copies still needed for the next star; nil once the print has them all.
    public static func copiesToNextStar(copies: Int) -> Int? {
        thresholds.first { copies < $0 }.map { $0 - max(copies, 0) }
    }
}

public enum AchievementCategory: String, CaseIterable, Sendable {
    case packs, pulls, collection, sets, stars, usage

    public var displayName: String {
        switch self {
        case .packs: "팩 개봉"
        case .pulls: "첫 획득"
        case .collection: "수집"
        case .sets: "세트 완성"
        case .stars: "별"
        case .usage: "AI 사용량"
        }
    }
}

/// One achievement. The id is stored with the unlock and is never reused for
/// a different condition.
public struct AchievementDefinition: Sendable, Hashable, Identifiable {
    public enum Rule: Sendable, Hashable {
        case packsOpened(Int)
        case distinctSetsOpened(Int)
        case firstOfRarity(CardRarity)
        /// A single pack with at least this many high-rarity cards.
        case highRarityPack(Int)
        case uniquePrints(Int)
        case setCompletion(setID: String, percent: Int)
        /// Any one print held this many times.
        case printCopies(Int)
        /// This many prints holding at least one star.
        case starredPrints(Int)
        case acceptedTokens(Int)
        case usageStreak(days: Int)
        case usageTools(Int)
    }

    public var id: String
    public var category: AchievementCategory
    public var title: String
    public var detail: String
    public var rewardPoints: Int
    public var rule: Rule
}

/// What the achievements are judged on. Built by the store from stored
/// records; only fully revealed openings count, so an achievement can never
/// give away a card the user has not seen yet.
public struct AchievementFacts: Sendable {
    public struct Card: Sendable, Hashable {
        public var key: CardKey
        public var variant: CardVariant
        public var rarity: CardRarity
        public var setID: String

        public init(key: CardKey, variant: CardVariant, rarity: CardRarity, setID: String) {
            self.key = key
            self.variant = variant
            self.rarity = rarity
            self.setID = setID
        }
    }

    public struct Opening: Sendable {
        public var completedAt: Date
        public var setID: String
        public var cards: [Card]

        public init(completedAt: Date, setID: String, cards: [Card]) {
            self.completedAt = completedAt
            self.setID = setID
            self.cards = cards
        }
    }

    /// One Seoul calendar day with credited usage, and when it started.
    public struct UsageDay: Sendable, Hashable {
        public var day: Int
        public var firstAt: Date

        public init(day: Int, firstAt: Date) {
            self.day = day
            self.firstAt = firstAt
        }
    }

    public var openings: [Opening] = []
    /// Supported prints per set (the binder's denominator).
    public var setPrintTotals: [String: Int] = [:]
    public var usageDays: [UsageDay] = []
    public var totalAcceptedTokens = 0
    /// When the cumulative accepted tokens first reached each threshold.
    public var tokenCrossings: [Int: Date] = [:]
    /// When each tool first had credited usage.
    public var toolFirstUse: [String: Date] = [:]

    public init() {}
}

/// Where one achievement stands.
public struct AchievementProgress: Sendable, Identifiable {
    public var definition: AchievementDefinition
    /// Progress towards `target`, never above it.
    public var current: Int
    public var target: Int
    /// When the condition first held, from the records themselves; nil while
    /// it has not.
    public var achievedAt: Date?

    public var id: String { definition.id }
    public var isAchieved: Bool { achievedAt != nil }
    public var fraction: Double { target > 0 ? Double(current) / Double(target) : 0 }
}

public struct AchievementCatalog: Sendable {
    public static let version = 1

    /// Rarities that count as a big hit for the lucky-pack achievement.
    public static let highRarities: Set<CardRarity> = Set([
        "Ultra Rare", "Illustration rare", "Special illustration rare", "Hyper rare",
        // Earlier eras' big hits.
        "Secret Rare", "Rare Holo LV.X", "LEGEND", "Holo Rare VMAX", "Holo Rare VSTAR",
        "Amazing Rare", "Radiant Rare", "Shiny Ultra Rare", "Mega Hyper Rare", "Black White Rare",
    ].map(CardRarity.init(rawValue:)))

    /// First pulls of earlier eras' rarities, offered only when a shipped set
    /// has that rarity (an achievement nothing can unlock is not listed).
    static let eraPulls: [(id: String, rarity: String, title: String, reward: Int)] = [
        ("pull.secret-rare", "Secret Rare", "첫 시크릿 레어", 30),
        ("pull.lv-x", "Rare Holo LV.X", "첫 LV.X", 20),
        ("pull.prime", "Rare PRIME", "첫 프라임", 20),
        ("pull.legend", "LEGEND", "첫 레전드", 30),
        ("pull.vmax", "Holo Rare VMAX", "첫 VMAX", 20),
        ("pull.vstar", "Holo Rare VSTAR", "첫 VSTAR", 20),
        ("pull.amazing-rare", "Amazing Rare", "첫 어메이징 레어", 30),
        ("pull.radiant-rare", "Radiant Rare", "첫 레디언트 레어", 30),
        ("pull.shiny-rare", "Shiny rare", "첫 샤이니 레어", 20),
        ("pull.mega-hyper-rare", "Mega Hyper Rare", "첫 메가 하이퍼 레어", 50),
    ]

    public let definitions: [AchievementDefinition]

    public init(definitions: [AchievementDefinition]) {
        self.definitions = definitions
    }

    /// Token thresholds the catalogue asks the store to locate.
    public var tokenThresholds: [Int] {
        definitions.compactMap { if case let .acceptedTokens(value) = $0.rule { value } else { nil } }
    }

    /// The first catalogue. Rewards are small next to a pack (100 P): points
    /// still come mainly from AI usage.
    public static func v1(sets: [(id: String, name: String)], rarities: Set<CardRarity> = []) -> AchievementCatalog {
        func make(_ id: String, _ category: AchievementCategory, _ title: String, _ detail: String, _ reward: Int, _ rule: AchievementDefinition.Rule) -> AchievementDefinition {
            AchievementDefinition(id: id, category: category, title: title, detail: detail, rewardPoints: reward, rule: rule)
        }
        func rarity(_ raw: String) -> CardRarity { CardRarity(rawValue: raw) }

        var list: [AchievementDefinition] = [
            make("packs.1", .packs, "첫 개봉", "팩 하나를 끝까지 공개", 10, .packsOpened(1)),
            make("packs.10", .packs, "팩 10개", "팩 10개를 끝까지 공개", 20, .packsOpened(10)),
            make("packs.50", .packs, "팩 50개", "팩 50개를 끝까지 공개", 50, .packsOpened(50)),
            make("packs.100", .packs, "팩 100개", "팩 100개를 끝까지 공개", 100, .packsOpened(100)),
            make("sets.5", .packs, "다섯 세트", "서로 다른 세트의 팩 5종을 개봉", 30, .distinctSetsOpened(5)),
            make("sets.10", .packs, "열 세트", "서로 다른 세트의 팩 10종을 개봉", 50, .distinctSetsOpened(10)),
            make("sets.25", .packs, "스물다섯 세트", "서로 다른 세트의 팩 25종을 개봉", 60, .distinctSetsOpened(25)),
            make("sets.50", .packs, "쉰 세트", "서로 다른 세트의 팩 50종을 개봉", 80, .distinctSetsOpened(50)),
            make("sets.100", .packs, "백 세트", "서로 다른 세트의 팩 100종을 개봉", 100, .distinctSetsOpened(100)),

            make("pull.double-rare", .pulls, "첫 더블 레어", "더블 레어를 처음 획득", 10, .firstOfRarity(rarity("Double rare"))),
            make("pull.ultra-rare", .pulls, "첫 울트라 레어", "울트라 레어를 처음 획득", 20, .firstOfRarity(rarity("Ultra Rare"))),
            make("pull.illustration-rare", .pulls, "첫 일러스트 레어", "일러스트 레어를 처음 획득", 20, .firstOfRarity(rarity("Illustration rare"))),
            make("pull.ace-spec", .pulls, "첫 에이스 스펙", "에이스 스펙 레어를 처음 획득", 20, .firstOfRarity(rarity("ACE SPEC Rare"))),
            make("pull.special-illustration-rare", .pulls, "첫 스페셜 일러스트 레어", "스페셜 일러스트 레어를 처음 획득", 50, .firstOfRarity(rarity("Special illustration rare"))),
            make("pull.hyper-rare", .pulls, "첫 하이퍼 레어", "하이퍼 레어를 처음 획득", 50, .firstOfRarity(rarity("Hyper rare"))),
            make("pull.lucky-pack", .pulls, "대박 팩", "한 팩에서 울트라·일러스트 레어급 이상 2장", 50, .highRarityPack(2)),

            make("prints.100", .collection, "고유 프린트 100", "서로 다른 프린트 100종 수집", 20, .uniquePrints(100)),
            make("prints.250", .collection, "고유 프린트 250", "서로 다른 프린트 250종 수집", 40, .uniquePrints(250)),
            make("prints.500", .collection, "고유 프린트 500", "서로 다른 프린트 500종 수집", 80, .uniquePrints(500)),
            make("prints.1000", .collection, "고유 프린트 1000", "서로 다른 프린트 1,000종 수집", 150, .uniquePrints(1000)),
            make("prints.2500", .collection, "고유 프린트 2500", "서로 다른 프린트 2,500종 수집", 180, .uniquePrints(2500)),
            make("prints.5000", .collection, "고유 프린트 5000", "서로 다른 프린트 5,000종 수집", 200, .uniquePrints(5000)),
        ]
        for pull in eraPulls where rarities.contains(CardRarity(rawValue: pull.rarity)) {
            let rarity = CardRarity(rawValue: pull.rarity)
            list.append(make(pull.id, .pulls, pull.title, "\(rarity.displayName)를 처음 획득", pull.reward, .firstOfRarity(rarity)))
        }
        for set in sets {
            let label = "\(set.name) (\(set.id.uppercased()))"
            list.append(make("set.\(set.id).50", .sets, "\(set.name) 절반", "\(label) 앱 지원 프린트의 50% 수집", 50, .setCompletion(setID: set.id, percent: 50)))
            list.append(make("set.\(set.id).100", .sets, "\(set.name) 완성", "\(label) 앱 지원 프린트를 모두 수집", 200, .setCompletion(setID: set.id, percent: 100)))
        }
        list += [
            make("stars.first", .stars, "첫 별", "같은 프린트 2장으로 ★", 10, .printCopies(CardMastery.thresholds[0])),
            make("stars.3", .stars, "★★★", "같은 프린트 \(CardMastery.thresholds[2])장", 30, .printCopies(CardMastery.thresholds[2])),
            make("stars.5", .stars, "★★★★★", "같은 프린트 \(CardMastery.thresholds[4])장", 100, .printCopies(CardMastery.thresholds[4])),
            make("stars.prints.10", .stars, "별 카드 10종", "★ 이상인 프린트 10종", 30, .starredPrints(10)),

            make("usage.tokens.1m", .usage, "인정 토큰 100만", "누적 인정 토큰 1,000,000", 10, .acceptedTokens(1_000_000)),
            make("usage.tokens.10m", .usage, "인정 토큰 1,000만", "누적 인정 토큰 10,000,000", 30, .acceptedTokens(10_000_000)),
            make("usage.tokens.100m", .usage, "인정 토큰 1억", "누적 인정 토큰 100,000,000", 100, .acceptedTokens(100_000_000)),
            make("usage.streak.3", .usage, "3일 연속", "3일 연속으로 AI 사용량 적립", 10, .usageStreak(days: 3)),
            make("usage.streak.7", .usage, "7일 연속", "7일 연속으로 AI 사용량 적립", 30, .usageStreak(days: 7)),
            make("usage.streak.30", .usage, "30일 연속", "30일 연속으로 AI 사용량 적립", 100, .usageStreak(days: 30)),
            make("usage.tools.3", .usage, "도구 셋", "AI 도구 3종에서 사용량 적립", 20, .usageTools(3)),
        ]
        return AchievementCatalog(definitions: list)
    }

    // MARK: - Evaluation

    /// Pure: the same facts always give the same progress and dates.
    public func evaluate(_ facts: AchievementFacts) -> [AchievementProgress] {
        let openings = facts.openings.sorted { $0.completedAt < $1.completedAt }
        return definitions.map { definition in
            let (current, target, date) = Self.judge(definition.rule, facts: facts, openings: openings)
            return AchievementProgress(definition: definition, current: min(current, target), target: target, achievedAt: date)
        }
    }

    private static func judge(
        _ rule: AchievementDefinition.Rule,
        facts: AchievementFacts,
        openings: [AchievementFacts.Opening]
    ) -> (Int, Int, Date?) {
        switch rule {
        case let .packsOpened(count):
            return (openings.count, count, openings.count >= count ? openings[count - 1].completedAt : nil)

        case let .distinctSetsOpened(count):
            var seen = Set<String>()
            for opening in openings {
                seen.insert(opening.setID)
                if seen.count == count { return (count, count, opening.completedAt) }
            }
            return (seen.count, count, nil)

        case let .firstOfRarity(rarity):
            let hit = openings.first { $0.cards.contains { $0.rarity == rarity } }
            return (hit == nil ? 0 : 1, 1, hit?.completedAt)

        case let .highRarityPack(count):
            var best = 0
            for opening in openings {
                let hits = opening.cards.filter { highRarities.contains($0.rarity) }.count
                best = max(best, hits)
                if hits >= count { return (count, count, opening.completedAt) }
            }
            return (best, count, nil)

        case let .uniquePrints(count):
            var prints = Set<String>()
            for opening in openings {
                for card in opening.cards { prints.insert(printID(card)) }
                if prints.count >= count { return (count, count, opening.completedAt) }
            }
            return (prints.count, count, nil)

        case let .setCompletion(setID, percent):
            let total = facts.setPrintTotals[setID] ?? 0
            guard total > 0 else { return (0, 1, nil) }
            let target = max(1, Int((Double(total) * Double(percent) / 100).rounded(.up)))
            var prints = Set<String>()
            for opening in openings {
                for card in opening.cards where card.setID == setID { prints.insert(printID(card)) }
                if prints.count >= target { return (target, target, opening.completedAt) }
            }
            return (prints.count, target, nil)

        case let .printCopies(count):
            var copies: [String: Int] = [:]
            var best = 0
            for opening in openings {
                for card in opening.cards {
                    let held = (copies[printID(card)] ?? 0) + 1
                    copies[printID(card)] = held
                    best = max(best, held)
                }
                if best >= count { return (count, count, opening.completedAt) }
            }
            return (best, count, nil)

        case let .starredPrints(count):
            var copies: [String: Int] = [:]
            var starred = 0
            for opening in openings {
                for card in opening.cards {
                    let held = (copies[printID(card)] ?? 0) + 1
                    copies[printID(card)] = held
                    if held == CardMastery.thresholds[0] { starred += 1 }
                }
                if starred >= count { return (count, count, opening.completedAt) }
            }
            return (starred, count, nil)

        case let .acceptedTokens(threshold):
            return (facts.totalAcceptedTokens, threshold, facts.tokenCrossings[threshold])

        case let .usageStreak(days):
            var best = 0
            var run = 0
            var previous: Int?
            for day in facts.usageDays.sorted(by: { $0.day < $1.day }) {
                run = previous.map { day.day == $0 + 1 ? run + 1 : 1 } ?? 1
                previous = day.day
                best = max(best, run)
                if run >= days { return (days, days, day.firstAt) }
            }
            return (best, days, nil)

        case let .usageTools(count):
            let dates = facts.toolFirstUse.values.sorted()
            return (dates.count, count, dates.count >= count ? dates[count - 1] : nil)
        }
    }

    private static func printID(_ card: AchievementFacts.Card) -> String {
        "\(card.key.rawValue)#\(card.variant.rawValue)"
    }
}

/// An achievement the store recorded, with the points it paid.
public struct AchievementRecord: Sendable, Hashable {
    public var achievementID: String
    public var achievedAt: Date
    public var unlockedAt: Date
    public var rewardPoints: Int
}
