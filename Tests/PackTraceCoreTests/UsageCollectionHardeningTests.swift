import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// OMP and OpenCode collection edges found in the 2026-09-24 review: files past
/// the slice's file budget, found files read over several slices, a file that
/// can never finish its baseline, the single-source helpers, and OpenCode rows
/// created while the baseline is still being fixed. Synthetic data only.
@Suite("사용량 수집 보강 (OMP·OpenCode)", .serialized)
struct UsageCollectionHardeningTests {
    /// The OMP fixtures are stamped from `OMPFixture.timestamp(0)`; the
    /// connection is placed a little before that, so offset ≥ 0 is "after".
    static let connectedAt = Date(timeIntervalSince1970: Double(OMPFixture.timestamp(0)) / 1000 - 60)

    static func collector(_ store: PackTraceStore, limits: OMPLogScanner.Limits = .small) -> OMPUsageCollector {
        OMPUsageCollector(store: store, limits: limits, clock: { connectedAt })
    }

    static func drain(_ collector: OMPUsageCollector, slices: Int = 60) async throws {
        for _ in 0..<slices {
            let run = try await collector.scan(trigger: .manual)
            if !run.moreWork { break }
        }
    }

    // MARK: - OMP

    @Test("OMP 세션 파일이 슬라이스 파일 한도보다 많아도 모두 보고, 연결 뒤 기록을 모두 적립한다")
    func ompSeesFilesPastTheLimit() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let collector = Self.collector(harness.store)
        // Five sessions, three files per slice (`Limits.small`).
        let paths = (1...5).map { "project-\($0)/session.jsonl" }
        for (index, path) in paths.enumerated() {
            try harness.tree.write(
                UsageTestSupport.sessionFile(records: [
                    UsageTestSupport.record(index * 10, input: 1, output: 1, offset: -600),
                ]),
                to: path
            )
        }
        _ = try await collector.connect(root: harness.tree.root)
        try await Self.drain(collector)
        #expect(try await harness.store.usageTotals().acceptedTokens == 0)
        let tracked = try await harness.store.usageCheckpoints()
        #expect(tracked.count == 5, "한도 밖 파일도 추적해야 합니다")
        #expect(tracked.allSatisfy { $0.status != .missing }, "보이지 않는다고 사라진 파일로 표시하면 안 됩니다")

        for (index, path) in paths.enumerated() {
            try harness.tree.append(UsageTestSupport.record(index * 10 + 1, input: 1_000, output: 0, offset: 10) + "\n", to: path)
        }
        try await Self.drain(collector)
        #expect(try await harness.store.usageTotals().acceptedTokens == 5_000)
    }

    @Test("OMP 연결 뒤 처음 보인 파일은 여러 슬라이스에 걸쳐도 연결 전 기록을 적립하지 않는다")
    func ompFoundFileFilterSurvivesSlices() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let collector = Self.collector(harness.store)
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: "seed/session.jsonl")
        _ = try await collector.connect(root: harness.tree.root)
        try await Self.drain(collector)

        // Eight records from before the connection (five per slice), then one
        // after it, in a session the scan meets only now.
        var records = (1...8).map { UsageTestSupport.record($0, input: 1_000, output: 0, session: OMPFixture.session2, offset: -500 + $0) }
        records.append(UsageTestSupport.record(99, input: 700, output: 0, session: OMPFixture.session2, offset: 30))
        try harness.tree.write(UsageTestSupport.sessionFile(session: OMPFixture.session2, records: records), to: "late/session.jsonl")
        try await Self.drain(collector)
        #expect(try await harness.store.usageTotals().acceptedTokens == 700)
    }

    @Test("세션 헤더가 없는 파일이 OMP 기준선을 영원히 붙잡지 않는다")
    func headerlessFileDoesNotHoldTheBaseline() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let collector = Self.collector(harness.store)
        try harness.tree.write(
            UsageTestSupport.sessionFile(records: [UsageTestSupport.record(1, input: 1, output: 1, offset: -600)]),
            to: "good/session.jsonl"
        )
        // Records but no session header, last written long ago.
        let broken = try harness.tree.write(
            UsageTestSupport.record(2, input: 1, output: 1, offset: -600) + "\n",
            to: "broken/session.jsonl"
        )
        try FileManager.default.setAttributes([.modificationDate: Self.connectedAt.addingTimeInterval(-3_600)], ofItemAtPath: broken.path)

        _ = try await collector.connect(root: harness.tree.root)
        try await Self.drain(collector)
        let source = try #require(try await harness.store.usageSource())
        #expect(source.baselineCompletedAt != nil, "읽을 수 없는 파일 하나 때문에 기준선이 끝나지 않으면 안 됩니다")
        #expect(try await harness.store.usageCheckpoints().contains { $0.status == .error }, "그 파일은 오류로 보고됩니다")
    }

    @Test("단일 소스 조회와 스캔 시각은 다른 도구가 나중에 연결돼도 OMP 행만 다룬다")
    func singleSourceHelpersAreOMP() async throws {
        let harness = try UsageTestSupport.harness()
        defer { harness.tree.remove() }
        let collector = Self.collector(harness.store)
        try harness.tree.write(UsageTestSupport.sessionFile(records: []), to: "p/session.jsonl")
        let omp = try await collector.connect(root: harness.tree.root)

        let codexRoot = harness.tree.root.appendingPathComponent("codex-root", isDirectory: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let codex = try await harness.store.connectUsageSource(tool: .codex, rootPath: codexRoot.path, now: Self.connectedAt.addingTimeInterval(120))

        #expect(try await harness.store.usageSource()?.sourceID == omp.sourceID)
        #expect(try await harness.store.latestUsageSource()?.sourceID == omp.sourceID)
        let stamp = Self.connectedAt.addingTimeInterval(500)
        try await harness.store.recordUsageScanTime(stamp)
        #expect(try await harness.store.usageSource(id: omp.sourceID)?.lastScanAt == stamp)
        #expect(try await harness.store.usageSource(id: codex.sourceID)?.lastScanAt == nil, "Codex 행에 OMP 스캔 시각을 쓰면 안 됩니다")
    }

    // MARK: - OpenCode

    static func openCodeDatabase(at root: URL) throws -> SQLiteDatabase {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: root.appendingPathComponent(OpenCodeUsageAdapter.databaseName).path)
        try db.execute("""
        CREATE TABLE IF NOT EXISTS message (
            id text PRIMARY KEY,
            session_id text NOT NULL,
            time_created integer NOT NULL,
            time_updated integer NOT NULL,
            data text NOT NULL
        );
        """)
        return db
    }

    static func insert(_ db: SQLiteDatabase, id: String, createdAt: Date, input: Int) throws {
        let object: [String: Any] = [
            "role": "assistant",
            "providerID": "opencode",
            "modelID": "fixture-model",
            "finish": "stop",
            "tokens": ["input": input, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0], "total": input],
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let ms = Int(createdAt.timeIntervalSince1970 * 1000)
        try db.run(
            "INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
            [.text(id), .text("oc-session"), .int(ms), .int(ms), .text(json)]
        )
    }

    @Test("OpenCode 기준선이 여러 패스에 걸치는 동안 연결 뒤 생긴 행은 기준선이 되지 않고 적립된다")
    func openCodeRowsCreatedDuringTheBaselineAreCredited() async throws {
        let location = try StoreLocation.temporary(realm: .production, label: "packtrace-hardening-store")
        try location.prepareDirectories()
        defer { TestOwnedRoot.remove(location.directory.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-hardening-opencode-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { TestOwnedRoot.remove(root) }
        let db = try Self.openCodeDatabase(at: root)
        defer { db.close() }
        for index in 0..<5 {
            try Self.insert(db, id: "old-\(index)", createdAt: Self.connectedAt.addingTimeInterval(-100 + Double(index)), input: 1_000)
        }

        let store = try PackTraceStore(location: location, library: try CatalogLoader.bundledLibrary())
        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry([OpenCodeUsageAdapter()]),
            budget: UsageScanBudget(maxFiles: 8, maxRecords: 2_000, maxBytes: 1024 * 1024, maxRows: 2),
            clock: { Self.connectedAt }
        )
        // Two rows per pass: the connect pass fixes only part of the baseline.
        let source = try await coordinator.connect(tool: .openCode, rootPath: root)
        #expect(source.baselineCompletedAt == nil)
        // A call made after the connection, while the baseline is still open.
        try Self.insert(db, id: "new-0", createdAt: Self.connectedAt.addingTimeInterval(30), input: 700)
        for _ in 0..<20 {
            let run = try await coordinator.scan(trigger: .manual)
            if !run.moreWork, try await store.usageSource(id: source.sourceID)?.baselineCompletedAt != nil { break }
        }
        _ = try await coordinator.scan(trigger: .manual)
        let accepted = try await store.usageToolTotals().first { $0.tool == .openCode }?.acceptedTokens ?? 0
        #expect(accepted == 700, "연결 뒤 호출만 적립되고, 연결 전 5,000은 적립되지 않습니다")
    }
}
