import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

@Suite("사용량 저장 트랜잭션")
struct UsageStorageTests {
    @Test("배치 커밋 직전 실패는 아무것도 남기지 않는다")
    func batchFailureLeavesNothingBehind() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)

        let offsetBefore = try await harness.store.usageCheckpoints().first?.byteOffset
        await harness.store.setInjectedFailureForTesting(.beforeUsageBatchCommit)
        let summaries = try await harness.drain(maxSlices: 5)
        // The whole write path is failing, so the failure is reported through
        // the scan summary rather than persisted.
        #expect(summaries.contains { $0.errors > 0 })

        var totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0)
        #expect(totals.awardedPoints == 0)
        #expect(totals.remainderTokens == 0)
        var ledger = try await harness.store.ledger()
        #expect(ledger.isEmpty)
        var events = try await harness.store.usageRecentEvents(limit: 10)
        #expect(events.isEmpty, "실패한 배치는 이벤트도 남기지 않습니다")
        var checkpoints = try await harness.store.usageCheckpoints()
        #expect(
            checkpoints.first?.byteOffset == offsetBefore,
            "실패한 배치의 레코드 너머로 checkpoint가 전진하면 안 됩니다"
        )

        // The same records are collected once the failure is cleared.
        await harness.store.setInjectedFailureForTesting(nil)
        _ = try await harness.drain()
        totals = try await harness.store.usageTotals()
        ledger = try await harness.store.ledger()
        events = try await harness.store.usageRecentEvents(limit: 10)
        checkpoints = try await harness.store.usageCheckpoints()
        #expect(totals.awardedPoints == 1)
        #expect(ledger.count == 1)
        #expect(events.count == 1)
        #expect(checkpoints.first?.status == .ok)
    }

    @Test("커밋 직후 중단되어도 같은 배치를 다시 적용하면 중복 지급이 없다")
    func reapplyingCommittedBatchPaysOnce() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)
        _ = try await harness.drain()

        let awarded = try await harness.store.usageTotals()
        #expect(awarded.awardedPoints == 1)

        // Re-run the file from scratch: same records, same identities.
        let checkpoints = try await harness.store.usageCheckpoints()
        let file = try #require(checkpoints.first)
        var rewound = file
        rewound.byteOffset = 0
        rewound.status = .ok
        _ = try await harness.store.applyUsageBatch(
            sourceID: try #require(try await harness.store.usageSource()).sourceID,
            baseline: false,
            entries: [],
            checkpoints: [rewound],
            run: UsageScanRunSummary(
                runID: UUID().uuidString,
                trigger: "manual",
                startedAt: Date(),
                finishedAt: Date()
            ),
            recordRun: false
        )
        _ = try await harness.drain()

        let after = try await harness.store.usageTotals()
        #expect(after.awardedPoints == 1)
        #expect(after.acceptedTokens == 10_000)
        let ledger = try await harness.store.ledger()
        #expect(ledger.filter { $0.reason == .usageReward }.count == 1)
    }

    @Test("팩 구매와 적립이 겹쳐도 잔액은 장부 합계와 같고 음수가 되지 않는다")
    func purchaseAndAwardRaceKeepsLedgerConsistent() async throws {
        let harness = try UsageTestSupport.harness(
            economy: PackEconomy(version: 1, initialDemoGrantPoints: 0, packCostPoints: 1)
        )
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // 1 P worth of usage, appended while pack purchases run concurrently.
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)

        // Only actors cross the concurrency boundary here.
        let store = harness.store
        let collector = harness.collector
        async let award: Void = { _ = try? await collector.scan(trigger: .manual) }()
        let purchases = await withTaskGroup(of: Bool.self) { group -> [Bool] in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        _ = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: SeedSource.randomSeed())
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        _ = await award
        _ = try await harness.drain()

        let balance = try await harness.store.balance()
        let ledger = try await harness.store.ledger(limit: 500)
        let packs = try await harness.store.packInstances()
        let spent = packs.count * 1
        let earned = try await harness.store.usageTotals().awardedPoints

        #expect(balance == ledger.reduce(0) { $0 + $1.deltaPoints })
        #expect(balance >= 0)
        #expect(packs.count == purchases.filter { $0 }.count, "실패한 구매는 팩을 만들지 않습니다")
        #expect(balance == earned - spent)
    }

    @Test("원본 로그가 삭제되어도 이미 얻은 포인트는 유지된다")
    func deletingSourceKeepsRewards() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)
        _ = try await harness.drain()
        #expect(try await harness.store.balance() == 1)

        try FileManager.default.removeItem(at: harness.tree.root.appendingPathComponent(path))
        _ = try await harness.drain()

        #expect(try await harness.store.balance() == 1)
        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1)
        let checkpoints = try await harness.store.usageCheckpoints()
        #expect(checkpoints.first?.status == .missing)
    }

    @Test("루트가 사라지면 상태로 표시되고 장부는 그대로다")
    func missingRootIsReportedAsStatus() async throws {
        let harness = try UsageTestSupport.harness()
        let treeRoot = harness.tree.root
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: "project-a/session.jsonl")
        _ = try await harness.collector.connect(root: treeRoot)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: "project-a/session.jsonl")
        _ = try await harness.drain()
        #expect(try await harness.store.balance() == 1)

        harness.tree.remove()
        let summary = try await harness.collector.scan(trigger: .manual)
        #expect(summary.errors >= 1)
        let source = try await harness.store.usageSource()
        #expect(source?.status == .rootMissing || source?.status == .permissionDenied)
        #expect(try await harness.store.balance() == 1)

        // A missing root is not the same state as "no new events".
        let status = try await harness.collector.status()
        #expect(status.source?.status != .collecting)
    }

    @Test("일시정지는 장부와 checkpoint를 유지하고 재개하면 미처리분을 반영한다")
    func pauseKeepsStateAndResumeCollects() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(UsageTestSupport.record(1, input: 10_000, output: 0, offset: 1) + "\n", to: path)
        _ = try await harness.drain()
        let before = try await harness.store.usageTotals()

        try await harness.collector.pause()
        try harness.tree.append(UsageTestSupport.record(2, input: 10_000, output: 0, offset: 2) + "\n", to: path)
        _ = try await harness.drain(maxSlices: 3)
        let paused = try await harness.store.usageTotals()
        #expect(paused.awardedPoints == before.awardedPoints, "일시정지 중에는 적립하지 않습니다")
        let status = try await harness.collector.status()
        #expect(status.source?.isPaused == true)

        try await harness.collector.resume()
        let resumed = try await harness.store.usageTotals()
        #expect(resumed.awardedPoints == before.awardedPoints + 1, "재개 시 미처리분이 반영됩니다")
    }
}
