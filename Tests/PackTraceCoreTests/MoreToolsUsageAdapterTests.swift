import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Hermes, Grok and Kimi readers, on synthetic records in the observed shapes.
@Suite("Hermes · Grok · Kimi 사용량")
struct MoreToolsUsageAdapterTests {
    private func source(_ tool: UsageToolKind, connectedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> UsageSourceRecord {
        UsageSourceRecord(sourceID: "\(tool.rawValue)-src", realm: .production, tool: tool, toolVersion: nil, formatVersion: nil,
                          rootPath: "/tmp/\(tool.rawValue)", connectedAt: connectedAt, baselineCompletedAt: connectedAt,
                          isPaused: false, lastScanAt: nil, status: .collecting, lastReason: nil)
    }

    private func hermesRow(calls: Int, input: Int, output: Int, cacheRead: Int = 0, firstSeen: Double = 1_789_000_000,
                           lastSeen: Double = 1_790_000_100, baseURL: String = "https://chatgpt.com/backend-api/codex") -> HermesUsageAdapter.Row {
        HermesUsageAdapter.Row(sessionID: "s1", model: "gpt-5", task: "", provider: "openai-codex", baseURL: baseURL,
                               calls: calls, input: input, output: output, cacheRead: cacheRead, cacheWrite: 0, reasoning: 0,
                               firstSeen: firstSeen, lastSeen: lastSeen)
    }

    @Test("Hermes: 기준선에서는 누적값만 기록하고, 이후 늘어난 만큼만 적립한다")
    func hermesCreditsGrowthOnly() throws {
        let baseline = UsageSliceRequest(source: source(.hermes), isBaselining: true, now: Date())
        let first = HermesUsageAdapter.decide(row: hermesRow(calls: 10, input: 50_000, output: 2_000), previous: nil, request: baseline)
        #expect(first.entry == nil, "연결 시점의 누적값은 기준선입니다")
        let cursor = try #require(first.cursor)

        let later = UsageSliceRequest(source: source(.hermes), cursors: [cursor.cursorKey: cursor], isBaselining: false, now: Date())
        let grown = HermesUsageAdapter.decide(row: hermesRow(calls: 12, input: 58_000, output: 2_500, cacheRead: 90_000), previous: cursor, request: later)
        let entry = try #require(grown.entry)
        #expect(entry.status == .accepted)
        #expect(entry.event?.inputTokens == 8_000 && entry.event?.outputTokens == 500, "증가분만")
        #expect(entry.event?.cacheReadTokens == 90_000)

        // Same totals again: nothing new, no write.
        let again = HermesUsageAdapter.decide(row: hermesRow(calls: 12, input: 58_000, output: 2_500, cacheRead: 90_000), previous: grown.cursor, request: later)
        #expect(again.entry == nil && again.cursor == nil)

        // Shrunk (rewind): re-anchored, nothing paid.
        let rewound = HermesUsageAdapter.decide(row: hermesRow(calls: 3, input: 9_000, output: 100), previous: grown.cursor, request: later)
        #expect(rewound.entry == nil && rewound.cursor != nil)
    }

    @Test("Hermes: 연결 뒤 새로 생긴 세션은 처음부터 적립하고, 연결 전 세션은 기록만, 로컬 모델은 제외한다")
    func hermesNewRowsAndLocalModels() throws {
        let request = UsageSliceRequest(source: source(.hermes), isBaselining: false, now: Date())
        let fresh = HermesUsageAdapter.decide(row: hermesRow(calls: 2, input: 3_000, output: 400, firstSeen: 1_790_000_050), previous: nil, request: request)
        #expect(fresh.entry?.status == .accepted && fresh.entry?.event?.inputTokens == 3_000)
        let old = HermesUsageAdapter.decide(row: hermesRow(calls: 2, input: 3_000, output: 400, firstSeen: 1_789_999_000), previous: nil, request: request)
        #expect(old.entry == nil && old.cursor != nil, "연결 전부터 있던 줄은 기준선")
        let local = HermesUsageAdapter.decide(row: hermesRow(calls: 1, input: 1_000, output: 100, firstSeen: 1_790_000_050, baseURL: "http://localhost:1234/v1"),
                                              previous: nil, request: request)
        #expect(local.entry?.status == .excluded && local.entry?.reason == .localModelExcluded)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func entry(_ outcome: UsageJSONLScan.Outcome) -> UsageBatchEntry? {
        if case let .entry(entry, _, _) = outcome { return entry }
        return nil
    }

    static func grokTurn(prompt: String, stop: String = "end_turn", input: Int = 20_000, cached: Int = 12_000, output: Int = 800) -> String {
        #"{"timestamp":1790000200,"method":"session/update","params":{"sessionId":"g1","_meta":{},"update":{"sessionUpdate":"turn_completed","prompt_id":"\#(prompt)","stop_reason":"\#(stop)","usage":{"inputTokens":\#(input),"outputTokens":\#(output),"cachedReadTokens":\#(cached),"cacheCreationTokens":0,"reasoningTokens":300,"totalTokens":\#(input + output),"modelCalls":3,"numTurns":1,"modelUsage":{"grok-4.6-build":{}}}}}}"#
    }

    @Test("Grok: 턴마다 (입력 − 캐시 읽기) + 출력을 인정하고, 오류 턴은 제외한다")
    func grokTurns() throws {
        let adapter = GrokUsageAdapter()
        let accepted = try #require(entry(adapter.parse(try object(Self.grokTurn(prompt: "p1")))))
        #expect(accepted.status == .accepted)
        #expect(accepted.event?.inputTokens == 8_000, "입력 20,000에 캐시 12,000이 포함돼 있습니다")
        #expect(accepted.event?.outputTokens == 800)
        #expect(accepted.event?.id.rawValue == "grok:g1:p1")
        let failed = try #require(entry(adapter.parse(try object(Self.grokTurn(prompt: "p2", stop: "error")))))
        #expect(failed.status == .excluded)
        let impossible = try #require(entry(adapter.parse(try object(Self.grokTurn(prompt: "p3", input: 100, cached: 500)))))
        #expect(impossible.status == .unsupported, "캐시가 입력보다 크면 의미가 다른 기록입니다")
        if case .skip = adapter.parse(try object(#"{"params":{"update":{"sessionUpdate":"tool_call"}}}"#)) {} else {
            Issue.record("usage가 없는 갱신은 건너뜁니다")
        }
    }

    @Test("Kimi: inputOther(비캐시) + 출력을 인정하고, 세션 폴더에서 세션 ID를 얻는다")
    func kimiSteps() throws {
        let adapter = KimiUsageAdapter()
        let line = #"{"type":"context.append_loop_event","time":1790000300000,"event":{"type":"step","uuid":"u1","turnId":"t1","step":1,"usage":{"inputOther":13265,"output":51,"inputCacheRead":10496,"inputCacheCreation":0},"finishReason":"tool_calls","messageId":"m1"}}"#
        let accepted = try #require(entry(adapter.parse(try object(line), sessionID: "abc")))
        #expect(accepted.status == .accepted)
        #expect(accepted.event?.inputTokens == 13_265 && accepted.event?.cacheReadTokens == 10_496)
        #expect(accepted.event?.id.rawValue == "kimi:abc:m1")
        let file = URL(fileURLWithPath: "/tmp/kimi/sessions/wd_x/session_70b6-1/agents/main/wire.jsonl")
        #expect(KimiUsageAdapter.sessionID(of: file) == "70b6-1")
    }

    @Test("Grok 파일이 코디네이터를 거쳐 연결 뒤 턴만 공통 지갑에 적립된다")
    func grokEndToEnd() async throws {
        let root = try UsageCoordinatorTests.tree("grok")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("%2Ftmp%2Fproject/g1/updates.jsonl")
        try UsageCoordinatorTests.write(Self.grokTurn(prompt: "old") + "\n", to: file)
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(store: store, registry: UsageAdapterRegistry([GrokUsageAdapter()]))
        _ = try await coordinator.connect(tool: .grok, rootPath: root)
        #expect(try await store.usageTotals().acceptedTokens == 0)

        let now = Int(Date().timeIntervalSince1970) + 60
        let newTurn = Self.grokTurn(prompt: "new", input: 30_000, cached: 20_000, output: 2_000)
            .replacingOccurrences(of: #""timestamp":1790000200"#, with: #""timestamp":\#(now)"#)
        try UsageCoordinatorTests.append(newTurn + "\n", to: file)
        _ = try await coordinator.scan(trigger: .manual)
        #expect(try await store.usageTotals().acceptedTokens == 12_000)
        _ = try await coordinator.scan(trigger: .manual)
        #expect(try await store.usageTotals().acceptedTokens == 12_000, "다시 읽어도 한 번만")
    }
}
