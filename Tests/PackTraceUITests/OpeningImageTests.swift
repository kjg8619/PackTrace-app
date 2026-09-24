import AppKit
import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Images during the opening: which ones are warmed ahead of a reveal, and that
/// a front whose full image is still on its way shows the cached thumbnail
/// rather than a spinner. The network is a stub; no host is contacted.
@Suite("개봉 이미지 준비")
@MainActor
struct OpeningImageTests {
    static let library: CatalogLibrary = try! CatalogLoader.bundledLibrary()

    private func cards(_ count: Int) -> [PackOpeningCard] {
        let catalog = Self.library.catalogs.values.sorted { $0.catalogVersion < $1.catalogVersion }.first!
        return catalog.cards.prefix(count).enumerated().map { index, card in
            PackOpeningCard(position: index, card: card, variant: card.primaryVariant, isNew: false)
        }
    }

    @Test("카드가 올라오는 순간 남은 카드의 앞면(full)을 공개 순서대로 먼저, 썸네일을 그다음에 요청한다")
    func preloadWarmsTheRemainingFronts() {
        let pack = cards(10)
        func full(_ index: Int) -> String {
            ImageRequest.remote(urlString: CardImageURL.url(for: pack[index].card, quality: .full), quality: .full).cacheKey
        }
        func thumbnail(_ index: Int) -> String {
            ImageRequest.remote(urlString: CardImageURL.url(for: pack[index].card, quality: .thumbnail), quality: .thumbnail).cacheKey
        }
        let rise = OpeningImagePreload.requests(for: .cardsRise, cards: pack, revealedCount: 0).map(\.cacheKey)
        #expect(rise == (0..<10).map(full) + (0..<10).map(thumbnail))

        // A resumed opening starts from where it stopped; revealed cards are not fetched again.
        let resumed = OpeningImagePreload.requests(for: .cardsRise, cards: pack, revealedCount: 4).map(\.cacheKey)
        #expect(resumed == (4..<10).map(full) + (4..<10).map(thumbnail))
        #expect(OpeningImagePreload.requests(for: .cardWaiting(nextIndex: 9), cards: pack, revealedCount: 9).map(\.cacheKey)
            == [full(9), thumbnail(9)])

        // Nothing to warm before the cards exist, mid-reveal, or once they are all out.
        for state: PackOpeningEngine.State in [.idle, .packEnter, .packReady, .packOpening, .cardRevealing(index: 3), .summary, .complete] {
            #expect(OpeningImagePreload.requests(for: state, cards: pack, revealedCount: 3).isEmpty, "\(state.name)")
        }
    }

    /// Never answers, so a load stays in flight for the whole test.
    final class StallProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {}
        override func stopLoading() {}

        static var session: URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StallProtocol.self]
            // Longer than any wait below: the full image must still be in
            // flight when the test looks, however late the main actor runs.
            configuration.timeoutIntervalForRequest = 60
            return URLSession(configuration: configuration)
        }
    }

    nonisolated static let pngBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """)!

    @Test("앞면 full 이미지가 오는 동안 캐시된 썸네일이 먼저 보인다")
    func cachedThumbnailCoversTheWait() async throws {
        let location = try StoreLocation.temporary(label: "packtrace-opening-images")
        defer { TestOwnedRoot.remove(location.directory.deletingLastPathComponent()) }
        try location.prepareDirectories()
        let card = try #require(cards(1).first).card
        // The thumbnail is already on disk (warmed); the full image never arrives.
        let thumbnail = CardImageURL.url(for: card, quality: .thumbnail)
        try Self.pngBytes.write(to: location.imageDirectory.appendingPathComponent(
            ImageCache.cacheKey(urlString: thumbnail, quality: .thumbnail)
        ))
        let cache = ImageCache(directory: location.imageDirectory, session: StallProtocol.session)

        let model = RemoteImageModel()
        let loading = Task { await model.load(card: card, quality: .full, fallbackQuality: .thumbnail, cache: cache) }
        // Returns as soon as the thumbnail is up. The limit only covers a busy
        // main actor (other UI tests render synchronously on it in parallel);
        // a one-second limit failed there although nothing was wrong.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.fallbackImage == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.fallbackImage != nil, "썸네일이 먼저 보여야 합니다")
        #expect(model.state == .loading, "full 이미지는 아직 오는 중입니다")
        loading.cancel()
    }

    /// Answers 404 for thumbnails (`low.webp`) and a real image for the large
    /// one, like TCGdex does for sv10 #028.
    final class MissingThumbnailProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url!
            let missing = url.lastPathComponent == "low.webp"
            let response = HTTPURLResponse(
                url: url,
                statusCode: missing ? 404 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: missing ? Data() : OpeningImageTests.pngBytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}

        static var session: URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MissingThumbnailProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    @Test("썸네일 이미지가 원본에 없으면 큰 이미지를 썸네일 크기로 쓴다")
    func missingThumbnailUsesTheLargeImage() async throws {
        let location = try StoreLocation.temporary(label: "packtrace-missing-thumbnail")
        defer { TestOwnedRoot.remove(location.directory.deletingLastPathComponent()) }
        try location.prepareDirectories()
        let card = try #require(cards(1).first).card
        let cache = ImageCache(directory: location.imageDirectory, session: MissingThumbnailProtocol.session)

        let model = RemoteImageModel()
        await model.load(card: card, quality: .thumbnail, fallbackQuality: nil, cache: cache)
        #expect(model.state == .loaded, "큰 이미지로 대신 보여야 합니다")
        #expect(model.image != nil)

        // A full-size request is untouched by this: it never falls back.
        let fullModel = RemoteImageModel()
        await fullModel.load(card: card, quality: .full, fallbackQuality: nil, cache: cache)
        #expect(fullModel.state == .loaded)
    }
}
