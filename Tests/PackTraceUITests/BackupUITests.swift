import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Drives backup and restore the way the settings screen does, against a
/// temporary data root: a real profile, real files, no user data.
@Suite("앱 백업·복원")
@MainActor
struct BackupUITests {
    private func makeEnvironment() throws -> (AppEnvironment, OMPFixture.Tree, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-backup-ui").directory
        // The saved profile wins at bootstrap, so ask for production explicitly:
        // usage rewards only ever live in the production wallet.
        let settings = makeIsolatedSettings()
        settings.lastProfile = .production
        let environment = AppEnvironment(realm: .production, locationRoot: root, settings: settings)
        return (environment, try OMPFixture.Tree(), root)
    }

    private func usageRecord(_ n: Int, input: Int) -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            input: input,
            output: 0,
            occurredAt: now + n * 1_000,
            completedAt: now + n * 1_000 + 900
        )
    }

    @Test("백업 생성 → 팩 구매·개봉 → 복원 후 화면이 백업 시점으로 돌아온다")
    func restoreReturnsTheVisibleCollectionToTheBackup() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        await environment.bootstrap()
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.connectUsage(root: tree.root)
        try tree.append(usageRecord(1, input: 4_000_000) + "\n", to: path)
        await environment.refreshUsageNow()
        await environment.refresh()

        let balanceBeforeBackup = environment.balance
        #expect(balanceBeforeBackup >= environment.packCostPoints)
        let pack = try #require(await environment.exchangeRandomPack())
        _ = try await environment.openPack(pack.id)
        await environment.refresh()
        #expect(environment.sealedPacks.isEmpty)

        // Backup now holds one sealed pack and no opening.
        await environment.createBackup()
        #expect(environment.backups.count == 1)
        let backup = try #require(environment.backups.first)
        #expect(backup.manifest.counts.sealedPacks == 0)
        #expect(backup.manifest.counts.openedPacks == 1)
        let sealedAtBackup = environment.sealedPacks.count
        let openingsAtBackup = environment.openings.count

        // Change the collection after the backup.
        let second = try #require(await environment.exchangeRandomPack())
        await environment.refresh()
        #expect(environment.sealedPacks.count == sealedAtBackup + 1)
        #expect(environment.openings.count == openingsAtBackup)

        // Restore through the same entry point the settings screen uses.
        await environment.restore(from: backup)
        #expect(environment.lastActionError == nil)
        #expect(environment.balance == balanceBeforeBackup - environment.packCostPoints)
        #expect(environment.sealedPacks.isEmpty)
        #expect(environment.openings.count == openingsAtBackup)
        #expect(environment.allPacks.count == 1)
        #expect(environment.allPacks.first?.id != second.id)

        // The restored profile must be reconnected before it collects again.
        #expect(environment.usage.isConnected == false)
        #expect(environment.usage.requiresReconnect)
        #expect(environment.usage.ompStateLabel == "재연결 필요")
        #expect(environment.usage.rootPath == tree.root.path)
        #expect(environment.usage.awardedPoints > 0)
    }

    @Test("복원 직후에는 자동 수집이 다시 적립하지 않고, 재연결 뒤 새 사용량만 적립한다")
    func automaticCollectionStaysIdleUntilReconnect() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        await environment.bootstrap()
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.connectUsage(root: tree.root)
        try tree.append(usageRecord(1, input: 2_000_000) + "\n", to: path)
        await environment.refreshUsageNow()
        await environment.refresh()
        await environment.createBackup()
        let backup = try #require(environment.backups.first)
        let awardedBefore = environment.usage.awardedPoints

        // Usage that was already paid before the backup stays in the log.
        try tree.append(usageRecord(2, input: 1_000_000) + "\n", to: path)
        await environment.refreshUsageNow()
        #expect(environment.usage.awardedPoints == awardedBefore + 100)

        await environment.restore(from: backup)
        #expect(environment.usage.awardedPoints == awardedBefore)

        // The scheduler and the manual refresh do nothing while disconnected.
        await environment.scheduledUsageScan()
        await environment.refreshUsageNow()
        #expect(environment.usage.awardedPoints == awardedBefore)

        // Reconnect with the stored path, then only new usage is paid.
        let root = try #require(environment.usage.rootPath)
        await environment.connectUsage(root: URL(fileURLWithPath: root))
        #expect(environment.usage.awardedPoints == awardedBefore)
        #expect(environment.usage.baselineComplete)

        try tree.append(usageRecord(3, input: 500_000) + "\n", to: path)
        await environment.refreshUsageNow()
        #expect(environment.usage.awardedPoints == awardedBefore + 50)
    }

    @Test("손상된 백업을 고르면 현재 데이터를 그대로 두고 사유를 보여준다")
    func corruptBackupLeavesTheProfileIntact() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        await environment.bootstrap()
        let path = "project-a/session.jsonl"
        try tree.write(OMPFixture.sessionFile(assistants: []), to: path)
        await environment.connectUsage(root: tree.root)
        try tree.append(usageRecord(1, input: 2_000_000) + "\n", to: path)
        await environment.refreshUsageNow()
        await environment.refresh()
        await environment.createBackup()
        var backup = try #require(environment.backups.first)
        let packed = try #require(await environment.exchangeRandomPack())
        await environment.refresh()
        let balance = environment.balance
        let packs = environment.allPacks.count

        // Damage the packaged database, keeping the manifest as it was.
        let databaseURL = backup.url.appendingPathComponent(BackupManifest.databaseFileName)
        let handle = try FileHandle(forWritingTo: databaseURL)
        try handle.truncate(atOffset: 4096)
        try handle.close()
        backup = AppEnvironment.BackupSummary(url: backup.url, manifest: backup.manifest)

        await environment.restore(from: backup)
        #expect(environment.lastActionError != nil)
        #expect(environment.balance == balance)
        #expect(environment.allPacks.count == packs)
        #expect(environment.allPacks.contains { $0.id == packed.id })
        #expect(environment.store != nil)
    }

    @Test("백업 삭제는 이 프로필의 백업만 지운다")
    func deleteRemovesOnlyThisProfilesBackup() async throws {
        let (environment, tree, _) = try makeEnvironment()
        defer { tree.remove() }
        await environment.bootstrap()
        await environment.createBackup()
        #expect(environment.backups.count == 1)
        let backup = try #require(environment.backups.first)

        environment.deleteBackup(backup)
        #expect(environment.backups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: backup.url.path))
        #expect(environment.lastActionError == nil)
    }
}
