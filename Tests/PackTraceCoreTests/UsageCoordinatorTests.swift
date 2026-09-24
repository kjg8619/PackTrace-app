import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// The coordinator: adapters reading into the common wallet, per-source
/// isolation, and the end-to-end path this milestone is about.
@Suite("사용량 coordinator")
struct UsageCoordinatorTests {
    static func tree(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-coordinator-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// A Codex-shaped session file: header plus one `token_count` event.
    static func session(ordinal: Int, input: Int, cached: Int, output: Int, previousTotal: Int) -> String {
        let lastTotal = input + cached + output
        let total = previousTotal + lastTotal
        let header = #"{"timestamp":"2026-09-23T00:00:00.000Z","type":"session_meta","payload":{"id":"session-e2e","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
        let event = #"{"timestamp":"2026-09-23T00:00:0\#(ordinal).000Z","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(previousTotal + input + cached),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(previousTotal + output),"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input + cached),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(lastTotal)},"model_context_window":272000}}}"# + "\n"
        return ordinal == 0 ? header + event : event
    }

    @Test("Codex 파일이 어댑터 → 저장 → 공통 지갑까지 이어진다")
    func endToEndThroughCoordinator() async throws {
        let root = try Self.tree("e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions/2026/09/23/rollout-fixture.jsonl")
        try Self.write(Self.session(ordinal: 0, input: 9_000, cached: 0, output: 1_000, previousTotal: 0), to: sessions)

        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(store: store, registry: UsageAdapterRegistry([CodexUsageAdapter()]))

        // Connect: the first pass is the baseline, so the existing backlog earns
        // nothing.
        let source = try await coordinator.connect(tool: .codex, rootPath: root)
        #expect(try await store.usageTotals().acceptedTokens == 0)
        #expect(try await store.usageTotals().awardedPoints == 0)
        _ = source
        let afterConnect = try await store.usageSource(tool: .codex)
        #expect(afterConnect?.baselineCompletedAt != nil)

        // Work happens: a new call appears after the boundary.
        try Self.append(Self.session(ordinal: 1, input: 6_000, cached: 1_000, output: 2_000, previousTotal: 10_000), to: sessions)
        _ = try await coordinator.scan(trigger: .manual)

        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 8_000, "비캐시 입력 6,000 + 출력 2,000")
        #expect(totals.awardedPoints == 0)
        #expect(totals.remainderTokens == 8_000)

        // One more call reaches the first point.
        try Self.append(Self.session(ordinal: 2, input: 1_500, cached: 0, output: 500, previousTotal: 19_000), to: sessions)
        let pointsBefore = totals.awardedPoints
        _ = try await coordinator.scan(trigger: .manual)
        let after = try await store.usageTotals()
        #expect(after.acceptedTokens == 10_000)
        #expect(after.awardedPoints == pointsBefore + 1)
        #expect(after.remainderTokens == 0)

        // Rescanning changes nothing at all.
        _ = try await coordinator.scan(trigger: .manual)
        let final = try await store.usageTotals()
        #expect(final.acceptedTokens == after.acceptedTokens)
        #expect(final.awardedPoints == after.awardedPoints)
        #expect(final.remainderTokens == after.remainderTokens)

        let ledger = try await store.ledger()
        #expect(ledger.filter { $0.reason == .usageReward }.count == 1)

        let statuses = try await coordinator.status()
        #expect(statuses.count == 1)
        #expect(statuses.first?.inspection.support == .supported)
        #expect(statuses.first?.acceptedTokens == 10_000)
        #expect(statuses.first?.acceptedEvents == 2)
    }

    @Test("한 소스의 오류가 다른 소스 수집을 멈추지 않는다")
    func failingSourceIsIsolated() async throws {
        let goodRoot = try Self.tree("good")
        let missingRoot = try Self.tree("missing")
        defer {
            try? FileManager.default.removeItem(at: goodRoot)
            try? FileManager.default.removeItem(at: missingRoot)
        }
        let sessions = goodRoot.appendingPathComponent("sessions/2026/09/23/rollout-good.jsonl")
        try Self.write(Self.session(ordinal: 0, input: 100, cached: 0, output: 100, previousTotal: 0), to: sessions)

        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let coordinator = UsageCoordinator(store: store, registry: UsageAdapterRegistry([CodexUsageAdapter()]))
        _ = try await coordinator.connect(tool: .codex, rootPath: goodRoot)

        // A second source that disappears between connect and scan.
        let broken = try await store.connectUsageSource(tool: .codex, rootPath: missingRoot.path)
        try FileManager.default.removeItem(at: missingRoot)

        // The good source still makes progress.
        try Self.append(Self.session(ordinal: 1, input: 500, cached: 0, output: 500, previousTotal: 200), to: sessions)
        let summary = try await coordinator.scan(trigger: .manual)
        let sourceStates = try await coordinator.status().map { "\($0.source.tool.rawValue):\($0.source.status.rawValue):\($0.source.lastReason ?? "-")" }

        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 1_000, "summary=\(summary) states=\(sourceStates)")
        let brokenSource = try await store.usageSource(id: broken.sourceID)
        #expect(brokenSource?.status == .rootMissing || brokenSource?.status == .baselining)
    }
}
