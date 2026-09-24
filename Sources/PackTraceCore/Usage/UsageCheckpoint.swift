import Foundation

/// Connection between the app and one OMP log root.
public struct UsageSourceRecord: Sendable, Hashable {
    public var sourceID: String
    public var realm: Realm
    /// Which tool this source belongs to. Rows that predate multi-tool support
    /// are OMP, the only adapter that could have created them.
    public var tool: UsageToolKind = .omp
    public var toolVersion: String?
    public var formatVersion: String?
    public var rootPath: String
    public var connectedAt: Date
    public var baselineCompletedAt: Date?
    public var isPaused: Bool
    public var lastScanAt: Date?
    public var status: UsageSourceStatus
    public var lastReason: String?
}

public enum UsageSourceStatus: String, Sendable, Codable {
    case unconnected
    case baselining
    case collecting
    case paused
    case rootMissing = "root_missing"
    case permissionDenied = "permission_denied"
    case unsupportedFormat = "unsupported_format"
    case error

    public var displayName: String {
        switch self {
        case .unconnected: "미연결"
        case .baselining: "기준선 설정 중"
        case .collecting: "수집 중"
        case .paused: "읽기 일시정지"
        case .rootMissing: "로그 폴더 없음"
        case .permissionDenied: "권한 오류"
        case .unsupportedFormat: "형식 미지원"
        case .error: "오류"
        }
    }
}

/// One file's read position. `byteOffset` is always the end of the last record
/// that was safely consumed; a partial trailing record is never skipped over.
public struct UsageFileCheckpoint: Sendable, Hashable {
    public var relativePath: String
    public var deviceID: UInt64
    public var inode: UInt64
    public var byteOffset: Int64
    /// Boundary fixed at connect time: everything before it is baseline.
    public var baselineOffset: Int64
    /// True once the baseline region of this file has been fully recorded.
    public var baselineDone: Bool
    public var fileSize: Int64
    public var status: UsageFileStatus
    public var reason: String?
    public var updatedAt: Date
}

public enum UsageFileStatus: String, Sendable, Codable {
    case ok
    case rotated
    case missing
    case permissionDenied = "permission_denied"
    case error

    public var displayName: String {
        switch self {
        case .ok: "정상"
        case .rotated: "교체·축소 감지"
        case .missing: "파일 없음"
        case .permissionDenied: "권한 없음"
        case .error: "읽기 오류"
        }
    }
}

public enum UsageEventStatus: String, Sendable, Codable {
    /// Reward-eligible record that was counted.
    case accepted
    /// Existed at connect time; recorded so a later copy cannot be rewarded.
    case baseline
    /// Confirmed not rewardable (error/aborted call).
    case excluded
    /// Format or provider not verified.
    case unsupported
    /// Same identity already recorded with different values.
    case conflict

    public var displayName: String {
        switch self {
        case .accepted: "인정"
        case .baseline: "기준선"
        case .excluded: "제외"
        case .unsupported: "미지원"
        case .conflict: "충돌"
        }
    }
}

/// What the store is asked to record for one parsed record.
public struct UsageBatchEntry: Sendable, Hashable {
    public var event: UsageEvent?
    public var status: UsageEventStatus
    public var reason: UsageRejectionReason?

    public init(event: UsageEvent?, status: UsageEventStatus, reason: UsageRejectionReason? = nil) {
        self.event = event
        self.status = status
        self.reason = reason
    }

    public static func baseline(_ event: UsageEvent) -> UsageBatchEntry {
        UsageBatchEntry(event: event, status: .baseline)
    }
}

public struct UsageBatchResult: Sendable, Hashable {
    public var inserted = 0
    public var duplicates = 0
    public var conflicts = 0
    public var acceptedEvents = 0
    public var acceptedTokens = 0
    public var pointsAwarded = 0
    public var remainderTokens = 0
    public var awardEntryID: WalletEntryID?
}

public struct UsageScanRunSummary: Sendable, Hashable {
    public var runID: String
    public var trigger: String
    public var startedAt: Date
    public var finishedAt: Date
    public var filesConsidered = 0
    public var filesRead = 0
    public var bytesRead: Int64 = 0
    public var recordsSeen = 0
    public var inserted = 0
    public var duplicates = 0
    public var conflicts = 0
    public var excluded = 0
    public var unsupported = 0
    public var acceptedTokens = 0
    public var pointsAwarded = 0
    public var errors = 0
    public var baseline = false
    /// Records withheld because they belong to a fork/import's history.
    public var inherited = 0
    /// True when the slice budget ran out and another call is needed.
    public var moreWork = false
    /// Set when the scan did nothing because no source is connected. A restored
    /// profile stays in this state until the user reconnects, and this is a
    /// state rather than an error.
    public var skippedReason: String?
}

public struct UsageTotals: Sendable, Hashable {
    public var ruleID: String
    public var acceptedTokens: Int
    public var remainderTokens: Int
    public var awardedPoints: Int
    public var acceptedEvents: Int
}

public struct UsageDayTotals: Sendable, Hashable {
    /// Accepted tokens of events that *occurred* on the day (Asia/Seoul).
    public var acceptedTokens: Int
    public var acceptedEvents: Int
    /// Points whose ledger entry was confirmed on the day (Asia/Seoul).
    public var awardedPoints: Int
}

/// One tool's credited calls on one day, with the token kinds kept apart: the
/// credited part (uncached input + output) and the cache tokens the rule
/// leaves out. Other tools' "total tokens" include the cache reads, which is
/// why they are much larger.
public struct UsageToolDay: Sendable, Hashable, Identifiable {
    public var id: String { tool.rawValue }
    public var tool: UsageToolKind
    public var events: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var acceptedTokens: Int

    public init(tool: UsageToolKind, events: Int, inputTokens: Int, outputTokens: Int,
                cacheReadTokens: Int, cacheWriteTokens: Int, acceptedTokens: Int) {
        self.tool = tool
        self.events = events
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.acceptedTokens = acceptedTokens
    }

    /// Every token of these calls, cache included (what usage dashboards show).
    public var allTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
}

/// One stored usage record, without any log content.
public struct UsageEventRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String
    public var responseID: String
    public var provider: String
    public var model: String
    public var stopReason: String
    public var occurredAt: Date
    public var completedAt: Date?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var acceptedTokens: Int
    public var status: UsageEventStatus
    public var reason: UsageRejectionReason?
    public var awardEntryID: WalletEntryID?
}

public struct UsageDiagnostics: Sendable, Hashable {
    public var lastScanAt: Date?
    public var lastScanTrigger: String?
    public var lastRun: UsageScanRunSummary?
    public var acceptedEvents: Int
    public var baselineEvents: Int
    public var excludedEvents: Int
    public var unsupportedEvents: Int
    public var conflictEvents: Int
    /// Cumulative skipped-duplicate count (observed, not distinct).
    public var duplicateEvents: Int
    public var excludedByIdentity: [UsageRejectionReason: Int]
    /// Event ids that mapped to an already recorded original call (fork/import).
    public var aliasEvents: Int
    /// Observed sessions and how many of them declared a fork origin.
    public var sessionsObserved: Int
    public var sessionsWithParent: Int
    public var filesTracked: Int
    public var filesWithErrors: Int
    public var lastErrorReason: String?
}
