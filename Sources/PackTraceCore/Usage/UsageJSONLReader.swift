import Foundation

/// Reading JSONL storage: record boundaries, bounded reads and relative paths.
///
/// Shared by the file-based adapters so a partial line, a large record or a
/// symbolic link is handled the same way in each of them.
public struct UsageJSONLReader: Sendable {
    public struct Record: Sendable {
        public var data: Data
        public var bytes: Int
        /// False for the last fragment when the file does not end in a newline.
        /// Such a fragment is never consumed.
        public var complete: Bool
    }

    public var maxLineBytes: Int

    public init(maxLineBytes: Int = 8 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Splits a buffer into records. A record longer than `maxLineBytes` is
    /// reported as a single incomplete record rather than being split.
    public func records(in data: Data) -> [Record] {
        var lines: [Record] = []
        var start = data.startIndex
        while start < data.endIndex {
            guard let newline = data[start...].firstIndex(of: 0x0A) else {
                let tail = data[start...]
                lines.append(Record(data: Data(tail), bytes: tail.count, complete: false))
                break
            }
            let length = data.distance(from: start, to: newline)
            if length == 0 {
                lines.append(Record(data: Data(), bytes: 1, complete: true))
            } else {
                lines.append(Record(data: Data(data[start..<newline]), bytes: length + 1, complete: true))
            }
            start = data.index(after: newline)
        }
        return lines
    }

    /// Where the record starting at `offset` ends (just past its newline), for
    /// skipping one that is too large to read in a slice. Nil while the record
    /// has no newline yet: it is still being written, or the file ends there.
    public func endOfRecord(in url: URL, from offset: Int64, size: Int64, chunk: Int = 1 << 20) -> Int64? {
        var position = offset
        while position < size {
            let length = Int(min(Int64(chunk), size - position))
            guard let data = try? readRange(of: url, from: position, length: length), !data.isEmpty else { return nil }
            if let newline = data.firstIndex(of: 0x0A) {
                return position + Int64(data.distance(from: data.startIndex, to: newline)) + 1
            }
            position += Int64(data.count)
        }
        return nil
    }

    /// Offset just past the last complete record: the only safe place to fix a
    /// baseline, because everything before it is whole.
    public func lastCompleteRecordEnd(in data: Data) -> Int {
        guard let newline = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: newline) + 1
    }

    public func readPrefix(of url: URL, maxBytes: Int) throws -> Data {
        try readRange(of: url, from: 0, length: maxBytes)
    }

    public func readRange(of url: URL, from offset: Int64, length: Int? = nil) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(0, offset)))
        if let length {
            return try handle.read(upToCount: max(0, length)) ?? Data()
        }
        return try handle.readToEnd() ?? Data()
    }

    /// A file found under a root, with what the slice needs to decide whether
    /// to read it at all.
    public struct FoundFile: Sendable, Hashable {
        public var url: URL
        public var size: Int64
        public var modified: Date
    }

    /// Every matching file under a root, most recently modified first, skipping
    /// symbolic links (an approved root must not be an escape hatch to somewhere
    /// else) and hidden files.
    ///
    /// Discovery is never cut short: a budget limits what a slice *reads*, not
    /// what it can see. Stopping the walk after a few files made everything past
    /// them invisible for good, because the walk returns them in the same order
    /// every time. Newest first puts the sessions that are being written ahead of
    /// a backlog of old ones.
    public func allFiles(under root: URL, matching: (String) -> Bool) -> [FoundFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [FoundFile] = []
        for case let url as URL in enumerator {
            guard matching(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            found.append(
                FoundFile(
                    url: url,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            )
        }
        return found.sorted {
            $0.modified != $1.modified ? $0.modified > $1.modified : $0.url.path < $1.url.path
        }
    }

    /// Up to `limit` matching files, in walk order, stopping as soon as it has
    /// them. For inspection only ("does the root hold any at all"): a slice uses
    /// `allFiles`, which never stops early.
    public func files(
        under root: URL,
        matching: (String) -> Bool,
        limit: Int
    ) -> [URL] {
        guard limit > 0, let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator {
            guard matching(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }
            found.append(url)
            if found.count >= limit { break }
        }
        return found
    }

    public func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return file.lastPathComponent }
        return String(path.dropFirst(rootPath.count).drop { $0 == "/" })
    }

    public func device(_ url: URL) -> UInt64 {
        guard let identifier = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let number = identifier as? NSNumber else { return 0 }
        return UInt64(max(0, number.int64Value))
    }

    public func inode(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return 0 }
        return number.uint64Value
    }

    /// A non-negative integer inside `Int` range, or nil. Strings, negatives,
    /// fractions, infinities and booleans are rejected rather than coerced.
    public func intValue(_ value: Any?) -> Int? {
        Self.nonNegativeInt(value)
    }

    /// The one rule every adapter uses for a token count.
    ///
    /// A JSON number too large for `Int` arrives as a floating-point NSNumber,
    /// and bridging it with `as? Int` silently clamps it to `Int.max`; a damaged
    /// value then turned into an absurd token count. Floating-point numbers are
    /// therefore checked as doubles (the bound is exclusive: `Double(Int.max)`
    /// is 2^63), and only true integers are read as integers.
    public static func nonNegativeInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                guard double.isFinite, double >= 0, double < Double(Int.max), double.rounded() == double else { return nil }
                return Int(double)
            }
            let integer = number.int64Value
            return integer >= 0 ? Int(integer) : nil
        }
        if let number = value as? Int { return number >= 0 ? number : nil }
        if let number = value as? Double {
            guard number.isFinite, number >= 0, number < Double(Int.max), number.rounded() == number else { return nil }
            return Int(number)
        }
        return nil
    }

    public static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
