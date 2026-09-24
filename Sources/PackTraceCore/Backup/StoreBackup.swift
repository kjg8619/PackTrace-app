import CryptoKit
import Foundation

/// Creates and inspects backup packages for one profile.
///
/// A package is a directory:
/// ```
/// <realm>/backups/<timestamp>-<realm>.ptbackup/
///     manifest.json          what this backup is and what it should contain
///     packtrace.sqlite       consistent snapshot (SQLite online backup API)
///     catalogs/<version>.json  snapshots the backed-up packs are pinned to
/// ```
/// Creation writes into a `.partial` directory and only renames it into place
/// after the snapshot and its manifest agree, so a failed or cancelled run can
/// never look like a finished backup or replace an older good one.
public enum StoreBackup {
    public enum BackupError: Error, CustomStringConvertible {
        case destinationExists(String)
        case missingSource(String)
        case consistencyMismatch(expected: Int, actual: Int)
        case unsupportedPackage(String)
        case cancelled

        public var description: String {
            switch self {
            case let .destinationExists(path): "백업 대상이 이미 있습니다: \(path)"
            case let .missingSource(path): "백업할 데이터베이스가 없습니다: \(path)"
            case let .consistencyMismatch(expected, actual):
                "백업 스냅샷과 manifest 집계가 일치하지 않습니다(기대 \(expected), 실제 \(actual))"
            case let .unsupportedPackage(path): "이 프로필의 백업 폴더 밖에 있는 항목은 삭제하지 않습니다: \(path)"
            case .cancelled: "백업이 취소되었습니다"
            }
        }
    }

    public struct Result: Sendable {
        public var packageURL: URL
        public var manifest: BackupManifest
    }

    /// Writes a backup of `location`'s database plus the catalogues it needs.
    public static func create(
        location: StoreLocation,
        library: CatalogLibrary,
        poolVersion: String?,
        now: Date = Date(),
        includeCatalogs: Bool = true,
        isCancelled: () -> Bool = { false }
    ) throws -> Result {
        let manager = FileManager.default
        try location.prepareDirectories()
        guard manager.fileExists(atPath: location.databaseURL.path) else {
            throw BackupError.missingSource(location.databaseURL.path)
        }

        let stamp = Self.timestamp(now)
        let name = "\(stamp)-\(location.realm.rawValue)"
        let finalURL = location.backupDirectory.appendingPathComponent(name)
            .appendingPathExtension(BackupManifest.packageExtension)
        let partialURL = location.backupDirectory.appendingPathComponent("\(name).partial")
        guard !manager.fileExists(atPath: finalURL.path) else {
            throw BackupError.destinationExists(finalURL.path)
        }
        try? manager.removeItem(at: partialURL)
        try manager.createDirectory(at: partialURL, withIntermediateDirectories: true)

        var committed = false
        defer {
            if !committed {
                // Never leave a half-written package that could be mistaken for
                // a usable backup.
                try? manager.removeItem(at: partialURL)
            }
        }

        // 1. Consistent database snapshot at a single committed point.
        let databaseURL = partialURL.appendingPathComponent(BackupManifest.databaseFileName)
        let source = try SQLiteDatabase(path: location.databaseURL.path)
        do {
            try source.backup(to: databaseURL.path)
        } catch {
            source.close()
            throw error
        }
        source.close()
        if isCancelled() { throw BackupError.cancelled }

        // 2. Facts taken from the snapshot itself, so counts and the file can
        //    never describe different moments. Every connection to it is closed
        //    before it is hashed and published: the last close folds the WAL back
        //    in and removes `-wal`/`-shm`, which open connections used to leave
        //    inside the package.
        let snapshot = try SQLiteDatabase(path: databaseURL.path)
        defer { snapshot.close() }
        let reference = try catalogReferences(database: snapshot, library: library)
        var manifest = try buildManifest(
            snapshot: snapshot,
            realm: location.realm,
            databaseURL: databaseURL,
            createdAt: now,
            catalogs: reference
        )
        if let poolVersion {
            manifest.poolVersion = poolVersion
        } else {
            // Fall back to whatever the packs themselves record.
            manifest.poolVersion = try snapshot.query(
                "SELECT pool_version FROM pack_instance WHERE pool_version IS NOT NULL ORDER BY rowid LIMIT 1",
                []
            ) { $0.text(at: 0) }.first
        }

        // 3. Catalogue snapshots the packs are pinned to, so a backup stays
        //    openable even after the app ships newer snapshots.
        if includeCatalogs, !reference.isEmpty {
            let catalogDirectory = partialURL.appendingPathComponent(BackupManifest.catalogsDirectoryName)
            try manager.createDirectory(at: catalogDirectory, withIntermediateDirectories: true)
            for reference in reference {
                guard let catalog = library.catalog(version: reference.catalogVersion) else { continue }
                let fileURL = catalogDirectory.appendingPathComponent("\(catalog.catalogVersion).json")
                // The app's own snapshot, or one an earlier restore installed
                // beside the profile: skipping the latter made a backup of a
                // restored profile unrestorable anywhere that lacks it.
                let installed = location.catalogDirectory.appendingPathComponent("\(catalog.catalogVersion).json")
                guard let sourceURL = CatalogLoader.bundledCatalogURL(version: catalog.catalogVersion)
                    ?? (manager.fileExists(atPath: installed.path) ? installed : nil)
                else {
                    continue
                }
                try manager.copyItem(at: sourceURL, to: fileURL)
                let fileHash = try Self.sha256(of: fileURL)
                let relativePath = "\(BackupManifest.catalogsDirectoryName)/\(fileURL.lastPathComponent)"
                manifest.catalogs = manifest.catalogs.map { entry -> BackupManifest.CatalogReference in
                    guard entry.catalogVersion == catalog.catalogVersion else { return entry }
                    var updated = entry
                    updated.file = relativePath
                    updated.fileSHA256 = fileHash
                    return updated
                }
            }
        }

        snapshot.close()

        // 4. The staged snapshot must still match what the manifest claims.
        let verify = try SQLiteDatabase(path: databaseURL.path)
        let balance = try verify.scalarInt("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry") ?? 0
        verify.close()
        guard balance == manifest.counts.balancePoints else {
            throw BackupError.consistencyMismatch(expected: manifest.counts.balancePoints, actual: balance)
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            try? manager.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
        manifest.databaseSHA256 = try Self.sha256(of: databaseURL)
        manifest.databaseBytes = (try? databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: partialURL.appendingPathComponent(BackupManifest.manifestFileName))

        if isCancelled() { throw BackupError.cancelled }

        // 5. Publish atomically: only now can this look like a backup.
        try manager.moveItem(at: partialURL, to: finalURL)
        committed = true
        return Result(packageURL: finalURL, manifest: manifest)
    }

    /// Backups already present for this profile, newest first.
    public static func list(location: StoreLocation) -> [URL] {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(
            at: location.backupDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return contents
            .filter { $0.pathExtension == BackupManifest.packageExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Removes one package. Only packages that live in this profile's backup
    /// directory can be removed.
    public static func delete(packageURL: URL, location: StoreLocation) throws {
        let directory = location.backupDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        // A package directly inside this profile's backup directory, compared by
        // path components: a prefix test also matched a sibling such as
        // `backups-old/…`.
        guard target.deletingLastPathComponent().path == directory.path,
              target.pathExtension == BackupManifest.packageExtension else {
            throw BackupError.unsupportedPackage(packageURL.path)
        }
        try FileManager.default.removeItem(at: target)
    }

    /// A file inside a package, or nil when `name` would leave it (`..`, an
    /// absolute path, a symbolic link out).
    static func fileInside(_ packageURL: URL, named name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/") else { return nil }
        let root = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = packageURL.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root + "/") else { return nil }
        return candidate
    }

    public static func loadManifest(packageURL: URL) throws -> BackupManifest {
        let url = packageURL.appendingPathComponent(BackupManifest.manifestFileName)
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw PackTraceError.storage("백업 manifest를 읽을 수 없습니다: \(error)")
        }
    }

    static func buildManifest(
        snapshot: SQLiteDatabase,
        realm: Realm,
        databaseURL: URL,
        createdAt: Date,
        catalogs: [BackupManifest.CatalogReference]
    ) throws -> BackupManifest {
        func count(_ sql: String) throws -> Int {
            try snapshot.scalarInt(sql) ?? 0
        }
        let counts = BackupManifest.Counts(
            balancePoints: try count("SELECT COALESCE(SUM(delta_points), 0) FROM wallet_entry"),
            ledgerEntries: try count("SELECT COUNT(*) FROM wallet_entry"),
            sealedPacks: try count("SELECT COUNT(*) FROM pack_instance WHERE state = 'sealed'"),
            openedPacks: try count("SELECT COUNT(*) FROM pack_instance WHERE state = 'opened'"),
            openings: try count("SELECT COUNT(*) FROM opening"),
            unfinishedOpenings: try count(
                "SELECT COUNT(*) FROM opening o JOIN pack_instance p ON p.instance_id = o.pack_instance_id WHERE o.revealed_count < json_array_length(o.result_json)"
            ),
            ownedCards: try count("SELECT COUNT(*) FROM owned_card_instance"),
            packRequests: try count("SELECT COUNT(*) FROM pack_request")
        )
        // Every source in the profile, not just the newest row: a backup that
        // recorded one tool would silently drop the others' connections.
        let sources = try snapshot.query(
            """
            SELECT tool_kind, root_path, status, baseline_completed_at, tool_version, format_version
            FROM usage_source
            ORDER BY tool_kind ASC, connected_at ASC
            """,
            []
        ) { statement in
            BackupManifest.UsageState.Source(
                tool: statement.text(at: 0),
                rootPath: statement.optionalText(at: 1),
                status: statement.text(at: 2),
                baselineCompleted: statement.optionalText(at: 3) != nil,
                toolVersion: statement.optionalText(at: 4),
                formatVersion: statement.optionalText(at: 5)
            )
        }
        let connectedSources = sources.filter { (source: BackupManifest.UsageState.Source) in source.status != UsageSourceStatus.unconnected.rawValue }
        let usage = BackupManifest.UsageState(
            connected: !connectedSources.isEmpty,
            rootConfigured: connectedSources.contains { $0.rootPath != nil },
            baselineCompleted: connectedSources.contains { $0.baselineCompleted },
            checkpoints: try count("SELECT COUNT(*) FROM usage_file_checkpoint"),
            events: try count("SELECT COUNT(*) FROM usage_event"),
            aliases: try count("SELECT COUNT(*) FROM usage_event_alias"),
            sources: sources
        )

        return BackupManifest(
            formatVersion: BackupManifest.currentFormatVersion,
            appSchemaVersion: Int(snapshot.userVersion),
            createdAt: createdAt.packTraceTimestamp,
            realm: realm,
            databaseFile: BackupManifest.databaseFileName,
            databaseSHA256: "",
            databaseBytes: 0,
            counts: counts,
            catalogs: catalogs,
            poolVersion: nil,
            usage: usage,
            images: BackupManifest.ImagePolicy(
                included: false,
                note: "카드 이미지는 다시 받을 수 있는 캐시라 백업에 포함하지 않습니다. 복원 후 오프라인이면 일부 이미지가 비어 있을 수 있고, 이름·번호·희귀도·수량은 그대로 남습니다."
            ),
            notes: [
                "이 백업은 PackTrace 프로필 데이터베이스 전체를 담습니다. 프로필 DB에는 OMP 로그 폴더 경로와 사용량 메타데이터(식별자·토큰 수·처리 상태)가 들어 있으므로 개인 데이터로 다루세요.",
                "복원하면 현재 프로필이 백업 시점으로 되돌아가고, 백업 이후의 적립·구매·획득 기록은 사라질 수 있습니다.",
                "복원 후에는 OMP 수집을 다시 연결해야 하며, 그 전까지는 자동으로 적립하지 않습니다. 재연결 시 현재 로그는 기준선으로만 기록하고 이후 새 사용량부터 적립합니다.",
            ]
        )
    }

    /// Catalogue snapshots the backed-up packs are pinned to, taken from the
    /// database rather than from whatever the app happens to bundle.
    static func catalogReferences(
        database: SQLiteDatabase,
        library: CatalogLibrary
    ) throws -> [BackupManifest.CatalogReference] {
        let rows = try database.query(
            "SELECT catalog_version, COUNT(*) FROM pack_instance GROUP BY catalog_version ORDER BY catalog_version",
            []
        ) { statement in
            (version: statement.text(at: 0), packs: statement.int(at: 1))
        }
        return rows.map { row in
            BackupManifest.CatalogReference(
                catalogVersion: row.version,
                contentHash: library.catalog(version: row.version)?.contentHash ?? "",
                referencedByPacks: row.packs,
                file: nil,
                fileSHA256: nil
            )
        }
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func timestamp(_ date: Date) -> String {
        formatted(date, format: "yyyyMMdd-HHmmss")
    }

    /// Millisecond-resolution stamp for the kept-aside copy a restore writes, so
    /// two restores in the same second keep separate snapshots.
    static func preciseTimestamp(_ date: Date) -> String {
        formatted(date, format: "yyyyMMdd-HHmmss-SSS")
    }

    private static func formatted(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
