import Foundation

/// Grok CLI usage reader.
///
/// Contract (observed 2026-09-24 on grok 1.0.40, docs/USAGE_SOURCES.md §12):
/// `~/.grok/sessions/**/updates.jsonl`, one `turn_completed` update per turn
/// with `prompt_id`, `stop_reason` and the turn's `usage`. `inputTokens`
/// includes cache reads (they never exceed it) and `totalTokens` equals input
/// plus output, so reasoning is inside `outputTokens`.
public struct GrokUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "grok-updates-1"

    private let reader: UsageJSONLReader

    public init(reader: UsageJSONLReader = UsageJSONLReader()) {
        self.reader = reader
    }

    public var tool: UsageToolKind { .grok }

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        let root = home.appendingPathComponent(".grok/sessions", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: root.path)
        return [UsageSourceCandidate(identity: UsageSourceIdentity(tool: .grok, url: root), origin: "default",
                                     note: exists ? nil : "not found", exists: exists)]
    }

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let root = URL(fileURLWithPath: source.rootPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return UsageSourceInspection(support: .empty, detail: "폴더가 아직 없습니다")
        }
        guard !reader.files(under: root, matching: { $0 == "updates.jsonl" }, limit: 1).isEmpty else {
            return UsageSourceInspection(support: .empty, detail: "세션 기록이 아직 없습니다")
        }
        return UsageSourceInspection(
            support: .supported,
            formatVersion: Self.formatVersion,
            detail: "updates.jsonl · turn_completed.usage",
            providerScope: ["턴마다의 비캐시 입력 + 출력"],
            excluded: ["오류로 끝난 턴", "캐시 읽기·쓰기"]
        )
    }

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        UsageJSONLScan(reader: reader, matches: { $0 == "updates.jsonl" }).scan(request) { record in
            parse(record.object)
        }
    }

    func parse(_ object: [String: Any]) -> UsageJSONLScan.Outcome {
        guard let params = object["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              update["sessionUpdate"] as? String == "turn_completed",
              let usage = update["usage"] as? [String: Any]
        else { return .skip }
        let sessionID = params["sessionId"] as? String ?? ""
        let session = sessionID.isEmpty ? nil : UsageSessionObservation(sessionID: sessionID, schemaVersion: 1)
        guard !sessionID.isEmpty, let promptID = update["prompt_id"] as? String, !promptID.isEmpty else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .missingCallIdentity), occurredAt: nil, session: session)
        }
        guard let seconds = OMPLogParser.strictInt(object["timestamp"]), seconds > 978_307_200, seconds < 4_102_444_800 else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTimestamp), occurredAt: nil, session: session)
        }
        func int(_ key: String) -> Int? {
            guard let raw = usage[key] else { return 0 }
            guard let value = OMPLogParser.strictInt(raw), value >= 0, value <= OMPLogParser.maximumTokenFieldValue else { return nil }
            return value
        }
        guard let input = int("inputTokens"), let output = int("outputTokens"),
              let cached = int("cachedReadTokens"), let created = int("cacheCreationTokens"), cached <= input else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTokenField), occurredAt: nil, session: session)
        }
        let model = (usage["modelUsage"] as? [String: Any])?.keys.sorted().first ?? "unknown"
        var event = UsageEvent(
            id: UsageEventID(tool: .grok, sessionID: sessionID, responseID: promptID),
            sessionID: sessionID,
            responseID: promptID,
            provider: "xai",
            model: model,
            stopReason: update["stop_reason"] as? String ?? "",
            occurredAtMilliseconds: seconds * 1000,
            completedAtMilliseconds: nil,
            // Input includes the cached part here; only the rest counts.
            inputTokens: input - cached,
            outputTokens: output,
            cacheReadTokens: cached,
            cacheWriteTokens: created
        )
        event.reasoningTokens = int("reasoningTokens")
        event.callKey = "grok:\(sessionID):\(promptID)"
        let occurred = Date(timeIntervalSince1970: Double(seconds))
        if event.stopReason == "error" || event.stopReason == "cancelled" {
            return .entry(UsageBatchEntry(event: event, status: .excluded, reason: .stopReasonError), occurredAt: occurred, session: session)
        }
        return .entry(UsageBatchEntry(event: event, status: .accepted), occurredAt: occurred, session: session)
    }
}
