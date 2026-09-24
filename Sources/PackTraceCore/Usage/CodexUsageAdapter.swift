import Foundation

/// Codex CLI usage reader.
///
/// Contract (verified on `codex-cli 0.155.1`, see docs/USAGE_SOURCES.md §4):
/// sessions are JSONL under `<root>/<YYYY>/<MM>/<DD>/rollout-*.jsonl`; a
/// `token_count` event carries both a cumulative `total_token_usage` and the
/// per-request `last_token_usage`.
///
/// The cumulative counter is the authority for *how much* happened, and the
/// per-request object is the authority for *which fields* to read. They are
/// never added together, a repeated notification (no increase) credits nothing,
/// and a decrease is treated as a reset whose meaning is not established.
public struct CodexUsageAdapter: UsageSourceAdapter {
    public static let formatVersion = "rollout-jsonl-1"
    /// How far back from a boundary to look for the counter value when a file
    /// that was marked as history grows: enough for the last events of a
    /// session, never the whole file.
    private let counterTailBytes: Int
    private let maxLineBytes: Int
    /// Cursor value for "not read yet": a history boundary is fixed without
    /// reading the file, so the counter and session are looked up only if the
    /// file ever grows.
    static let unknown = "?"

    public init(baselineTailBytes: Int = 512 * 1024, maxLineBytes: Int = 8 * 1024 * 1024) {
        self.counterTailBytes = baselineTailBytes
        self.maxLineBytes = maxLineBytes
    }

    public var tool: UsageToolKind { .codex }

    // MARK: - Discovery

    public func candidates(home: URL, environment: [String: String]) -> [UsageSourceCandidate] {
        var roots: [(URL, String)] = []
        if let override = environment["CODEX_HOME"], !override.isEmpty {
            roots.append((URL(fileURLWithPath: override).appendingPathComponent("sessions", isDirectory: true), "environment"))
        }
        roots.append((home.appendingPathComponent(".codex/sessions", isDirectory: true), "default"))

        return roots.map { url, origin in
            let exists = FileManager.default.fileExists(atPath: url.path)
            return UsageSourceCandidate(
                identity: UsageSourceIdentity(tool: .codex, url: url),
                origin: origin,
                note: exists ? nil : "not found",
                exists: exists
            )
        }
    }

    // MARK: - Inspection

    public func inspect(source: UsageSourceRecord) -> UsageSourceInspection {
        let root = URL(fileURLWithPath: source.rootPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            return UsageSourceInspection(support: .empty, detail: "폴더가 아직 없습니다")
        }
        guard isDirectory.boolValue else {
            return UsageSourceInspection(support: .notThisTool, detail: "폴더가 아닙니다")
        }
        let files: [URL]
        do {
            files = try sessionFiles(root: root, limit: 1)
        } catch {
            return .unreadable("세션 파일을 읽을 수 없습니다(권한)")
        }
        guard let first = files.first else {
            return UsageSourceInspection(
                support: .empty,
                detail: "세션 파일이 아직 없습니다",
                providerScope: ["Codex `token_count` 이벤트(누적+요청별)"],
                excluded: ["rate limit", "컨텍스트 크기", "누적값과 요청별 값의 동시 가산"]
            )
        }
        let head = (try? readPrefix(of: first, maxBytes: 64 * 1024)) ?? Data()
        guard let meta = firstMeta(in: head) else {
            return UsageSourceInspection(support: .unsupportedVersion, detail: "session_meta 레코드를 찾지 못했습니다")
        }
        return UsageSourceInspection(
            support: .supported,
            toolVersion: meta.cliVersion,
            formatVersion: Self.formatVersion,
            detail: "rollout JSONL · token_count 이벤트",
            providerScope: ["Codex `token_count` 이벤트(누적+요청별)"],
            excluded: ["rate limit", "컨텍스트 크기", "누적값과 요청별 값의 동시 가산", "증가분이 요청별 값과 맞지 않는 경우"]
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
        guard FileManager.default.isReadableFile(atPath: root.path) else {
            output.status = .permissionDenied
            output.statusReason = "permission_denied"
            output.counters.errorCount += 1
            return output
        }
        let files = UsageJSONLReader(maxLineBytes: maxLineBytes).allFiles(under: root, matching: Self.isSessionFile)
        output.counters.filesConsidered = files.count
        guard !files.isEmpty else {
            output.skippedReason = "no_session_files"
            return output
        }

        let known = Dictionary(uniqueKeysWithValues: request.fileCheckpoints.map { ($0.relativePath, $0) })
        var budgets = (records: 0, bytes: 0, files: 0, newFiles: 0)

        for file in files {
            let relative = relativePath(of: file.url, under: root)
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
                deviceID: UInt64(max(0, fileDevice(file.url))),
                inode: fileInode(file.url),
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
                markHistory(file: file, relative: relative, request: request, into: &output)
            case let .read(checkpoint, fromStart):
                guard budgets.files < request.budget.maxFiles,
                      budgets.records < request.budget.maxRecords,
                      budgets.bytes < request.budget.maxBytes else {
                    output.moreWork = true
                    continue
                }
                budgets.files += 1
                readIncrement(
                    file: file.url,
                    relative: relative,
                    from: checkpoint,
                    fromStart: fromStart,
                    size: file.size,
                    request: request,
                    budgets: &budgets,
                    into: &output
                )
            }
        }
        return output
    }

    static func isSessionFile(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
    }

    // MARK: - Baseline

    /// History: a boundary at the file's current end, without reading it. The
    /// counter value and the session id at that boundary are only needed if the
    /// file ever grows, so they are recorded as unknown and looked up then.
    private func markHistory(
        file: UsageJSONLReader.FoundFile,
        relative: String,
        request: UsageSliceRequest,
        into output: inout UsageSliceOutput
    ) {
        output.fileCheckpoints.append(
            UsageFilePlan.historyCheckpoint(
                relativePath: relative,
                size: file.size,
                deviceID: UInt64(max(0, fileDevice(file.url))),
                inode: fileInode(file.url),
                now: request.now
            )
        )
        // Written even though unknown: a boundary fixed again (a replaced file,
        // a restored profile) must not keep a previous file's values.
        for key in [counterKey(relative), sessionKey(relative)] {
            output.cursors.append(UsageCursor(cursorKey: key, kind: .recordIndex, payload: Self.unknown, updatedAt: request.now))
        }
    }

    /// The counter value at `offset`: the last cumulative total before it.
    /// Absent (no usage yet) means zero, which is a real value.
    private func counterValue(in file: URL, before offset: Int64) -> Int {
        let tailStart = max(0, offset - Int64(counterTailBytes))
        let tail = (try? readRange(of: file, from: tailStart, length: Int(offset - tailStart))) ?? Data()
        return lastCumulative(in: tail, upTo: lastCompleteRecordEnd(in: tail)) ?? 0
    }

    // MARK: - Increment

    private func readIncrement(
        file: URL,
        relative: String,
        from checkpoint: UsageFileCheckpoint,
        fromStart: Bool,
        size: Int64,
        request: UsageSliceRequest,
        budgets: inout (records: Int, bytes: Int, files: Int, newFiles: Int),
        into output: inout UsageSliceOutput
    ) {
        let start = checkpoint.byteOffset
        // Where the counter and the session stood at `start`. Read from the
        // start of the file they are zero and the header; otherwise they come
        // from the cursors, or from the file itself for a history boundary that
        // was fixed without reading it.
        var counter: Int
        var knownSession: String?
        if fromStart {
            counter = 0
            knownSession = nil
        } else {
            let storedCounter = request.cursors[counterKey(relative)]?.payload
            counter = storedCounter.flatMap(Int.init) ?? counterValue(in: file, before: start)
            let storedSession = request.cursors[sessionKey(relative)]?.payload
            if let storedSession, storedSession != Self.unknown {
                knownSession = storedSession
            } else {
                knownSession = firstMeta(in: (try? readPrefix(of: file, maxBytes: 64 * 1024)) ?? Data())?.id
            }
        }
        let remaining = max(0, request.budget.maxBytes - budgets.bytes)
        let window = min(remaining, Int(max(0, size - start)))
        guard window > 0 else {
            output.moreWork = true
            return
        }
        let data = (try? readRange(of: file, from: start, length: window)) ?? Data()
        budgets.bytes += data.count
        output.counters.filesRead += 1
        output.counters.bytesRead += data.count

        var consumed: Int64 = 0
        for line in records(in: data) {
            guard line.complete else { break } // never consume a partial record
            let recordStart = start + consumed
            consumed += Int64(line.bytes)
            budgets.records += 1
            output.counters.recordsSeen += 1
            guard let record = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else {
                output.counters.errorCount += 1
                continue
            }
            if let meta = sessionMeta(in: record), let sessionID = meta.id {
                knownSession = sessionID
                output.sessions.append(UsageSessionObservation(sessionID: sessionID, schemaVersion: 1))
            }
            guard isTokenCount(record) else { continue }

            guard let total = cumulativeTotal(record) else { continue }
            let previous = counter
            if total < previous {
                // A decrease means a reset, a fork or a correction. The meaning
                // is not established, so nothing is credited and the counter is
                // simply re-based.
                output.entries.append(
                    UsageBatchEntry(
                        event: nil,
                        status: .excluded,
                        reason: .cumulativeBoundaryUnclear
                    )
                )
                counter = total
                continue
            }
            let delta = total - previous
            counter = total
            guard delta > 0 else {
                // A repeated notification with no increase is not a new call.
                continue
            }
            guard let sessionID = knownSession, let ordinal = record["ordinal"] as? Int else {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .missingCallIdentity))
                continue
            }
            guard let last = lastUsage(record), last.total == delta else {
                // The cumulative jump does not match a single request: splitting
                // it would be a guess, so the increase is left uncredited.
                output.entries.append(UsageBatchEntry(event: nil, status: .excluded, reason: .cumulativeBoundaryUnclear))
                continue
            }
            guard let event = makeEvent(sessionID: sessionID, ordinal: ordinal, last: last, record: record, request: request) else {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .invalidTokenField))
                continue
            }
            let occurred = Date(timeIntervalSince1970: Double(event.occurredAtMilliseconds) / 1000)
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
            // Nothing complete to consume: keep the position where it is — unless
            // one record is longer than the whole window. That one can never be
            // read as a whole here, and retrying it every pass used the slice's
            // byte budget and starved every other file, so it is skipped and
            // reported. The counter is left where it was: the next record's
            // increase will not match a single request and is not credited.
            let reader = UsageJSONLReader(maxLineBytes: maxLineBytes)
            if data.count >= maxLineBytes, let end = reader.endOfRecord(in: file, from: start, size: size) {
                output.entries.append(UsageBatchEntry(event: nil, status: .unsupported, reason: .oversizedRecord))
                output.fileCheckpoints.append(
                    UsageFileCheckpoint(
                        relativePath: relative,
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
                output.cursors.append(UsageCursor(cursorKey: counterKey(relative), kind: .recordIndex, payload: String(counter), updatedAt: request.now))
                output.cursors.append(UsageCursor(cursorKey: sessionKey(relative), kind: .recordIndex, payload: knownSession ?? Self.unknown, updatedAt: request.now))
                if end < size { output.moreWork = true }
            }
            return
        }
        output.fileCheckpoints.append(
            UsageFileCheckpoint(
                relativePath: relative,
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
        output.cursors.append(
            UsageCursor(
                cursorKey: counterKey(relative),
                kind: .recordIndex,
                payload: String(counter),
                updatedAt: request.now
            )
        )
        // The session id is remembered: a later slice that contains no header
        // record would otherwise lose it.
        output.cursors.append(
            UsageCursor(
                cursorKey: sessionKey(relative),
                kind: .recordIndex,
                payload: knownSession ?? Self.unknown,
                updatedAt: request.now
            )
        )
        if consumed < Int64(window) {
            output.moreWork = true
        }
    }

    private func makeEvent(
        sessionID: String,
        ordinal: Int,
        last: (input: Int, cached: Int, output: Int, reasoning: Int, total: Int),
        record: [String: Any],
        request: UsageSliceRequest
    ) -> UsageEvent? {
        // Cached input is a subset of input (total == input + output was checked
        // over 3,089 records), so the non-cached part is the difference. A cache
        // count larger than the input contradicts that contract: refuse it.
        guard last.cached <= last.input else { return nil }
        guard let occurred = (record["timestamp"] as? String).flatMap(Self.parseTimestamp) else { return nil }
        var event = UsageEvent(
            id: UsageEventID(tool: .codex, sessionID: sessionID, responseID: String(ordinal)),
            sessionID: sessionID,
            // The ordinal is only unique inside one session file; the stored
            // response id has to be unique across sessions, because the store
            // treats provider + response id as one real call wherever it appears.
            // With the bare ordinal every session after the first lost its calls
            // as "duplicates" of the first one's.
            responseID: "\(sessionID):\(ordinal)",
            provider: provider(in: record) ?? "codex",
            model: model(in: record) ?? "unknown",
            // token_count carries no stop reason; the event itself is the
            // completion of one model call.
            stopReason: "completed",
            occurredAtMilliseconds: Int(occurred.timeIntervalSince1970 * 1000),
            completedAtMilliseconds: nil,
            inputTokens: last.input - last.cached,
            outputTokens: last.output,
            cacheReadTokens: last.cached,
            cacheWriteTokens: 0
        )
        event.reasoningTokens = last.reasoning
        event.normalizationVersion = 2
        _ = request
        return event
    }

    // MARK: - Record reading

    struct Line {
        var data: Data
        var bytes: Int
        var complete: Bool
    }

    /// Splits a buffer into JSONL records, reporting whether each was terminated
    /// by a newline. An unterminated tail is never consumed.
    func records(in data: Data) -> [Line] {
        var lines: [Line] = []
        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                let tail = data[start...]
                lines.append(Line(data: Data(tail), bytes: tail.count, complete: false))
                break
            }
            if newline > start {
                lines.append(Line(data: Data(data[start..<newline]), bytes: (newline - start) + 1, complete: true))
            } else {
                lines.append(Line(data: Data(), bytes: 1, complete: true))
            }
            start = data.index(after: newline)
        }
        return lines
    }

    /// Offset just past the last complete record inside `data`.
    ///
    /// Used as a baseline boundary: everything before it is history, so the
    /// position has to be the end of a record whose bytes are fully present,
    /// never the start of one that would then be read again.
    func lastCompleteRecordEnd(in data: Data) -> Int {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: lastNewline) + 1
    }

    private func firstMeta(in data: Data) -> (id: String?, cliVersion: String?)? {
        for line in records(in: data) where line.complete {
            guard let record = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { continue }
            guard record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any] else { continue }
            return (payload["id"] as? String, payload["cli_version"] as? String)
        }
        return nil
    }

    func lastCumulative(in data: Data, upTo: Int) -> Int? {
        var value: Int?
        let slice = data.prefix(upTo)
        for line in records(in: Data(slice)) where line.complete {
            guard let record = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { continue }
            guard isTokenCount(record), let total = cumulativeTotal(record) else { continue }
            value = total
        }
        return value
    }

    func cumulativeTotal(_ record: [String: Any]) -> Int? {
        guard let payload = record["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else { return nil }
        return intValue(total["total_tokens"])
    }

    func lastUsage(_ record: [String: Any]) -> (input: Int, cached: Int, output: Int, reasoning: Int, total: Int)? {
        guard let payload = record["payload"] as? [String: Any],
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return nil }
        guard let input = intValue(last["input_tokens"]),
              let output = intValue(last["output_tokens"]),
              let total = intValue(last["total_tokens"]) else { return nil }
        return (
            input: input,
            cached: intValue(last["cached_input_tokens"]) ?? 0,
            output: output,
            reasoning: intValue(last["reasoning_output_tokens"]) ?? 0,
            total: total
        )
    }

    func isTokenCount(_ record: [String: Any]) -> Bool {
        guard record["type"] as? String == "event_msg", let payload = record["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == "token_count"
    }

    func sessionMeta(in record: [String: Any]) -> (id: String?, cliVersion: String?)? {
        guard record["type"] as? String == "session_meta", let payload = record["payload"] as? [String: Any] else { return nil }
        return (payload["id"] as? String, payload["cli_version"] as? String)
    }

    private func provider(in record: [String: Any]) -> String? {
        guard let payload = record["payload"] as? [String: Any], let info = payload["info"] as? [String: Any] else { return nil }
        return info["model_provider"] as? String
    }

    private func model(in record: [String: Any]) -> String? {
        guard let payload = record["payload"] as? [String: Any] else { return nil }
        return payload["model"] as? String
    }

    /// The shared rule for a token count (`UsageJSONLReader.nonNegativeInt`).
    func intValue(_ value: Any?) -> Int? {
        UsageJSONLReader.nonNegativeInt(value)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    func counterKey(_ relative: String) -> String { "codex-counter:\(relative)" }

    /// Session id per file, remembered so an incremental slice can identify a
    /// call without re-reading the file's header.
    func sessionKey(_ relative: String) -> String { "codex-session:\(relative)" }

    // MARK: - Files

    /// Some session files, for inspection only; a slice sees every one of them.
    func sessionFiles(root: URL, limit: Int) throws -> [URL] {
        UsageJSONLReader(maxLineBytes: maxLineBytes).files(under: root, matching: Self.isSessionFile, limit: limit)
    }

    func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
    }

    private func fileDevice(_ url: URL) -> Int64 {
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let number = identifier as? NSNumber else { return 0 }
        return number.int64Value
    }

    private func fileInode(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return 0 }
        return number.uint64Value
    }

    func readPrefix(of url: URL, maxBytes: Int) throws -> Data {
        try readRange(of: url, from: 0, length: maxBytes)
    }

    func readRange(of url: URL, from offset: Int64, length: Int? = nil) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        if let length {
            return try handle.read(upToCount: max(0, length)) ?? Data()
        }
        return try handle.readToEnd() ?? Data()
    }
}
