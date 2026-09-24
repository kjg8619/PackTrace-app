import Foundation

/// Claude Code usage reader.
///
/// Contract (verified on `claude 2.1.280`, docs/USAGE_SOURCES.md §5): sessions
/// are JSONL transcripts under `~/.claude/projects/<slug>/<session>.jsonl`, and
/// only `assistant` records carry confirmed usage. Status lines, cost totals and
/// context ratios are not reward evidence and are never read here.
///
/// Subagents (`<session>/subagents/agent-*.jsonl`, `isSidechain`) are their own
/// API calls and count. A forked subagent's transcript can repeat the parent's
/// last calls; those copies keep the parent's session and request id, so they
/// are the same event and are counted once (checked on real transcripts,
/// 2026-09-24: 3 of 1,460 subagent calls were such copies).
public struct ClaudeCodeUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "claude-transcript-1"

    private let reader: UsageJSONLReader

    public init(reader: UsageJSONLReader = UsageJSONLReader()) {
        self.reader = reader
    }

    public var tool: UsageToolKind { .claudeCode }

    // MARK: - Discovery

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: root.path)
        return [
            UsageSourceCandidate(
                identity: UsageSourceIdentity(tool: .claudeCode, url: root),
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
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return UsageSourceInspection(support: .empty, detail: "폴더가 아직 없습니다")
        }
        let files = reader.files(under: root, matching: { $0.hasSuffix(".jsonl") }, limit: 1)
        guard let first = files.first else {
            return UsageSourceInspection(
                support: .empty,
                detail: "transcript가 아직 없습니다",
                providerScope: ["Claude Code assistant 확정 usage"],
                excluded: ["statusline·비용 합계·컨텍스트 비율", "스트리밍 중간값"]
            )
        }
        // The transcripts do not carry the CLI version, so it is left unknown
        // rather than guessed from the file's own timestamps.
        let sample = (try? reader.readPrefix(of: first, maxBytes: 128 * 1024)) ?? Data()
        let sawAssistantUsage = reader.records(in: sample).contains { record in
            guard record.complete,
                  let object = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any] else { return false }
            return usage(in: object) != nil
        }
        guard sawAssistantUsage else {
            return UsageSourceInspection(
                support: .unsupportedVersion,
                detail: "형식은 읽었지만 확정 usage 필드를 찾지 못했습니다"
            )
        }
        return UsageSourceInspection(
            support: .supported,
            toolVersion: nil,
            formatVersion: Self.formatVersion,
            detail: "transcript JSONL · assistant.message.usage",
            providerScope: ["Claude Code assistant 확정 usage(서브에이전트 포함)"],
            excluded: ["statusline·비용 합계·컨텍스트 비율", "스트리밍 중간값"]
        )
    }

    // MARK: - Slice

    public func scanSlice(_ request: UsageSliceRequest) async throws -> UsageSliceOutput {
        var output = UsageSliceOutput()
        let root = URL(fileURLWithPath: request.source.rootPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            output.status = .rootMissing
            output.statusReason = "root_missing"
            return output
        }
        let files = reader.allFiles(under: root, matching: { $0.hasSuffix(".jsonl") })
        output.counters.filesConsidered = files.count
        guard !files.isEmpty else {
            output.skippedReason = "no_transcripts"
            return output
        }

        let known = Dictionary(uniqueKeysWithValues: request.fileCheckpoints.map { ($0.relativePath, $0) })
        var budgets = (records: 0, bytes: 0, files: 0, newFiles: 0)

        for file in files {
            let relative = reader.relativePath(of: file.url, under: root)
            let checkpoint = known[relative]
            // Unchanged since the last read: nothing to look up or read.
            if let checkpoint, checkpoint.baselineDone, file.size == checkpoint.byteOffset { continue }
            let plan = UsageFilePlan.decide(
                relativePath: relative,
                checkpoint: checkpoint,
                size: file.size,
                modified: file.modified,
                connectedAt: request.source.connectedAt,
                isBaselining: request.isBaselining,
                deviceID: reader.device(file.url),
                inode: reader.inode(file.url),
                now: request.now
            )
            switch plan {
            case .skip:
                continue
            case .markHistory:
                guard budgets.newFiles < request.budget.maxNewFiles else {
                    output.moreWork = true
                    continue
                }
                budgets.newFiles += 1
                output.fileCheckpoints.append(
                    UsageFilePlan.historyCheckpoint(
                        relativePath: relative,
                        size: file.size,
                        deviceID: reader.device(file.url),
                        inode: reader.inode(file.url),
                        now: request.now
                    )
                )
            case let .read(checkpoint, _):
                guard budgets.files < request.budget.maxFiles,
                      budgets.records < request.budget.maxRecords,
                      budgets.bytes < request.budget.maxBytes else {
                    output.moreWork = true
                    continue
                }
                budgets.files += 1
                readIncrement(
                    file: file.url,
                    checkpoint: checkpoint,
                    size: file.size,
                    request: request,
                    budgets: &budgets,
                    into: &output
                )
            }
        }
        return output
    }

    private func readIncrement(
        file: URL,
        checkpoint: UsageFileCheckpoint,
        size: Int64,
        request: UsageSliceRequest,
        budgets: inout (records: Int, bytes: Int, files: Int, newFiles: Int),
        into output: inout UsageSliceOutput
    ) {
        let start = checkpoint.byteOffset
        let window = min(max(0, request.budget.maxBytes - budgets.bytes), Int(max(0, size - start)))
        guard window > 0 else {
            output.moreWork = true
            return
        }
        let data = (try? reader.readRange(of: file, from: start, length: window)) ?? Data()
        budgets.bytes += data.count
        output.counters.filesRead += 1
        output.counters.bytesRead += data.count

        var consumed = 0
        for record in reader.records(in: data) {
            guard record.complete else { break }
            let recordStart = start + Int64(consumed)
            consumed += record.bytes
            budgets.records += 1
            output.counters.recordsSeen += 1
            guard let object = try? JSONSerialization.jsonObject(with: record.data) as? [String: Any] else {
                output.counters.errorCount += 1
                continue
            }
            guard let usage = usage(in: object) else { continue }

            let sessionID = (object["sessionId"] as? String) ?? "unknown-session"
            output.sessions.append(UsageSessionObservation(sessionID: sessionID, schemaVersion: 1))

            // Subagent records are read like any other: a subagent's calls
            // are separate API calls, and a copy of a parent call has the
            // parent's session and request id, so it is the same event.
            guard let callID = (object["requestId"] as? String) ?? ((object["message"] as? [String: Any])?["id"] as? String),
                  !callID.isEmpty else {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .missingCallIdentity))
                continue
            }
            guard let occurred = (object["timestamp"] as? String).flatMap(UsageJSONLReader.parseTimestamp) else {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTimestamp))
                continue
            }
            let message = object["message"] as? [String: Any]
            var event = UsageEvent(
                id: UsageEventID(tool: .claudeCode, sessionID: sessionID, responseID: callID),
                sessionID: sessionID,
                responseID: callID,
                provider: "anthropic",
                model: (message?["model"] as? String) ?? "unknown",
                stopReason: (message?["stop_reason"] as? String) ?? "completed",
                occurredAtMilliseconds: Int(occurred.timeIntervalSince1970 * 1000),
                completedAtMilliseconds: nil,
                // Anthropic reports uncached input and cache reads separately, so
                // `input_tokens` is already the non-cached part.
                inputTokens: usage.input,
                outputTokens: usage.output,
                cacheReadTokens: usage.cacheRead,
                cacheWriteTokens: usage.cacheCreation
            )
            // Thinking tokens are reported inside output_tokens; they are kept
            // for diagnostics and never added.
            event.reasoningTokens = usage.thinking
            event.normalizationVersion = 2
            if UsageFilePlan.isCreditable(
                recordStart: recordStart,
                checkpoint: checkpoint,
                occurredAt: occurred,
                connectedAt: request.source.connectedAt
            ) {
                output.entries.append(UsageBatchEntry(event: event, status: .accepted))
            } else {
                // Found in a file first seen after the connection, but it
                // happened before it: history, recorded so a copy is not paid.
                output.entries.append(UsageBatchEntry(event: event, status: .baseline, reason: .inheritedPreConnection))
            }
        }

        guard consumed > 0 else {
            // One record longer than the whole window: it can never be read as a
            // whole here, and retrying it every pass used the slice's byte budget
            // and starved every other file. It is skipped and reported.
            if data.count >= reader.maxLineBytes, let end = reader.endOfRecord(in: file, from: start, size: size) {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .oversizedRecord))
                output.fileCheckpoints.append(
                    UsageFileCheckpoint(
                        relativePath: checkpoint.relativePath,
                        deviceID: checkpoint.deviceID,
                        inode: checkpoint.inode,
                        byteOffset: end,
                        baselineOffset: checkpoint.baselineOffset,
                        baselineDone: true,
                        fileSize: size,
                        status: .ok,
                        reason: "oversized_record_skipped",
                        updatedAt: request.now
                    )
                )
                if end < size { output.moreWork = true }
            }
            return
        }
        output.fileCheckpoints.append(
            UsageFileCheckpoint(
                relativePath: checkpoint.relativePath,
                deviceID: checkpoint.deviceID,
                inode: checkpoint.inode,
                byteOffset: checkpoint.byteOffset + Int64(consumed),
                baselineOffset: checkpoint.baselineOffset,
                baselineDone: true,
                fileSize: size,
                status: .ok,
                reason: nil,
                updatedAt: request.now
            )
        )
        if consumed < window { output.moreWork = true }
    }

    // MARK: - Records

    struct Usage {
        var input: Int
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var thinking: Int?
    }

    /// Confirmed usage from an `assistant` record. Anything else (user, system,
    /// attachment, summary, status) is not usage evidence.
    func usage(in record: [String: Any]) -> Usage? {
        guard record["type"] as? String == "assistant",
              let message = record["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        guard let input = reader.intValue(usage["input_tokens"]),
              let output = reader.intValue(usage["output_tokens"]) else { return nil }
        return Usage(
            input: input,
            output: output,
            cacheRead: reader.intValue(usage["cache_read_input_tokens"]) ?? 0,
            cacheCreation: reader.intValue(usage["cache_creation_input_tokens"]) ?? 0,
            thinking: (usage["output_tokens_details"] as? [String: Any]).flatMap { reader.intValue($0["thinking_tokens"]) }
        )
    }
}
