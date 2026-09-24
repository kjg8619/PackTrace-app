import Foundation

/// Which AI tool produced a usage record.
///
/// The tool is what the user ran; the model and provider inside a record are
/// separate facts. Two tools can report the same model name, and one tool can
/// route through several providers — neither makes two calls the same call.
public enum UsageToolKind: String, Sendable, Codable, CaseIterable, Identifiable {
    case omp
    case codex
    case claudeCode = "claude-code"
    case openCode = "opencode"
    /// pi-family agents: the same session JSONL as OMP, each in its own folder.
    case pi
    case omo
    case senpi
    case hermes
    case grok
    case kimi

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .omp: "OMP"
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .openCode: "OpenCode"
        case .pi: "pi"
        case .omo: "omo"
        case .senpi: "senpi"
        case .hermes: "Hermes"
        case .grok: "Grok"
        case .kimi: "Kimi"
        }
    }

    /// Order used for deterministic scanning and for the settings list.
    public var order: Int {
        switch self {
        case .omp: 0
        case .codex: 1
        case .claudeCode: 2
        case .openCode: 3
        case .pi: 4
        case .omo: 5
        case .senpi: 6
        case .hermes: 7
        case .grok: 8
        case .kimi: 9
        }
    }

    /// What the adapter reads. Stored per source so a future version can tell
    /// which storage layout a connection was made against.
    public var storageKind: UsageSourceStorageKind {
        switch self {
        case .omp, .codex, .claudeCode, .pi, .omo, .senpi, .grok, .kimi: .jsonLines
        case .openCode, .hermes: .sqliteDatabase
        }
    }
}

/// The physical shape of a source's storage.
public enum UsageSourceStorageKind: String, Sendable, Codable {
    case jsonLines = "jsonl"
    /// A read-only SQLite snapshot. PackTrace never writes to the original.
    case sqliteDatabase = "sqlite"
}

/// Stable identity of a connected source.
///
/// Derived from the tool and the canonical storage path, never from a fresh
/// UUID: re-selecting the same physical storage with the same adapter must reuse
/// the existing connection (baseline, checkpoint, pause state) instead of
/// starting a second one over the same records.
public struct UsageSourceIdentity: Hashable, Sendable {
    public var tool: UsageToolKind
    /// Absolute, symlink-resolved, standardised path.
    public var canonicalPath: String

    /// The path is canonicalised here as well, so a caller that hands in a path
    /// with `..` or a trailing slash gets the same identity as one that resolved
    /// it first.
    public init(tool: UsageToolKind, canonicalPath: String) {
        self.tool = tool
        self.canonicalPath = Self.canonicalise(URL(fileURLWithPath: canonicalPath))
    }

    public init(tool: UsageToolKind, url: URL) {
        self.init(tool: tool, canonicalPath: Self.canonicalise(url))
    }

    public var sourceID: String {
        let digest = UsageSourceIdentity.stableHash("\(tool.rawValue)|\(canonicalPath)")
        return "\(tool.rawValue):\(digest)"
    }

    /// Resolves symlinks and standardises separators so the same directory chosen
    /// twice through different paths produces the same identity.
    public static func canonicalise(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// FNV-1a over the UTF-8 bytes: short, dependency-free and stable across
    /// launches. This is an identifier, not a security boundary.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", hash)
    }

    /// Display form: home directory replaced, per the privacy rules.
    public var maskedPath: String {
        UsageSourceIdentity.mask(canonicalPath)
    }

    public static func mask(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// A source found on this machine but not yet connected.
///
/// Discovery only proposes; without an explicit connect no records from it are
/// ever credited.
public struct UsageSourceCandidate: Hashable, Sendable, Identifiable {
    public var id: String { identity.sourceID }
    public var identity: UsageSourceIdentity
    /// Where the candidate came from: `default`, `environment`, `cli-report`.
    public var origin: String
    public var note: String?
    public var exists: Bool

    public init(identity: UsageSourceIdentity, origin: String, note: String? = nil, exists: Bool = true) {
        self.identity = identity
        self.origin = origin
        self.note = note
        self.exists = exists
    }

    public var maskedPath: String { identity.maskedPath }
}

/// Result of probing a chosen root before or after connecting.
public struct UsageSourceInspection: Hashable, Sendable {
    public enum Support: String, Hashable, Sendable, Codable {
        /// The adapter recognised the format and can read it.
        case supported
        /// Recognised the tool's data, but this layout/version is not handled.
        case unsupportedVersion = "unsupported-version"
        /// The path exists but is not this tool's data.
        case notThisTool = "not-this-tool"
        /// Nothing to read (no files yet), which is not an error.
        case empty
        /// Permission or I/O problem.
        case unreadable

        public var displayName: String {
            switch self {
            case .supported: "지원"
            case .unsupportedVersion: "미지원 형식"
            case .notThisTool: "다른 도구의 데이터"
            case .empty: "아직 기록 없음"
            case .unreadable: "읽을 수 없음"
            }
        }

        /// True when a scan of this source can credit anything.
        public var canScan: Bool { self == .supported || self == .empty }
    }

    public var support: Support
    /// Version the tool itself reports, when it can be read without running it.
    public var toolVersion: String?
    /// Version of the storage layout the adapter recognised.
    public var formatVersion: String?
    /// Free-text detail, safe to show (no paths, no content).
    public var detail: String
    /// Provider/model routes the adapter is willing to credit.
    public var providerScope: [String]
    /// What the adapter deliberately leaves out.
    public var excluded: [String]

    public init(
        support: Support,
        toolVersion: String? = nil,
        formatVersion: String? = nil,
        detail: String,
        providerScope: [String] = [],
        excluded: [String] = []
    ) {
        self.support = support
        self.toolVersion = toolVersion
        self.formatVersion = formatVersion
        self.detail = detail
        self.providerScope = providerScope
        self.excluded = excluded
    }

    public static func unreadable(_ detail: String) -> UsageSourceInspection {
        UsageSourceInspection(support: .unreadable, detail: detail)
    }
}
