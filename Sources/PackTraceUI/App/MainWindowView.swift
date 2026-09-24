import AppKit
import PackTraceCore
import SwiftUI

public enum AppWindow {
    public static let main = "packtrace.main"
}

/// Shows the collection window and puts it in front.
///
/// `openWindow(id:)` alone only *creates* a window: when it already exists
/// behind another app, the click looks like it did nothing. Activating the app
/// and ordering the window front is what the menu bar is expected to do.
@MainActor
public enum MainWindowPresenter {
    public static func show(openWindow: OpenWindowAction) {
        openWindow(id: AppWindow.main)
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        raise()
        // The scene may create its window a moment later, so try again once the
        // window has had a chance to exist.
        DispatchQueue.main.async { raise() }
    }

    private static func raise() {
        mainWindow()?.makeKeyAndOrderFront(nil)
    }

    /// The window of the `AppWindow.main` scene. Falls back to the titled window
    /// for builds where the identifier has not been attached yet.
    ///
    /// `NSApplication.shared` rather than the `NSApp` global so this cannot trap
    /// when no application object exists yet (tests, early launch).
    private static func mainWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows
        let identified = windows.first { $0.identifier?.rawValue == AppWindow.main }
        if let identified { return identified }
        return windows.first { $0.title == "PackTrace" && $0.canBecomeMain }
    }
}

/// Tags the hosting window with the scene id so `MainWindowPresenter` can find
/// it without guessing from titles.
public struct MainWindowTag: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(AppWindow.main)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.identifier = NSUserInterfaceItemIdentifier(AppWindow.main)
    }
}

public struct MainWindowView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    public init() {}

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Palette.hairline)
            content
        }
        .background(Palette.backdrop)
        .task { await environment.bootstrap() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await environment.applicationDidBecomeActive() }
        }
        .sheet(item: $environment.receivedPack) { pack in
            ReceivedPackSheet(pack: pack)
                .environmentObject(environment)
                .environmentObject(environment.settings)
        }
        .sheet(item: $environment.openingPreview) { result in
            // The development preview always animates: it exists to look at the
            // motion, so the user's "빠르게 열기"/모션 줄이기 setting does not apply here.
            PackOpeningScene(source: .preview(result), skipsAnimations: false)
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .frame(width: 780, height: 660)
        }
        .sheet(item: $environment.openingRequest) { request in
            PackOpeningScene(
                source: .stored(request.pack),
                skipsAnimations: environment.settings.skipsAnimations(systemReduceMotion: systemReduceMotion)
            )
            .environmentObject(environment)
            .environmentObject(environment.settings)
            // Fixed size: without it the sheet lays its content out at the
            // parent window's width, which pushes the pack off centre.
            .frame(width: 780, height: 660)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PackTrace")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text("AI 작업 기록 → 카드 수집")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(.bottom, 10)

            ForEach(AppEnvironment.Tab.allCases) { tab in
                Button {
                    environment.selectedTab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .frame(width: 16)
                        Text(tab.title)
                            .font(.system(size: 12, weight: environment.selectedTab == tab ? .semibold : .regular))
                        Spacer(minLength: 0)
                        if tab == .vault, !environment.sealedPacks.isEmpty {
                            Text("\(environment.sealedPacks.count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Palette.accent.opacity(0.25)))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(environment.selectedTab == tab ? Palette.panelRaised : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(environment.selectedTab == tab ? Palette.ink : Palette.inkMuted)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                BadgeView(
                    text: environment.profile == .demo ? "개발용 지갑 · demo" : "실사용 지갑 · production",
                    color: environment.profile == .demo ? Palette.demoBadge : Palette.success
                )
                // Rewards only ever go to production, whatever is connected.
                Text(environment.profile == .production
                    ? "AI 사용량 적립 대상 지갑"
                    : "AI 사용량은 실사용 지갑에 적립됩니다.")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 196)
        .background(Palette.panel.opacity(0.6))
    }

    @ViewBuilder
    private var content: some View {
        switch environment.loadState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("카탈로그와 저장소를 준비하는 중입니다")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 12) {
                NoticeBanner(
                    title: "시작할 수 없습니다",
                    message: message,
                    color: Palette.danger,
                    icon: "exclamationmark.triangle"
                )
                Text("번들 카탈로그나 저장소 경로를 확인하세요.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .ready:
            Group {
                switch environment.selectedTab {
                case .today: TodayView()
                case .vault: VaultView()
                case .binder: BinderView()
                case .achievements: AchievementsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if !environment.recentUnlocks.isEmpty {
                    AchievementUnlockNotice()
                        .padding(18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

/// How far a balance is from the next pack, for the wallet lines.
struct PackAffordance: Equatable {
    var balance: Int
    var cost: Int

    var packsAvailable: Int { cost > 0 ? max(0, balance) / cost : 0 }
    var progress: Double { cost > 0 ? min(1, Double(max(0, balance)) / Double(cost)) : 0 }

    var caption: String {
        if packsAvailable > 0 { return "팩 \(packsAvailable)개를 받을 수 있습니다" }
        return "다음 팩까지 \(cost - max(0, balance)) P"
    }
}

/// The menu bar popover: the wallet, AI usage at a glance, what can be done
/// now, and the window. Details live in the window.
public struct MenuBarSummary: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            wallet
            usage
            actions
            if let error = environment.lastActionError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.hairline)
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(Palette.backdrop)
        .task { await environment.bootstrap() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("PackTrace")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
            BadgeView(
                text: environment.profile == .demo ? "개발용 지갑" : "실사용 지갑",
                color: environment.profile == .demo ? Palette.demoBadge : Palette.success
            )
        }
    }

    private var wallet: some View {
        let affordance = PackAffordance(balance: environment.balance, cost: environment.packCostPoints)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(environment.balance) P")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Text("미개봉 \(environment.sealedPacks.count) · 카드 \(environment.collectionTotals.totalCopies)")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
            }
            ProgressView(value: affordance.progress)
                .tint(affordance.packsAvailable > 0 ? Palette.success : Palette.accent)
            Text(environment.profile == .demo
                ? "\(affordance.caption) · AI 사용량은 실사용 지갑에 적립됩니다"
                : affordance.caption)
                .font(.system(size: 10))
                .foregroundStyle(Palette.inkMuted)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
    }

    private var usage: some View {
        let overview = environment.usageOverview
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("AI 사용량")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Circle()
                    .fill(overview.tone.color)
                    .frame(width: 6, height: 6)
                Text(overview.stateLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(overview.tone == .attention ? Palette.danger : Palette.inkMuted)
                Spacer(minLength: 0)
                if environment.usage.isScanning {
                    ProgressView().controlSize(.mini)
                }
                if overview.hasConnection {
                    Button {
                        Task { await environment.refreshUsageNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("사용량 새로고침")
                    .disabled(!environment.hasCollectableSource || environment.usage.isScanning)
                    if overview.canPause {
                        Button {
                            Task { await environment.pauseAllUsage() }
                        } label: {
                            Image(systemName: "pause.fill")
                        }
                        .help("모든 도구 수집 일시정지")
                    } else if overview.canResume {
                        Button {
                            Task { await environment.resumeAllUsage() }
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .help("모든 도구 수집 재개")
                        .disabled(environment.usage.isScanning)
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))

            // Accepted tokens only: cache reads are never mixed into this line.
            Text("오늘 \(environment.usage.todayAcceptedTokens.formatted()) 토큰 · +\(environment.usage.todayAwardedPoints) P")
                .font(.system(size: 10))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()

            if overview.sources.isEmpty {
                Text("연결한 도구가 없습니다 · 설정에서 연결")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.inkMuted)
            } else {
                HStack(spacing: 8) {
                    // The popover is narrow: the first five tools, then a count.
                    ForEach(overview.sources.prefix(5)) { source in
                        HStack(spacing: 3) {
                            Circle()
                                .fill(source.state.tone.color)
                                .frame(width: 5, height: 5)
                            Text(source.tool.displayName)
                                .font(.system(size: 9))
                                .foregroundStyle(Palette.inkMuted)
                                .lineLimit(1)
                        }
                        .help("\(source.tool.displayName) · \(source.state.label)")
                    }
                    if overview.sources.count > 5 {
                        Text("+\(overview.sources.count - 5)")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.inkMuted)
                            .help(overview.sources.dropFirst(5).map { "\($0.tool.displayName) · \($0.state.label)" }.joined(separator: "\n"))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task {
                    await environment.exchangeRandomPack()
                    MainWindowPresenter.show(openWindow: openWindow)
                }
            } label: {
                Text("랜덤팩 받기 · \(environment.packCostPoints) P")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(environment.balance < environment.packCostPoints || !environment.loadState.isReady)

            if !environment.sealedPacks.isEmpty || !environment.unfinishedOpenings.isEmpty {
                HStack(spacing: 6) {
                    if let opening = environment.unfinishedOpenings.first {
                        Button {
                            MainWindowPresenter.show(openWindow: openWindow)
                            environment.requestOpening(packID: opening.packInstanceID)
                        } label: {
                            Label("이어서 공개 \(opening.revealedCount)/\(opening.cards.count)", systemImage: "play.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    if !environment.sealedPacks.isEmpty {
                        Button {
                            show(.vault)
                        } label: {
                            Label("미개봉 \(environment.sealedPacks.count)팩 뜯기", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("창 열기") { MainWindowPresenter.show(openWindow: openWindow) }
            Button("설정") { show(.settings) }
            Spacer(minLength: 0)
            Button("종료") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(Palette.inkMuted)
    }

    private func show(_ tab: AppEnvironment.Tab) {
        environment.selectedTab = tab
        MainWindowPresenter.show(openWindow: openWindow)
    }
}
