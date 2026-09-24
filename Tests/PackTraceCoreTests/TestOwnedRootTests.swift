import Foundation
import PackTraceTestSupport
import Testing

/// The guard that stops a test from deleting anything it does not own.
///
/// Every case is an injected path policy: no real user directory is used, and
/// nothing is removed here — the tests only assert the decision.
@Suite("테스트 삭제 경로 보호")
struct TestOwnedRootTests {
    static func owned(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-3f2a9c41-77b1-4d2e-9a01-6c1e5b8d0f33", isDirectory: true)
    }

    @Test("harness가 만든 고유 임시 루트만 삭제할 수 있다")
    func ownedRootIsAllowed() throws {
        let root = Self.owned("packtrace-guard")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try TestOwnedRoot.verifyOwned(root)
        let nested = root.appendingPathComponent("child/grandchild", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try TestOwnedRoot.verifyOwned(nested)
    }

    @Test("넓은 경로와 사용자 경로는 거절한다")
    func widePathsAreRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let temporary = FileManager.default.temporaryDirectory
        let applicationSupport = home.appendingPathComponent("Library/Application Support/PackTrace", isDirectory: true)

        for path in [
            home,
            home.appendingPathComponent("Library", isDirectory: true),
            temporary,
            applicationSupport,
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Users"),
        ] {
            #expect(TestOwnedRoot.remove(path) != nil, "\(path.path)는 삭제 대상이 될 수 없습니다")
        }
    }

    @Test("고유 임시 루트가 아닌 임시 하위 경로도 거절한다")
    func nonUniqueTemporaryPathIsRefused() {
        // A temporary path that the harness did not create (no unique suffix).
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("tmp", isDirectory: true)
        #expect(TestOwnedRoot.remove(plain) != nil)
    }
}
