import Foundation

/// OpenCode usage reader.
///
/// Contract (verified on `opencode 1.18.31`, docs/USAGE_SOURCES.md §6): sessions
/// live in a SQLite database (`<data root>/opencode.db`, WAL) with a `message`
/// table — `id`, `session_id`, `time_created`, `time_updated`, `data` (JSON) —
/// indexed by `(session_id, time_created, id)`.
///
/// The original database is opened **read-only**: no journal-mode change, no
/// migration, no VACUUM, no index, and no copy of the main file pretending to be
/// a consistent snapshot while its WAL is live.
public struct OpenCodeUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "opencode-message-v1"
    public static let databaseName = "opencode.db"

    public init() {}

    /// Values observed on the supported installation for a call that finished
    /// and wrote its usage.
    static let completedFinishes: Set<String> = ["tool-calls", "stop", "length"]

    public var tool: UsageToolKind { .openCode }

    public func storageKind(source: UsageSourceRecord) -> UsageSourceStorageKind { .sqliteDatabase }

    // MARK: - Discovery

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        var roots: [(URL, String)] = []
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            roots.append((URL(fileURLWithPath: xdg).appendingPathComponent("opencode", isDirectory: true), "environment"))
        }
        roots.append((home.appendingPathComponent(".local/share/opencode", isDirectory: true), "default"))
        return roots.map { url, origin in
            let database = url.appendingPathComponent(Self.databaseName)
            let exists = FileManager.default.fileExists(atPath: database.path)
            return UsageSourceCandidate(
                identity: UsageSourceIdentity(tool: .openCode, url: url),
                origin: origin,
                note: exists ? nil : "\(Self.databaseName) not found",
                exists: exists
            )
        }
    }

    // MARK: - Inspection

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let database = databaseURL(source)
        guard FileManager.default.fileExists(atPath: database.path) else {
            return UsageSourceInspection(
                support: .empty,
                detail: "\(Self.databaseName)가 아직 없습니다",
                providerScope: ["OpenCode assistant message tokens"],
                excluded: ["user 메시지", "cache read/write", "요약·정리 메시지"]
            )
        }
        do {
            let db = try SQLiteDatabase(readOnlyPath: database.path)
            defer { db.close() }
            let columns = try db.query("PRAGMA table_info(message)", []) { $0.text(at: 1) }
            guard !columns.isEmpty else {
                return UsageSourceInspection(support: .unsupportedVersion, detail: "message 테이블이 없습니다")
            }
            let expected = ["id", "session_id", "time_created", "time_updated", "data"]
            let missing = expected.filter { !columns.contains($0) }
            guard missing.isEmpty else {
                return UsageSourceInspection(
                    support: .unsupportedVersion,
                    detail: "message 테이블 컬럼이 다릅니다(없음: \(missing.joined(separator: ",")))"
                )
            }
            let count = try db.scalarInt("SELECT COUNT(*) FROM message", []) ?? 0
            guard count > 0 else {
                return UsageSourceInspection(
                    support: .empty,
                    detail: "message 테이블이 비어 있습니다",
                    providerScope: ["OpenCode assistant message tokens"]
                )
            }
            return UsageSourceInspection(
                support: .supported,
                toolVersion: nil,
                formatVersion: Self.formatVersion,
                detail: "SQLite message 테이블(읽기 전용) · tokens.input/output/reasoning/cache",
                providerScope: ["OpenCode assistant message tokens"],
                excluded: ["user 메시지", "cache read/write", "요약 메시지", "finish 의미 미확인 값"]
            )
        } catch {
            return .unreadable("데이터베이스를 읽을 수 없습니다(권한 또는 손상)")
        }
    }

    // MARK: - Slice

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        var output = UsageSliceOutput()
        let database = databaseURL(request.source)
        guard FileManager.default.fileExists(atPath: database.path) else {
            output.status = .rootMissing
            output.statusReason = "database_missing"
            return output
        }
        let db: SQLiteDatabase
        do {
            db = try SQLiteDatabase(readOnlyPath: database.path)
        } catch {
            output.status = .permissionDenied
            output.statusReason = "permission_denied"
            output.counters.errorCount += 1
            return output
        }
        defer { db.close() }

        do {
            // New rows, in the order the index already provides. A composite
            // cursor (time, id) keeps two rows written in the same millisecond
            // from hiding each other.
            let appendCursor = request.cursors[appendKey]
            let appendCutoff = appendCursor.flatMap { Int64($0.payload.split(separator: "|").first.map(String.init) ?? "") } ?? 0
            let appendID = appendCursor.flatMap { $0.payload.split(separator: "|", maxSplits: 1).last.map(String.init) } ?? ""
            // While the baseline is being fixed, only rows created before the
            // connection are walked: everything in a baselining batch is stored
            // as history, and a row created after the connection that the walk
            // reached during those passes used to be lost that way. Those rows
            // wait for the first pass after the baseline, and are credited then.
            let createdBefore = request.isBaselining
                ? Int64(request.source.connectedAt.timeIntervalSince1970 * 1000)
                : Int64.max
            let rows = try db.query(
                """
                SELECT id, session_id, time_created, time_updated, data FROM message
                WHERE (time_created > ? OR (time_created = ? AND id > ?)) AND time_created < ?
                ORDER BY time_created ASC, id ASC
                LIMIT ?
                """,
                [
                    .int(Int(appendCutoff)),
                    .int(Int(appendCutoff)),
                    .text(appendID),
                    .int(Int(createdBefore)),
                    .int(request.budget.maxRows),
                ]
            ) { row in
                Row(
                    id: row.text(at: 0),
                    sessionID: row.text(at: 1),
                    createdAt: Int64(row.int(at: 2)),
                    updatedAt: Int64(row.int(at: 3)),
                    data: row.text(at: 4)
                )
            }
            output.counters.recordsSeen += rows.count
            var lastCreated = appendCutoff
            var lastID = appendID
            for row in rows {
                lastCreated = row.createdAt
                lastID = row.id
                append(row, request: request, into: &output)
            }
            if rows.count >= request.budget.maxRows { output.moreWork = true }
            // Both walks have to be drained before the baseline is done. The
            // append walk can finish while the update walk still has the table
            // ahead of it, and marking the baseline complete at that point made
            // every remaining row look new — which credited history.

            // The position is always written back, even when this pass read
            // nothing: a cursor that is only emitted when rows appear would be
            // forgotten, and the next pass would read the whole table again.
            output.cursors.append(
                UsageCursor(
                    cursorKey: appendKey,
                    kind: .rowPosition,
                    payload: "\(lastCreated)|\(lastID)",
                    updatedAt: request.now
                )
            )

            // Rows whose update time moved: a message that had no tokens when it
            // was first seen gets them when the call finishes.
            // Composite position (time_updated, id): two rows touched in the
            // same millisecond must not hide each other, and a row already read
            // at this position is not read again.
            let recheckParts = request.cursors[recheckKey]?.payload.split(separator: "|", maxSplits: 1) ?? []
            // Without a stored position the recheck starts where the append read
            // started: rows written before this pass have already been looked at,
            // and a row that gains tokens later moves its update time past it.
            let recheckSince = Int64(recheckParts.first.map(String.init) ?? "") ?? appendCutoff
            let recheckID = recheckParts.count > 1 ? String(recheckParts[1]) : ""
            let updated = try db.query(
                """
                SELECT id, session_id, time_created, time_updated, data FROM message
                WHERE (time_updated > ? OR (time_updated = ? AND id > ?)) AND time_created < ?
                ORDER BY time_updated ASC, id ASC
                LIMIT ?
                """,
                [
                    .int(Int(max(0, recheckSince))),
                    .int(Int(max(0, recheckSince))),
                    .text(recheckID),
                    .int(Int(createdBefore)),
                    .int(request.budget.maxRows),
                ]
            ) { row in
                Row(
                    id: row.text(at: 0),
                    sessionID: row.text(at: 1),
                    createdAt: Int64(row.int(at: 2)),
                    updatedAt: Int64(row.int(at: 3)),
                    data: row.text(at: 4)
                )
            }
            output.counters.recordsSeen += updated.count
            if updated.count >= request.budget.maxRows { output.moreWork = true }
            var latestUpdate = recheckSince
            var latestUpdateID = recheckID
            let appendedIDs = Set(rows.map(\.id))
            for row in updated {
                latestUpdate = row.updatedAt
                latestUpdateID = row.id
                if appendedIDs.contains(row.id) { continue } // already read in this slice
                recheck(row, request: request, into: &output)
            }
            // Emitted unconditionally for the same reason. When no row moved,
            // this is the position the pass started from, so it never rewinds.
            output.cursors.append(
                UsageCursor(
                    cursorKey: recheckKey,
                    kind: .rowPosition,
                    payload: "\(latestUpdate)|\(latestUpdateID)",
                    updatedAt: request.now
                )
            )
        } catch {
            output.status = .permissionDenied
            output.statusReason = "query_failed"
            output.counters.errorCount += 1
        }
        return output
    }

    struct Row {
        var id: String
        var sessionID: String
        var createdAt: Int64
        var updatedAt: Int64
        var data: String
    }

    /// A row seen for the first time: it is read, and while the connection's
    /// baseline is still open nothing is credited.
    private func append(_ row: Row, request: UsageSliceRequest, into output: inout UsageSliceOutput) {
        guard let event = event(from: row) else {
            if let parsed = parse(row.data) {
                output.sessions.append(UsageSessionObservation(sessionID: row.sessionID, schemaVersion: 1))
                _ = parsed
            }
            return
        }
        output.sessions.append(UsageSessionObservation(sessionID: row.sessionID, schemaVersion: 1))
        output.entries.append(UsageBatchEntry(event: event, status: .accepted))
    }

    /// A row re-read because its update time moved. The identity is the same, so
    /// the store decides: an unchanged fingerprint is a duplicate, a changed one
    /// is a conflict rather than a second payment.
    private func recheck(_ row: Row, request: UsageSliceRequest, into output: inout UsageSliceOutput) {
        guard let event = event(from: row) else { return }
        output.entries.append(UsageBatchEntry(event: event, status: .accepted))
    }

    /// One assistant message with tokens. `tokens.total` equals
    /// `input + output + reasoning + cache.write + cache.read` (verified over
    /// 3,492 assistant rows), which is how the accepted amount is derived:
    /// non-cached input plus everything the model generated, counted once.
    func event(from row: Row) -> UsageEvent? {
        guard let object = parse(row.data),
              object["role"] as? String == "assistant",
              let tokens = object["tokens"] as? [String: Any] else { return nil }
        guard let input = intValue(tokens["input"]),
              let output = intValue(tokens["output"]) else { return nil }
        let reasoning = intValue(tokens["reasoning"]) ?? 0
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let cacheRead = intValue(cache["read"]) ?? 0
        let cacheWrite = intValue(cache["write"]) ?? 0

        let finish = object["finish"] as? String
        // Verified on this installation (20,000 sampled rows): the only values
        // are `tool-calls` (15,161), `stop` (1,893), `length` (1) and absent
        // (299) — no error or aborted value exists. Usage is written when the
        // call finishes, so a row with tokens is a completed call. A value
        // outside that set is not treated as success: it is left for the policy
        // below rather than being credited by default.
        if let finish, Self.completedFinishes.contains(finish) == false {
            return nil
        }
        var event = UsageEvent(
            id: UsageEventID(tool: .openCode, sessionID: row.sessionID, responseID: row.id),
            sessionID: row.sessionID,
            responseID: row.id,
            provider: (object["providerID"] as? String) ?? "opencode",
            model: (object["modelID"] as? String) ?? "unknown",
            // `finish` is recorded as read; its vocabulary is not verified, so it
            // is never used to decide reward here.
            stopReason: finish ?? "completed",
            occurredAtMilliseconds: Int(row.createdAt),
            completedAtMilliseconds: Int(row.updatedAt),
            inputTokens: input,
            outputTokens: output + reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        event.reasoningTokens = reasoning
        event.normalizationVersion = 2
        return event
    }

    private func parse(_ data: String) -> [String: Any]? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }

    /// The shared rule for a token count (`UsageJSONLReader.nonNegativeInt`).
    func intValue(_ value: Any?) -> Int? {
        UsageJSONLReader.nonNegativeInt(value)
    }

    func databaseURL(_ source: UsageSourceRecord) -> URL {
        URL(fileURLWithPath: source.rootPath).appendingPathComponent(Self.databaseName)
    }

    var appendKey: String { "opencode-message-appended" }
    var recheckKey: String { "opencode-message-updated" }
}
