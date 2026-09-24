import Foundation
import PackTraceCore

/// The OMP connection (its own collector) plus the shared reward account.
/// Built on the main actor from the store and the collector; contains no log
/// content.
///
/// Connection fields (`isConnected` … `requiresReconnect`, `lastScanAt`,
/// `lastError`) describe OMP alone. The token, point and diagnostic figures
/// come from the shared account and cover every tool. For collection as a
/// whole, read `UsageOverview`.
struct UsageStatusSnapshot: Equatable {
    var isConnected = false
    var status: UsageSourceStatus = .unconnected
    var rootDisplay = "-"
    /// Raw stored log path, so "reconnect" can reuse it without a new picker.
    var rootPath: String?
    var isPaused = false
    var baselineFilesTotal = 0
    var baselineFilesDone = 0
    var baselineComplete = false
    var lastScanAt: Date?
    var isScanning = false
    var pendingWork = false
    /// A restored profile keeps its log path but stays disconnected until the
    /// user connects again; the panel explains that instead of showing 오류.
    var requiresReconnect = false

    var todayAcceptedTokens = 0
    var todayAcceptedEvents = 0
    var todayAwardedPoints = 0
    /// Today's credited calls per tool, cache tokens kept apart.
    var todayByTool: [UsageToolDay] = []

    var totalAcceptedTokens = 0
    var remainderTokens = 0
    var awardedPoints = 0
    var acceptedEvents = 0
    var baselineEvents = 0
    var duplicateEvents = 0
    var excludedEvents = 0
    var unsupportedEvents = 0
    var conflictEvents = 0
    /// Event ids that mapped to an already recorded original call (fork/import).
    var aliasEvents = 0
    /// Observed sessions and how many declared a fork origin.
    var sessionsObserved = 0
    var sessionsWithParent = 0
    var filesTracked = 0
    var filesWithErrors = 0
    var rejectReasons: [UsageRejectionReason: Int] = [:]
    var lastError: String?

    /// Accepted tokens per tool. Duplicates are stored once, and each event
    /// belongs to exactly one source, so these sum to `totalAcceptedTokens`.
    var toolTotals: [UsageToolTotals] = []

    var ruleID = UsageRewardRule.ompNonCacheV1.ruleID
    var tokensPerPoint = UsageRewardRule.ompNonCacheV1.tokensPerPoint
    var packCostPoints = PackEconomy.v1.packCostPoints

    /// Accepted (non-cache input + output) tokens only. Cache reads are shown
    /// separately and are never part of this number.
    var tokensUntilNextPoint: Int {
        guard tokensPerPoint > 0 else { return 0 }
        let remainder = remainderTokens % tokensPerPoint
        return remainder == 0 ? tokensPerPoint : tokensPerPoint - remainder
    }

    var progressToNextPoint: Double {
        guard tokensPerPoint > 0 else { return 0 }
        return Double(remainderTokens % tokensPerPoint) / Double(tokensPerPoint)
    }

    /// OMP connection only.
    var ompStateLabel: String {
        if requiresReconnect { return "재연결 필요" }
        if !isConnected { return "미연결" }
        if isPaused { return "읽기 일시정지" }
        if status == .baselining || !baselineComplete {
            return "기준선 설정 중 (\(baselineFilesDone)/\(max(baselineFilesTotal, baselineFilesDone)))"
        }
        switch status {
        case .collecting: return isScanning ? "수집 중" : "수집 대기"
        case .rootMissing: return "로그 폴더 없음"
        case .permissionDenied: return "권한 오류"
        case .unsupportedFormat: return "형식 미지원"
        case .error: return "오류"
        case .paused: return "읽기 일시정지"
        case .baselining: return "기준선 설정 중"
        case .unconnected: return "미연결"
        }
    }

    /// OMP connection only. Distinguishes "nothing new" from "could not read".
    var ompSummaryLine: String {
        if requiresReconnect {
            return "복원된 데이터입니다. 재연결하면 지금 로그에 있는 기록은 기준선으로만 남고, 이후 새 사용량부터 적립됩니다."
        }
        if !isConnected { return "OMP는 연결하지 않았습니다. OMP를 쓴다면 로그 폴더를 연결하세요. 연결 뒤 사용량부터 적립됩니다." }
        if isPaused { return "읽기 일시정지 · 재개하면 미처리 사용량이 반영됩니다." }
        if let lastError { return "읽지 못했습니다: \(lastError)" }
        if status == .rootMissing || status == .permissionDenied { return "로그를 읽지 못했습니다." }
        if isScanning || pendingWork { return "확인 중…" }
        return "새 이벤트 없음 · 마지막 확인 \(lastScanAt?.packTraceDisplay ?? "-")"
    }
}
