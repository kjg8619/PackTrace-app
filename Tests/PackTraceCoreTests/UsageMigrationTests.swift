import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

/// Upgrade safety for the usage store.
///
/// Schema v3 added the inherited-call tables. These tests simulate a database
/// written by the previous version, upgrade it, and prove that nothing already
/// recorded is re-awarded, promoted or lost.
@Suite("사용량 저장소 업그레이드")
struct UsageMigrationTests {
    private func record(_ n: Int, input: Int, output: Int, offset: Int) -> String {
        OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            input: input,
            output: output,
            occurredAt: OMPFixture.timestamp(offset),
            completedAt: OMPFixture.timestamp(offset + 1)
        )
    }

    /// Rewrites the database as schema v2 by dropping the v3 objects.
    private func downgradeToV2(_ location: StoreLocation) throws {
        let database = try SQLiteDatabase(path: location.databaseURL.path)
        try database.execute("DROP TABLE IF EXISTS usage_event_alias")
        try database.execute("DROP TABLE IF EXISTS usage_session")
        try database.execute("DROP INDEX IF EXISTS usage_event_original_call")
        try database.execute("DROP INDEX IF EXISTS usage_event_by_original_call")
        database.userVersion = 2
    }

    private struct Snapshot: Equatable {
        var eventsByStatus: [String: Int]
        var acceptedTokens: Int
        var remainder: Int
        var awardedPoints: Int
        var ledgerSum: Int
        var ledgerCount: Int
        var awards: Int
        var checkpoints: [String]
    }

    private func snapshot(_ store: PackTraceStore) async throws -> Snapshot {
        let diagnostics = try await store.usageDiagnostics()
        let totals = try await store.usageTotals()
        let ledger = try await store.ledger(limit: 500)
        let checkpoints = try await store.usageCheckpoints()
        return Snapshot(
            eventsByStatus: [
                "accepted": diagnostics.acceptedEvents,
                "baseline": diagnostics.baselineEvents,
                "excluded": diagnostics.excludedEvents,
                "unsupported": diagnostics.unsupportedEvents,
            ],
            acceptedTokens: totals.acceptedTokens,
            remainder: totals.remainderTokens,
            awardedPoints: totals.awardedPoints,
            ledgerSum: ledger.reduce(0) { $0 + $1.deltaPoints },
            ledgerCount: ledger.count,
            awards: diagnostics.acceptedEvents,
            checkpoints: checkpoints.map { "\($0.relativePath)|\($0.byteOffset)|\($0.baselineOffset)|\($0.baselineDone)" }.sorted()
        )
    }

    @Test("더 새로운 앱이 만든 스키마는 열지 않고 그대로 둔다")
    func newerSchemaIsNotOpened() async throws {
        let location = try StoreLocation.temporary(realm: .production, label: "packtrace-newer-schema")
        try location.prepareDirectories()
        defer { TestOwnedRoot.remove(location.directory.deletingLastPathComponent()) }
        let library = try CatalogLoader.bundledLibrary()
        let store = try PackTraceStore(location: location, library: library)
        await store.close()

        let raw = try SQLiteDatabase(path: location.databaseURL.path)
        try raw.execute("PRAGMA user_version = \(Int(Schema.currentVersion) + 3)")
        raw.close()

        let error = await captureError("새 스키마") {
            try PackTraceStore(location: location, library: library)
        }
        guard case let .newerSchema(found, supported)? = error else {
            Issue.record("newerSchema를 기대했습니다: \(String(describing: error))")
            return
        }
        #expect(found == Int(Schema.currentVersion) + 3)
        #expect(supported == Int(Schema.currentVersion))
        let check = try SQLiteDatabase(path: location.databaseURL.path)
        #expect(check.userVersion == Schema.currentVersion + 3, "파일은 건드리지 않습니다")
        check.close()
    }

    @Test("이전 버전 DB를 올려도 지급·나머지·기준선·checkpoint가 그대로다")
    func upgradePreservesEverything() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        // Pre-connection history (baseline) plus one rewarded call.
        try harness.tree.write(
            OMPFixture.sessionFile(assistants: [record(1, input: 50_000, output: 50_000, offset: 0)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(record(2, input: 10_000, output: 0, offset: 20) + "\n", to: path)
        _ = try await harness.drain()

        let before = try await snapshot(harness.store)
        #expect(before.awardedPoints == 1)
        #expect(before.eventsByStatus["baseline"] == 1)

        // Simulate a database written by the previous schema version.
        try downgradeToV2(harness.location)

        let upgraded = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        let after = try await snapshot(upgraded)
        #expect(after == before, "업그레이드가 기존 기록을 바꾸면 안 됩니다")

        // Re-reading the same records after the upgrade must not pay again.
        let collector = OMPUsageCollector(store: upgraded, limits: .standard)
        _ = try await collector.scan(trigger: .manual)
        _ = try await collector.scan(trigger: .manual)
        let rescanned = try await snapshot(upgraded)
        #expect(rescanned.awardedPoints == before.awardedPoints)
        #expect(rescanned.remainder == before.remainder)

        // And a fork of the already recorded call is still refused.
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [record(2, input: 10_000, output: 0, offset: 20)]
            ),
            to: "project-a/fork.jsonl"
        )
        _ = try await collector.scan(trigger: .manual)
        let forked = try await upgraded.usageTotals()
        #expect(forked.awardedPoints == before.awardedPoints)
        #expect(forked.acceptedTokens == before.acceptedTokens)
    }

    @Test("업그레이드 후에도 미처리 신규 이벤트는 지급 대상으로 남는다")
    func unprocessedAppendsSurviveUpgrade() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // A call arrives and is never scanned before the upgrade.
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(9),
                input: 10_000,
                output: 0,
                occurredAt: Int(Date().timeIntervalSince1970 * 1000),
                completedAt: Int(Date().timeIntervalSince1970 * 1000) + 1_000
            ) + "\n",
            to: path
        )
        let beforeUpgrade = try await harness.store.usageTotals()
        #expect(beforeUpgrade.awardedPoints == 0)

        try downgradeToV2(harness.location)
        let upgraded = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        let collector = OMPUsageCollector(store: upgraded, limits: .standard)
        _ = try await collector.scan(trigger: .manual)

        let totals = try await upgraded.usageTotals()
        #expect(totals.awardedPoints == 1, "업그레이드가 미처리 신규 이벤트를 버리면 안 됩니다")
        #expect(totals.acceptedTokens == 10_000)
        let diagnostics = try await upgraded.usageDiagnostics()
        #expect(diagnostics.acceptedEvents == 1)
    }


    @Test("업그레이드 도중 실패하면 이전 버전 그대로 남고, 충돌을 없앤 뒤 다시 올리면 보존된다")
    func failedUpgradeRollsBackCompletely() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            OMPFixture.sessionFile(assistants: [record(1, input: 50_000, output: 50_000, offset: 0)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(record(2, input: 10_000, output: 0, offset: 20) + "\n", to: path)
        _ = try await harness.drain()
        let before = try await snapshot(harness.store)
        let sourceBefore = try await harness.store.usageSource()
        await harness.store.close()

        // A database from the previous version, plus an object that makes the
        // upgrade fail halfway: the index is created after the table it indexes.
        try downgradeToV2(harness.location)
        do {
            let database = try SQLiteDatabase(path: harness.location.databaseURL.path)
            try database.execute("CREATE TABLE usage_event_alias_by_original (blocker TEXT)")
        }

        let failure = await captureError("업그레이드 실패") {
            _ = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        }
        #expect(failure != nil, "충돌하는 객체가 있으면 업그레이드가 실패해야 합니다")

        // Nothing from the failed attempt is left behind: the file is still the
        // previous version and no half-created table survives.
        do {
            let database = try SQLiteDatabase(path: harness.location.databaseURL.path)
            #expect(database.userVersion == 2)
            let tables = try database.query(
                "SELECT name FROM sqlite_master WHERE type = 'table'",
                []
            ) { $0.text(at: 0) }
            #expect(!tables.contains("usage_event_alias"), "실패한 업그레이드가 테이블을 남겼습니다")
            #expect(!tables.contains("usage_session"), "실패한 업그레이드가 테이블을 남겼습니다")
            let integrity = try database.query("PRAGMA integrity_check", []) { $0.text(at: 0) }
            #expect(integrity == ["ok"], "실패한 업그레이드 뒤 파일이 손상되면 안 됩니다")
        }

        // Removing the conflict lets the same file upgrade cleanly, with every
        // existing record intact and no new baseline or grant.
        do {
            let database = try SQLiteDatabase(path: harness.location.databaseURL.path)
            try database.execute("DROP TABLE usage_event_alias_by_original")
        }
        let upgraded = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        let after = try await snapshot(upgraded)
        #expect(after == before, "다시 올린 뒤에도 기록이 같아야 합니다")

        let sourceAfter = try await upgraded.usageSource()
        #expect(sourceAfter?.sourceID == sourceBefore?.sourceID)
        #expect(sourceAfter?.status == .collecting, "업그레이드는 복원이 아니므로 재연결을 요구하지 않습니다")
        #expect(sourceAfter?.baselineCompletedAt == sourceBefore?.baselineCompletedAt)
        #expect(sourceAfter?.lastReason != OMPUsageCollector.restoreReconnectReason)
        #expect(try await upgraded.usageSource()?.isPaused == false)
        #expect(try await snapshot(upgraded) == before)

        // And the collection still works: a new call pays exactly once.
        try harness.tree.append(record(3, input: 10_000, output: 0, offset: 40) + "\n", to: path)
        let collector = OMPUsageCollector(store: upgraded, limits: .standard)
        _ = try await collector.scan(trigger: .manual)
        _ = try await collector.scan(trigger: .manual)
        #expect(try await upgraded.usageTotals().awardedPoints == before.awardedPoints + 1)
    }

    @Test("업그레이드는 demo 지갑의 개발용 지급을 다시 하지 않는다")
    func upgradeDoesNotRegrantDemoPoints() async throws {
        let harness = try UsageTestSupport.harness(realm: .demo)
        defer { harness.tree.remove() }
        let granted = try await harness.store.grantInitialDemoPoints()
        #expect(granted == 500)
        let ledgerBefore = try await harness.store.ledger(limit: 50)
        let balanceBefore = try await harness.store.balance()
        await harness.store.close()

        try downgradeToV2(harness.location)
        let upgraded = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        #expect(try await upgraded.balance() == balanceBefore)
        #expect(try await upgraded.ledger(limit: 50).count == ledgerBefore.count)
        #expect(try await upgraded.grantInitialDemoPoints() == nil, "두 번째 지급이 일어났습니다")
        #expect(try await upgraded.balance() == balanceBefore)
    }

    @Test("업그레이드는 반복 실행해도 안전하다")
    func upgradeIsIdempotent() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: "project-a/session.jsonl")
        _ = try await harness.collector.connect(root: harness.tree.root)

        for _ in 0..<3 {
            let store = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
            let totals = try await store.usageTotals()
            #expect(totals.awardedPoints == 0)
        }
        let store = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        let diagnostics = try await store.usageDiagnostics()
        #expect(diagnostics.filesTracked == 1)
    }

    @Test("기존 행에 원본 호출 중복이 있으면 색인만 건너뛰고 행은 보존한다")
    func duplicateOriginalCallsKeepRowsAndStayUnpayable() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(record(1, input: 10_000, output: 0, offset: 20) + "\n", to: path)
        _ = try await harness.drain()
        #expect(try await harness.store.usageTotals().awardedPoints == 1)

        // A database written before the original-call check can hold two rows
        // for one provider call: drop the v3 objects first, then insert it.
        let database = try SQLiteDatabase(path: harness.location.databaseURL.path)
        try database.execute("DROP INDEX IF EXISTS usage_event_original_call")
        try database.execute("DROP INDEX IF EXISTS usage_event_by_original_call")
        try database.execute("DROP TABLE IF EXISTS usage_event_alias")
        try database.execute("DROP TABLE IF EXISTS usage_session")
        database.userVersion = 2
        try database.run(
            "UPDATE usage_event SET event_id = event_id || ':legacy' WHERE status = 'accepted'"
        )
        try database.run(
            """
            INSERT INTO usage_event (
                event_id, source_id, session_id, response_id, provider, model, stop_reason,
                occurred_at, completed_at, input_tokens, output_tokens, cache_read_tokens,
                cache_write_tokens, accepted_tokens, status, reason, fingerprint, first_seen_at
            )
            SELECT event_id || ':dup', source_id, session_id || '-fork', response_id, provider, model, stop_reason,
                   occurred_at, completed_at, input_tokens, output_tokens, cache_read_tokens,
                   cache_write_tokens, accepted_tokens, status, reason, fingerprint, first_seen_at
            FROM usage_event WHERE event_id LIKE '%:legacy'
            """
        )
        let legacyRows = try database.scalarInt("SELECT COUNT(*) FROM usage_event") ?? 0
        #expect(legacyRows == 2)

        // Migration must keep both rows and simply skip the unique index.
        let upgraded = try PackTraceStore(location: harness.location, catalog: CatalogLoader.loadBundled())
        let rowsAfter = try await upgraded.usageRecentEvents(limit: 10)
        #expect(rowsAfter.count == 2, "기존 행은 삭제·병합되지 않습니다")
        let totals = try await upgraded.usageTotals()
        #expect(totals.awardedPoints == 1, "업그레이드가 소급 지급하지 않습니다")

        // The transactional check still refuses a third copy of that call.
        let collector = OMPUsageCollector(store: upgraded, limits: .standard)
        try harness.tree.write(
            OMPFixture.sessionFile(
                sessionID: OMPFixture.session2,
                assistants: [record(1, input: 10_000, output: 0, offset: 20)]
            ),
            to: "project-a/fork.jsonl"
        )
        _ = try await collector.scan(trigger: .manual)
        let after = try await upgraded.usageTotals()
        #expect(after.awardedPoints == 1)
        #expect(after.acceptedTokens == 10_000)
    }
}
