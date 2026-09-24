import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

/// Backup, restore and the collection safety that must follow a restore.
/// Everything runs on temporary roots; no user profile is touched.
@Suite("백업·복원")
struct BackupRestoreTests {
    private struct Fixture {
        var location: StoreLocation
        var tree: OMPFixture.Tree
        var store: PackTraceStore
        var pool: ResolvedPackPool
        var library: CatalogLibrary
    }

    /// A production profile fed by synthetic usage, with one pack opened
    /// halfway and one still sealed.
    private func makeFixture() async throws -> Fixture {
        let harness = try UsageTestSupport.harness()
        let path = "project-a/session.jsonl"
        try harness.tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let base = Int(Date().timeIntervalSince1970 * 1000)
        for (index, id) in [1, 2].enumerated() {
            try harness.tree.append(
                OMPFixture.assistant(
                    responseID: OMPFixture.responseID(id),
                    input: 2_000_000,
                    output: 0,
                    occurredAt: base + index * 1_000,
                    completedAt: base + index * 1_000 + 900
                ) + "\n",
                to: path
            )
        }
        _ = try await harness.drain()

        let library = try harness.store.library
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        let store = harness.store
        let first = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 5).packInstance
        _ = try await store.exchangePack(pool: pool, requestID: ExchangeRequestID(), seed: 6)
        let opening = try await store.openPack(instanceID: first.id, seed: 5)
        _ = try await store.setRevealedCount(openingID: opening.id, count: 3)

        return Fixture(
            location: harness.location,
            tree: harness.tree,
            store: store,
            pool: pool,
            library: library
        )
    }

    private func loadLibrary(_ fixture: Fixture) throws -> CatalogLibrary {
        try CatalogLoader.library(includingLocalDirectories: [fixture.location.catalogDirectory])
    }

    // MARK: - Backup

    @Test("백업은 DB 집계와 일치하고 팩·개봉·카드·usage 상태를 담는다")
    func backupMatchesDatabase() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store

        let result = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )

        // The manifest describes the snapshot it just wrote.
        let snapshot = try SQLiteDatabase(path: result.packageURL
            .appendingPathComponent(BackupManifest.databaseFileName).path)
        let balance = try snapshot.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
        let packs = try snapshot.scalarInt("SELECT COUNT(*) FROM pack_instance") ?? 0
        let owned = try snapshot.scalarInt("SELECT COUNT(*) FROM owned_card_instance") ?? 0
        let openings = try snapshot.scalarInt("SELECT COUNT(*) FROM opening") ?? 0

        let live = try await store.balance()
        #expect(result.manifest.counts.balancePoints == balance)
        #expect(result.manifest.counts.balancePoints == live)
        #expect(result.manifest.counts.sealedPacks == 1)
        #expect(result.manifest.counts.openedPacks == 1)
        #expect(result.manifest.counts.openings == openings)
        #expect(result.manifest.counts.unfinishedOpenings == 1)
        #expect(result.manifest.counts.ownedCards == owned)
        #expect(result.manifest.counts.ownedCards == 10)
        #expect(result.manifest.realm == .production)
        #expect(result.manifest.appSchemaVersion == Int(Schema.currentVersion))
        #expect(result.manifest.usage.events > 0)
        #expect(result.manifest.images.included == false)
        #expect(result.manifest.notes.contains { $0.contains("개인 데이터") })

        // The catalogues the packs are pinned to travel with the backup.
        #expect(!result.manifest.catalogs.isEmpty)
        for reference in result.manifest.catalogs {
            #expect(reference.referencedByPacks > 0)
            let file = try #require(reference.file)
            let url = result.packageURL.appendingPathComponent(file)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try StoreBackup.sha256(of: url) == reference.fileSHA256)
        }
        #expect(try StoreBackup.sha256(of: result.packageURL
            .appendingPathComponent(BackupManifest.databaseFileName)) == result.manifest.databaseSHA256)

        // No partial package was left behind.
        let contents = try FileManager.default.contentsOfDirectory(atPath: fixture.location.backupDirectory.path)
        #expect(!contents.contains { $0.hasSuffix(".partial") })
    }

    @Test("백업 생성 실패는 이전 정상 백업을 덮어쓰지 않는다")
    func failedBackupKeepsPreviousOne() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }

        let first = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: "packs-v1"
        )
        // A cancelled run must leave the first package untouched.
        let error = #expect(throws: StoreBackup.BackupError.self) {
            _ = try StoreBackup.create(
                location: fixture.location,
                library: fixture.library,
                poolVersion: "packs-v1",
                isCancelled: { true }
            )
        }
        _ = error
        let packages = StoreBackup.list(location: fixture.location)
        #expect(packages.count == 1)
        #expect(packages[0].lastPathComponent == first.packageURL.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: first.packageURL
            .appendingPathComponent(BackupManifest.manifestFileName).path))
    }

    @Test("백업은 여러 번 만들 수 있고 서로 구분된다")
    func multipleBackupsAreDistinct() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store

        let first = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: "packs-v1",
            now: Date(timeIntervalSince1970: 1_790_000_000)
        )
        // Change the profile, then back it up again.
        _ = try await store.exchangePack(pool: fixture.pool, requestID: ExchangeRequestID(), seed: 7)
        let second = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: "packs-v1",
            now: Date(timeIntervalSince1970: 1_790_000_100)
        )
        #expect(first.packageURL != second.packageURL)
        #expect(second.manifest.counts.sealedPacks == 2)
        #expect(first.manifest.counts.sealedPacks == 1)
        let packages = StoreBackup.list(location: fixture.location)
        #expect(packages.count == 2)
        #expect(packages[0].lastPathComponent > packages[1].lastPathComponent, "최신 백업이 먼저 옵니다")
    }

    // MARK: - Restore

    @Test("복원은 백업 시점의 지갑·팩·카드·공개 진행도로 되돌린다")
    func restoreReturnsToBackupState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store
        let balanceAtBackup = try await store.balance()
        let awardedAtBackup = try await store.usageTotals().awardedPoints
        let packsAtBackup = try await store.packInstances().count

        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )

        // Change everything after the backup: more usage, more packs, more reveals.
        _ = try await store.exchangePack(pool: fixture.pool, requestID: ExchangeRequestID(), seed: 9)
        let opening = try #require(try await store.openings().first)
        _ = try await store.setRevealedCount(openingID: opening.id, count: 10)
        try fixture.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(2),
                input: 1_000_000,
                output: 0,
                occurredAt: Int(Date().timeIntervalSince1970 * 1000) + 60_000,
                completedAt: Int(Date().timeIntervalSince1970 * 1000) + 61_000
            ) + "\n",
            to: "project-a/session.jsonl"
        )
        let collector = OMPUsageCollector(store: store, limits: .standard)
        _ = try await collector.scan(trigger: .manual)
        let changed = try await store.usageTotals()
        #expect(changed.awardedPoints > 100)

        // Restore.
        await store.close()
        let plan = try StoreRestore.restore(
            packageURL: backup.packageURL,
            location: fixture.location,
            library: fixture.library
        )
        #expect(plan.manifest.counts.balancePoints == balanceAtBackup)

        let restored = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        let restoredBalance = try await restored.balance()
        let restoredPacks = try await restored.packInstances()
        #expect(restoredBalance == balanceAtBackup)
        #expect(restoredPacks.count == packsAtBackup)
        #expect(try await restored.ownedCardInstances().count == 10)
        let unfinished = try await restored.unfinishedOpenings()
        #expect(unfinished.count == 1)
        #expect(unfinished.first?.revealedCount == 3)
        let totals = try await restored.usageTotals()
        #expect(totals.awardedPoints == awardedAtBackup, "usage 누적도 백업 시점으로 돌아갑니다")
        #expect(try await restored.usageSource() == nil, "복원 직후에는 활성 수집 소스가 없습니다")

        // The restored profile requires an explicit reconnect.
        let source = try await restored.latestUsageSource()
        #expect(source?.status == .unconnected)
        #expect(source?.isPaused == true)
        #expect(source?.baselineCompletedAt == nil)
        #expect(source?.lastReason == OMPUsageCollector.restoreReconnectReason)
    }

    @Test("복원은 이미 지급된 사용량을 다시 지급하지 않는다")
    func restoreDoesNotRePayUsage() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store
        let collector = OMPUsageCollector(store: store, limits: .standard)

        // More usage is collected and paid before the backup.
        _ = try await collector.scan(trigger: .manual)
        let paidBeforeBackup = try await store.usageTotals()
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )

        // Usage arrives after the backup and is paid in the live profile.
        let path = "project-a/session.jsonl"
        try fixture.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(5),
                input: 500_000,
                output: 0,
                occurredAt: Int(Date().timeIntervalSince1970 * 1000) + 120_000,
                completedAt: Int(Date().timeIntervalSince1970 * 1000) + 121_000
            ) + "\n",
            to: path
        )
        _ = try await collector.scan(trigger: .manual)
        let paidAfterBackup = try await store.usageTotals()
        #expect(paidAfterBackup.awardedPoints == paidBeforeBackup.awardedPoints + 50)

        // Restore, then reconnect explicitly: the log still holds that event.
        await store.close()
        _ = try StoreRestore.restore(
            packageURL: backup.packageURL,
            location: fixture.location,
            library: fixture.library
        )
        let restored = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        let restoredCollector = OMPUsageCollector(store: restored, limits: .standard)
        let afterRestore = try await restored.usageTotals()
        #expect(afterRestore.awardedPoints == paidBeforeBackup.awardedPoints)

        // No automatic collection happens before the user reconnects.
        let idleScan = try await restoredCollector.scan(trigger: .scheduled)
        #expect(idleScan.skippedReason == "usage_source_unconnected")
        #expect(idleScan.pointsAwarded == 0)
        let stillRestored = try await restored.usageTotals()
        #expect(stillRestored.awardedPoints == afterRestore.awardedPoints)

        // Explicit reconnect baselines everything currently in the log.
        _ = try await restoredCollector.connect(root: fixture.tree.root)
        let afterReconnect = try await restored.usageTotals()
        #expect(
            afterReconnect.awardedPoints == afterRestore.awardedPoints,
            "복원 전에 이미 지급된 이벤트를 다시 지급하면 안 됩니다"
        )
        // The reconnect completed a baseline over the log as it stands, and the
        // records already paid before the backup stayed history.
        #expect(try await restored.usageSource()?.baselineCompletedAt != nil)

        // Only genuinely new usage after the reconnect is paid.
        try fixture.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(9),
                input: 100_000,
                output: 0,
                occurredAt: Int(Date().timeIntervalSince1970 * 1000) + 240_000,
                completedAt: Int(Date().timeIntervalSince1970 * 1000) + 241_000
            ) + "\n",
            to: path
        )
        _ = try await restoredCollector.scan(trigger: .manual)
        let afterNewUsage = try await restored.usageTotals()
        #expect(afterNewUsage.awardedPoints == afterReconnect.awardedPoints + 10)
    }

    @Test("복원 후 재시작·재시도에도 중복 지급이 없다")
    func restoreThenRestartStaysStable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        await store.close()
        _ = try StoreRestore.restore(
            packageURL: backup.packageURL,
            location: fixture.location,
            library: fixture.library
        )

        var totals: UsageTotals?
        for _ in 0..<3 {
            let reopened = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
            let collector = OMPUsageCollector(store: reopened, limits: .standard)
            _ = try await collector.connect(root: fixture.tree.root)
            _ = try await collector.scan(trigger: .scheduled)
            let current = try await reopened.usageTotals()
            if let totals {
                #expect(current.awardedPoints == totals.awardedPoints)
            }
            totals = current
            await reopened.close()
        }
        let finalStore = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await finalStore.balance() > 0)
    }

    @Test("손상·형식 불일치·프로필 불일치 백업은 거절한다")
    func invalidBackupsAreRejected() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        let library = fixture.library

        // Wrong realm.
        let demoLocation = try StoreLocation.temporary(realm: .demo, label: "packtrace-restore-demo")
        let realmError = await captureRestoreError("프로필 불일치") {
            try StoreRestore.inspect(packageURL: backup.packageURL, target: .demo, library: library)
        }
        _ = demoLocation
        guard case .realmMismatch? = realmError else {
            Issue.record("realmMismatch를 기대했습니다: \(String(describing: realmError))")
            return
        }

        // Truncated database file.
        let brokenURL = try copyPackage(backup.packageURL, label: "broken")
        defer { try? FileManager.default.removeItem(at: brokenURL) }
        let databaseURL = brokenURL.appendingPathComponent(BackupManifest.databaseFileName)
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.truncate(atOffset: 2048)
        try handle.close()
        let hashError = await captureRestoreError("해시 불일치") {
            try StoreRestore.inspect(packageURL: brokenURL, target: .production, library: library)
        }
        guard case .hashMismatch? = hashError else {
            Issue.record("hashMismatch를 기대했습니다: \(String(describing: hashError))")
            return
        }

        // Missing database file.
        let missingURL = try copyPackage(backup.packageURL, label: "missing")
        defer { try? FileManager.default.removeItem(at: missingURL) }
        try FileManager.default.removeItem(at: missingURL.appendingPathComponent(BackupManifest.databaseFileName))
        let missingError = await captureRestoreError("파일 누락") {
            try StoreRestore.inspect(packageURL: missingURL, target: .production, library: library)
        }
        guard case .missingFile? = missingError else {
            Issue.record("missingFile을 기대했습니다: \(String(describing: missingError))")
            return
        }

        // Unsupported future format and schema.
        let futureURL = try copyPackage(backup.packageURL, label: "future")
        defer { try? FileManager.default.removeItem(at: futureURL) }
        var manifest = try StoreBackup.loadManifest(packageURL: futureURL)
        manifest.formatVersion = BackupManifest.currentFormatVersion + 1
        try writeManifest(manifest, to: futureURL)
        let formatError = await captureRestoreError("미래 형식") {
            try StoreRestore.inspect(packageURL: futureURL, target: .production, library: library)
        }
        guard case .unsupportedFormat? = formatError else {
            Issue.record("unsupportedFormat를 기대했습니다: \(String(describing: formatError))")
            return
        }
        manifest.formatVersion = BackupManifest.currentFormatVersion
        manifest.appSchemaVersion = Int(Schema.currentVersion) + 1
        try writeManifest(manifest, to: futureURL)
        let schemaError = await captureRestoreError("미래 스키마") {
            try StoreRestore.inspect(packageURL: futureURL, target: .production, library: library)
        }
        guard case .newerSchema? = schemaError else {
            Issue.record("newerSchema를 기대했습니다: \(String(describing: schemaError))")
            return
        }
    }

    @Test("복원에 필요한 카탈로그가 없으면 다른 버전으로 대체하지 않고 거절한다")
    func missingCatalogueIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )

        // A backup referring to a snapshot that neither the app nor the package
        // carries: an unknown set is never opened with a substitute.
        let orphanURL = try copyPackage(backup.packageURL, label: "orphan-catalog")
        defer { try? FileManager.default.removeItem(at: orphanURL) }
        var manifest = try StoreBackup.loadManifest(packageURL: orphanURL)
        manifest.catalogs = [
            BackupManifest.CatalogReference(
                catalogVersion: "tcgdex-unknown-19990101",
                contentHash: "unknown",
                referencedByPacks: 1,
                file: nil,
                fileSHA256: nil
            ),
        ]
        try writeManifest(manifest, to: orphanURL)
        let error = await captureRestoreError("카탈로그 누락") {
            try StoreRestore.inspect(
                packageURL: orphanURL,
                target: .production,
                library: try CatalogLoader.bundledLibrary()
            )
        }
        guard case .missingCatalogue? = error else {
            Issue.record("missingCatalogue를 기대했습니다: \(String(describing: error))")
            return
        }
    }

    @Test("복원 중단은 다음 실행에서 완료 또는 이전 상태로 복구한다")
    func interruptedRestoreIsRecovered() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let store = fixture.store
        let balance = try await store.balance()
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        let preRestore = fixture.location.backupDirectory.appendingPathComponent("pre-restore-test")
        try FileManager.default.createDirectory(at: preRestore, withIntermediateDirectories: true)
        let snapshot = try SQLiteDatabase(path: fixture.location.databaseURL.path)
        try snapshot.backup(to: preRestore.appendingPathComponent(BackupManifest.databaseFileName).path)

        // Marker left behind with the database already swapped in.
        let markerURL = fixture.location.directory.appendingPathComponent("restore.state")
        let marker: [String: String] = [
            "preRestoreDirectory": preRestore.path,
            "createdAt": "2026-09-22T00:00:00Z",
        ]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        await store.close()

        let message = try StoreRestore.recoverIfNeeded(location: fixture.location)
        #expect(message != nil)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        let reopened = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await reopened.balance() == balance)

        // Marker left behind with the database missing: roll back to the copy.
        try FileManager.default.removeItem(at: fixture.location.databaseURL)
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        await reopened.close()
        let rolledBack = try StoreRestore.recoverIfNeeded(location: fixture.location)
        #expect(rolledBack?.contains("되돌렸") == true)
        let afterRollback = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await afterRollback.balance() == balance)
        #expect(try await afterRollback.packInstances().count == 2)
    }

    @Test("다른 프로세스가 쓰는 중이면 복원을 거절한다")
    func restoreRefusesWhileAnotherWriterHoldsTheDatabase() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )

        // Simulate another writer holding an exclusive transaction.
        let otherConnection = try SQLiteDatabase(path: fixture.location.databaseURL.path)
        try otherConnection.execute("BEGIN EXCLUSIVE")
        defer { try? otherConnection.execute("ROLLBACK") }

        let error = await captureRestoreError("사용 중 복원") {
            try StoreRestore.restore(
                packageURL: backup.packageURL,
                location: fixture.location,
                library: fixture.library
            )
        }
        guard case .alreadyInUse? = error else {
            Issue.record("alreadyInUse를 기대했습니다: \(String(describing: error))")
            return
        }
        // The live profile is untouched by the refused restore.
        try otherConnection.execute("ROLLBACK")
        let store = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await store.balance() > 0)
    }

    @Test("앱 규칙을 어긴 백업은 현재 데이터를 건드리지 않고 거절한다")
    func brokenInvariantsAreRefused() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        let liveBalance = try await fixture.store.balance()
        let livePacks = try await fixture.store.packInstances().count

        // A structurally valid SQLite file whose contents break the app's own
        // rules: more cards revealed than the stored result holds. Foreign keys
        // and integrity_check cannot see this, so the domain check must.
        let revealURL = try copyPackage(backup.packageURL, label: "bad-reveal")
        defer { try? FileManager.default.removeItem(at: revealURL) }
        let revealDatabase = revealURL.appendingPathComponent(BackupManifest.databaseFileName)
        do {
            let database = try SQLiteDatabase(path: revealDatabase.path)
            try database.execute("UPDATE opening SET revealed_count = json_array_length(result_json) + 5")
        }
        var manifest = try StoreBackup.loadManifest(packageURL: revealURL)
        manifest.databaseSHA256 = try StoreBackup.sha256(of: revealDatabase)
        try writeManifest(manifest, to: revealURL)

        let revealError = await captureRestoreError("공개 진행도 초과") {
            try StoreRestore.restore(
                packageURL: revealURL,
                location: fixture.location,
                library: fixture.library
            )
        }
        guard case .invariantViolation? = revealError else {
            Issue.record("invariantViolation를 기대했습니다: \(String(describing: revealError))")
            return
        }

        // A pack with no ledger entry behind it: the file is a valid database,
        // and foreign_key_check still finds the missing parent row.
        let orphanURL = try copyPackage(backup.packageURL, label: "orphan-pack")
        defer { try? FileManager.default.removeItem(at: orphanURL) }
        let orphanDatabase = orphanURL.appendingPathComponent(BackupManifest.databaseFileName)
        do {
            let database = try SQLiteDatabase(path: orphanDatabase.path)
            try database.execute("PRAGMA foreign_keys = OFF")
            try database.execute(
                """
                DELETE FROM wallet_entry WHERE entry_id IN (
                    SELECT exchange_entry_id FROM pack_instance WHERE exchange_entry_id IS NOT NULL
                )
                """
            )
        }
        manifest.databaseSHA256 = try StoreBackup.sha256(of: orphanDatabase)
        try writeManifest(manifest, to: orphanURL)

        let orphanError = await captureRestoreError("교환 장부 없는 팩") {
            try StoreRestore.restore(
                packageURL: orphanURL,
                location: fixture.location,
                library: fixture.library
            )
        }
        guard case .corrupted? = orphanError else {
            Issue.record("corrupted를 기대했습니다: \(String(describing: orphanError))")
            return
        }

        // A production backup carrying a development grant is refused too.
        let grantURL = try copyPackage(backup.packageURL, label: "demo-grant")
        defer { try? FileManager.default.removeItem(at: grantURL) }
        let grantDatabase = grantURL.appendingPathComponent(BackupManifest.databaseFileName)
        do {
            let database = try SQLiteDatabase(path: grantDatabase.path)
            try database.transaction {
                try database.run(
                    """
                    INSERT INTO wallet_entry (entry_id, idempotency_key, delta_points, reason, ref, created_at)
                    VALUES (?, ?, ?, ?, NULL, ?)
                    """,
                    [
                        .text("test-grant-entry"),
                        .text("test-grant-key"),
                        .int(500),
                        .text(WalletReason.demoInitialGrant.rawValue),
                        .double(Date().timeIntervalSince1970),
                    ]
                )
            }
        }
        manifest.databaseSHA256 = try StoreBackup.sha256(of: grantDatabase)
        try writeManifest(manifest, to: grantURL)

        let grantError = await captureRestoreError("production 개발용 지급") {
            try StoreRestore.restore(
                packageURL: grantURL,
                location: fixture.location,
                library: fixture.library
            )
        }
        guard case .invariantViolation? = grantError else {
            Issue.record("invariantViolation를 기대했습니다: \(String(describing: grantError))")
            return
        }

        // Both refusals happened before the swap: the live profile is intact.
        let store = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await store.balance() == liveBalance)
        #expect(try await store.packInstances().count == livePacks)
        #expect(try await store.ownedCardInstances().count == 10)
    }

    // MARK: - helpers


    // MARK: - Interruption during the swap

    /// Stands in for a crash or a power loss at a chosen point of the swap.
    private struct InjectedInterruption: Error, CustomStringConvertible {
        var stage: StoreRestore.Stage
        var description: String { "injected interruption at \(stage)" }
    }

    @Test("교체 직후 중단되면 다음 실행이 복원 상태로 끝내고, 반복 실행에도 중복 적용이 없다")
    func interruptionAfterSwapFinishesOnNextLaunch() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        let backupPacks = backup.manifest.counts.sealedPacks + backup.manifest.counts.openedPacks
        let backupBalance = backup.manifest.counts.balancePoints

        // Move the live profile away from the backup so old and new are distinguishable.
        _ = try await fixture.store.exchangePack(pool: fixture.pool, requestID: ExchangeRequestID(), seed: 9)
        let opening = try #require(try await fixture.store.openings().first)
        _ = try await fixture.store.setRevealedCount(openingID: opening.id, count: 10)
        let changedPacks = try await fixture.store.packInstances().count
        #expect(changedPacks == backupPacks + 1)
        await fixture.store.close()

        // The swap happens, then the process dies before the reconnect marker is
        // applied and cleared.
        let error = await captureAnyError("교체 중단") {
            try StoreRestore.restore(
                packageURL: backup.packageURL,
                location: fixture.location,
                library: fixture.library,
                onStage: { stage in
                    if stage == .swapped { throw InjectedInterruption(stage: stage) }
                }
            )
        }
        let injected = try #require(error as? InjectedInterruption)
        #expect(injected.stage == .swapped)
        let markerURL = fixture.location.directory.appendingPathComponent("restore.state")
        #expect(FileManager.default.fileExists(atPath: markerURL.path), "중단 지점이 남아야 합니다")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.location.directory.appendingPathComponent("restore-staging.sqlite").path
        ))

        // The next launch completes the swap instead of opening a half-applied profile.
        let notice = try StoreRestore.recoverIfNeeded(location: fixture.location)
        #expect(notice?.contains("완료") == true)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        let recovered = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await recovered.balance() == backupBalance)
        #expect(try await recovered.packInstances().count == backupPacks)
        let recoveredOpening = try #require(try await recovered.openings().first)
        #expect(recoveredOpening.revealedCount == 3)
        let source = try await recovered.latestUsageSource()
        #expect(source?.status == .unconnected)
        #expect(source?.lastReason == OMPUsageCollector.restoreReconnectReason)

        // The recovered profile satisfies the same rules a restore checks, so a
        // ledger from one state and packs from another cannot be opened as normal.
        try StoreRestore.checkIntegrity(databaseURL: fixture.location.databaseURL)
        try StoreRestore.checkDomainInvariants(
            databaseURL: fixture.location.databaseURL,
            realm: .production,
            library: try loadLibrary(fixture)
        )

        // Running recovery again changes nothing.
        #expect(try StoreRestore.recoverIfNeeded(location: fixture.location) == nil)
        #expect(try await recovered.balance() == backupBalance)
        #expect(try await recovered.packInstances().count == backupPacks)
        await recovered.close()
    }

    @Test("백업 패키지는 DB 한 파일과 매니페스트만 담고, 지울 때는 백업 폴더 안의 패키지만 지운다")
    func packagesAreSelfContainedAndDeletionIsScoped() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: backup.packageURL.path)
        #expect(!names.contains { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") || $0.hasSuffix("-journal") },
                "패키지에 SQLite 부속 파일이 섞이면 안 됩니다: \(names)")
        // The hash in the manifest is the file as published.
        let database = backup.packageURL.appendingPathComponent(backup.manifest.databaseFile)
        #expect(try StoreBackup.sha256(of: database) == backup.manifest.databaseSHA256)

        // A sibling directory whose name merely starts like the backup directory
        // is not inside it.
        let sibling = URL(fileURLWithPath: fixture.location.backupDirectory.path + "-old", isDirectory: true)
            .appendingPathComponent("x.\(BackupManifest.packageExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) {
            try StoreBackup.delete(packageURL: sibling, location: fixture.location)
        }
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        try StoreBackup.delete(packageURL: backup.packageURL, location: fixture.location)
        #expect(!FileManager.default.fileExists(atPath: backup.packageURL.path))

        // A manifest may not name a file outside its own package.
        #expect(StoreBackup.fileInside(backup.packageURL, named: "../../packtrace.sqlite") == nil)
        #expect(StoreBackup.fileInside(backup.packageURL, named: "/etc/hosts") == nil)
        #expect(StoreBackup.fileInside(backup.packageURL, named: "catalogs/a.json") != nil)
    }

    @Test("표시만 남기고 교체 전에 중단되면, 다음 실행은 기존 DB를 복원본으로 오인하지 않는다")
    func interruptionAfterTheMarkerKeepsTheOldProfile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        // The live profile moves on after the backup.
        _ = try await fixture.store.exchangePack(pool: fixture.pool, requestID: ExchangeRequestID(), seed: 9)
        let livePacks = try await fixture.store.packInstances().count
        let liveBalance = try await fixture.store.balance()
        let liveSource = try await fixture.store.latestUsageSource()
        await fixture.store.close()

        // The marker is written, then the process dies before the swap.
        let error = await captureAnyError("표시 직후 중단") {
            try StoreRestore.restore(
                packageURL: backup.packageURL,
                location: fixture.location,
                library: fixture.library,
                onStage: { stage in
                    if stage == .markerWritten { throw InjectedInterruption(stage: stage) }
                }
            )
        }
        #expect((error as? InjectedInterruption)?.stage == .markerWritten)
        let markerURL = fixture.location.directory.appendingPathComponent("restore.state")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        let notice = try StoreRestore.recoverIfNeeded(location: fixture.location)
        #expect(notice?.contains("기존 상태") == true, "\(notice ?? "nil")")
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: fixture.location.directory.appendingPathComponent("restore-staging.sqlite").path
        ))

        // The profile is the live one, untouched: no restore applied, and its
        // usage source was not forced to reconnect.
        let reopened = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await reopened.packInstances().count == livePacks)
        #expect(try await reopened.balance() == liveBalance)
        let source = try await reopened.latestUsageSource()
        #expect(source?.status == liveSource?.status)
        #expect(source?.lastReason != OMPUsageCollector.restoreReconnectReason)
        await reopened.close()
    }

    @Test("교체 전에 중단되면 기존 상태가 그대로 남고 앱이 정상적으로 열린다")
    func interruptionBeforeSwapKeepsTheOldState() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        _ = try await fixture.store.exchangePack(pool: fixture.pool, requestID: ExchangeRequestID(), seed: 11)
        let balance = try await fixture.store.balance()
        let packs = try await fixture.store.packInstances().count
        let sourceBefore = try await fixture.store.usageSource()
        await fixture.store.close()

        let error = await captureAnyError("교체 전 중단") {
            try StoreRestore.restore(
                packageURL: backup.packageURL,
                location: fixture.location,
                library: fixture.library,
                onStage: { stage in
                    if stage == .replacing { throw InjectedInterruption(stage: stage) }
                }
            )
        }
        let injected = try #require(error as? InjectedInterruption)
        #expect(injected.stage == .replacing)

        // Nothing was replaced, no marker was left, and no recovery is needed.
        let markerURL = fixture.location.directory.appendingPathComponent("restore.state")
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(try StoreRestore.recoverIfNeeded(location: fixture.location) == nil)

        let store = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(try await store.balance() == balance)
        #expect(try await store.packInstances().count == packs)
        let source = try await store.usageSource()
        #expect(source?.rootPath == sourceBefore?.rootPath)
        #expect(source?.lastReason != OMPUsageCollector.restoreReconnectReason)
        try StoreRestore.checkIntegrity(databaseURL: fixture.location.databaseURL)
        await store.close()
    }

    @Test("백업에 동봉된 카탈로그로 앱이 모르는 판본의 팩도 복원한다")
    func packagedCatalogueKeepsOlderPacksOpenable() async throws {
        let fixture = try await makeFixture()
        defer { fixture.tree.remove() }
        let pinned = try #require(try await fixture.store.packInstances().first?.catalogVersion)
        let backup = try StoreBackup.create(
            location: fixture.location,
            library: fixture.library,
            poolVersion: fixture.pool.poolVersion
        )
        #expect(backup.manifest.catalogs.contains { $0.catalogVersion == pinned })
        await fixture.store.close()

        // An app that no longer ships that snapshot: the package must carry it.
        let slimLibrary = try CatalogLibrary(catalogs: [Fixtures.syntheticCatalog(catalogVersion: "slim-v1")])
        let plan = try StoreRestore.restore(
            packageURL: backup.packageURL,
            location: fixture.location,
            library: slimLibrary
        )
        #expect(plan.catalogVersions.contains(pinned))
        let installed = fixture.location.catalogDirectory.appendingPathComponent("\(pinned).json")
        #expect(FileManager.default.fileExists(atPath: installed.path))

        // The restored profile can still open its own packs through the installed snapshot.
        let restored = try PackTraceStore(location: fixture.location, library: try loadLibrary(fixture))
        #expect(restored.library.catalog(version: pinned) != nil)
        let pack = try #require(try await restored.packInstances().first)
        #expect(pack.catalogVersion == pinned)
        let opening = try await restored.openPack(instanceID: pack.id, seed: 3)
        #expect(opening.cards.count == 10)
        await restored.close()
    }

    private func copyPackage(_ source: URL, label: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-\(label)-\(UUID().uuidString.lowercased())")
            .appendingPathExtension(BackupManifest.packageExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func writeManifest(_ manifest: BackupManifest, to packageURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest)
            .write(to: packageURL.appendingPathComponent(BackupManifest.manifestFileName))
    }
}

/// `captureError` covers `PackTraceError`; restore failures use their own type.
func captureRestoreError<T>(
    _ label: String,
    _ body: () throws -> T
) async -> StoreRestore.RestoreError? {
    do {
        _ = try body()
        Issue.record("\(label): 예외가 발생하지 않았습니다")
        return nil
    } catch let error as StoreRestore.RestoreError {
        return error
    } catch {
        Issue.record("\(label): 예상과 다른 오류 \(error)")
        return nil
    }
}

/// `captureRestoreError` only accepts `RestoreError`; an injected interruption
/// is a different type on purpose.
private func captureAnyError<T>(
    _ label: String,
    _ body: () throws -> T
) async -> (any Error)? {
    do {
        _ = try body()
        Issue.record("\(label): 예외가 발생하지 않았습니다")
        return nil
    } catch {
        return error
    }
}
