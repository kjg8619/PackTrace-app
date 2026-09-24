import AppKit
import PackTraceCore
import SwiftUI

/// Minimal AppKit use: a folder picker. Everything else stays SwiftUI.
enum FolderPicker {
    @MainActor
    static func chooseDirectory(message: String, prompt: String, startingAt: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = message
        panel.prompt = prompt
        if let startingAt {
            panel.directoryURL = startingAt
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct ProfileSection: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "지갑 프로필",
                    subtitle: "개발용 지갑과 실사용 지갑은 서로 다른 데이터베이스입니다."
                )
                HStack(spacing: 10) {
                    ForEach(Realm.allCases, id: \.self) { realm in
                        Button {
                            Task { await environment.switchProfile(to: realm) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: environment.profile == realm ? "largecircle.fill.circle" : "circle")
                                Text(realm.displayName)
                                    .font(.system(size: 12, weight: environment.profile == realm ? .semibold : .regular))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(environment.profile == realm ? Palette.ink : Palette.inkMuted)
                        .disabled(!environment.canSwitchProfile && environment.profile != realm)
                    }
                    Spacer(minLength: 0)
                    BadgeView(
                        text: environment.profile == .demo ? "개발용 지갑 · demo" : "실사용 지갑 · production",
                        color: environment.profile == .demo ? Palette.demoBadge : Palette.success
                    )
                }
                Text("실사용은 0 P부터 시작하며 기존 데모 수집품은 데모에 보관됩니다. AI 사용량 적립은 도구와 관계없이 실사용 지갑에만 들어갑니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                if !environment.canSwitchProfile {
                    Text("진행 중인 작업이 끝나면 전환할 수 있습니다.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accentWarm)
                }
            }
        }
    }
}

/// Pauses every connected source, or resumes them when all are paused. One
/// source at a time is paused in Settings.
struct UsagePauseAllButton: View {
    @EnvironmentObject private var environment: AppEnvironment
    let overview: UsageOverview

    var body: some View {
        if overview.canPause {
            Button("수집 일시정지") {
                Task { await environment.pauseAllUsage() }
            }
            .controlSize(.small)
            .help("연결한 모든 도구의 읽기를 멈춥니다")
        } else if overview.canResume {
            Button("수집 재개") {
                Task { await environment.resumeAllUsage() }
            }
            .controlSize(.small)
            .disabled(environment.usage.isScanning)
            .help("일시정지한 모든 도구를 다시 읽습니다")
        }
    }
}

/// Collection as a whole: every connected tool's state, the rules they share
/// and the shared account's diagnostics. Each tool's own connection follows.
struct UsageOverviewSection: View {
    @EnvironmentObject private var environment: AppEnvironment

    private var usage: UsageStatusSnapshot { environment.usage }

    var body: some View {
        let overview = environment.usageOverview
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(
                    title: "AI 사용량 수집",
                    subtitle: "연결한 AI 도구의 확정 사용량을 하나의 실사용 지갑에 합산합니다. 도구 하나만 연결해도 됩니다. 공식 청구 금액이 아닙니다."
                )

                HStack(spacing: 8) {
                    BadgeView(text: overview.stateLabel, color: overview.tone.color)
                    if usage.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                if !overview.sources.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(overview.sources) { source in
                            BadgeView(text: "\(source.tool.displayName) · \(source.state.label)", color: source.state.tone.color)
                        }
                    }
                }

                Text(overview.summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(overview.tone == .attention ? Palette.danger : Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if overview.hasConnection {
                    HStack(spacing: 8) {
                        Button("지금 새로고침") {
                            Task { await environment.refreshUsageNow() }
                        }
                        .controlSize(.small)
                        .disabled(!environment.hasCollectableSource || usage.isScanning)
                        UsagePauseAllButton(overview: overview)
                        Spacer(minLength: 0)
                    }
                }

                Divider().overlay(Palette.hairline)

                DetailsDisclosure(title: "적립 규칙 (모든 도구 공통)") {
                    Text("""
                    · 인정 토큰: 비캐시 입력 + 출력 · 캐시 읽기/쓰기는 제외하고 따로 표시
                    · 환산: \(usage.tokensPerPoint.formatted()) 인정 토큰 = 1 P (규칙 \(usage.ruleID)) · 도구별 포인트를 따로 만들지 않음
                    · 연결 시점에 이미 있던 기록은 기준선이며 소급 지급하지 않음 · 연결 뒤 사용량부터 적립
                    · 같은 원본 호출은 한 번만 인정
                    · 저장하는 것: 세션·응답 식별자, 모델·provider, 종료 사유, 시각, 토큰 수, 처리 상태
                    · 저장하지 않는 것: 프롬프트·응답 본문, thinking, 도구 인자·결과, cwd, 인증정보 · 원본 로그·DB는 읽기만 함
                    """)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                }

                DetailsDisclosure(title: "상태·진단 (모든 도구 합계)") {
                    ruleRow("마지막 확인", overview.lastScanAt?.packTraceDisplay ?? "-")
                    ruleRow("인정 이벤트", "\(usage.acceptedEvents)건 · 기준선 \(usage.baselineEvents)건")
                    ruleRow("중복/제외/미지원", "\(usage.duplicateEvents) / \(usage.excludedEvents) / \(usage.unsupportedEvents)건")
                    ruleRow("충돌", "\(usage.conflictEvents)건")
                    ruleRow("추적 파일", "\(usage.filesTracked)개 · 오류 \(usage.filesWithErrors)개")
                    ruleRow("관찰 세션", "\(usage.sessionsObserved)개 · fork 출처 표시 \(usage.sessionsWithParent)개")
                    ruleRow("상속 중복", "\(usage.aliasEvents)건 (다른 세션에 이미 기록된 원본 호출)")
                    ruleRow("인정 토큰 누적", "\(usage.totalAcceptedTokens.formatted()) · 나머지 \(usage.remainderTokens.formatted())")
                    ruleRow("적립 누적", "\(usage.awardedPoints) P")
                    if !usage.rejectReasons.isEmpty {
                        ruleRow(
                            "제외 사유",
                            usage.rejectReasons
                                .sorted { $0.value > $1.value }
                                .prefix(4)
                                .map { "\($0.key.displayName) \($0.value)" }
                                .joined(separator: " · ")
                        )
                    }
                }

                if !environment.usageEvents.isEmpty {
                    DetailsDisclosure(title: "최근 인정 기록 \(environment.usageEvents.count)건") {
                        Text("모든 도구 · 본문 없이 수치와 식별자만 표시합니다.")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                        ForEach(environment.usageEvents) { event in
                            HStack(spacing: 8) {
                                Text(event.occurredAt.packTraceDisplay)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Palette.inkMuted)
                                Text(event.model)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(1)
                                BadgeView(text: event.status.displayName, color: Palette.accent)
                                Spacer(minLength: 0)
                                Text("인정 \(event.acceptedTokens.formatted())")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Palette.ink)
                                Text("캐시 \(event.cacheReadTokens.formatted())")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.inkMuted)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Every AI tool in one list, in the tools' usual order. OMP is a row like
/// the others; only its way of connecting differs (it reads a log folder the
/// user picks, the others a storage path detected on this Mac).
struct AIToolsSection: View {
    @EnvironmentObject private var environment: AppEnvironment

    private var usage: UsageStatusSnapshot { environment.usage }

    /// Tools read through the coordinator; OMP is drawn from its collector.
    private var adapterStatuses: [UsageCoordinator.SourceStatus] {
        environment.toolStatuses
            .filter { $0.source.tool != .omp }
            .sorted { ($0.source.tool.order, $0.source.rootPath) < ($1.source.tool.order, $1.source.rootPath) }
    }

    /// Detected folders not connected yet, OMP's log folders first.
    private var ompCandidates: [OMPLogRootCandidate] {
        environment.usageCandidates.filter { $0.path != usage.rootPath }
    }

    private var toolCandidates: [UsageSourceCandidate] {
        environment.toolCandidates.filter { candidate in
            environment.toolStatuses.allSatisfy { $0.source.rootPath != candidate.identity.canonicalPath }
        }
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "AI 도구",
                    subtitle: "OMP · Codex · Claude Code · OpenCode · pi · omo · senpi · Hermes · Grok · Kimi. 쓰는 도구만 연결합니다. 각 도구의 기록을 읽기만 하고 하나의 실사용 지갑에 합산합니다. 연결 시점의 기존 기록은 기준선이며 소급 지급하지 않습니다. 로컬·테스트 모델은 적립하지 않습니다."
                )
                ompRow
                Divider().overlay(Palette.hairline)
                ForEach(adapterStatuses) { status in
                    toolRow(status)
                    Divider().overlay(Palette.hairline)
                }
                if let error = environment.toolScanError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.demoBadge)
                }
                candidates
                Text("자동 감지는 후보만 보여줍니다. 연결하기 전에는 어떤 기록도 적립하지 않습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The folders are listed when this screen is shown, not on every usage
        // refresh (which happens several times per scan).
        .task { environment.refreshUsageCandidates() }
    }

    // MARK: - Rows

    private func header(_ name: String, @ViewBuilder badges: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
            badges()
            Spacer(minLength: 0)
        }
    }

    private func detail(_ text: String, color: Color = Palette.inkMuted, monospaced: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, design: monospaced ? .monospaced : .default))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var ompRow: some View {
        let totals = usage.toolTotals.first { $0.tool == .omp }
        return VStack(alignment: .leading, spacing: 3) {
            header(UsageToolKind.omp.displayName) {
                BadgeView(text: usage.ompStateLabel, color: ompStateColor)
                BadgeView(text: "로그 폴더", color: Palette.inkMuted)
                if usage.isPaused {
                    BadgeView(text: "일시정지", color: Palette.demoBadge)
                }
            }
            detail(usage.rootPath == nil ? "로그 폴더 미연결" : usage.rootDisplay, monospaced: usage.rootPath != nil)
            if usage.isConnected, !usage.baselineComplete {
                ProgressView(value: Double(usage.baselineFilesDone), total: Double(max(usage.baselineFilesTotal, 1)))
                detail("기준선 설정 중 \(usage.baselineFilesDone)/\(usage.baselineFilesTotal) · 연결 이전 기록은 적립하지 않습니다.")
            }
            detail(usage.ompSummaryLine, color: usage.lastError == nil ? Palette.inkMuted : Palette.danger)
            if let totals {
                detail("인정 토큰 \(totals.acceptedTokens) · 인정 호출 \(totals.acceptedEvents)")
            }
            HStack(spacing: 8) {
                if usage.requiresReconnect {
                    Button("다시 연결") {
                        guard let path = usage.rootPath else { return }
                        Task { await environment.connectUsage(root: URL(fileURLWithPath: path)) }
                    }
                    .controlSize(.small)
                    .disabled(usage.isScanning)
                }
                if usage.isConnected {
                    Button(usage.isPaused ? "재개" : "일시정지") {
                        Task {
                            if usage.isPaused {
                                await environment.resumeUsage()
                            } else {
                                await environment.pauseUsage()
                            }
                        }
                    }
                    .controlSize(.small)
                }
                Button(usage.rootPath == nil ? "로그 폴더 선택…" : "다른 로그 폴더…") {
                    let selected = FolderPicker.chooseDirectory(
                        message: "OMP 세션 로그 폴더를 선택하세요 (기본: ~/.omp/agent/sessions)",
                        prompt: "연결",
                        startingAt: nil
                    )
                    if let selected {
                        Task { await environment.connectUsage(root: selected) }
                    }
                }
                .controlSize(.small)
            }
            DetailsDisclosure(title: "OMP에서 읽는 항목") {
                Text("""
                · 적립 대상: 모델 서비스(commandcode·openai-codex·openrouter 등) 메인 세션의 확정 assistant usage
                · 제외: 로컬·테스트 모델(lm-studio·ollama·omlx·faux 등)
                · 제외: 서브에이전트 로그, 오류·중단으로 끝난 호출, provider가 없는 기록, 형식이 다른 로그 버전
                · fork/가져오기: 같은 원본 호출(provider+응답 ID)은 한 번만 인정하고, 연결 이전 시각의 상속 기록은 적립하지 않습니다
                · 레코드 상한: 한 줄 8 MiB까지 파싱하고, 초과분은 원문 없이 사유만 기록합니다
                · 마지막 확인: \(usage.lastScanAt?.packTraceDisplay ?? "-")
                """)
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func toolRow(_ status: UsageCoordinator.SourceStatus) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(status.source.tool.displayName) {
                BadgeView(text: status.source.status.displayName, color: status.source.status == .collecting ? Palette.accent : Palette.inkMuted)
                BadgeView(text: status.inspection.support.displayName, color: status.inspection.support.canScan ? Palette.accent : Palette.demoBadge)
                if status.source.isPaused {
                    BadgeView(text: "일시정지", color: Palette.demoBadge)
                }
            }
            detail(UsageSourceIdentity.mask(status.source.rootPath), monospaced: true)
            detail("\(status.inspection.detail) · 형식 \(status.inspection.formatVersion ?? "-") · 도구 버전 \(status.inspection.toolVersion ?? "미확인")")
            detail("인정 토큰 \(status.acceptedTokens) · 인정 호출 \(status.acceptedEvents) · \(status.source.baselineCompletedAt == nil ? "기준선 설정 중" : "기준선 완료")")
            if let reason = status.source.lastReason {
                detail("사유: \(reason)", color: Palette.demoBadge)
            }
            HStack(spacing: 8) {
                if status.source.status == .unconnected {
                    Button("연결") {
                        Task { await environment.connectTool(status.source.tool, rootPath: status.source.rootPath) }
                    }
                    .controlSize(.small)
                } else {
                    Button(status.source.isPaused ? "재개" : "일시정지") {
                        Task { await environment.setToolPaused(!status.source.isPaused, sourceID: status.source.sourceID) }
                    }
                    .controlSize(.small)
                    Button("연결 해제") {
                        Task { await environment.disconnectTool(sourceID: status.source.sourceID) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Detected, not connected

    @ViewBuilder
    private var candidates: some View {
        if !ompCandidates.isEmpty || !toolCandidates.isEmpty {
            Text("감지된 후보")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.ink)
            ForEach(ompCandidates, id: \.path) { candidate in
                candidateRow(
                    tool: .omp,
                    path: OMPLogRootDetector.displayPath(candidate.path),
                    note: "\(candidate.origin) · 세션 파일 \(candidate.sessionFileCount)개" + (candidate.isReadable ? "" : " · 읽을 수 없음"),
                    canConnect: candidate.exists && candidate.isReadable
                ) {
                    Task { await environment.connectUsage(root: URL(fileURLWithPath: candidate.path)) }
                }
            }
            ForEach(toolCandidates) { candidate in
                candidateRow(tool: candidate.identity.tool, path: candidate.maskedPath, note: nil, canConnect: candidate.exists) {
                    Task { await environment.connectTool(candidate.identity.tool, rootPath: candidate.identity.canonicalPath) }
                }
            }
        }
    }

    private func candidateRow(tool: UsageToolKind, path: String, note: String?, canConnect: Bool, connect: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(tool.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            Spacer(minLength: 0)
            if canConnect {
                Button("연결", action: connect)
                    .controlSize(.small)
            } else {
                Text("없음")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
        }
    }

    private var ompStateColor: Color {
        switch usage.status {
        case .collecting: Palette.success
        case .baselining: Palette.accent
        case .paused: Palette.accentWarm
        case .unconnected: Palette.inkMuted
        case .rootMissing, .permissionDenied, .unsupportedFormat, .error: Palette.danger
        }
    }
}

/// One label/value line in the usage sections.
@MainActor
private func ruleRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(Palette.inkMuted)
            .frame(width: 118, alignment: .leading)
        Text(value)
            .font(.system(size: 11))
            .foregroundStyle(Palette.ink)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
    }
}
