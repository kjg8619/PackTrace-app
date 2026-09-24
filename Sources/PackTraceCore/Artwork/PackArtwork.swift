import Foundation

/// What a piece of pack artwork depicts.
///
/// The scene tears the pack open, so the only kind this registry accepts is the
/// printed foil booster itself. A paper sleeve, a display box or a set logo are
/// different subjects and must not be registered here.
public enum PackArtworkKind: String, Codable, Sendable, CaseIterable {
    case foilBoosterFront = "foil-booster-front"

    public var displayName: String {
        switch self {
        case .foilBoosterFront: "은박 부스터 정면"
        }
    }
}

/// Whether the right to reuse an image was established. Decoding an image
/// successfully is a technical fact and is deliberately not this.
public enum PackArtworkRights: String, Codable, Sendable {
    /// The source page carries no licence statement; the artwork belongs to its
    /// publisher and is kept as a local, private asset only.
    case unverifiedPrivateUse = "unverified-private-use"
    /// A licence was found and recorded, and it permits this use.
    case verified

    public var displayName: String {
        switch self {
        case .unverifiedPrivateUse: "미확인(비공개 개인용)"
        case .verified: "확인됨"
        }
    }

    /// No artwork may be published until its rights are verified.
    public var allowsRedistribution: Bool { self == .verified }
}

/// Where an artwork came from, kept so the picture can be re-obtained and so
/// its status is never guessed from the file being present.
public struct PackArtworkSource: Hashable, Sendable, Codable {
    public var publisher: String
    /// `official-render`, `photograph`, … — never claims a camera that was not used.
    public var kind: String
    /// The page that documents the file (provenance, not a token).
    public var pageURL: String
    /// The direct image address that was fetched.
    public var imageURL: String
    public var retrievedAt: String
    public var rights: PackArtworkRights
    public var rightsNote: String
}

/// One verified front picture for one product.
public struct PackArtworkDescriptor: Hashable, Sendable, Codable, Identifiable {
    public var id: String { artworkID }

    public var artworkID: String
    public var artworkVersion: Int
    /// Product identity. All three must match before the artwork is used.
    public var productID: String
    public var setID: String
    public var language: String
    public var region: String
    /// Human-readable name of this print, e.g. "SV01 은박 부스터 (Gyarados 아트)".
    public var displayName: String

    /// File inside the local pack-artwork directory.
    public var file: String
    /// Hash of the installed (normalised) file.
    public var contentSHA256: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    /// Hash and size of what was downloaded, before normalisation.
    public var originalSHA256: String
    public var originalPixelWidth: Int
    public var originalPixelHeight: Int
    public var originalBytes: Int

    public var kind: PackArtworkKind
    public var source: PackArtworkSource
    /// Every step applied to the pixels, in order.
    public var processing: [String]
    /// Why this picture is the right product.
    public var matchEvidence: String
    /// What could not be established about it.
    public var unverified: [String]

    public var widthToHeightRatio: Double {
        Double(pixelWidth) / Double(max(pixelHeight, 1))
    }

    public var isNormalised: Bool {
        max(pixelWidth, pixelHeight) <= PackArtworkLimits.normalizedMaxPixelSize
    }

    /// A descriptor is only usable once the installed file has been recorded:
    /// half-installed entries are dropped instead of rendering a broken pack.
    public var isComplete: Bool {
        !contentSHA256.isEmpty
            && !originalSHA256.isEmpty
            && pixelWidth > 0 && pixelHeight > 0
            && originalPixelWidth > 0 && originalPixelHeight > 0
    }
}

/// The committed artwork registry: which picture belongs to which product.
///
/// This is presentation data and lives outside the card catalogue, so installing
/// or removing artwork never touches a catalogue hash, a recipe or an opening.
public struct PackArtworkRegistry: Hashable, Sendable, Codable {
    public static let bundledFileName = "pack-artwork-v1.json"

    public var registryVersion: Int
    public var generatedAt: String
    public var note: String
    public var artworks: [PackArtworkDescriptor]

    public static func loadBundled() throws -> PackArtworkRegistry {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "pack-artwork-v1", withExtension: "json", subdirectory: "pack-artwork")
            ?? bundle.url(forResource: "pack-artwork-v1", withExtension: "json")
        guard let url else { throw PackArtworkError.registryMissing }
        return try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PackArtworkRegistry {
        do {
            let registry = try JSONDecoder().decode(PackArtworkRegistry.self, from: data)
            guard registry.registryVersion >= 1 else { throw PackArtworkError.registryUnsupported }
            return registry
        } catch let error as PackArtworkError {
            throw error
        } catch {
            throw PackArtworkError.registryUnreadable
        }
    }

    /// The artwork for a product, only when product, set and language all agree.
    ///
    /// Matching on the set name alone would hand a Japanese or Korean print to an
    /// English product, so every identity field is compared. Entries that were
    /// never installed are ignored, so a half-written registry degrades to the
    /// substitute wrapper instead of a broken pack.
    public func descriptor(productID: String, setID: String, language: String) -> PackArtworkDescriptor? {
        artworks.first {
            $0.isComplete
                && $0.productID == productID
                && $0.setID == setID
                && $0.language.lowercased() == language.lowercased()
        }
    }

    public func descriptors(productID: String) -> [PackArtworkDescriptor] {
        artworks.filter { $0.isComplete && $0.productID == productID }
    }

    /// Every entry that has an installed file recorded.
    public var installedArtworks: [PackArtworkDescriptor] {
        artworks.filter(\.isComplete)
    }
}

public enum PackArtworkError: Error, Equatable, Sendable {
    case registryMissing
    case registryUnreadable
    case registryUnsupported
    case artworkFileMissing(String)
    case installFailed(String)

    public var displayMessage: String {
        switch self {
        case .registryMissing: "포장 아트 레지스트리를 찾을 수 없습니다."
        case .registryUnreadable: "포장 아트 레지스트리를 읽을 수 없습니다."
        case .registryUnsupported: "지원하지 않는 포장 아트 레지스트리 버전입니다."
        case let .artworkFileMissing(name): "포장 이미지 파일이 없습니다: \(name)"
        case let .installFailed(reason): "포장 이미지 설치 실패: \(reason)"
        }
    }
}

/// Why a pack is drawn with the substitute wrapper instead of real artwork.
public enum PackArtworkFallback: String, Hashable, Sendable {
    /// The pack's product is not in the catalogue at all.
    case productUnknown = "product-unknown"
    /// The product has no artwork in the registry.
    case notRegistered = "not-registered"
    /// An artwork exists for this product but not for this set/language edition.
    case editionMismatch = "edition-mismatch"
    /// Registered, but the installed file is missing or unreadable.
    case fileUnavailable = "file-unavailable"

    public var displayMessage: String {
        switch self {
        case .productUnknown: "상품 정보 없음"
        case .notRegistered: "등록된 실물 포장 없음"
        case .editionMismatch: "이 판본의 실물 포장 없음"
        case .fileUnavailable: "포장 이미지 미설치"
        }
    }
}

/// The outcome of looking a pack's artwork up. Exactly one of the two cases is
/// always produced, so a screen can never show "real artwork" by accident.
public enum PackArtworkResolution: Hashable, Sendable {
    case real(PackArtworkDescriptor, URL)
    case substitute(PackArtworkFallback)

    public var descriptor: PackArtworkDescriptor? {
        if case let .real(descriptor, _) = self { return descriptor }
        return nil
    }

    public var fileURL: URL? {
        if case let .real(_, url) = self { return url }
        return nil
    }

    public var fallback: PackArtworkFallback? {
        if case let .substitute(reason) = self { return reason }
        return nil
    }

    public var isReal: Bool { descriptor != nil }

    /// Shown where status is explained (settings), never over the pack surface.
    public var statusText: String {
        switch self {
        case let .real(descriptor, _):
            "실제 포장 이미지 · \(descriptor.displayName) · \(descriptor.source.publisher)"
        case let .substitute(reason):
            "대체 포장 · \(reason.displayMessage)"
        }
    }
}

/// Maps a product to installed artwork. Presentation only: it reads files and
/// never touches the store, the RNG or the catalogue.
public struct PackArtworkResolver: Sendable {
    public var registry: PackArtworkRegistry
    /// Directory holding the installed artwork files.
    public var directory: URL

    public init(registry: PackArtworkRegistry, directory: URL) {
        self.registry = registry
        self.directory = directory
    }

    public func resolve(productID: String?, setID: String?, language: String?) -> PackArtworkResolution {
        guard let productID, let setID, let language else { return .substitute(.productUnknown) }
        // A registered picture for another edition of the same set is not a match.
        guard !registry.descriptors(productID: productID).isEmpty else {
            return .substitute(.notRegistered)
        }
        guard let descriptor = registry.descriptor(productID: productID, setID: setID, language: language) else {
            return .substitute(.editionMismatch)
        }
        let fileURL = directory.appendingPathComponent(descriptor.file)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .substitute(.fileUnavailable)
        }
        return .real(descriptor, fileURL)
    }

    public func resolve(product: PackProduct?) -> PackArtworkResolution {
        resolve(productID: product?.packID, setID: product?.setID, language: product?.language)
    }
}

/// Decode sizes for pack artwork: a small tile and the opening wrapper are
/// different jobs and get different downsample targets.
public enum PackArtworkRenderSize: String, Sendable, CaseIterable {
    /// Vault rows, Today candidates and the received-pack sheet (≤120pt wide).
    case tile
    /// The 300×430pt opening wrapper, which is torn open.
    case opening

    public var maxPixelSize: Int {
        switch self {
        case .tile: 480
        case .opening: PackArtworkLimits.normalizedMaxPixelSize
        }
    }
}

public enum PackArtworkLimits {
    /// Largest file that will be fetched from a source.
    public static let maxSourceBytes = 24 * 1024 * 1024
    /// Largest file the app will read from the artwork directory.
    public static let maxInstalledBytes = 12 * 1024 * 1024
    public static let maxPixelDimension = 8000
    public static let maxPixelCount = 40_000_000
    /// Installed artwork is resampled so its longest edge is at most this.
    /// The opening wrapper is 430pt tall, so 900 covers a 2× display with a
    /// little headroom while keeping the file small.
    public static let normalizedMaxPixelSize = 900
}
