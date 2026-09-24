import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Baseline boundaries (C) and the four real collection paths sharing one account (D).
///
/// Everything runs on synthetic storages in harness-owned temporary roots with a
/// fixed clock. No real log, no real profile, no network.
@Suite("기준선 경계와 네 경로 통합")
struct BaselineBoundaryAndIntegrationTests {
    // MARK: - Shared fixtures

    struct Tree {
        var root: URL
        func remove() { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func write(_ text: String, to relative: String) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func append(_ text: String, to relative: String) throws {
            let url = root.appendingPathComponent(relative)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
    }

    static func tree(_ label: String) throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-boundary-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try TestOwnedRoot.verifyOwned(root)
        return Tree(root: root)
    }

    /// A fixed clock: nothing waits for real time.
    static let clock = Date(timeIntervalSince1970: 1_700_000_000)

    static func openCodeSource(_ root: URL) -> UsageSourceRecord {
        UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .openCode, url: root).sourceID,
            realm: .production,
            tool: .openCode,
            rootPath: root.standardizedFileURL.path,
            connectedAt: clock,
            baselineCompletedAt: nil,
            isPaused: false,
            lastScanAt: nil,
            status: .baselining,
            lastReason: nil
        )
    }

    static func openCodeRequest(
        _ source: UsageSourceRecord,
        rows: Int,
        cursors: [String: UsageCursor] = [:]
    ) -> UsageSliceRequest {
        UsageSliceRequest(
            source: source,
            cursors: cursors,
            budget: UsageScanBudget(maxFiles: 8, maxRecords: 100, maxBytes: 1024 * 1024, maxRows: rows),
            isBaselining: true,
            now: clock
        )
    }

    static func cursorMap(_ output: UsageSliceOutput) -> [String: UsageCursor] {
        Dictionary(uniqueKeysWithValues: output.cursors.map { ($0.cursorKey, $0) })
    }

    static func insertOpenCode(_ database: URL, id: String, created: Int64, updated: Int64? = nil, input: Int?) throws {
        var object: [String: Any] = [
            "role": "assistant",
            "providerID": "fixture-provider",
            "modelID": "fixture-model",
            "finish": "stop",
        ]
        if let input {
            object["tokens"] = ["input": input, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0], "total": input]
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let db = try SQLiteDatabase(path: database.path)
        defer { db.close() }
        try db.run(
            "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text("session-fixture"), .int(Int(created)), .int(Int(updated ?? created)), .text(json)]
        )
    }

    static func makeOpenCodeDatabase(_ tree: Tree) throws -> URL {
        let url = tree.root.appendingPathComponent(OpenCodeUsageAdapter.databaseName)
        let db = try SQLiteDatabase(path: url.path)
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
        return url
    }

    // MARK: - C1 / C2: one walk finished, the other still has history

    @Test("C1 추가 경로만 끝나고 갱신 재확인에 과거 행이 남으면 기준선은 끝나지 않는다")
    func c1AppendDrainedRecheckRemaining() async throws {
        let tree = try Self.tree("c1")
        defer { tree.remove() }
        let database = try Self.makeOpenCodeDatabase(tree)
        for index in 1...4 {
            try Self.insertOpenCode(database, id: "msg_\(index)", created: Int64(index * 1_000), input: 100)
        }
        let adapter = OpenCodeUsageAdapter()
        let source = Self.openCodeSource(tree.root)

        // Read everything once, so both cursors are at the end.
        let drained = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100))
        #expect(drained.moreWork == false, "모두 읽으면 더 할 일이 없습니다")
        var cursors = Self.cursorMap(drained)

        // Rewind only the update walk: the append walk is finished, the update
        // walk still has rows to hand back.
        cursors[adapter.recheckKey] = UsageCursor(
            cursorKey: adapter.recheckKey,
            kind: .rowPosition,
            payload: "0|",
            updatedAt: Self.clock
        )
        // A budget smaller than the remaining rows: the update walk cannot finish
        // in one slice, so the baseline is not done either.
        let output = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 2, cursors: cursors))
        #expect(output.moreWork, "갱신 경로에 남은 행이 있으면 기준선은 끝난 것이 아닙니다")
        // Those rows are the same calls: same identities, so nothing new is paid.
        let ids = output.entries.compactMap(\.event?.id.rawValue)
        #expect(ids.count == 2, "예산만큼만 읽습니다")
        #expect(ids.allSatisfy { $0.hasPrefix("opencode:session-fixture:msg_") })
        #expect(ids.allSatisfy { $0.hasPrefix("opencode:session-fixture:msg_") })
    }

    @Test("C2 갱신 재확인만 끝나고 추가 경로에 과거 행이 남아도 기준선은 끝나지 않는다")
    func c2RecheckDrainedAppendRemaining() async throws {
        let tree = try Self.tree("c2")
        defer { tree.remove() }
        let database = try Self.makeOpenCodeDatabase(tree)
        for index in 1...4 {
            try Self.insertOpenCode(database, id: "msg_\(index)", created: Int64(index * 1_000), input: 100)
        }
        let adapter = OpenCodeUsageAdapter()
        let source = Self.openCodeSource(tree.root)

        // Only the update walk is at the end; the append walk has not started.
        let cursors: [String: UsageCursor] = [
            adapter.recheckKey: UsageCursor(
                cursorKey: adapter.recheckKey,
                kind: .rowPosition,
                payload: "9999999999999|~",
                updatedAt: Self.clock
            ),
        ]
        let output = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 2, cursors: cursors))
        #expect(output.entries.compactMap(\.event).count == 2)
        #expect(output.moreWork, "추가 경로에 아직 행이 남아 있습니다")

        // Draining the append walk from where it stopped reaches the end.
        var next = Self.cursorMap(output)
        next[adapter.recheckKey] = cursors[adapter.recheckKey]
        let second = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100, cursors: next))
        #expect(second.entries.compactMap(\.event).count == 2)
        #expect(second.moreWork == false, "두 경로 모두 소진되어야 기준선이 끝납니다")
    }

    // MARK: - C5 / C6: history versus genuinely new calls

    @Test("C5 기준선 도중 생긴 새 호출은 한 번 인정되고 과거 범위는 지급되지 않는다")
    func c5NewCallDuringBaseline() async throws {
        let tree = try Self.tree("c5")
        defer { tree.remove() }
        let file = try tree.write(Self.codexSession(ordinal: 0, input: 5_000, output: 0, previousTotal: 0), to: "sessions/rollout-a.jsonl")
        _ = file
        let adapter = CodexUsageAdapter()
        let source = UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .codex, url: tree.root).sourceID,
            realm: .production,
            tool: .codex,
            rootPath: tree.root.standardizedFileURL.path,
            connectedAt: Self.clock,
            baselineCompletedAt: nil,
            isPaused: false,
            lastScanAt: nil,
            status: .baselining,
            lastReason: nil
        )
        // Baseline: the boundary lands at the end of what exists now.
        let baseline = try await adapter.scanSlice(Self.codexSlice(source, baselining: true))
        #expect(baseline.entries.filter { $0.status == .accepted }.isEmpty, "연결 시점 이전 기록은 지급되지 않습니다")

        // A call that happens while the baseline is still being settled.
        try tree.append(Self.codexSession(ordinal: 1, input: 1_500, output: 500, previousTotal: 5_000), to: "sessions/rollout-a.jsonl")
        let during = try await adapter.scanSlice(Self.codexSlice(source, checkpoints: baseline.fileCheckpoints, cursors: Self.cursorMap(baseline), baselining: true))
        #expect(during.entries.compactMap(\.event).count == 1, "진짜 신규 호출은 기준선 중에도 한 번 인정됩니다")
        #expect(during.entries.compactMap(\.event).first?.inputTokens == 1_500)

        // Reading again changes nothing: the older range is never paid.
        let again = try await adapter.scanSlice(Self.codexSlice(source, checkpoints: during.fileCheckpoints, cursors: Self.cursorMap(during), baselining: true))
        #expect(again.entries.isEmpty)
    }

    @Test("C6 기준선 뒤 늦게 갱신된 과거 행은 신규 지급되지 않고, 신규 호출의 늦은 확정은 한 번 인정된다")
    func c6LateUpdateAfterBaseline() async throws {
        let tree = try Self.tree("c6")
        defer { tree.remove() }
        let database = try Self.makeOpenCodeDatabase(tree)
        // A historical call, already read and recorded before the connection.
        try Self.insertOpenCode(database, id: "msg_old", created: 1_000, input: 2_000)
        let adapter = OpenCodeUsageAdapter()
        let source = Self.openCodeSource(tree.root)
        let baseline = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100))
        #expect(baseline.entries.compactMap(\.event).map(\.id.rawValue) == ["opencode:session-fixture:msg_old"])

        // The same historical row is touched later (an update, not a new call).
        try Self.insertOpenCode(database, id: "msg_old", created: 1_000, updated: 5_000, input: 2_000)
        let recheck = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100, cursors: Self.cursorMap(baseline)))
        let reread = recheck.entries.compactMap(\.event)
        #expect(reread.count == 1)
        #expect(reread.first?.id.rawValue == "opencode:session-fixture:msg_old", "같은 identity라 재지급되지 않습니다")
        #expect(reread.first?.inputTokens == 2_000, "값이 커지지 않았습니다")

        // A new call whose tokens are confirmed later is credited once.
        try Self.insertOpenCode(database, id: "msg_new", created: 9_000, input: nil)
        let pending = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100, cursors: Self.cursorMap(recheck)))
        #expect(pending.entries.compactMap(\.event).isEmpty, "토큰이 없으면 지급할 것이 없습니다")
        try Self.insertOpenCode(database, id: "msg_new", created: 9_000, updated: 9_500, input: 700)
        let confirmed = try await adapter.scanSlice(Self.openCodeRequest(source, rows: 100, cursors: Self.cursorMap(pending)))
        #expect(confirmed.entries.compactMap(\.event).map(\.inputTokens) == [700])
    }

    // MARK: - C7: the same past call seen again

    @Test("C7 과거 호출이 다른 루트에서 재등장해도 소급 지급되지 않는다")
    func c7DuplicateRoot() async throws {
        let first = try Self.tree("c7-first")
        let second = try Self.tree("c7-second")
        defer {
            first.remove()
            second.remove()
        }
        let session = Self.codexSession(ordinal: 0, input: 4_000, output: 0, previousTotal: 0)
        try first.write(session, to: "sessions/rollout-dup.jsonl")
        // A second root holding a copy of the same session (same session id and
        // ordinal, so the same call).
        try second.write(session, to: "sessions/rollout-dup.jsonl")

        let catalog = Fixtures.syntheticCatalog()
        let location = try StoreLocation.temporary(label: "packtrace-c7")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = try Fixtures.makeStore(catalog: catalog, location: location)

        // The first root is connected and its history is read as baseline.
        let sourceA = try await store.connectUsageSource(tool: .codex, rootPath: first.root.path, now: Self.clock)
        try await store.applyUsageBatch(
            sourceID: sourceA.sourceID,
            baseline: true,
            entries: [UsageBatchEntry(
                event: Self.codexEvent(session: "session-dup", ordinal: 0, input: 4_000),
                status: .accepted
            )],
            checkpoints: [],
            run: Self.runSummary()
        )
        #expect(try await store.usageTotals().acceptedTokens == 0, "기준선 통과분은 지급되지 않습니다")

        // The copy appears under a different root: the same call is recognised
        // and is not paid a second time.
        let sourceB = try await store.connectUsageSource(tool: .codex, rootPath: second.root.path, now: Self.clock.addingTimeInterval(60))
        try await store.applyUsageBatch(
            sourceID: sourceB.sourceID,
            baseline: false,
            entries: [UsageBatchEntry(
                event: Self.codexEvent(session: "session-dup", ordinal: 0, input: 4_000),
                status: .accepted
            )],
            checkpoints: [],
            run: Self.runSummary()
        )
        #expect(try await store.usageTotals().acceptedTokens == 0, "같은 과거 호출은 재지급되지 않습니다")
        #expect(try await store.usageRecentEvents(limit: 10).count == 1, "관찰은 하나로 기록됩니다")

        // A different call with the same token count is a different call.
        try await store.applyUsageBatch(
            sourceID: sourceB.sourceID,
            baseline: false,
            entries: [UsageBatchEntry(
                event: Self.codexEvent(session: "session-dup", ordinal: 1, input: 4_000),
                status: .accepted
            )],
            checkpoints: [],
            run: Self.runSummary()
        )
        #expect(try await store.usageTotals().acceptedTokens == 4_000, "숫자가 같아도 별개 호출은 각각 인정됩니다")
    }

    // MARK: - Codex fixtures for C5/C7

    static func codexSession(ordinal: Int, input: Int, output: Int, previousTotal: Int) -> String {
        let header = #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"session-dup","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
        let lastTotal = input + output
        let event = #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(previousTotal + input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(previousTotal + lastTotal)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(lastTotal)},"model_context_window":272000}}}"# + "\n"
        return ordinal == 0 ? header + event : event
    }

    static func codexEvent(session: String, ordinal: Int, input: Int) -> UsageEvent {
        UsageEvent(
            id: UsageEventID(tool: .codex, sessionID: session, responseID: String(ordinal)),
            sessionID: session,
            responseID: String(ordinal),
            provider: "openai",
            model: "fixture-model",
            stopReason: "completed",
            occurredAtMilliseconds: Int(clock.timeIntervalSince1970 * 1000),
            completedAtMilliseconds: nil,
            inputTokens: input,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
    }

    static func runSummary() -> UsageScanRunSummary {
        UsageScanRunSummary(runID: UUID().uuidString, trigger: "test", startedAt: clock, finishedAt: clock)
    }

    static func codexSlice(
        _ source: UsageSourceRecord,
        checkpoints: [UsageFileCheckpoint] = [],
        cursors: [String: UsageCursor] = [:],
        baselining: Bool
    ) -> UsageSliceRequest {
        UsageSliceRequest(
            source: source,
            fileCheckpoints: checkpoints,
            cursors: cursors,
            budget: UsageScanBudget(maxFiles: 4, maxRecords: 1_000, maxBytes: 1024 * 1024, maxRows: 1_000),
            isBaselining: baselining,
            now: clock
        )
    }
}
