import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// pi-family (pi · omo · senpi) sessions: synthetic files in the observed
/// layout, never a real session.
@Suite("pi 계열 사용량")
struct PiSessionUsageAdapterTests {
    static let header = OMPLogParser.SessionHeader(id: "session-pi", version: 3, parentSession: nil)

    static func headerLine(_ id: String = "session-pi") -> String {
        #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-09-24T00:00:00.000Z","cwd":"/tmp/fixture"}"# + "\n"
    }

    static func call(entry: String, at milliseconds: Int, provider: String = "openai-codex", responseID: String? = "resp", stop: String = "toolUse",
                     input: Int = 1_000, output: Int = 200, cacheRead: Int = 5_000) -> String {
        let response = responseID.map { #","responseId":"\#($0)""# } ?? ""
        return #"{"type":"message","id":"\#(entry)","parentId":null,"timestamp":"2026-09-24T00:00:00.000Z","message":{"role":"assistant","provider":"\#(provider)","model":"fixture-model","api":"fixture","stopReason":"\#(stop)"\#(response),"timestamp":\#(milliseconds),"usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(cacheRead),"cacheWrite":0,"totalTokens":\#(input + output + cacheRead)}}}"# + "\n"
    }

    private func object(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func entry(_ outcome: UsageJSONLScan.Outcome) -> UsageBatchEntry? {
        if case let .entry(entry, _, _) = outcome { return entry }
        return nil
    }

    @Test("모델 서비스 호출은 비캐시 입력 + 출력으로 인정하고, 도구를 넘는 호출 키를 붙인다")
    func acceptsModelServiceCalls() throws {
        let adapter = PiSessionUsageAdapter(tool: .omo)
        let at = 1_790_000_000_000
        let result = try #require(entry(adapter.parse(try object(Self.call(entry: "e1", at: at, responseID: "resp_1")), header: Self.header)))
        #expect(result.status == .accepted)
        let event = try #require(result.event)
        #expect(event.inputTokens + event.outputTokens == 1_200 && event.cacheReadTokens == 5_000, "캐시 읽기 5,000은 인정하지 않습니다")
        #expect(event.id.rawValue == "omo:session-pi:resp_1")
        #expect(event.callKey == "pi-entry:e1@\(at)")
    }

    @Test("로컬·테스트 모델, 오류·중단 호출은 적립하지 않는다")
    func excludesLocalModelsAndFailedCalls() throws {
        let adapter = PiSessionUsageAdapter(tool: .pi)
        let at = 1_790_000_000_000
        for provider in ["faux", "lm-studio", "ollama", "omlx"] {
            let result = try #require(entry(adapter.parse(try object(Self.call(entry: "e", at: at, provider: provider)), header: Self.header)))
            #expect(result.status == .excluded && result.reason == .localModelExcluded, "\(provider)")
        }
        let error = try #require(entry(adapter.parse(try object(Self.call(entry: "e", at: at, stop: "error")), header: Self.header)))
        #expect(error.reason == .stopReasonError)
        let aborted = try #require(entry(adapter.parse(try object(Self.call(entry: "e", at: at, stop: "aborted")), header: Self.header)))
        #expect(aborted.reason == .stopReasonAborted)
    }

    @Test("응답 ID가 없는 호출(claude-sdk 등)은 항목 ID로 식별하고, 다른 버전 헤더는 받지 않는다")
    func identityFallbackAndHeaderVersion() throws {
        let adapter = PiSessionUsageAdapter(tool: .senpi)
        let at = 1_790_000_000_000
        let result = try #require(entry(adapter.parse(try object(Self.call(entry: "e9", at: at, provider: "claude-sdk-oauth", responseID: nil)), header: Self.header)))
        #expect(result.status == .accepted)
        #expect(result.event?.responseID == "entry:e9")
        let other = OMPLogParser.SessionHeader(id: "s", version: 4, parentSession: nil)
        let rejected = try #require(entry(adapter.parse(try object(Self.call(entry: "e9", at: at)), header: other)))
        #expect(rejected.reason == .unsupportedSchemaVersion)
        // Not an assistant usage record: nothing to say about it.
        if case .skip = adapter.parse(try object(#"{"type":"custom","id":"x"}"#), header: Self.header) {} else {
            Issue.record("usage가 없는 줄은 건너뛰어야 합니다")
        }
    }

    @Test("omo가 senpi 세션을 복사해 두어도 같은 호출은 한 번만 적립되고, 서브에이전트 실행도 읽는다")
    func copiedSessionsAreCountedOnce() async throws {
        let base = try UsageCoordinatorTests.tree("pi-family")
        defer { try? FileManager.default.removeItem(at: base) }
        let omoRoot = base.appendingPathComponent("omo/sessions", isDirectory: true)
        let senpiRoot = base.appendingPathComponent("senpi/agent/sessions", isDirectory: true)
        let omoFile = omoRoot.appendingPathComponent("--project--/2026-09-24T00-00-00-000Z_session-pi.jsonl")
        let senpiFile = senpiRoot.appendingPathComponent("--project--/2026-09-24T00-00-00-000Z_session-pi.jsonl")
        let history = Self.headerLine() + Self.call(entry: "old", at: 1_700_000_000_000, responseID: "resp_old")
        try UsageCoordinatorTests.write(history, to: omoFile)
        try UsageCoordinatorTests.write(history, to: senpiFile)

        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry(PiSessionUsageAdapter.tools.map { PiSessionUsageAdapter(tool: $0) })
        )
        _ = try await coordinator.connect(tool: .omo, rootPath: omoRoot)
        _ = try await coordinator.connect(tool: .senpi, rootPath: senpiRoot)
        #expect(try await store.usageTotals().acceptedTokens == 0, "연결 전 기록은 기준선입니다")

        // New work after the connection, copied into both trees: one call with a
        // provider response id and one without (claude-sdk).
        let now = Int(Date().timeIntervalSince1970 * 1000) + 60_000
        let newCalls = Self.call(entry: "n1", at: now, responseID: "resp_new", input: 4_000, output: 1_000)
            + Self.call(entry: "n2", at: now + 1_000, provider: "claude-sdk-oauth", responseID: nil, input: 3_000, output: 2_000)
        try UsageCoordinatorTests.append(newCalls, to: omoFile)
        try UsageCoordinatorTests.append(newCalls, to: senpiFile)
        // A subagent run inside the session folder, created after the connection.
        let run = omoRoot.appendingPathComponent("--project--/2026-09-24T00-00-00-000Z_session-pi/agent1/run-0/session.jsonl")
        try UsageCoordinatorTests.write(Self.headerLine("session-run") + Self.call(entry: "r1", at: now + 2_000, responseID: "resp_run", input: 500, output: 500), to: run)

        for _ in 0..<3 { _ = try await coordinator.scan(trigger: .manual) }
        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 5_000 + 5_000 + 1_000, "복사본은 한 번만, 서브에이전트 실행은 따로")
        let tools = try await store.usageToolTotals()
        let counted = tools.reduce(0) { $0 + $1.acceptedTokens }
        #expect(counted == totals.acceptedTokens, "도구별 합계 = 공통 계정")
    }
}
