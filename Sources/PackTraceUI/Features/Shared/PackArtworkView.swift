import AppKit
import PackTraceCore
import SwiftUI

/// One pack picture source for every screen.
///
/// The registry says which artwork belongs to a product and the resolver says
/// whether its file is installed; this model loads it once and never changes its
/// mind while the view is alive. That last part matters: a picture that finished
/// loading after a drag began must not resize the pack or move the tear line
/// under the user's hand.
@MainActor
final class PackArtworkModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        /// Real artwork is in hand.
        case real
        /// No usable artwork: the substitute wrapper is drawn instead.
        case substitute(PackArtworkFallback)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var image: NSImage?
    @Published private(set) var descriptor: PackArtworkDescriptor?
    /// A failure a retry could fix (file installed later, damaged file repaired).
    @Published private(set) var isRetryable = false

    private var resolution: PackArtworkResolution?
    private var preparedKey: String?

    /// Resolves and loads. Repeated calls for the same pack and size are no-ops,
    /// so a re-render can never re-decide the picture or the geometry.
    func prepare(product: PackProduct?, environment: AppEnvironment, size: PackArtworkRenderSize) async {
        let key = "\(product?.packID ?? "-")|\(size.rawValue)|\(environment.imageCache == nil)"
        guard key != preparedKey else { return }
        preparedKey = key
        resolution = nil
        await load(product: product, environment: environment, size: size)
    }

    /// Retries after a failure. The only path that may turn a substitute into
    /// real artwork once a view is on screen.
    func retry(product: PackProduct?, environment: AppEnvironment, size: PackArtworkRenderSize) async {
        if case let .real(descriptor, fileURL) = resolution {
            await environment.imageCache?.forgetFailure(
                .packArtwork(descriptor: descriptor, fileURL: fileURL, size: size)
            )
        }
        resolution = nil
        preparedKey = "\(product?.packID ?? "-")|\(size.rawValue)|\(environment.imageCache == nil)"
        await load(product: product, environment: environment, size: size)
    }

    private func load(product: PackProduct?, environment: AppEnvironment, size: PackArtworkRenderSize) async {
        let resolution = resolution ?? environment.packArtwork(for: product)
        self.resolution = resolution

        guard let cache = environment.imageCache else {
            // The store is still opening. Showing the substitute here and then
            // swapping in the picture would change the pack mid-scene.
            state = .loading
            return
        }

        switch resolution {
        case let .substitute(reason):
            state = .substitute(reason)
            descriptor = nil
            image = nil
            isRetryable = false

        case let .real(descriptor, fileURL):
            self.descriptor = descriptor
            state = .loading
            let request = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: size)
            if let decoded = await cache.image(for: request) {
                image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                state = .real
                isRetryable = false
            } else {
                // Registered but unreadable: the substitute is drawn, and a retry
                // is offered instead of pretending the real pack is there.
                image = nil
                state = .substitute(.fileUnavailable)
                isRetryable = true
            }
        }
    }

    /// `true` while the picture on screen is the real printed pack.
    var showsRealArtwork: Bool {
        state == .real && image != nil
    }
}

/// The stand-in wrapper: set logo on a neutral foil panel with the artwork
/// disclaimer attached. Used for every pack that has no installed picture, and
/// for the whole screen while a real picture is still loading.
struct PackSubstituteSurface: View {
    var product: PackProduct?
    /// `true` for small tiles, which have no room for the full disclaimer.
    var compact: Bool
    var showsSpinner: Bool = false

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var logoLoader = RemoteImageModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.17, blue: 0.31),
                    Color(red: 0.30, green: 0.18, blue: 0.38),
                    Color(red: 0.14, green: 0.24, blue: 0.36),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: compact ? 2 : 12) {
                Spacer(minLength: 0)
                logo
                if compact == false {
                    VStack(spacing: 4) {
                        Text(product?.name ?? "팩")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text("\(product?.region ?? "") · \(product?.language.uppercased() ?? "")" + (environment.packSize(of: product).map { " · 카드 \($0)장" } ?? ""))
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.ink.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
                if compact == false {
                    VStack(spacing: 3) {
                        Text("PackTrace 대체 포장")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Palette.ink.opacity(0.75))
                        Text("실제 부스터 포장지가 아닙니다")
                            .font(.system(size: 9))
                            .foregroundStyle(Palette.ink.opacity(0.55))
                    }
                    .padding(.bottom, 18)
                }
            }
            .padding(.horizontal, 18)
        }
        .task(id: product?.artworkSubstitute.logoURL) {
            await logoLoader.load(
                urlString: product?.artworkSubstitute.logoURL,
                quality: .thumbnail,
                cache: environment.imageCache
            )
        }
    }

    private var logo: some View {
        Group {
            if let logo = logoLoader.image {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: compact ? 40 : 190)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            } else if showsSpinner {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "seal.fill")
                    .font(.system(size: compact ? 16 : 42))
                    .foregroundStyle(Palette.ink.opacity(0.7))
            }
        }
    }
}

/// A pack as a picture: real printed artwork when it is installed, the
/// substitute surface otherwise. Every screen that shows a pack uses this, so
/// the shop, the vault and the opening scene cannot disagree.
struct PackArtworkView: View {
    var product: PackProduct?
    var size: PackArtworkRenderSize = .tile
    var isOpened: Bool = false
    var allowsRetry: Bool = true

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = PackArtworkModel()

    var body: some View {
        ZStack {
            switch model.state {
            case .real:
                if let image = model.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    PackSubstituteSurface(product: product, compact: size == .tile)
                }
            case let .substitute(reason):
                PackSubstituteSurface(
                    product: product,
                    compact: size == .tile,
                    showsSpinner: false
                )
                .overlay(alignment: .bottom) {
                    if allowsRetry, model.isRetryable {
                        PackArtworkRetryButton(reason: reason) {
                            Task { await model.retry(product: product, environment: environment, size: size) }
                        }
                        .padding(4)
                    }
                }
            case .idle, .loading:
                PackSubstituteSurface(product: product, compact: size == .tile, showsSpinner: true)
            }
        }
        .grayscale(isOpened ? 0.6 : 0)
        .task(id: "\(product?.packID ?? "-")|\(size.rawValue)|\(environment.imageCache == nil)") {
            await model.prepare(product: product, environment: environment, size: size)
        }
    }
}

/// Small retry affordance for a registered picture that could not be read.
struct PackArtworkRetryButton: View {
    var reason: PackArtworkFallback
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .bold))
                Text(reason.displayMessage)
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .foregroundStyle(Palette.ink)
        }
        .buttonStyle(.plain)
        .help("포장 이미지를 다시 읽습니다. 실패하면 대체 포장으로 표시됩니다.")
    }
}
