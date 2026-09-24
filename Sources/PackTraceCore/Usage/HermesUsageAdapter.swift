import Foundation

/// Hermes usage reader.
///
/// Contract (observed 2026-09-24 on hermes v0.21.3, docs/USAGE_SOURCES.md §12):
/// `~/.hermes/state.db` (SQLite, opened read-only) keeps running totals per
/// session, model, task and provider in `session_model_usage`
/// (`api_call_count`, `input_tokens`, `output_tokens`, `cache_read_tokens`,
/// `cache_write_tokens`, `last_seen`). `input_tokens` is already the non-cached
/// input (cache reads exceed it in 137 of 203 subscription rows).
///
/// There is no per-call record, so the adapter credits the *growth* of each
/// row: the last totals it saw are kept as a cursor per row, and only the
/// increase after the connection becomes an event. A row that shrinks (a
/// rewind or a reset) is re-anchored without credit.
public struct HermesUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "hermes-session-model-usage-1"

    public init() {}

    public var tool: UsageToolKind { .hermes }

    static func databaseURL(_ source: UsageSourceRecord) -> URL {
        URL(fileURLWithPath: source.rootPath).appendingPathComponent("state.db")
    }

    // MARK: - Discovery

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        let root = home.appendingPathComponent(".hermes", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent("state.db").path)
        return [UsageSourceCandidate(identity: UsageSourceIdentity(tool: .hermes, url: root), origin: "default",
                                     note: exists ? nil : "not found", exists: exists)]
    }

    // MARK: - Inspection

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let database = Self.databaseURL(source)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return UsageSourceInspection(support: .empty, detail: "state.db가 아직 없습니다")
        }
        guard let db = try? SQLiteDatabase(readOnlyPath: database.path) else {
            return UsageSourceInspection(support: .unreadable, detail: "state.db를 열 수 없습니다")
        }
        defer { db.close() }
        let columns = Set((try? db.query("PRAGMA table_info(session_model_usage)", []) { $0.text(at: 1) }) ?? [])
        let required: Set<String> = ["session_id", "model", "task", "billing_provider", "billing_base_url", "api_call_count",
                                     "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "last_seen"]
        guard required.isSubset(of: columns) else {
            return UsageSourceInspection(support: .unsupportedVersion, detail: "session_model_usage 형식이 다릅니다")
        }
        return UsageSourceInspection(
            support: .supported,
            formatVersion: Self.formatVersion,
            detail: "state.db · session_model_usage 누적값의 증가분",
            providerScope: ["모델 서비스 호출의 비캐시 입력 + 출력(세션별 누적값이 늘어난 만큼)"],
            excluded: ["로컬 주소(localhost)로 호출한 모델", "캐시 읽기·쓰기", "연결 전 누적값"]
        )
    }

    // MARK: - Slice

    struct Row: Sendable {
        var sessionID: String
        var model: String
        var task: String
        var provider: String
        var baseURL: String
        var calls: Int
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheWrite: Int
        var reasoning: Int
        var firstSeen: Double
        var lastSeen: Double

        var key: String { "\(sessionID)|\(model)|\(task)|\(provider)" }
        var totals: [Int] { [calls, input, output, cacheRead, cacheWrite] }
    }

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        var output = UsageSliceOutput()
        let database = Self.databaseURL(request.source)
        guard FileManager.default.fileExists(atPath: database.path) else {
            output.status = .rootMissing
            output.statusReason = "database_missing"
            return output
        }
        let rows: [Row]
        do {
            let db = try SQLiteDatabase(readOnlyPath: database.path)
            defer { db.close() }
            rows = try db.query(
                """
                SELECT session_id, COALESCE(model, ''), COALESCE(task, ''), COALESCE(billing_provider, ''),
                       COALESCE(billing_base_url, ''), COALESCE(api_call_count, 0), COALESCE(input_tokens, 0),
                       COALESCE(output_tokens, 0), COALESCE(cache_read_tokens, 0), COALESCE(cache_write_tokens, 0),
                       COALESCE(reasoning_tokens, 0), COALESCE(first_seen, 0), COALESCE(last_seen, 0)
                FROM session_model_usage
                ORDER BY session_id, model, task
                """,
                []
            ) { row in
                Row(sessionID: row.text(at: 0), model: row.text(at: 1), task: row.text(at: 2), provider: row.text(at: 3),
                    baseURL: row.text(at: 4), calls: row.int(at: 5), input: row.int(at: 6), output: row.int(at: 7),
                    cacheRead: row.int(at: 8), cacheWrite: row.int(at: 9), reasoning: row.int(at: 10),
                    firstSeen: row.double(at: 11), lastSeen: row.double(at: 12))
            }
        } catch {
            output.status = .permissionDenied
            output.statusReason = "query_failed"
            output.counters.errorCount += 1
            return output
        }
        output.counters.recordsSeen = rows.count
        var sessions = Set<String>()
        for row in rows {
            let decision = Self.decide(row: row, previous: request.cursors["row:\(row.key)"], request: request)
            if let cursor = decision.cursor { output.cursors.append(cursor) }
            if let entry = decision.entry {
                output.entries.append(entry)
                if sessions.insert(row.sessionID).inserted {
                    output.sessions.append(UsageSessionObservation(sessionID: row.sessionID, schemaVersion: 1))
                }
            }
        }
        return output
    }

    /// What one row means for this pass: a new position, and an event for the
    /// growth since the last one, if there is any to credit.
    static func decide(row: Row, previous: UsageCursor?, request: UsageSliceRequest) -> (cursor: UsageCursor?, entry: UsageBatchEntry?) {
        let current = row.totals.map(String.init).joined(separator: "|")
        let cursor = UsageCursor(cursorKey: "row:\(row.key)", kind: .rowPosition, payload: current, updatedAt: request.now)
        let before = previous.map { $0.payload.split(separator: "|").compactMap { Int($0) } }
        if let before, before == row.totals { return (nil, nil) }

        // History: everything that is there while the baseline is fixed, and a
        // row this reader never saw that existed before the connection.
        let connected = request.source.connectedAt.timeIntervalSince1970
        guard !request.isBaselining, before != nil || row.firstSeen >= connected else { return (cursor, nil) }
        let base = before ?? [0, 0, 0, 0, 0]
        guard base.count == 5 else { return (cursor, nil) }
        let delta = zip(row.totals, base).map { $0 - $1 }
        // Shrunk: a rewind or a reset. Re-anchor without paying anything.
        guard delta.allSatisfy({ $0 >= 0 }) else { return (cursor, nil) }
        guard delta[1] + delta[2] > 0 else { return (cursor, nil) }

        var event = UsageEvent(
            id: UsageEventID(tool: .hermes, sessionID: row.sessionID, responseID: "\(row.model)|\(row.task)|\(row.provider)#\(current)"),
            sessionID: row.sessionID,
            responseID: "\(row.model)|\(row.task)|\(row.provider)#\(current)",
            provider: row.provider.isEmpty ? "unknown" : row.provider,
            model: row.model.isEmpty ? "unknown" : row.model,
            stopReason: "completed",
            occurredAtMilliseconds: Int(row.lastSeen * 1000),
            completedAtMilliseconds: nil,
            inputTokens: delta[1],
            outputTokens: delta[2],
            cacheReadTokens: delta[3],
            cacheWriteTokens: delta[4]
        )
        event.normalizationVersion = 1
        if isLocal(row.baseURL) {
            return (cursor, UsageBatchEntry(event: event, status: .excluded, reason: .localModelExcluded))
        }
        return (cursor, UsageBatchEntry(event: event, status: .accepted))
    }

    static func isLocal(_ baseURL: String) -> Bool {
        let host = URL(string: baseURL)?.host?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host)
    }
}
