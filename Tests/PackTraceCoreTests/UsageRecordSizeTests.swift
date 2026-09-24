import Foundation
import PackTraceCore
import PackTraceTestSupport
import Testing

/// Record-size behaviour of the scanner.
///
/// The unit under test is the JSONL *record* (one line) and the reader's
/// bounded buffers. `maxLineBytes` is a safety ceiling for a single record;
/// the shipping default is 8 MiB (see docs/OMP_USAGE_SCHEMA.md §12).
@Suite("OMP 레코드 크기")
struct UsageRecordSizeTests {
    /// Builds an assistant record whose *body* is `padding` bytes long, with the
    /// usage block placed before or after it.
    private func paddedRecord(
        _ n: Int,
        bodyBytes: Int,
        usageFirst: Bool,
        filler: Character = "x",
        occurredAt: Int
    ) -> String {
        let padding = String(repeating: filler, count: max(bodyBytes, 0))
        let usage = """
        "usage":{"input":6000,"output":4000,"cacheRead":123,"cacheWrite":0,"totalTokens":10123}
        """
        let body = """
        "content":[{"type":"text","text":"\(padding)"}]
        """
        let inner = usageFirst ? "\(usage),\(body)" : "\(body),\(usage)"
        return """
        {"type":"message","id":"rec_size_\(n)","parentId":"rec_parent","timestamp":\(occurredAt),\
        "message":{"role":"assistant","api":"openai-completions","provider":"commandcode",\
        "model":"deepseek/deepseek-v4-flash","responseId":"\(OMPFixture.responseID(n))",\
        \(inner),"stopReason":"stop","timestamp":\(occurredAt),"duration":1,"ttft":1}}
        """
    }

    private func harness(limits: OMPLogScanner.Limits = .standard) throws -> UsageTestSupport.Harness {
        try UsageTestSupport.harness(limits: limits)
    }

    private func sessionFile(records: [String], session: String = OMPFixture.session1) -> String {
        OMPFixture.sessionFile(sessionID: session, assistants: records)
    }

    @Test("4KiB 경계 전후의 정상 레코드는 모두 인정된다", arguments: [0, 1024, 4096 - 1, 4096, 4096 + 1, 64 * 1024, 1024 * 1024])
    func recordsAroundFormerTestLimitAreAccepted(bodyBytes: Int) async throws {
        let harness = try harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            paddedRecord(1, bodyBytes: bodyBytes, usageFirst: true, occurredAt: OMPFixture.timestamp(5)) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1, "본문 \(bodyBytes)바이트 레코드가 인식되어야 합니다")
        #expect(rows.first?.acceptedTokens == 10_000)
        #expect(rows.first?.status == .accepted, "연결 이후 추가된 레코드입니다")
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.oversizedRecord] == nil)
    }

    @Test("usage 블록이 본문 앞에 있어도 뒤에 있어도 같은 값으로 정규화된다")
    func usagePositionDoesNotMatter() async throws {
        let harness = try harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            paddedRecord(1, bodyBytes: 100_000, usageFirst: true, occurredAt: OMPFixture.timestamp(5)) + "\n"
                + paddedRecord(2, bodyBytes: 100_000, usageFirst: false, occurredAt: OMPFixture.timestamp(6)) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.acceptedTokens == 10_000 })
        #expect(rows.allSatisfy { $0.inputTokens == 6_000 && $0.outputTokens == 4_000 })
    }

    @Test("본문 안의 이스케이프·중괄호·usage 문자열은 값으로만 취급된다")
    func bodyContentCannotForgeUsage() async throws {
        let harness = try harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let trap = String(repeating: "\\\"usage\\\":{\\\"input\\\":999999999,\\\"output\\\":0},{\\\"a\\\":1} ", count: 200)
        try harness.tree.append(
            paddedRecord(1, bodyBytes: 0, usageFirst: true, occurredAt: OMPFixture.timestamp(5))
                .replacingOccurrences(of: "\"text\":\"\"", with: "\"text\":\"\(trap)\"") + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.acceptedTokens == 10_000, "본문에 흉내 낸 값이 아니라 실제 usage를 읽어야 합니다")
    }

    @Test("여러 read chunk에 걸친 레코드도 한 번만 인정된다")
    func recordSpanningChunksIsAcceptedOnce() async throws {
        let harness = try harness(limits: OMPLogScanner.Limits(
            maxRecordsPerSlice: 50,
            maxBytesPerSlice: 4 * 1024 * 1024,
            maxFilesPerSlice: 4,
            maxLineBytes: 4 * 1024 * 1024,
            chunkBytes: 512
        ))
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            paddedRecord(1, bodyBytes: 40_000, usageFirst: true, occurredAt: OMPFixture.timestamp(5)) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.acceptedTokens == 10_000)
    }

    @Test("미완성 대형 레코드는 완성된 뒤에 한 번만 소비된다")
    func incompleteLargeRecordIsHeldBack() async throws {
        // The record is larger than the per-slice byte budget but within the
        // per-record ceiling, so it must still be parsed once it completes.
        let harness = try harness(limits: OMPLogScanner.Limits(
            maxRecordsPerSlice: 50,
            maxBytesPerSlice: 64 * 1024,
            maxFilesPerSlice: 4,
            maxLineBytes: 1024 * 1024,
            chunkBytes: 4 * 1024
        ))
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        // The record ends with a newline, so it is only "incomplete" while the
        // first half is on disk.
        let record = paddedRecord(1, bodyBytes: 200_000, usageFirst: false, occurredAt: OMPFixture.timestamp(5)) + "\n"
        let bytes = Array(record.utf8)
        let handle = try FileHandle(forWritingTo: harness.tree.root.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes[0..<(bytes.count / 2)]))
        try handle.close()

        _ = try await harness.drain(maxSlices: 2)
        #expect(try await harness.store.usageRecentEvents(limit: 10).isEmpty, "미완성 레코드는 소비하지 않습니다")

        let handle2 = try FileHandle(forWritingTo: harness.tree.root.appendingPathComponent(path))
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(bytes[(bytes.count / 2)...]))
        try handle2.close()

        _ = try await harness.drain(maxSlices: 5)
        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.acceptedTokens == 10_000)
    }

    @Test("상한을 넘는 레코드는 진단만 남기고 다음 레코드는 정상 처리한다")
    func oversizedRecordIsSkippedAndScanContinues() async throws {
        let cap = 64 * 1024
        let harness = try harness(limits: OMPLogScanner.Limits(
            maxRecordsPerSlice: 50,
            maxBytesPerSlice: 4 * 1024 * 1024,
            maxFilesPerSlice: 4,
            maxLineBytes: cap,
            chunkBytes: 8 * 1024
        ))
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            paddedRecord(1, bodyBytes: cap * 2, usageFirst: true, occurredAt: OMPFixture.timestamp(5)) + "\n"
                + paddedRecord(2, bodyBytes: 4_000, usageFirst: true, occurredAt: OMPFixture.timestamp(6)) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1, "상한 초과 레코드만 제외됩니다")
        #expect(rows.first?.responseID == OMPFixture.responseID(2))
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.oversizedRecord] ?? 0 >= 1)

        // Checkpoint advanced past the skipped record: a rescan reads nothing new.
        let second = try await harness.collector.scan(trigger: .manual)
        #expect(second.bytesRead == 0)
    }

    @Test("잘못된 JSON 뒤의 정상 레코드는 크기와 무관하게 처리된다")
    func brokenRecordDoesNotStopLargeFile() async throws {
        let harness = try harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            "{\"type\":\"message\",\"message\":{\"role\":\"assistant\",\"broken\":\n"
                + paddedRecord(1, bodyBytes: 500_000, usageFirst: true, occurredAt: OMPFixture.timestamp(7)) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.acceptedTokens == 10_000)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.unparsableRecord] ?? 0 >= 1)
    }

    @Test("청크가 레코드 상한보다 커도 정상 레코드를 잃지 않는다")
    func chunkLargerThanLineCapLosesNothing() async throws {
        // Deliberately misconfigured limits: a chunk can hold more bytes than
        // the per-record ceiling, and slices are tiny.
        let harness = try harness(limits: OMPLogScanner.Limits(
            maxRecordsPerSlice: 1,
            maxBytesPerSlice: 1 << 20,
            maxFilesPerSlice: 4,
            maxLineBytes: 512,
            chunkBytes: 8192
        ))
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let records = (1...8).map {
            paddedRecord($0, bodyBytes: 200, usageFirst: true, occurredAt: OMPFixture.timestamp(10 + $0))
        }
        try harness.tree.append(records.joined(separator: "\n") + "\n", to: path)
        _ = try await harness.drain(maxSlices: 40)

        let rows = try await harness.store.usageRecentEvents(limit: 20)
        #expect(rows.count == 8, "정상 레코드가 상한 초과로 오인되어 사라지면 안 됩니다")
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.oversizedRecord] == nil)
    }

    @Test("본문 크기가 달라도 같은 usage는 같은 값으로 정규화된다")
    func bodySizeDoesNotChangeNormalization() async throws {
        let harness = try harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            [
                paddedRecord(1, bodyBytes: 0, usageFirst: true, occurredAt: OMPFixture.timestamp(5)),
                paddedRecord(2, bodyBytes: 300_000, usageFirst: true, occurredAt: OMPFixture.timestamp(6)),
            ].joined(separator: "\n") + "\n",
            to: path
        )
        _ = try await harness.drain()

        let rows = try await harness.store.usageRecentEvents(limit: 10)
        #expect(rows.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.responseID, $0) })
        let small = try #require(byID[OMPFixture.responseID(1)])
        let large = try #require(byID[OMPFixture.responseID(2)])
        #expect(small.acceptedTokens == large.acceptedTokens)
        #expect(small.inputTokens == large.inputTokens)
        #expect(small.outputTokens == large.outputTokens)
        #expect(small.cacheReadTokens == large.cacheReadTokens)
        #expect(small.stopReason == large.stopReason)
        #expect(small.model == large.model)
    }
}
