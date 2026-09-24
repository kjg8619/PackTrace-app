import Foundation

/// Kimi Code usage reader.
///
/// Contract (observed 2026-09-24, docs/USAGE_SOURCES.md §12):
/// `~/.kimi-code/sessions/**/session_<id>/agents/<agent>/wire.jsonl`; a model
/// step carries `event.usage` with `inputOther` (the non-cached input),
/// `inputCacheRead`, `inputCacheCreation` and `output`, plus `messageId` and
/// `finishReason`.
public struct KimiUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "kimi-wire-1"

    private let reader: UsageJSONLReader

    public init(reader: UsageJSONLReader = UsageJSONLReader()) {
        self.reader = reader
    }

    public var tool: UsageToolKind { .kimi }

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        let root = home.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: root.path)
        return [UsageSourceCandidate(identity: UsageSourceIdentity(tool: .kimi, url: root), origin: "default",
                                     note: exists ? nil : "not found", exists: exists)]
    }

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let root = URL(fileURLWithPath: source.rootPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return UsageSourceInspection(support: .empty, detail: "폴더가 아직 없습니다")
        }
        guard !reader.files(under: root, matching: { $0 == "wire.jsonl" }, limit: 1).isEmpty else {
            return UsageSourceInspection(support: .empty, detail: "세션 기록이 아직 없습니다")
        }
        return UsageSourceInspection(
            support: .supported,
            formatVersion: Self.formatVersion,
            detail: "wire.jsonl · event.usage",
            providerScope: ["모델 단계마다의 비캐시 입력(inputOther) + 출력"],
            excluded: ["오류·취소로 끝난 단계", "캐시 읽기·쓰기"]
        )
    }

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        UsageJSONLScan(reader: reader, matches: { $0 == "wire.jsonl" }).scan(request) { record in
            parse(record.object, sessionID: Self.sessionID(of: record.file))
        }
    }

    /// The `session_<id>` folder the file sits in.
    static func sessionID(of file: URL) -> String {
        file.pathComponents.last { $0.hasPrefix("session_") }.map { String($0.dropFirst("session_".count)) } ?? file.deletingLastPathComponent().lastPathComponent
    }

    func parse(_ object: [String: Any], sessionID: String) -> UsageJSONLScan.Outcome {
        guard let event = object["event"] as? [String: Any], let usage = event["usage"] as? [String: Any] else { return .skip }
        let session = UsageSessionObservation(sessionID: sessionID, schemaVersion: 1)
        guard let messageID = (event["messageId"] as? String) ?? (event["uuid"] as? String), !messageID.isEmpty else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .missingCallIdentity), occurredAt: nil, session: session)
        }
        guard let raw = OMPLogParser.strictInt(object["time"]) else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTimestamp), occurredAt: nil, session: session)
        }
        // Seconds or milliseconds, judged by magnitude.
        let milliseconds = raw > 100_000_000_000 ? raw : raw * 1000
        guard milliseconds >= OMPLogParser.minimumTimestampMilliseconds, milliseconds <= OMPLogParser.maximumTimestampMilliseconds else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTimestamp), occurredAt: nil, session: session)
        }
        func int(_ key: String) -> Int? {
            guard let raw = usage[key] else { return 0 }
            guard let value = OMPLogParser.strictInt(raw), value >= 0, value <= OMPLogParser.maximumTokenFieldValue else { return nil }
            return value
        }
        guard let input = int("inputOther"), let output = int("output"),
              let cacheRead = int("inputCacheRead"), let cacheWrite = int("inputCacheCreation") else {
            return .entry(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTokenField), occurredAt: nil, session: session)
        }
        var usageEvent = UsageEvent(
            id: UsageEventID(tool: .kimi, sessionID: sessionID, responseID: messageID),
            sessionID: sessionID,
            responseID: messageID,
            provider: "moonshot",
            model: event["model"] as? String ?? "kimi",
            stopReason: event["finishReason"] as? String ?? "",
            occurredAtMilliseconds: milliseconds,
            completedAtMilliseconds: nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        usageEvent.callKey = "kimi:\(messageID)"
        let occurred = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        switch usageEvent.stopReason.lowercased() {
        case "error":
            return .entry(UsageBatchEntry(event: usageEvent, status: .excluded, reason: .stopReasonError), occurredAt: occurred, session: session)
        case "cancelled", "canceled", "aborted", "interrupted":
            return .entry(UsageBatchEntry(event: usageEvent, status: .excluded, reason: .stopReasonAborted), occurredAt: occurred, session: session)
        default:
            return .entry(UsageBatchEntry(event: usageEvent, status: .accepted), occurredAt: occurred, session: session)
        }
    }
}
