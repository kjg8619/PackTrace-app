import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// The multi-source layer: stable source identity, reuse on reconnect, cursors
/// kept apart from file offsets, cross-source duplicate calls, and one common
/// reward account that does not depend on scanning order.
@Suite("다중 소스 사용량")
struct UsageMultiSourceTests {
    // MARK: - Helpers

    /// A synthetic event. Identity, tokens and time are supplied so a test can
    /// describe exactly one call.
    static func event(
        tool: UsageToolKind,
        session: String,
        record: String,
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int? = nil,
        provider: String = "verified-provider",
        model: String = "test-model",
        callKey: String? = nil,
        occurredAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UsageEvent {
        var event = UsageEvent(
            // The provider's own ids are only unique inside one tool, so the
            // fixture keeps them apart the same way the adapters do.
            id: UsageEventID(tool: tool, sessionID: session, responseID: "\(tool.rawValue)-\(record)"),
            sessionID: session,
            responseID: "\(tool.rawValue)-\(record)",
            provider: provider,
            model: model,
            stopReason: "stop",
            occurredAtMilliseconds: Int(occurredAt.timeIntervalSince1970 * 1000),
            completedAtMilliseconds: Int(occurredAt.timeIntervalSince1970 * 1000),
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        event.reasoningTokens = reasoning
        event.callKey = callKey
        return event
    }

    static func run(trigger: String = "manual") -> UsageScanRunSummary {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return UsageScanRunSummary(runID: UUID().uuidString.lowercased(), trigger: trigger, startedAt: now, finishedAt: now)
    }

    static func accepted(_ events: [UsageEvent]) -> [UsageBatchEntry] {
        events.map { UsageBatchEntry(event: $0, status: .accepted) }
    }

    // MARK: - A. Source identity

    @Test("같은 도구·같은 경로는 같은 sourceID를 얻고, 도구가 다르면 다른 ID를 얻는다")
    func sourceIdentityIsStableAndToolScoped() async throws {
        let path = "/tmp/packtrace-identity/../packtrace-identity/sessions"
        let first = UsageSourceIdentity(tool: .codex, canonicalPath: path)
        let second = UsageSourceIdentity(tool: .codex, canonicalPath: path)
        #expect(first.sourceID == second.sourceID)
        #expect(first.sourceID.hasPrefix("codex:"))

        // The same directory read by another adapter is a different source.
        let otherTool = UsageSourceIdentity(tool: .claudeCode, canonicalPath: path)
        #expect(otherTool.sourceID != first.sourceID)

        // A differently written path for the same directory resolves to one id.
        let messy = UsageSourceIdentity(tool: .codex, url: URL(fileURLWithPath: "/tmp/packtrace-identity/sessions/./"))
        #expect(messy.sourceID == first.sourceID)
        expectSameIdentity(first, messy)
    }

    private func expectSameIdentity(_ a: UsageSourceIdentity, _ b: UsageSourceIdentity) {
        #expect(a.canonicalPath == b.canonicalPath)
    }

    @Test("경로는 홈 디렉터리를 ~로 가려서 표시한다")
    func maskedPathHidesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let identity = UsageSourceIdentity(tool: .omp, canonicalPath: home + "/.omp/agent/sessions")
        #expect(identity.maskedPath.hasPrefix("~/"))
        #expect(identity.maskedPath.contains(home) == false)
    }

    // MARK: - B. Connect and reuse

    @Test("같은 저장소를 다시 연결하면 기존 소스 행과 기준선을 재사용한다")
    func reconnectReusesSourceRow() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let root = "/tmp/packtrace-multisource/reuse"
        let first = try await store.connectUsageSource(tool: .codex, rootPath: root)
        #expect(first.tool == .codex)
        #expect(first.baselineCompletedAt == nil)

        try await store.markUsageSourceBaselined(sourceID: first.sourceID)
        let again = try await store.connectUsageSource(tool: .codex, rootPath: root)
        #expect(again.sourceID == first.sourceID, "재연결은 같은 행을 써야 합니다")
        #expect(again.baselineCompletedAt != nil, "기준선은 재연결로 초기화되지 않습니다")
        #expect(try await store.usageSources().count == 1)
    }

    @Test("다른 도구를 연결해도 기존 도구의 소스는 그대로 남는다")
    func connectingAnotherToolKeepsExistingSources() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let omp = try await store.connectUsageSource(tool: .omp, rootPath: "/tmp/packtrace-multisource/omp")
        let codex = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/codex")
        let claude = try await store.connectUsageSource(tool: .claudeCode, rootPath: "/tmp/packtrace-multisource/claude")

        let sources = try await store.usageSources()
        #expect(sources.count == 3)
        #expect(sources.map(\.tool) == [.omp, .codex, .claudeCode])
        #expect(sources.map(\.sourceID).contains(omp.sourceID))
        #expect(try await store.usageSource(tool: .codex)?.sourceID == codex.sourceID)
        #expect(try await store.usageSource(tool: .claudeCode)?.sourceID == claude.sourceID)

        // Another path for the same tool is another source, not a replacement:
        // both keep collecting, and nothing else is disturbed.
        let second = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/codex-second")
        #expect(second.sourceID != codex.sourceID)
        #expect(second.status != .unconnected)
        #expect(try await store.allUsageSourceRows().first { $0.sourceID == codex.sourceID }?.status != .unconnected)
        #expect(try await store.usageSources().filter { $0.tool == .codex }.count == 2)
        #expect(try await store.usageSource(tool: .omp)?.sourceID == omp.sourceID)
        #expect(try await store.usageSource(tool: .claudeCode)?.sourceID == claude.sourceID)
    }

    // MARK: - C. One common account

    @Test("도구별 인정 토큰이 하나의 공통 계정에 모여 1 P가 되고 나머지가 0이 된다")
    func toolTotalsShareOneAccount() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let omp = try await store.connectUsageSource(tool: .omp, rootPath: "/tmp/packtrace-multisource/totals-omp")
        let codex = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/totals-codex")
        let claude = try await store.connectUsageSource(tool: .claudeCode, rootPath: "/tmp/packtrace-multisource/totals-claude")

        try await store.applyUsageBatch(
            sourceID: omp.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .omp, session: "s1", record: "r1", input: 5_000, output: 1_000)]),
            checkpoints: [],
            run: Self.run()
        )
        let afterOmp = try await store.usageTotals()
        #expect(afterOmp.acceptedTokens == 6_000)
        #expect(afterOmp.awardedPoints == 0, "도구별로 먼저 반올림하지 않습니다")
        #expect(afterOmp.remainderTokens == 6_000)

        try await store.applyUsageBatch(
            sourceID: codex.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .codex, session: "s2", record: "r1", input: 1_800, output: 200)]),
            checkpoints: [],
            run: Self.run()
        )
        try await store.applyUsageBatch(
            sourceID: claude.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .claudeCode, session: "s3", record: "r1", input: 1_500, output: 500)]),
            checkpoints: [],
            run: Self.run()
        )

        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
        #expect(totals.remainderTokens == 0)

        let perTool = try await store.usageToolTotals()
        #expect(perTool.map(\.tool) == [.omp, .codex, .claudeCode])
        #expect(perTool.map(\.acceptedTokens) == [6_000, 2_000, 2_000])
        #expect(perTool.reduce(0) { $0 + $1.acceptedTokens } == totals.acceptedTokens)
    }

    @Test("기존 나머지 7,000을 보존한 채 세 도구가 각각 1,000을 더하면 1 P가 된다")
    func existingRemainderIsKept() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.setRewardRemainderForTesting(ruleID: UsageRewardRule.ompNonCacheV1.ruleID, remainderTokens: 7_000)

        var sources: [UsageToolKind: String] = [:]
        for tool in [UsageToolKind.codex, .claudeCode, .openCode] {
            sources[tool] = try await store.connectUsageSource(tool: tool, rootPath: "/tmp/packtrace-multisource/remainder-\(tool.rawValue)").sourceID
        }
        for (tool, sourceID) in sources.sorted(by: { $0.key.order < $1.key.order }) {
            try await store.applyUsageBatch(
                sourceID: sourceID,
                baseline: false,
                entries: Self.accepted([Self.event(tool: tool, session: "s-\(tool.rawValue)", record: "r1", input: 800, output: 200)]),
                checkpoints: [],
                run: Self.run()
            )
        }

        let totals = try await store.usageTotals()
        // 7,000 carried over plus 3,000 new tokens make exactly one point, and
        // the remainder starts again at zero.
        #expect(totals.awardedPoints == 1)
        #expect(totals.remainderTokens == 0)
    }

    @Test("스캔 순서를 바꿔도 총 적립과 나머지가 같다")
    func scanOrderDoesNotChangeTotals() async throws {
        func run(order: [UsageToolKind]) async throws -> (points: Int, remainder: Int, accepted: Int) {
            let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
            var sources: [UsageToolKind: String] = [:]
            for tool in order {
                sources[tool] = try await store.connectUsageSource(tool: tool, rootPath: "/tmp/packtrace-multisource/order-\(tool.rawValue)").sourceID
            }
            let tokens: [UsageToolKind: (Int, Int)] = [
                .omp: (1_500, 500),
                .codex: (2_400, 600),
                .claudeCode: (3_700, 300),
                .openCode: (900, 100),
            ]
            for tool in order {
                let (input, output) = tokens[tool] ?? (0, 0)
                try await store.applyUsageBatch(
                    sourceID: sources[tool]!,
                    baseline: false,
                    entries: Self.accepted([Self.event(tool: tool, session: "s-\(tool.rawValue)", record: "r1", input: input, output: output)]),
                    checkpoints: [],
                    run: Self.run()
                )
            }
            let totals = try await store.usageTotals()
            return (totals.awardedPoints, totals.remainderTokens, totals.acceptedTokens)
        }

        let forward = try await run(order: [.omp, .codex, .claudeCode, .openCode])
        let backward = try await run(order: [.openCode, .claudeCode, .codex, .omp])
        #expect(forward.points == backward.points)
        #expect(forward.remainder == backward.remainder)
        #expect(forward.accepted == backward.accepted)
        #expect(forward.accepted == 10_000)
        #expect(forward.points == 1)
        #expect(forward.remainder == 0)
    }

    // MARK: - D. Duplicates across sources

    @Test("같은 실제 호출을 두 소스에서 관찰하면 한 번만 지급하고 나머지도 늘지 않는다")
    func sameCallFromTwoSourcesIsPaidOnce() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let omp = try await store.connectUsageSource(tool: .omp, rootPath: "/tmp/packtrace-multisource/dup-omp")
        let claude = try await store.connectUsageSource(tool: .claudeCode, rootPath: "/tmp/packtrace-multisource/dup-claude")

        let callKey = "anthropic-request:req_fixture_1"
        try await store.applyUsageBatch(
            sourceID: omp.sourceID,
            baseline: false,
            entries: Self.accepted([
                Self.event(tool: .omp, session: "omp-session", record: "r1", input: 4_000, output: 1_000, callKey: callKey)
            ]),
            checkpoints: [],
            run: Self.run()
        )
        let first = try await store.usageTotals()

        // The same call, seen through the other tool, with a different reason
        // string that would have looked like a different call on its own.
        try await store.applyUsageBatch(
            sourceID: claude.sourceID,
            baseline: false,
            entries: Self.accepted([
                Self.event(
                    tool: .claudeCode,
                    session: "claude-session",
                    record: "req_fixture_1",
                    input: 4_000,
                    output: 1_000,
                    provider: "anthropic",
                    callKey: callKey
                )
            ]),
            checkpoints: [],
            run: Self.run()
        )

        let second = try await store.usageTotals()
        #expect(second.acceptedTokens == first.acceptedTokens, "중복 관찰은 인정량을 늘리지 않습니다")
        #expect(second.remainderTokens == first.remainderTokens)
        #expect(second.awardedPoints == first.awardedPoints)

        let events = try await store.usageRecentEvents(limit: 10)
        #expect(events.count == 1, "중복은 별칭으로만 기록됩니다")
        let perTool = try await store.usageToolTotals()
        #expect(perTool.map(\.tool) == [.omp])
    }

    @Test("숫자가 같아도 서로 다른 호출이면 각각 인정한다")
    func equalNumbersFromDifferentCallsBothCount() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let codex = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/equal-codex")

        try await store.applyUsageBatch(
            sourceID: codex.sourceID,
            baseline: false,
            entries: Self.accepted([
                Self.event(tool: .codex, session: "s1", record: "1", input: 3_000, output: 1_000),
                Self.event(tool: .codex, session: "s1", record: "2", input: 3_000, output: 1_000),
                Self.event(tool: .codex, session: "s1", record: "3", input: 3_000, output: 1_000),
            ]),
            checkpoints: [],
            run: Self.run()
        )

        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 12_000)
        #expect(totals.awardedPoints == 1)
        #expect(totals.remainderTokens == 2_000)
        #expect(try await store.usageRecentEvents(limit: 10).count == 3)
    }

    // MARK: - E. Cursors and transactions

    @Test("커서는 배치와 같은 트랜잭션에서 저장되고, 실패하면 남지 않는다")
    func cursorsCommitWithTheBatch() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let source = try await store.connectUsageSource(tool: .openCode, rootPath: "/tmp/packtrace-multisource/cursor")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cursor = UsageCursor(
            cursorKey: "message-table",
            kind: .rowPosition,
            payload: #"{"created":1758000000000,"id":"msg_fixture"}"#,
            updatedAt: now
        )

        try await store.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .openCode, session: "s-oc", record: "r1", input: 900, output: 100)]),
            checkpoints: [],
            cursors: [cursor],
            run: Self.run()
        )
        var cursors = try await store.usageCursors(sourceID: source.sourceID)
        #expect(cursors["message-table"]?.kind == .rowPosition)
        #expect(cursors["message-table"]?.payload.contains("msg_fixture") == true)

        // A failed batch leaves the cursor exactly where it was.
        await store.setInjectedFailureForTesting(.beforeUsageBatchCommit)
        let failed = try? await store.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .openCode, session: "s-oc", record: "r2", input: 5_000, output: 0)]),
            checkpoints: [],
            cursors: [
                UsageCursor(
                    cursorKey: "message-table",
                    kind: .rowPosition,
                    payload: #"{"created":1758000001000,"id":"msg_later"}"#,
                    updatedAt: now
                )
            ],
            run: Self.run()
        )
        #expect(failed == nil)
        cursors = try await store.usageCursors(sourceID: source.sourceID)
        #expect(cursors["message-table"]?.payload.contains("msg_fixture") == true)
        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 1_000, "실패한 배치는 인정량도 커서도 남기지 않습니다")
    }

    @Test("세션 관찰과 포장 도구 메타데이터가 소스별로 따로 저장된다")
    func sessionObservationsArePerSource() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let codex = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/sessions-codex")
        try await store.updateUsageSourceMetadata(sourceID: codex.sourceID, toolVersion: "codex-cli 0.155.1", formatVersion: "rollout-jsonl")

        try await store.applyUsageBatch(
            sourceID: codex.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .codex, session: "session-codex", record: "1", input: 100, output: 100)]),
            checkpoints: [],
            sessions: [UsageSessionObservation(sessionID: "session-codex", parentSessionID: nil, schemaVersion: 1)],
            run: Self.run()
        )

        let source = try #require(try await store.usageSource(tool: .codex))
        #expect(source.toolVersion == "codex-cli 0.155.1")
        #expect(source.formatVersion == "rollout-jsonl")
    }

    // MARK: - F. Baseline isolation

    @Test("한 소스의 기준선은 다른 소스의 신규 보상을 막지 않는다")
    func baselineIsPerSource() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let omp = try await store.connectUsageSource(tool: .omp, rootPath: "/tmp/packtrace-multisource/base-omp")
        try await store.markUsageSourceBaselined(sourceID: omp.sourceID)

        // OMP sees a new call after its baseline: this is credited.
        try await store.applyUsageBatch(
            sourceID: omp.sourceID,
            baseline: false,
            entries: Self.accepted([Self.event(tool: .omp, session: "s-omp", record: "new", input: 2_000, output: 0)]),
            checkpoints: [],
            run: Self.run()
        )
        #expect(try await store.usageTotals().acceptedTokens == 2_000)

        // A newly connected tool walks its own history: nothing from it is
        // credited, and OMP's earlier credit is untouched.
        let codex = try await store.connectUsageSource(tool: .codex, rootPath: "/tmp/packtrace-multisource/base-codex")
        try await store.applyUsageBatch(
            sourceID: codex.sourceID,
            baseline: true,
            entries: [
                UsageBatchEntry(
                    event: Self.event(tool: .codex, session: "s-codex", record: "old", input: 90_000, output: 10_000),
                    status: .accepted
                )
            ],
            checkpoints: [],
            run: Self.run()
        )

        let totals = try await store.usageTotals()
        #expect(totals.acceptedTokens == 2_000, "기준선 통과 기록은 인정량에 들어가지 않습니다")
        #expect(totals.awardedPoints == 0)
        #expect(totals.remainderTokens == 2_000)
        let perTool = try await store.usageToolTotals()
        #expect(perTool.first { $0.tool == .codex }?.baselineEvents == 1)
        #expect(perTool.first { $0.tool == .codex }?.acceptedTokens == 0)
    }
}
