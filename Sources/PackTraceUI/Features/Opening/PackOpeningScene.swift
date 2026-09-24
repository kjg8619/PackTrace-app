import PackTraceCore
import SwiftUI

/// Root of the pack opening presentation.
///
/// Responsibilities, in order:
/// 1. resolve the stored result into card view models (or resume one),
/// 2. hand it to `PackOpeningEngine`, which owns the state machine,
/// 3. compose the stages and forward user input.
///
/// It never draws a card itself: the draw happens through `AppEnvironment` when
/// the user tears the pack, and the wrapper is only shown as open after that
/// commit succeeded. No card face is drawn before the result exists.
struct PackOpeningScene: View {
    /// What this scene opens: a stored pack, or the development preview.
    enum Source {
        case stored(PackInstanceRecord)
        case preview(PackOpeningPreview.Result)

        var pack: PackInstanceRecord? {
            if case let .stored(pack) = self { return pack }
            return nil
        }

        var previewResult: PackOpeningPreview.Result? {
            if case let .preview(result) = self { return result }
            return nil
        }
    }

    let source: Source
    var skipsAnimations: Bool

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = PackOpeningSceneModel()
    @FocusState private var keyFocus: Bool

    private var engine: PackOpeningEngine? { model.engine }
    private var loadError: String? { model.loadError }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.hairline)
            Group {
                if let engine {
                    stage(engine)
                } else if let loadError {
                    NoticeBanner(
                        title: "팩 상태를 확인하지 못했습니다",
                        message: loadError,
                        color: Palette.danger,
                        icon: "exclamationmark.triangle"
                    )
                    .padding(24)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("팩 상태를 확인하는 중입니다")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.backdrop)
        .focusable()
        .focused($keyFocus)
        .task {
            await model.prepare(source: source, environment: environment, skipsAnimations: skipsAnimations)
            keyFocus = true
            await autoplay()
        }
        .onKeyPress(.space) { handlePrimaryKey() }
        .onKeyPress(.return) { handlePrimaryKey() }
        .onKeyPress(.escape) {
            close()
            return .handled
        }
        .onDisappear {
            // Nothing may outlive the sheet: timers, tasks and animations stop here.
            model.cancel()
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            if source.previewResult != nil {
                BadgeView(text: "개발용 미리보기 · 저장 안 함", color: Palette.demoBadge)
            }
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("닫기 (Esc)")
        }
        .padding(16)
    }

    private var headerTitle: String {
        switch source {
        case let .stored(pack):
            return environment.product(for: pack)?.name ?? pack.productID
        case let .preview(result):
            return result.product?.name ?? "미리보기 팩"
        }
    }

    private var subtitle: String {
        switch source {
        case let .stored(pack):
            return "팩 ID \(pack.id.rawValue.prefix(8)) · 판본 \(pack.catalogVersion) · recipe v\(pack.recipeVersion)"
        case let .preview(result):
            return "합성 결과 · 실제 지갑·팩·카드 기록에 영향 없음 · \(result.catalogVersion)"
        }
    }

    // MARK: - Stages

    private func stage(_ engine: PackOpeningEngine) -> some View {
        PackOpeningStageHost(
            engine: engine,
            skipsAnimations: skipsAnimations,
            onClose: { close() },
            onShowBinder: {
                if source.pack != nil {
                    environment.selectedTab = .binder
                }
                close()
            },
            preload: { current in await preload(from: current) }
        )
    }

    // MARK: - Input

    /// Space/Return: tear, then reveal, then close. Each state accepts exactly
    /// one kind of input, so held keys cannot skip a card or double-fire.
    private func handlePrimaryKey() -> KeyPress.Result {
        guard let engine else { return .ignored }
        switch OpeningPrimaryAction.for(engine) {
        case .tear: engine.tear()
        case .advance: engine.advance()
        case .close: close()
        // Anything that is playing right now ignores input on purpose.
        case .none: break
        }
        return .handled
    }

    // MARK: - Preview autoplay

    /// Development preview only, and only when `PACKTRACE_OPENING_AUTOPLAY` is set
    /// as well: tears the pack and reveals every card by itself so the motion can
    /// be watched without a hand on the keyboard. A stored pack is never opened
    /// this way, and nothing here writes to the store.
    private func autoplay() async {
        guard PackOpeningPreview.autoplayAllowed(
            isPreviewSource: source.previewResult != nil,
            environment: ProcessInfo.processInfo.environment
        ) else { return }
        guard let engine else { return }
        while !Task.isCancelled {
            switch OpeningPrimaryAction.for(engine) {
            case .tear: engine.tear()
            case .advance: engine.advance()
            case .close: return
            case .none: break
            }
            // The engine's input lock sets the pace: while a stage is playing it
            // accepts nothing, so this only waits for the stage to settle.
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    // MARK: - Preloading


    /// Warms the images the next cards need (see `OpeningImagePreload`). The
    /// preview takes the same path, so measuring it measures the product.
    private func preload(from engine: PackOpeningEngine) async {
        guard let cache = environment.imageCache else { return }
        let requests = OpeningImagePreload.requests(
            for: engine.state,
            cards: engine.cards,
            revealedCount: engine.revealedCount
        )
        guard !requests.isEmpty else { return }
        await cache.prefetch(requests)
    }

    private func close() {
        model.cancel()
        dismiss()
    }
}
