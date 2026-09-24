import Foundation

/// Identity of one rewarded API call. Built from the OMP session id and the
/// provider's response id, both of which were verified to be stable and unique
/// in the observed log corpus (see docs/OMP_USAGE_SCHEMA.md).
public struct UsageEventID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    /// `tool:session:record` — the tool prefix keeps two tools' ids apart even
    /// when they happen to use the same format for their own identifiers.
    public init(tool: UsageToolKind, sessionID: String, responseID: String) {
        self.rawValue = "\(tool.rawValue):\(sessionID):\(responseID)"
    }

    /// OMP events keep the prefix they were first recorded with, so an upgrade
    /// never renames an existing event or re-pays it.
    public init(sessionID: String, responseID: String) {
        self.init(tool: .omp, sessionID: sessionID, responseID: responseID)
    }

    public var description: String { rawValue }
}

/// A normalised usage record: only the fields the app stores.
public struct UsageEvent: Sendable, Hashable {
    public var id: UsageEventID
    public var sessionID: String
    public var responseID: String
    public var provider: String
    public var model: String
    public var stopReason: String
    /// Request start, UTC epoch milliseconds.
    public var occurredAtMilliseconds: Int
    /// Response end, UTC epoch milliseconds, when the log carries it.
    public var completedAtMilliseconds: Int?
    /// Non-cached input tokens: OMP already subtracts cache reads.
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Reasoning tokens, when the source reports them *inside* output. Stored
    /// for diagnostics only: they are never added to the accepted total.
    public var reasoningTokens: Int? = nil
    /// Version of the adapter's normalisation rules that produced this event.
    public var normalizationVersion: Int = 1
    /// Tool-independent identity of the real call, when the source carries one
    /// (a provider request id, for example). Used to recognise the same call
    /// seen through two tools; empty means "not provable".
    public var callKey: String? = nil

    /// Fingerprint of the numeric fields, used to detect an id whose values
    /// changed. Contains no content.
    public var fingerprint: String {
        UsageEvent.makeFingerprint(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheWriteTokens,
            provider: provider,
            model: model,
            stopReason: stopReason
        )
    }

    public static func makeFingerprint(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        provider: String,
        model: String,
        stopReason: String
    ) -> String {
        "\(input)|\(output)|\(cacheRead)|\(cacheWrite)|\(provider)|\(model)|\(stopReason)"
    }
}

/// Why a record is not rewarded. Stored with the event (when it has an id) so
/// diagnostics never need the raw log line.
public enum UsageRejectionReason: String, Sendable, Codable, CaseIterable {
    case unparsableRecord = "unparsable_record"
    case missingSessionHeader = "missing_session_header"
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case missingResponseID = "missing_response_id"
    case missingUsage = "missing_usage"
    case missingTimestamp = "missing_timestamp"
    case invalidTimestamp = "invalid_timestamp"
    case invalidTokenField = "invalid_token_field"
    case tokenOutOfRange = "token_out_of_range"
    case unknownStopReason = "unknown_stop_reason"
    case stopReasonError = "stop_reason_error"
    case stopReasonAborted = "stop_reason_aborted"
    case providerNotVerified = "provider_not_verified"
    case oversizedRecord = "oversized_record"
    case subagentExcluded = "subagent_excluded"
    case sourcePaused = "source_paused"
    case identityConflict = "identity_conflict"
    /// Record from a fork/import whose call time predates the connection.
    case inheritedPreConnection = "inherited_pre_connection"
    /// Record whose provider response id was already recorded for another
    /// session (fork/import of an original call).
    case duplicateOriginalCall = "duplicate_original_call"
    /// Same real call, recognised through the adapter's call key, seen from
    /// another source or tool.
    case duplicateCall = "duplicate_call"
    /// The source's storage layout or version is not one this adapter reads.
    case unsupportedFormat = "unsupported_format"
    /// A cumulative counter moved in a way whose meaning is not established
    /// (reset, fork of a counter, correction). Nothing is credited from it.
    case cumulativeBoundaryUnclear = "cumulative_boundary_unclear"
    /// The record carries no identity stable enough to deduplicate.
    case missingCallIdentity = "missing_call_identity"
    /// Recognised, but the tools' own event is not a model call (summary,
    /// snapshot, rate limit notice, context size report).
    case notAModelCall = "not_a_model_call"
    /// A local or test model (lm-studio, ollama, a fake provider …): no model
    /// service was used, and points could be farmed for free.
    case localModelExcluded = "local_model_excluded"

    public var displayName: String {
        switch self {
        case .unparsableRecord: "읽을 수 없는 줄"
        case .missingSessionHeader: "세션 헤더 없음"
        case .unsupportedSchemaVersion: "지원하지 않는 로그 버전"
        case .missingResponseID: "응답 식별자 없음"
        case .missingUsage: "usage 없음"
        case .missingTimestamp: "시각 없음"
        case .invalidTimestamp: "잘못된 시각"
        case .invalidTokenField: "토큰 값 형식 오류"
        case .tokenOutOfRange: "토큰 값 범위 초과"
        case .unknownStopReason: "알 수 없는 종료 사유"
        case .stopReasonError: "오류로 종료된 호출"
        case .stopReasonAborted: "중단된 호출"
        case .providerNotVerified: "검증되지 않은 provider"
        case .oversizedRecord: "너무 큰 레코드"
        case .subagentExcluded: "서브에이전트 로그"
        case .sourcePaused: "읽기 일시정지"
        case .identityConflict: "같은 ID의 다른 사용량"
        case .inheritedPreConnection: "연결 이전 시각의 상속 기록"
        case .duplicateOriginalCall: "다른 세션에 이미 기록된 원본 호출"
        case .duplicateCall: "다른 도구·소스에 이미 기록된 같은 호출"
        case .unsupportedFormat: "지원하지 않는 저장 형식"
        case .cumulativeBoundaryUnclear: "누적값 의미 미확인"
        case .missingCallIdentity: "호출 식별자 없음"
        case .notAModelCall: "모델 호출이 아닌 기록"
        case .localModelExcluded: "로컬·테스트 모델"
        }
    }
}

/// Outcome of reading one log line.
public enum UsageLineVerdict: Sendable, Hashable {
    /// Reward-eligible record.
    case accepted(UsageEvent)
    /// Valid record that must not be rewarded, with the reason kept locally.
    case rejected(UsageEvent?, UsageRejectionReason)
    /// Nothing to do (title, tool result, user message, unknown-but-harmless).
    case ignored
    /// Session header; the scanner keeps it as context for the following lines.
    case sessionHeader(OMPLogParser.SessionHeader)
}

/// Reward rule. Fixed values for this milestone; no UI changes them.
public struct UsageRewardRule: Sendable, Hashable, Codable {
    public let ruleID: String
    public let tokensPerPoint: Int
    /// The provider whose usage fields were verified first (M3). Kept as a
    /// record: since 2026-09-24 every model service counts and only local and
    /// test models are left out (`PiProviderPolicy`).
    public let verifiedProviders: Set<String>

    public init(ruleID: String, tokensPerPoint: Int, verifiedProviders: Set<String>) {
        self.ruleID = ruleID
        self.tokensPerPoint = tokensPerPoint
        self.verifiedProviders = verifiedProviders
    }

    /// `omp-noncache-v1`: confirmed non-cached input + confirmed output,
    /// 10,000 accepted tokens = 1 P. Cache reads and writes are excluded, and
    /// `totalTokens` is never used to derive them back.
    public static let ompNonCacheV1 = UsageRewardRule(
        ruleID: "omp-noncache-v1",
        tokensPerPoint: 10_000,
        verifiedProviders: ["commandcode"]
    )

    /// Accepted tokens for one event, or nil when the sum overflows.
    public func acceptedTokens(for event: UsageEvent) -> Int? {
        let (inputPlusOutput, overflow1) = event.inputTokens.addingReportingOverflow(event.outputTokens)
        guard !overflow1 else { return nil }
        return inputPlusOutput
    }

    /// Integer point conversion that keeps the remainder.
    public func convert(totalAcceptedTokens: Int) -> (points: Int, remainder: Int) {
        guard tokensPerPoint > 0 else { return (0, totalAcceptedTokens) }
        return (totalAcceptedTokens / tokensPerPoint, totalAcceptedTokens % tokensPerPoint)
    }
}

public enum UsageRealmScope {
    /// Usage rewards are only ever written to the production wallet.
    public static let rewardRealm: Realm = .production
}

public enum UsageCalendar {
    /// Day boundaries for display: events are stored in UTC, the UI aggregates
    /// by Asia/Seoul.
    public static var seoul: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }
}
