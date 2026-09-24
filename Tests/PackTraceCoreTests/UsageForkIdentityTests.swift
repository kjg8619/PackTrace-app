import Foundation
import PackTraceCore
import PackTraceTestSupport
import Testing

/// Reproduction tests for inherited (fork/import) records.
///
/// OMP 18.2.8 has a real fork path: `SessionManager.forkFrom` structured-clones
/// the source session's entries and writes them into a *new* session file with a
/// new session id (see docs/OMP_USAGE_SCHEMA.md §11). The cloned assistant
/// records keep their `message.responseId`. These tests model exactly that shape
/// with synthetic session data in a temporary directory — no OMP process, no
/// network and no model call is involved.
@Suite("상속(fork/import) 이벤트 identity")
struct UsageForkIdentityTests {
    /// A record that occurred now, so it counts as post-connection usage.
    private func recordNow(_ n: Int, input: Int, output: Int, session: String) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            sessionID: session,
            input: input,
            output: output,
            occurredAt: now,
            completedAt: now + 1_000
        )
    }

    private func record(_ n: Int, input: Int, output: Int, offset: Int, session: String) -> String {
        OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            sessionID: session,
            input: input,
            output: output,
            occurredAt: OMPFixture.timestamp(offset),
            completedAt: OMPFixture.timestamp(offset + 1)
        )
    }

    /// Row 6 of the verification matrix: a call recorded in the baseline is
    /// cloned into a second session after the connection.
    @Test("baseline에 있던 호출이 fork로 다시 나타나도 지급되지 않는다")
    func forkedBaselineCallIsNotRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let originPath = "project-a/origin.jsonl"
        let forkPath = "project-a/fork.jsonl"

        // Origin session: exists before the connection, so it is baseline.
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session1,
                assistants: [record(1, input: 50_000, output: 50_000, offset: 0, session: OMPFixture.session1)]
            ),
            to: originPath
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        #expect(try await harness.store.usageTotals().awardedPoints == 0)

        // A fork appears afterwards: new session id, cloned entry, same responseId.
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [record(1, input: 50_000, output: 50_000, offset: 0, session: OMPFixture.session2)]
            ),
            to: forkPath
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0, "fork로 복제된 baseline 호출이 지급되면 안 됩니다")
        #expect(totals.awardedPoints == 0)
    }

    /// Row 7: an already rewarded call reappears through a fork.
    @Test("이미 지급된 호출이 fork로 다시 나타나도 한 번만 지급된다")
    func forkedRewardedCallPaysOnce() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let originPath = "project-a/origin.jsonl"
        let forkPath = "project-a/fork.jsonl"
        try harness.tree.write(
            OMPFixture.sessionFile(sessionID: OMPFixture.session1, assistants: []),
            to: originPath
        )
        _ = try await harness.collector.connect(root: harness.tree.root)

        // New call after the connection: rewarded once.
        let live = record(2, input: 10_000, output: 0, offset: 30, session: OMPFixture.session1)
        try harness.tree.append(live + "\n", to: originPath)
        _ = try await harness.drain()
        #expect(try await harness.store.usageTotals().awardedPoints == 1)

        // The fork copies that call and then adds a genuinely new call.
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [
                    // Cloned from the origin session: same call, old timestamp.
                    record(2, input: 10_000, output: 0, offset: 30, session: OMPFixture.session2),
                    // Created after the fork: a genuinely new call.
                    recordNow(3, input: 10_000, output: 0, session: OMPFixture.session2),
                ]
            ),
            to: forkPath
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 20_000, "복제된 호출 1회 + 신규 호출 1회만 인정되어야 합니다")
        #expect(totals.awardedPoints == 2)
        let ledger = try await harness.store.ledger()
        #expect(ledger.filter { $0.reason == .usageReward }.count == 2)
    }

    /// Row 3/4: the same response id arrives with different numbers.
    @Test("같은 호출 ID의 값이 다르면 지급하지 않고 충돌로 남긴다")
    func forkedCallWithDifferentValuesIsIsolated() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let originPath = "project-a/origin.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(sessionID: OMPFixture.session1, assistants: []), to: originPath)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            record(4, input: 10_000, output: 0, offset: 30, session: OMPFixture.session1) + "\n",
            to: originPath
        )
        _ = try await harness.drain()
        #expect(try await harness.store.usageTotals().awardedPoints == 1)

        // Same response id, different session, different token counts.
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [record(4, input: 99_000, output: 99_000, offset: 30, session: OMPFixture.session2)]
            ),
            to: "project-a/fork.jsonl"
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1, "충돌은 추가 지급하지 않습니다")
        #expect(totals.acceptedTokens == 10_000)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.conflictEvents >= 1)
    }

    /// A fork whose origin was never collected: old records must stay unpaid.
    @Test("원본을 본 적 없는 fork의 과거 기록은 지급하지 않는다")
    func unbaselinedInheritedRecordsAreNotRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        // Empty at connect time; the fork arrives with pre-connection history.
        try harness.tree.write(OMPFixture.sessionFile(sessionID: OMPFixture.session1, assistants: []), to: "project-a/session.jsonl")
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [
                    record(5, input: 10_000, output: 0, offset: 0, session: OMPFixture.session2),
                    record(6, input: 10_000, output: 0, offset: 1, session: OMPFixture.session2),
                ]
            ),
            to: "project-a/late-fork.jsonl"
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0, "연결 이전 시각의 상속 기록은 지급 대상이 아닙니다")
        #expect(totals.awardedPoints == 0)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 2)
    }

    /// Row 8: real new calls after the fork are still rewarded.
    @Test("fork 이후 새로 생긴 호출은 정상 지급된다")
    func postForkCallsAreRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        try harness.tree.write(OMPFixture.sessionFile(sessionID: OMPFixture.session1, assistants: []), to: "project-a/session.jsonl")
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [
                    record(7, input: 10_000, output: 0, offset: 0, session: OMPFixture.session2),
                    recordNow(8, input: 10_000, output: 0, session: OMPFixture.session2),
                ]
            ),
            to: "project-a/live-fork.jsonl"
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000, "fork 이후 발생한 호출만 인정됩니다")
        #expect(totals.awardedPoints == 1)
    }
}
