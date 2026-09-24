import AppKit
import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Image caching and failure handling.
///
/// The network is replaced by a stub protocol: nothing here touches a real host,
/// and no system network setting is changed.
@Suite("카드 이미지 캐시")
struct ImageCacheTests {
    /// One canned response or a stall, per URL.
    final class Stub: @unchecked Sendable {
        enum Reply {
            case ok(Data)
            case status(Int)
            case stall
        }

        private let lock = NSLock()
        private var replies: [String: Reply] = [:]
        private var counts: [String: Int] = [:]

        func set(_ reply: Reply, for url: String) {
            lock.lock()
            defer { lock.unlock() }
            replies[url] = reply
        }

        func reply(for url: String) -> Reply {
            lock.lock()
            defer { lock.unlock() }
            counts[url, default: 0] += 1
            return replies[url] ?? .status(404)
        }

        func requestCount(for url: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[url] ?? 0
        }

        /// Every request the stub saw, whatever the URL. Used to prove that a
        /// path never reaches the network at all.
        func totalRequests() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    /// A valid 1×1 PNG: the bytes a real asset server would return.
    static let pngBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """)!

    final class StubProtocol: URLProtocol {
        static let stub = Stub()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url?.absoluteString ?? ""
            switch Self.stub.reply(for: url) {
            case let .ok(data):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "image/png"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .status(code):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .stall:
                // Never answer: the session's own timeout produces the failure.
                break
            }
        }

        override func stopLoading() {}
    }

    private func makeCache(label: String, timeout: TimeInterval = 1) throws -> (ImageCache, StoreLocation) {
        let location = try StoreLocation.temporary(label: label)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let cache = ImageCache(
            directory: location.imageDirectory,
            session: URLSession(configuration: configuration)
        )
        return (cache, location)
    }

    @Test("200 응답은 캐시되고, 네트워크가 없어도 캐시에서 다시 나온다")
    func successIsCachedAndServedOffline() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-ok")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/ok.webp"
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)

        let first = await cache.data(for: url)
        #expect(first == Self.pngBytes)
        #expect(await cache.isKnownFailure(url) == false)

        // A second cache instance over the same directory (an app restart) with a
        // source that only fails still shows the card.
        StubProtocol.stub.set(.status(500), for: url)
        let restarted = ImageCache(
            directory: location.imageDirectory,
            session: URLSession(configuration: .ephemeral)
        )
        let fromDisk = await restarted.data(for: url)
        #expect(fromDisk == Self.pngBytes)
        #expect(await restarted.isKnownFailure(url) == false)
    }

    @Test("404와 500은 실패로 남고 다시 시도하면 성공한다")
    func httpErrorsFailThenRetry() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-404")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/missing.webp"
        StubProtocol.stub.set(.status(404), for: url)
        #expect(await cache.data(for: url) == nil)
        #expect(await cache.isKnownFailure(url) == true)

        let other = "https://stub.invalid/card/broken.webp"
        StubProtocol.stub.set(.status(500), for: other)
        #expect(await cache.data(for: other) == nil)
        #expect(await cache.isKnownFailure(other) == true)

        // The failure is not permanent: the next attempt fetches again.
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)
        #expect(await cache.data(for: url) == Self.pngBytes)
        #expect(await cache.isKnownFailure(url) == false)

        let stats = await cache.stats()
        #expect(stats.diskEntries == 1)
    }

    @Test("응답이 없으면 시간 초과로 실패하고 캐시를 오염시키지 않는다")
    func timeoutFailsWithoutCaching() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-timeout", timeout: 0.3)
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/slow.webp"
        StubProtocol.stub.set(.stall, for: url)

        let data = await cache.data(for: url)
        #expect(data == nil)
        #expect(await cache.isKnownFailure(url) == true)
        #expect(await cache.stats().diskEntries == 0)

        // Retry after the source recovers works, and the earlier failure is gone.
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)
        #expect(await cache.data(for: url) == Self.pngBytes)
        #expect(await cache.isKnownFailure(url) == false)
    }

    @Test("같은 주소를 여러 화면이 동시에 요청해도 한 번만 받는다")
    func concurrentRequestsShareOneFetch() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-shared")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/shared.webp"
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)

        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<6 {
                group.addTask { await cache.data(for: url) }
            }
            for await data in group {
                #expect(data == Self.pngBytes)
            }
        }
        #expect(StubProtocol.stub.requestCount(for: url) == 1)
    }

    @Test("디코딩된 이미지는 메모리에서 즉시 나오고 디스크를 다시 읽지 않는다")
    func decodedImagesAreServedFromMemory() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-decoded")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/decoded.webp"
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)

        let cold = await cache.image(for: url)
        #expect(cold != nil)
        #expect(StubProtocol.stub.requestCount(for: url) == 1)
        let requestsAfterCold = StubProtocol.stub.requestCount(for: url)

        // Second read comes from the decoded memory entry: no network, no disk.
        let warm = await cache.image(for: url)
        #expect(warm != nil)
        #expect(StubProtocol.stub.requestCount(for: url) == requestsAfterCold)
        #expect(await cache.hasDecodedImage(url))

        // A fresh instance over the same directory still reads the file once and
        // decodes it without any download.
        let reloaded = ImageCache(
            directory: location.imageDirectory,
            session: URLSession(configuration: .ephemeral)
        )
        let diskWarm = await reloaded.image(for: url)
        #expect(diskWarm != nil)
        #expect(StubProtocol.stub.requestCount(for: url) == requestsAfterCold)
        #expect(await reloaded.stats().decodedEntries == 1)

        await cache.clearDisk()
        #expect(await cache.hasDecodedImage(url) == false)
    }

    @Test("디코딩은 요청한 품질 크기로 줄여서 한다")
    func decodingDownsamplesToTheRequestedSize() async throws {
        // A 600×825 PNG stands in for the full-size asset.
        let big = Self.makePNG(width: 600, height: 825)
        let (cache, location) = try makeCache(label: "packtrace-image-downsample")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/big.webp"
        StubProtocol.stub.set(.ok(big), for: url)

        let thumbnail = try #require(await cache.image(for: url, quality: .thumbnail))
        #expect(max(thumbnail.width, thumbnail.height) <= CardImageQuality.thumbnail.maxPixelSize)
        #expect(CardImageQuality.thumbnail.maxPixelSize == 337)

        let full = try #require(await cache.image(for: url, quality: .full))
        #expect(max(full.width, full.height) <= CardImageQuality.full.maxPixelSize)
        #expect(full.width > thumbnail.width, "상세 이미지는 썸네일보다 커야 합니다")
    }

    @Test("실패를 지우면 다음 요청이 다시 시도한다")
    func forgettingAFailureRetries() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-retry")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/retry.webp"
        StubProtocol.stub.set(.status(404), for: url)
        #expect(await cache.image(for: url) == nil)
        #expect(await cache.isKnownFailure(url))

        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)
        await cache.forgetFailure(url)
        #expect(await cache.isKnownFailure(url) == false)
        #expect(await cache.image(for: url) != nil)
    }

    @Test("손상된 파일은 다시 받아 복구하고, 그래도 안 되면 실패로 남긴다")
    func damagedFileIsRefetched() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-damaged")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/damaged.webp"
        try FileManager.default.createDirectory(at: location.imageDirectory, withIntermediateDirectories: true)
        let file = location.imageDirectory.appendingPathComponent(
            ImageCache.cacheKey(urlString: url, quality: .thumbnail)
        )
        try Data("not an image".utf8).write(to: file)

        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)
        let healed = await cache.image(for: url)
        #expect(healed != nil, "손상 바이트는 다시 받아 복구해야 합니다")
        #expect(try Data(contentsOf: file) == Self.pngBytes)

        // Source down as well: the file is still damaged and the failure is recorded.
        let broken = "https://stub.invalid/card/damaged-2.webp"
        let brokenFile = location.imageDirectory.appendingPathComponent(
            ImageCache.cacheKey(urlString: broken, quality: .thumbnail)
        )
        try Data("not an image".utf8).write(to: brokenFile)
        StubProtocol.stub.set(.status(500), for: broken)
        #expect(await cache.image(for: broken) == nil)
        #expect(await cache.isKnownFailure(broken))
    }

    @Test("prefetch는 이미 디코딩된 이미지를 다시 받지 않는다")
    func prefetchSkipsDecodedImages() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-prefetch")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let urls = (0..<4).map { "https://stub.invalid/card/prefetch-\($0).webp" }
        for url in urls { StubProtocol.stub.set(.ok(Self.pngBytes), for: url) }

        await cache.prefetch(urls, quality: .thumbnail)
        let counts = urls.map { StubProtocol.stub.requestCount(for: $0) }
        #expect(counts.allSatisfy { $0 == 1 })
        #expect(await cache.stats().decodedEntries == 4)

        // Second prefetch: everything is decoded, so nothing is requested again.
        await cache.prefetch(urls, quality: .thumbnail)
        #expect(urls.map { StubProtocol.stub.requestCount(for: $0) } == counts)
    }

    @Test("캐시를 비우면 다음 요청은 다시 받아온다")
    func clearingDiskRefetches() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-clear")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let url = "https://stub.invalid/card/clear.webp"
        StubProtocol.stub.set(.ok(Self.pngBytes), for: url)
        _ = await cache.data(for: url)
        #expect(await cache.stats().diskEntries == 1)

        await cache.clearDisk()
        #expect(await cache.stats().diskEntries == 0)

        StubProtocol.stub.set(.status(404), for: url)
        #expect(await cache.data(for: url) == nil, "비운 뒤에는 다시 받아와야 합니다")
    }

    /// A real PNG of the requested size, so downsampling can be measured.
    static func makePNG(width: Int, height: Int) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    @Test("이미지 실패는 지갑·팩·카드 기록을 바꾸지 않는다")
    func imageFailuresDoNotTouchRecords() async throws {
        let library = try CatalogLoader.bundledLibrary()
        let location = try StoreLocation.temporary(label: "packtrace-image-records")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = try PackTraceStore(location: location, library: library, economy: .v1)
        try await store.grantInitialDemoPoints()
        let pool = try ResolvedPackPool.resolve(pool: try PackPool.loadBundled(), library: library)
        let pack = try await store.exchangePack(
            pool: pool,
            requestID: ExchangeRequestID(),
            seed: 5
        ).packInstance
        let opening = try await store.openPack(instanceID: pack.id, seed: 5)
        let balance = try await store.balance()

        let (cache, _) = try makeCache(label: "packtrace-image-records")
        for card in opening.cards {
            guard let definition = library.card(for: card.cardKey) else { continue }
            let url = CardImageURL.url(for: definition, quality: .thumbnail)
                .replacingOccurrences(of: "https://", with: "https://stub.invalid/")
            StubProtocol.stub.set(.status(503), for: url)
            #expect(await cache.data(for: url) == nil)
        }

        #expect(try await store.balance() == balance)
        #expect(try await store.ownedCardInstances().count == 10)
        #expect(try await store.opening(id: opening.id)?.cards == opening.cards)
        // Card metadata stays available locally, so the binder still lists them.
        #expect(try await store.binderEntries(setID: library.primary.set.externalSetID).count > 0)
        await store.close()
    }

    // MARK: - Installed pack artwork

    /// A descriptor for a file in the artwork directory. The bytes are a fixture
    /// PNG; no publisher asset is used in tests.
    static func artworkDescriptor(file: String, hash: String) -> PackArtworkDescriptor {
        PackArtworkDescriptor(
            artworkID: "fixture-art",
            artworkVersion: 1,
            productID: "tpcgi-en-sv01-booster",
            setID: "sv01",
            language: "en",
            region: "US/International",
            displayName: "fixture",
            file: file,
            contentSHA256: hash,
            pixelWidth: 32,
            pixelHeight: 64,
            originalSHA256: String(repeating: "0", count: 64),
            originalPixelWidth: 64,
            originalPixelHeight: 128,
            originalBytes: 512,
            kind: .foilBoosterFront,
            source: PackArtworkSource(
                publisher: "fixture",
                kind: "official-render",
                pageURL: "https://example.invalid/page",
                imageURL: "https://example.invalid/image.png",
                retrievedAt: "2026-09-23",
                rights: .unverifiedPrivateUse,
                rightsNote: "fixture"
            ),
            processing: [],
            matchEvidence: "fixture",
            unverified: []
        )
    }

    /// A session protocol that only counts requests.
    ///
    /// Kept apart from `StubProtocol` so the count cannot pick up traffic from
    /// tests running in parallel: the claim being made is that loading installed
    /// artwork never reaches the network at all.
    final class CountingProtocol: URLProtocol {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }

            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        static let counter = Counter()
        static let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CountingProtocol.self]
            return configuration
        }())

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.counter.increment()
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }

        override func stopLoading() {}
    }

    @Test("설치된 포장 이미지는 네트워크를 쓰지 않고 읽고 캐시한다")
    func localArtworkLoadsWithoutNetwork() async throws {
        let location = try StoreLocation.temporary(label: "packtrace-image-artwork")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        // Its own session, whose protocol counts every request it sees.
        let cache = ImageCache(directory: location.imageDirectory, session: CountingProtocol.session)
        let directory = location.directory.appendingPathComponent("pack-artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("fixture.png")
        let png = Self.makePNG(width: 32, height: 64)
        try png.write(to: fileURL)

        let descriptor = Self.artworkDescriptor(file: "fixture.png", hash: PackArtworkValidator.sha256(of: png))
        let request = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: .opening)

        let image = await cache.image(for: request)
        #expect(image != nil)
        #expect(await cache.hasDecodedImage(request))
        #expect(await cache.isKnownFailure(request) == false)
        #expect(CountingProtocol.counter.count == 0, "설치된 파일은 네트워크를 요청하지 않습니다")

        // The decoded image (and the bytes) are held, so removing the file does
        // not make the picture disappear while the view is alive.
        try FileManager.default.removeItem(at: fileURL)
        #expect(await cache.image(for: request) != nil)

        // A different render size is a different entry, not a shared one.
        let tile = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: .tile)
        #expect(tile.cacheKey != request.cacheKey)
    }

    @Test("없거나 손상된 설치 파일은 실패로 남고 파일을 지우지 않는다")
    func missingOrDamagedArtworkFails() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-artwork-bad")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let directory = location.directory.appendingPathComponent("pack-artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("missing.png")
        let descriptor = Self.artworkDescriptor(file: "missing.png", hash: String(repeating: "a", count: 64))

        let missing = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: .opening)
        #expect(await cache.image(for: missing) == nil)
        #expect(await cache.isKnownFailure(missing))

        // Damaged bytes: refused, recorded, and the installed file is untouched.
        try Data("<!DOCTYPE html>".utf8).write(to: fileURL)
        await cache.forgetFailure(missing)
        #expect(await cache.image(for: missing) == nil)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try Data(contentsOf: fileURL) == Data("<!DOCTYPE html>".utf8))

        // A file larger than the reading limit is refused without being read.
        let huge = directory.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(PackArtworkLimits.maxInstalledBytes + 1))
        try handle.close()
        let hugeRequest = ImageRequest.packArtwork(
            descriptor: Self.artworkDescriptor(file: "huge.png", hash: String(repeating: "b", count: 64)),
            fileURL: huge,
            size: .opening
        )
        #expect(await cache.image(for: hugeRequest) == nil)
        #expect(await cache.isKnownFailure(hugeRequest))
    }

    @Test("손상된 뒤 파일을 교체하면 다음 시도에서 복구된다")
    func replacedArtworkRecovers() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-artwork-recover")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let directory = location.directory.appendingPathComponent("pack-artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("replace.png")
        let good = Self.makePNG(width: 32, height: 64)
        let descriptor = Self.artworkDescriptor(file: "replace.png", hash: PackArtworkValidator.sha256(of: good))
        let request = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: .opening)

        try Data("<!DOCTYPE html>".utf8).write(to: fileURL)
        #expect(await cache.image(for: request) == nil)
        #expect(await cache.isKnownFailure(request))

        // Replacing the file is enough on its own: the broken bytes must not be
        // served again from the memory cache.
        try good.write(to: fileURL)
        await cache.forgetFailure(request)
        #expect(await cache.image(for: request) != nil)
        #expect(await cache.hasDecodedImage(request))
        #expect(await cache.isKnownFailure(request) == false)
    }

    @Test("카드 이미지와 포장 이미지 캐시 키는 서로 겹치지 않는다")
    func artworkAndCardKeysDoNotCollide() async throws {
        let (cache, location) = try makeCache(label: "packtrace-image-keys")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let directory = location.directory.appendingPathComponent("pack-artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("card.png")
        try Self.pngBytes.write(to: fileURL)

        // The same trailing path as a card URL, once as a card and once as an
        // installed file: the entries must stay separate.
        let cardURL = "https://stub.invalid/assets/low.webp"
        StubProtocol.stub.set(.ok(Self.pngBytes), for: cardURL)
        let cardRequest = ImageRequest.remote(urlString: cardURL, quality: .thumbnail)
        let artworkRequest = ImageRequest.packArtwork(
            descriptor: Self.artworkDescriptor(file: "card.png", hash: PackArtworkValidator.sha256(of: Self.pngBytes)),
            fileURL: fileURL,
            size: .opening
        )
        #expect(cardRequest.cacheKey != artworkRequest.cacheKey)

        _ = await cache.image(for: cardRequest)
        _ = await cache.image(for: artworkRequest)
        let stats = await cache.stats()
        #expect(stats.decodedEntries == 2)
        // Only the card was downloaded; the artwork came from disk.
        #expect(await cache.stats().diskEntries == 1)

        // Replacing the installed file changes the request key, so the old
        // picture is not served from a stale entry.
        let replacement = ImageRequest.packArtwork(
            descriptor: Self.artworkDescriptor(file: "card.png", hash: String(repeating: "f", count: 64)),
            fileURL: fileURL,
            size: .opening
        )
        #expect(replacement.cacheKey != artworkRequest.cacheKey)
    }
}
