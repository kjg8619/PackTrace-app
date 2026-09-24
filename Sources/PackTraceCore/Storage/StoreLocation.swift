import Foundation

/// Where a realm keeps its database, images and backups. Demo and production
/// never share a directory, and tests only ever get a temporary directory.
public struct StoreLocation: Sendable, Hashable {
    public var realm: Realm
    public var directory: URL

    public init(realm: Realm, directory: URL) {
        self.realm = realm
        self.directory = directory
    }

    public var databaseURL: URL {
        directory.appendingPathComponent("packtrace.sqlite")
    }

    public var imageDirectory: URL {
        directory.appendingPathComponent("images", isDirectory: true)
    }

    public var backupDirectory: URL {
        directory.appendingPathComponent("backups", isDirectory: true)
    }

    /// Catalogue snapshots installed by a restore, kept beside the profile so
    /// an older backup stays openable after the app ships newer snapshots.
    public var catalogDirectory: URL {
        directory.appendingPathComponent("catalogs", isDirectory: true)
    }

    public func prepareDirectories() throws {
        let manager = FileManager.default
        for url in [directory, imageDirectory, backupDirectory, catalogDirectory] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// `~/Library/Application Support/PackTrace/<realm>`
    public static func applicationSupport(realm: Realm) throws -> StoreLocation {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return StoreLocation(
            realm: realm,
            directory: base.appendingPathComponent("PackTrace", isDirectory: true)
                .appendingPathComponent(realm.rawValue, isDirectory: true)
        )
    }

    /// Fresh directory under the system temporary directory. Tests and previews
    /// use this so they can never touch a real collection.
    public static func temporary(realm: Realm = .demo, label: String = "packtrace-test") throws -> StoreLocation {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        return StoreLocation(realm: realm, directory: root)
    }
}
