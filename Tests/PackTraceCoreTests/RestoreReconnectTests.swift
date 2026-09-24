import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Restoring a profile whose OMP log is *not* empty, and reconnecting it.
///
/// The log root, the profile root and the backup root are all temporary. Only
/// synthetic OMP-format records are used: no real session file is read, copied
/// or written, and no user profile is opened for writing.
///
/// Token numbers are fixture values for the reward rule (10,000 accepted tokens
/// = 1 P): 1,000,000 → 100 P, 200,000 → 20 P, 10,000 → 1 P.
@Suite("복원 후 재연결 (비어 있지 않은 로그)")
struct RestoreReconnectTests {
    /// Reward rule constants, asserted so a change to the rule fails here loudly
    /// instead of silently invalidating the numbers below.
    private func assertRule() {
        #expect(UsageRewardRule.ompNonCacheV1.tokensPerPoint == 10_000)
    }

    private func event(_ n: Int, input: Int, offsetSeconds: Int) -> String {
        let base = Int(Date().timeIntervalSince1970 * 1000)
        return OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            input: input,
            output: 0,
            occurredAt: base + offsetSeconds * 1_000,
            completedAt: base + offsetSeconds * 1_000 + 900
        ) + "\n"
    }

    private func totals(_ store: PackTraceStore) async throws -> UsageTotals {
        try await store.usageTotals()
    }

    // MARK: - Required scenario

    @Test("100 P 적립 → 백업 → +20 P → 복원 → 재연결 → 새 1 P, 나머지·중복 없음")
    func restoreThenReconnectOnNonEmptyLog() async throws {
        assertRule()
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"

        // 1. An ordinary collection path reaches 100 P.
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()
        let afterFirst = try await totals(harness.store)
        #expect(afterFirst.awardedPoints == 100)
        #expect(afterFirst.remainderTokens == 0)
        #expect(try await harness.store.balance() == 100)

        // 2. Backup B.
        let package = try StoreBackup.create(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary(),
            poolVersion: "packs-v1"
        )
        #expect(package.packageURL.deletingLastPathComponent() == harness.location.backupDirectory)
        #expect(package.manifest.counts.balancePoints == 100)

        // 3. A new event adds 20 P.
        try harness.tree.append(event(2, input: 200_000, offsetSeconds: 60), to: path)
        _ = try await harness.drain()
        let afterSecond = try await totals(harness.store)
        #expect(afterSecond.awardedPoints == 120)
        #expect(try await harness.store.balance() == 120)

        // 4. Restore B: the wallet, the reward remainder and the collection state
        //    all return to the backup point.
        let logBytesBefore = try logBytes(harness.tree.root)
        await harness.store.close()
        _ = try StoreRestore.restore(
            packageURL: package.packageURL,
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let restored = try PackTraceStore(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let restoredTotals = try await totals(restored)
        #expect(restoredTotals.awardedPoints == 100)
        #expect(restoredTotals.remainderTokens == 0)
        #expect(try await restored.balance() == 100)

        // 5. The log still holds every event, byte for byte: the app never edits it.
        #expect(try logBytes(harness.tree.root) == logBytesBefore)

        // 6. Neither the scheduled nor the manual scan pays anything after a restore.
        let restoredCollector = OMPUsageCollector(store: restored, limits: .small)
        let quiet = try await restoredCollector.scan(trigger: .scheduled)
        #expect(quiet.skippedReason == "usage_source_unconnected")
        #expect(quiet.pointsAwarded == 0)
        let manual = try await restoredCollector.scan(trigger: .manual)
        #expect(manual.pointsAwarded == 0)
        #expect(try await totals(restored).awardedPoints == 100)

        // Restarting the app (a new store and collector over the same files) must
        // not collect either: the profile is waiting for an explicit reconnect.
        let afterRestart = try PackTraceStore(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let restartedCollector = OMPUsageCollector(store: afterRestart, limits: .small)
        _ = try await restartedCollector.scan(trigger: .scheduled)
        #expect(try await totals(afterRestart).awardedPoints == 100)
        #expect(try await afterRestart.balance() == 100)

        // 7. The user reconnects explicitly.
        let source = try await restartedCollector.connect(root: harness.tree.root)
        #expect(source.baselineCompletedAt != nil)

        // 8. Everything already in the log is history now: no payment.
        let reconnectTotals = try await totals(afterRestart)
        #expect(reconnectTotals.awardedPoints == 100)
        #expect(try await afterRestart.balance() == 100)
        #expect(try await afterRestart.usageSource()?.status == .collecting)

        // 9-10. Only a brand new event pays, and it pays exactly 1 P.
        try harness.tree.append(event(3, input: 10_000, offsetSeconds: 120), to: path)
        _ = try await restartedCollector.scan(trigger: .manual)
        let afterNew = try await totals(afterRestart)
        #expect(afterNew.awardedPoints == 101)
        #expect(afterNew.remainderTokens == 0)
        #expect(try await afterRestart.balance() == 101)

        // 11. Rescans and a restart add nothing.
        for _ in 0..<3 {
            _ = try await restartedCollector.scan(trigger: .manual)
        }
        let afterRescans = try await totals(afterRestart)
        #expect(afterRescans.awardedPoints == 101)
        #expect(afterRescans.remainderTokens == 0)
        #expect(afterRescans.acceptedEvents == afterNew.acceptedEvents)

        await afterRestart.close()
        let reopened = try PackTraceStore(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let reopenedCollector = OMPUsageCollector(store: reopened, limits: .small)
        _ = try await reopenedCollector.connect(root: harness.tree.root)
        _ = try await reopenedCollector.scan(trigger: .manual)
        let afterRestartTotals = try await totals(reopened)
        #expect(afterRestartTotals.awardedPoints == 101)
        #expect(afterRestartTotals.remainderTokens == 0)
        #expect(try await reopened.balance() == 101)
        await reopened.close()
    }

    // MARK: - Boundaries

    @Test("복원과 재연결 사이에 생긴 기록은 소급 지급하지 않는다")
    func recordsBetweenRestoreAndReconnectAreNotPaid() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()
        #expect(try await totals(harness.store).awardedPoints == 100)

        let package = try StoreBackup.create(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary(),
            poolVersion: "packs-v1"
        )
        await harness.store.close()
        _ = try StoreRestore.restore(
            packageURL: package.packageURL,
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )

        // Work happens while the profile is disconnected, then the user reconnects.
        try harness.tree.append(event(2, input: 500_000, offsetSeconds: 60), to: path)
        let restored = try PackTraceStore(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let collector = OMPUsageCollector(store: restored, limits: .small)
        _ = try await collector.scan(trigger: .scheduled)
        _ = try await collector.connect(root: harness.tree.root)

        let totalsAfter = try await totals(restored)
        #expect(totalsAfter.awardedPoints == 100, "복원 뒤 재연결 전 기록은 지급 대상이 아닙니다")
        #expect(try await restored.balance() == 100)

        // And the same event is not paid later either, when new usage arrives.
        try harness.tree.append(event(3, input: 10_000, offsetSeconds: 120), to: path)
        _ = try await collector.scan(trigger: .manual)
        #expect(try await totals(restored).awardedPoints == 101)
        await restored.close()
    }

    @Test("기준선 도중 중단되면 다음 실행이 이어서 끝내고 이중 지급하지 않는다")
    func baselineInterruptedThenResumed() async throws {
        // One record per slice: the first pass cannot finish the baseline.
        let tiny = OMPLogScanner.Limits(
            maxRecordsPerSlice: 1,
            maxBytesPerSlice: 4 * 1024,
            maxFilesPerSlice: 1,
            maxLineBytes: 64 * 1024,
            chunkBytes: 2 * 1024
        )
        let harness = try UsageTestSupport.harness(limits: tiny)
        defer { harness.tree.remove() }
        // Two files, and a slice budget small enough that the baseline cannot
        // finish in one pass.
        try harness.tree.write(OMPFixture.sessionFile(assistants: [
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(1),
                input: 400_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(0),
                completedAt: OMPFixture.timestamp(1)
            ),
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(2),
                input: 400_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(2),
                completedAt: OMPFixture.timestamp(3)
            ),
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(3),
                input: 400_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(4),
                completedAt: OMPFixture.timestamp(5)
            ),
        ]), to: "project-a/session.jsonl")
        try harness.tree.write(OMPFixture.sessionFile(sessionID: OMPFixture.session2, assistants: [
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(4),
                sessionID: OMPFixture.session2,
                input: 400_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(6),
                completedAt: OMPFixture.timestamp(7)
            ),
        ]), to: "project-b/session.jsonl")

        // The first pass is deliberately left unfinished.
        _ = try await harness.collector.connect(root: harness.tree.root)
        let status = try await harness.collector.status()
        #expect(status.isBaselineComplete == false, "슬라이스 예산이 커지면 이 테스트가 의미를 잃습니다")

        // A restart resumes the baseline and still pays nothing for the history.
        let resumed = OMPUsageCollector(store: harness.store, limits: .small)
        _ = try await resumed.connect(root: harness.tree.root)
        for _ in 0..<40 {
            let summary = try await resumed.scan(trigger: .manual)
            if !summary.moreWork { break }
        }
        let finished = try await harness.store.usageSource()
        #expect(finished?.baselineCompletedAt != nil, "재시작이 기준선을 끝내야 합니다")
        #expect(try await totals(harness.store).awardedPoints == 0)
        #expect(try await harness.store.usageDiagnostics().baselineEvents == 4)

        // New usage after the baseline pays normally and only once.
        try harness.tree.append(event(9, input: 20_000, offsetSeconds: 600), to: "project-a/session.jsonl")
        _ = try await resumed.scan(trigger: .manual)
        #expect(try await totals(harness.store).awardedPoints == 2)
        _ = try await resumed.scan(trigger: .manual)
        #expect(try await totals(harness.store).awardedPoints == 2)
    }

    @Test("복원 뒤 같은 과거 호출이 복제 파일·중복 루트로 다시 나타나도 한 번만 지급한다")
    func duplicatedHistoryAfterRestorePaysOnce() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()
        let package = try StoreBackup.create(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary(),
            poolVersion: "packs-v1"
        )
        await harness.store.close()
        _ = try StoreRestore.restore(
            packageURL: package.packageURL,
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )

        // A copy of the log (same records, new file, new inode) appears, and the
        // new source is connected afterwards.
        let original = try String(contentsOf: harness.tree.root.appendingPathComponent(path), encoding: .utf8)
        try harness.tree.write(original, to: "project-b/copied.jsonl")

        let restored = try PackTraceStore(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary()
        )
        let collector = OMPUsageCollector(store: restored, limits: .small)
        _ = try await collector.connect(root: harness.tree.root)
        let totalsAfter = try await totals(restored)
        #expect(totalsAfter.awardedPoints == 100)

        // New work after the reconnect pays once, even when it is scanned twice
        // and through a second, overlapping root.
        let newEvent = event(2, input: 10_000, offsetSeconds: 120)
        try harness.tree.append(newEvent, to: path)
        _ = try await collector.scan(trigger: .manual)
        #expect(try await totals(restored).awardedPoints == 101)

        // Same root connected again: the checkpoints are kept, so nothing repeats.
        _ = try await collector.connect(root: harness.tree.root)
        _ = try await collector.scan(trigger: .manual)
        #expect(try await totals(restored).awardedPoints == 101)
        await restored.close()
    }

    @Test("같은 백업을 두 번 복원해도 결과와 원본 보존이 같다")
    func restoringTheSameBackupTwiceIsStable() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()
        let package = try StoreBackup.create(
            location: harness.location,
            library: try CatalogLoader.bundledLibrary(),
            poolVersion: "packs-v1"
        )

        var firstLedger: [String] = []
        var open: PackTraceStore?
        for attempt in 0..<2 {
            if attempt == 0 {
                await harness.store.close()
            } else if let current = open {
                await current.close()
            }
            _ = try StoreRestore.restore(
                packageURL: package.packageURL,
                location: harness.location,
                library: try CatalogLoader.bundledLibrary()
            )
            open = try PackTraceStore(
                location: harness.location,
                library: try CatalogLoader.bundledLibrary()
            )
            let ledger = try await open!.ledger(limit: 100)
                .map { "\($0.id.rawValue)|\($0.deltaPoints)|\($0.reason.rawValue)" }
                .sorted()
            if attempt == 0 {
                firstLedger = ledger
            } else {
                #expect(ledger == firstLedger, "두 번째 복원이 장부를 중복 적용했습니다")
            }
            #expect(try await open!.balance() == 100)
            #expect(try await totals(open!).awardedPoints == 100)
        }
        await open?.close()

        // Old snapshots are kept under pre-restore-*, one per restore, so the
        // state before each swap can still be recovered.
        let preRestores = (try? FileManager.default.contentsOfDirectory(
            at: harness.location.backupDirectory,
            includingPropertiesForKeys: nil
        ))?.filter { $0.lastPathComponent.hasPrefix("pre-restore-") } ?? []
        #expect(preRestores.count == 2)
        for directory in preRestores {
            #expect(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(BackupManifest.databaseFileName).path
            ))
        }
    }

    @Test("일반 재시작은 복원과 달리 checkpoint를 유지하고 기준선을 다시 만들지 않는다")
    func plainRestartKeepsCheckpoints() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()
        let before = try await harness.store.usageCheckpoints()
        let sourceBefore = try await harness.store.usageSource()
        #expect(before.allSatisfy { $0.baselineDone })

        // A restart: same store object survives, a new collector connects again.
        let restarted = OMPUsageCollector(store: harness.store, limits: .small)
        _ = try await restarted.connect(root: harness.tree.root)
        let sourceAfter = try await harness.store.usageSource()
        #expect(sourceAfter?.sourceID == sourceBefore?.sourceID, "일반 재시작은 새 source를 만들지 않습니다")
        #expect(sourceAfter?.lastReason != OMPUsageCollector.restoreReconnectReason)

        let after = try await harness.store.usageCheckpoints()
        #expect(after.map(\.byteOffset) == before.map(\.byteOffset))
        #expect(after.map(\.baselineOffset) == before.map(\.baselineOffset))
        #expect(try await totals(harness.store).awardedPoints == 100)
    }

    @Test("복원은 저장된 개봉 결과와 공개 진행도를 보존하고 같은 카드를 다시 뽑지 않는다")
    func restoreKeepsStoredOpeningResult() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(event(1, input: 1_000_000, offsetSeconds: 0), to: path)
        _ = try await harness.drain()

        let library = try CatalogLoader.bundledLibrary()
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        let pack = try await harness.store.exchangePack(
            pool: pool,
            requestID: ExchangeRequestID(),
            seed: 5
        ).packInstance
        let opening = try await harness.store.openPack(instanceID: pack.id, seed: 5)
        _ = try await harness.store.setRevealedCount(openingID: opening.id, count: 4)
        let storedCards = opening.cards

        let package = try StoreBackup.create(
            location: harness.location,
            library: library,
            poolVersion: pool.poolVersion
        )

        // More reveals happen after the backup, then the backup is restored.
        _ = try await harness.store.setRevealedCount(openingID: opening.id, count: 10)
        await harness.store.close()
        _ = try StoreRestore.restore(packageURL: package.packageURL, location: harness.location, library: library)

        let restored = try PackTraceStore(location: harness.location, library: library)
        let restoredOpening = try #require(try await restored.opening(id: opening.id))
        #expect(restoredOpening.cards == storedCards, "저장된 결과가 그대로 남아야 합니다")
        #expect(restoredOpening.revealedCount == 4)
        #expect(try await restored.ownedCardInstances().count == 10)

        // Opening the same pack again returns the stored result, not a new draw.
        let reopened = try await restored.openPack(instanceID: pack.id, seed: 99)
        #expect(reopened.cards == storedCards)
        await restored.close()
    }

    // MARK: - helpers

    /// Every byte under the log root, keyed by relative path: proves the app
    /// treats the logs as read-only.
    private func logBytes(_ root: URL) throws -> [String: Int] {
        let manager = FileManager.default
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var sizes: [String: Int] = [:]
        while let url = enumerator?.nextObject() as? URL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            sizes[relative] = size
        }
        return sizes
    }
}
