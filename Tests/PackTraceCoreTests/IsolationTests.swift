import Foundation
import Testing

@testable import PackTraceCore

@Suite("데이터 격리")
struct IsolationTests {
    @Test("테스트 저장소는 임시 디렉터리만 사용한다")
    func testStoresStayInTemporaryDirectory() throws {
        let location = try StoreLocation.temporary()
        let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        #expect(location.directory.standardizedFileURL.path.hasPrefix(temporaryRoot))

        let applicationSupport = try StoreLocation.applicationSupport(realm: .demo)
        #expect(location.directory != applicationSupport.directory)
        #expect(!location.directory.path.contains("Application Support"))
    }

    @Test("demo와 production 지갑은 다른 데이터베이스를 쓴다")
    func realmsUseSeparateDatabases() async throws {
        let catalog = Fixtures.syntheticCatalog()
        let demo = try Fixtures.makeStore(catalog: catalog, realm: .demo)
        let production = try Fixtures.makeStore(catalog: catalog, realm: .production)

        #expect(demo.location.databaseURL != production.location.databaseURL)
        try await demo.grantInitialDemoPoints()
        try await production.grantInitialDemoPoints()

        let demoBalance = try await demo.balance()
        let productionBalance = try await production.balance()
        let demoEntries = try await demo.ledger()
        let productionEntries = try await production.ledger()
        #expect(demoBalance == 500)
        #expect(productionBalance == 0)
        #expect(demoEntries.count == 1)
        #expect(productionEntries.isEmpty)
    }

    @Test("저장소 작업은 사용자 Application Support 데이터를 건드리지 않는다")
    func storeDoesNotTouchApplicationSupport() async throws {
        let appSupport = try StoreLocation.applicationSupport(realm: .demo).directory
        let before = Self.snapshot(of: appSupport)

        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()
        let pack = try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: 6).packInstance
        _ = try await store.openPack(instanceID: pack.id, seed: 6)
        _ = try await store.binderEntries(setID: "synth")

        let after = Self.snapshot(of: appSupport)
        #expect(before == after, "테스트가 사용자 데이터 디렉터리를 변경했습니다")
    }

    @Test("팩·개봉·소유 기록은 저장소 디렉터리 안에만 생긴다")
    func filesStayInsideStoreDirectory() async throws {
        let location = try StoreLocation.temporary()
        let store = try PackTraceStore(location: location, catalog: Fixtures.syntheticCatalog())
        try await store.grantInitialDemoPoints()

        let contents = try FileManager.default.contentsOfDirectory(atPath: location.directory.path)
        #expect(contents.contains("packtrace.sqlite"))
        #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
    }

    /// Paths and sizes under a directory, used to prove a test run left it alone.
    private static func snapshot(of directory: URL) -> [String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else {
            return []
        }
        var entries: [String] = []
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            entries.append("\(url.path)|\(size)|\(modified.timeIntervalSince1970)")
        }
        return entries.sorted()
    }
}
