import Foundation
import PackTraceTestSupport
@testable import PackTraceCore
import Testing

/// Opt-in migration probe for a database copy.
///
/// ```bash
/// PACKTRACE_MIGRATION_DB=/tmp/copy.sqlite ./scripts/test.sh --filter UsageMigrationProbeTests
/// ```
///
/// It opens the given database through the real `PackTraceStore` (so the real
/// migration runs), then prints only aggregate invariants — never card, pack or
/// log content. Used to prove that migrating a copy of the live database leaves
/// every recorded fact intact.
@Suite(
    "DB 업그레이드 프로브(옵트인)",
    .enabled(if: ProcessInfo.processInfo.environment["PACKTRACE_MIGRATION_DB"] != nil)
)
struct UsageMigrationProbeTests {
    @Test("사본 DB를 실제 코드로 열어 보존 상태를 확인한다")
    func openCopyAndReport() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["PACKTRACE_MIGRATION_DB"])
        let database = try SQLiteDatabase(path: path)
        let versionBefore = database.userVersion

        var events: [String: Int] = [:]
        for row in try database.query("SELECT status, COUNT(*) FROM usage_event GROUP BY status", [], map: { statement in
            (status: statement.text(at: 0), count: statement.int(at: 1))
        }) {
            events[row.status] = row.count
        }
        let totalEvents = try database.scalarInt("SELECT COUNT(*) FROM usage_event") ?? 0
        let duplicateOriginalCalls = try database.scalarInt(
            """
            SELECT COUNT(*) FROM (
                SELECT provider, response_id FROM usage_event GROUP BY provider, response_id HAVING COUNT(*) > 1
            )
            """
        ) ?? 0
        let remainderBefore = try database.scalarInt("SELECT remainder_tokens FROM reward_state") ?? 0
        let acceptedBefore = try database.scalarInt("SELECT accepted_tokens FROM reward_state") ?? 0
        let pointsBefore = try database.scalarInt("SELECT awarded_points FROM reward_state") ?? 0
        let ledgerBefore = try database.query("SELECT delta_points FROM wallet_entry", []) { $0.int(at: 0) }

        // Open through the store: this is where the migration runs.
        let location = StoreLocation(realm: .production, directory: URL(fileURLWithPath: path).deletingLastPathComponent())
        let store = try PackTraceStore(location: location, catalog: CatalogLoader.loadBundled())
        let totals = try await store.usageTotals()
        let ledger = try await store.ledger(limit: 1000)
        let diagnostics = try await store.usageDiagnostics()
        let checkpoints = try await store.usageCheckpoints()
        let versionAfter = try SQLiteDatabase(path: path).userVersion

        print("""
        [migrate] schema \(versionBefore) → \(versionAfter)
        [migrate] events total=\(totalEvents) byStatus=\(events.sorted { $0.key < $1.key })
        [migrate] baseline=\(diagnostics.baselineEvents) accepted=\(diagnostics.acceptedEvents) rejected(unsupported)=\(diagnostics.unsupportedEvents) excluded=\(diagnostics.excludedEvents)
        [migrate] acceptedTokens=\(totals.acceptedTokens) (was \(acceptedBefore)) remainder=\(totals.remainderTokens) (was \(remainderBefore)) points=\(totals.awardedPoints) (was \(pointsBefore))
        [migrate] ledger entries=\(ledger.count) (was \(ledgerBefore.count)) sum=\(ledger.reduce(0) { $0 + $1.deltaPoints }) (was \(ledgerBefore.reduce(0, +)))
        [migrate] checkpoints=\(checkpoints.count) baselined=\(checkpoints.filter(\.baselineDone).count)
        [migrate] duplicateOriginalCallPairs=\(duplicateOriginalCalls) aliases=\(diagnostics.aliasEvents) sessions=\(diagnostics.sessionsObserved)
        """)

        #expect(totals.acceptedTokens == acceptedBefore, "업그레이드가 인정 토큰을 바꾸면 안 됩니다")
        #expect(totals.remainderTokens == remainderBefore, "나머지가 바뀌면 안 됩니다")
        #expect(totals.awardedPoints == pointsBefore, "지급 포인트가 바뀌면 안 됩니다")
        #expect(ledger.reduce(0) { $0 + $1.deltaPoints } == ledgerBefore.reduce(0, +))
        #expect(totals.awardedPoints * UsageRewardRule.ompNonCacheV1.tokensPerPoint + totals.remainderTokens == totals.acceptedTokens)
        #expect(diagnostics.baselineEvents + diagnostics.acceptedEvents <= totalEvents)
        if duplicateOriginalCalls == 0 {
            #expect(versionAfter == Schema.currentVersion)
        }
    }
}
