import Foundation

/// Discovers and incrementally reads OMP session logs. File system only: the
/// scanner never writes, never follows symlinks out of the approved root, and
/// never carries raw log content past `UsageBatchEntry`.
public struct OMPLogScanner: Sendable {
    public struct Limits: Sendable, Hashable {
        /// Records per slice; keeps a large corpus from blocking the UI.
        public var maxRecordsPerSlice: Int
        /// Bytes per slice.
        public var maxBytesPerSlice: Int
        /// Files read per slice (every file is still listed and checked for
        /// changes).
        public var maxFilesPerSlice: Int
        /// A single JSONL record larger than this is skipped with a diagnostic.
        public var maxLineBytes: Int
        /// Chunk size for streaming reads.
        public var chunkBytes: Int

        public init(
            maxRecordsPerSlice: Int = 2_000,
            maxBytesPerSlice: Int = 32 * 1024 * 1024,
            maxFilesPerSlice: Int = 400,
            maxLineBytes: Int = 8 * 1024 * 1024,
            chunkBytes: Int = 1 << 20
        ) {
            self.maxRecordsPerSlice = maxRecordsPerSlice
            self.maxBytesPerSlice = maxBytesPerSlice
            self.maxFilesPerSlice = maxFilesPerSlice
            self.maxLineBytes = maxLineBytes
            self.chunkBytes = chunkBytes
        }

        public static let standard = Limits()

        /// Tiny slices: used by tests to force multi-slice behaviour.
        public static let small = Limits(
            maxRecordsPerSlice: 5,
            maxBytesPerSlice: 64 * 1024,
            maxFilesPerSlice: 3,
            maxLineBytes: 64 * 1024,
            chunkBytes: 4 * 1024
        )
    }

    public struct DiscoveredFile: Sendable, Hashable {
        public var relativePath: String
        public var url: URL
        public var deviceID: UInt64
        public var inode: UInt64
        public var size: Int64
        public var sessionID: String
    }

    public struct ReadOutcome: Sendable {
        public var entries: [UsageBatchEntry] = []
        /// Session header seen while reading, when the slice crossed it.
        public var sessionHeader: OMPLogParser.SessionHeader?
        public var recordsSeen = 0
        public var bytesRead: Int64 = 0
        /// Offset of the end of the last complete record consumed.
        public var nextOffset: Int64 = 0
        public var reachedEOF = false
        public var oversizedRecords = 0
        /// An oversized record was skipped but its newline has not arrived yet.
        public var unterminatedOversizedRecord = false
        public var rotated = false
        public var schemaVersion: Int?
        public var unreadableReason: String?
    }

    public enum ScanError: Error, Equatable {
        case rootMissing
        case permissionDenied
    }

    public init() {}

    // MARK: - Discovery

    /// Session files under `<root>/<project>/<session>.jsonl` and directly under
    /// `<root>/<session>.jsonl`. Subagent transcripts (deeper) are not collected.
    public func discover(root: URL, limits: Limits = Limits()) throws -> [DiscoveredFile] {
        let manager = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory) else {
            throw ScanError.rootMissing
        }
        guard isDirectory.boolValue, manager.isReadableFile(atPath: resolvedRoot.path) else {
            throw manager.isReadableFile(atPath: resolvedRoot.path) ? ScanError.rootMissing : ScanError.permissionDenied
        }

        var files: [DiscoveredFile] = []
        let rootPrefix = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"

        // Every session file is listed: `maxFilesPerSlice` limits what a slice
        // reads, not what it can see. Cut here, sessions past the limit were
        // never read, and tracked ones past it were reported as missing.
        func consider(_ url: URL, relativePrefix: String) {
            guard url.pathExtension == "jsonl" else { return }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            // Never leave the approved root, even through a symlink.
            guard resolved.path.hasPrefix(rootPrefix) else { return }
            guard let attributes = try? manager.attributesOfItem(atPath: resolved.path),
                  let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return }
            files.append(
                DiscoveredFile(
                    relativePath: relativePrefix + url.lastPathComponent,
                    url: resolved,
                    deviceID: device,
                    inode: inode,
                    size: size,
                    sessionID: Self.sessionID(fromFileName: url.lastPathComponent)
                )
            )
        }

        let topLevel = (try? manager.contentsOfDirectory(
            at: resolvedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in topLevel.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let children = (try? manager.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    consider(child, relativePrefix: entry.lastPathComponent + "/")
                }
            } else {
                consider(entry, relativePrefix: "")
            }
        }
        return files
    }

    /// `2026-09-22T04-25-29-228Z_<sessionId>.jsonl` → `<sessionId>`.
    static func sessionID(fromFileName name: String) -> String {
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        guard let separator = stem.lastIndex(of: "_") else { return stem }
        return String(stem[stem.index(after: separator)...])
    }

    // MARK: - Baseline boundary

    /// End offset of the last complete (newline-terminated) record, without
    /// reading the whole file.
    public func lastCompleteRecordOffset(of file: DiscoveredFile, limits: Limits = Limits()) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        let size = file.size
        guard size > 0 else { return 0 }
        var window: Int64 = 64 * 1024
        while true {
            let start = max(0, size - window)
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: Int(size - start)) ?? Data()
            if let newline = data.lastIndex(of: 0x0A) {
                return start + Int64(data.distance(from: data.startIndex, to: newline)) + 1
            }
            if start == 0 {
                return 0 // no complete record yet
            }
            window *= 4
        }
    }

    /// Session context for a file, read from its first bytes only. Incremental
    /// reads start far past the header, so the parser needs this to know the
    /// schema version of the file it is continuing.
    public func sessionContext(for file: DiscoveredFile, limits: Limits = .standard) -> OMPLogParser.Context? {
        sessionHeader(for: file, limits: limits).map { header in
            OMPLogParser.Context(sessionID: header.id, schemaVersion: header.version)
        }
    }

    /// The session header of a file, read from its first bytes only. Used both
    /// for the parser context and to record the session (and its fork origin)
    /// even when the read resumes past the header.
    public func sessionHeader(for file: DiscoveredFile, limits: Limits = .standard) -> OMPLogParser.SessionHeader? {
        let headBytes = min(file.size, 64 * 1024)
        guard headBytes > 0, let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Int(headBytes)) else { return nil }

        var start = data.startIndex
        while let newline = data[start...].firstIndex(of: 0x0A) {
            let line = data[start..<newline]
            start = data.index(after: newline)
            if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               object["type"] as? String == "session",
               let version = OMPLogParser.strictInt(object["version"]) {
                let id = (object["id"] as? String) ?? file.sessionID
                guard !id.isEmpty else { return nil }
                let parent = (object["parentSession"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return OMPLogParser.SessionHeader(id: id, version: version, parentSession: parent)
            }
        }
        return nil
    }

    // MARK: - Incremental read

    /// Reads complete records starting at `offset`, stopping at `limit` (used to
    /// hold the baseline boundary) or when the slice budget is exhausted.
    public func read(
        file: DiscoveredFile,
        from offset: Int64,
        limit: Int64? = nil,
        context: OMPLogParser.Context,
        limits: Limits = Limits()
    ) throws -> ReadOutcome {
        var outcome = ReadOutcome()
        outcome.nextOffset = offset
        var context = context
        if context.sessionID == nil { context.sessionID = file.sessionID }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }

        let endBoundary = min(limit ?? file.size, file.size)
        guard offset <= endBoundary else {
            // The file shrank or was replaced: restart from the beginning and
            // rely on event identities to prevent double payment.
            outcome.rotated = true
            return try read(file: file, from: 0, limit: limit, context: context, limits: limits)
        }
        try handle.seek(toOffset: UInt64(offset))

        var pending = Data()
        /// Bytes of the current incomplete record already discarded because it
        /// exceeded `maxLineBytes`.
        var discardedLineBytes = 0
        /// True while the current incomplete record is being skipped.
        var skippingOversized = false
        var position = offset
        var reachedEOF = false

        // The byte budget yields control *between* records: while a record is
        // still in progress the read continues, otherwise a single record
        // larger than the slice budget could never be consumed or skipped.
        while outcome.recordsSeen < limits.maxRecordsPerSlice,
              outcome.bytesRead < limits.maxBytesPerSlice || !pending.isEmpty || skippingOversized {
            let remaining = endBoundary - position
            if remaining <= 0 {
                reachedEOF = position >= file.size
                break
            }
            // Never read more than the per-record ceiling in one chunk, so a
            // chunk can never hold more bytes than one allowed record.
            let chunkLimit = max(1, min(limits.chunkBytes, limits.maxLineBytes))
            let want = Int(min(Int64(chunkLimit), remaining))
            guard let chunk = try handle.read(upToCount: want), !chunk.isEmpty else {
                reachedEOF = true
                break
            }
            position += Int64(chunk.count)
            outcome.bytesRead += Int64(chunk.count)
            pending.append(chunk)

            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if skippingOversized {
                    // The whole record (discarded prefix + this tail) is
                    // consumed: advance past every byte of it, count one
                    // skipped record, and parse nothing from its middle.
                    outcome.nextOffset += Int64(discardedLineBytes + lineData.count) + 1
                    discardedLineBytes = 0
                    skippingOversized = false
                    outcome.oversizedRecords += 1
                    outcome.recordsSeen += 1
                    continue
                }
                outcome.nextOffset += Int64(lineData.count) + 1
                if lineData.isEmpty { continue }
                let verdict = OMPLogParser.parse(line: Data(lineData), context: context)
                outcome.recordsSeen += 1
                switch verdict {
                case let .sessionHeader(header):
                    context.schemaVersion = header.version
                    outcome.schemaVersion = header.version
                    outcome.sessionHeader = header
                    if header.id != file.sessionID {
                        // Header id disagrees with the file name: refuse to guess.
                        context.sessionID = header.id
                    }
                case let .accepted(event):
                    outcome.entries.append(UsageBatchEntry(event: event, status: .accepted))
                case let .rejected(event, reason):
                    outcome.entries.append(
                        UsageBatchEntry(
                            event: event,
                            status: Self.status(for: reason),
                            reason: reason
                        )
                    )
                case .ignored:
                    break
                }
                if outcome.recordsSeen >= limits.maxRecordsPerSlice { break }
            }

            if pending.count > limits.maxLineBytes {
                // The current record is larger than the safety ceiling: drop
                // what has been buffered, keep counting its bytes so the
                // checkpoint can pass its end, and record a diagnostic instead
                // of the content.
                discardedLineBytes += pending.count
                skippingOversized = true
                pending.removeAll(keepingCapacity: false)
            }
            if outcome.recordsSeen >= limits.maxRecordsPerSlice { break }
        }

        // Anything after the last newline is a partial record: it is not
        // consumed and the checkpoint stays before it. An oversized record that
        // is still unterminated stays unconsumed for the same reason, and is
        // reported so the skip is visible instead of silent.
        if skippingOversized, !pending.isEmpty || discardedLineBytes > 0 {
            outcome.unterminatedOversizedRecord = true
        }
        outcome.reachedEOF = reachedEOF && pending.isEmpty && !skippingOversized
        return outcome
    }

    static func status(for reason: UsageRejectionReason) -> UsageEventStatus {
        switch reason {
        case .providerNotVerified, .unsupportedSchemaVersion, .missingSessionHeader,
             .subagentExcluded, .oversizedRecord:
            return .unsupported
        case .unparsableRecord, .missingResponseID, .missingUsage, .invalidTokenField,
             .missingTimestamp, .invalidTimestamp, .tokenOutOfRange, .unknownStopReason,
             .sourcePaused:
            // Identity is missing or the record cannot be trusted: keep it out
            // of the reward path but still visible in diagnostics.
            return .unsupported
        case .stopReasonError, .stopReasonAborted:
            return .excluded
        case .identityConflict:
            return .conflict
        case .inheritedPreConnection:
            // Recorded as history, never rewarded.
            return .baseline
        case .duplicateOriginalCall, .duplicateCall:
            // Maps to an already recorded call; the store decides whether it is
            // a duplicate or a conflict.
            return .conflict
        case .unsupportedFormat:
            return .unsupported
        case .cumulativeBoundaryUnclear, .notAModelCall, .localModelExcluded:
            // Understood, but deliberately not rewarded: record it so the
            // decision is visible instead of the record vanishing.
            return .excluded
        case .missingCallIdentity:
            return .unsupported
        }
    }
}
