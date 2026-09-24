import Foundation

/// Candidate OMP log roots, in the order the installed OMP resolves them.
///
/// The order mirrors the source of OMP 18.2.8 (see docs/OMP_USAGE_SCHEMA.md):
/// `--session-dir` is a per-run flag the app cannot know, so the environment
/// variable is next, then the agent home, then the default location.
public struct OMPLogRootCandidate: Sendable, Hashable {
    public var path: String
    /// Which rule produced this candidate.
    public var origin: String
    public var exists: Bool
    public var isReadable: Bool
    public var sessionFileCount: Int
}

public enum OMPLogRootDetector {
    public static let defaultRelativeSessions = ".omp/agent/sessions"

    public static func candidates(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [OMPLogRootCandidate] {
        var paths: [(String, String)] = []
        if let explicit = environment["PI_CODING_AGENT_SESSION_DIR"], !explicit.isEmpty {
            paths.append((explicit, "PI_CODING_AGENT_SESSION_DIR"))
        }
        if let agentDir = environment["PI_CODING_AGENT_DIR"], !agentDir.isEmpty {
            paths.append((agentDir + "/sessions", "PI_CODING_AGENT_DIR"))
        }
        paths.append((home.appendingPathComponent(defaultRelativeSessions).path, "기본 경로"))

        var seen = Set<String>()
        return paths.compactMap { path, origin in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard seen.insert(standardized).inserted else { return nil }
            return candidate(path: standardized, origin: origin)
        }
    }

    public static func candidate(path: String, origin: String = "직접 선택") -> OMPLogRootCandidate {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: path, isDirectory: &isDirectory)
        let readable = exists && manager.isReadableFile(atPath: path)
        var sessionFiles = 0
        if readable, isDirectory.boolValue {
            let top = (try? manager.contentsOfDirectory(
                at: URL(fileURLWithPath: path),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in top {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                let children = (try? manager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                sessionFiles += children.filter { $0.pathExtension == "jsonl" }.count
            }
        }
        return OMPLogRootCandidate(
            path: path,
            origin: origin,
            exists: exists,
            isReadable: readable,
            sessionFileCount: sessionFiles
        )
    }

    /// Path with the user's home directory replaced, for display only. Stored
    /// configuration keeps the real path locally.
    public static func displayPath(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = home.path
        var display = path
        if display.hasPrefix(homePath) {
            display = "~" + display.dropFirst(homePath.count)
        }
        let components = display.split(separator: "/").map(String.init)
        if components.count > 3 {
            return "…/" + components.suffix(3).joined(separator: "/")
        }
        return display
    }
}
