import PackTraceCore
import PackTraceUI
import SwiftUI

@main
struct PackTraceApp: App {
    @StateObject private var environment = AppEnvironment.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        // Prepare the store, catalogue and demo grant as soon as the app starts,
        // so the menu bar shows real numbers on first click.
        let environment = AppEnvironment.shared
        Task { @MainActor in await environment.bootstrap() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarSummary()
                .environmentObject(environment)
        } label: {
            Label("PackTrace", systemImage: "rectangle.stack")
                // Menu bar first: the collection window is opened once at launch
                // and can be reopened from the menu. macOS 14 has no
                // `defaultLaunchBehavior`, so this fires from the label instead.
                .onAppear { MainWindowPresenter.show(openWindow: openWindow) }
        }
        .menuBarExtraStyle(.window)

        Window("PackTrace", id: AppWindow.main) {
            MainWindowView()
                .environmentObject(environment)
                .background(MainWindowTag())
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
    }
}
