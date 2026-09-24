import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PackTraceTestSupport
import Testing
import UniformTypeIdentifiers

@testable import PackTraceCore

/// Pack artwork: mapping, byte-level validation, the tear split, and proof that
/// installing or removing a picture never changes what a pack contains.
///
/// Nothing here touches the network. The source artwork is never used as a test
/// fixture: the bytes are generated in-process.
@Suite("팩 포장 아트")
struct PackArtworkTests {
    // MARK: - Fixtures

    /// Deterministic greyscale bands, so a crop that is off by a row is visible
    /// as a brightness jump instead of an invisible shift.
    static func bandedPNG(width: Int, height: Int, bands: Int = 12) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Software rendering keeps the fixture byte-identical between runs.
        for index in 0..<bands {
            let level = CGFloat(index + 1) / CGFloat(bands)
            context.setFillColor(CGColor(red: level, green: level, blue: level, alpha: 1))
            context.fill(CGRect(
                x: 0,
                y: CGFloat(index) * CGFloat(height) / CGFloat(bands),
                width: CGFloat(width),
                height: CGFloat(height) / CGFloat(bands)
            ))
        }
        // A strong marker at the very top row: the strip must carry it and the
        // body must not. Blue, so it is distinguishable from the brightest band.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) - 2, width: CGFloat(width), height: 2))
        let image = context.makeImage()!
        return png(image)
    }

    static func png(_ image: CGImage) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func descriptor(
        artworkID: String = "fixture-art-v1",
        productID: String = "tpcgi-en-sv01-booster",
        setID: String = "sv01",
        language: String = "en",
        file: String = "fixture.png",
        width: Int = 60,
        height: Int = 110
    ) -> PackArtworkDescriptor {
        PackArtworkDescriptor(
            artworkID: artworkID,
            artworkVersion: 1,
            productID: productID,
            setID: setID,
            language: language,
            region: "US/International",
            displayName: "fixture artwork",
            file: file,
            contentSHA256: String(repeating: "a", count: 64),
            pixelWidth: width,
            pixelHeight: height,
            originalSHA256: String(repeating: "b", count: 64),
            originalPixelWidth: width * 2,
            originalPixelHeight: height * 2,
            originalBytes: 1024,
            kind: .foilBoosterFront,
            source: PackArtworkSource(
                publisher: "fixture",
                kind: "official-render",
                pageURL: "https://example.invalid/page",
                imageURL: "https://example.invalid/image.png",
                retrievedAt: "2026-09-23",
                rights: .unverifiedPrivateUse,
                rightsNote: "fixture"
            ),
            processing: ["fixture"],
            matchEvidence: "fixture",
            unverified: []
        )
    }

    static func registry(_ descriptors: [PackArtworkDescriptor]) -> PackArtworkRegistry {
        PackArtworkRegistry(
            registryVersion: 1,
            generatedAt: "2026-09-23",
            note: "fixture",
            artworks: descriptors
        )
    }

    /// A temporary directory that is deleted when the test ends.
    static func makeDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("packtrace-artwork-\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Mean red per row, top row first. The fixture's bands are grey, so the red
    /// channel is the band's level and the blue top marker reads as zero.
    static func rowMeans(_ image: CGImage) -> [Double] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var means: [Double] = []
        for row in 0..<height {
            let start = row * width * 4
            var total = 0
            for column in 0..<width {
                total += Int(bytes[start + column * 4])
            }
            means.append(Double(total) / Double(width))
        }
        return means
    }

    // MARK: - A. Mapping

    static var registryHasArtwork: Bool {
        !((try? PackArtworkRegistry.loadBundled())?.artworks.isEmpty ?? true)
    }

    @Test("포장 그림을 등록하지 않은 빌드는 모든 상품을 대체 포장으로 보인다", .enabled(if: !PackArtworkTests.registryHasArtwork))
    func emptyRegistryFallsBackEverywhere() throws {
        let registry = try PackArtworkRegistry.loadBundled()
        #expect(registry.artworks.isEmpty)
        let resolver = PackArtworkResolver(registry: registry, directory: try Self.makeDirectory("empty-registry"))
        for product in try CatalogLoader.bundledLibrary().products {
            #expect(resolver.resolve(product: product) == .substitute(.notRegistered), "\(product.packID)")
        }
    }

    @Test("교환 후보 상품마다 자기 포장 그림이 하나씩 매핑된다 (원본에 그림이 없는 POP 2~7 제외)", .enabled(if: PackArtworkTests.registryHasArtwork))
    func bundledRegistryMapsEveryProduct() throws {
        let registry = try PackArtworkRegistry.loadBundled()
        let library = try CatalogLoader.bundledLibrary()
        let pool = try PackPool.loadBundled()
        // Bulbapedia has no picture of these league packs; they keep the
        // substitute wrapper.
        let withoutPicture: Set<String> = (2...7).map { "tpcgi-en-pop\($0)-booster" }.reduce(into: []) { $0.insert($1) }
        let products = try pool.candidates.map { candidate -> (String, String) in
            let product = try #require(library.product(id: candidate.packID))
            return (product.packID, product.setID)
        }
        #expect(products.count == CatalogTests.allEraSets)
        #expect(Set(registry.artworks.map(\.productID)) == Set(products.map(\.0)).subtracting(withoutPicture))
        for (productID, setID) in products {
            let descriptor = registry.descriptor(productID: productID, setID: setID, language: "en")
            guard !withoutPicture.contains(productID) else {
                #expect(descriptor == nil)
                continue
            }
            let found = try #require(descriptor, "\(productID) artwork missing")
            #expect(found.kind == .foilBoosterFront)
            #expect(found.file.hasSuffix(".png"))
            #expect(found.isComplete)
            #expect(found.isNormalised)
            // A booster is taller than it is wide; a logo or a box would not be.
            #expect(found.widthToHeightRatio > 0.4 && found.widthToHeightRatio < 0.72, "\(productID)")
            // Provenance must be reproducible: no signed or tokenised addresses.
            for url in [found.source.pageURL, found.source.imageURL] {
                #expect(url.hasPrefix("https://"))
                #expect(!url.contains("?"))
                #expect(!url.lowercased().contains("token"))
                #expect(!url.lowercased().contains("signature"))
            }
            #expect(found.source.rights == .unverifiedPrivateUse)
            #expect(found.source.rights.allowsRedistribution == false)
            #expect(found.unverified.isEmpty == false)
            #expect(found.matchEvidence.contains("보인다"), "무엇이 보이는지 적어야 합니다")
        }
        // One picture per product — not one picture reused.
        #expect(Set(registry.artworks.map(\.file)).count == registry.artworks.count)
        #expect(Set(registry.artworks.map(\.contentSHA256)).count == registry.artworks.count)
        #expect(Set(registry.artworks.map(\.originalSHA256)).count == registry.artworks.count)
    }

    @Test("언어·판본이 다르면 그 상품의 포장을 쓰지 않는다")
    func editionMismatchIsRejected() throws {
        let directory = try Self.makeDirectory("edition")
        let registry = Self.registry([Self.descriptor()])
        let resolver = PackArtworkResolver(registry: registry, directory: directory)

        // Same product, different language edition.
        #expect(resolver.resolve(productID: "tpcgi-en-sv01-booster", setID: "sv01", language: "ko")
            == .substitute(.editionMismatch))
        // Same product, different set (a rename that dropped the language tag).
        #expect(resolver.resolve(productID: "tpcgi-en-sv01-booster", setID: "sv02", language: "en")
            == .substitute(.editionMismatch))
        // Unregistered product of the same set.
        #expect(resolver.resolve(productID: "tpcgi-en-sv02-booster", setID: "sv02", language: "en")
            == .substitute(.notRegistered))
        // Unknown product entirely.
        #expect(resolver.resolve(productID: nil, setID: nil, language: nil) == .substitute(.productUnknown))
        #expect(resolver.resolve(product: nil) == .substitute(.productUnknown))
    }

    @Test("파일이 없으면 대체 포장으로, 있으면 실물 포장으로 판정한다")
    func resolverChecksInstalledFile() throws {
        let directory = try Self.makeDirectory("file")
        let descriptor = Self.descriptor(file: "installed.png")
        let resolver = PackArtworkResolver(registry: Self.registry([descriptor]), directory: directory)

        #expect(resolver.resolve(productID: descriptor.productID, setID: descriptor.setID, language: descriptor.language)
            == .substitute(.fileUnavailable))

        try Self.bandedPNG(width: 60, height: 110).write(to: directory.appendingPathComponent("installed.png"))
        let resolution = resolver.resolve(
            productID: descriptor.productID,
            setID: descriptor.setID,
            language: descriptor.language
        )
        #expect(resolution.isReal)
        #expect(resolution.descriptor?.artworkID == descriptor.artworkID)
        #expect(resolution.fileURL?.lastPathComponent == "installed.png")
    }

    @Test("설치 기록이 없는 항목은 등록으로 취급하지 않는다")
    func incompleteEntriesAreIgnored() throws {
        var incomplete = Self.descriptor()
        incomplete.contentSHA256 = ""
        incomplete.pixelWidth = 0
        incomplete.pixelHeight = 0
        let registry = Self.registry([incomplete])

        #expect(registry.descriptor(productID: incomplete.productID, setID: incomplete.setID, language: "en") == nil)
        #expect(registry.descriptors(productID: incomplete.productID).isEmpty)
        #expect(registry.installedArtworks.isEmpty)
    }

    // MARK: - B. Image validation

    @Test("HTML 오류 페이지와 손상 파일은 이미지로 통과하지 못한다")
    func rejectsNonImages() throws {
        let html = Data("<!DOCTYPE html><html><body>404 Not Found</body></html>".utf8)
        #expect(throws: PackArtworkValidationError.unrecognisedFormat) {
            try PackArtworkValidator.inspect(html)
        }

        var truncated = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        truncated.append(Data(repeating: 0x00, count: 512))
        #expect(throws: PackArtworkValidationError.undecodable) {
            try PackArtworkValidator.inspect(truncated)
        }
    }

    @Test("크기·픽셀 한도를 넘는 파일은 거절한다")
    func rejectsOversizeFiles() throws {
        let png = Self.bandedPNG(width: 20, height: 20)

        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.inspect(png, limits: (16, 40_000_000, 8000))
        }
        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.inspect(png, limits: (24 * 1024 * 1024, 100, 8000))
        }
        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.inspect(png, limits: (24 * 1024 * 1024, 40_000_000, 10))
        }

        // A 9000-pixel-wide image is refused from its header, before decoding.
        let wide = Self.bandedPNG(width: 9000, height: 2, bands: 1)
        #expect(throws: PackArtworkValidationError.tooManyPixels(width: 9000, height: 2, limit: 40_000_000)) {
            try PackArtworkValidator.inspect(wide)
        }
    }

    @Test("원본·설치 파일의 해시와 해상도를 대조한다")
    func verifiesHashesAndDimensions() throws {
        let png = Self.bandedPNG(width: 40, height: 80)
        let hash = PackArtworkValidator.sha256(of: png)
        let info = try PackArtworkValidator.inspect(png)
        #expect(info.format == .png)
        #expect(info.pixelWidth == 40)
        #expect(info.pixelHeight == 80)

        let verified = try PackArtworkValidator.verifyOriginal(
            png,
            expectedSHA256: hash,
            expectedWidth: 40,
            expectedHeight: 80
        )
        #expect(verified.sha256 == hash)

        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.verifyOriginal(
                png,
                expectedSHA256: String(repeating: "c", count: 64),
                expectedWidth: 40,
                expectedHeight: 80
            )
        }
        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.verifyOriginal(png, expectedSHA256: hash, expectedWidth: 41, expectedHeight: 80)
        }

        var installed = Self.descriptor()
        installed.contentSHA256 = PackArtworkValidator.sha256(of: Self.bandedPNG(width: 60, height: 110))
        installed.pixelWidth = 60
        installed.pixelHeight = 110
        let fixture = Self.bandedPNG(width: 60, height: 110)
        _ = try PackArtworkValidator.verifyInstalled(fixture, descriptor: installed)
        #expect(throws: PackArtworkValidationError.self) {
            try PackArtworkValidator.verifyInstalled(fixture, descriptor: Self.descriptor())
        }
    }

    @Test("정규화는 비율을 유지하고 긴 변을 제한한다")
    func normalisationKeepsAspectRatio() throws {
        let source = Self.bandedPNG(width: 780, height: 1429)
        let result = try PackArtworkValidator.normalise(source, maxPixelSize: 900)
        #expect(max(result.width, result.height) == 900)
        #expect(abs(Double(result.width) / Double(result.height) - 780.0 / 1429.0) < 0.002)

        let info = try PackArtworkValidator.inspect(result.data, limits: (
            PackArtworkLimits.maxInstalledBytes,
            PackArtworkLimits.maxPixelCount,
            PackArtworkLimits.maxPixelDimension
        ))
        #expect(info.pixelWidth == result.width)
        #expect(info.pixelHeight == result.height)

        // Small images are not scaled up.
        let small = try PackArtworkValidator.normalise(Self.bandedPNG(width: 20, height: 30), maxPixelSize: 900)
        #expect(small.width == 20 && small.height == 30)
    }

    // MARK: - C. Tear split

    @Test("상단 조각과 본체는 한 이미지를 겹침·틈 없이 나눈다")
    func splitCoversArtworkExactlyOnce() throws {
        let artwork = CGSize(width: 491, height: 900)
        let frame = CGSize(width: PackWrapFrame.width, height: PackWrapFrame.height)
        let geometry = PackArtworkGeometry(frame: frame, artworkSize: artwork)

        #expect(geometry.preservesArtworkAspect)
        #expect(geometry.isContinuous)
        // A tall pack is fitted by height, so it is centred with side margins.
        #expect(abs(geometry.artRect.height - frame.height) < 0.001)
        #expect(geometry.artRect.minX > 0)
        // The seam sits inside the artwork, not above it.
        #expect(geometry.seamY > geometry.artRect.minY)
        #expect(geometry.seamY < geometry.artRect.maxY)

        let rects = geometry.sourcePixelRects()
        #expect(abs(rects.strip.minY) < 0.001)
        #expect(abs(rects.strip.minX) < 0.001)
        #expect(abs(rects.strip.maxY - rects.body.minY) < 0.001)
        #expect(abs(rects.body.maxY - artwork.height) < 0.001)
        #expect(abs(rects.strip.width - artwork.width) < 0.001)
        #expect(abs(rects.body.width - artwork.width) < 0.001)

        // Both pieces are the same window width, which is what makes one scale.
        #expect(abs(geometry.stripRect.width - geometry.bodyRect.width) < 0.001)
    }

    @Test("합성 격자 포장으로 절취선 전후 인쇄가 이어진다")
    func tearSeamKeepsPrintedRowsAdjacent() throws {
        let width = 60
        let height = 220
        let data = Self.bandedPNG(width: width, height: height, bands: 11)
        let image = try #require(ImageCache.decode(data, maxPixelSize: 1000))
        #expect(image.width == width && image.height == height)
        let source = Self.rowMeans(image)
        // Orientation of the fixture itself: the blue marker is the top row and
        // the darkest band is the bottom row.
        #expect(source[0] < 5)
        #expect(source[height - 1] > 15 && source[height - 1] < 60)

        let geometry = PackArtworkGeometry(
            frame: CGSize(width: 300, height: 430),
            artworkSize: CGSize(width: width, height: height)
        )
        let rects = geometry.sourcePixelRects()
        // A rounded seam row, so the two crops are a partition of the image and
        // not overlapping by a row of rounding.
        let seamRow = Int(rects.strip.maxY.rounded())
        let strip = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: width, height: seamRow)))
        let body = try #require(image.cropping(to: CGRect(x: 0, y: seamRow, width: width, height: height - seamRow)))

        // Nothing is lost and nothing is repeated.
        #expect(strip.height + body.height == height)

        let stripRows = Self.rowMeans(strip)
        let bodyRows = Self.rowMeans(body)
        #expect(stripRows.count == strip.height)
        #expect(bodyRows.count == body.height)

        // The rows either side of the seam come from adjacent printed lines.
        #expect(abs(stripRows[stripRows.count - 1] - bodyRows[0]) < 30)
        // The strip carries the top marker and the body carries the bottom band.
        #expect(stripRows[0] < 5)
        #expect(bodyRows[bodyRows.count - 1] > 15 && bodyRows[bodyRows.count - 1] < 60)
        // And the crops match the source rows they claim to show.
        #expect(abs(stripRows[0] - source[0]) < 2)
        #expect(abs(bodyRows[bodyRows.count - 1] - source[height - 1]) < 2)
    }

    @Test("창 크기가 달라져도 비율과 절취 위치가 유지된다")
    func splitHoldsForDifferentFrames() throws {
        let artwork = CGSize(width: 491, height: 900)
        let frames = [
            CGSize(width: 300, height: 430),
            CGSize(width: 420, height: 640),
            CGSize(width: 180, height: 240),
        ]
        for frame in frames {
            let geometry = PackArtworkGeometry(frame: frame, artworkSize: artwork)
            #expect(geometry.preservesArtworkAspect)
            #expect(geometry.isContinuous)
            // The tear line is always the same fraction of the printed pack.
            let printedFraction = (geometry.seamY - geometry.artRect.minY) / geometry.artRect.height
            #expect(abs(printedFraction - PackWrapFrame.seamFraction) < 0.001)
            // The torn strip never exceeds the frame.
            #expect(geometry.stripRect.height <= frame.height)
            #expect(geometry.bodyRect.height <= frame.height)
        }
    }

    @Test("가로가 긴 그림과 빈 크기에서도 나눔이 깨지지 않는다")
    func splitHandlesDegenerateInputs() throws {
        let wide = PackArtworkGeometry(
            frame: CGSize(width: 300, height: 430),
            artworkSize: CGSize(width: 1200, height: 400)
        )
        #expect(wide.preservesArtworkAspect)
        #expect(wide.isContinuous)
        #expect(wide.artRect.minY > 0)
        #expect(wide.seamY >= wide.artRect.minY)

        let empty = PackArtworkGeometry(frame: .zero, artworkSize: .zero)
        #expect(empty.isContinuous)
        #expect(empty.stripRect.isEmpty)
    }

    // MARK: - D. Domain invariance

    @Test("포장 아트는 팩 선택과 카드 추첨에 영향을 주지 않는다")
    func artworkDoesNotChangeDraws() async throws {
        // Run A: artwork resolved (nothing installed) before the opening.
        let withArtwork = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let directory = try Self.makeDirectory("invariance")
        let resolver = PackArtworkResolver(
            registry: Self.registry([Self.descriptor(productID: "synthetic-pack-1", setID: "synth")]),
            directory: directory
        )
        let packA = try await sealedPack(withArtwork, seed: 21)
        _ = resolver.resolve(productID: "synthetic-pack-1", setID: "synth", language: "en")
        _ = resolver.resolve(productID: packA.productID, setID: "synth", language: "en")
        let openingA = try await withArtwork.openPack(instanceID: packA.id, seed: 33)

        // Run B: no artwork at all.
        let withoutArtwork = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let packB = try await sealedPack(withoutArtwork, seed: 21)
        let openingB = try await withoutArtwork.openPack(instanceID: packB.id, seed: 33)

        #expect(packA.productID == packB.productID)
        #expect(openingA.cards.map(\.cardKey) == openingB.cards.map(\.cardKey))
        #expect(openingA.cards.map(\.variant) == openingB.cards.map(\.variant))
        #expect(openingA.cards.count == openingB.cards.count)
        #expect(try await withArtwork.balance() == (try await withoutArtwork.balance()))
    }

    @Test("카탈로그 판본·해시·recipe와 가격은 그대로다")
    func catalogAndPoolUnchanged() throws {
        // The artwork registry is a separate resource; the catalogues keep the
        // hashes recorded in docs/CATALOG_VERIFICATION.md.
        let expected = [
            "tcgdex-en-sv01-20260922": "sha256:cdc1bf4c9d40e00e46710a04bf4a45db22e88560482e6e702bffebd9c0af8997",
            "tcgdex-en-sv02-20260922": "sha256:01b05007",
            "tcgdex-en-sv03-20260922": "sha256:210d8fb0",
        ]
        var seen = Set<String>()
        for url in CatalogLoader.bundledCatalogURLs() {
            let catalog = try CatalogLoader.load(contentsOf: url)
            guard let prefix = expected[catalog.catalogVersion] else { continue }
            seen.insert(catalog.catalogVersion)
            #expect(catalog.contentHash.hasPrefix(prefix))
        }
        #expect(seen.count == 3)

        // Adding SV04–SV10 (packs-v2) and every era (packs-v3) kept the first
        // three snapshots and the price exactly as they were.
        let pool = try PackPool.loadBundled()
        #expect(pool.pricePoints == 100)
        #expect(pool.candidates.count == CatalogTests.allEraSets)
        #expect(Set(pool.candidates.map(\.weight)) == [1])
        #expect(Set(pool.candidates.map(\.catalogVersion)).isSuperset(of: [
            "tcgdex-en-sv01-20260922",
            "tcgdex-en-sv02-20260922",
            "tcgdex-en-sv03-20260922",
        ]))
    }

    // MARK: - E. Storage and fallback

    @Test("이미 받은 미개봉 팩에도 같은 상품의 포장을 적용한다")
    func existingPacksResolveToArtwork() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store, seed: 7)

        let directory = try Self.makeDirectory("existing")
        let descriptor = Self.descriptor(productID: pack.productID, setID: "synth", file: "pack.png")
        let resolver = PackArtworkResolver(registry: Self.registry([descriptor]), directory: directory)
        try Self.bandedPNG(width: 60, height: 110).write(to: directory.appendingPathComponent("pack.png"))

        let resolution = resolver.resolve(productID: pack.productID, setID: "synth", language: "en")
        #expect(resolution.isReal)
        // Looking a picture up must not touch the collection.
        let packs = try await store.packInstances()
        #expect(packs.map(\.id) == [pack.id])
        #expect(packs.first?.state == .sealed)
    }

    @Test("포장 파일을 지우거나 손상시켜도 보유 팩·장부는 그대로다")
    func missingOrDamagedArtworkKeepsCollection() async throws {
        let store = try Fixtures.makeStore(catalog: Fixtures.syntheticCatalog())
        let pack = try await sealedPack(store, seed: 11)
        let opening = try await store.openPack(instanceID: pack.id, seed: 12)
        let balanceBefore = try await store.balance()
        let ownedBefore = try await store.ownedCardInstances()

        let directory = try Self.makeDirectory("damaged")
        let descriptor = Self.descriptor(productID: pack.productID, setID: "synth", file: "pack.png")
        let resolver = PackArtworkResolver(registry: Self.registry([descriptor]), directory: directory)
        let fileURL = directory.appendingPathComponent("pack.png")

        // Missing file: substitute wrapper, collection unchanged.
        #expect(resolver.resolve(productID: pack.productID, setID: "synth", language: "en")
            == .substitute(.fileUnavailable))

        // Damaged file: the cache refuses it, and the installed file is left alone.
        let cache = ImageCache(directory: try Self.makeDirectory("damaged-cache"))
        try Data("<!DOCTYPE html>".utf8).write(to: fileURL)
        let request = ImageRequest.packArtwork(descriptor: descriptor, fileURL: fileURL, size: .opening)
        #expect(await cache.image(for: request) == nil)
        #expect(await cache.isKnownFailure(request))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        #expect(try await store.balance() == balanceBefore)
        #expect(try await store.ownedCardInstances() == ownedBefore)
        #expect(try await store.opening(forPack: pack.id)?.cards == opening.cards)
        #expect(try await store.packInstances().first?.state == .opened)
    }

    private func sealedPack(_ store: PackTraceStore, seed: UInt64) async throws -> PackInstanceRecord {
        try await store.grantInitialDemoPoints()
        return try await store.exchangePack(pool: try store.testPool(), requestID: ExchangeRequestID(), seed: seed)
            .packInstance
    }
}
