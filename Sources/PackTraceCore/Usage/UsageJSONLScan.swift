import Foundation

/// The file-walking half of a JSONL adapter: discovery, the connection rule
/// (`UsageFilePlan`), budgets, incremental reads, oversized records and
/// checkpoints. The adapter supplies only how one record becomes an entry.
///
/// Same behaviour as the Claude Code adapter's own loop (which predates this
/// helper): every file is looked at, only changed ones are read, history is
/// marked without reading, and a record found in a first-read file counts only
/// if it happened after the connection.
struct UsageJSONLScan {
    struct Record {
        var object: [String: Any]
        var file: URL
        var relativePath: String
    }

    enum Outcome {
        /// Not a usage record (user message, tool call, metadata …).
        case skip
        /// A line that is not a JSON object.
        case unreadable
        /// A usage record. An accepted event is re-classified as baseline when
        /// it happened before the connection and sits in the part of the file
        /// that was already there when the file was found.
        case entry(UsageBatchEntry, occurredAt: Date?, session: UsageSessionObservation?)
    }

    let reader: UsageJSONLReader
    let matches: (String) -> Bool

    func scan(_ request: UsageSliceRequest, handle: (Record) -> Outcome) -> UsageSliceOutput {
        var output = UsageSliceOutput()
        let root = URL(fileURLWithPath: request.source.rootPath)
        guard FileManager.default.fileExists(atPath: root.path) else {
            output.status = .rootMissing
            output.statusReason = "root_missing"
            return output
        }
        let files = reader.allFiles(under: root, matching: matches)
        output.counters.filesConsidered = files.count
        guard !files.isEmpty else {
            output.skippedReason = "no_files"
            return output
        }

        let known = Dictionary(uniqueKeysWithValues: request.fileCheckpoints.map { ($0.relativePath, $0) })
        var budgets = Budgets()
        for file in files {
            let relative = reader.relativePath(of: file.url, under: root)
            let checkpoint = known[relative]
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
                readIncrement(file: file.url, relativePath: relative, checkpoint: checkpoint, size: file.size,
                              request: request, budgets: &budgets, into: &output, handle: handle)
            }
        }
        return output
    }

    private struct Budgets {
        var records = 0
        var bytes = 0
        var files = 0
        var newFiles = 0
    }

    private func readIncrement(
        file: URL,
        relativePath: String,
        checkpoint: UsageFileCheckpoint,
        size: Int64,
        request: UsageSliceRequest,
        budgets: inout Budgets,
        into output: inout UsageSliceOutput,
        handle: (Record) -> Outcome
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
        var sessionsSeen = Set<String>()
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
            switch handle(Record(object: object, file: file, relativePath: relativePath)) {
            case .skip:
                continue
            case .unreadable:
                output.counters.errorCount += 1
            case let .entry(entry, occurredAt, session):
                if let session, sessionsSeen.insert(session.sessionID).inserted {
                    output.sessions.append(session)
                }
                if entry.status == .accepted, let event = entry.event, let occurredAt,
                   !UsageFilePlan.isCreditable(recordStart: recordStart, checkpoint: checkpoint,
                                               occurredAt: occurredAt, connectedAt: request.source.connectedAt) {
                    // Found in a file first seen after the connection, but it
                    // happened before it: history, recorded so a copy is not paid.
                    output.entries.append(UsageBatchEntry(event: event, status: .baseline, reason: .inheritedPreConnection))
                } else {
                    if entry.status == .unsupported { output.counters.unsupported += 1 }
                    output.entries.append(entry)
                }
            }
        }

        guard consumed > 0 else {
            // One record longer than the whole window can never be read here;
            // it is skipped and reported instead of starving every other file.
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
}
