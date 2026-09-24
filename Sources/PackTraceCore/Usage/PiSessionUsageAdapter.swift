import Foundation

/// pi-family session reader: pi, omo and senpi.
///
/// Contract (observed 2026-09-24 on pi 0.87.0, omo 5.0.0-beta.82, senpi
/// 2026.8.24, docs/USAGE_SOURCES.md §12): the same session JSONL as OMP — a
/// `session` header with `version: 3` and `id`, then entries `{type, id,
/// parentId, timestamp, message}`. Assistant messages carry a normalised
/// `usage` whose `input` is already the non-cached input (cache reads exceed it
/// in most records) and whose `output` already includes reasoning.
///
/// Differences from the OMP reader:
/// - any model service counts; local and test models do not (`PiProviderPolicy`);
/// - a call without a provider response id is identified by its entry id;
/// - subagent runs (`<session>/<agent>/run-N/session.jsonl`) are their own
///   sessions with their own calls, so they are read; a call copied into
///   another session is recognised by its response id or its call key.
///
/// omo migrated senpi's sessions by copying them: the same entry id and time
/// then appear under both tools, and the call key makes the second one a
/// duplicate instead of a second payment.
public struct PiSessionUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "pi-session-3"

    public let tool: UsageToolKind
    private let reader: UsageJSONLReader

    public init(tool: UsageToolKind, reader: UsageJSONLReader = UsageJSONLReader()) {
        precondition(Self.tools.contains(tool), "not a pi-family tool: \(tool)")
        self.tool = tool
        self.reader = reader
    }

    public static let tools: [UsageToolKind] = [.pi, .omo, .senpi]

    /// Where each tool keeps its sessions, relative to the home folder.
    public static func defaultRoot(for tool: UsageToolKind) -> String {
        switch tool {
        case .omo: ".omo/sessions"
        case .senpi: ".senpi/agent/sessions"
        default: ".pi/agent/sessions"
        }
    }

    // MARK: - Discovery

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        let root = home.appendingPathComponent(Self.defaultRoot(for: tool), isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: root.path)
        return [
            UsageSourceCandidate(
                identity: UsageSourceIdentity(tool: tool, url: root),
                origin: "default",
                note: exists ? nil : "not found",
                exists: exists
            )
        ]
    }

    // MARK: - Inspection

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let root = URL(fileURLWithPath: source.rootPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return UsageSourceInspection(support: .empty, detail: "폴더가 아직 없습니다")
        }
        guard let first = reader.files(under: root, matching: { $0.hasSuffix(".jsonl") }, limit: 1).first else {
            return UsageSourceInspection(support: .empty, detail: "세션이 아직 없습니다", providerScope: Self.scope, excluded: Self.excluded)
        }
        guard let header = header(of: first), header.version == OMPLogParser.supportedSchemaVersion else {
            return UsageSourceInspection(support: .unsupportedVersion, detail: "세션 헤더가 없거나 버전이 다릅니다")
        }
        return UsageSourceInspection(
            support: .supported,
            formatVersion: "\(Self.formatVersion) (v\(header.version))",
            detail: "세션 JSONL · assistant message.usage",
            providerScope: Self.scope,
            excluded: Self.excluded
        )
    }

    private static let scope = ["모델 서비스의 확정 assistant usage(비캐시 입력 + 출력)"]
    private static let excluded = ["로컬·테스트 모델(lm-studio·ollama·omlx·faux 등)", "오류·중단으로 끝난 호출", "캐시 읽기·쓰기"]

    // MARK: - Slice

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        var headers: [URL: OMPLogParser.SessionHeader?] = [:]
        let scan = UsageJSONLScan(reader: reader, matches: { $0.hasSuffix(".jsonl") })
        return scan.scan(request) { record in
            if headers[record.file] == nil {
                headers[record.file] = .some(header(of: record.file))
            }
            // A file without a session header (a run's goal state, for
            // example) holds no calls of this kind.
            guard let header = headers[record.file] ?? nil else { return .skip }
            return parse(record.object, header: header)
        }
    }

    /// The session header on the first line of a file.
    func header(of file: URL) -> OMPLogParser.SessionHeader? {
        guard let prefix = try? reader.readPrefix(of: file, maxBytes: 64 * 1024),
              let first = reader.records(in: prefix).first, first.complete,
              case let .sessionHeader(header) = OMPLogParser.parse(line: first.data, context: .init())
        else { return nil }
        return header
    }

    // MARK: - Records

    func parse(_ object: [String: Any], header: OMPLogParser.SessionHeader) -> UsageJSONLScan.Outcome {
        guard object["type"] as? String == "message",
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? [String: Any]
        else { return .skip }
        let session = UsageSessionObservation(sessionID: header.id, parentSessionID: header.parentSession, schemaVersion: header.version)
        func reject(_ reason: UsageRejectionReason, _ event: UsageEvent? = nil) -> UsageJSONLScan.Outcome {
            .entry(UsageBatchEntry(event: event, status: event == nil ? .unsupported : .excluded, reason: reason), occurredAt: nil, session: session)
        }
        guard header.version == OMPLogParser.supportedSchemaVersion else { return reject(.unsupportedSchemaVersion) }
        guard let entryID = object["id"] as? String, !entryID.isEmpty else { return reject(.missingCallIdentity) }
        guard let timestamp = OMPLogParser.strictInt(message["timestamp"]),
              timestamp >= OMPLogParser.minimumTimestampMilliseconds,
              timestamp <= OMPLogParser.maximumTimestampMilliseconds
        else { return reject(message["timestamp"] == nil ? .missingTimestamp : .invalidTimestamp) }

        func token(_ key: String, required: Bool) -> Int?? {
            guard let raw = usage[key], !(raw is NSNull) else { return required ? .none : .some(0) }
            guard let value = OMPLogParser.strictInt(raw), value >= 0 else { return .none }
            return .some(value)
        }
        guard case let .some(input?) = token("input", required: true),
              case let .some(output?) = token("output", required: true),
              case let .some(cacheRead?) = token("cacheRead", required: false),
              case let .some(cacheWrite?) = token("cacheWrite", required: false)
        else { return reject(.invalidTokenField) }
        for value in [input, output, cacheRead, cacheWrite] where value > OMPLogParser.maximumTokenFieldValue {
            return reject(.tokenOutOfRange)
        }

        let provider = message["provider"] as? String ?? ""
        let responseID = (message["responseId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "entry:\(entryID)"
        var event = UsageEvent(
            id: UsageEventID(tool: tool, sessionID: header.id, responseID: responseID),
            sessionID: header.id,
            responseID: responseID,
            provider: provider,
            model: message["model"] as? String ?? "unknown",
            stopReason: message["stopReason"] as? String ?? "",
            occurredAtMilliseconds: timestamp,
            completedAtMilliseconds: nil,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite
        )
        event.reasoningTokens = OMPLogParser.strictInt(usage["reasoning"] ?? usage["reasoningTokens"])
        // The same entry (same id, same moment) under another session or
        // another pi-family tool is the same call.
        event.callKey = "pi-entry:\(entryID)@\(timestamp)"
        event.normalizationVersion = 1
        let occurred = Date(timeIntervalSince1970: Double(timestamp) / 1000)

        switch event.stopReason {
        case "stop", "toolUse": break
        case "error": return .entry(UsageBatchEntry(event: event, status: .excluded, reason: .stopReasonError), occurredAt: occurred, session: session)
        case "aborted": return .entry(UsageBatchEntry(event: event, status: .excluded, reason: .stopReasonAborted), occurredAt: occurred, session: session)
        default: return .entry(UsageBatchEntry(event: event, status: .excluded, reason: .unknownStopReason), occurredAt: occurred, session: session)
        }
        guard PiProviderPolicy.isModelService(provider) else {
            return .entry(UsageBatchEntry(event: event, status: .excluded, reason: .localModelExcluded), occurredAt: occurred, session: session)
        }
        return .entry(UsageBatchEntry(event: event, status: .accepted), occurredAt: occurred, session: session)
    }
}

/// Which providers count. Everything that reaches a model service counts;
/// models running on this Mac and test fakes do not.
public enum PiProviderPolicy {
    public static let localOrTest: Set<String> = [
        "faux", "lm-studio", "lmstudio", "ollama", "omlx", "mlx", "llama.cpp", "llamacpp", "local",
    ]

    public static func isModelService(_ provider: String) -> Bool {
        let name = provider.lowercased()
        return !name.isEmpty && !localOrTest.contains(name)
    }
}
