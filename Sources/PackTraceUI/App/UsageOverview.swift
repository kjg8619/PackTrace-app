import Foundation
import PackTraceCore
import SwiftUI

/// Collection across every connected tool, for the places that summarise usage
/// (Today, the menu bar, the top of Settings). OMP is one of the tools here.
///
/// `UsageStatusSnapshot` describes the OMP connection, which has its own
/// collector; the other tools come from the coordinator. Built from both on
/// demand, so it never lags behind whichever of the two refreshed last.
struct UsageOverview: Equatable {
    enum SourceState: Equatable {
        case collecting
        case baselining
        case paused
        /// Disconnected by a restore: nothing is read until it is connected again.
        case needsReconnect
        case failing(UsageSourceStatus)

        var label: String {
            switch self {
            // "연결됨", not "수집 중": whether a scan is running right now is
            // the overall label's job.
            case .collecting: "연결됨"
            case .baselining: "기준선 설정 중"
            case .paused: "일시정지"
            case .needsReconnect: "재연결 필요"
            case let .failing(status): status.displayName
            }
        }

        /// Reads on the next scan.
        var isActive: Bool { self == .collecting || self == .baselining }

        var tone: Tone {
            switch self {
            case .collecting: .active
            case .baselining: .baselining
            case .paused: .paused
            case .needsReconnect, .failing: .attention
            }
        }
    }

    struct Source: Equatable, Identifiable {
        var id: String
        var tool: UsageToolKind
        var state: SourceState
        var lastScanAt: Date?
    }

    enum Tone: Equatable {
        case idle, active, baselining, paused, attention

        var color: Color {
            switch self {
            case .idle: Palette.inkMuted
            case .active: Palette.success
            case .baselining: Palette.accent
            case .paused: Palette.accentWarm
            case .attention: Palette.danger
            }
        }
    }

    var sources: [Source] = []
    var isScanning = false
    var pendingWork = false

    static func make(omp: UsageStatusSnapshot, tools: [UsageCoordinator.SourceStatus]) -> UsageOverview {
        var sources: [Source] = []
        if let state = ompState(omp) {
            sources.append(Source(id: UsageToolKind.omp.rawValue, tool: .omp, state: state, lastScanAt: omp.lastScanAt))
        }
        for status in tools where status.source.tool != .omp {
            guard let state = toolState(status.source) else { continue }
            sources.append(Source(id: status.source.sourceID, tool: status.source.tool, state: state, lastScanAt: status.source.lastScanAt))
        }
        sources.sort { ($0.tool.order, $0.id) < ($1.tool.order, $1.id) }
        return UsageOverview(
            sources: sources,
            isScanning: omp.isScanning,
            pendingWork: omp.pendingWork || tools.contains { $0.pendingWork }
        )
    }

    private static let failingStatuses: Set<UsageSourceStatus> = [.rootMissing, .permissionDenied, .unsupportedFormat, .error]

    private static func ompState(_ omp: UsageStatusSnapshot) -> SourceState? {
        if omp.requiresReconnect { return .needsReconnect }
        guard omp.isConnected else { return nil }
        if omp.isPaused { return .paused }
        if failingStatuses.contains(omp.status) { return .failing(omp.status) }
        if omp.status == .baselining || !omp.baselineComplete { return .baselining }
        return .collecting
    }

    private static func toolState(_ source: UsageSourceRecord) -> SourceState? {
        if source.status == .unconnected {
            // A restore disconnects every source with this reason; one the user
            // disconnected is simply not part of collection any more.
            return source.lastReason == OMPUsageCollector.restoreReconnectReason ? .needsReconnect : nil
        }
        if source.isPaused { return .paused }
        if failingStatuses.contains(source.status) { return .failing(source.status) }
        if source.status == .baselining || source.baselineCompletedAt == nil { return .baselining }
        return .collecting
    }

    var failing: [Source] {
        sources.filter { if case .failing = $0.state { true } else { false } }
    }

    var activeCount: Int { sources.filter(\.state.isActive).count }
    var pausedCount: Int { sources.filter { $0.state == .paused }.count }
    var needsReconnectCount: Int { sources.filter { $0.state == .needsReconnect }.count }
    var baselining: [Source] { sources.filter { $0.state == .baselining } }

    /// Something is connected, whatever its state.
    var hasConnection: Bool { sources.contains { $0.state != .needsReconnect } }
    /// "Pause collection" has something to pause (a failing source is still
    /// retried on every scan, so it counts).
    var canPause: Bool { sources.contains { $0.state != .paused && $0.state != .needsReconnect } }
    var canResume: Bool { pausedCount > 0 }

    var lastScanAt: Date? { sources.compactMap(\.lastScanAt).max() }

    var stateLabel: String {
        if sources.isEmpty { return "미연결" }
        if !failing.isEmpty { return "확인 필요 \(failing.count)" }
        if activeCount == 0 { return pausedCount > 0 ? "읽기 일시정지" : "재연결 필요" }
        if !baselining.isEmpty { return "기준선 설정 중" }
        return isScanning ? "수집 중" : "수집 대기"
    }

    var tone: Tone {
        if sources.isEmpty { return .idle }
        if !failing.isEmpty { return .attention }
        if activeCount == 0 { return pausedCount > 0 ? .paused : .attention }
        if !baselining.isEmpty { return .baselining }
        return .active
    }

    /// Distinguishes "nothing connected", "could not read" and "nothing new".
    var summaryLine: String {
        if sources.isEmpty {
            return "연결한 도구가 없습니다. 설정 > AI 사용량에서 쓰는 AI 도구를 연결하면 그 뒤 사용량부터 적립됩니다."
        }
        if let first = failing.first {
            let others = failing.count > 1 ? " 외 \(failing.count - 1)개" : ""
            return "\(first.tool.displayName)\(others)를 읽지 못했습니다: \(first.state.label). 설정에서 확인하세요."
        }
        if activeCount == 0 {
            if pausedCount > 0 {
                return "모든 도구 읽기 일시정지 · 재개하면 미처리 사용량이 반영됩니다."
            }
            return "복원된 데이터입니다. 설정에서 도구를 다시 연결하면 지금 기록은 기준선으로만 남고, 이후 새 사용량부터 적립됩니다."
        }
        if isScanning || pendingWork { return "확인 중…" }
        var line = "\(activeCount)개 도구에서 수집 · 마지막 확인 \(lastScanAt?.packTraceDisplay ?? "-")"
        if pausedCount > 0 { line += " · \(pausedCount)개 일시정지" }
        if needsReconnectCount > 0 { line += " · \(needsReconnectCount)개 재연결 필요" }
        return line
    }
}
