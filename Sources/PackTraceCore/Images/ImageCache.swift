import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image to load.
///
/// Card and set artwork is fetched by URL; installed pack artwork is read from a
/// local file. Both use the same cache, keyed so the two can never collide and
/// so a different size or a replaced file gets its own entry.
public struct ImageRequest: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case remote(urlString: String)
        /// A file installed by explicit asset preparation. `contentVersion`
        /// changes when the bytes change, so a replaced file is never served
        /// from a stale cache entry.
        case localFile(url: URL, contentVersion: String)
    }

    public var source: Source
    /// Longest edge the decoded image needs.
    public var maxPixelSize: Int
    /// Folded into the cache key: keeps sizes and content versions apart.
    public var cacheTag: String
    public var fileExtension: String

    public init(source: Source, maxPixelSize: Int, cacheTag: String, fileExtension: String) {
        self.source = source
        self.maxPixelSize = maxPixelSize
        self.cacheTag = cacheTag
        self.fileExtension = fileExtension
    }

    /// Card or set artwork addressed by URL.
    public static func remote(urlString: String, quality: CardImageQuality) -> ImageRequest {
        ImageRequest(
            source: .remote(urlString: urlString),
            maxPixelSize: quality.maxPixelSize,
            cacheTag: quality.rawValue,
            fileExtension: quality.fileExtension
        )
    }

    /// Installed pack artwork read from the local asset directory.
    public static func packArtwork(
        descriptor: PackArtworkDescriptor,
        fileURL: URL,
        size: PackArtworkRenderSize
    ) -> ImageRequest {
        ImageRequest(
            source: .localFile(
                url: fileURL,
                contentVersion: "v\(descriptor.artworkVersion)|\(descriptor.contentSHA256.prefix(16))"
            ),
            maxPixelSize: size.maxPixelSize,
            cacheTag: "pack-art-\(size.rawValue)",
            fileExtension: fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension
        )
    }

    public var isLocalFile: Bool {
        if case .localFile = source { return true }
        return false
    }

    var identifier: String {
        switch source {
        case let .remote(urlString): urlString
        case let .localFile(url, contentVersion): "\(url.path)|\(contentVersion)"
        }
    }

    public var cacheKey: String {
        let digest = SHA256.hash(data: Data("\(cacheTag)|\(identifier)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex + "." + (fileExtension.isEmpty ? "img" : fileExtension)
    }
}

/// Disk + memory cache for card, set and pack artwork. Images are presentation
/// data: a download failure never touches ownership records, it only falls back
/// to a placeholder or the substitute wrapper in the UI.
public actor ImageCache {
    public struct Stats: Sendable, Hashable {
        /// Decoded images held in memory, ready to draw without touching disk.
        public var decodedEntries = 0

        public var memoryEntries: Int
        public var diskEntries: Int
        public var diskBytes: Int
        public var failures: Int
    }

    private let directory: URL
    private let session: URLSession
    private var memory: [String: Data] = [:]
    /// Decoded, downsampled images. Handing a view a ready `CGImage` is what
    /// keeps scrolling off the main thread's decode path; the queue is bounded
    /// and evicted oldest-first.
    private var decoded: [String: CGImage] = [:]
    private var decodeOrder: [String] = []
    private var failures: Set<String> = []
    private var inFlight: [String: Task<Data?, Never>] = [:]
    private let memoryLimit = 120
    private let decodedLimit = 240

    public init(directory: URL, session: URLSession = .shared) {
        self.directory = directory
        self.session = session
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Data for an image, or nil when it is unavailable offline and not yet
    /// cached. Callers must render a placeholder on nil.
    public func data(for request: ImageRequest) async -> Data? {
        let key = request.cacheKey
        if let cached = memory[key] {
            return cached
        }
        if let task = inFlight[key] {
            return await task.value
        }
        let task = Task<Data?, Never> { [directory, session] in
            switch request.source {
            case let .remote(urlString):
                let fileURL = directory.appendingPathComponent(key)
                if let data = try? Data(contentsOf: fileURL) {
                    return data
                }
                return await Self.download(urlString: urlString, session: session, fileURL: fileURL)
            case let .localFile(url, _):
                // Installed artwork already lives on disk: read it where it is
                // instead of copying it into the download cache.
                return Self.readLocalFile(url)
            }
        }
        inFlight[key] = task
        let data = await task.value
        inFlight[key] = nil
        if let data {
            if memory.count >= memoryLimit, let first = memory.keys.first {
                memory.removeValue(forKey: first)
            }
            memory[key] = data
            failures.remove(key)
        } else {
            failures.insert(key)
        }
        return data
    }

    /// Data for an image URL. Kept for card and set artwork.
    public func data(for urlString: String, quality: CardImageQuality = .thumbnail) async -> Data? {
        await data(for: .remote(urlString: urlString, quality: quality))
    }

    /// Reads an installed artwork file under a size limit, so a bad path can
    /// never pull an unbounded file into memory.
    nonisolated static func readLocalFile(_ url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize,
              size <= PackArtworkLimits.maxInstalledBytes
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// One fresh copy from the network, written to the cache. Used both by the
    /// normal path and when cached bytes turned out not to be an image.
    private func fetch(_ request: ImageRequest) async -> Data? {
        guard case let .remote(urlString) = request.source else { return nil }
        return await Self.download(
            urlString: urlString,
            session: session,
            fileURL: directory.appendingPathComponent(request.cacheKey)
        )
    }

    /// Largest image accepted from the network. Card art is ~100 KB; anything far
    /// larger is not an image this app asked for.
    static let maxDownloadBytes = 16 * 1024 * 1024

    nonisolated static func download(urlString: String, session: URLSession, fileURL: URL) async -> Data? {
        // Encrypted transport only, and nothing oversized written to disk.
        guard let url = URL(string: urlString), url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              data.count <= maxDownloadBytes
        else {
            return nil
        }
        try? data.write(to: fileURL, options: .atomic)
        return data
    }

    /// An image ready to draw, or nil when the asset is unavailable.
    ///
    /// The bytes are read (memory → disk → network) and decoded to the size the
    /// quality needs *inside the actor*, so a grid of cards does not decode on
    /// the main thread while the user scrolls.
    public func image(for request: ImageRequest) async -> CGImage? {
        let key = request.cacheKey
        if let ready = decoded[key] {
            touch(key)
            return ready
        }
        if var data = await data(for: request) {
            if let image = Self.decode(data, maxPixelSize: request.maxPixelSize) {
                store(image, for: key)
                return image
            }
            // The bytes are not a usable image. They are dropped from the memory
            // cache first, so a retry after the file is replaced reads the new
            // bytes instead of being served the same broken ones again.
            memory.removeValue(forKey: key)
            // A remote copy is also retaken once so a damaged download cache heals
            // itself; an installed file belongs to the user's asset directory and
            // is left untouched, and the caller falls back to the substitute.
            guard request.isLocalFile == false else {
                failures.insert(key)
                return nil
            }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key))
            failures.remove(key)
            data = await fetch(request) ?? Data()
            if let image = Self.decode(data, maxPixelSize: request.maxPixelSize) {
                store(image, for: key)
                return image
            }
            failures.insert(key)
        }
        return nil
    }

    /// An image ready to draw, or nil when the asset is unavailable.
    ///
    /// The bytes are read (memory → disk → network) and decoded to the size the
    /// quality needs *inside the actor*, so a grid of cards does not decode on
    /// the main thread while the user scrolls.
    public func image(for urlString: String, quality: CardImageQuality = .thumbnail) async -> CGImage? {
        await image(for: .remote(urlString: urlString, quality: quality))
    }

    /// An image that is already available without any network access (memory,
    /// the download cache, or the installed file itself). Used for
    /// low-resolution fallbacks.
    public func cachedImage(for request: ImageRequest) async -> CGImage? {
        let key = request.cacheKey
        if let ready = decoded[key] {
            touch(key)
            return ready
        }
        let data: Data?
        switch request.source {
        case .remote:
            data = try? Data(contentsOf: directory.appendingPathComponent(key))
        case let .localFile(url, _):
            data = Self.readLocalFile(url)
        }
        guard let data,
              let image = Self.decode(data, maxPixelSize: request.maxPixelSize)
        else { return nil }
        store(image, for: key)
        return image
    }

    /// An image that is already cached (memory or disk), without any network
    /// access. Used for low-resolution fallbacks.
    public func cachedImage(for urlString: String, quality: CardImageQuality = .thumbnail) async -> CGImage? {
        await cachedImage(for: .remote(urlString: urlString, quality: quality))
    }

    /// True when the cached bytes for this request decoded, so a caller can skip work.
    public func hasDecodedImage(_ request: ImageRequest) -> Bool {
        decoded[request.cacheKey] != nil
    }

    /// Clears a recorded failure so the next request tries again.
    public func forgetFailure(_ request: ImageRequest) {
        failures.remove(request.cacheKey)
    }

    /// Decodes off the main thread. `maxPixelSize` bounds the larger dimension.
    public nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func store(_ image: CGImage, for key: String) {
        decoded[key] = image
        touch(key)
        while decodeOrder.count > decodedLimit, let oldest = decodeOrder.first {
            decodeOrder.removeFirst()
            decoded.removeValue(forKey: oldest)
        }
    }

    private func touch(_ key: String) {
        if let index = decodeOrder.firstIndex(of: key) {
            decodeOrder.remove(at: index)
        }
        decodeOrder.append(key)
    }

    /// Fetches several images with limited concurrency; failures are ignored.
    public func prefetch(_ requests: [ImageRequest], concurrency: Int = 4) async {
        // Already decoded: nothing to do. This is what makes scrolling back cheap.
        let pending = requests.filter { !hasDecodedImage($0) }
        guard !pending.isEmpty else { return }
        var iterator = pending.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            var started = 0
            while let next = iterator.next(), started < max(1, concurrency) {
                started += 1
                group.addTask { _ = await self.image(for: next) }
            }
            while await group.next() != nil {
                if let next = iterator.next() {
                    group.addTask { _ = await self.image(for: next) }
                }
            }
        }
    }

    /// Fetches several URLs with limited concurrency; failures are ignored.
    public func prefetch(_ urlStrings: [String], quality: CardImageQuality = .thumbnail, concurrency: Int = 4) async {
        await prefetch(
            urlStrings.map { .remote(urlString: $0, quality: quality) },
            concurrency: concurrency
        )
    }

    public func isKnownFailure(_ request: ImageRequest) -> Bool {
        failures.contains(request.cacheKey)
    }

    public func isKnownFailure(_ urlString: String, quality: CardImageQuality = .thumbnail) -> Bool {
        isKnownFailure(.remote(urlString: urlString, quality: quality))
    }

    public func hasDecodedImage(_ urlString: String, quality: CardImageQuality = .thumbnail) -> Bool {
        hasDecodedImage(.remote(urlString: urlString, quality: quality))
    }

    public func forgetFailure(_ urlString: String, quality: CardImageQuality = .thumbnail) {
        forgetFailure(.remote(urlString: urlString, quality: quality))
    }

    public func stats() -> Stats {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let bytes = files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + size
        }
        return Stats(
            decodedEntries: decoded.count,
            memoryEntries: memory.count,
            diskEntries: files.count,
            diskBytes: bytes,
            failures: failures.count
        )
    }

    public func clearDisk() {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? manager.removeItem(at: file)
        }
        memory.removeAll()
        decoded.removeAll()
        decodeOrder.removeAll()
        failures.removeAll()
    }

    static func cacheKey(urlString: String, quality: CardImageQuality) -> String {
        ImageRequest.remote(urlString: urlString, quality: quality).cacheKey
    }
}

public enum CardImageQuality: String, Sendable {
    /// 245x337 webp used in grids and pack bundles.
    case thumbnail = "low"
    /// 600x825 webp used for a single revealed or enlarged card.
    case full = "high"

    public var fileExtension: String { "webp" }

    /// Longest edge a decoded image needs. Decoding to this instead of the
    /// source size is what keeps a grid of cards cheap to draw.
    public var maxPixelSize: Int {
        switch self {
        case .thumbnail: 337
        case .full: 825
        }
    }
}

public enum CardImageURL {
    /// False for a card the source lists without artwork (a few subset and
    /// newly released cards): screens show the card's text placeholder and no
    /// request is made.
    public static func hasImage(_ card: CardDefinition) -> Bool {
        !card.imageBaseURL.isEmpty
    }

    /// TCGdex asset rule: `{imageBaseURL}/{quality}.{extension}`.
    public static func url(for card: CardDefinition, quality: CardImageQuality) -> String {
        "\(card.imageBaseURL)/\(quality.rawValue).\(quality.fileExtension)"
    }
}
