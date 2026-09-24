import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// The four real collection paths sharing one reward account.
///
/// Each tool contributes through the code the app actually runs — the OMP
/// collector for OMP, the adapters and coordinator for the other three — into a
/// single temporary production profile. Nothing is summed into the store
/// directly, and each tool's own contribution is asserted, so one tool being
/// wrong cannot be hidden by the total.
@Suite("네 입력 경로 공통 계정 통합", .serialized)
struct FourPathIntegrationTests {
    /// A fixed clock: the fixture timestamps, the connection time and the
    /// coordinator all use the same instant, and nothing waits for real time.
    static let clock = Date(timeIntervalSince1970: 1_800_000_000)

    struct Paths {
        var codex: URL
        var claude: URL
        var opencode: URL
        var omp: URL
    }

    static func makePaths(_ tree: URL) throws -> Paths {
        let paths = Paths(
            codex: tree.appendingPathComponent("codex", isDirectory: true),
            claude: tree.appendingPathComponent("claude", isDirectory: true),
            opencode: tree.appendingPathComponent("opencode", isDirectory: true),
            omp: tree.appendingPathComponent("omp", isDirectory: true)
        )
        for path in [paths.codex, paths.claude, paths.opencode, paths.omp] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        return paths
    }

    // MARK: - Fixture writers (baseline, then a new call)

    static func appendCodexNew(_ root: URL, session: String, previousTotal: Int, newInput: Int) throws {
        let file = root.appendingPathComponent("2026/09/23").appendingPathComponent("rollout-\(session).jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(codexCall(ordinal: 1, previousTotal: previousTotal, input: newInput).utf8))
        try handle.close()
    }

    static func writeCodex(_ root: URL, session: String, baselineInput: Int) throws {
        let directory = root.appendingPathComponent("2026/09/23", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-\(session).jsonl")
        var lines = #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(session)","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
        lines += codexCall(ordinal: 0, previousTotal: 0, input: baselineInput)
        try lines.write(to: file, atomically: true, encoding: .utf8)
    }

    static func codexCall(ordinal: Int, previousTotal: Int, input: Int) -> String {
        let total = previousTotal + input
        return #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(input)},"model_context_window":272000}}}"# + "\n"
    }

    static func appendClaudeNew(_ root: URL, newInput: Int) throws {
        let file = root.appendingPathComponent("project-fixture").appendingPathComponent("session-fixture.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(claudeRecord(requestID: "new", input: newInput).utf8))
        try handle.close()
    }

    static func writeClaude(_ root: URL, baselineInput: Int) throws {
        let directory = root.appendingPathComponent("project-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session-fixture.jsonl")
        try claudeRecord(requestID: "baseline", input: baselineInput)
            .write(to: file, atomically: true, encoding: .utf8)
    }

    static func claudeRecord(requestID: String, input: Int) -> String {
        #"{"type":"assistant","uuid":"u-\#(requestID)","sessionId":"claude-fixture","isSidechain":false,"timestamp":"2026-09-23T01:00:00.000Z","requestId":"\#(requestID)","message":{"id":"\#(requestID)","model":"claude-fixture","stop_reason":"end_turn","usage":{"input_tokens":\#(input),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"# + "\n"
    }

    static func appendOpenCodeNew(_ root: URL, newInput: Int) throws {
        let db = try SQLiteDatabase(path: root.appendingPathComponent(OpenCodeUsageAdapter.databaseName).path)
        defer { db.close() }
        try insertOpenCode(db, id: "msg-new", created: 2_000, input: newInput)
    }

    static func writeOpenCode(_ root: URL, baselineInput: Int) throws {
        let database = root.appendingPathComponent(OpenCodeUsageAdapter.databaseName)
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
        try insertOpenCode(db, id: "msg-baseline", created: 1_000, input: baselineInput)
    }

    static func insertOpenCode(_ db: SQLiteDatabase, id: String, created: Int64, input: Int) throws {
        let object: [String: Any] = [
            "role": "assistant",
            "providerID": "opencode",
            "modelID": "fixture-model",
            "finish": "stop",
            "tokens": ["input": input, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0], "total": input],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        try db.run(
            "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text("opencode-fixture"), .int(Int(created)), .int(Int(created)), .text(json)]
        )
    }

    // MARK: - The test

    static func runIntegration(order: [UsageToolKind], label: String) async throws -> (perTool: [UsageToolKind: Int], points: Int, remainder: Int, accepted: Int, balance: Int) {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let store = harness.store
        let tree = harness.tree.root
        let paths = try makePaths(tree)

        // Every tool's storage, written so that exactly one call is history and
        // one happens after the connection.
        try writeCodex(paths.codex, session: "codex-\(label)", baselineInput: 5_000)
        try writeClaude(paths.claude, baselineInput: 4_000)
        try writeOpenCode(paths.opencode, baselineInput: 3_000)
        // OMP: a synthetic session in the verified format, read by its collector.
        let ompRelative = "project-fixture/session-omp.jsonl"
        let ompFile = paths.omp.appendingPathComponent(ompRelative)
        try FileManager.default.createDirectory(at: ompFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The history that exists at connect time, plus nothing else yet.
        try (UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 9_000, output: 0, offset: 1)])
            + "\n").write(to: ompFile, atomically: true, encoding: .utf8)

        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry([CodexUsageAdapter(), ClaudeCodeUsageAdapter(), OpenCodeUsageAdapter()]),
            clock: { Self.clock }
        )

        // Baselines first, in the requested order, then the new calls.
        for tool in order {
            switch tool {
            case .omp:
                // The OMP collector fixes its boundary the same way: the history
                // that is already there is not credited.
                _ = try await harness.collector.connect(root: paths.omp)
            case .codex:
                _ = try await coordinator.connect(tool: .codex, rootPath: paths.codex)
            case .claudeCode:
                _ = try await coordinator.connect(tool: .claudeCode, rootPath: paths.claude)
            case .openCode:
                _ = try await coordinator.connect(tool: .openCode, rootPath: paths.opencode)
            default:
                Issue.record("이 테스트는 네 경로만 다룹니다: \(tool)")
            }
        }
        #expect(try await store.usageTotals().acceptedTokens == 0, "기준선만으로는 적립되지 않습니다")

        // The new calls happen after every baseline is fixed, one per tool, in
        // the same order as the connections.
        for tool in order {
            switch tool {
            case .omp:
                let handle = try FileHandle(forWritingTo: ompFile)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((UsageTestSupport.record(2, input: 6_000, output: 0, offset: 2) + "\n").utf8))
                try handle.close()
            case .codex:
                try appendCodexNew(paths.codex, session: "codex-\(label)", previousTotal: 5_000, newInput: 2_000)
            case .claudeCode:
                try appendClaudeNew(paths.claude, newInput: 1_000)
            case .openCode:
                try appendOpenCodeNew(paths.opencode, newInput: 1_000)
            default:
                Issue.record("이 테스트는 네 경로만 다룹니다: \(tool)")
            }
        }

        for _ in 0..<4 {
            _ = try await harness.drain(maxSlices: 6)
            _ = try await coordinator.scan(trigger: .manual)
        }
        // Diagnostics for the failure being investigated: per-source state and
        // where reading got to, without dumping any record content.
        for status in try await coordinator.status() {
            print("  [\(label)] source \(status.source.tool.rawValue) status=\(status.source.status.rawValue) reason=\(status.source.lastReason ?? "-") baseline=\(status.source.baselineCompletedAt != nil) accepted=\(status.acceptedTokens)")
        }
        for row in try await store.allUsageSourceRows() {
            print("  [\(label)] row \(row.tool.rawValue) path=\(UsageSourceIdentity.mask(row.rootPath)) paused=\(row.isPaused) status=\(row.status.rawValue) reason=\(row.lastReason ?? "-")")
        }
        let checkpoints = try await store.usageCheckpoints()
        print("  [\(label)] checkpoints=\(checkpoints.count) ok=\(checkpoints.filter { $0.status == .ok }.count)")
        for event in try await store.usageRecentEvents(limit: 12) {
            let tool = event.id.split(separator: ":").first.map(String.init) ?? "?"
            print("  [\(label)] event tool=\(tool) provider=\(event.provider) input=\(event.inputTokens) output=\(event.outputTokens)")
        }

        // A second pass over every path must not add anything.
        let afterFirst = try await store.usageTotals()
        _ = try await harness.drain(maxSlices: 6)
        _ = try await coordinator.scan(trigger: .manual)
        let afterRescan = try await store.usageTotals()

        // Restart the store and rescan: same result.
        let reopened = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog(), location: harness.location)
        let reopenedCoordinator = UsageCoordinator(
            store: reopened,
            registry: UsageAdapterRegistry([CodexUsageAdapter(), ClaudeCodeUsageAdapter(), OpenCodeUsageAdapter()]),
            clock: { Self.clock }
        )
        _ = try await reopenedCoordinator.scan(trigger: .manual)
        let afterRestart = try await reopened.usageTotals()
        #expect(afterRescan.acceptedTokens == afterFirst.acceptedTokens)
        #expect(afterRestart.acceptedTokens == afterFirst.acceptedTokens)
        #expect(afterRestart.awardedPoints == afterFirst.awardedPoints)
        #expect(afterRestart.remainderTokens == afterFirst.remainderTokens)

        let perTool = try await reopened.usageToolTotals()
        let map = Dictionary(uniqueKeysWithValues: perTool.map { ($0.tool, $0.acceptedTokens) })
        let balance = try await reopened.balance()
        return (
            perTool: map,
            points: afterFirst.awardedPoints,
            remainder: afterFirst.remainderTokens,
            accepted: afterFirst.acceptedTokens,
            balance: balance
        )
    }

    @Test("순서 A: OMP → Codex → Claude Code → OpenCode")
    func orderA() async throws {
        let result = try await Self.runIntegration(order: [.omp, .codex, .claudeCode, .openCode], label: "a")
        print("order A accepted=\(result.accepted) points=\(result.points) remainder=\(result.remainder) balance=\(result.balance) perTool=\(result.perTool)")
        #expect(result.perTool[.codex] == 2_000, "Codex 기여분")
        #expect(result.perTool[.claudeCode] == 1_000, "Claude Code 기여분")
        #expect(result.perTool[.openCode] == 1_000, "OpenCode 기여분")
        #expect(result.accepted == 10_000, "OMP 6,000 + 나머지 4,000")
        #expect(result.points == 1)
        #expect(result.remainder == 0)
        #expect(result.balance == 1, "구매 없는 임시 지갑 잔액")
    }

    @Test("순서 B: OpenCode → Claude Code → Codex → OMP")
    func orderB() async throws {
        let result = try await Self.runIntegration(order: [.openCode, .claudeCode, .codex, .omp], label: "b")
        print("order B accepted=\(result.accepted) points=\(result.points) remainder=\(result.remainder) balance=\(result.balance) perTool=\(result.perTool)")
        #expect(result.perTool[.codex] == 2_000)
        #expect(result.perTool[.claudeCode] == 1_000)
        #expect(result.perTool[.openCode] == 1_000)
        #expect(result.accepted == 10_000)
        #expect(result.points == 1)
        #expect(result.remainder == 0)
        #expect(result.balance == 1)
    }
}
