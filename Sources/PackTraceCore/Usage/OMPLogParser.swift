import Foundation

/// Parser for OMP session JSONL. Pure: no file system, no network, no database.
/// Everything it emits is either a normalised event, a rejection reason, or an
/// explicit "nothing to do". Raw content is never carried out of the parser.
///
/// Contract recorded in docs/OMP_USAGE_SCHEMA.md.
public enum OMPLogParser {
    /// Values the parser needs from the surrounding file.
    public struct Context: Sendable, Hashable {
        /// Session id taken from the file name; confirmed by the header.
        public var sessionID: String?
        /// Schema version from the session header, when one was seen.
        public var schemaVersion: Int?
        /// True when the file is a subagent transcript (depth 3); never rewarded.
        public var isSubagentTranscript: Bool

        public init(sessionID: String? = nil, schemaVersion: Int? = nil, isSubagentTranscript: Bool = false) {
            self.sessionID = sessionID
            self.schemaVersion = schemaVersion
            self.isSubagentTranscript = isSubagentTranscript
        }
    }

    public struct SessionHeader: Sendable, Hashable {
        public var id: String
        public var version: Int
        /// Origin session when this file was produced by a fork or an import
        /// (`parentSession` in the header, observed in OMP 18.2.8).
        public var parentSession: String?
    }

    /// Schema version this parser was written against.
    public static let supportedSchemaVersion = 3

    /// Largest value accepted in a single token field. Observed maximum in the
    /// real corpus is 849,664 for cache reads; anything near this bound is
    /// already implausible and is rejected instead of clamped.
    public static let maximumTokenFieldValue = 1_000_000_000
    /// Timestamps must be a plausible epoch-millisecond value (2001..2100).
    public static let minimumTimestampMilliseconds = 978_307_200_000
    public static let maximumTimestampMilliseconds = 4_102_444_800_000

    private static let rewardableStopReasons: Set<String> = ["stop", "toolUse"]

    /// Parses one complete log line.
    public static func parse(line: Data, context: Context) -> UsageLineVerdict {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .rejected(nil, .unparsableRecord)
        }
        switch object["type"] as? String {
        case "session":
            guard let id = object["id"] as? String,
                  let version = strictInt(object["version"])
            else {
                return .ignored
            }
            let parent = (object["parentSession"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .sessionHeader(SessionHeader(id: id, version: version, parentSession: parent))
        case "message":
            return parseMessage(object, context: context)
        default:
            // title, custom, custom_message, model_change, thinking_level_change
            // and anything unknown: no usage of the supported kind.
            return .ignored
        }
    }

    private static func parseMessage(_ object: [String: Any], context: Context) -> UsageLineVerdict {
        guard let message = object["message"] as? [String: Any] else { return .ignored }
        guard (message["role"] as? String) == "assistant" else { return .ignored }

        // A subagent transcript is never rewarded: its relationship to the
        // parent session is not verified.
        if context.isSubagentTranscript {
            return .rejected(nil, .subagentExcluded)
        }
        guard let schemaVersion = context.schemaVersion else {
            return .rejected(nil, .missingSessionHeader)
        }
        guard schemaVersion == supportedSchemaVersion else {
            return .rejected(nil, .unsupportedSchemaVersion)
        }
        guard let responseID = message["responseId"] as? String, !responseID.isEmpty else {
            return .rejected(nil, .missingResponseID)
        }
        guard let sessionID = context.sessionID, !sessionID.isEmpty else {
            return .rejected(nil, .missingResponseID)
        }

        guard let timestamp = strictInt(message["timestamp"]) else {
            return message["timestamp"] == nil
                ? .rejected(nil, .missingTimestamp)
                : .rejected(nil, .invalidTimestamp)
        }
        guard timestamp >= minimumTimestampMilliseconds, timestamp <= maximumTimestampMilliseconds else {
            return .rejected(nil, .invalidTimestamp)
        }
        var completedAt: Int?
        if let rawCompleted = message["completedAt"] {
            guard let value = strictInt(rawCompleted),
                  value >= minimumTimestampMilliseconds,
                  value <= maximumTimestampMilliseconds
            else {
                return .rejected(nil, .invalidTimestamp)
            }
            completedAt = value
        }

        guard let usage = message["usage"] as? [String: Any] else {
            return .rejected(nil, .missingUsage)
        }
        guard let input = tokenField(usage, "input"),
              let output = tokenField(usage, "output")
        else {
            return .rejected(nil, .invalidTokenField)
        }
        let cacheRead = usage["cacheRead"] == nil ? 0 : tokenField(usage, "cacheRead")
        let cacheWrite = usage["cacheWrite"] == nil ? 0 : tokenField(usage, "cacheWrite")
        guard let cacheRead, let cacheWrite else {
            return .rejected(nil, .invalidTokenField)
        }
        for value in [input, output, cacheRead, cacheWrite] where value > maximumTokenFieldValue {
            return .rejected(nil, .tokenOutOfRange)
        }

        let provider = message["provider"] as? String ?? ""
        let model = message["model"] as? String ?? ""
        let stopReason = message["stopReason"] as? String ?? ""

        let event = UsageEvent(
            id: UsageEventID(sessionID: sessionID, responseID: responseID),
            sessionID: sessionID,
            responseID: responseID,
            provider: provider,
            model: model,
            stopReason: stopReason,
            occurredAtMilliseconds: timestamp,
            completedAtMilliseconds: completedAt,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )

        // Accepted tokens are added with checked arithmetic so a record that
        // cannot be summed safely never reaches the reward computation.
        let (accepted, overflow) = input.addingReportingOverflow(output)
        guard !overflow, accepted <= maximumTokenFieldValue else {
            return .rejected(event, .tokenOutOfRange)
        }

        switch stopReason {
        case let reason where rewardableStopReasons.contains(reason):
            break
        case "error":
            return .rejected(event, .stopReasonError)
        case "aborted":
            return .rejected(event, .stopReasonAborted)
        default:
            return .rejected(event, .unknownStopReason)
        }

        // Any model service counts, as for the other pi-family tools: the
        // normalised usage means the same for every provider (cache reads
        // exceed `input` in 95–99% of cached calls on commandcode,
        // openai-codex, openrouter and codex-lb alike, checked 2026-09-24).
        // Models running on this Mac and test fakes cost nothing and are not
        // rewarded. Until then only commandcode was counted.
        guard !provider.isEmpty else {
            return .rejected(event, .providerNotVerified)
        }
        guard PiProviderPolicy.isModelService(provider) else {
            return .rejected(event, .localModelExcluded)
        }

        // `input` is already the non-cached input and `output` already contains
        // reasoning tokens, so no further adjustment is applied here.
        return .accepted(event)
    }

    /// Accepts only JSON integers. Strings, booleans, null, floats and values
    /// outside the representable range are rejected rather than coerced.
    static func strictInt(_ value: Any?) -> Int? {
        guard let value else { return nil }
        switch value {
        case let number as NSNumber:
            // JSONSerialization maps both booleans and numbers to NSNumber.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(.towardZero) else { return nil }
            // 2^53-1 keeps every accepted integer exactly representable, so the
            // conversion below can never trap on an out-of-range double.
            guard abs(double) <= 9_007_199_254_740_991 else { return nil }
            return Int(double)
        default:
            return nil
        }
    }

    /// Token fields must be present, integral and non-negative.
    private static func tokenField(_ usage: [String: Any], _ key: String) -> Int? {
        guard let raw = usage[key], !(raw is NSNull) else { return nil }
        guard let value = strictInt(raw) else { return nil }
        return value >= 0 ? value : nil
    }
}
