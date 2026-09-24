import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Correcting miscredited usage without rewriting history.
///
/// The store used here is the harness's own temporary profile, and the
/// "production copy" case is a restored snapshot in a second temporary root. The
/// user's real profile is never opened for writing.
@Suite("사용량 오적립 보정")
struct UsageCorrectionTests {
    // MARK: - Arithmetic against the recorded snapshots

    @Test("기록된 스냅샷으로 보정 산술을 회귀 검증한다")
    func arithmeticMatchesRecordedSnapshots() {
        // Case A: the state right after the incident was discovered.
        let a = UsageCorrectionPlan.compute(
            beforeAcceptedTokens: 159_978_142,
            beforePoints: 15_997,
            excludedTokens: 150_929_692,
            tokensPerPoint: 10_000
        )
        #expect(a.afterAcceptedTokens == 9_048_450)
        #expect(a.afterPoints == 904)
        #expect(a.afterRemainder == 8_450)
        #expect(a.deltaPoints == -15_093)

        // Case B: the state a few minutes later, after normal usage arrived.
        // The same excluded set now produces a different adjustment, which is why
        // a plan is always computed from the current account.
        let b = UsageCorrectionPlan.compute(
            beforeAcceptedTokens: 160_019_742,
            beforePoints: 16_001,
            excludedTokens: 150_929_692,
            tokensPerPoint: 10_000
        )
        #expect(b.afterAcceptedTokens == 9_090_050)
        #expect(b.afterPoints == 909)
        #expect(b.afterRemainder == 50)
        #expect(b.deltaPoints == -15_092)
        #expect(15_401 + b.deltaPoints == 309)
    }

    // MARK: - Harness

    /// A profile with the incident's shape: paid usage from a connected tool, and
    /// one source whose history was credited even though it predates the
    /// connection.
    static func makeIncidentProfile(label: String) async throws -> (store: PackTraceStore, location: StoreLocation, miscredited: [String]) {
        let catalog = Fixtures.syntheticCatalog()
        let location = try StoreLocation.temporary(label: label)
        let store = try Fixtures.makeStore(catalog: catalog, location: location)

        // A tool connected at T, whose history is credited by mistake.
        let connected = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try await store.connectUsageSource(tool: .openCode, rootPath: "/tmp/\(label)/opencode", now: connected)
        var miscredited: [String] = []
        for index in 1...3 {
            let event = UsageEvent(
                id: UsageEventID(tool: .openCode, sessionID: "history", responseID: "h\(index)"),
                sessionID: "history",
                responseID: "h\(index)",
                provider: "fixture",
                model: "fixture-model",
                stopReason: "stop",
                // Calls that happened long before the connection existed.
                occurredAtMilliseconds: Int(connected.timeIntervalSince1970 * 1000) - 30 * 24 * 3600 * 1000,
                completedAtMilliseconds: nil,
                inputTokens: 2_000,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0
            )
            miscredited.append(event.id.rawValue)
            try await store.applyUsageBatch(
                sourceID: source.sourceID,
                baseline: false,
                entries: [UsageBatchEntry(event: event, status: .accepted)],
                checkpoints: [],
                run: UsageScanRunSummary(runID: UUID().uuidString, trigger: "test", startedAt: connected, finishedAt: connected)
            )
        }
        // A genuine call after the connection.
        let genuine = UsageEvent(
            id: UsageEventID(tool: .openCode, sessionID: "live", responseID: "live1"),
            sessionID: "live",
            responseID: "live1",
            provider: "fixture",
            model: "fixture-model",
            stopReason: "stop",
            occurredAtMilliseconds: Int(connected.timeIntervalSince1970 * 1000) + 60_000,
            completedAtMilliseconds: nil,
            inputTokens: 6_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        try await store.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: false,
            entries: [UsageBatchEntry(event: genuine, status: .accepted)],
            checkpoints: [],
            run: UsageScanRunSummary(runID: UUID().uuidString, trigger: "test", startedAt: connected, finishedAt: connected)
        )
        return (store, location, miscredited)
    }

    /// The incident profile's consistent snapshot, restored into a second root.
    /// A copy is what the correction is verified on; the original is untouched.
    static func copyOfIncidentProfile() async throws -> (original: PackTraceStore, originalLocation: StoreLocation, copy: PackTraceStore, copyLocation: StoreLocation) {
        let (store, originalLocation, _) = try await makeIncidentProfile(label: "packtrace-correction-source")
        let package = try StoreBackup.create(
            location: originalLocation,
            library: try CatalogLoader.bundledLibrary(),
            poolVersion: "packs-v1"
        )
        // The original stays open; the copy is verified by reading it, and the
        // original is checked through the read-only reader.
        let copyLocation = try StoreLocation.temporary(label: "packtrace-correction-copy")
        _ = try StoreRestore.restore(
            packageURL: package.packageURL,
            location: copyLocation,
            library: try CatalogLoader.bundledLibrary()
        )
        let copy = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog(), location: copyLocation)
        return (store, originalLocation, copy, copyLocation)
    }

    static func incidentSourceID(_ store: PackTraceStore) async throws -> String {
        let rows = try await store.allUsageSourceRows().filter { $0.tool == .openCode }
        return try #require(rows.first, "no opencode source in this profile").sourceID
    }

    // MARK: - Plan

    @Test("오적립 대상만 골라내고 정상 신규 사용량은 남긴다")
    func planSelectsOnlyMiscreditedEvents() async throws {
        let (store, location, miscredited) = try await Self.makeIncidentProfile(label: "packtrace-correction-plan")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let sourceID = try await Self.incidentSourceID(store)
        let plan = try await store.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)

        #expect(plan.candidates.map(\.eventID) == miscredited.sorted())
        #expect(plan.excludedTokens == 6_000, "과거 호출 3건 x 2,000")
        #expect(plan.beforeAcceptedTokens == 12_000, "과거 6,000 + 정상 6,000")
        #expect(plan.afterAcceptedTokens == 6_000, "정상 신규 사용량은 유지")
        #expect(plan.beforePoints == 1)
        #expect(plan.afterPoints == 0)
        #expect(plan.afterRemainder == 6_000)
        #expect(plan.deltaPoints == -1)
        #expect(plan.expectedBalance == plan.beforeBalance + plan.deltaPoints)
        #expect(plan.isApplicable)
    }

    // MARK: - Apply on the copy

    @Test("사본에 적용해도 원본 이벤트·장부는 보존되고 멱등하다")
    func applyOnCopyPreservesHistory() async throws {
        let (original, originalLocation, copy, copyLocation) = try await Self.copyOfIncidentProfile()
        defer {
            try? FileManager.default.removeItem(at: originalLocation.directory)
            try? FileManager.default.removeItem(at: copyLocation.directory)
        }
        let sourceID = try await Self.incidentSourceID(copy)
        let before = try await copy.usageRecentEvents(limit: 100)
        let ledgerBefore = try await copy.ledger(limit: 200)
        let packsBefore = try await copy.packInstances()
        let balanceBefore = try await copy.balance()

        let plan = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)
        let applied = try await copy.applyUsageCorrection(plan)
        #expect(applied.deltaPoints == plan.deltaPoints)

        // History is readable exactly as it was, and the correction is recorded
        // separately.
        #expect(try await copy.usageRecentEvents(limit: 100) == before, "원본 usage 이벤트는 변경되지 않습니다")
        let ledgerAfter = try await copy.ledger(limit: 200)
        #expect(ledgerAfter.count == ledgerBefore.count + 1)
        #expect(ledgerAfter.contains { $0.reason == .usageReward })
        #expect(ledgerAfter.contains { $0.reason == .usageCorrection && $0.deltaPoints == plan.deltaPoints })
        #expect(try await copy.balance() == balanceBefore + plan.deltaPoints)
        #expect(try await copy.balance() == ledgerAfter.reduce(0) { $0 + $1.deltaPoints }, "잔액 = 장부 합계")
        #expect(try await copy.packInstances().map(\.id) == packsBefore.map(\.id), "팩·소유권 변화 없음")
        #expect(try await copy.corrections().count == 1)

        // Valid statistics exclude the miscredited tokens; the raw events remain.
        // The account reports the valid total; the events it was computed from
        // are still all there (checked above via usageRecentEvents).
        let totals = try await copy.usageTotals()
        #expect(totals.acceptedTokens == plan.afterAcceptedTokens)
        #expect(try await copy.correctedTokens() == plan.excludedTokens)

        // Re-applying the same incident changes nothing.
        let balanceAfterApply = try await copy.balance()
        await #expect(throws: UsageCorrectionError.self) {
            _ = try await copy.applyUsageCorrection(plan)
        }
        #expect(try await copy.balance() == balanceAfterApply)
        #expect(try await copy.corrections().count == 1)
        #expect(try await copy.usageTotals().acceptedTokens == plan.afterAcceptedTokens)

        // And the original profile was never touched.
        #expect(try await original.balance() == balanceBefore)
        #expect(try await original.corrections().isEmpty)
    }

    @Test("보정 후 재스캔은 오적립을 되살리지 않고, 새 사용량은 보정된 나머지에서 적립된다")
    func rescanAndNewUsageAfterCorrection() async throws {
        let (original, originalLocation, copy, copyLocation) = try await Self.copyOfIncidentProfile()
        defer {
            try? FileManager.default.removeItem(at: originalLocation.directory)
            try? FileManager.default.removeItem(at: copyLocation.directory)
        }
        let sourceID = try await Self.incidentSourceID(copy)
        let plan = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)
        _ = try await copy.applyUsageCorrection(plan)
        let balanceAfterCorrection = try await copy.balance()

        // The same history is offered again (a rescan): nothing is re-credited.
        let again = try await copy.miscreditedEvents(sourceID: sourceID)
        let reapply = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check-2", sourceID: sourceID)
        // The corrected events are not offered again: a second plan has nothing
        // to exclude, which is what stops the same tokens being subtracted twice.
        #expect(again.isEmpty, "이미 보정된 이벤트는 다시 대상이 되지 않습니다")
        #expect(reapply.excludedTokens == 0)
        #expect(reapply.deltaPoints == 0, "다시 빼지 않습니다")
        #expect(reapply.isApplicable == false)

        // New usage is credited from the corrected remainder.
        let event = UsageEvent(
            id: UsageEventID(tool: .openCode, sessionID: "live", responseID: "new-after-correction"),
            sessionID: "live",
            responseID: "new-after-correction",
            provider: "fixture",
            model: "fixture-model",
            stopReason: "stop",
            occurredAtMilliseconds: Int(Date().timeIntervalSince1970 * 1000),
            completedAtMilliseconds: nil,
            inputTokens: 4_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        try await copy.applyUsageBatch(
            sourceID: sourceID,
            baseline: false,
            entries: [UsageBatchEntry(event: event, status: .accepted)],
            checkpoints: [],
            run: UsageScanRunSummary(runID: UUID().uuidString, trigger: "test", startedAt: Date(), finishedAt: Date())
        )
        // 6,000 remaining + 4,000 new = 10,000 → exactly one more point.
        #expect(try await copy.balance() == balanceAfterCorrection + 1)
        let totals = try await copy.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
    }

    @Test("적용 중 실패하면 장부·계정·정정 기록이 모두 rollback된다")
    func failureRollsBackEverything() async throws {
        let (original, originalLocation, copy, copyLocation) = try await Self.copyOfIncidentProfile()
        defer {
            try? FileManager.default.removeItem(at: originalLocation.directory)
            try? FileManager.default.removeItem(at: copyLocation.directory)
        }
        let sourceID = try await Self.incidentSourceID(copy)
        let plan = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)
        let balanceBefore = try await copy.balance()
        let ledgerBefore = try await copy.ledger(limit: 200).count

        await copy.setInjectedFailureForTesting(.beforeUsageBatchCommit)
        await #expect(throws: (any Error).self) {
            _ = try await copy.applyUsageCorrection(plan)
        }
        await copy.setInjectedFailureForTesting(nil)

        #expect(try await copy.balance() == balanceBefore)
        #expect(try await copy.ledger(limit: 200).count == ledgerBefore)
        #expect(try await copy.corrections().isEmpty)
        #expect(try await copy.correctedTokens() == 0)
        // The plan still applies cleanly afterwards.
        _ = try await copy.applyUsageCorrection(plan)
        #expect(try await copy.corrections().count == 1)
    }

    @Test("계획 뒤에 포인트를 써서 잔액이 모자라면 적용 시점에 다시 검사해 거절한다")
    func balanceIsRecheckedAtApply() async throws {
        let (original, originalLocation, copy, copyLocation) = try await Self.copyOfIncidentProfile()
        defer {
            try? FileManager.default.removeItem(at: originalLocation.directory)
            try? FileManager.default.removeItem(at: copyLocation.directory)
        }
        _ = original
        let sourceID = try await Self.incidentSourceID(copy)
        let plan = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)
        try #require(plan.isApplicable && plan.deltaPoints < 0, "이 시나리오는 차감이 있는 계획이 필요합니다")

        // The app spends points between the plan and the apply.
        let pool = try copy.testPool()
        while try await copy.balance() >= pool.pricePoints {
            _ = try await copy.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 3)
        }
        let balance = try await copy.balance()
        // Packs cost 100 P, so the wallet may land exactly on the adjustment. The
        // guard under test is the apply-time check against the real balance: the
        // same plan, asking for one point more than is left, must be refused
        // even though the plan itself was made when the balance covered it.
        var shortfall = plan
        shortfall.deltaPoints = -(balance + 1)
        #expect(shortfall.isApplicable, "계획 자체는 적용 가능 상태로 만들어졌습니다")

        await #expect(throws: UsageCorrectionError.self) {
            _ = try await copy.applyUsageCorrection(shortfall)
        }
        #expect(try await copy.balance() == balance, "거절되면 잔액이 그대로입니다")
        #expect(try await copy.corrections().isEmpty)
    }

    @Test("조정 후 잔액이 음수면 적용을 거절한다")
    func negativeBalanceIsRefused() async throws {
        let (original, originalLocation, copy, copyLocation) = try await Self.copyOfIncidentProfile()
        defer {
            try? FileManager.default.removeItem(at: originalLocation.directory)
            try? FileManager.default.removeItem(at: copyLocation.directory)
        }
        let sourceID = try await Self.incidentSourceID(copy)
        let real = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-check", sourceID: sourceID)
        // A wallet smaller than the adjustment must be refused, not clamped: the
        // guard is the same one a real plan would hit.
        var uncovered = real
        uncovered.beforeBalance = -real.deltaPoints - 1
        uncovered.expectedBalance = uncovered.beforeBalance + uncovered.deltaPoints
        #expect(uncovered.expectedBalance < 0)
        uncovered.blockedReason = "조정 후 잔액이 음수입니다(\(uncovered.expectedBalance) P). 사용자 결정이 필요합니다"
        #expect(uncovered.isApplicable == false)
        await #expect(throws: UsageCorrectionError.self) {
            _ = try await copy.applyUsageCorrection(uncovered)
        }
        #expect(try await copy.corrections().isEmpty, "거절된 계획은 아무것도 남기지 않습니다")
        // The real plan on this wallet is still applicable.
        #expect(real.expectedBalance >= 0)
    }
}
