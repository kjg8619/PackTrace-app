import AppKit
import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The pack picture decision, as the screens see it.
///
/// Uses the bundled registry and catalogue with fixture PNG bytes written under
/// the descriptors' file names: no publisher artwork is needed to run this, and
/// no real collection is touched.
@Suite("포장 아트 화면")
@MainActor
struct PackArtworkUITests {
    private func fixturePNG(width: Int = 32, height: Int = 64) -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    private func artworkDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("pack-artwork", isDirectory: true)
    }

    private func bootstrapped() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-artwork-ui").directory
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: makeIsolatedSettings())
        await environment.bootstrap()
        #expect(environment.loadState == .ready)
        return (environment, root)
    }

    private func product(_ environment: AppEnvironment, setID: String) throws -> PackProduct {
        // The environment's `catalog` is one snapshot; the three products live
        // across the library it was built from.
        let library = try CatalogLoader.bundledLibrary()
        return try #require(
            library.catalogs.values.flatMap(\.products).first { $0.setID == setID }
        )
    }

    /// A public checkout ships an empty registry (publisher artwork is not
    /// redistributed); the tests that install a picture for a registered
    /// product need entries.
    nonisolated static var registryHasArtwork: Bool {
        !((try? PackArtworkRegistry.loadBundled())?.artworks.isEmpty ?? true)
    }

    /// File name the registry expects for a set, so the fixture stands in the
    /// same place a real installed picture would.
    private func descriptorFile(_ environment: AppEnvironment, setID: String) throws -> String {
        let product = try product(environment, setID: setID)
        let registry = try PackArtworkRegistry.loadBundled()
        return try #require(
            registry.descriptor(productID: product.packID, setID: product.setID, language: product.language)
        ).file
    }

    @Test("설치된 상품은 실물 포장, 미설치 상품은 대체 포장으로 표시된다", .enabled(if: PackArtworkUITests.registryHasArtwork))
    func installedResolvesToRealArtworkOnly() async throws {
        let (environment, root) = try await bootstrapped()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = artworkDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixturePNG().write(to: directory.appendingPathComponent(try descriptorFile(environment, setID: "sv01")))

        let model = PackArtworkModel()
        await model.prepare(product: try product(environment, setID: "sv01"), environment: environment, size: .tile)
        #expect(model.state == .real)
        #expect(model.image != nil)
        #expect(model.descriptor?.setID == "sv01")
        #expect(model.isRetryable == false)

        let other = PackArtworkModel()
        await other.prepare(product: try product(environment, setID: "sv02"), environment: environment, size: .tile)
        #expect(other.state == .substitute(.fileUnavailable))
        #expect(other.image == nil)
        // Not installed is not a failure that a retry could fix: the file is
        // simply not there, so no retry is offered.
        #expect(other.isRetryable == false)
    }

    @Test("화면은 환경과 같은 매핑을 쓰고, 상품이 없으면 대체 포장이다", .enabled(if: PackArtworkUITests.registryHasArtwork))
    func screensShareOneMapping() async throws {
        let (environment, root) = try await bootstrapped()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = artworkDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixturePNG().write(to: directory.appendingPathComponent(try descriptorFile(environment, setID: "sv03")))

        for setID in ["sv01", "sv02", "sv03"] {
            let product = try product(environment, setID: setID)
            let model = PackArtworkModel()
            await model.prepare(product: product, environment: environment, size: .opening)
            let resolution = environment.packArtwork(for: product)
            #expect((model.state == .real) == resolution.isReal)
            #expect(model.descriptor == resolution.descriptor)
        }

        let unknown = PackArtworkModel()
        await unknown.prepare(product: nil, environment: environment, size: .tile)
        #expect(unknown.state == .substitute(.productUnknown))
        #expect(environment.packArtwork(for: nil) == .substitute(.productUnknown))
    }

    @Test("준비된 포장은 다시 결정되지 않고, 드래그 중에는 바뀌지 않는다", .enabled(if: PackArtworkUITests.registryHasArtwork))
    func preparedArtworkNeverSwapsMidScene() async throws {
        let (environment, root) = try await bootstrapped()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = artworkDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try descriptorFile(environment, setID: "sv02")
        let product = try product(environment, setID: "sv02")

        // Starts without an installed file: the substitute wrapper is decided.
        let model = PackArtworkModel()
        await model.prepare(product: product, environment: environment, size: .opening)
        #expect(model.state == .substitute(.fileUnavailable))
        let substituteImage = model.image

        // The file appears while the pack is on screen: preparing again must not
        // swap the picture, resize the pack or move the tear line.
        try fixturePNG().write(to: directory.appendingPathComponent(file))
        await model.prepare(product: product, environment: environment, size: .opening)
        #expect(model.state == .substitute(.fileUnavailable))
        #expect(model.image == substituteImage)

        // An explicit retry (a button, not a redraw) may pick it up.
        await model.retry(product: product, environment: environment, size: .opening)
        #expect(model.state == .real)
        #expect(model.image != nil)

        // Once real, further prepares keep the same picture instance.
        let firstImage = model.image
        await model.prepare(product: product, environment: environment, size: .opening)
        #expect(model.image === firstImage)
    }

    @Test("손상된 포장 파일은 대체 포장으로 보이고 재시도로 복구된다", .enabled(if: PackArtworkUITests.registryHasArtwork))
    func damagedArtworkFallsBackAndRecovers() async throws {
        let (environment, root) = try await bootstrapped()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = artworkDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try descriptorFile(environment, setID: "sv01")
        let fileURL = directory.appendingPathComponent(file)
        try Data("<!DOCTYPE html><html>error</html>".utf8).write(to: fileURL)

        let product = try product(environment, setID: "sv01")
        let model = PackArtworkModel()
        await model.prepare(product: product, environment: environment, size: .opening)
        #expect(model.state == .substitute(.fileUnavailable))
        #expect(model.isRetryable)

        // The installed file was not deleted by the failed read.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        try fixturePNG().write(to: fileURL)
        await model.retry(product: product, environment: environment, size: .opening)
        #expect(model.state == .real)
        #expect(model.isRetryable == false)
    }

    @Test("포장 이미지 상태는 팩 내용·잔액과 무관하다", .enabled(if: PackArtworkUITests.registryHasArtwork))
    func artworkStatusDoesNotChangePackContents() async throws {
        let (environment, root) = try await bootstrapped()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = artworkDirectory(root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try fixturePNG().write(to: directory.appendingPathComponent(try descriptorFile(environment, setID: "sv01")))

        let balanceBefore = environment.balance
        let pack = try #require(await environment.exchangeRandomPack())
        let product = try #require(environment.product(for: pack))
        let model = PackArtworkModel()
        await model.prepare(product: product, environment: environment, size: .tile)
        let resolution = environment.packArtwork(for: product)

        // The picture state is a presentation fact and nothing else.
        #expect(environment.balance == balanceBefore - environment.packCostPoints)
        #expect(environment.sealedPacks.contains { $0.id == pack.id })
        #expect(resolution.isReal || resolution.fallback != nil)
        if resolution.isReal {
            #expect(model.state == .real)
        } else {
            #expect(model.state == .substitute(resolution.fallback ?? .notRegistered))
        }
    }
}
