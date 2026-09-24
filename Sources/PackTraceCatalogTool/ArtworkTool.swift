import Foundation
import PackTraceCore

/// Explicit asset preparation for real pack artwork.
///
/// Nothing else downloads these files: the app only ever reads what this
/// command installed, so a build, a launch or an opening never depends on a
/// source being reachable. The committed registry describes what belongs where;
/// the binaries stay in the local asset directory and are not tracked by Git.
enum ArtworkTool {
    static func run(mode: String, flags: [String: String], log: (String) -> Void) async throws {
        let manifestURL = URL(fileURLWithPath: flags["--manifest"] ?? defaultManifestPath)
        let directory = URL(fileURLWithPath: flags["--directory"] ?? defaultDirectoryPath, isDirectory: true)
        let registry = try PackArtworkRegistry.decode(Data(contentsOf: manifestURL))

        switch mode {
        case "fetch":
            try await fetch(
                registry: registry,
                manifestURL: manifestURL,
                directory: directory,
                writeManifest: flags["--write-manifest"] != nil,
                log: log
            )
        case "verify":
            let failures = verify(registry: registry, directory: directory, log: log)
            if failures > 0 {
                throw ArtworkToolError.verificationFailed(failures)
            }
        case "list":
            for artwork in registry.artworks {
                log("\(artwork.productID)\t\(artwork.artworkID) v\(artwork.artworkVersion)\t\(artwork.pixelWidth)x\(artwork.pixelHeight)\t\(artwork.file)")
            }
        default:
            throw ArtworkToolError.unknownMode(mode)
        }
    }

    /// Paths used when no flag is given, kept explicit so the documented command
    /// works from the repository root without arguments.
    static let defaultManifestPath = "Sources/PackTraceCore/Resources/pack-artwork/pack-artwork-v1.json"

    static var defaultDirectoryPath: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PackTrace/pack-artwork", isDirectory: true)
        return base.path
    }

    // MARK: - Fetch

    static func fetch(
        registry: PackArtworkRegistry,
        manifestURL: URL,
        directory: URL,
        writeManifest: Bool,
        log: (String) -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var updated = registry

        for (index, artwork) in registry.artworks.enumerated() {
            log("== \(artwork.productID) · \(artwork.displayName)")
            let data = try await download(artwork.source.imageURL)
            let info = try PackArtworkValidator.verifyOriginal(
                data,
                expectedSHA256: artwork.originalSHA256,
                expectedWidth: artwork.originalPixelWidth,
                expectedHeight: artwork.originalPixelHeight
            )
            log("   source: \(info.pixelWidth)x\(info.pixelHeight) \(info.format.rawValue) \(info.byteCount) bytes sha256=\(info.sha256.prefix(16))…")

            let normalised = try PackArtworkValidator.normalise(data, maxPixelSize: PackArtworkLimits.normalizedMaxPixelSize)
            let normalisedHash = PackArtworkValidator.sha256(of: normalised.data)
            log("   normalised: \(normalised.width)x\(normalised.height) png \(normalised.data.count) bytes sha256=\(normalisedHash.prefix(16))…")

            // Write beside the target and verify before replacing anything, so a
            // failed download or a broken normalisation cannot destroy a working
            // file that is already installed.
            let target = directory.appendingPathComponent(artwork.file)
            let staging = directory.appendingPathComponent(artwork.file + ".incoming")
            try normalised.data.write(to: staging, options: .atomic)
            var candidate = artwork
            candidate.contentSHA256 = normalisedHash
            candidate.pixelWidth = normalised.width
            candidate.pixelHeight = normalised.height
            let installed = try Data(contentsOf: staging)
            _ = try PackArtworkValidator.verifyInstalled(installed, descriptor: candidate)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: staging, to: target)
            updated.artworks[index] = candidate
            log("   installed: \(target.path)")
        }

        if writeManifest {
            // A manifest write must never silently drop entries: that is how a
            // half-installed registry would erase the other products.
            guard updated.artworks.count == registry.artworks.count else {
                throw ArtworkToolError.manifestWouldLoseEntries(
                    loaded: registry.artworks.count,
                    updated: updated.artworks.count
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(updated).write(to: manifestURL, options: .atomic)
            log("== manifest updated: \(manifestURL.path)")
        }

        // Read the installed files back from disk: the report is about what is
        // actually there, not about what was just written.
        let failures = verify(registry: updated, directory: directory, log: log)
        if failures > 0 {
            throw ArtworkToolError.verificationFailed(failures)
        }
        let bytes = updated.artworks.reduce(0) { total, artwork in
            let url = directory.appendingPathComponent(artwork.file)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
        log("== installed \(updated.artworks.count) artwork file(s), \(bytes) bytes total in \(directory.path)")
        log("   local assets only: do not commit or upload these files")
    }

    static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw ArtworkToolError.badURL(urlString) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("PackTrace/0.1 (local macOS app; artwork preparation)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ArtworkToolError.httpFailure(urlString, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.count <= PackArtworkLimits.maxSourceBytes else {
            throw ArtworkToolError.tooLarge(data.count)
        }
        return data
    }

    // MARK: - Verify

    /// Checks installed files against the registry. No network access.
    @discardableResult
    static func verify(registry: PackArtworkRegistry, directory: URL, log: (String) -> Void) -> Int {
        var failures = 0
        for artwork in registry.artworks {
            let url = directory.appendingPathComponent(artwork.file)
            do {
                let data = try Data(contentsOf: url)
                let info = try PackArtworkValidator.verifyInstalled(data, descriptor: artwork)
                log("PASS \(artwork.productID) \(artwork.displayName): \(info.pixelWidth)x\(info.pixelHeight) \(info.byteCount) bytes sha256=\(info.sha256.prefix(16))…")
            } catch {
                failures += 1
                let reason = (error as? PackArtworkValidationError)?.displayMessage ?? "\(error)"
                log("FAIL \(artwork.productID) \(artwork.file): \(reason)")
            }
        }
        return failures
    }

    enum ArtworkToolError: Error, CustomStringConvertible {
        case unknownMode(String)
        case badURL(String)
        case httpFailure(String, Int)
        case tooLarge(Int)
        case verificationFailed(Int)
        case manifestWouldLoseEntries(loaded: Int, updated: Int)

        var description: String {
            switch self {
            case let .unknownMode(mode): "unknown artwork mode \(mode) (fetch|verify|list)"
            case let .badURL(url): "bad image URL \(url)"
            case let .httpFailure(url, status): "download failed (\(status)) for \(url)"
            case let .tooLarge(bytes): "download too large: \(bytes) bytes"
            case let .verificationFailed(count): "\(count) artwork file(s) failed verification"
            case let .manifestWouldLoseEntries(loaded, updated):
                "refusing to write manifest: loaded \(loaded) entries, would write \(updated)"
            }
        }
    }
}
