import AppKit
import PackTraceTestSupport
import SwiftUI
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Opt-in offscreen renders for looking at the opening by eye. Writes PNGs to
/// `PACKTRACE_RENDER_PROBE_DIR` and asserts nothing about taste.
@Suite("오프스크린 렌더 프로브(옵트인)")
@MainActor
struct RenderProbeTests {
    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["PACKTRACE_RENDER_PROBE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    static func write<V: View>(_ view: V, _ name: String, scale: CGFloat = 2) throws {
        guard let directory else { return }
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test("개봉 대표 장면", .enabled(if: directory != nil))
    func openingMoments() async throws {
        let (environment, root) = try await OpeningRenderTests.makeEnvironment()
        defer { TestOwnedRoot.remove(root.deletingLastPathComponent()) }
        guard let directory = Self.directory else { return }
        for frame in try await OpeningRenderTests.frames(environment: environment, scale: 2) {
            let rep = NSBitmapImageRep(cgImage: frame.image)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("opening-" + frame.name + ".png"))
        }
    }

    @Test("모션 줄이기 무대", .enabled(if: directory != nil))
    func reducedMotionStage() async throws {
        guard let directory = Self.directory else { return }
        let (environment, root) = try await OpeningRenderTests.makeEnvironment()
        defer { TestOwnedRoot.remove(root.deletingLastPathComponent()) }
        let library = try CatalogLoader.bundledLibrary()
        let result = try #require(PackOpeningPreview.makeResult(library: library))
        let cards = result.cards.compactMap { entry -> PackOpeningCard? in
            guard let card = library.card(for: entry.cardKey) else { return nil }
            return PackOpeningCard(position: entry.position, card: card, variant: entry.variant, isNew: entry.isNew)
        }
        let engine = PackOpeningEngine(
            presentation: PackOpeningPresentation(
                openingID: nil, packID: nil, productName: "미리보기", catalogVersion: result.catalogVersion,
                recipeVersion: result.recipeVersion, product: result.product, cards: cards, revealedCount: 3, isPreview: true
            ),
            openPack: nil,
            resolveCards: { _ in cards },
            reveal: PreviewOpeningReveal(total: cards.count),
            timing: .instant
        )
        engine.start() // resumes at the fourth card
        let view = PackOpeningStageHost(engine: engine, skipsAnimations: true, onClose: {}, onShowBinder: {}, preload: { _ in })
            .environmentObject(environment)
            .frame(width: 780, height: 585)
        let image = try OpeningRenderTests.render(AnyView(view), scale: 2)
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("opening-11-reduced-motion.png"))
    }

    @Test("카드 뒷면", .enabled(if: directory != nil))
    func cardBack() throws {
        try Self.write(
            HStack(alignment: .bottom, spacing: 24) {
                CardBackView().frame(width: 150)
                CardBackView().frame(width: 300)
            }
            .padding(24)
            .background(Palette.backdrop),
            "card-back"
        )
    }
}
