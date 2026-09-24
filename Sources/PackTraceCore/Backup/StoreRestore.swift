import Foundation

/// Restores a profile from a backup package.
///
/// Restoring replaces the profile with the backup's snapshot; it never merges.
/// The current data is only replaced after the staged copy passes every check,
/// and a restore marker lets the next launch finish or roll back a swap that
/// was interrupted.
public enum StoreRestore {
    public enum RestoreError: Error, CustomStringConvertible {
        case unsupportedFormat(Int)
        case newerSchema(Int)
        case realmMismatch(expected: Realm, actual: Realm)
        case missingFile(String)
        case hashMismatch(String)
        case corrupted(String)
        case invariantViolation(String)
        case missingCatalogue(String)
        case alreadyInUse(String)
        case replacementInProgress(String)

        public var description: String {
            switch self {
            case let .unsupportedFormat(version): "지원하지 않는 백업 형식입니다: \(version)"
            case let .newerSchema(version): "이 앱보다 새로운 스키마 백업입니다: \(version)"
            case let .realmMismatch(expected, actual):
                "백업 프로필이 다릅니다. 이 백업은 \(actual.displayName)용이고 대상은 \(expected.displayName)입니다."
            case let .missingFile(name): "백업에 필요한 파일이 없습니다: \(name)"
            case let .hashMismatch(name): "백업 파일이 손상되었습니다(해시 불일치): \(name)"
            case let .corrupted(detail): "백업 데이터베이스가 손상되었습니다: \(detail)"
            case let .invariantViolation(detail): "복원할 데이터가 앱 규칙을 만족하지 않습니다: \(detail)"
            case let .missingCatalogue(version):
                "복원에 필요한 카탈로그를 찾을 수 없습니다: \(version). 다른 버전으로 대체 개봉하지 않습니다."
            case let .alreadyInUse(detail): "다른 프로세스가 이 데이터를 쓰고 있어 복원을 진행하지 않았습니다: \(detail)"
            case let .replacementInProgress(detail): "이전 복원이 중단된 상태입니다: \(detail)"
            }
        }
    }

    public enum Stage: Sendable, Hashable {
        case readOnlyValidation
        case domainChecks
        /// Catalogue snapshots are installed. Nothing has been replaced yet.
        case cataloguesInstalled
        case replacing
        /// The marker naming the staged database is written; the live database
        /// has not been touched yet.
        case markerWritten
        /// The staged database is in place; only the reconnect marker remains.
        case swapped
        case reopened
    }

    public struct Plan: Sendable {
        public var manifest: BackupManifest
        /// Snapshots the package carries that the running app does not ship.
        public var catalogURLs: [URL]
        public var catalogVersions: [String]
        public var catalogContents: [PackCatalog]

        /// The library this restore must be checked against: what the app has,
        /// plus what the backup brought with it.
        public func effectiveLibrary(base: CatalogLibrary) throws -> CatalogLibrary {
            try base.adding(catalogContents)
        }
    }

    /// Reads and checks a package without touching the profile.
    public static func inspect(
        packageURL: URL,
        target: Realm,
        library: CatalogLibrary
    ) throws -> Plan {
        let manifest = try StoreBackup.loadManifest(packageURL: packageURL)
        guard manifest.formatVersion == BackupManifest.currentFormatVersion else {
            throw RestoreError.unsupportedFormat(manifest.formatVersion)
        }
        guard manifest.appSchemaVersion <= Int(Schema.currentVersion) else {
            throw RestoreError.newerSchema(manifest.appSchemaVersion)
        }
        guard manifest.realm == target else {
            throw RestoreError.realmMismatch(expected: target, actual: manifest.realm)
        }

        let manager = FileManager.default
        // The package's own files only: a name from the manifest must not reach
        // outside the package.
        guard let databaseURL = StoreBackup.fileInside(packageURL, named: manifest.databaseFile) else {
            throw RestoreError.missingFile(manifest.databaseFile)
        }
        guard manager.fileExists(atPath: databaseURL.path) else {
            throw RestoreError.missingFile(manifest.databaseFile)
        }
        guard try StoreBackup.sha256(of: databaseURL) == manifest.databaseSHA256 else {
            throw RestoreError.hashMismatch(manifest.databaseFile)
        }

        var catalogURLs: [URL] = []
        var versions: [String] = []
        var contents: [PackCatalog] = []
        for reference in manifest.catalogs {
            // The app must be able to open these packs: either the running app
            // ships the snapshot, or the package carries a verified copy.
            if library.catalog(version: reference.catalogVersion) != nil { continue }
            var resolved: URL?
            if let bundled = CatalogLoader.bundledCatalogURL(version: reference.catalogVersion) {
                resolved = bundled
            } else if let file = reference.file {
                guard let url = StoreBackup.fileInside(packageURL, named: file) else {
                    throw RestoreError.missingFile(file)
                }
                guard manager.fileExists(atPath: url.path) else {
                    throw RestoreError.missingFile(file)
                }
                if let expected = reference.fileSHA256, try StoreBackup.sha256(of: url) != expected {
                    throw RestoreError.hashMismatch(file)
                }
                resolved = url
            }
            guard let resolved else {
                throw RestoreError.missingCatalogue(reference.catalogVersion)
            }
            // Keep the verified copy so the restored profile can open its own
            // packs after the app moved on. A snapshot that cannot be parsed is
            // refused instead of being treated as present.
            guard let catalog = try? CatalogLoader.load(contentsOf: resolved) else {
                throw RestoreError.corrupted("카탈로그 스냅샷을 읽을 수 없습니다: \(resolved.lastPathComponent)")
            }
            catalogURLs.append(resolved)
            versions.append(reference.catalogVersion)
            contents.append(catalog)
        }
        return Plan(
            manifest: manifest,
            catalogURLs: catalogURLs,
            catalogVersions: versions,
            catalogContents: contents
        )
    }

    /// Restores `location` from `packageURL`.
    ///
    /// `onStage` lets the caller show progress. Everything that can fail
    /// happens before the swap; a failure leaves the current profile untouched.
    @discardableResult
    public static func restore(
        packageURL: URL,
        location: StoreLocation,
        library: CatalogLibrary,
        now: Date = Date(),
        onStage: (Stage) throws -> Void = { _ in }
    ) throws -> Plan {
        try onStage(.readOnlyValidation)
        let plan = try inspect(packageURL: packageURL, target: location.realm, library: library)

        // A second PackTrace process writing the same profile would make the
        // swap unsafe; refuse instead of guessing.
        try requireExclusiveAccess(location: location)

        let manager = FileManager.default
        try location.prepareDirectories()
        let stagingURL = location.directory.appendingPathComponent("restore-staging.sqlite")
        let preRestoreDirectory = location.backupDirectory
            .appendingPathComponent("pre-restore-\(StoreBackup.preciseTimestamp(now))")
        let markerURL = location.directory.appendingPathComponent("restore.state")
        // A WAL left next to a previous staging copy would be replayed onto this
        // one: the sidecars go with the file, before and after.
        removeDatabaseSidecars(at: stagingURL)
        try? manager.removeItem(at: stagingURL)

        var staged = false
        defer {
            removeDatabaseSidecars(at: stagingURL)
            if !staged {
                try? manager.removeItem(at: stagingURL)
            }
        }

        // 1. Copy the package database aside and migrate it if it is older.
        try manager.copyItem(at: packageURL.appendingPathComponent(plan.manifest.databaseFile), to: stagingURL)
        try migrateIfNeeded(databaseURL: stagingURL, from: plan.manifest.appSchemaVersion)

        // 2. Structural and domain checks on the staged copy. The library used
        //    here includes the snapshots the package carries, so a backup made by
        //    an older app (or opened by a newer one) still validates.
        try onStage(.domainChecks)
        try checkIntegrity(databaseURL: stagingURL)
        let effectiveLibrary = try plan.effectiveLibrary(base: library)
        try checkDomainInvariants(
            databaseURL: stagingURL,
            realm: location.realm,
            library: effectiveLibrary
        )

        // 3. Install catalogue snapshots *before* touching the profile: an extra
        //    snapshot is inert (nothing references it) whereas a missing one would
        //    leave a restored profile unable to open its own packs. This keeps the
        //    window in which an interruption can mix old and new state down to
        //    database-only work.
        for (index, url) in plan.catalogURLs.enumerated() {
            let destination = location.catalogDirectory
                .appendingPathComponent("\(plan.catalogVersions[index]).json")
            try manager.createDirectory(at: location.catalogDirectory, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: destination.path) {
                try manager.copyItem(at: url, to: destination)
            }
        }
        try onStage(.cataloguesInstalled)

        // 4. Preserve the current profile, then swap.
        try onStage(.replacing)
        try manager.createDirectory(at: preRestoreDirectory, withIntermediateDirectories: true)
        if manager.fileExists(atPath: location.databaseURL.path) {
            let snapshot = try SQLiteDatabase(path: location.databaseURL.path)
            try snapshot.backup(to: preRestoreDirectory.appendingPathComponent(BackupManifest.databaseFileName).path)
        }
        // The staged database carries a token the marker names, so recovery can
        // tell the restored database from the one it was meant to replace. Without
        // it, an interruption between the marker and the swap left the old
        // database under a marker, and recovery "completed" a restore that never
        // happened — forcing every source to reconnect on the old data.
        let token = UUID().uuidString.lowercased()
        try writeRestoreToken(token, databaseURL: stagingURL)
        try writeMarker(
            markerURL,
            state: RestoreMarker(
                preRestoreDirectory: preRestoreDirectory.path,
                createdAt: now.packTraceTimestamp,
                restoreToken: token
            )
        )
        try onStage(.markerWritten)

        removeDatabaseSidecars(at: location.databaseURL)
        if manager.fileExists(atPath: location.databaseURL.path) {
            // One rename: there is no moment without a database file.
            _ = try manager.replaceItemAt(location.databaseURL, withItemAt: stagingURL)
        } else {
            try manager.moveItem(at: stagingURL, to: location.databaseURL)
        }
        staged = true
        try onStage(.swapped)

        // 5. From here on the profile holds the backup's data. The remaining work
        //    is a single write, so an interruption leaves either the old state or
        //    the restored state, and the marker finishes the job next launch.
        try requireReconnect(databaseURL: location.databaseURL, reason: "restore_requires_reconnect")
        try? manager.removeItem(at: markerURL)

        try onStage(.reopened)
        return plan
    }

    /// Completes or rolls back a swap that was interrupted by a crash.
    public static func recoverIfNeeded(location: StoreLocation) throws -> String? {
        let markerURL = location.directory.appendingPathComponent("restore.state")
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(RestoreMarker.self, from: data)
        else { return nil }

        let manager = FileManager.default
        let databaseExists = manager.fileExists(atPath: location.databaseURL.path)
        let preRestore = URL(fileURLWithPath: marker.preRestoreDirectory)
            .appendingPathComponent(BackupManifest.databaseFileName)

        if databaseExists, (try? checkIntegrity(databaseURL: location.databaseURL)) != nil {
            if let token = marker.restoreToken, (try? restoreToken(databaseURL: location.databaseURL)) != token {
                // The database in place is not the staged one: the interruption
                // came before the swap, and the profile is exactly as it was.
                try? manager.removeItem(at: markerURL)
                removeDatabaseSidecars(at: location.directory.appendingPathComponent("restore-staging.sqlite"))
                try? manager.removeItem(at: location.directory.appendingPathComponent("restore-staging.sqlite"))
                return "복원이 적용되기 전에 중단되어 기존 상태를 그대로 두었습니다."
            }
            // The swap completed; finish the remaining steps.
            try requireReconnect(databaseURL: location.databaseURL, reason: "restore_requires_reconnect")
            try? manager.removeItem(at: markerURL)
            return "복원이 완료된 상태로 확인했습니다."
        }
        if manager.fileExists(atPath: preRestore.path) {
            try manager.createDirectory(at: location.directory, withIntermediateDirectories: true)
            removeDatabaseSidecars(at: location.databaseURL)
            try? manager.removeItem(at: location.databaseURL)
            try manager.copyItem(at: preRestore, to: location.databaseURL)
            try? manager.removeItem(at: markerURL)
            return "복원이 중단되어 이전 상태로 되돌렸습니다."
        }
        try? manager.removeItem(at: markerURL)
        throw RestoreError.replacementInProgress("이전 상태와 복원본을 모두 찾지 못했습니다.")
    }

    // MARK: - Steps

    struct RestoreMarker: Codable {
        var preRestoreDirectory: String
        var createdAt: String
        /// Names the staged database (`meta.restore_token`). Absent in markers
        /// written before it existed; those keep the old recovery rule.
        var restoreToken: String?
    }

    static let restoreTokenKey = "restore_token"

    static func writeRestoreToken(_ token: String, databaseURL: URL) throws {
        let database = try SQLiteDatabase(path: databaseURL.path)
        defer { database.close() }
        try database.run(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
            [.text(restoreTokenKey), .text(token)]
        )
        // Fold the write into the main file: the staged database is moved as a
        // single file, without its WAL.
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    static func restoreToken(databaseURL: URL) throws -> String? {
        // A normal connection: after a crash the WAL sidecars may be missing, and
        // recovery writes to this database next anyway.
        let database = try SQLiteDatabase(path: databaseURL.path)
        defer { database.close() }
        return try database.query("SELECT value FROM meta WHERE key = ?", [.text(restoreTokenKey)]) { $0.text(at: 0) }.first
    }

    static func requireExclusiveAccess(location: StoreLocation) throws {
        guard FileManager.default.fileExists(atPath: location.databaseURL.path) else { return }
        let database = try SQLiteDatabase(path: location.databaseURL.path)
        do {
            try database.execute("BEGIN EXCLUSIVE")
            try database.execute("ROLLBACK")
        } catch {
            throw RestoreError.alreadyInUse("다른 프로세스가 데이터베이스를 잠그고 있습니다.")
        }
    }

    static func migrateIfNeeded(databaseURL: URL, from version: Int) throws {
        if version < Int(Schema.currentVersion) {
            let database = try SQLiteDatabase(path: databaseURL.path)
            try Schema.migrate(database)
        }
    }

    static func checkIntegrity(databaseURL: URL) throws {
        let database = try SQLiteDatabase(path: databaseURL.path)
        let integrity = try database.query("PRAGMA integrity_check", []) { $0.text(at: 0) }
        guard integrity == ["ok"] else {
            throw RestoreError.corrupted("integrity_check: \(integrity.prefix(2).joined(separator: ", "))")
        }
        let foreignKeys = try database.query("PRAGMA foreign_key_check", []) { statement in
            "\(statement.text(at: 0)):\(statement.int(at: 1))"
        }
        guard foreignKeys.isEmpty else {
            throw RestoreError.corrupted("foreign_key_check: \(foreignKeys.prefix(3).joined(separator: ", "))")
        }
    }

    /// Application-level invariants: the checks a database can hold even when
    /// SQLite itself is happy.
    static func checkDomainInvariants(
        databaseURL: URL,
        realm: Realm,
        library: CatalogLibrary
    ) throws {
        let database = try SQLiteDatabase(path: databaseURL.path)

        let balance = try database.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
        guard balance >= 0 else {
            throw RestoreError.invariantViolation("잔액이 음수입니다: \(balance)")
        }
        guard database.userVersion <= Schema.currentVersion else {
            throw RestoreError.newerSchema(Int(database.userVersion))
        }
        if realm == .production {
            let demoGrant = try database.scalarInt(
                "SELECT COUNT(*) FROM wallet_entry WHERE reason = ?",
                [.text(WalletReason.demoInitialGrant.rawValue)]
            ) ?? 0
            guard demoGrant == 0 else {
                throw RestoreError.invariantViolation("production 백업에 개발용 지급 기록이 있습니다")
            }
        }

        // Every rewarded pack must have been charged by exactly one request, and
        // every request must point at a pack that exists.
        let orphanPacks = try database.scalarInt(
            """
            SELECT COUNT(*) FROM pack_instance p
            WHERE NOT EXISTS (SELECT 1 FROM wallet_entry w WHERE w.entry_id = p.exchange_entry_id)
            """
        ) ?? 0
        guard orphanPacks == 0 else {
            throw RestoreError.invariantViolation("교환 장부가 없는 팩이 \(orphanPacks)개 있습니다")
        }
        let danglingRequests = try database.scalarInt(
            """
            SELECT COUNT(*) FROM pack_request r
            WHERE NOT EXISTS (SELECT 1 FROM pack_instance p WHERE p.instance_id = r.instance_id)
            """
        ) ?? 0
        guard danglingRequests == 0 else {
            throw RestoreError.invariantViolation("가리키는 팩이 없는 교환 요청이 \(danglingRequests)개 있습니다")
        }

        // Openings and their cards must agree in both directions.
        let orphanOwned = try database.scalarInt(
            """
            SELECT COUNT(*) FROM owned_card_instance o
            WHERE NOT EXISTS (SELECT 1 FROM opening g WHERE g.opening_id = o.opening_id)
            """
        ) ?? 0
        guard orphanOwned == 0 else {
            throw RestoreError.invariantViolation("개봉 기록이 없는 소유 카드가 \(orphanOwned)개 있습니다")
        }
        let openedWithoutCards = try database.scalarInt(
            """
            SELECT COUNT(*) FROM opening g
            WHERE NOT EXISTS (SELECT 1 FROM owned_card_instance o WHERE o.opening_id = g.opening_id)
            """
        ) ?? 0
        guard openedWithoutCards == 0 else {
            throw RestoreError.invariantViolation("카드가 없는 개봉 기록이 \(openedWithoutCards)개 있습니다")
        }
        let badReveal = try database.scalarInt(
            "SELECT COUNT(*) FROM opening WHERE revealed_count < 0 OR revealed_count > json_array_length(result_json)"
        ) ?? 0
        guard badReveal == 0 else {
            throw RestoreError.invariantViolation("공개 진행도가 범위를 벗어난 개봉 기록이 \(badReveal)개 있습니다")
        }

        // Packs must stay pinned to a catalogue the app can open.
        let pinned = try database.query(
            "SELECT DISTINCT catalog_version FROM pack_instance", []
        ) { $0.text(at: 0) }
        for version in pinned where library.catalog(version: version) == nil {
            throw RestoreError.missingCatalogue(version)
        }

        let badRemainder = try database.scalarInt(
            "SELECT COUNT(*) FROM reward_state WHERE remainder_tokens < 0 OR remainder_tokens > 10000"
        ) ?? 0
        guard badRemainder == 0 else {
            throw RestoreError.invariantViolation("보상 나머지가 범위를 벗어났습니다")
        }
    }

    /// A restored profile must not silently resume collecting: the collector
    /// stops, the checkpoints go back to zero and the next explicit connect
    /// treats everything currently in the logs as baseline.
    static func requireReconnect(databaseURL: URL, reason: String) throws {
        let database = try SQLiteDatabase(path: databaseURL.path)
        try database.transaction {
            try database.run(
                """
                UPDATE usage_source
                SET status = ?, paused = 1, baseline_completed_at = NULL, last_reason = ?
                """,
                [.text(UsageSourceStatus.unconnected.rawValue), .text(reason)]
            )
            try database.run("UPDATE usage_file_checkpoint SET byte_offset = 0, baseline_done = 0")
            // Cursors for sources that are not files (a database row position)
            // are cleared in the same transaction: after a restore, the next
            // connect has to treat what is there now as baseline, not resume
            // from a position that predates the restore.
            try database.run("DELETE FROM usage_cursor")
        }
    }

    static func writeMarker(_ url: URL, state: RestoreMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func removeDatabaseSidecars(at databaseURL: URL) {
        let manager = FileManager.default
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }
}
