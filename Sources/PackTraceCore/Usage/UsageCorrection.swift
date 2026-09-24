import Foundation

/// Correcting credited usage that should never have been credited.
///
/// The mistake this exists for: a source's baseline was closed while history was
/// still being read, so past calls were credited as new usage. Nothing here
/// deletes or rewrites that history — the events and the ledger entry they
/// produced stay readable. A correction records which events were miscredited
/// and expresses the difference as one separate ledger entry, so both the
/// original record and the valid total can be inspected afterwards.
public struct UsageCorrectionCandidate: Sendable, Hashable {
    public var eventID: String
    public var acceptedTokens: Int
    public var occurredAt: Date?

    public init(eventID: String, acceptedTokens: Int, occurredAt: Date? = nil) {
        self.eventID = eventID
        self.acceptedTokens = acceptedTokens
        self.occurredAt = occurredAt
    }
}

/// What a correction would do, computed from the state as it is now.
///
/// The numbers are never carried between runs: a plan is recalculated against
/// the account's current accepted tokens, so usage that arrived since the last
/// look changes the result instead of being subtracted from a frozen amount.
public struct UsageCorrectionPlan: Sendable, Hashable {
    public var incidentID: String
    public var realm: Realm
    public var ruleID: String
    public var sourceID: String
    /// Events confirmed as miscredited, sorted for a stable digest.
    public var candidates: [UsageCorrectionCandidate]
    public var excludedTokens: Int
    public var eventDigest: String

    public var beforeAcceptedTokens: Int
    public var beforePoints: Int
    public var beforeRemainder: Int
    public var beforeBalance: Int

    /// `beforeAcceptedTokens - excludedTokens`, floored at zero by construction:
    /// a correction can never be larger than what is currently credited.
    public var afterAcceptedTokens: Int
    public var afterPoints: Int
    public var afterRemainder: Int
    /// Negative when points were over-credited.
    public var deltaPoints: Int
    public var expectedBalance: Int

    /// Set when the plan must not be applied.
    public var blockedReason: String?

    public var isApplicable: Bool { blockedReason == nil }

    public var eventCount: Int { candidates.count }
}

public extension UsageCorrectionPlan {
    /// The only place the correction arithmetic lives, so a regression test can
    /// check it against recorded snapshots and the store uses the same code.
    static func compute(
        beforeAcceptedTokens: Int,
        beforePoints: Int,
        excludedTokens: Int,
        tokensPerPoint: Int
    ) -> (afterAcceptedTokens: Int, afterPoints: Int, afterRemainder: Int, deltaPoints: Int) {
        let perPoint = max(tokensPerPoint, 1)
        let afterAccepted = max(0, beforeAcceptedTokens - excludedTokens)
        let afterPoints = afterAccepted / perPoint
        return (
            afterAcceptedTokens: afterAccepted,
            afterPoints: afterPoints,
            afterRemainder: afterAccepted % perPoint,
            deltaPoints: afterPoints - beforePoints
        )
    }

    /// Stable digest over the corrected set: sorted ids and their tokens, so two
    /// plans can be compared without storing the whole list.
    static func digest(of candidates: [UsageCorrectionCandidate]) -> String {
        let text = candidates
            .sorted { $0.eventID < $1.eventID }
            .map { "\($0.eventID):\($0.acceptedTokens)" }
            .joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }
}

/// SQL for "this usage event still counts": accepted, and not excluded
/// later by a usage correction. A correction keeps the original events (they
/// stay `accepted` as history) and records which ones it took back, so any
/// statistic of credited usage has to leave those out. Expects the event
/// table under the alias `e`.
enum CreditedUsage {
    static let condition = """
        e.status = 'accepted'
        AND NOT EXISTS (SELECT 1 FROM usage_correction_event c WHERE c.event_id = e.event_id)
        """
}

public enum UsageCorrectionError: Error, Equatable {
    case alreadyApplied(incidentID: String)
    case blocked(String)
    case accountMismatch

    public var displayMessage: String {
        switch self {
        case let .alreadyApplied(incidentID): "이미 적용된 보정입니다(\(incidentID))"
        case let .blocked(reason): "적용할 수 없습니다: \(reason)"
        case .accountMismatch: "보상 계정 상태가 계획과 다릅니다. 계획을 다시 계산하세요"
        }
    }
}

extension PackTraceStore {
    /// Confirmed miscredited events for one source: accepted events whose call
    /// happened before the connection existed.
    ///
    /// This is the same rule the OMP path already uses for an imported call, so a
    /// past call never becomes payable just because a tool was connected later.
    /// The connection's own timestamp is the boundary, and the tool's own record
    /// of when the call happened is the evidence — not the moment PackTrace
    /// happened to read it.
    public func miscreditedEvents(sourceID: String) throws -> [UsageCorrectionCandidate] {
        try database.query(
            """
            SELECT e.event_id, e.accepted_tokens, e.occurred_at
            FROM usage_event e
            JOIN usage_source s ON s.source_id = e.source_id
            WHERE e.source_id = ?
              AND e.status = 'accepted'
              AND e.occurred_at < s.connected_at
              -- An event that a previous correction already excluded must not be
              -- excluded again: a second plan would otherwise compute a second
              -- adjustment for the same tokens.
              AND NOT EXISTS (
                  SELECT 1 FROM usage_correction_event c WHERE c.event_id = e.event_id
              )
            ORDER BY e.event_id
            """,
            [.text(sourceID)]
        ) { statement in
            UsageCorrectionCandidate(
                eventID: statement.text(at: 0),
                acceptedTokens: statement.int(at: 1),
                occurredAt: Date(timeIntervalSince1970: statement.double(at: 2))
            )
        }
    }

    /// Computes what a correction would change, without writing anything.
    public func usageCorrectionPlan(
        incidentID: String,
        sourceID: String,
        rule: UsageRewardRule = .ompNonCacheV1
    ) throws -> UsageCorrectionPlan {
        let candidates = try miscreditedEvents(sourceID: sourceID)
        let excluded = candidates.reduce(0) { $0 + $1.acceptedTokens }
        let state = try correctionAccountState(ruleID: rule.ruleID)
        let balance = try walletBalance()

        let computed = UsageCorrectionPlan.compute(
            beforeAcceptedTokens: state.acceptedTokens,
            beforePoints: state.awardedPoints,
            excludedTokens: excluded,
            tokensPerPoint: rule.tokensPerPoint
        )
        let afterAccepted = computed.afterAcceptedTokens
        let afterPoints = computed.afterPoints
        let afterRemainder = computed.afterRemainder
        let delta = computed.deltaPoints
        let expected = balance + delta

        var blocked: String?
        if try isCorrectionApplied(incidentID: incidentID) {
            blocked = "이미 적용된 보정입니다"
        } else if candidates.isEmpty || excluded == 0 {
            blocked = "보정할 대상이 없습니다"
        } else if expected < 0 {
            // Never silently clamp, never claw back cards to make the books fit.
            blocked = "조정 후 잔액이 음수입니다(\(expected) P). 사용자 결정이 필요합니다"
        } else if state.remainderTokens != state.acceptedTokens % max(rule.tokensPerPoint, 1) {
            blocked = "보상 계정의 나머지가 누적 인정량과 일치하지 않습니다"
        }

        return UsageCorrectionPlan(
            incidentID: incidentID,
            realm: location.realm,
            ruleID: rule.ruleID,
            sourceID: sourceID,
            candidates: candidates,
            excludedTokens: excluded,
            eventDigest: UsageCorrectionPlan.digest(of: candidates),
            beforeAcceptedTokens: state.acceptedTokens,
            beforePoints: state.awardedPoints,
            beforeRemainder: state.remainderTokens,
            beforeBalance: balance,
            afterAcceptedTokens: afterAccepted,
            afterPoints: afterPoints,
            afterRemainder: afterRemainder,
            deltaPoints: delta,
            expectedBalance: expected,
            blockedReason: blocked
        )
    }

    /// Applies a correction: the exclusion record, the account state and the one
    /// adjustment entry commit together, or none of them do.
    ///
    /// The plan is re-checked against the current account first. A plan made
    /// against a different state is refused rather than applied to numbers it was
    /// not computed from.
    @discardableResult
    public func applyUsageCorrection(
        _ plan: UsageCorrectionPlan,
        rule: UsageRewardRule = .ompNonCacheV1,
        now: Date = Date()
    ) throws -> UsageCorrectionPlan {
        try requireOpen()
        guard plan.isApplicable else { throw UsageCorrectionError.blocked(plan.blockedReason ?? "unknown") }
        return try database.transaction {
            if try isCorrectionApplied(incidentID: plan.incidentID) {
                throw UsageCorrectionError.alreadyApplied(incidentID: plan.incidentID)
            }
            #if DEBUG
            if injectedFailure == .beforeUsageBatchCommit {
                throw PackTraceError.injectedFailure("usage.correction.before-commit")
            }
            #endif
            let state = try correctionAccountState(ruleID: rule.ruleID)
            guard state.acceptedTokens == plan.beforeAcceptedTokens,
                  state.awardedPoints == plan.beforePoints,
                  state.remainderTokens == plan.beforeRemainder
            else { throw UsageCorrectionError.accountMismatch }
            // The balance is checked again here, under the write lock: a pack
            // bought between the plan and the apply (by the app, while the tool
            // planned) would otherwise take the wallet below zero — and every
            // later backup of it would be refused on restore.
            let balance = try database.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
            guard balance + plan.deltaPoints >= 0 else {
                throw UsageCorrectionError.blocked("잔액 \(balance) P에서 \(-plan.deltaPoints) P를 빼면 음수가 됩니다")
            }

            var entryID: WalletEntryID?
            if plan.deltaPoints != 0 {
                let id = WalletEntryID()
                try insertLedgerEntry(
                    id: id,
                    idempotencyKey: "usage.correction.\(plan.incidentID)",
                    deltaPoints: plan.deltaPoints,
                    reason: .usageCorrection,
                    reference: plan.incidentID,
                    createdAt: now
                )
                entryID = id
            } else {
                // A zero-point correction still needs an entry id for the record.
                let id = WalletEntryID()
                try insertLedgerEntry(
                    id: id,
                    idempotencyKey: "usage.correction.\(plan.incidentID)",
                    deltaPoints: 0,
                    reason: .usageCorrection,
                    reference: plan.incidentID,
                    createdAt: now
                )
                entryID = id
            }

            try database.run(
                """
                INSERT INTO usage_correction (
                    incident_id, realm, rule_id, excluded_tokens, event_count, event_digest,
                    before_accepted_tokens, after_accepted_tokens, before_points, after_points,
                    after_remainder, delta_points, entry_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(plan.incidentID),
                    .text(location.realm.rawValue),
                    .text(plan.ruleID),
                    .int(plan.excludedTokens),
                    .int(plan.eventCount),
                    .text(plan.eventDigest),
                    .int(plan.beforeAcceptedTokens),
                    .int(plan.afterAcceptedTokens),
                    .int(plan.beforePoints),
                    .int(plan.afterPoints),
                    .int(plan.afterRemainder),
                    .int(plan.deltaPoints),
                    .text(entryID!.rawValue),
                    .double(now.timeIntervalSince1970),
                ]
            )
            for candidate in plan.candidates {
                try database.run(
                    "INSERT OR REPLACE INTO usage_correction_event (incident_id, event_id, tokens) VALUES (?, ?, ?)",
                    [.text(plan.incidentID), .text(candidate.eventID), .int(candidate.acceptedTokens)]
                )
            }
            try database.run(
                """
                INSERT INTO reward_state (rule_id, realm, remainder_tokens, accepted_tokens, awarded_points, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(rule_id) DO UPDATE SET
                    remainder_tokens = excluded.remainder_tokens,
                    accepted_tokens = excluded.accepted_tokens,
                    awarded_points = excluded.awarded_points,
                    updated_at = excluded.updated_at
                """,
                [
                    .text(rule.ruleID),
                    .text(location.realm.rawValue),
                    .int(plan.afterRemainder),
                    .int(plan.afterAcceptedTokens),
                    .int(plan.afterPoints),
                    .double(now.timeIntervalSince1970),
                ]
            )
            return plan
        }
    }

    /// Tokens that have been excluded by an applied correction, so a status view
    /// can show the valid total separately from the raw history.
    public func correctedTokens(ruleID: String = UsageRewardRule.ompNonCacheV1.ruleID) throws -> Int {
        try database.scalarInt(
            "SELECT COALESCE(SUM(excluded_tokens), 0) FROM usage_correction WHERE rule_id = ?",
            [.text(ruleID)]
        ) ?? 0
    }

    public func corrections() throws -> [(incidentID: String, excludedTokens: Int, deltaPoints: Int, createdAt: Date)] {
        try database.query(
            "SELECT incident_id, excluded_tokens, delta_points, created_at FROM usage_correction ORDER BY created_at"
        ) { statement in
            (
                incidentID: statement.text(at: 0),
                excludedTokens: statement.int(at: 1),
                deltaPoints: statement.int(at: 2),
                createdAt: Date(timeIntervalSince1970: statement.double(at: 3))
            )
        }
    }

    func isCorrectionApplied(incidentID: String) throws -> Bool {
        let count = try database.scalarInt(
            "SELECT COUNT(*) FROM usage_correction WHERE incident_id = ?",
            [.text(incidentID)]
        ) ?? 0
        return count > 0
    }

    private func correctionAccountState(ruleID: String) throws -> (acceptedTokens: Int, awardedPoints: Int, remainderTokens: Int) {
        let row = try database.query(
            "SELECT accepted_tokens, awarded_points, remainder_tokens FROM reward_state WHERE rule_id = ?",
            [.text(ruleID)]
        ) { statement in
            (statement.int(at: 0), statement.int(at: 1), statement.int(at: 2))
        }.first
        return row ?? (0, 0, 0)
    }

    private func walletBalance() throws -> Int {
        try database.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
    }
}
