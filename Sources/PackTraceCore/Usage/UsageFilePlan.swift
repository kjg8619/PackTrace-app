import Foundation

/// What a file-based adapter does with one file in a slice. Pure, so the rule
/// is tested once for every JSONL tool.
///
/// The connection's rule is "what was there when the tool was connected is
/// history; what happens after it is credited". A file's own state decides how
/// that is applied:
///
/// - While the baseline is being fixed, every file is marked as history at its
///   current end, without being read.
/// - After that, a file seen for the first time that has not been written since
///   the connection is history too, and is also not read.
/// - A first-seen file written after the connection is read from its start.
///   Everything it held when it was found is checked against the connection
///   time record by record (it may be a new session, or an older one that was
///   simply never seen before); what is appended later is new by definition.
/// - A known file is read from its checkpoint when it grew, and skipped when it
///   did not.
public enum UsageFilePlan: Equatable, Sendable {
    /// Nothing new: not read.
    case skip
    /// History: a boundary at the current end, nothing read or credited.
    case markHistory
    /// Read from `checkpoint.byteOffset`. Records that start before
    /// `checkpoint.baselineOffset` are credited only if they occurred after the
    /// connection (`isCreditable(occurredAt:)`).
    case read(UsageFileCheckpoint, fromStart: Bool)

    public static func decide(
        relativePath: String,
        checkpoint: UsageFileCheckpoint?,
        size: Int64,
        modified: Date,
        connectedAt: Date,
        isBaselining: Bool,
        deviceID: UInt64,
        inode: UInt64,
        now: Date
    ) -> UsageFilePlan {
        func fromStart() -> UsageFilePlan {
            .read(
                UsageFileCheckpoint(
                    relativePath: relativePath,
                    deviceID: deviceID,
                    inode: inode,
                    byteOffset: 0,
                    // The region found in the file is the part that has to be
                    // checked against the connection time.
                    baselineOffset: max(size, 0),
                    baselineDone: true,
                    fileSize: max(size, 0),
                    status: .ok,
                    reason: nil,
                    updatedAt: now
                ),
                fromStart: true
            )
        }

        guard let checkpoint else {
            if isBaselining || modified < connectedAt { return .markHistory }
            return fromStart()
        }
        // A boundary that was never finished (a restored profile resets them)
        // is fixed again at the current end.
        if !checkpoint.baselineDone { return .markHistory }
        if size < checkpoint.byteOffset {
            // Shorter than what was read: replaced or truncated. Reading it again
            // from the start is safe — calls already recorded are recognised by
            // their identity — and only what happened after the connection counts.
            if isBaselining || modified < connectedAt { return .markHistory }
            return fromStart()
        }
        if size == checkpoint.byteOffset { return .skip }
        return .read(checkpoint, fromStart: false)
    }

    /// The boundary for a file marked as history.
    public static func historyCheckpoint(
        relativePath: String,
        size: Int64,
        deviceID: UInt64,
        inode: UInt64,
        now: Date
    ) -> UsageFileCheckpoint {
        UsageFileCheckpoint(
            relativePath: relativePath,
            deviceID: deviceID,
            inode: inode,
            byteOffset: max(size, 0),
            baselineOffset: max(size, 0),
            baselineDone: true,
            fileSize: max(size, 0),
            status: .ok,
            reason: "baseline_boundary",
            updatedAt: now
        )
    }

    /// Whether a record read at `recordStart` may be credited: past the region
    /// that was found in the file, always; inside it, only if it happened after
    /// the connection.
    public static func isCreditable(
        recordStart: Int64,
        checkpoint: UsageFileCheckpoint,
        occurredAt: Date,
        connectedAt: Date
    ) -> Bool {
        recordStart >= checkpoint.baselineOffset || occurredAt >= connectedAt
    }
}
