import AppKit
import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Image presentation and the input/motion paths of the opening flow, driven
/// through the same entry points the views use.
///
/// Everything runs on a temporary data root; nothing reads or writes user data.
@Suite("이미지 표시와 입력·모션 경로")
@MainActor
struct MediaAndInputTests {
    private func makeEnvironment(
        realm: Realm = .demo,
        seed: UInt64? = 7,
        root existingRoot: URL? = nil
    ) throws -> (AppEnvironment, URL) {
        let root = try existingRoot ?? StoreLocation.temporary(label: "packtrace-media-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = realm
        settings.testSeed = seed
        let environment = AppEnvironment(realm: realm, locationRoot: root, settings: settings)
        return (environment, root)
    }

    // MARK: - Image presentation

    /// Writes bytes straight into the cache, so the test needs no network.
    private func seedCache(_ environment: AppEnvironment, root: URL, url: String, bytes: Data) throws {
        let directory = StoreLocation(
            realm: environment.profile,
            directory: root.appendingPathComponent(environment.profile.rawValue, isDirectory: true)
        ).imageDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = ImageCache.cacheKey(urlString: url, quality: .thumbnail)
        try bytes.write(to: directory.appendingPathComponent(key))
    }

    @Test("캐시된 이미지가 있으면 카드가 이미지와 함께 표시된다")
    func cachedImageLoads() async throws {
        let (environment, root) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let card = try #require(environment.catalog?.cards.first)
        let url = CardImageURL.url(for: card, quality: .thumbnail)
        let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
        try seedCache(environment, root: root, url: url, bytes: png)

        let model = RemoteImageModel()
        await model.load(urlString: url, quality: .thumbnail, cache: environment.imageCache)
        #expect(model.state == .loaded)
        #expect(model.image != nil)
    }

    @Test("디코딩할 수 없는 바이트는 실패로 표시되고 재시도 가능 상태가 된다")
    func undecodableImageFallsBackToPlaceholder() async throws {
        let (environment, root) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let card = try #require(environment.catalog?.cards.first)
        let url = CardImageURL.url(for: card, quality: .thumbnail)

        // Damaged cache bytes plus a source that cannot serve them either: the
        // only honest outcome is a placeholder that offers a retry.
        let location = try StoreLocation.temporary(label: "packtrace-broken-image")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let cache = ImageCache(directory: location.imageDirectory, session: FailingImageSession.failing())
        try FileManager.default.createDirectory(at: location.imageDirectory, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(
            to: location.imageDirectory.appendingPathComponent(
                ImageCache.cacheKey(urlString: url, quality: .thumbnail)
            )
        )

        let model = RemoteImageModel()
        await model.load(urlString: url, quality: .thumbnail, cache: cache)
        #expect(model.state == .unavailable)
        #expect(model.image == nil)
        #expect(model.isRetryable)
        // What the placeholder shows instead is local metadata, and it is present.
        #expect(!card.name.isEmpty)
        #expect(!card.setID.isEmpty)
        #expect(!card.localID.isEmpty)

        // A retry clears the recorded failure and reports the same result here.
        await model.retry(cache: cache)
        #expect(model.state == .unavailable)
    }

    @Test("손상된 캐시는 다시 받아 스스로 복구한다")
    func damagedCacheHealsItself() async throws {
        let (environment, root) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let card = try #require(environment.catalog?.cards.first)
        let url = CardImageURL.url(for: card, quality: .thumbnail)

        let location = try StoreLocation.temporary(label: "packtrace-heal-image")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let cache = ImageCache(directory: location.imageDirectory, session: FailingImageSession.servingImage())
        try FileManager.default.createDirectory(at: location.imageDirectory, withIntermediateDirectories: true)
        let file = location.imageDirectory.appendingPathComponent(ImageCache.cacheKey(urlString: url, quality: .thumbnail))
        try Data("not an image".utf8).write(to: file)

        let model = RemoteImageModel()
        await model.load(urlString: url, quality: .thumbnail, cache: cache)
        #expect(model.state == .loaded, "손상된 캐시 바이트는 다시 받아 복구해야 합니다")
        #expect(model.image != nil)
        // The damaged file was replaced by a usable one.
        let healed = try Data(contentsOf: file)
        #expect(healed != Data("not an image".utf8))
    }

    @Test("캐시가 없으면 실패로 표시되고 지갑·카드 기록은 그대로다")
    func missingCacheShowsPlaceholderOnly() async throws {
        let (environment, root) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let card = try #require(environment.catalog?.cards.first)
        let url = CardImageURL.url(for: card, quality: .thumbnail)

        let model = RemoteImageModel()
        await model.load(urlString: url, quality: .thumbnail, cache: nil)
        #expect(model.state == .unavailable)

        let balanceBefore = environment.balance
        let pack = try #require(await environment.exchangeRandomPack())
        let opening = try await environment.openPack(pack.id)
        #expect(opening.cards.count == environment.packSize(of: environment.product(for: pack)))
        await environment.refresh()
        #expect(environment.balance == balanceBefore - environment.packCostPoints)
        #expect(environment.allPacks.count == 1)
    }

    // MARK: - Motion

    @Test("모션 줄이기 판단은 설정과 시스템 값 중 하나만 켜져도 참이다")
    func skipsAnimationsContract() async throws {
        let settings = makeIsolatedSettings()
        #expect(settings.skipsAnimations(systemReduceMotion: false) == false)

        settings.fastOpen = true
        #expect(settings.skipsAnimations(systemReduceMotion: false) == true)
        settings.fastOpen = false

        settings.reduceMotion = true
        #expect(settings.skipsAnimations(systemReduceMotion: false) == true)
        settings.reduceMotion = false

        // The system setting alone is enough, and it is only ever read.
        #expect(settings.skipsAnimations(systemReduceMotion: true) == true)
        #expect(settings.reduceMotion == false)
    }

    @Test("모션 줄이기 경로도 같은 카드 결과와 진행 상태를 남긴다")
    func reduceMotionKeepsSameResults() async throws {
        let (motion, motionRoot) = try makeEnvironment(seed: 21)
        defer { try? FileManager.default.removeItem(at: motionRoot) }
        let (normal, normalRoot) = try makeEnvironment(seed: 21)
        defer { try? FileManager.default.removeItem(at: normalRoot) }
        motion.settings.reduceMotion = true
        #expect(motion.settings.skipsAnimations(systemReduceMotion: false))
        #expect(!normal.settings.skipsAnimations(systemReduceMotion: false))

        await motion.bootstrap()
        await normal.bootstrap()
        let motionPack = try #require(await motion.exchangeRandomPack())
        let normalPack = try #require(await normal.exchangeRandomPack())
        #expect(motionPack.productID == normalPack.productID)
        #expect(motionPack.catalogVersion == normalPack.catalogVersion)

        let motionOpening = try await motion.openPack(motionPack.id)
        let normalOpening = try await normal.openPack(normalPack.id)
        #expect(motionOpening.cards == normalOpening.cards, "연출을 건너뛰어도 저장 결과는 같아야 합니다")

        // Revealing everything is a store operation, so both paths end in the
        // same persisted state.
        let motionAll = try #require(await motion.revealAll(motionOpening))
        let normalAll = try #require(await normal.revealAll(normalOpening))
        #expect(motionAll.revealedCount == normalAll.revealedCount)
        #expect(motionAll.revealedCount == motionOpening.cards.count)
        #expect(motionAll.isComplete)
        #expect(normalAll.isComplete)
    }

    // MARK: - Input paths

    @Test("한 장씩 공개와 모두 공개가 같은 저장 결과로 끝난다")
    func revealAllMatchesStepByStep() async throws {
        let (environment, root) = try makeEnvironment(seed: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let first = try #require(await environment.exchangeRandomPack())
        let second = try #require(await environment.exchangeRandomPack())
        let stepByStep = try await environment.openPack(first.id)
        let allAtOnce = try await environment.openPack(second.id)

        var current = stepByStep
        while !current.isComplete {
            let next = try #require(await environment.revealNext(current))
            #expect(next.revealedCount == current.revealedCount + 1)
            current = next
        }
        let revealed = try #require(await environment.revealAll(allAtOnce))

        #expect(current.revealedCount == revealed.revealedCount)
        #expect(current.revealedCount == stepByStep.cards.count)
        #expect(current.cards == stepByStep.cards, "공개 방식이 저장된 결과를 바꾸면 안 됩니다")
        #expect(revealed.cards == allAtOnce.cards)
        #expect(try await environment.store?.ownedCardInstances().count == 20)

        // Revealing again after completion changes nothing.
        let afterExtra = try #require(await environment.revealNext(revealed))
        #expect(afterExtra.revealedCount == revealed.revealedCount)
    }

    @Test("같은 팩을 연속으로 열어도 카드가 두 번 저장되지 않는다")
    func repeatedOpenDoesNotDuplicate() async throws {
        let (environment, root) = try makeEnvironment(seed: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let pack = try #require(await environment.exchangeRandomPack())

        // A held key or a double click reaches this twice.
        let first = try await environment.openPack(pack.id)
        let second = try await environment.openPack(pack.id)
        #expect(first.id == second.id)
        #expect(first.cards == second.cards)
        #expect(try await environment.store?.ownedCardInstances().count == first.cards.count)
        #expect(first.cards.count == environment.packSize(of: environment.product(for: pack)))
        #expect(try await environment.store?.openings().count == 1)
    }

    @Test("공개 중 창을 닫고 다시 열어도 저장된 진행 위치에서 이어진다")
    func closingDuringRevealResumes() async throws {
        let (environment, root) = try makeEnvironment(seed: 5)
        defer { try? FileManager.default.removeItem(at: root) }
        await environment.bootstrap()
        let pack = try #require(await environment.exchangeRandomPack())
        var opening = try await environment.openPack(pack.id)
        for _ in 0..<3 {
            // The views chain the returned record; a stale one would set the same
            // count again, which is what this loop mirrors.
            opening = try #require(await environment.revealNext(opening))
        }
        environment.openingRequest = nil
        await environment.refresh()
        #expect(environment.unfinishedOpenings.count == 1)
        #expect(environment.unfinishedOpenings.first?.revealedCount == 3)

        // Reopening the same pack continues from the stored position.
        let resumed = try #require(await environment.openPack(pack.id))
        #expect(resumed.id == opening.id)
        #expect(resumed.revealedCount == 3)
        #expect(resumed.cards == opening.cards)

        // A restart over the same data root shows the same unfinished opening.
        let (restarted, _) = try makeEnvironment(seed: 5, root: root)
        await restarted.bootstrap()
        #expect(restarted.unfinishedOpenings.first?.revealedCount == 3)
        #expect(restarted.unfinishedOpenings.first?.id == opening.id)
    }
}

/// App-level contracts for the window and for launch.
@Suite("앱 창과 시작")
@MainActor
struct AppWindowTests {
    @Test("시작이 겹쳐 들어와도 열린 저장소를 다시 열거나 닫지 않는다")
    func overlappingBootstrapKeepsOneStore() async throws {
        let root = try StoreLocation.temporary(label: "packtrace-bootstrap-ui").directory
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeIsolatedSettings()
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)

        // The app, the window and the menu bar each ask for bootstrap at launch.
        let first = Task { await environment.bootstrap() }
        var opened: PackTraceStore?
        for _ in 0..<500 where opened == nil {
            try await Task.sleep(for: .milliseconds(1))
            opened = environment.activeStore(for: .demo)
        }
        let store = try #require(opened, "첫 시작이 저장소를 열지 않았습니다")

        // A second caller arrives while the first is still working.
        let second = Task { await environment.bootstrap() }
        await first.value
        await second.value

        #expect(environment.activeStore(for: .demo) === store, "두 번째 시작이 저장소를 갈아끼웠습니다")
        #expect(environment.loadState == .ready)
        #expect(environment.lastActionError == nil)
        // The store the screens use is the one that stayed open.
        await environment.refresh()
        #expect(environment.lastActionError == nil)
        #expect(environment.balance == 500)
        #expect(environment.setSummaries.count >= 3)
    }
}

/// URLSessions whose requests never reach the network, for deterministic image
/// failure and recovery tests. Two classes rather than one shared flag, because
/// the test suite runs cases in parallel.
enum FailingImageSession {
    static func failing() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func servingImage() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageProtocol.self]
        return URLSession(configuration: configuration)
    }

    static let pngBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """)!

    final class FailingProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    final class ImageProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: FailingImageSession.pngBytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
}
