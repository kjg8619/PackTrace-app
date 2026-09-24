import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// OpenCode reading: a read-only database, a composite row cursor, and rows
/// whose tokens only appear after the call finished.
///
/// The test builds its own database with the verified schema; the real one is
/// never opened.
@Suite("OpenCode 사용량 어댑터")
struct OpenCodeUsageAdapterTests {
    struct Fixture {
        var root: URL

        func remove() { try? FileManager.default.removeItem(at: root) }

        var database: URL { root.appendingPathComponent(OpenCodeUsageAdapter.databaseName) }

        /// Creates the message table exactly as the verified schema describes it.
        func createDatabase() throws {
            let db = try SQLiteDatabase(path: database.path)
            defer { db.close() }
            try db.execute("""
            CREATE TABLE message (
                id text PRIMARY KEY,
                session_id text NOT NULL,
                time_created integer NOT NULL,
                time_updated integer NOT NULL,
                data text NOT NULL
            );
            """)
            try db.execute("CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id)")
        }

        /// Writes a message row. `tokens` is omitted when nil, which is what a
        /// message looks like before its call finishes.
        func insert(
            id: String,
            session: String = "session-oc",
            created: Int64,
            updated: Int64? = nil,
            role: String = "assistant",
            input: Int? = nil,
            output: Int? = nil,
            reasoning: Int = 0,
            cacheRead: Int = 0,
            cacheWrite: Int = 0,
            finish: String? = "stop"
        ) throws {
            var object: [String: Any] = ["role": role, "providerID": "fixture-provider", "modelID": "fixture-model"]
            if let input, let output {
                object["tokens"] = [
                    "input": input,
                    "output": output,
                    "reasoning": reasoning,
                    "cache": ["read": cacheRead, "write": cacheWrite],
                    "total": input + output + reasoning + cacheRead + cacheWrite,
                ]
            }
            if let finish { object["finish"] = finish }
            let data = try JSONSerialization.data(withJSONObject: object)
            let json = String(data: data, encoding: .utf8)!

            let db = try SQLiteDatabase(path: database.path)
            defer { db.close() }
            try db.run(
                "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                [
                    .text(id),
                    .text(session),
                    .int(Int(created)),
                    .int(Int(updated ?? created)),
                    .text(json),
                ]
            )
        }

        func touch(id: String, updated: Int64) throws {
            let db = try SQLiteDatabase(path: database.path)
            defer { db.close() }
            try db.run("UPDATE message SET time_updated = ? WHERE id = ?", [.int(Int(updated)), .text(id)])
        }
    }

    static func fixture(_ label: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-opencode-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root)
        try fixture.createDatabase()
        return fixture
    }

    static func source(root: URL) -> UsageSourceRecord {
        UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .openCode, url: root).sourceID,
            realm: .production,
            tool: .openCode,
            rootPath: root.standardizedFileURL.path,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baselineCompletedAt: nil,
            isPaused: false,
            lastScanAt: nil,
            status: .collecting,
            lastReason: nil
        )
    }

    static func request(
        _ source: UsageSourceRecord,
        cursors: [String: UsageCursor] = [:]
    ) -> UsageSliceRequest {
        UsageSliceRequest(
            source: source,
            cursors: cursors,
            budget: UsageScanBudget(),
            isBaselining: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func acceptedTokens(_ output: UsageSliceOutput) -> Int {
        output.entries
            .filter { $0.status == .accepted }
            .compactMap(\.event)
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    static func carry(_ output: UsageSliceOutput) -> [String: UsageCursor] {
        Dictionary(uniqueKeysWithValues: output.cursors.map { ($0.cursorKey, $0) })
    }

    // MARK: - Tests

    @Test("새 assistant 메시지는 한 번 읽고, 캐시는 제외하고 reasoning은 한 번만 센다")
    func readsAssistantOnce() async throws {
        let fixture = try Self.fixture("read")
        defer { fixture.remove() }
        try fixture.insert(id: "msg_1", created: 1_000, input: 500, output: 200, reasoning: 100, cacheRead: 7_000, cacheWrite: 3_000)

        let adapter = OpenCodeUsageAdapter()
        let source = Self.source(root: fixture.root)
        let first = try await adapter.scanSlice(Self.request(source))
        let events = first.entries.compactMap(\.event)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.id.rawValue == "opencode:session-oc:msg_1")
        #expect(event.inputTokens == 500)
        #expect(event.outputTokens == 300, "생성 토큰(output + reasoning)을 한 번만 셉니다")
        #expect(event.reasoningTokens == 100)
        #expect(event.cacheReadTokens == 7_000)
        #expect(event.cacheWriteTokens == 3_000)
        #expect(Self.acceptedTokens(first) == 800)

        // Same rows again: the cursor moves past them and nothing is re-read.
        let second = try await adapter.scanSlice(Self.request(source, cursors: Self.carry(first)))
        #expect(second.entries.isEmpty)
    }

    @Test("같은 시각의 여러 행도 커서가 삼키지 않는다")
    func compositeCursorHandlesSameTimestamp() async throws {
        let fixture = try Self.fixture("cursor")
        defer { fixture.remove() }
        for index in 1...3 {
            try fixture.insert(id: "msg_\(index)", created: 5_000, input: 100 * index, output: 10)
        }

        let adapter = OpenCodeUsageAdapter()
        let source = Self.source(root: fixture.root)
        let small = UsageSliceRequest(
            source: source,
            budget: UsageScanBudget(maxRows: 2),
            isBaselining: false,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let first = try await adapter.scanSlice(small)
        #expect(first.entries.compactMap(\.event).count == 2)
        #expect(first.moreWork)

        let second = try await adapter.scanSlice(Self.request(source, cursors: Self.carry(first)))
        let secondEvents = second.entries.compactMap(\.event)
        #expect(secondEvents.count == 1, "같은 시각이라도 남은 행을 읽습니다")
        #expect(secondEvents.first?.responseID == "msg_3")
    }

    @Test("나중에 토큰이 채워진 행은 갱신 재확인으로 한 번만 적립된다")
    func lateTokensArePickedUpOnce() async throws {
        let fixture = try Self.fixture("late")
        defer { fixture.remove() }
        // A message that exists before its call finished: no tokens yet.
        try fixture.insert(id: "msg_pending", created: 1_000, input: nil, output: nil, finish: nil)

        let adapter = OpenCodeUsageAdapter()
        let source = Self.source(root: fixture.root)
        let first = try await adapter.scanSlice(Self.request(source))
        #expect(first.entries.isEmpty, "토큰이 없으면 지급할 것이 없습니다")

        // The call finishes: the same row is rewritten with tokens.
        try fixture.insert(id: "msg_pending", created: 1_000, input: 4_000, output: 1_000, finish: "stop")
        try fixture.touch(id: "msg_pending", updated: 9_999)
        let second = try await adapter.scanSlice(Self.request(source, cursors: Self.carry(first)))
        #expect(Self.acceptedTokens(second) == 5_000)
        #expect(second.entries.compactMap(\.event).count == 1)
        #expect(Self.carry(second)[adapter.recheckKey]?.payload == "9999|msg_pending", "recheck cursor: \(Self.carry(second).mapValues(\.payload))")

        // The recheck cursor moved past that row, so the next pass reads nothing
        // at all rather than re-sending a call that is already recorded.
        let third = try await adapter.scanSlice(Self.request(source, cursors: Self.carry(second)))
        #expect(third.entries.isEmpty)
    }

    @Test("user 메시지와 토큰 없는 메시지는 지급 대상이 아니다")
    func onlyAssistantTokensCount() async throws {
        let fixture = try Self.fixture("roles")
        defer { fixture.remove() }
        try fixture.insert(id: "msg_user", created: 1_000, role: "user", input: 5_000, output: 5_000)
        try fixture.insert(id: "msg_summary", created: 1_001, role: "assistant", input: nil, output: nil)
        try fixture.insert(id: "msg_real", created: 1_002, input: 300, output: 200)

        let adapter = OpenCodeUsageAdapter()
        let source = Self.source(root: fixture.root)
        let first = try await adapter.scanSlice(Self.request(source))
        #expect(first.entries.compactMap(\.event).map(\.responseID) == ["msg_real"])
        #expect(Self.acceptedTokens(first) == 500)
    }

    @Test("갱신 재확인 경로가 남아 있으면 기준선이 끝났다고 표시하지 않는다")
    func baselineStaysOpenUntilBothWalksAreDrained() async throws {
        let fixture = try Self.fixture("drain")
        defer { fixture.remove() }
        // More rows than one slice can hold, all with an update time, so both the
        // append walk and the update walk are truncated.
        for index in 1...6 {
            try fixture.insert(id: "msg_\(index)", created: Int64(index * 1_000), input: 100, output: 100)
        }

        let adapter = OpenCodeUsageAdapter()
        let source = Self.source(root: fixture.root)
        let small = UsageSliceRequest(
            source: source,
            budget: UsageScanBudget(maxRows: 2),
            isBaselining: true,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var cursors: [String: UsageCursor] = [:]
        var rounds = 0
        while rounds < 10 {
            rounds += 1
            let output = try await adapter.scanSlice(
                UsageSliceRequest(
                    source: source,
                    cursors: cursors,
                    budget: UsageScanBudget(maxRows: 2),
                    isBaselining: true,
                    now: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
            cursors = Self.carry(output)
            if output.moreWork == false { break }
        }
        // Draining the whole table takes several rounds: six rows with a budget of
        // two cannot be finished in one or two passes.
        #expect(rounds >= 2, "두 경로 중 하나만 끝나도 기준선이 끝난 것으로 보면 안 됩니다")

        let drained = try await adapter.scanSlice(
            UsageSliceRequest(
                source: source,
                cursors: cursors,
                budget: UsageScanBudget(maxRows: 2),
                isBaselining: true,
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )
        #expect(drained.entries.isEmpty, "모두 읽은 뒤에는 새 기록이 없습니다")
        #expect(drained.moreWork == false)
    }

    @Test("읽기 전용으로 열고, 스키마가 다르면 지원하지 않는다고 표시한다")
    func inspectionAndReadOnlyOpen() throws {
        let fixture = try Self.fixture("inspect")
        defer { fixture.remove() }
        let adapter = OpenCodeUsageAdapter()

        // No rows yet: recognised but empty.
        #expect(adapter.inspect(source: Self.source(root: fixture.root)).support == .empty)

        // A different schema is reported as unsupported rather than read blindly.
        let other = try Self.fixture("other")
        defer { other.remove() }
        let db = try SQLiteDatabase(path: other.database.path)
        try db.execute("DROP TABLE message")
        try db.execute("CREATE TABLE message (id text PRIMARY KEY, payload text)")
        db.close()
        #expect(adapter.inspect(source: Self.source(root: other.root)).support == .unsupportedVersion)

        // The adapter's connection cannot write: the database file is unchanged
        // by a read, and the original stays the writer's business.
        try fixture.insert(id: "msg_x", created: 10, input: 10, output: 10)
        let before = try Data(contentsOf: fixture.database)
        let output = try adapter.inspect(source: Self.source(root: fixture.root))
        #expect(output.support == .supported)
        #expect(output.excluded.contains { $0.contains("cache read/write") })
        #expect(try Data(contentsOf: fixture.database) == before)
    }
}
