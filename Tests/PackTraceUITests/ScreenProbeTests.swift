import AppKit
import PackTraceTestSupport
import SwiftUI
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Opt-in window renders for looking at whole screens by eye. Unlike
/// `ImageRenderer`, a hosting view in an offscreen window draws scroll views,
/// buttons and progress indicators the way the app does. Writes PNGs to
/// `PACKTRACE_RENDER_PROBE_DIR` from a temporary demo profile; asserts nothing
/// about taste and never touches a real collection.
@Suite("화면 렌더 프로브(옵트인)")
@MainActor
struct ScreenProbeTests {
    static func snapshot<V: View>(_ view: V, size: CGSize, settle: Duration = .milliseconds(1500)) async throws -> CGImage {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        // Let `.task` work (image loads, bootstrap guards) and layout settle.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: settle / 6)
        }
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.cgImage)
    }

    static func write(_ image: CGImage, _ name: String) throws {
        guard let directory = RenderProbeTests.directory else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// A demo profile with some packs received, some opened and one opening
    /// left half way.
    static func populatedEnvironment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-screen-probe").directory
        // A copy of the pack pictures installed on this Mac, if any, so the
        // renders show real wrappers. Only the picture files; nothing else from
        // the real data root is read.
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PackTrace/pack-artwork", isDirectory: true)
        if FileManager.default.fileExists(atPath: installed.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: installed, to: root.appendingPathComponent("pack-artwork", isDirectory: true))
        }
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = 11
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        var received: [PackInstanceRecord] = []
        for _ in 0..<7 where environment.balance >= environment.packCostPoints {
            if let pack = await environment.exchangeRandomPack() { received.append(pack) }
        }
        let store = try #require(environment.store)
        for (index, pack) in received.prefix(3).enumerated() {
            let opening = try await environment.openPack(pack.id)
            // Two finished, one left half way.
            let count = index < 2 ? opening.cards.count : opening.cards.count / 2
            _ = try await store.setRevealedCount(openingID: opening.id, count: count)
        }
        await environment.refresh()
        environment.receivedPack = nil
        return (environment, root)
    }

    @Test("주요 화면", .enabled(if: RenderProbeTests.directory != nil))
    func mainScreens() async throws {
        let (environment, root) = try await Self.populatedEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }
        for tab in AppEnvironment.Tab.allCases {
            environment.selectedTab = tab
            let image = try await Self.snapshot(
                MainWindowView().environmentObject(environment),
                size: CGSize(width: 1080, height: 1400)
            )
            try Self.write(image, "screen-\(tab.rawValue)")
        }
        if let set = environment.setSummaries.first?.setID {
            await environment.selectBinderSet(set)
            try Self.write(
                try await Self.snapshot(
                    BinderView(startingSet: set).environmentObject(environment).background(Palette.backdrop),
                    size: CGSize(width: 884, height: 900)
                ),
                "screen-binder-set"
            )
        }
        // Card search across every set.
        let searching = BinderView(startingQuery: "charizard").environmentObject(environment).background(Palette.backdrop)
        try Self.write(try await Self.snapshot(searching, size: CGSize(width: 884, height: 1100)), "screen-binder-search")
        for section in SettingsModel.Section.allCases {
            try Self.write(
                try await Self.snapshot(
                    SettingsView(section: section).environmentObject(environment).background(Palette.backdrop),
                    size: CGSize(width: 884, height: 1100)
                ),
                "screen-settings-\(section.rawValue)"
            )
        }
        environment.selectedTab = .vault
        environment.settings.vaultLayout = .list
        try Self.write(
            try await Self.snapshot(MainWindowView().environmentObject(environment), size: CGSize(width: 1080, height: 900)),
            "screen-vault-list"
        )
        environment.settings.vaultLayout = .gallery
        let menu = try await Self.snapshot(
            MenuBarSummary().environmentObject(environment),
            size: CGSize(width: 300, height: 480)
        )
        try Self.write(menu, "screen-menu")
    }
}
