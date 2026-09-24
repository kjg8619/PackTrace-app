import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Claude Code transcript reading: only confirmed assistant usage counts; a
/// subagent's own calls count, and a copy of a parent call counts once.
///
/// Synthetic transcripts only; no real session file is read.
@Suite("Claude Code 사용량 어댑터")
struct ClaudeCodeUsageAdapterTests {
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
            .appendingPathComponent("packtrace-claude-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Tree(root: root)
    }

    static let relative = "project-fixture/session-fixture.jsonl"

    static func assistant(
        requestID: String? = "req_fixture",
        messageID: String = "msg_fixture",
        sessionID: String = "session-fixture",
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheCreation: Int = 0,
        thinking: Int? = nil,
        sidechain: Bool = false,
        model: String = "claude-fixture",
        stopReason: String = "end_turn",
        timestamp: String = "2026-09-23T00:00:01.000Z"
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_input_tokens": cacheRead,
            "cache_creation_input_tokens": cacheCreation,
        ]
        if let thinking { usage["output_tokens_details"] = ["thinking_tokens": thinking] }
        var message: [String: Any] = ["id": messageID, "model": model, "stop_reason": stopReason, "usage": usage]
        var record: [String: Any] = [
            "type": "assistant",
            "uuid": "uuid-\(messageID)",
            "parentUuid": NSNull(),
            "sessionId": sessionID,
            "isSidechain": sidechain,
            "timestamp": timestamp,
            "message": message,
        ]
        if let requestID { record["requestId"] = requestID }
        message = record
        let data = try! JSONSerialization.data(withJSONObject: [record], options: [])
        // One record per line, without the array wrapper.
        let text = String(data: data, encoding: .utf8)!
        return String(text.dropFirst().dropLast()) + "\n"
    }

    static func other(type: String) -> String {
        #"{"type":"\#(type)","sessionId":"session-fixture","timestamp":"2026-09-23T00:00:00.000Z"}"# + "\n"
    }

    static func source(root: URL) -> UsageSourceRecord {
        UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .claudeCode, url: root).sourceID,
            realm: .production,
            tool: .claudeCode,
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
        checkpoints: [UsageFileCheckpoint] = [],
        baselining: Bool = false
    ) -> UsageSliceRequest {
        UsageSliceRequest(
            source: source,
            fileCheckpoints: checkpoints,
            budget: UsageScanBudget(),
            isBaselining: baselining,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    static func acceptedTokens(_ output: UsageSliceOutput) -> Int {
        output.entries
            .filter { $0.status == .accepted }
            .compactMap(\.event)
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    // MARK: - Tests

    @Test("연결 이전 기록은 기준선이고, 그 뒤 확정 assistant usage만 인정한다")
    func baselineThenConfirmedUsage() async throws {
        let tree = try Self.tree("baseline")
        defer { tree.remove() }
        try tree.write(Self.other(type: "summary") + Self.assistant(input: 20_000, output: 4_000, cacheRead: 15_000), to: Self.relative)

        let adapter = ClaudeCodeUsageAdapter()
        let source = Self.source(root: tree.root)
        let baseline = try await adapter.scanSlice(Self.request(source, baselining: true))
        #expect(baseline.entries.filter { $0.status == .accepted }.isEmpty)
        #expect(baseline.fileCheckpoints.count == 1)

        try tree.append(
            Self.other(type: "user")
                + Self.assistant(requestID: "req_new", messageID: "msg_new", input: 1_200, output: 800, cacheRead: 9_000, cacheCreation: 3_000, thinking: 500)
        , to: Self.relative)
        let second = try await adapter.scanSlice(Self.request(source, checkpoints: baseline.fileCheckpoints))

        let events = second.entries.compactMap(\.event)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.id.rawValue == "claude-code:session-fixture:req_new")
        #expect(event.inputTokens == 1_200, "input_tokens는 이미 비캐시 입력입니다")
        #expect(event.outputTokens == 800)
        #expect(event.cacheReadTokens == 9_000)
        #expect(event.cacheWriteTokens == 3_000)
        #expect(event.reasoningTokens == 500)
        #expect(Self.acceptedTokens(second) == 2_000, "cache와 thinking은 인정량에 들어가지 않습니다")
    }

    @Test("서브에이전트 호출도 인정하고, 부모 호출의 복사본은 같은 호출로 본다")
    func subagentCallsCount() async throws {
        let tree = try Self.tree("sidechain")
        defer { tree.remove() }
        try tree.write(Self.other(type: "summary"), to: Self.relative)

        let adapter = ClaudeCodeUsageAdapter()
        let source = Self.source(root: tree.root)
        let baseline = try await adapter.scanSlice(Self.request(source, baselining: true))

        try tree.append(
            Self.assistant(requestID: "req_sub", messageID: "msg_sub", input: 5_000, output: 1_000, sidechain: true)
                + Self.assistant(requestID: "req_main", input: 900, output: 100)
        , to: Self.relative)
        let second = try await adapter.scanSlice(Self.request(source, checkpoints: baseline.fileCheckpoints))

        #expect(!second.entries.contains { $0.reason == .subagentExcluded })
        #expect(Self.acceptedTokens(second) == 7_000)
        let events = second.entries.compactMap(\.event)
        #expect(events.map(\.responseID) == ["req_sub", "req_main"])
        // A copy of the parent's call inside a subagent transcript is the same
        // event (same session and request id), so the store keeps one.
        let copy = try #require(events.last)
        #expect(copy.id == UsageEventID(tool: .claudeCode, sessionID: "session-fixture", responseID: "req_main"))
    }

    @Test("서브에이전트 파일의 호출은 따로 적립되고, 복사된 부모 호출은 한 번만 적립된다")
    func subagentFilesThroughTheStore() async throws {
        let base = try UsageCoordinatorTests.tree("claude-subagents")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("claude/projects", isDirectory: true)
        let parent = root.appendingPathComponent("-project-/session-fixture.jsonl")
        try UsageCoordinatorTests.write(Self.other(type: "summary"), to: parent)

        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(store: store, registry: UsageAdapterRegistry([ClaudeCodeUsageAdapter()]))
        _ = try await coordinator.connect(tool: .claudeCode, rootPath: root)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func at(_ seconds: Double) -> String { formatter.string(from: Date().addingTimeInterval(60 + seconds)) }
        let parentCall = Self.assistant(requestID: "req_parent", messageID: "msg_parent", input: 1_000, output: 500, timestamp: at(0))
        try UsageCoordinatorTests.append(parentCall, to: parent)
        // The subagent transcript, created after the connection: a copy of the
        // parent's call (a forked subagent starts from it), then its own call.
        let subagent = root.appendingPathComponent("-project-/session-fixture/subagents/agent-a1.jsonl")
        let copied = Self.assistant(requestID: "req_parent", messageID: "msg_parent", input: 1_000, output: 500, sidechain: true, timestamp: at(0))
        let own = Self.assistant(requestID: "req_sub", messageID: "msg_sub", input: 3_000, output: 2_000, sidechain: true, timestamp: at(5))
        try UsageCoordinatorTests.write(copied + own, to: subagent)

        for _ in 0..<3 { _ = try await coordinator.scan(trigger: .manual) }
        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 1_500 + 5_000, "부모 호출 1,500 + 서브에이전트 호출 5,000, 복사본은 한 번")
        let tools = try await store.usageToolTotals()
        #expect(tools.first { $0.tool == .claudeCode }?.acceptedEvents == 2)
    }

    @Test("오늘 도구별 요약은 인정분과 캐시 토큰을 나눠 보여 준다")
    func dayByToolKeepsCacheApart() async throws {
        let base = try UsageCoordinatorTests.tree("claude-day-by-tool")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("claude/projects", isDirectory: true)
        let file = root.appendingPathComponent("-project-/session-fixture.jsonl")
        try UsageCoordinatorTests.write(Self.other(type: "summary"), to: file)
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(store: store, registry: UsageAdapterRegistry([ClaudeCodeUsageAdapter()]))
        _ = try await coordinator.connect(tool: .claudeCode, rootPath: root)

        let when = Date().addingTimeInterval(60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: when)
        try UsageCoordinatorTests.append(
            Self.assistant(requestID: "req_a", messageID: "msg_a", input: 10, output: 2_000, cacheRead: 400_000, cacheCreation: 9_000, timestamp: stamp)
                + Self.assistant(requestID: "req_b", messageID: "msg_b", input: 5, output: 1_000, cacheRead: 600_000, cacheCreation: 1_000, timestamp: stamp),
            to: file
        )
        for _ in 0..<3 { _ = try await coordinator.scan(trigger: .manual) }

        let days = try await store.usageDayByTool(day: when, calendar: UsageCalendar.seoul)
        let claude = try #require(days.first { $0.tool == .claudeCode })
        #expect(claude.events == 2)
        #expect(claude.inputTokens == 15 && claude.outputTokens == 3_000)
        #expect(claude.cacheReadTokens == 1_000_000 && claude.cacheWriteTokens == 10_000)
        #expect(claude.acceptedTokens == 3_015, "캐시는 인정분에 들어가지 않습니다")
        #expect(claude.allTokens == 1_013_015)
        let dayTotals = try await store.usageDayTotals(day: when, calendar: UsageCalendar.seoul)
        #expect(days.reduce(0) { $0 + $1.acceptedTokens } == dayTotals.acceptedTokens, "도구별 합 = 오늘 인정 토큰")
    }

    @Test("호출 식별자가 없는 기록은 지급하지 않는다")
    func missingCallIdentity() async throws {
        let tree = try Self.tree("identity")
        defer { tree.remove() }
        try tree.write(Self.other(type: "summary"), to: Self.relative)

        let adapter = ClaudeCodeUsageAdapter()
        let source = Self.source(root: tree.root)
        let baseline = try await adapter.scanSlice(Self.request(source, baselining: true))

        try tree.append(Self.assistant(requestID: nil, messageID: "", input: 700, output: 300), to: Self.relative)
        let second = try await adapter.scanSlice(Self.request(source, checkpoints: baseline.fileCheckpoints))
        #expect(Self.acceptedTokens(second) == 0)
        #expect(second.entries.contains { $0.reason == .missingCallIdentity })
    }

    @Test("부분 줄은 소비하지 않고, 다시 스캔해도 중복이 생기지 않는다")
    func partialLineAndRescan() async throws {
        let tree = try Self.tree("partial")
        defer { tree.remove() }
        try tree.write(Self.other(type: "summary"), to: Self.relative)

        let adapter = ClaudeCodeUsageAdapter()
        let source = Self.source(root: tree.root)
        let baseline = try await adapter.scanSlice(Self.request(source, baselining: true))

        let complete = Self.assistant(requestID: "req_a", input: 400, output: 100)
        try tree.append(complete + #"{"type":"assistant","sessionId":"session-fixture""#, to: Self.relative)
        let second = try await adapter.scanSlice(Self.request(source, checkpoints: baseline.fileCheckpoints))
        #expect(Self.acceptedTokens(second) == 500)

        let fileURL = tree.root.appendingPathComponent(Self.relative)
        let size = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let checkpoint = try #require(second.fileCheckpoints.first)
        #expect(checkpoint.byteOffset < size, "부분 줄 너머로 전진하지 않습니다")

        // Same positions again: nothing new, nothing duplicated.
        let third = try await adapter.scanSlice(Self.request(source, checkpoints: second.fileCheckpoints))
        #expect(third.entries.isEmpty)
    }

    @Test("형식 인식: transcript가 없으면 오류가 아니라 빈 상태다")
    func inspection() throws {
        let tree = try Self.tree("inspect")
        defer { tree.remove() }
        let adapter = ClaudeCodeUsageAdapter()

        #expect(adapter.inspect(source: Self.source(root: tree.root)).support == .empty)

        try tree.write(Self.assistant(input: 100, output: 50), to: Self.relative)
        let supported = adapter.inspect(source: Self.source(root: tree.root))
        #expect(supported.support == .supported)
        #expect(supported.formatVersion == ClaudeCodeUsageAdapter.formatVersion)
        #expect(!supported.excluded.contains { $0.contains("서브에이전트") }, "서브에이전트 호출도 읽습니다")

        // A file with no assistant usage at all is recognised but not credited.
        let other = try Self.tree("inspect-other")
        defer { other.remove() }
        try other.write(Self.other(type: "summary"), to: Self.relative)
        #expect(adapter.inspect(source: Self.source(root: other.root)).support == .unsupportedVersion)
    }
}
