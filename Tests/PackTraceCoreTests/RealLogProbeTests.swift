import Foundation
import PackTraceCore
import PackTraceTestSupport
import Testing

/// Opt-in smoke test against the developer's real OMP logs.
///
/// It only ever *reads* the approved log root and writes to a temporary
/// database, so it can prove the parser and collector work on real data without
/// touching the app's production wallet. Run it with:
///
/// ```bash
/// PACKTRACE_REAL_LOGS=1 ./scripts/test.sh --filter RealLogProbeTests
/// ```
///
/// Nothing about log content is printed: only counts, byte volumes and timings.
@Suite(
    "실제 로그 스모크(옵트인)",
    .enabled(if: ProcessInfo.processInfo.environment["PACKTRACE_REAL_LOGS"] != nil)
)
struct RealLogProbeTests {
    private var root: URL {
        if let explicit = ProcessInfo.processInfo.environment["PACKTRACE_REAL_LOGS"] {
            return URL(fileURLWithPath: explicit.isEmpty ? OMPLogRootDetector.candidates()[0].path : explicit)
        }
        return URL(fileURLWithPath: OMPLogRootDetector.candidates()[0].path)
    }

    @Test("실제 로그를 임시 DB로 기준선 처리하고 측정값을 남긴다")
    func baselineRealLogs() async throws {
        let location = try StoreLocation.temporary(realm: .production, label: "packtrace-real-probe")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let store = try PackTraceStore(location: location, catalog: CatalogLoader.loadBundled())
        let collector = OMPUsageCollector(store: store)

        let candidates = OMPLogRootDetector.candidates()
        print("[real] 감지된 후보: \(candidates.map { "\($0.origin)=\($0.sessionFileCount) files" })")

        let started = Date()
        var slices = 0
        var records = 0
        var bytes: Int64 = 0
        var busySlices = 0
        let source = try await collector.connect(root: root)
        let connectElapsed = Date().timeIntervalSince(started)
        while slices < 400 {
            let sliceStart = Date()
            let summary = try await collector.scan(trigger: .scheduled)
            slices += 1
            records += summary.recordsSeen
            bytes += summary.bytesRead
            if Date().timeIntervalSince(sliceStart) > 0.001 { busySlices += 1 }
            if !summary.moreWork { break }
        }
        let elapsed = Date().timeIntervalSince(started)
        let baselineAt = try await collector.status().source?.baselineCompletedAt
        print("[real] connect wall=\(String(format: "%.2f", connectElapsed))s)" )
        print("[real] connect→baselineComplete wall=\(baselineAt.map { String(format: "%.2f", $0.timeIntervalSince(started.addingTimeInterval(-connectElapsed))) } ?? "n/a")s")
        print("[real] baseline loop wall=\(String(format: "%.2f", elapsed - connectElapsed))s slices=\(slices) busy=\(busySlices) records=\(records) bytes=\(bytes)")

        let status = try await collector.status()
        let totals = status.totals
        let diagnostics = status.diagnostics
        print("""
        [real] root=\(OMPLogRootDetector.displayPath(source.rootPath))
        [real] slices=\(slices) elapsed=\(String(format: "%.2f", elapsed))s
        [real] files tracked=\(diagnostics.filesTracked) errors=\(diagnostics.filesWithErrors)
        [real] baselineComplete=\(status.isBaselineComplete) baselineEvents=\(diagnostics.baselineEvents)
        [real] acceptedEvents=\(diagnostics.acceptedEvents) unsupported=\(diagnostics.unsupportedEvents) excluded=\(diagnostics.excludedEvents)
        [real] acceptedTokens=\(totals.acceptedTokens) awardedPoints=\(totals.awardedPoints) remainder=\(totals.remainderTokens)
        [real] reject reasons=\(diagnostics.excludedByIdentity.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
        """)

        // A second pass must not re-read anything.
        let secondStart = Date()
        let second = try await collector.scan(trigger: .manual)
        let secondElapsed = Date().timeIntervalSince(secondStart)
        print("[real] second pass bytes=\(second.bytesRead) records=\(second.recordsSeen) elapsed=\(String(format: "%.3f", secondElapsed))s")
        #expect(second.bytesRead == 0, "증분 스캔은 다시 읽지 않아야 합니다")

        // No prompt, response or tool content may reach the database.
        let rows = try await store.usageRecentEvents(limit: 5)
        for row in rows {
            #expect(!row.model.isEmpty)
            #expect(row.inputTokens >= 0)
            #expect(row.sessionID.count > 10)
        }
        print("[real] 최근 이벤트 샘플: \(rows.map { "\($0.status.rawValue)/\($0.acceptedTokens)tok/\($0.model)" })")
    }
}
