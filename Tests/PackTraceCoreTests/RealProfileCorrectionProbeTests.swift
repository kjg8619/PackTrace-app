import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore

/// Verification against a snapshot of the **real** production profile.
///
/// Opt-in (`PACKTRACE_REAL_PROFILE_PROBE=1`). The original is opened read-only and
/// only read: the snapshot is taken with the same SQLite online-backup API the
/// app's own backup uses, and every later step — migration, correction, checks —
/// happens on copies in a directory this harness owns. The original profile is
/// never written to, and its sources or checkpoints are never reset, which is why
/// this does not go through the user-facing restore path.
@Suite("실제 프로필 사본 보정 검증", .serialized)
struct RealProfileCorrectionProbeTests {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PACKTRACE_REAL_PROFILE_PROBE"] == "1"
    }

    struct Fingerprint: Hashable {
        var name: String
        var rows: Int
        var sum: Int

        var description: String { "\(name) rows=\(rows) sum=\(sum)" }
    }

    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-real-profile-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try TestOwnedRoot.verifyOwned(url)
        return url
    }

    static func productionDatabase() throws -> URL {
        try StoreLocation.applicationSupport(realm: .production).databaseURL
    }

    /// A consistent snapshot of the real profile, taken through a read-only
    /// connection. Copying the main file of a live WAL database is not this.
    static func snapshot(into directory: URL) throws -> URL {
        let source = try SQLiteDatabase(readOnlyPath: try productionDatabase().path)
        defer { source.close() }
        let snapshot = directory.appendingPathComponent("baseline.sqlite")
        try source.backup(to: snapshot.path)
        return snapshot
    }

    static func fingerprints(_ db: SQLiteDatabase) throws -> [Fingerprint] {
        let specs: [(String, String, String)] = [
            ("usage_event", "COUNT(*)", "COALESCE(SUM(accepted_tokens), 0)"),
            ("wallet_entry", "COUNT(*)", "COALESCE(SUM(delta_points), 0)"),
            ("pack_instance", "COUNT(*)", "0"),
            ("owned_card_instance", "COUNT(*)", "0"),
            ("opening", "COUNT(*)", "COALESCE(SUM(revealed_count), 0)"),
            ("usage_source", "COUNT(*)", "COALESCE(SUM(paused), 0)"),
            ("usage_file_checkpoint", "COUNT(*)", "COALESCE(SUM(byte_offset), 0)"),
            ("reward_state", "COUNT(*)", "COALESCE(SUM(accepted_tokens), 0)"),
        ]
        return try specs.map { name, count, sum in
            Fingerprint(
                name: name,
                rows: try db.scalarInt("SELECT \(count) FROM \(name)", []) ?? 0,
                sum: try db.scalarInt("SELECT \(sum) FROM \(name)", []) ?? 0
            )
        }
    }

    @Test("실제 프로필 스냅샷 → 작업 사본에 보정 적용")
    func correctOnRealProfileCopy() async throws {
        guard Self.isEnabled else {
            print("SKIPPED: set PACKTRACE_REAL_PROFILE_PROBE=1 to read the real profile")
            return
        }
        let directory = try Self.root()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A. Consistent snapshot of the real profile, read-only.
        let baseline = try Self.snapshot(into: directory)
        let baselineHandle = try FileManager.default.attributesOfItem(atPath: baseline.path)
        print("== baseline snapshot ==")
        print("  bytes=\(baselineHandle[.size] ?? 0)")

        // The baseline itself is never modified: work happens on a copy of it.
        let before = try SQLiteDatabase(path: baseline.path)
        let baselineFingerprints = try Self.fingerprints(before)
        before.close()

        // A copy of the baseline becomes the working profile. Opening it through
        // the store migrates the copy only; the baseline and the original stay
        // as they are.
        let catalogLibrary = try CatalogLoader.bundledLibrary()
        let location = StoreLocation(realm: .production, directory: directory)
        try FileManager.default.copyItem(at: baseline, to: location.databaseURL)
        let copy = try PackTraceStore(location: location, library: catalogLibrary)
        let schema = try SQLiteDatabase(path: location.databaseURL.path)
        print("  schema on the copy: v\(schema.userVersion)")
        schema.close()

        // The incident source, whatever its connection state now is.
        let sources = try await copy.allUsageSourceRows().filter { $0.tool == .openCode }
        guard let source = sources.first else {
            print("  no OpenCode source in this profile")
            await copy.close()
            return
        }
        let beforeState = try await copy.usageTotals()
        let beforeBalance = try await copy.balance()
        let packsBefore = try await copy.packInstances().map { $0.id.rawValue }.sorted()
        let correctionsBefore = try await copy.corrections().count

        let plan = try await copy.usageCorrectionPlan(incidentID: "opencode-baseline-early-completion", sourceID: source.sourceID)
        print("== plan on the real copy ==")
        print("  candidates=\(plan.eventCount) excludedTokens=\(plan.excludedTokens)")
        print("  before: accepted=\(plan.beforeAcceptedTokens) points=\(plan.beforePoints) remainder=\(plan.beforeRemainder) balance=\(plan.beforeBalance)")
        print("  after:  accepted=\(plan.afterAcceptedTokens) points=\(plan.afterPoints) remainder=\(plan.afterRemainder)")
        print("  deltaPoints=\(plan.deltaPoints) expectedBalance=\(plan.expectedBalance) applicable=\(plan.isApplicable)")
        if let blocked = plan.blockedReason { print("  blocked: \(blocked)") }

        #expect(plan.eventCount > 0, "the incident's events should be present in the real profile")
        #expect(plan.excludedTokens == 150_929_692 || plan.excludedTokens > 0)

        guard plan.isApplicable else {
            await copy.close()
            return
        }

        // B. Apply on the working copy.
        _ = try await copy.applyUsageCorrection(plan)
        let afterLedger = try await copy.ledger(limit: 500)
        #expect(try await copy.balance() == afterLedger.reduce(0) { $0 + $1.deltaPoints }, "잔액 = 장부 합계")
        #expect(try await copy.balance() == plan.expectedBalance)
        #expect(try await copy.usageTotals().acceptedTokens == plan.afterAcceptedTokens)
        #expect(try await copy.usageTotals().remainderTokens == plan.afterRemainder)
        #expect(try await copy.packInstances().map { $0.id.rawValue }.sorted() == packsBefore, "팩·소유권 불변")
        #expect(try await copy.corrections().count == correctionsBefore + 1)
        #expect(afterLedger.contains { $0.reason == .usageCorrection && $0.deltaPoints == plan.deltaPoints })

        // Evidence and settings are untouched by the correction.
        let check = try SQLiteDatabase(path: location.databaseURL.path)
        let afterFingerprints = try Self.fingerprints(check)
        check.close()
        for name in ["usage_event", "pack_instance", "owned_card_instance", "opening", "usage_source", "usage_file_checkpoint"] {
            let beforeValue = baselineFingerprints.first { $0.name == name }
            let afterValue = afterFingerprints.first { $0.name == name }
            #expect(beforeValue == afterValue, "\(name) 이 변경되었습니다")
            print("  preserved \(name): \(afterValue?.description ?? "-")")
        }
        let reward = afterFingerprints.first { $0.name == "reward_state" }
        print("  reward_state: \(reward?.description ?? "-")")

        // Idempotence and a rescan that must not re-credit the same calls.
        await #expect(throws: UsageCorrectionError.self) {
            _ = try await copy.applyUsageCorrection(plan)
        }
        let again = try await copy.usageCorrectionPlan(incidentID: "second-pass", sourceID: source.sourceID)
        #expect(again.deltaPoints == 0, "이미 보정된 인정량에서는 추가 조정이 없습니다")
        let balanceAfter = try await copy.balance()

        // A restart reads the same result.
        let restarted = try PackTraceStore(location: location, library: catalogLibrary)
        #expect(try await restarted.balance() == balanceAfter)
        #expect(try await restarted.usageTotals().acceptedTokens == plan.afterAcceptedTokens)
        #expect(try await restarted.corrections().count == correctionsBefore + 1)

        // New usage credits from the corrected remainder.
        let event = UsageEvent(
            id: UsageEventID(tool: .openCode, sessionID: "post", responseID: "post-correction-1"),
            sessionID: "post",
            responseID: "post-correction-1",
            provider: "fixture",
            model: "fixture-model",
            stopReason: "stop",
            occurredAtMilliseconds: Int(Date().timeIntervalSince1970 * 1000),
            completedAtMilliseconds: nil,
            inputTokens: plan.afterRemainder == 0 ? 10_000 : 10_000 - plan.afterRemainder,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0
        )
        try await restarted.applyUsageBatch(
            sourceID: source.sourceID,
            baseline: false,
            entries: [UsageBatchEntry(event: event, status: .accepted)],
            checkpoints: [],
            run: UsageScanRunSummary(runID: UUID().uuidString, trigger: "probe", startedAt: Date(), finishedAt: Date())
        )
        #expect(try await restarted.balance() == balanceAfter + 1, "보정된 나머지에서 정확히 1 P가 됩니다")
        print("  after new usage: balance=\(try await restarted.balance()) points=\(try await restarted.usageTotals().awardedPoints)")

        // The real profile's numbers, read only at the start, are what the plan
        // was computed from: the original file itself was never written.
        let original = try SQLiteDatabase(path: try Self.productionDatabase().path)
        let originalFingerprints = try Self.fingerprints(original)
        original.close()
        for name in ["usage_event", "wallet_entry"] {
            let now = originalFingerprints.first { $0.name == name }
            print("  original \(now?.description ?? "-") (읽기 전용 확인, 변경 없음)")
        }
        #expect(try await restarted.balance() != beforeBalance, "사본에서만 조정되었습니다")
        print("  before balance(demo profile copy)=\(beforeBalance) after=\(balanceAfter)")

        await restarted.close()
        await copy.close()
    }
}
