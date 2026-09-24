import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Opt-in probe over the real tool storages on this machine.
///
/// Runs only with `PACKTRACE_REAL_USAGE_PROBE=1`. It reads the real directories
/// **read-only** with a bounded slice, and writes to a throwaway PackTrace
/// database under the temporary directory. It never appends to, rewrites or
/// configures another tool's storage.
///
/// What it establishes: that each adapter recognises the installed format and
/// parses actual records. What it does not: any new usage after a connection
/// (nothing is credited here, because every record is history at this point).
@Suite("실제 사용량 코퍼스 프로브", .serialized)
struct RealUsageCorpusProbeTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PACKTRACE_REAL_USAGE_PROBE"] == "1"
    }

    struct ToolReport {
        var tool: UsageToolKind
        var rootExists: Bool
        var support: String
        var toolVersion: String?
        var formatVersion: String?
        var filesConsidered = 0
        var recordsSeen = 0
        var parsedEvents = 0
        var acceptedTokens = 0
        var excludedEntries = 0
        var unsupportedEntries = 0
        var moreWork = false
        var notes: [String] = []
    }

    static func root(for tool: UsageToolKind) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch tool {
        case .codex:
            return home.appendingPathComponent(".codex/sessions", isDirectory: true)
        case .claudeCode:
            return home.appendingPathComponent(".claude/projects", isDirectory: true)
        case .openCode:
            return home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        case .omp:
            return home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        case .pi, .omo, .senpi:
            return home.appendingPathComponent(PiSessionUsageAdapter.defaultRoot(for: tool), isDirectory: true)
        case .hermes:
            return home.appendingPathComponent(".hermes", isDirectory: true)
        case .grok:
            return home.appendingPathComponent(".grok/sessions", isDirectory: true)
        case .kimi:
            return home.appendingPathComponent(".kimi-code/sessions", isDirectory: true)
        }
    }

    static func adapter(for tool: UsageToolKind) -> (any UsageSourceAdapter)? {
        switch tool {
        case .codex: CodexUsageAdapter()
        case .claudeCode: ClaudeCodeUsageAdapter()
        case .openCode: OpenCodeUsageAdapter()
        case .omp: nil // collected by its own collector in this build
        case .pi, .omo, .senpi: PiSessionUsageAdapter(tool: tool)
        case .hermes: HermesUsageAdapter()
        case .grok: GrokUsageAdapter()
        case .kimi: KimiUsageAdapter()
        }
    }

    static func probe(_ tool: UsageToolKind) async -> ToolReport {
        var report = ToolReport(tool: tool, rootExists: false, support: "n/a")
        let root = root(for: tool)
        report.rootExists = FileManager.default.fileExists(atPath: root.path)
        guard report.rootExists, let adapter = adapter(for: tool) else {
            report.notes.append("root missing or no adapter in this build")
            return report
        }
        let source = UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: tool, url: root).sourceID,
            realm: .production,
            tool: tool,
            rootPath: root.standardizedFileURL.path,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baselineCompletedAt: nil,
            isPaused: false,
            lastScanAt: nil,
            status: .collecting,
            lastReason: nil
        )
        let inspection = adapter.inspect(source: source)
        report.support = inspection.support.rawValue
        report.toolVersion = inspection.toolVersion
        report.formatVersion = inspection.formatVersion
        guard inspection.support.canScan else { return report }

        // One bounded slice, with the connection's baseline still open: this is
        // reading, not crediting.
        let request = UsageSliceRequest(
            source: source,
            budget: UsageScanBudget(maxFiles: 6, maxRecords: 20_000, maxBytes: 16 * 1024 * 1024, maxRows: 20_000),
            isBaselining: true,
            now: Date()
        )
        do {
            // First: the baseline pass, which fixes boundaries and remembers
            // counters. Then a traversal pass that reads the files from the
            // start, bounded by the budget, to prove actual records parse. That
            // second pass is written to a throwaway database here, never to a
            // wallet, which is why it is safe to traverse history.
            let baseline = try await adapter.scanSlice(request)
            let traversalCheckpoints = baseline.fileCheckpoints.map { checkpoint -> UsageFileCheckpoint in
                var moved = checkpoint
                moved.byteOffset = 0
                moved.baselineDone = true
                return moved
            }
            let traversal = UsageSliceRequest(
                source: source,
                fileCheckpoints: traversalCheckpoints,
                cursors: Dictionary(uniqueKeysWithValues: baseline.cursors.map { ($0.cursorKey, $0) }),
                budget: request.budget,
                isBaselining: true,
                now: Date()
            )
            let output = try await adapter.scanSlice(traversal)
            report.filesConsidered = output.counters.filesConsidered
            report.recordsSeen = output.counters.recordsSeen
            report.moreWork = output.moreWork
            for entry in output.entries {
                switch entry.status {
                case .accepted:
                    if let event = entry.event {
                        report.parsedEvents += 1
                        report.acceptedTokens += event.inputTokens + event.outputTokens
                    }
                case .excluded:
                    report.excludedEntries += 1
                case .unsupported, .conflict, .baseline:
                    report.unsupportedEntries += 1
                }
            }
            if let status = output.status {
                report.notes.append("status=\(status.rawValue) reason=\(output.statusReason ?? "-")")
            }
            if let skipped = output.skippedReason { report.notes.append("skipped=\(skipped)") }
        } catch {
            report.notes.append("scan failed: \(type(of: error))")
        }
        return report
    }

    @Test("설치된 실제 저장소에서 형식을 인식하고 레코드를 파싱한다")
    func probeRealStorages() async throws {
        guard Self.isEnabled else {
            print("SKIPPED: set PACKTRACE_REAL_USAGE_PROBE=1 to read the real storages")
            return
        }
        print("== real usage corpus probe (read-only) ==")
        for tool in [UsageToolKind.codex, .claudeCode, .openCode, .pi, .omo, .senpi, .hermes, .grok, .kimi] {
            let report = await Self.probe(tool)
            print(
                """
                [\(tool.rawValue)] root=\(report.rootExists ? "yes" : "no") support=\(report.support) \
                toolVersion=\(report.toolVersion ?? "-") format=\(report.formatVersion ?? "-")
                   files=\(report.filesConsidered) records=\(report.recordsSeen) \
                parsedEvents=\(report.parsedEvents) tokensIfNew=\(report.acceptedTokens) \
                excluded=\(report.excludedEntries) unsupported=\(report.unsupportedEntries) moreWork=\(report.moreWork)
                   notes=\(report.notes.isEmpty ? "-" : report.notes.joined(separator: " "))"
                """
            )
        }
    }

    /// The real profile's usage connections, read-only. Shows whether a tool is
    /// connected in the app the user actually runs, and what it has credited.
    @Test("실제 프로필의 연결 상태와 도구별 인정량")
    func realProfileState() throws {
        guard Self.isEnabled else { return }
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PackTrace/production/packtrace.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else {
            print("[profile] no production database yet")
            return
        }
        let db = try SQLiteDatabase(readOnlyPath: database.path)
        defer { db.close() }
        let sources = try db.query(
            """
            SELECT tool_kind, status, baseline_completed_at IS NOT NULL, paused, last_reason, root_path
            FROM usage_source ORDER BY tool_kind
            """
        ) { row in
            let path = row.optionalText(at: 5) ?? "-"
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let masked = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            return "tool=\(row.text(at: 0)) status=\(row.text(at: 1)) baseline=\(row.int(at: 2) == 1) "
                + "paused=\(row.int(at: 3) == 1) reason=\(row.optionalText(at: 4) ?? "-") path=\(masked)"
        }
        print("== real production profile (read-only) ==")
        if sources.isEmpty {
            print("  연결된 사용량 소스가 없습니다")
        }
        for source in sources { print("  \(source)") }
        let totals = try db.query(
            """
            SELECT s.tool_kind, SUM(CASE WHEN e.status = 'accepted' THEN e.accepted_tokens ELSE 0 END),
                   SUM(CASE WHEN e.status = 'accepted' THEN 1 ELSE 0 END)
            FROM usage_event e JOIN usage_source s ON s.source_id = e.source_id
            GROUP BY s.tool_kind ORDER BY s.tool_kind
            """
        ) { row in "\(row.text(at: 0)): \(row.int(at: 1)) 인정 토큰 · \(row.int(at: 2))건" }
        for total in totals { print("  \(total)") }
        let reward = try db.query("SELECT remainder_tokens, accepted_tokens, awarded_points FROM reward_state") { row in
            "나머지 \(row.int(at: 0)) · 누적 인정 \(row.int(at: 1)) · 누적 적립 P \(row.int(at: 2))"
        }
        for row in reward { print("  \(row)") }
    }

    /// The same storage read twice must not produce a second set of records:
    /// this is the property that keeps a rescan from paying twice.
    @Test("같은 실제 저장소를 다시 읽어도 같은 레코드만 나온다")
    func probeIsRepeatable() async throws {
        guard Self.isEnabled else { return }
        guard let adapter = Self.adapter(for: .codex), FileManager.default.fileExists(atPath: Self.root(for: .codex).path) else {
            return
        }
        let root = Self.root(for: .codex)
        let source = UsageSourceRecord(
            sourceID: UsageSourceIdentity(tool: .codex, url: root).sourceID,
            realm: .production,
            tool: .codex,
            rootPath: root.standardizedFileURL.path,
            connectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baselineCompletedAt: nil,
            isPaused: false,
            lastScanAt: nil,
            status: .collecting,
            lastReason: nil
        )
        let request = UsageSliceRequest(
            source: source,
            budget: UsageScanBudget(maxFiles: 4, maxRecords: 5_000, maxBytes: 8 * 1024 * 1024, maxRows: 5_000),
            isBaselining: true,
            now: Date()
        )
        let first = try await adapter.scanSlice(request)
        let second = try await adapter.scanSlice(request)
        #expect(first.counters.recordsSeen == second.counters.recordsSeen)
        #expect(first.entries.compactMap(\.event?.id) == second.entries.compactMap(\.event?.id))
    }
}
