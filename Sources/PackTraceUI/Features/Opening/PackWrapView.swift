import AppKit
import PackTraceCore
import SwiftUI

/// Torn paper edge used where the wrapper strip separates from the pack body.
struct TearEdgeShape: Shape {
    var edgeAtBottom: Bool
    var teeth: Int = 12
    var amplitude: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step = rect.width / CGFloat(max(teeth, 1))
        if edgeAtBottom {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            var x = rect.maxX
            var index = 0
            while x > rect.minX {
                let nextX = max(rect.minX, x - step / 2)
                path.addLine(to: CGPoint(x: nextX, y: index % 2 == 0 ? rect.maxY : rect.maxY - amplitude))
                x = nextX
                index += 1
            }
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + amplitude))
            var x = rect.minX
            var index = 0
            while x < rect.maxX {
                let nextX = min(rect.maxX, x + step / 2)
                path.addLine(to: CGPoint(x: nextX, y: index % 2 == 0 ? rect.minY : rect.minY + amplitude))
                x = nextX
                index += 1
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The sealed pack.
///
/// When the product's real printed booster is installed, the wrapper *is* that
/// picture: the strip and the body are two windows over one image at one scale,
/// so the printed logo, set name and seal line up across the tear. Without it the
/// substitute foil panel is drawn and labelled as such.
///
/// The wrapper reacts to the hand: the tear strip follows the drag, the body
/// compresses a little and the tear line brightens. `cleared` is only ever set
/// after the draw is committed, which is what makes the wrapper "open".
struct PackWrapView: View {
    var product: PackProduct?
    var dragOffset: CGFloat
    var threshold: CGFloat
    var cleared: Bool
    /// Reduced motion: no drifting highlight, no breathing.
    var stillSurface: Bool = false
    /// Advances while the wrapper is on screen; drives the strain vibration.
    var shakePhase: Double = 0

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var artwork = PackArtworkModel()
    @StateObject private var logoLoader = RemoteImageModel()
    @StateObject private var surface = FoilSurfaceModel()

    private let width: CGFloat = PackWrapFrame.width
    private let height: CGFloat = PackWrapFrame.height
    private let stripHeight: CGFloat = PackWrapFrame.stripHeight

    private var progress: TearProgress {
        TearProgress.from(dragOffset: dragOffset, threshold: threshold)
    }

    /// Where the real artwork sits and where the tear line crosses it. Depends
    /// only on the pack identity, so it cannot move while the pack is dragged.
    private var artworkGeometry: PackArtworkGeometry? {
        guard let descriptor = artwork.descriptor else { return nil }
        return PackArtworkGeometry(
            frame: CGSize(width: width, height: height),
            artworkSize: CGSize(width: descriptor.pixelWidth, height: descriptor.pixelHeight)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Top-aligned: the wrapper's own stack is only as tall as the body
            // (strip and body are offsets inside it), and centred in the frame it
            // was drawn half a strip (46pt) below the pack's layout frame —
            // spilling into the HUD and off the area that takes the drag.
            wrapper
                .frame(width: width, height: height, alignment: .top)
        }
        .frame(width: width, height: height)
        .task(id: "\(product?.packID ?? "-")|\(environment.imageCache == nil)") {
            await artwork.prepare(product: product, environment: environment, size: .opening)
        }
        .task(id: "\(product?.packID ?? "-")|\(logoLoader.image == nil)") {
            // Only needed for the substitute; harmless (and cached) otherwise.
            guard artwork.showsRealArtwork == false else { return }
            await logoLoader.load(
                urlString: product?.artworkSubstitute.logoURL,
                quality: .thumbnail,
                cache: environment.imageCache
            )
        }
        .task(id: "\(stillSurface)|\(artwork.showsRealArtwork)") {
            // The printed pack already carries its own highlights, so the foil
            // drift only runs for the substitute surface.
            surface.drift(enabled: !stillSurface && artwork.showsRealArtwork == false)
        }
        .onHover { inside in
            guard !cleared else { return }
            if inside {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    private var wrapper: some View {
        let tear = progress
        return ZStack(alignment: .top) {
            // Body: compresses slightly while pulled, then opens and drops away.
            bodyContent(travel: tear.stripTravel)
                .frame(width: width, height: height - stripHeight)
                .clipShape(TearEdgeShape(edgeAtBottom: false, amplitude: 5 + CGFloat(tear.progress) * 3))
                .scaleEffect(
                    x: 1 - CGFloat(tear.bodySquash),
                    y: 1 + CGFloat(tear.bodySquash) * 0.4,
                    anchor: .bottom
                )
                .offset(y: stripHeight + (cleared ? 26 : min(tear.progress * 10, 10) + tear.bodyFollow))
                .offset(x: tear.shake(at: shakePhase))
                .opacity(cleared ? 0 : 1)
                .offset(y: cleared ? 150 : 0)
                .rotationEffect(.degrees(cleared ? 1.6 : 0), anchor: .bottom)

            // Strip: follows the drag, tilts, then leaves the screen.
            stripContent(travel: tear.stripTravel)
                .frame(width: width, height: stripHeight)
                .clipShape(TearEdgeShape(edgeAtBottom: true, amplitude: 5))
                .rotationEffect(
                    .degrees(cleared ? 16 : -tear.stripRotation - tear.tension * 2.4),
                    anchor: .topTrailing
                )
                .offset(
                    x: cleared ? 430 : tear.stripTravel,
                    y: cleared ? -90 : -min(tear.progress * 4, 4)
                )
                .opacity(cleared ? 0 : tear.stripOpacity)

            if !cleared {
                tearLine(highlight: tear.edgeHighlight + tear.tension * 0.5)
            }
            if cleared {
                // Short foil peel where the strip left the body.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Palette.ink.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: width, height: 26)
                    .offset(y: stripHeight - 13)
                    .blendMode(.plusLighter)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(cleared && !stillSurface ? .spring(response: 0.5, dampingFraction: 0.72) : nil, value: cleared)
    }

    private func stripContent(travel: CGFloat) -> some View {
        ZStack {
            wrapperPiece(isStrip: true, travel: travel)
            if artwork.showsRealArtwork == false {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink.opacity(0.75))
                    Text("여기를 잡고 뜯기")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink.opacity(0.8))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.ink.opacity(0.6))
                }
                .padding(.horizontal, 14)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                // Over printed artwork the cue stays small and legible instead of
                // covering the set logo.
                Text("여기를 잡고 뜯기")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func bodyContent(travel: CGFloat) -> some View {
        wrapperPiece(isStrip: false, travel: travel)
    }

    /// One window over the pack picture.
    ///
    /// Both pieces draw the same image at the same placement and are then offset
    /// and clipped to their half, which is what keeps the print continuous and at
    /// one scale across the tear. The substitute surface fills each window
    /// instead when there is no installed artwork.
    @ViewBuilder
    private func wrapperPiece(isStrip: Bool, travel: CGFloat) -> some View {
        if artwork.showsRealArtwork, let image = artwork.image, let geometry = artworkGeometry {
            let window = isStrip ? geometry.stripWindow : geometry.bodyWindow
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geometry.artRect.width, height: geometry.artRect.height)
                    .offset(x: geometry.artRect.minX, y: geometry.artRect.minY)
                // A hint of the inner foil where the pack has been opened.
                if isStrip == false, travel > 0 || cleared {
                    Rectangle()
                        .fill(Palette.ink.opacity(0.18))
                        .frame(width: geometry.artRect.width, height: 10)
                        .offset(x: geometry.artRect.minX, y: 0)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .offset(y: -window.minY)
            .frame(width: width, height: window.height, alignment: .top)
            .clipped()
        } else {
            substitutePiece(isStrip: isStrip, travel: travel)
        }
    }

    private func substitutePiece(isStrip: Bool, travel: CGFloat) -> some View {
        ZStack {
            if isStrip {
                foil(baseOffset: 0, travel: travel)
            } else {
                PackSubstituteSurface(product: product, compact: false, showsSpinner: artwork.state == .loading)
                    .overlay(alignment: .bottom) {
                        if artwork.isRetryable {
                            PackArtworkRetryButton(reason: .fileUnavailable) {
                                Task {
                                    await artwork.retry(
                                        product: product,
                                        environment: environment,
                                        size: .opening
                                    )
                                }
                            }
                            .padding(.bottom, 6)
                        }
                    }
            }
        }
    }

    /// The tear line brightens as the wrapper opens.
    private func tearLine(highlight: Double) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.0001))
                .frame(height: 1)
            TearEdgeShape(edgeAtBottom: true, teeth: 12, amplitude: 5)
                .fill(Palette.ink.opacity(0.05 + highlight * 0.09))
                .frame(width: width, height: stripHeight)
                .blendMode(.plusLighter)
        }
        .offset(y: stripHeight)
        .allowsHitTesting(false)
    }

    /// Foil gradient plus a highlight band that moves with the drag and drifts
    /// slowly while the pack waits. Substitute surface only.
    private func foil(baseOffset: CGFloat, travel: CGFloat) -> some View {
        let shift = Double(baseOffset + travel) / 900 + surface.driftOffset
        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.17, blue: 0.31),
                    Color(red: 0.30, green: 0.18, blue: 0.38),
                    Color(red: 0.14, green: 0.24, blue: 0.36),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(0.0),
                    Color.white.opacity(0.16),
                    Color.white.opacity(0.0),
                ],
                startPoint: UnitPoint(x: 0.1 + shift, y: 0),
                endPoint: UnitPoint(x: 0.5 + shift, y: 1)
            )
            .blendMode(.plusLighter)
        }
    }
}

/// Drives the slow highlight drift on the wrapper.
///
/// `@State` is not available in this toolchain (Command Line Tools only, no
/// SwiftUIMacros), so the surface animation lives in a tiny observable object.
@MainActor
final class FoilSurfaceModel: ObservableObject {
    @Published private(set) var driftOffset: Double = 0
    private var task: Task<Void, Never>?

    func drift(enabled: Bool) {
        task?.cancel()
        guard enabled else {
            driftOffset = 0
            return
        }
        task = Task { [weak self] in
            var forward = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.6))
                guard let self, !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 2.4)) {
                    self.driftOffset = forward ? 0.05 : -0.02
                }
                forward.toggle()
            }
        }
    }

    deinit { task?.cancel() }
}
