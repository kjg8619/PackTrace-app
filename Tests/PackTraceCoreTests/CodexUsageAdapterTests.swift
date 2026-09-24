import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Codex rollout reading: the cumulative boundary, repeated notifications, a
/// reset that must not be credited, and the subset relations between fields.
///
/// Everything here is a synthetic file written by the test. No real session log
/// is read.
@Suite("Codex 사용량 어댑터")
struct CodexUsageAdapterTests {
    // MARK: - Fixtures

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
            .appendingPathComponent("packtrace-codex-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Tree(root: root)
    }

    static let relative = "2026/09/23/rollout-2026-09-23T00-00-00-fixture.jsonl"

    static func meta(sessionID: String = "session-fixture", cliVersion: String = "0.155.1") -> String {
        #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"\#(sessionID)","timestamp":"2026-09-23T00:00:00.000Z","cli_version":"\#(cliVersion)","model_provider":"openai"}}"# + "\n"
    }

    /// One `token_count` event.
    ///
    /// `input` is the non-cached part and `cached` the cached part, exactly as
    /// the real records express them: `total_tokens == input_tokens +
    /// output_tokens`, with cached input inside `input_tokens`. The `previous*`
    /// arguments carry the cumulative totals of the preceding record, so the
    /// fixture keeps the same identity the real file does.
    static func tokenCount(
        ordinal: Int,
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int = 0,
        previousInputTotal: Int = 0,
        previousCachedTotal: Int = 0,
        previousOutputTotal: Int = 0,
        previousReasoningTotal: Int = 0,
        timestamp: String = "2026-09-23T00:00:01.000Z"
    ) -> String {
        let inputTotal = previousInputTotal + input + cached
        let cachedTotal = previousCachedTotal + cached
        let outputTotal = previousOutputTotal + output
        let reasoningTotal = previousReasoningTotal + reasoning
        let total = inputTotal + outputTotal
        let lastTotal = input + cached + output
        return #"{"timestamp":"\#(timestamp)","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(inputTotal),"cached_input_tokens":\#(cachedTotal),"cache_write_input_tokens":0,"output_tokens":\#(outputTotal),"reasoning_output_tokens":\#(reasoningTotal),"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input + cached),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(lastTotal)},"model_context_window":272000}}}"# + "\n"
    }

    static func source(root: URL) -> UsageSourceRecord {
        UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .codex, url: root).sourceID,
            realm: .production,
            tool: .codex,
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
        cursors: [String: UsageCursor] = [:],
        baselining: Bool = false
    ) -> UsageSliceRequest {
        UsageSliceRequest(
            source: source,
            fileCheckpoints: checkpoints,
            cursors: cursors,
            budget: UsageScanBudget(),
            isBaselining: baselining,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Baselining pass, then one incremental pass, done the way the coordinator
    /// will: the positions returned by the first pass are handed to the second.
    static func baselineThenIncrement(
        _ adapter: CodexUsageAdapter,
        _ source: UsageSourceRecord
    ) async throws -> (baseline: UsageSliceOutput, increment: UsageSliceOutput) {
        let baseline = try await adapter.scanSlice(request(source, baselining: true))
        let cursors = Dictionary(uniqueKeysWithValues: baseline.cursors.map { ($0.cursorKey, $0) })
        let increment = try await adapter.scanSlice(
            request(source, checkpoints: baseline.fileCheckpoints, cursors: cursors)
        )
        return (baseline, increment)
    }

    static func acceptedTokens(_ output: UsageSliceOutput) -> Int {
        output.entries
            .filter { $0.status == .accepted }
            .compactMap(\.event)
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    // MARK: - Baseline

    @Test("연결 시점의 누적값은 기준선이 되고, 그 뒤 증가분만 인정한다")
    func baselineCreditsOnlyIncrease() async throws {
        let tree = try Self.tree("baseline")
        defer { tree.remove() }
        try tree.write(Self.meta() + Self.tokenCount(ordinal: 0, input: 60_000, cached: 10_000, output: 5_000, reasoning: 1_000), to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))
        #expect(first.entries.filter { $0.status == .accepted }.isEmpty, "기준선 통과 기록은 인정하지 않습니다")
        #expect(first.fileCheckpoints.count == 1)
        #expect(first.cursors.count >= 1)

        try tree.append(
            Self.tokenCount(
                ordinal: 1,
                input: 900,
                cached: 400,
                output: 300,
                reasoning: 120,
                previousInputTotal: 70_000,
                previousCachedTotal: 10_000,
                previousOutputTotal: 5_000,
                previousReasoningTotal: 1_000
            ),
            to: Self.relative
        )
        let second = try await adapter.scanSlice(
            Self.request(
                source,
                checkpoints: first.fileCheckpoints,
                cursors: Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) })
            )
        )
        let events = second.entries.compactMap(\.event)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.id.rawValue == "codex:session-fixture:1")
        #expect(event.inputTokens == 900, "비캐시 입력만 인정합니다")
        #expect(event.outputTokens == 300)
        #expect(event.cacheReadTokens == 400)
        #expect(event.reasoningTokens == 120)
        #expect(event.reasoningTokens! < event.outputTokens, "reasoning은 output의 부분집합입니다")
        #expect(Self.acceptedTokens(second) == 1_200)
    }

    // MARK: - Cumulative edges

    @Test("같은 누적값이 반복되는 알림은 새 호출로 세지 않는다")
    func repeatedNotificationCreditsNothing() async throws {
        let tree = try Self.tree("repeat")
        defer { tree.remove() }
        let line = Self.tokenCount(ordinal: 0, input: 500, cached: 0, output: 500)
        try tree.write(Self.meta() + line, to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))

        // The same notification again, with a different ordinal: no increase.
        try tree.append(line.replacingOccurrences(of: "\"ordinal\":0", with: "\"ordinal\":1"), to: Self.relative)
        let second = try await adapter.scanSlice(
            Self.request(source, checkpoints: first.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(second.entries.compactMap(\.event).isEmpty)
        #expect(Self.acceptedTokens(second) == 0)
    }

    @Test("누적값이 줄면 지급하지 않고 기준만 다시 잡는다")
    func decreaseIsNotCredited() async throws {
        let tree = try Self.tree("decrease")
        defer { tree.remove() }
        try tree.write(Self.meta() + Self.tokenCount(ordinal: 0, input: 8_000, cached: 0, output: 2_000), to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))

        // A reset: the counter restarts from a smaller value.
        try tree.append(Self.tokenCount(ordinal: 1, input: 100, cached: 0, output: 50), to: Self.relative)
        let second = try await adapter.scanSlice(
            Self.request(source, checkpoints: first.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(Self.acceptedTokens(second) == 0, "의미가 확인되지 않은 감소는 지급하지 않습니다")
        #expect(second.entries.contains { $0.reason == .cumulativeBoundaryUnclear })
        let cursor = try #require(second.cursors.first)
        #expect(cursor.payload == "150", "기준은 새 값으로 다시 잡힙니다")

        // After the reset, the next increase is credited in full.
        try tree.append(
            Self.tokenCount(
                ordinal: 2,
                input: 300,
                cached: 0,
                output: 200,
                previousInputTotal: 100,
                previousOutputTotal: 50
            ),
            to: Self.relative
        )
        let third = try await adapter.scanSlice(
            Self.request(
                source,
                checkpoints: second.fileCheckpoints,
                cursors: Dictionary(uniqueKeysWithValues: second.cursors.map { ($0.cursorKey, $0) })
            )
        )
        #expect(Self.acceptedTokens(third) == 500)
    }

    @Test("증가분과 요청별 값이 맞지 않으면 추측하지 않고 제외한다")
    func mismatchedIncreaseIsExcluded() async throws {
        let tree = try Self.tree("mismatch")
        defer { tree.remove() }
        try tree.write(Self.meta() + Self.tokenCount(ordinal: 0, input: 1_000, cached: 0, output: 1_000), to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))

        // A jump covering more than one request: the cumulative total grows by
        // 5,000 while the last-request object only describes 1,000.
        let jump = #"{"timestamp":"2026-09-23T00:00:02.000Z","ordinal":9,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":11000,"reasoning_output_tokens":0,"total_tokens":15000},"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":500,"reasoning_output_tokens":0,"total_tokens":1000},"model_context_window":272000}}}"# + "\n"
        try tree.append(jump, to: Self.relative)
        let second = try await adapter.scanSlice(
            Self.request(source, checkpoints: first.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(Self.acceptedTokens(second) == 0)
        #expect(second.entries.contains { $0.reason == .cumulativeBoundaryUnclear })
    }

    @Test("캐시가 입력보다 큰 기록은 거절하고, 부분 줄은 소비하지 않는다")
    func invalidCacheAndPartialLine() async throws {
        let tree = try Self.tree("invalid")
        defer { tree.remove() }
        // cached_input_tokens larger than input_tokens contradicts the verified
        // contract (total == input + output).
        let broken = #"{"timestamp":"2026-09-23T00:00:01.000Z","ordinal":0,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":20},"last_token_usage":{"input_tokens":10,"cached_input_tokens":500,"cache_write_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":20},"model_context_window":272000}}}"# + "\n"
        try tree.write(Self.meta() + broken, to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))

        // A complete record with a valid contract, followed by a partial line.
        let good = Self.tokenCount(
            ordinal: 1,
            input: 600,
            cached: 100,
            output: 400,
            previousInputTotal: 10,
            previousCachedTotal: 500,
            previousOutputTotal: 10
        )
        try tree.append(good + #"{"timestamp":"2026-09-23T00:00:03.000Z","ordinal":2,"type":"event_msg""#, to: Self.relative)
        let second = try await adapter.scanSlice(
            Self.request(source, checkpoints: first.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(Self.acceptedTokens(second) == 1_000, "비캐시 입력 600 + 출력 400")
        let checkpoint = try #require(second.fileCheckpoints.first)
        let size = try #require(FileManager.default.attributesOfItem(atPath: tree.root.appendingPathComponent(Self.relative).path)[.size] as? NSNumber)
        #expect(checkpoint.byteOffset < size.int64Value, "부분 줄 너머로 전진하지 않습니다")

        // Completing the line consumes the rest.
        try tree.append(#""info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":1000},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"model_context_window":272000}}}"# + "\n", to: Self.relative)
        let third = try await adapter.scanSlice(
            Self.request(source, checkpoints: second.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: second.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(Self.acceptedTokens(third) == 0, "증가 없는 완성 레코드는 인정하지 않습니다")
        let finalCheckpoint = try #require(third.fileCheckpoints.first)
        #expect(finalCheckpoint.byteOffset == size.int64Value - 0 - Int64(0) || finalCheckpoint.byteOffset > checkpoint.byteOffset)
    }

    @Test("다시 스캔해도 같은 호출을 두 번 만들지 않는다")
    func rescanProducesNothing() async throws {
        let tree = try Self.tree("rescan")
        defer { tree.remove() }
        try tree.write(Self.meta() + Self.tokenCount(ordinal: 0, input: 2_000, cached: 0, output: 1_000), to: Self.relative)

        let adapter = CodexUsageAdapter()
        let source = Self.source(root: tree.root)
        let first = try await adapter.scanSlice(Self.request(source, baselining: true))
        try tree.append(
            Self.tokenCount(
                ordinal: 1,
                input: 1_500,
                cached: 500,
                output: 500,
                previousInputTotal: 2_000,
                previousOutputTotal: 1_000
            ),
            to: Self.relative
        )
        let cursors = Dictionary(uniqueKeysWithValues: first.cursors.map { ($0.cursorKey, $0) })
        let second = try await adapter.scanSlice(Self.request(source, checkpoints: first.fileCheckpoints, cursors: cursors))
        #expect(Self.acceptedTokens(second) == 2_000, "비캐시 입력 1,500 + 출력 500")

        // Same positions again: nothing new.
        let third = try await adapter.scanSlice(
            Self.request(source, checkpoints: second.fileCheckpoints, cursors: Dictionary(uniqueKeysWithValues: second.cursors.map { ($0.cursorKey, $0) }))
        )
        #expect(third.entries.isEmpty)
        #expect(third.fileCheckpoints.isEmpty)
    }

    @Test("설치본 인식과 빈 폴더 구분")
    func inspection() throws {
        let tree = try Self.tree("inspect")
        defer { tree.remove() }
        let adapter = CodexUsageAdapter()

        let empty = adapter.inspect(source: Self.source(root: tree.root))
        #expect(empty.support == .empty, "파일이 없는 상태는 오류가 아닙니다")

        try tree.write(Self.meta(cliVersion: "0.155.1") + Self.tokenCount(ordinal: 0, input: 10, cached: 0, output: 10), to: Self.relative)
        let supported = adapter.inspect(source: Self.source(root: tree.root))
        #expect(supported.support == .supported)
        #expect(supported.toolVersion == "0.155.1")
        #expect(supported.formatVersion == CodexUsageAdapter.formatVersion)
        #expect(supported.excluded.contains { $0.contains("rate limit") })
    }
}
