import PackTraceCore
import SwiftUI

/// Loads one remote image (card art, set logo) through the shared cache.
/// Kept as a separate observable object so views stay free of async plumbing.
@MainActor
final class RemoteImageModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case loaded
        case unavailable
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var image: NSImage?
    /// A failed load that a retry could fix (wrong or damaged bytes, offline).
    @Published private(set) var isRetryable = false

    private var requestedURL: String?
    private var requestedQuality: CardImageQuality = .thumbnail

    func load(urlString: String?, quality: CardImageQuality, cache: ImageCache?) async {
        guard let urlString else {
            state = .unavailable
            image = nil
            isRetryable = false
            return
        }
        guard requestedURL != "\(quality.rawValue)|\(urlString)" || state == .idle else { return }
        requestedURL = "\(quality.rawValue)|\(urlString)"
        requestedQuality = quality
        state = .loading
        guard let cache else {
            state = .unavailable
            image = nil
            isRetryable = false
            return
        }
        // The cache decodes off the main thread and gives back a drawable image,
        // so this call never blocks a scroll.
        let requested = ContinuousClock.now
        let decoded = await cache.image(for: urlString, quality: quality)
        if OpeningTrace.isEnabled {
            OpeningTrace.log("image-\(quality.rawValue)-\(decoded == nil ? "failed" : "ready")-after-\(OpeningTrace.milliseconds(ContinuousClock.now - requested))ms")
        }
        if let decoded {
            image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
            state = .loaded
            isRetryable = false
        } else {
            image = nil
            state = .unavailable
            isRetryable = true
        }
    }

    /// The lower-quality image for the same card, shown while the requested one
    /// loads. Only used when a fallback quality was asked for.
    @Published private(set) var fallbackImage: NSImage?

    func loadFallback(card: CardDefinition, quality: CardImageQuality?, cache: ImageCache?) async {
        guard let quality, let cache else {
            fallbackImage = nil
            return
        }
        let url = CardImageURL.url(for: card, quality: quality)
        // Only from what is already cached: the fallback must never start a
        // download of its own on top of the requested image.
        guard let decoded = await cache.cachedImage(for: url, quality: quality) else {
            fallbackImage = nil
            return
        }
        fallbackImage = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
    }

    /// A card's image at `quality`, with the cached `fallbackQuality` shown while
    /// it loads.
    ///
    /// The fallback goes first: it only reads what is already cached, so it is up
    /// at once and covers the wait. (Loaded after the requested image, it only
    /// ever appeared once the wait was over — which is when it is not needed.)
    func load(
        card: CardDefinition,
        quality: CardImageQuality,
        fallbackQuality: CardImageQuality?,
        cache: ImageCache?
    ) async {
        guard CardImageURL.hasImage(card) else {
            await load(urlString: nil, quality: quality, cache: cache)
            return
        }
        await loadFallback(card: card, quality: fallbackQuality, cache: cache)
        await load(urlString: CardImageURL.url(for: card, quality: quality), quality: quality, cache: cache)
        // A few source cards ship only the large image (sv10 #028 has no
        // low.webp). A thumbnail that could not be loaded is then drawn from the
        // large one, decoded at thumbnail size; if that fails too the card keeps
        // its "no image" placeholder, and the cache remembers both failures.
        if state == .unavailable, quality == .thumbnail, let cache {
            let full = CardImageURL.url(for: card, quality: .full)
            if let decoded = await cache.image(for: .remote(urlString: full, quality: .thumbnail)) {
                image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
                state = .loaded
                isRetryable = false
            }
        }
    }

    /// Clears the recorded failure and tries the same URL again.
    func retry(cache: ImageCache?) async {
        guard let urlString = requestedURL?.split(separator: "|", maxSplits: 1).last.map(String.init) else { return }
        await cache?.forgetFailure(urlString, quality: requestedQuality)
        requestedURL = nil
        await load(urlString: urlString, quality: requestedQuality, cache: cache)
    }
}

/// Card image with a placeholder that keeps the card's identity readable when
/// the asset is missing or the machine is offline. Ownership data is never
/// affected by an image failure.
struct CardArtworkView: View {
    let card: CardDefinition
    var quality: CardImageQuality = .thumbnail
    var cornerRadius: CGFloat = 8
    /// Shown while the requested quality loads, so an enlargement can start from
    /// the thumbnail the grid already has instead of an empty box.
    var fallbackQuality: CardImageQuality?
    /// Offer a retry when the load failed in a way that could succeed later.
    var allowsRetry: Bool = false

    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var loader = RemoteImageModel()

    private var urlString: String {
        CardImageURL.url(for: card, quality: quality)
    }

    var body: some View {
        ZStack {
            switch loader.state {
            case .loaded:
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
            case .idle, .loading:
                placeholder(showsSpinner: true)
            case .unavailable:
                placeholder(showsSpinner: false)
            }
            // Low-res first, sharp a moment later: the enlargement never opens empty.
            if loader.state != .loaded, let fallback = loader.fallbackImage {
                Image(nsImage: fallback)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            if allowsRetry, loader.isRetryable {
                Button("다시 시도") {
                    Task { await loader.retry(cache: environment.imageCache) }
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .padding(4)
            }
        }
        .task(id: urlString) {
            await loader.load(
                card: card,
                quality: quality,
                fallbackQuality: fallbackQuality,
                cache: environment.imageCache
            )
        }
    }

    private func placeholder(showsSpinner: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [Palette.panelRaised, Palette.panel],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                if showsSpinner {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(Palette.inkMuted)
                }
                Text(card.name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.inkMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                // The card stays identifiable without its artwork: set, number
                // and rarity are local metadata, not part of the image.
                Text("\(card.setID.uppercased()) \(card.localID) · \(card.rarity.displayName)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted.opacity(0.9))
                    .lineLimit(1)
                if !showsSpinner {
                    Text(allowsRetry && loader.isRetryable ? "이미지 없음 · 다시 시도 가능" : "이미지 없음")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.inkMuted.opacity(0.8))
                }
            }
            .padding(8)
        }
        .aspectRatio(600.0 / 825.0, contentMode: .fit)
    }
}

/// A card as it appears in a pack, the binder and detail views.
struct CardFaceView: View {
    let card: CardDefinition
    var variant: CardVariant?
    var quality: CardImageQuality = .thumbnail
    /// Already-cached lower quality to show while `quality` loads.
    var fallbackQuality: CardImageQuality?
    var isNew: Bool = false
    var quantity: Int?
    /// Stars for duplicate copies (`CardMastery`); shown with the quantity.
    var stars: Int = 0
    /// A one-shot highlight over the card image only (the opening's reveal).
    var sweep: CardSweepBand?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                artwork
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Palette.rarityColor(card.rarity).opacity(0.55), lineWidth: 1)
                    )
                    .shadow(
                        color: Palette.rarityColor(card.rarity).opacity(card.rarity.isFoilByDefault ? 0.35 : 0.12),
                        radius: 10,
                        y: 4
                    )
                if let quantity, quantity > 1 {
                    HStack(spacing: 3) {
                        Text("×\(quantity)")
                            .foregroundStyle(Palette.ink)
                        if stars > 0 {
                            Text(String(repeating: "★", count: stars))
                                .foregroundStyle(Palette.accentWarm)
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(6)
                    .accessibilityLabel(stars > 0 ? "\(quantity)장, 별 \(stars)개" : "\(quantity)장")
                }
            }
            HStack(spacing: 4) {
                Text(card.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isNew {
                    BadgeView(text: "새 카드", color: Palette.success)
                }
            }
            HStack(spacing: 4) {
                Text("\(card.setID.uppercased()) \(card.localID)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
                BadgeView(text: card.rarity.displayName, color: Palette.rarityColor(card.rarity))
                if let variant, variant != .normal {
                    BadgeView(text: variant.displayName, color: Palette.accent)
                }
            }
        }
    }
}

extension CardFaceView {
    @ViewBuilder
    fileprivate var artwork: some View {
        let image = CardArtworkView(card: card, quality: quality, fallbackQuality: fallbackQuality, allowsRetry: true)
        if let sweep {
            image.modifier(sweep)
        } else {
            image
        }
    }
}
