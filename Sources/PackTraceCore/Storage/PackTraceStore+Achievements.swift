import Foundation

/// Achievements for this profile, judged on its own records.
extension PackTraceStore {
    public struct AchievementEvaluation: Sendable {
        /// Every achievement with its progress, in catalogue order.
        public var progress: [AchievementProgress]
        /// Unlocks recorded so far, by achievement id.
        public var records: [String: AchievementRecord]
        /// Achievements unlocked by this evaluation (their rewards were just paid).
        public var newlyUnlocked: [AchievementRecord]
    }

    /// The catalogue for the sets this store's library knows.
    public nonisolated var achievementCatalog: AchievementCatalog {
        AchievementCatalog.v1(
            sets: library.setIDs.map { ($0, library.setInfo(for: $0)?.name ?? $0.uppercased()) },
            rarities: Set(library.cards.map(\.rarity))
        )
    }

    /// Judges every achievement and records the ones that newly hold, paying
    /// each reward exactly once: the unlock row and its ledger entry are
    /// written in one transaction, and the ledger's idempotency key refuses a
    /// second payment even if two evaluations race.
    public func evaluateAchievements(now: Date = Date()) throws -> AchievementEvaluation {
        try requireOpen()
        let catalog = achievementCatalog
        let progress = catalog.evaluate(try achievementFacts(tokenThresholds: catalog.tokenThresholds))

        let newlyUnlocked: [AchievementRecord] = try database.transaction {
            let recorded = Set(try database.query("SELECT achievement_id FROM achievement") { $0.text(at: 0) })
            var unlocked: [AchievementRecord] = []
            for item in progress {
                guard let achievedAt = item.achievedAt, !recorded.contains(item.id) else { continue }
                let reward = max(0, item.definition.rewardPoints)
                var entryID: WalletEntryID?
                if reward > 0 {
                    let id = WalletEntryID()
                    try insertLedgerEntry(
                        id: id,
                        idempotencyKey: "achievement.\(item.id)",
                        deltaPoints: reward,
                        reason: .achievementReward,
                        reference: item.id,
                        createdAt: now
                    )
                    entryID = id
                }
                try database.run(
                    """
                    INSERT INTO achievement
                        (achievement_id, catalog_version, achieved_at, unlocked_at, reward_points, wallet_entry_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    [
                        .text(item.id),
                        .int(AchievementCatalog.version),
                        .double(achievedAt.timeIntervalSince1970),
                        .double(now.timeIntervalSince1970),
                        .int(reward),
                        .opt(entryID?.rawValue),
                    ]
                )
                unlocked.append(AchievementRecord(achievementID: item.id, achievedAt: achievedAt, unlockedAt: now, rewardPoints: reward))
            }
            return unlocked
        }
        return AchievementEvaluation(progress: progress, records: try achievementRecords(), newlyUnlocked: newlyUnlocked)
    }

    public func achievementRecords() throws -> [String: AchievementRecord] {
        let rows = try database.query(
            "SELECT achievement_id, achieved_at, unlocked_at, reward_points FROM achievement"
        ) { statement in
            AchievementRecord(
                achievementID: statement.text(at: 0),
                achievedAt: Date(timeIntervalSince1970: statement.double(at: 1)),
                unlockedAt: Date(timeIntervalSince1970: statement.double(at: 2)),
                rewardPoints: statement.int(at: 3)
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.achievementID, $0) })
    }

    /// The records achievements are judged on. Openings count only once every
    /// card was revealed, dated by when that happened.
    func achievementFacts(tokenThresholds: [Int]) throws -> AchievementFacts {
        var facts = AchievementFacts()
        for opening in try openings() {
            guard let completedAt = opening.completedAt else { continue }
            let cards = opening.cards.compactMap { drawn -> AchievementFacts.Card? in
                guard let card = library.card(for: drawn.cardKey) else { return nil }
                return AchievementFacts.Card(key: drawn.cardKey, variant: drawn.variant, rarity: card.rarity, setID: card.setID)
            }
            guard let setID = cards.first?.setID else { continue }
            facts.openings.append(AchievementFacts.Opening(completedAt: completedAt, setID: setID, cards: cards))
        }
        for setID in library.setIDs {
            facts.setPrintTotals[setID] = library.cards(inSet: setID).reduce(0) { $0 + $1.supportedVariants.count }
        }

        // Credited usage only: accepted events that carried tokens and that no
        // usage correction took back (a correction keeps the events as
        // history). Days are Seoul calendar days (UTC+9, no daylight saving),
        // as on Today.
        let credited = CreditedUsage.condition
        facts.usageDays = try database.query(
            """
            SELECT CAST((e.occurred_at + 32400) / 86400 AS INTEGER) AS day, MIN(e.occurred_at)
            FROM usage_event e
            WHERE \(credited) AND e.accepted_tokens > 0
            GROUP BY day ORDER BY day
            """
        ) { AchievementFacts.UsageDay(day: $0.int(at: 0), firstAt: Date(timeIntervalSince1970: $0.double(at: 1))) }
        facts.totalAcceptedTokens = try database.scalarInt(
            "SELECT COALESCE(SUM(e.accepted_tokens), 0) FROM usage_event e WHERE \(credited)"
        ) ?? 0
        for threshold in tokenThresholds where facts.totalAcceptedTokens >= threshold {
            let crossed = try database.query(
                """
                SELECT MIN(occurred_at) FROM (
                    SELECT e.occurred_at AS occurred_at,
                           SUM(e.accepted_tokens) OVER (ORDER BY e.occurred_at, e.rowid ROWS UNBOUNDED PRECEDING) AS running
                    FROM usage_event e WHERE \(credited)
                ) WHERE running >= ?
                """,
                [.int(threshold)]
            ) { $0.double(at: 0) }.first
            if let crossed {
                facts.tokenCrossings[threshold] = Date(timeIntervalSince1970: crossed)
            }
        }
        let tools = try database.query(
            """
            SELECT s.tool_kind, MIN(e.occurred_at)
            FROM usage_event e JOIN usage_source s ON s.source_id = e.source_id
            WHERE \(credited) AND e.accepted_tokens > 0
            GROUP BY s.tool_kind
            """
        ) { ($0.text(at: 0), Date(timeIntervalSince1970: $0.double(at: 1))) }
        facts.toolFirstUse = Dictionary(tools, uniquingKeysWith: min)
        return facts
    }
}
