import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("사용량 적립 규칙")
struct UsageRewardTests {
    /// Runs one connect + one appended reward record and returns the totals.
    private func award(
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        sequence: Int = 1
    ) async throws -> (UsageBatchResult, UsageTotals) {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(sequence),
                input: input,
                output: output,
                cacheRead: cacheRead,
                occurredAt: OMPFixture.timestamp(sequence),
                completedAt: OMPFixture.timestamp(sequence + 1)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()
        return (UsageBatchResult(), try await harness.store.usageTotals())
    }

    @Test("6,000 + 4,000 → 1 P, 나머지 0")
    func sixThousandPlusFourThousand() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            [
                UsageTestSupport.record(1, input: 4_000, output: 2_000, offset: 1),
                UsageTestSupport.record(2, input: 3_000, output: 1_000, offset: 2),
            ].joined(separator: "\n") + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
        #expect(totals.remainderTokens == 0)
    }

    @Test("9,999 + 1 → 1 P, 나머지 0")
    func nineThousandNineHundredNinetyNine() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            [
                UsageTestSupport.record(1, input: 9_999, output: 0, offset: 1),
                UsageTestSupport.record(2, input: 1, output: 0, offset: 2),
            ].joined(separator: "\n") + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1)
        #expect(totals.remainderTokens == 0)
    }

    @Test("25,500 → 2 P, 나머지 5,500")
    func twentyFiveThousandFiveHundred() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            UsageTestSupport.record(1, input: 20_000, output: 5_500, offset: 1) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 2)
        #expect(totals.remainderTokens == 5_500)
        #expect(totals.acceptedTokens == 25_500)
    }

    @Test("캐시 토큰은 인정량에서 제외되고 별도로 남는다")
    func cacheTokensAreExcludedButStored() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(1),
                input: 1_000,
                output: 0,
                cacheRead: 500_000,
                occurredAt: OMPFixture.timestamp(1),
                completedAt: OMPFixture.timestamp(2)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 1_000, "캐시 읽기는 인정 토큰이 아닙니다")
        #expect(totals.awardedPoints == 0)

        let rows = try await harness.store.usageRecentEvents(limit: 5)
        #expect(rows.first?.cacheReadTokens == 500_000)
        #expect(rows.first?.inputTokens == 1_000)
    }

    @Test("중복 이벤트는 포인트도 나머지도 움직이지 않는다")
    func duplicatesDoNotMoveRemainder() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        let record = UsageTestSupport.record(1, input: 7_000, output: 0, offset: 1)
        try harness.tree.append(record + "\n", to: path)
        _ = try await harness.drain()
        let first = try await harness.store.usageTotals()
        #expect(first.remainderTokens == 7_000)

        // Same record again in a copy under a second project directory.
        try harness.tree.write(UsageTestSupport.sessionFile(records: [record]), to: "project-b/session.jsonl")
        _ = try await harness.drain()

        let after = try await harness.store.usageTotals()
        #expect(after.remainderTokens == first.remainderTokens)
        #expect(after.awardedPoints == first.awardedPoints)
        #expect(after.acceptedTokens == first.acceptedTokens)
    }

    @Test("나머지는 재시작과 날짜 변경을 넘어 유지된다")
    func remainderSurvivesRestartAndMidnight() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 9_500, output: 0, offset: 1) + "\n", to: path)
        _ = try await harness.drain()
        let before = try await harness.store.usageTotals()
        #expect(before.remainderTokens == 9_500)

        // Restart: a new store and collector on the same directory.
        let reopened = try PackTraceStore(
            location: harness.location,
            catalog: CatalogLoader.loadBundled()
        )
        let collector = OMPUsageCollector(store: reopened, limits: .small)
        try harness.tree.append(UsageTestSupport.record(2, input: 600, output: 0, offset: 2) + "\n", to: path)
        _ = try await collector.scan(trigger: .manual)

        let after = try await reopened.usageTotals()
        #expect(after.remainderTokens == 100, "9,500 + 600 = 10,100 → 1 P, 나머지 100")
        #expect(after.awardedPoints == 1)
    }

    @Test("늦게 발견된 이벤트는 발생일과 적립일을 구분해 집계한다")
    func lateEventsSeparateOccurrenceAndAwardDay() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // Occurred yesterday (Seoul), discovered today.
        let now = Date()
        let yesterday = UsageCalendar.seoul.date(byAdding: .day, value: -1, to: now) ?? now
        let occurred = Int(yesterday.timeIntervalSince1970 * 1000)
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(1),
                input: 10_000,
                output: 0,
                occurredAt: occurred,
                completedAt: occurred + 1_000
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let today = try await harness.store.usageDayTotals(day: now, calendar: UsageCalendar.seoul)
        let yesterdayTotals = try await harness.store.usageDayTotals(day: yesterday, calendar: UsageCalendar.seoul)
        #expect(yesterdayTotals.acceptedTokens == 10_000, "인정량은 이벤트 발생일 기준입니다")
        #expect(today.acceptedTokens == 0)
        #expect(today.awardedPoints == 1, "적립 포인트는 장부 확정일 기준입니다")
    }

    @Test("합계가 넘치면 이번 배치를 통째로 되돌린다")
    func overflowRollsBackTheBatch() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try await harness.store.setRewardRemainderForTesting(
            ruleID: UsageRewardRule.ompNonCacheV1.ruleID,
            remainderTokens: Int.max
        )

        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)
        let summaries = try await harness.drain()
        #expect(summaries.contains { $0.errors > 0 }, "오버플로는 오류로 보고되어야 합니다")
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.filesWithErrors >= 1)

        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 0)
        let balance = try await harness.store.balance()
        #expect(balance == 0, "오버플로 배치는 지급하지 않습니다")
        let ledger = try await harness.store.ledger()
        #expect(ledger.isEmpty)

        // The checkpoint must not have advanced past the unprocessed record.
        let checkpoints = try await harness.store.usageCheckpoints()
        #expect(checkpoints.allSatisfy { $0.byteOffset == 0 || $0.status != .ok })

        // After the artificial remainder is removed the record is processed once.
        try await harness.store.setRewardRemainderForTesting(
            ruleID: UsageRewardRule.ompNonCacheV1.ruleID,
            remainderTokens: 0
        )
        _ = try await harness.drain()
        let recovered = try await harness.store.usageTotals()
        #expect(recovered.awardedPoints == 1)
        #expect(recovered.acceptedTokens == 10_000)
    }
}
