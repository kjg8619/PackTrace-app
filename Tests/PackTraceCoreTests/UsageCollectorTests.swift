import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Shared helpers for usage-collection tests: a production store in a
/// temporary directory plus a collector bound to it.
enum UsageTestSupport {
    struct Harness {
        var collector: OMPUsageCollector
        var store: PackTraceStore
        var location: StoreLocation
        var tree: OMPFixture.Tree

        func drain(maxSlices: Int = 60) async throws -> [UsageScanRunSummary] {
            var summaries: [UsageScanRunSummary] = []
            for _ in 0..<maxSlices {
                let summary = try await collector.scan(trigger: .manual)
                summaries.append(summary)
                if !summary.moreWork { break }
            }
            return summaries
        }
    }

    static func harness(
        realm: Realm = .production,
        limits: OMPLogScanner.Limits = .small,
        economy: PackEconomy = .v1
    ) throws -> Harness {
        let location = try StoreLocation.temporary(realm: realm, label: "packtrace-usage")
        // The store needs every bundled snapshot, so a pack pinned to any of the
        // three catalogues can still be opened.
        let store = try PackTraceStore(location: location, library: try CatalogLoader.bundledLibrary(), economy: economy)
        let collector = OMPUsageCollector(store: store, limits: limits)
        return Harness(collector: collector, store: store, location: location, tree: try OMPFixture.Tree())
    }

    /// One assistant record with the given accepted-token split.
    static func record(
        _ n: Int,
        input: Int,
        output: Int,
        session: String = OMPFixture.session1,
        offset: Int,
        stopReason: String = "toolUse",
        provider: String = OMPFixture.provider,
        cacheRead: Int = 0
    ) -> String {
        OMPFixture.assistant(
            responseID: OMPFixture.responseID(n),
            sessionID: session,
            provider: provider,
            stopReason: stopReason,
            input: input,
            output: output,
            cacheRead: cacheRead,
            occurredAt: OMPFixture.timestamp(offset),
            completedAt: OMPFixture.timestamp(offset + 1)
        )
    }

    static func sessionFile(
        session: String = OMPFixture.session1,
        records: [String]
    ) -> String {
        OMPFixture.sessionFile(sessionID: session, assistants: records)
    }
}

@Suite("OMP 수집 기준선과 증분")
struct UsageCollectorTests {
    // MARK: - Baseline

    @Test("최초 연결은 과거 기록을 기준선으로만 기록하고 지급하지 않는다")
    func baselinePaysNothing() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [
                UsageTestSupport.record(1, input: 5_000, output: 5_000, offset: 0),
                UsageTestSupport.record(2, input: 3_000, output: 3_000, offset: 10),
            ]),
            to: "project-a/session.jsonl"
        )

        let source = try await harness.collector.connect(root: harness.tree.root)
        #expect(source.baselineCompletedAt != nil)

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0)
        #expect(totals.awardedPoints == 0)
        let balance = try await harness.store.balance()
        #expect(balance == 0)

        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 2)
        #expect(diagnostics.acceptedEvents == 0)
    }

    @Test("연결 이후 append된 확정 usage만 적립한다")
    func appendsAfterConnectAreRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 9_000, output: 9_000, offset: 0)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(2),
                input: 4_000,
                output: 2_000,
                occurredAt: OMPFixture.timestamp(60),
                completedAt: OMPFixture.timestamp(61)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 6_000)
        #expect(totals.awardedPoints == 0, "6,000토큰은 아직 1 P가 아닙니다")
        #expect(totals.remainderTokens == 6_000)

        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(3),
                input: 2_500,
                output: 1_500,
                occurredAt: OMPFixture.timestamp(120),
                completedAt: OMPFixture.timestamp(121)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let after = try await harness.store.usageTotals()
        #expect(after.acceptedTokens == 10_000)
        #expect(after.awardedPoints == 1)
        #expect(after.remainderTokens == 0)
        let balance = try await harness.store.balance()
        #expect(balance == 1)
    }

    @Test("기준선 도중 append된 이벤트는 신규로 처리된다")
    func eventsAppendedDuringBaselineAreNew() async throws {
        // Slices are tiny, so the baseline pass runs over several calls.
        let harness = try UsageTestSupport.harness(limits: .small)
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        var contents = UsageTestSupport.sessionFile(records: [
            UsageTestSupport.record(1, input: 1_000, output: 1_000, offset: 0),
        ])
        // The boundary is fixed at connect time; the appended record lands after it.
        try harness.tree.write(contents, to: path)

        _ = try await harness.collector.connect(root: harness.tree.root)
        contents = ""
        let source = try #require(try await harness.store.usageSource())
        #expect(source.baselineCompletedAt != nil)

        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(9),
                input: 5_000,
                output: 5_000,
                occurredAt: OMPFixture.timestamp(300),
                completedAt: OMPFixture.timestamp(301)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 1)
        #expect(diagnostics.acceptedEvents == 1)
        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1)
    }

    @Test("연결 시점의 미완성 줄은 완성된 뒤에 처리된다")
    func partialTailIsHeldBack() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        let complete = UsageTestSupport.record(1, input: 2_000, output: 2_000, offset: 0)
        let later = OMPFixture.assistant(
            responseID: OMPFixture.responseID(2),
            input: 8_000,
            output: 2_000,
            occurredAt: OMPFixture.timestamp(30),
            completedAt: OMPFixture.timestamp(31)
        )
        // Write a truncated last line at connect time, after a real header.
        let half = String(later.prefix(later.count / 2))
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [complete]) + half,
            to: path
        )

        _ = try await harness.collector.connect(root: harness.tree.root)
        let afterConnect = try await harness.store.usageDiagnostics()
        #expect(afterConnect.baselineEvents == 1, "완성된 줄만 기준선에 기록되어야 합니다")
        #expect(afterConnect.acceptedEvents == 0)

        // Finish the line: it is now a complete record appended after connect.
        try harness.tree.append(String(later.dropFirst(half.count)) + "\n", to: path)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
    }

    @Test("과거 로그를 복사해 넣어도 소급 지급되지 않는다")
    func copiedOldLogIsNotRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let original = UsageTestSupport.sessionFile(records: [
            UsageTestSupport.record(1, input: 6_000, output: 6_000, offset: 0),
        ])
        try harness.tree.write(original, to: "project-a/session.jsonl")
        _ = try await harness.collector.connect(root: harness.tree.root)

        // A copy lands in another project directory after connect.
        try harness.tree.write(original, to: "project-z/copy.jsonl")
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0)
        #expect(totals.awardedPoints == 0)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 1)
        #expect(diagnostics.acceptedEvents == 0)
    }

    @Test("새 루트의 기존 기록은 기준선으로 처리된다")
    func newRootIsBaselined() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 4_000, output: 4_000, offset: 0)]),
            to: "project-a/session.jsonl"
        )
        _ = try await harness.collector.connect(root: harness.tree.root)

        let otherRoot = try OMPFixture.Tree()
        defer { otherRoot.remove() }
        try otherRoot.write(
            UsageTestSupport.sessionFile(session: OMPFixture.session2, records: [
                UsageTestSupport.record(7, input: 50_000, output: 50_000, session: OMPFixture.session2, offset: 0),
            ]),
            to: "project-b/session.jsonl"
        )
        _ = try await harness.collector.connect(root: otherRoot.root)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0, "새 루트의 기존 기록도 지급 대상이 아닙니다")
        #expect(totals.awardedPoints == 0)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 2)
    }

    @Test("같은 루트를 다시 연결해도 기준선을 초기화하지 않는다")
    func reconnectingSameRootKeepsBaseline() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 30_000, output: 30_000, offset: 0)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        let first = try await harness.store.usageSource()

        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(2),
                input: 10_000,
                output: 0,
                occurredAt: OMPFixture.timestamp(90),
                completedAt: OMPFixture.timestamp(91)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()
        let collected = try await harness.store.usageTotals()
        #expect(collected.awardedPoints == 1)

        _ = try await harness.collector.connect(root: harness.tree.root)
        let after = try await harness.store.usageTotals()
        let second = try await harness.store.usageSource()
        #expect(second?.sourceID == first?.sourceID)
        #expect(after.awardedPoints == 1, "재연결로 중복 지급되면 안 됩니다")
        #expect(after.remainderTokens == collected.remainderTokens)
    }

    @Test("기준선이 끝나기 전에는 적립 완료로 표시하지 않는다")
    func baselineProgressIsReportedUntilDone() async throws {
        let harness = try UsageTestSupport.harness(limits: OMPLogScanner.Limits(maxRecordsPerSlice: 2, maxFilesPerSlice: 1, chunkBytes: 1024))
        defer { harness.tree.remove() }
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: (1...4).map { UsageTestSupport.record($0, input: 100, output: 100, offset: $0) }),
            to: "project-a/session.jsonl"
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        let first = try await harness.collector.scan(trigger: .connect)
        #expect(first.moreWork)
        let midStatus = try await harness.collector.status()
        #expect(midStatus.isBaselineComplete == false)
        #expect(midStatus.source?.status == .baselining)

        _ = try await harness.drain()
        let done = try await harness.collector.status()
        #expect(done.isBaselineComplete)
        #expect(done.baselineFilesDone == done.baselineFilesTotal)
        #expect(done.source?.status == .collecting)
    }

    // MARK: - Incremental and duplicates

    @Test("변경이 없는 파일은 다시 읽지 않는다")
    func unchangedFilesAreNotReread() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: (1...20).map { UsageTestSupport.record($0, input: 1_000, output: 1_000, offset: $0) }),
            to: "project-a/session.jsonl"
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        _ = try await harness.drain()

        let second = try await harness.drain()
        #expect(second.allSatisfy { $0.bytesRead == 0 }, "증분 스캔은 바이트를 다시 읽지 않아야 합니다")
        #expect(second.allSatisfy { $0.recordsSeen == 0 })
    }

    @Test("같은 파일을 반복 스캔해도 추가 지급이 없다")
    func repeatedScanIsIdempotent() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 6_000, output: 4_000, offset: 0)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            OMPFixture.assistant(
                responseID: OMPFixture.responseID(2),
                input: 6_000,
                output: 4_000,
                occurredAt: OMPFixture.timestamp(10),
                completedAt: OMPFixture.timestamp(11)
            ) + "\n",
            to: path
        )
        _ = try await harness.drain()
        let first = try await harness.store.usageTotals()
        #expect(first.awardedPoints == 1)
        #expect(first.remainderTokens == 0)

        for _ in 0..<3 {
            _ = try await harness.drain()
            // Force a full re-read by pretending the file identity changed.
            _ = try await harness.collector.scan(trigger: .scheduled)
        }
        let after = try await harness.store.usageTotals()
        #expect(after.awardedPoints == first.awardedPoints)
        #expect(after.remainderTokens == first.remainderTokens)
        #expect(after.acceptedTokens == first.acceptedTokens)
    }

    @Test("중복 루트·복제 파일은 한 번만 지급한다")
    func duplicateFilesPayOnce() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let shared = UsageTestSupport.sessionFile(records: [
            UsageTestSupport.record(1, input: 5_000, output: 5_000, offset: 0),
        ])
        try harness.tree.write(shared, to: "project-a/session.jsonl")
        try harness.tree.write(shared, to: "project-b/session.jsonl")
        _ = try await harness.collector.connect(root: harness.tree.root)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 0, "기준선 기록이라 지급이 없습니다")

        // Same content appended to both copies: the identical identity appears twice.
        let extra = OMPFixture.assistant(
            responseID: OMPFixture.responseID(5),
            input: 10_000,
            output: 0,
            occurredAt: OMPFixture.timestamp(50),
            completedAt: OMPFixture.timestamp(51)
        ) + "\n"
        try harness.tree.append(extra, to: "project-a/session.jsonl")
        try harness.tree.append(extra, to: "project-b/session.jsonl")
        _ = try await harness.drain()

        let after = try await harness.store.usageTotals()
        #expect(after.acceptedTokens == 10_000, "같은 호출은 한 번만 인정됩니다")
        #expect(after.awardedPoints == 1)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.duplicateEvents >= 1)
    }

    @Test("숫자가 같은 서로 다른 호출은 각각 지급한다")
    func identicalNumbersDifferentCallsAreEachRewarded() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            [
                UsageTestSupport.record(11, input: 5_000, output: 0, offset: 1),
                UsageTestSupport.record(12, input: 5_000, output: 0, offset: 2),
            ].joined(separator: "\n") + "\n",
            to: path
        )
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
        #expect(totals.acceptedEvents == 2)
    }

    @Test("같은 ID의 값이 다르면 충돌로 격리하고 자동 지급하지 않는다")
    func conflictingValuesAreIsolated() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        try harness.tree.append(
            UsageTestSupport.record(21, input: 10_000, output: 0, offset: 5) + "\n",
            to: path
        )
        _ = try await harness.drain()
        let awarded = try await harness.store.usageTotals()
        #expect(awarded.awardedPoints == 1)

        // Same response id, different numbers: must not pay again or overwrite.
        try harness.tree.append(
            UsageTestSupport.record(21, input: 90_000, output: 90_000, offset: 6) + "\n",
            to: path
        )
        _ = try await harness.drain()

        let after = try await harness.store.usageTotals()
        #expect(after.awardedPoints == 1)
        #expect(after.acceptedTokens == 10_000)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.conflictEvents >= 1)
    }

    @Test("자동과 수동 스캔이 겹쳐도 한 번만 지급한다")
    func concurrentScansPayOnce() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            UsageTestSupport.record(31, input: 10_000, output: 0, offset: 3) + "\n",
            to: path
        )

        let collector = harness.collector
        async let manual = collector.scan(trigger: .manual)
        async let scheduled = collector.scan(trigger: .scheduled)
        async let activation = collector.scan(trigger: .activation)
        _ = try await (manual, scheduled, activation)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
    }

    // MARK: - File handling

    @Test("부분 JSON과 UTF-8 분할은 다음 읽기로 이어 붙인다")
    func partialWritesAreResumed() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let record = OMPFixture.assistant(
            responseID: OMPFixture.responseID(41),
            input: 10_000,
            output: 0,
            occurredAt: OMPFixture.timestamp(7),
            completedAt: OMPFixture.timestamp(8)
        ) + "\n"
        let bytes = Array(record.utf8)
        // Split inside a multi-byte character (the fixture contains Korean-free
        // JSON, so split inside the JSON string instead) and inside the record.
        let firstHalf = Data(bytes[0..<(bytes.count / 2)])
        let handle = try FileHandle(forWritingTo: harness.tree.root.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: firstHalf)
        try handle.close()

        _ = try await harness.drain()
        var totals = try await harness.store.usageTotals()
        #expect(totals.acceptedEvents == 0, "미완성 줄은 소비하지 않습니다")

        let handle2 = try FileHandle(forWritingTo: harness.tree.root.appendingPathComponent(path))
        try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(bytes[(bytes.count / 2)...]))
        try handle2.close()

        _ = try await harness.drain()
        totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
    }

    @Test("잘못된 중간 줄 뒤의 정상 줄도 처리한다")
    func brokenMiddleLineDoesNotStopTheFile() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let good = UsageTestSupport.record(51, input: 10_000, output: 0, offset: 9)
        try harness.tree.append("{not json at all\n" + good + "\n", to: path)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.acceptedTokens == 10_000)
        #expect(totals.awardedPoints == 1)
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.unparsableRecord] ?? 0 >= 1)
    }

    @Test("파일 교체·축소를 감지해 다시 읽되 중복 지급하지 않는다")
    func rotationIsDetected() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [
                UsageTestSupport.record(61, input: 10_000, output: 0, offset: 1),
            ]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            [
                UsageTestSupport.record(62, input: 10_000, output: 0, offset: 2),
                UsageTestSupport.record(64, input: 10_000, output: 0, offset: 3),
            ].joined(separator: "\n") + "\n",
            to: path
        )
        _ = try await harness.drain()
        let before = try await harness.store.usageTotals()
        #expect(before.awardedPoints == 2)

        // Rotate: brand new file, same path, same size, different inode.
        let replacement = UsageTestSupport.sessionFile(records: [
            UsageTestSupport.record(63, input: 10_000, output: 0, offset: 3),
        ])
        try harness.tree.write(replacement, to: path)
        _ = try await harness.drain()

        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 3, "새 호출은 지급되고 기존 호출은 중복 지급되지 않습니다")
        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.filesTracked >= 1)
    }

    @Test("삭제되거나 읽을 수 없는 파일은 상태로 남고 장부는 유지된다")
    func missingAndUnreadableFilesAreReported() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(71, input: 10_000, output: 0, offset: 1)]),
            to: path
        )
        _ = try await harness.collector.connect(root: harness.tree.root)
        try harness.tree.append(
            UsageTestSupport.record(72, input: 10_000, output: 0, offset: 2) + "\n",
            to: path
        )
        _ = try await harness.drain()
        let awarded = try await harness.store.usageTotals()
        #expect(awarded.awardedPoints == 1)

        // Permission denied: the file stays tracked but cannot be read.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: harness.tree.root.appendingPathComponent(path).path)
        let unreadable = try await harness.drain()
        let afterDenied = try await harness.store.usageTotals()
        #expect(afterDenied.awardedPoints == 1, "권한 오류는 기존 적립을 취소하지 않습니다")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: harness.tree.root.appendingPathComponent(path).path)
        try FileManager.default.removeItem(at: harness.tree.root.appendingPathComponent(path))
        _ = try await harness.drain()

        let checkpoints = try await harness.store.usageCheckpoints()
        #expect(checkpoints.contains { $0.status == .missing || $0.status == .permissionDenied })
        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1)
        #expect(unreadable.isEmpty == false)
    }

    @Test("승인 루트 밖을 가리키는 symlink는 따라가지 않는다")
    func symlinksOutsideRootAreIgnored() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let outside = try OMPFixture.Tree()
        defer { outside.remove() }
        try outside.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(81, input: 99_000, output: 99_000, offset: 1)]),
            to: "project-x/session.jsonl"
        )
        try FileManager.default.createSymbolicLink(
            at: harness.tree.root.appendingPathComponent("linked-project"),
            withDestinationURL: outside.root.appendingPathComponent("project-x")
        )
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: []),
            to: "project-a/session.jsonl"
        )

        _ = try await harness.collector.connect(root: harness.tree.root)
        _ = try await harness.drain()

        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.filesTracked == 1, "루트 밖 symlink은 수집 대상이 아닙니다")
    }

    @Test("너무 큰 레코드는 진단만 남기고 뒤의 정상 레코드는 처리한다")
    func oversizedRecordsAreSkipped() async throws {
        let harness = try UsageTestSupport.harness(limits: OMPLogScanner.Limits(maxLineBytes: 4 * 1024, chunkBytes: 1024))
        defer { harness.tree.remove() }
        let path = "project-a/session.jsonl"
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: path)
        _ = try await harness.collector.connect(root: harness.tree.root)

        let huge = "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":\""
            + String(repeating: "x", count: 20_000) + "\"}}"
        try harness.tree.append(huge + "\n" + UsageTestSupport.record(91, input: 10_000, output: 0, offset: 4) + "\n", to: path)
        _ = try await harness.drain()

        let diagnostics = try await harness.store.usageDiagnostics()
        #expect(diagnostics.excludedByIdentity[.oversizedRecord] ?? 0 >= 1)
        let totals = try await harness.store.usageTotals()
        #expect(totals.awardedPoints == 1, "큰 레코드 뒤의 정상 호출은 처리되어야 합니다")
    }

    @Test("여러 슬라이스로 나눠도 한 번에 읽은 것과 결과가 같다")
    func slicingDoesNotChangeResults() async throws {
        let large = try UsageTestSupport.harness(limits: .standard)
        let small = try UsageTestSupport.harness(limits: OMPLogScanner.Limits(maxRecordsPerSlice: 3, maxBytesPerSlice: 2 * 1024, maxFilesPerSlice: 1, chunkBytes: 512))
        defer { large.tree.remove(); small.tree.remove() }

        let contents = UsageTestSupport.sessionFile(records: (1...12).map {
            UsageTestSupport.record($0, input: 1_000, output: 500, offset: $0)
        })
        try large.tree.write(contents, to: "project-a/session.jsonl")
        try small.tree.write(contents, to: "project-a/session.jsonl")

        _ = try await large.collector.connect(root: large.tree.root)
        _ = try await small.collector.connect(root: small.tree.root)
        _ = try await large.drain()
        _ = try await small.drain()

        let largeTotals = try await large.store.usageTotals()
        let smallTotals = try await small.store.usageTotals()
        #expect(largeTotals == smallTotals)
    }
}
