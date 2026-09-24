import Foundation

/// Reads a profile's usage connections without the ability to change anything.
///
/// Deliberately not the store: opening the store can create a database or run a
/// migration, and a status query must never do either. This opens read-only and
/// runs only SELECTs.
public struct UsageProfileReader: Sendable {
    public struct Source: Sendable, Hashable {
        public var tool: UsageToolKind
        public var status: UsageSourceStatus
        public var isPaused: Bool
        public var maskedPath: String
        public var baselineCompleted: Bool
        public var reason: String?
    }

    public struct ToolTotal: Sendable, Hashable {
        public var tool: UsageToolKind
        public var acceptedTokens: Int
        public var acceptedEvents: Int
    }

    public struct Reward: Sendable, Hashable {
        public var remainderTokens: Int
        public var acceptedTokens: Int
        public var awardedPoints: Int
    }

    public struct Report: Sendable, Hashable {
        public var databaseExists: Bool
        public var schemaVersion: Int
        public var sources: [Source]
        public var toolTotals: [ToolTotal]
        public var reward: Reward?
    }

    public init() {}

    /// `nil` when the profile does not exist yet, which is a normal state and not
    /// something to create on the caller's behalf.
    public func read(databaseURL: URL) throws -> Report? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let db = try SQLiteDatabase(readOnlyPath: databaseURL.path)
        defer { db.close() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        let sources = try db.query(
            """
            SELECT tool_kind, status, paused, root_path, baseline_completed_at, last_reason
            FROM usage_source ORDER BY tool_kind ASC, connected_at ASC
            """
        ) { row in
            let path = row.optionalText(at: 3) ?? "-"
            return Source(
                tool: UsageToolKind(rawValue: row.text(at: 0)) ?? .omp,
                status: UsageSourceStatus(rawValue: row.text(at: 1)) ?? .unconnected,
                isPaused: row.int(at: 2) == 1,
                maskedPath: path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path,
                baselineCompleted: row.optionalText(at: 4) != nil,
                reason: row.optionalText(at: 5)
            )
        }
        let totals = try db.query(
            """
            SELECT s.tool_kind,
                   SUM(CASE WHEN e.status = 'accepted' THEN e.accepted_tokens ELSE 0 END),
                   SUM(CASE WHEN e.status = 'accepted' THEN 1 ELSE 0 END)
            FROM usage_event e JOIN usage_source s ON s.source_id = e.source_id
            GROUP BY s.tool_kind ORDER BY s.tool_kind ASC
            """
        ) { row in
            ToolTotal(
                tool: UsageToolKind(rawValue: row.text(at: 0)) ?? .omp,
                acceptedTokens: row.int(at: 1),
                acceptedEvents: row.int(at: 2)
            )
        }
        let reward = try db.query(
            "SELECT remainder_tokens, accepted_tokens, awarded_points FROM reward_state LIMIT 1"
        ) { row in
            Reward(remainderTokens: row.int(at: 0), acceptedTokens: row.int(at: 1), awardedPoints: row.int(at: 2))
        }.first

        return Report(
            databaseExists: true,
            schemaVersion: Int(db.userVersion),
            sources: sources,
            toolTotals: totals,
            reward: reward
        )
    }
}
