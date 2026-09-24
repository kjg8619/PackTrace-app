import Foundation
import PackTraceCore
import Testing

/// Runs an operation and returns the `PackTraceError` it threw, recording a
/// test failure when it threw something else or nothing at all.
@discardableResult
public func captureError<T>(
    _ label: String,
    fileID: String = #fileID,
    filePath: String = #filePath,
    line: Int = #line,
    column: Int = #column,
    _ body: () async throws -> T
) async -> PackTraceError? {
    do {
        _ = try await body()
        Issue.record("\(label): 예외가 발생하지 않았습니다", sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        return nil
    } catch let error as PackTraceError {
        return error
    } catch {
        Issue.record("\(label): 예상과 다른 오류 \(error)", sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
        return nil
    }
}

/// Deleting a directory in a test is only safe when the test itself created it.
///
/// The rule is checked before anything is removed: the target must be inside a
/// root the harness made (a unique directory under the system temporary
/// directory), and paths that mean "everything" — empty, home, the repository,
/// the temporary directory itself, the app's real data root — are refused even
/// if a test asks for them.
public enum TestOwnedRoot {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case emptyPath
        case notUnderTemporaryDirectory(String)
        case protectedPath(String)
        case outsideOwner(String, String)
        case ownerNotUnique(String)

        public var description: String {
            switch self {
            case .emptyPath: "빈 경로는 삭제 대상이 될 수 없습니다"
            case let .notUnderTemporaryDirectory(path): "\(path)는 시스템 임시 디렉터리 밖입니다"
            case let .protectedPath(path): "\(path)는 보호된 경로입니다"
            case let .outsideOwner(target, owner): "\(target)가 소유 루트 \(owner) 밖입니다"
            case let .ownerNotUnique(owner): "소유 루트 \(owner)가 고유 임시 루트가 아닙니다"
            }
        }
    }

    /// Roots the harness is allowed to delete: `<tmp>/<label>-<uuid>` and below.
    public static func verifyOwned(_ url: URL, fileManager: FileManager = .default) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.isEmpty, path != "/" else { throw Refusal.emptyPath }
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = fileManager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        for protected in [home, temporary, "/Users", "/"] where path == protected {
            throw Refusal.protectedPath(path)
        }
        if path.hasPrefix(home) && !path.hasPrefix(temporary) {
            throw Refusal.protectedPath(path)
        }
        guard path.hasPrefix(temporary + "/") else {
            throw Refusal.notUnderTemporaryDirectory(path)
        }
        // The first component under the temporary directory must be the unique
        // directory this harness created, not the temporary directory itself.
        if let own = url.standardizedFileURL.pathComponents.dropFirst(temporary.split(separator: "/").count + 1).first {
            guard own.count >= 8, own.contains("-") else {
                throw Refusal.ownerNotUnique(own)
            }
        }
    }

    /// Deletes only when the target is owned; returns the refusal instead of
    /// throwing so a cleanup path can never mask a test failure.
    @discardableResult
    public static func remove(_ url: URL, fileManager: FileManager = .default) -> Refusal? {
        do {
            try verifyOwned(url, fileManager: fileManager)
        } catch let refusal as Refusal {
            return refusal
        } catch {
            return .emptyPath
        }
        try? fileManager.removeItem(at: url)
        return nil
    }
}
