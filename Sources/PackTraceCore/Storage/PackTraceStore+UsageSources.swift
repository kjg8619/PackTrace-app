import Foundation

/// Multi-source usage: every connected source for this realm, not just the
/// newest one.
///
/// The single-source helpers (`usageSource()`, `latestUsageSource()`) are kept
/// for the OMP path and for existing call sites, but anything that has to see
/// all tools goes through these.
extension PackTraceStore {
    /// Every source in this realm that is not disconnected, in a deterministic
    /// order (tool, then connection time) so scans and reward arithmetic do not
    /// depend on the order rows happen to come back in.
    public func usageSources() throws -> [UsageSourceRecord] {
        try usageSourceRows(where: "WHERE status != 'unconnected'")
    }

    /// Every row, including disconnected ones (a restore leaves sources waiting
    /// for an explicit reconnect).
    public func allUsageSourceRows() throws -> [UsageSourceRecord] {
        try usageSourceRows(where: "")
    }

    public func usageSource(id: String) throws -> UsageSourceRecord? {
        try usageSourceRows(where: "WHERE source_id = ?", bindings: [.text(id)]).first
    }

    /// The newest row for a tool *whatever its state*, so a restored profile can
    /// still offer "reconnect" with the path it used to read.
    public func latestUsageSource(tool: UsageToolKind) throws -> UsageSourceRecord? {
        try usageSourceRows(where: "WHERE tool_kind = ?", bindings: [.text(tool.rawValue)]).last
    }

    public func usageSource(tool: UsageToolKind) throws -> UsageSourceRecord? {
        try usageSourceRows(
            where: "WHERE tool_kind = ? AND status != 'unconnected'",
            bindings: [.text(tool.rawValue)]
        ).first
    }

    private func usageSourceRows(where clause: String, bindings: [SQLiteValue] = []) throws -> [UsageSourceRecord] {
        // Ordered in Swift by the tool's declared order, so the scan order is a
        // property of the app rather than of how the strings sort.
        let rows = try database.query(
            """
            SELECT source_id, realm, root_path, connected_at, baseline_completed_at,
                   paused, last_scan_at, status, last_reason, tool_kind, tool_version, format_version
            FROM usage_source
            \(clause)
            ORDER BY tool_kind ASC, connected_at ASC
            """,
            bindings
        ) { statement in
            Self.sourceRecord(from: statement, realm: self.location.realm)
        }
        return rows.sorted {
            ($0.tool.order, $0.connectedAt) < ($1.tool.order, $1.connectedAt)
        }
    }

    /// One row of `usage_source`, read in one place so every query stays in
    /// step with the columns.
    static func sourceRecord(from statement: SQLiteStatement, realm: Realm) -> UsageSourceRecord {
        let baselineAt: Date? = statement.optionalText(at: 4).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        let scannedAt: Date? = statement.optionalText(at: 6).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
        let tool = UsageToolKind(rawValue: statement.text(at: 9)) ?? .omp
        let status = UsageSourceStatus(rawValue: statement.text(at: 7)) ?? .unconnected
        return UsageSourceRecord(
            sourceID: statement.text(at: 0),
            realm: Realm(rawValue: statement.text(at: 1)) ?? realm,
            tool: tool,
            toolVersion: statement.optionalText(at: 10),
            formatVersion: statement.optionalText(at: 11),
            rootPath: statement.text(at: 2),
            connectedAt: Date(timeIntervalSince1970: statement.double(at: 3)),
            baselineCompletedAt: baselineAt,
            isPaused: statement.int(at: 5) != 0,
            lastScanAt: scannedAt,
            status: status,
            lastReason: statement.optionalText(at: 8)
        )
    }

    /// Connects a tool's storage.
    ///
    /// Re-selecting the same physical storage with the same adapter reuses the
    /// existing row — its baseline, checkpoints, cursor and pause state — so the
    /// user never accidentally starts a second connection over the same records.
    /// A source id is derived from tool + canonical path, which makes that reuse
    /// work even across restarts.
    @discardableResult
    public func connectUsageSource(
        tool: UsageToolKind,
        rootPath: String,
        now: Date = Date()
    ) throws -> UsageSourceRecord {
        let canonical = UsageSourceIdentity.canonicalise(URL(fileURLWithPath: rootPath))
        let identity = UsageSourceIdentity(tool: tool, canonicalPath: canonical)

        if let existing = try usageSourceRows(
            where: "WHERE tool_kind = ? AND root_path = ?",
            bindings: [.text(tool.rawValue), .text(canonical)]
        ).first {
            // Reconnecting is an explicit user action: it clears the paused and
            // blocked state so collection actually resumes. A source that has no
            // baseline yet (a restore clears it) starts baselining again, which
            // is what makes its current history history rather than reward.
            try database.run(
                """
                UPDATE usage_source
                SET status = ?, last_reason = NULL, paused = 0
                WHERE source_id = ?
                """,
                [
                    .text(existing.baselineCompletedAt == nil
                        ? UsageSourceStatus.baselining.rawValue
                        : UsageSourceStatus.collecting.rawValue),
                    .text(existing.sourceID),
                ]
            )
            return try usageSource(id: existing.sourceID) ?? existing
        }

        // A different path is *another* source, not a replacement: both keep
        // collecting, each with its own baseline. Disconnecting one is an
        // explicit action, never a side effect of connecting something else.
        try database.run(
            """
            INSERT INTO usage_source (
                source_id, realm, root_path, connected_at, baseline_completed_at,
                paused, last_scan_at, status, last_reason, tool_kind
            ) VALUES (?, ?, ?, ?, NULL, 0, NULL, ?, NULL, ?)
            """,
            [
                .text(identity.sourceID),
                .text(location.realm.rawValue),
                .text(canonical),
                .double(now.timeIntervalSince1970),
                .text(UsageSourceStatus.baselining.rawValue),
                .text(tool.rawValue),
            ]
        )
        guard let record = try usageSource(id: identity.sourceID) else {
            throw PackTraceError.storage("usage source insert failed")
        }
        return record
    }

    /// Records what the adapter saw about the tool's own version and storage
    /// layout. Diagnostics only; it never changes a reward decision.
    public func updateUsageSourceMetadata(
        sourceID: String,
        toolVersion: String?,
        formatVersion: String?
    ) throws {
        try database.run(
            "UPDATE usage_source SET tool_version = COALESCE(?, tool_version), format_version = COALESCE(?, format_version) WHERE source_id = ?",
            [.opt(toolVersion), .opt(formatVersion), .text(sourceID)]
        )
    }

    public func setUsageSourceStatus(
        _ status: UsageSourceStatus,
        reason: String? = nil,
        paused: Bool? = nil,
        sourceID: String,
        now: Date = Date()
    ) throws {
        // An explicit parameter list: this overload always says which source it
        // is about, so one tool's failure can never be written onto another.
        var sql = "UPDATE usage_source SET status = ?, last_reason = ?, last_scan_at = ?"
        var bindings: [SQLiteValue] = [
            .text(status.rawValue),
            .opt(reason),
            .double(now.timeIntervalSince1970),
        ]
        if let paused {
            sql += ", paused = ?"
            bindings.append(.int(paused ? 1 : 0))
        }
        sql += " WHERE source_id = ?"
        bindings.append(.text(sourceID))
        try database.run(sql, bindings)
    }

    public func setUsageSourcePaused(_ paused: Bool, sourceID: String, now: Date = Date()) throws {
        try database.run(
            "UPDATE usage_source SET paused = ?, status = ?, last_reason = NULL WHERE source_id = ?",
            [
                .int(paused ? 1 : 0),
                .text(paused ? UsageSourceStatus.paused.rawValue : UsageSourceStatus.collecting.rawValue),
                .text(sourceID),
            ]
        )
    }

    public func markUsageSourceBaselined(sourceID: String, now: Date = Date()) throws {
        try database.run(
            "UPDATE usage_source SET baseline_completed_at = ?, status = ?, last_reason = NULL WHERE source_id = ?",
            [.double(now.timeIntervalSince1970), .text(UsageSourceStatus.collecting.rawValue), .text(sourceID)]
        )
    }

    public func usageCursors(sourceID: String) throws -> [String: UsageCursor] {
        let rows = try database.query(
            "SELECT cursor_key, kind, payload, updated_at FROM usage_cursor WHERE source_id = ?",
            [.text(sourceID)]
        ) { statement in
            UsageCursor(
                cursorKey: statement.text(at: 0),
                kind: UsageCursor.Kind(rawValue: statement.text(at: 1)) ?? .rowPosition,
                payload: statement.text(at: 2),
                updatedAt: Date(timeIntervalSince1970: statement.double(at: 3))
            )
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.cursorKey, $0) })
    }

    /// Accepted tokens per tool for the common reward rule. A duplicate
    /// observation is stored once, so this sum cannot double-count the same
    /// call: only events that were actually credited are counted here, and each
    /// event belongs to exactly one source.
    public func usageToolTotals(ruleID: String = UsageRewardRule.ompNonCacheV1.ruleID) throws -> [UsageToolTotals] {
        let rows = try database.query(
            """
            SELECT s.tool_kind,
                   SUM(CASE WHEN \(CreditedUsage.condition) THEN e.accepted_tokens ELSE 0 END) AS accepted,
                   SUM(CASE WHEN \(CreditedUsage.condition) THEN 1 ELSE 0 END) AS accepted_events,
                   COUNT(*) AS observed,
                   SUM(CASE WHEN e.status = 'baseline' THEN 1 ELSE 0 END) AS baseline,
                   SUM(CASE WHEN e.status = 'excluded' THEN 1 ELSE 0 END) AS excluded,
                   SUM(CASE WHEN e.status = 'unsupported' THEN 1 ELSE 0 END) AS unsupported,
                   SUM(CASE WHEN e.status = 'conflict' THEN 1 ELSE 0 END) AS conflicts
            FROM usage_event e
            JOIN usage_source s ON s.source_id = e.source_id
            GROUP BY s.tool_kind
            ORDER BY s.tool_kind
            """,
            []
        ) { statement in
            UsageToolTotals(
                tool: UsageToolKind(rawValue: statement.text(at: 0)) ?? .omp,
                acceptedTokens: statement.int(at: 1),
                acceptedEvents: statement.int(at: 2),
                observedEvents: statement.int(at: 3),
                baselineEvents: statement.int(at: 4),
                excludedEvents: statement.int(at: 5),
                unsupportedEvents: statement.int(at: 6),
                conflictEvents: statement.int(at: 7)
            )
        }
        _ = ruleID
        return rows.sorted { $0.tool.order < $1.tool.order }
    }
}

/// Per-tool accepted usage for the common account.
public struct UsageToolTotals: Sendable, Hashable, Identifiable {
    public var id: String { tool.rawValue }
    public var tool: UsageToolKind
    /// Tokens that became part of the common account.
    public var acceptedTokens: Int
    public var acceptedEvents: Int
    /// Every record looked at, whatever the outcome.
    public var observedEvents: Int
    public var baselineEvents: Int
    public var excludedEvents: Int
    public var unsupportedEvents: Int
    public var conflictEvents: Int

    public init(
        tool: UsageToolKind,
        acceptedTokens: Int,
        acceptedEvents: Int,
        observedEvents: Int,
        baselineEvents: Int,
        excludedEvents: Int,
        unsupportedEvents: Int,
        conflictEvents: Int
    ) {
        self.tool = tool
        self.acceptedTokens = acceptedTokens
        self.acceptedEvents = acceptedEvents
        self.observedEvents = observedEvents
        self.baselineEvents = baselineEvents
        self.excludedEvents = excludedEvents
        self.unsupportedEvents = unsupportedEvents
        self.conflictEvents = conflictEvents
    }
}
