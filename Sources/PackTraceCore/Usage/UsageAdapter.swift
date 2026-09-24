import Foundation

/// How much one adapter may read in a single slice.
///
/// Slices are bounded so one source with a large backlog cannot hold the others
/// (or the UI) for long: the coordinator comes back to it on the next pass.
public struct UsageScanBudget: Sendable, Hashable {
    /// Files whose content is read in one slice. Files that did not change are
    /// free: they are only looked at, never read.
    public var maxFiles: Int
    public var maxRecords: Int
    public var maxBytes: Int
    /// Rows, for sources that are not files.
    public var maxRows: Int
    /// Files seen for the first time that get a boundary without being read
    /// (history), per slice. Bounds one transaction, not what can be seen.
    public var maxNewFiles: Int

    public init(
        maxFiles: Int = 8,
        maxRecords: Int = 2_000,
        maxBytes: Int = 32 * 1024 * 1024,
        maxRows: Int = 4_000,
        maxNewFiles: Int = 1_000
    ) {
        self.maxFiles = maxFiles
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxNewFiles = maxNewFiles
    }

    public static let standard = UsageScanBudget()
}

/// A reading position that is not a byte offset.
///
/// A JSONL checkpoint is a byte offset inside a file; a database source keeps a
/// row ordering position instead. They are stored separately and never converted
/// into each other, because "5000" means different things in each.
public struct UsageCursor: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        /// Bytes into a file. Only file-based adapters use this.
        case fileOffset = "file-offset"
        /// An ordering position inside a database (adapter-defined JSON).
        case rowPosition = "row-position"
        /// Index inside the source's own enumeration (adapter-defined JSON).
        case recordIndex = "record-index"
    }

    public var cursorKey: String
    public var kind: Kind
    /// Adapter-owned JSON. Never contains content, only positions.
    public var payload: String
    public var updatedAt: Date

    public init(cursorKey: String, kind: Kind, payload: String, updatedAt: Date) {
        self.cursorKey = cursorKey
        self.kind = kind
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

/// A session the adapter observed, for diagnostics only.
public struct UsageSessionObservation: Sendable, Hashable {
    public var sessionID: String
    /// Set when the storage itself records the lineage (a fork origin).
    public var parentSessionID: String?
    public var schemaVersion: Int?

    public init(sessionID: String, parentSessionID: String? = nil, schemaVersion: Int? = nil) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.schemaVersion = schemaVersion
    }
}

/// One bounded, read-only read from one source.
public struct UsageSliceRequest: Sendable {
    public var source: UsageSourceRecord
    /// File positions, for file-based sources.
    public var fileCheckpoints: [UsageFileCheckpoint]
    /// Non-file positions, keyed by `cursorKey`.
    public var cursors: [String: UsageCursor]
    public var budget: UsageScanBudget
    /// True while the connection's baseline is still being fixed: records found
    /// now are history, not reward.
    public var isBaselining: Bool
    public var now: Date

    public init(
        source: UsageSourceRecord,
        fileCheckpoints: [UsageFileCheckpoint] = [],
        cursors: [String: UsageCursor] = [:],
        budget: UsageScanBudget = .standard,
        isBaselining: Bool,
        now: Date
    ) {
        self.source = source
        self.fileCheckpoints = fileCheckpoints
        self.cursors = cursors
        self.budget = budget
        self.isBaselining = isBaselining
        self.now = now
    }
}

/// Counters for one slice: what the adapter looked at, before any reward
/// decision.
public struct UsageSliceCounters: Sendable, Hashable {
    public var filesConsidered = 0
    public var filesRead = 0
    public var bytesRead = 0
    public var recordsSeen = 0
    public var unsupported = 0
    public var errorCount = 0

    public init() {}
}

/// What one slice produced.
///
/// The adapter only reports what it read and where it got to; the store decides
/// identity, baseline, reward and the ledger, all in one transaction with the
/// positions returned here.
public struct UsageSliceOutput: Sendable {
    public var entries: [UsageBatchEntry]
    public var fileCheckpoints: [UsageFileCheckpoint]
    public var cursors: [UsageCursor]
    public var sessions: [UsageSessionObservation]
    public var counters: UsageSliceCounters
    /// True when the budget ran out with more to read.
    public var moreWork: Bool
    /// Health the adapter observed for this source, if it changed.
    public var status: UsageSourceStatus?
    public var statusReason: String?
    /// Set when nothing was read and that is not an error (paused, empty).
    public var skippedReason: String?

    public init(
        entries: [UsageBatchEntry] = [],
        fileCheckpoints: [UsageFileCheckpoint] = [],
        cursors: [UsageCursor] = [],
        sessions: [UsageSessionObservation] = [],
        counters: UsageSliceCounters = UsageSliceCounters(),
        moreWork: Bool = false,
        status: UsageSourceStatus? = nil,
        statusReason: String? = nil,
        skippedReason: String? = nil
    ) {
        self.entries = entries
        self.fileCheckpoints = fileCheckpoints
        self.cursors = cursors
        self.sessions = sessions
        self.counters = counters
        self.moreWork = moreWork
        self.status = status
        self.statusReason = statusReason
        self.skippedReason = skippedReason
    }
}

/// One tool's storage reader.
///
/// Adapters read; they never write to the source, never touch the PackTrace
/// store, and never decide reward. Everything they can do is expressed as
/// "candidate roots", "what format is this", and "read one bounded slice".
public protocol UsageSourceAdapter: Sendable {
    var tool: UsageToolKind { get }

    /// Roots this machine plausibly has for the tool. Discovery is a proposal:
    /// no records are credited until the user connects one.
    func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate]

    /// Recognises the format at a chosen root without crediting anything.
    func inspect(source: UsageSourceRecord) -> UsageSourceInspection

    /// Reads one bounded slice.
    func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput
}

public extension UsageSourceAdapter {
    /// Default candidate scan: none. Adapters that know their layout override it.
    func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] { [] }

    /// Assumes the support state the adapter declared when connecting.
    func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        UsageSourceInspection(support: .supported, detail: "adapter did not probe the format")
    }
}

/// Adapters keyed by tool, so the coordinator can resolve one for a source row.
public struct UsageAdapterRegistry: Sendable {
    /// Every tool this build can read besides OMP (which keeps its own collector).
    public static var standard: UsageAdapterRegistry {
        UsageAdapterRegistry(
            [CodexUsageAdapter(), ClaudeCodeUsageAdapter(), OpenCodeUsageAdapter()]
                + PiSessionUsageAdapter.tools.map { PiSessionUsageAdapter(tool: $0) }
                + [HermesUsageAdapter(), GrokUsageAdapter(), KimiUsageAdapter()]
        )
    }

    private var adapters: [UsageToolKind: any UsageSourceAdapter]

    public init(_ adapters: [any UsageSourceAdapter] = []) {
        var map: [UsageToolKind: any UsageSourceAdapter] = [:]
        for adapter in adapters {
            map[adapter.tool] = adapter
        }
        self.adapters = map
    }

    public func adapter(for tool: UsageToolKind) -> (any UsageSourceAdapter)? {
        adapters[tool]
    }

    public var tools: [UsageToolKind] {
        adapters.keys.sorted { $0.order < $1.order }
    }

    /// Candidate roots from every adapter, in tool order.
    public func candidates(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> [UsageSourceCandidate] {
        tools.flatMap { adapters[$0]?.candidates(home: home, environment: environment) ?? [] }
    }
}
