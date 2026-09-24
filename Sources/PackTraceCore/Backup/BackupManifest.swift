import Foundation

/// What a backup package says about itself. Written and verified by the app;
/// there is no signature, so a hash only proves the file is intact, not who
/// produced it.
public struct BackupManifest: Sendable, Hashable, Codable {
    public struct Counts: Sendable, Hashable, Codable {
        public var balancePoints: Int
        public var ledgerEntries: Int
        public var sealedPacks: Int
        public var openedPacks: Int
        public var openings: Int
        public var unfinishedOpenings: Int
        public var ownedCards: Int
        public var packRequests: Int
    }

    public struct CatalogReference: Sendable, Hashable, Codable {
        public var catalogVersion: String
        public var contentHash: String
        /// Packs in the backed-up database that are pinned to this snapshot.
        public var referencedByPacks: Int
        /// File name inside the package, when the snapshot was included.
        public var file: String?
        public var fileSHA256: String?
    }

    public struct UsageState: Sendable, Hashable, Codable {
        /// Every connected source, one entry per tool/path. Absent in backups
        /// written before multi-tool support, which is why it is optional: an
        /// older OMP-only backup still decodes.
        public struct Source: Sendable, Hashable, Codable {
            public var tool: String
            public var rootPath: String?
            public var status: String
            public var baselineCompleted: Bool
            public var toolVersion: String?
            public var formatVersion: String?
        }

        public var connected: Bool
        public var rootConfigured: Bool
        public var baselineCompleted: Bool
        public var checkpoints: Int
        public var events: Int
        public var aliases: Int
        public var sources: [Source]?

        public init(
            connected: Bool,
            rootConfigured: Bool,
            baselineCompleted: Bool,
            checkpoints: Int,
            events: Int,
            aliases: Int,
            sources: [Source]? = nil
        ) {
            self.connected = connected
            self.rootConfigured = rootConfigured
            self.baselineCompleted = baselineCompleted
            self.checkpoints = checkpoints
            self.events = events
            self.aliases = aliases
            self.sources = sources
        }
    }

    public struct ImagePolicy: Sendable, Hashable, Codable {
        public var included: Bool
        public var note: String
    }

    public var formatVersion: Int
    public var appSchemaVersion: Int
    public var createdAt: String
    public var realm: Realm
    public var databaseFile: String
    public var databaseSHA256: String
    public var databaseBytes: Int
    public var counts: Counts
    public var catalogs: [CatalogReference]
    public var poolVersion: String?
    public var usage: UsageState
    public var images: ImagePolicy
    /// Plain-language notes shown before a restore.
    public var notes: [String]

    /// `createdAt` parsed back, for display and ordering. Nil for a manifest
    /// written by something that used a different format.
    public var createdAtDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    public static let currentFormatVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let databaseFileName = "packtrace.sqlite"
    public static let catalogsDirectoryName = "catalogs"
    public static let packageExtension = "ptbackup"
}
