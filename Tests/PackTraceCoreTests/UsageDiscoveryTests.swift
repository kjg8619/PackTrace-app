import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Seeing every session file, and crediting exactly the usage that happened
/// after the connection.
///
/// Before this, a slice only ever looked at the first eight files the directory
/// walk returned — the same eight every time — so on a real machine (3,226 Codex
/// sessions, 99 Claude Code transcripts) new sessions were almost never read,
/// and Codex calls of every session after the first were taken for duplicates
/// of the first one's (the per-file ordinal was stored as a global response id).
/// Synthetic files in a temporary root only; no real log is read.
@Suite("세션 파일 발견과 연결 이후 적립", .serialized)
struct UsageDiscoveryTests {
    // MARK: - Fixtures

    /// Connection time an hour in the past, so "before" and "after" it are both
    /// real moments and files written now count as modified after it.
    static let connectedAt = Date().addingTimeInterval(-3_600)
    static let before = connectedAt.addingTimeInterval(-600)
    static let after = connectedAt.addingTimeInterval(600)

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    struct Tree {
        var root: URL
        func remove() { TestOwnedRoot.remove(root) }

        @discardableResult
        func write(_ text: String, to relative: String, modified: Date? = nil) throws -> URL {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if let modified {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            return url
        }

        func append(_ text: String, to relative: String) throws {
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent(relative))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
    }

    static func tree(_ label: String) throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-discovery-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Tree(root: root)
    }

    // Codex rollout records: a header, then token_count events whose cumulative
    // total grows by exactly the request's own total.
    static func codexMeta(_ session: String) -> String {
        #"{"timestamp":"\#(iso(before))","type":"session_meta","payload":{"id":"\#(session)","cli_version":"0.155.1","model_provider":"openai"}}"# + "\n"
    }

    static func codexCall(ordinal: Int, previousTotal: Int, input: Int, at date: Date) -> String {
        let total = previousTotal + input
        return #"{"timestamp":"\#(iso(date))","ordinal":\#(ordinal),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(total)},"last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\#(input)},"model_context_window":272000}}}"# + "\n"
    }

    static func codexPath(_ session: String, day: Int = 23) -> String {
        String(format: "2026/09/%02d/rollout-%@.jsonl", day, session)
    }

    static func claudeRecord(session: String, request: String, input: Int, at date: Date) -> String {
        #"{"type":"assistant","uuid":"u-\#(request)","sessionId":"\#(session)","isSidechain":false,"timestamp":"\#(iso(date))","requestId":"\#(request)","message":{"id":"\#(request)","model":"claude-fixture","stop_reason":"end_turn","usage":{"input_tokens":\#(input),"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"# + "\n"
    }

    struct Setup {
        var store: PackTraceStore
        var coordinator: UsageCoordinator
        var location: StoreLocation
    }

    static func setup(adapter: any UsageSourceAdapter, budget: UsageScanBudget = .standard) throws -> Setup {
        let location = try StoreLocation.temporary(realm: .production, label: "packtrace-discovery-store")
        try location.prepareDirectories()
        let store = try PackTraceStore(location: location, library: try CatalogLoader.bundledLibrary())
        let coordinator = UsageCoordinator(
            store: store,
            registry: UsageAdapterRegistry([adapter]),
            budget: budget,
            clock: { connectedAt }
        )
        return Setup(store: store, coordinator: coordinator, location: location)
    }

    static func drain(_ coordinator: UsageCoordinator, passes: Int = 30) async throws -> [UsageScanRunSummary] {
        var runs: [UsageScanRunSummary] = []
        for _ in 0..<passes {
            let run = try await coordinator.scan(trigger: .manual)
            runs.append(run)
            if !run.moreWork { break }
        }
        return runs
    }

    static func accepted(_ store: PackTraceStore, _ tool: UsageToolKind) async throws -> Int {
        try await store.usageToolTotals().first { $0.tool == tool }?.acceptedTokens ?? 0
    }

    // MARK: - Every file, every session

    @Test("세션 파일이 슬라이스 예산보다 많아도 연결 뒤 호출은 세션마다 모두 적립된다 (Codex)")
    func codexSeesEverySession() async throws {
        let tree = try Self.tree("codex-many")
        defer { tree.remove() }
        let sessions = (1...12).map { "codex-\($0)" }
        for (index, session) in sessions.enumerated() {
            try tree.write(
                Self.codexMeta(session) + Self.codexCall(ordinal: 0, previousTotal: 0, input: 5_000, at: Self.before),
                to: Self.codexPath(session, day: index + 1),
                modified: Self.before
            )
        }
        let setup = try Self.setup(adapter: CodexUsageAdapter())
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        _ = try await setup.coordinator.connect(tool: .codex, rootPath: tree.root)
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .codex) == 0, "연결 전 기록은 적립되지 않습니다")
        #expect(try await setup.store.usageCheckpoints().count == sessions.count, "모든 세션 파일에 기준선이 있어야 합니다")

        // Every session makes one call after the connection, with the same
        // per-file ordinal: the ordinals collide across sessions on purpose.
        for (index, session) in sessions.enumerated() {
            try tree.append(Self.codexCall(ordinal: 1, previousTotal: 5_000, input: 1_000, at: Self.after), to: Self.codexPath(session, day: index + 1))
        }
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .codex) == 12_000, "12개 세션 × 1,000")

        // Scanning again credits nothing more.
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .codex) == 12_000)
    }

    @Test("transcript가 슬라이스 예산보다 많아도 연결 뒤 호출은 모두 적립된다 (Claude Code)")
    func claudeSeesEveryTranscript() async throws {
        let tree = try Self.tree("claude-many")
        defer { tree.remove() }
        let sessions = (1...12).map { "claude-\($0)" }
        for session in sessions {
            try tree.write(
                Self.claudeRecord(session: session, request: "\(session)-old", input: 4_000, at: Self.before),
                to: "project/\(session).jsonl",
                modified: Self.before
            )
        }
        let setup = try Self.setup(adapter: ClaudeCodeUsageAdapter())
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        _ = try await setup.coordinator.connect(tool: .claudeCode, rootPath: tree.root)
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .claudeCode) == 0)

        for session in sessions {
            try tree.append(Self.claudeRecord(session: session, request: "\(session)-new", input: 1_000, at: Self.after), to: "project/\(session).jsonl")
        }
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .claudeCode) == 12_000)
    }

    // MARK: - Files first seen after the connection

    @Test("연결 뒤 처음 보인 파일은 연결 전 기록을 기준선으로, 연결 뒤 기록만 적립한다 (Codex)")
    func codexNewFileSplitsAtTheConnection() async throws {
        let tree = try Self.tree("codex-new")
        defer { tree.remove() }
        try tree.write(Self.codexMeta("existing"), to: Self.codexPath("existing"), modified: Self.before)
        let setup = try Self.setup(adapter: CodexUsageAdapter())
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        _ = try await setup.coordinator.connect(tool: .codex, rootPath: tree.root)
        _ = try await Self.drain(setup.coordinator)

        // A session file the scan meets only now: two calls from before the
        // connection (an older session never seen, or a copy), one after it.
        var text = Self.codexMeta("found-later")
        text += Self.codexCall(ordinal: 0, previousTotal: 0, input: 5_000, at: Self.before)
        text += Self.codexCall(ordinal: 1, previousTotal: 5_000, input: 2_000, at: Self.before)
        text += Self.codexCall(ordinal: 2, previousTotal: 7_000, input: 3_000, at: Self.after)
        try tree.write(text, to: Self.codexPath("found-later", day: 24))
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .codex) == 3_000, "연결 뒤 3,000만")
        let diagnostics = try await setup.store.usageDiagnostics()
        #expect(diagnostics.baselineEvents == 2, "연결 전 두 호출은 적립 없이 기준선으로 기록됩니다")
        #expect(diagnostics.acceptedEvents == 1)
    }

    @Test("연결 뒤 처음 보인 파일이 여러 슬라이스에 걸쳐도 연결 전 기록은 적립되지 않는다")
    func newFileFilterSurvivesSlices() async throws {
        let tree = try Self.tree("claude-slices")
        defer { tree.remove() }
        try tree.write(Self.claudeRecord(session: "seed", request: "seed", input: 1, at: Self.before), to: "p/seed.jsonl", modified: Self.before)
        // About two records per slice: the found file needs several slices.
        let setup = try Self.setup(
            adapter: ClaudeCodeUsageAdapter(),
            budget: UsageScanBudget(maxFiles: 8, maxRecords: 2_000, maxBytes: 700, maxRows: 100)
        )
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        _ = try await setup.coordinator.connect(tool: .claudeCode, rootPath: tree.root)
        _ = try await Self.drain(setup.coordinator)

        var text = ""
        for index in 0..<10 {
            text += Self.claudeRecord(session: "late", request: "old-\(index)", input: 1_000, at: Self.before)
        }
        text += Self.claudeRecord(session: "late", request: "new-0", input: 700, at: Self.after)
        try tree.write(text, to: "p/late.jsonl")
        let runs = try await Self.drain(setup.coordinator)
        #expect(runs.count >= 3, "여러 슬라이스로 나뉘어야 이 경우를 시험합니다")
        #expect(try await Self.accepted(setup.store, .claudeCode) == 700)
    }

    // MARK: - Reading only what is needed

    @Test("연결 뒤 한 번도 수정되지 않은 파일은 읽지 않고, 나중에 이어 쓰면 그 부분만 적립한다")
    func untouchedFilesAreNotRead() async throws {
        let tree = try Self.tree("codex-untouched")
        defer { tree.remove() }
        try tree.write(Self.codexMeta("seed"), to: Self.codexPath("seed"), modified: Self.before)
        let setup = try Self.setup(adapter: CodexUsageAdapter())
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        _ = try await setup.coordinator.connect(tool: .codex, rootPath: tree.root)
        _ = try await Self.drain(setup.coordinator)

        // Old sessions that only now become visible, untouched since before the
        // connection: marked as history without reading a byte.
        for index in 1...6 {
            var text = Self.codexMeta("old-\(index)")
            text += Self.codexCall(ordinal: 0, previousTotal: 0, input: 2_000, at: Self.before)
            text += Self.codexCall(ordinal: 1, previousTotal: 2_000, input: 3_000, at: Self.before)
            try tree.write(text, to: Self.codexPath("old-\(index)", day: 10), modified: Self.before)
        }
        let runs = try await Self.drain(setup.coordinator)
        #expect(runs.reduce(0) { $0 + $1.bytesRead } == 0, "수정되지 않은 옛 파일은 읽지 않습니다")
        #expect(try await Self.accepted(setup.store, .codex) == 0)

        // One of them is resumed: the counter at the boundary is looked up then,
        // so the new call's increase is recognised as exactly one request.
        try tree.append(Self.codexCall(ordinal: 2, previousTotal: 5_000, input: 1_500, at: Self.after), to: Self.codexPath("old-3", day: 10))
        _ = try await Self.drain(setup.coordinator)
        #expect(try await Self.accepted(setup.store, .codex) == 1_500)
    }

    @Test("기준선은 파일을 읽지 않고 잡히며, 한 슬라이스에 새로 표시하는 파일 수에는 상한이 있다")
    func baselineIsCheapAndBounded() async throws {
        let tree = try Self.tree("codex-bounded")
        defer { tree.remove() }
        for index in 1...12 {
            try tree.write(
                Self.codexMeta("s\(index)") + Self.codexCall(ordinal: 0, previousTotal: 0, input: 1_000, at: Self.before),
                to: Self.codexPath("s\(index)", day: index),
                modified: Self.before
            )
        }
        let setup = try Self.setup(
            adapter: CodexUsageAdapter(),
            budget: UsageScanBudget(maxFiles: 8, maxRecords: 2_000, maxBytes: 1024 * 1024, maxRows: 100, maxNewFiles: 5)
        )
        defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
        let source = try await setup.coordinator.connect(tool: .codex, rootPath: tree.root)
        #expect(source.baselineCompletedAt == nil, "첫 슬라이스는 5개만 표시하고 남은 일을 알립니다")
        let runs = try await Self.drain(setup.coordinator)
        #expect(runs.allSatisfy { $0.bytesRead == 0 }, "기준선은 내용을 읽지 않습니다")
        #expect(try await setup.store.usageCheckpoints().count == 12)
        #expect(try await setup.store.usageSource(tool: .codex)?.baselineCompletedAt != nil)
    }

    // MARK: - Oversized records

    @Test("읽기 창보다 긴 레코드 하나가 파일을 멈추게 하지 않는다 (Claude Code·Codex)")
    func oversizedRecordIsSkipped() async throws {
        let filler = String(repeating: "x", count: 2_000)
        let budget = UsageScanBudget(maxFiles: 8, maxRecords: 2_000, maxBytes: 600, maxRows: 100)

        // Claude Code.
        do {
            let tree = try Self.tree("claude-oversized")
            defer { tree.remove() }
            try tree.write(Self.claudeRecord(session: "s", request: "seed", input: 1, at: Self.before), to: "p/s.jsonl", modified: Self.before)
            let setup = try Self.setup(adapter: ClaudeCodeUsageAdapter(reader: UsageJSONLReader(maxLineBytes: 500)), budget: budget)
            defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
            _ = try await setup.coordinator.connect(tool: .claudeCode, rootPath: tree.root)
            _ = try await Self.drain(setup.coordinator)
            try tree.append(#"{"type":"assistant","note":"\#(filler)"}"# + "\n", to: "p/s.jsonl")
            try tree.append(Self.claudeRecord(session: "s", request: "after-big", input: 900, at: Self.after), to: "p/s.jsonl")
            _ = try await Self.drain(setup.coordinator)
            #expect(try await Self.accepted(setup.store, .claudeCode) == 900)
        }

        // Codex: the skipped record carried no call, so the counter still lines up.
        do {
            let tree = try Self.tree("codex-oversized")
            defer { tree.remove() }
            try tree.write(
                Self.codexMeta("big") + Self.codexCall(ordinal: 0, previousTotal: 0, input: 1_000, at: Self.before),
                to: Self.codexPath("big"),
                modified: Self.before
            )
            let setup = try Self.setup(adapter: CodexUsageAdapter(maxLineBytes: 500), budget: budget)
            defer { TestOwnedRoot.remove(setup.location.directory.deletingLastPathComponent()) }
            _ = try await setup.coordinator.connect(tool: .codex, rootPath: tree.root)
            _ = try await Self.drain(setup.coordinator)
            try tree.append(#"{"type":"response_item","note":"\#(filler)"}"# + "\n", to: Self.codexPath("big"))
            try tree.append(Self.codexCall(ordinal: 1, previousTotal: 1_000, input: 400, at: Self.after), to: Self.codexPath("big"))
            _ = try await Self.drain(setup.coordinator)
            #expect(try await Self.accepted(setup.store, .codex) == 400)
        }
    }

    // MARK: - Rule table

    @Test("파일 처리 규칙: 기준선 중·연결 전 수정은 기록만, 연결 뒤 수정은 처음부터, 아는 파일은 늘어난 만큼")
    func planTable() {
        let connected = Self.connectedAt
        func plan(_ checkpoint: UsageFileCheckpoint?, size: Int64, modified: Date, baselining: Bool = false) -> UsageFilePlan {
            UsageFilePlan.decide(
                relativePath: "f.jsonl",
                checkpoint: checkpoint,
                size: size,
                modified: modified,
                connectedAt: connected,
                isBaselining: baselining,
                deviceID: 1,
                inode: 1,
                now: connected
            )
        }
        func known(offset: Int64, done: Bool = true) -> UsageFileCheckpoint {
            UsageFileCheckpoint(
                relativePath: "f.jsonl", deviceID: 1, inode: 1, byteOffset: offset, baselineOffset: offset,
                baselineDone: done, fileSize: offset, status: .ok, reason: nil, updatedAt: connected
            )
        }
        #expect(plan(nil, size: 100, modified: Self.after, baselining: true) == .markHistory)
        #expect(plan(nil, size: 100, modified: Self.before) == .markHistory)
        guard case let .read(fresh, fromStart) = plan(nil, size: 100, modified: Self.after) else {
            Issue.record("연결 뒤 수정된 새 파일은 읽어야 합니다")
            return
        }
        #expect(fromStart && fresh.byteOffset == 0 && fresh.baselineOffset == 100)
        #expect(plan(known(offset: 100), size: 100, modified: Self.after) == .skip)
        #expect(plan(known(offset: 100), size: 150, modified: Self.after) == .read(known(offset: 100), fromStart: false))
        // Shorter than what was read: replaced. Read again from the start if it
        // was written after the connection, otherwise just a new boundary.
        guard case .read(_, true) = plan(known(offset: 100), size: 40, modified: Self.after) else {
            Issue.record("교체된 파일은 처음부터 다시 읽어야 합니다")
            return
        }
        #expect(plan(known(offset: 100), size: 40, modified: Self.before) == .markHistory)
        // A boundary a restore reset is fixed again, never resumed from zero.
        #expect(plan(known(offset: 0, done: false), size: 500, modified: Self.after) == .markHistory)

        // Inside the found region only post-connection records count; past it, all.
        let region = UsageFileCheckpoint(
            relativePath: "f.jsonl", deviceID: 1, inode: 1, byteOffset: 0, baselineOffset: 100,
            baselineDone: true, fileSize: 100, status: .ok, reason: nil, updatedAt: connected
        )
        #expect(UsageFilePlan.isCreditable(recordStart: 10, checkpoint: region, occurredAt: Self.before, connectedAt: connected) == false)
        #expect(UsageFilePlan.isCreditable(recordStart: 10, checkpoint: region, occurredAt: Self.after, connectedAt: connected))
        #expect(UsageFilePlan.isCreditable(recordStart: 100, checkpoint: region, occurredAt: Self.before, connectedAt: connected))
    }

    @Test("2^63처럼 Int에 담기지 않는 값은 거절한다 (크래시 없음)")
    func hugeNumbersAreRefused() {
        let reader = UsageJSONLReader()
        let huge = NSNumber(value: 9_223_372_036_854_775_808.0)
        #expect(reader.intValue(huge) == nil)
        #expect(CodexUsageAdapter().intValue(9_223_372_036_854_775_808.0) == nil)
        #expect(CodexUsageAdapter().intValue(huge) == nil)
        #expect(reader.intValue(NSNumber(value: 12_345)) == 12_345)
        #expect(reader.intValue(NSNumber(value: true)) == nil, "true는 1토큰이 아닙니다")
        #expect(reader.intValue(NSNumber(value: -3)) == nil)
        #expect(reader.intValue(NSNumber(value: 2.5)) == nil)
        // Through JSON, as the adapters actually receive them.
        let parsed = try? JSONSerialization.jsonObject(with: Data(#"{"a":9223372036854775808,"b":42}"#.utf8)) as? [String: Any]
        #expect(reader.intValue(parsed?["a"]) == nil)
        #expect(reader.intValue(parsed?["b"]) == 42)
    }
}
