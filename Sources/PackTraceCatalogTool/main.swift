import Foundation
import ImageIO
import PackTraceCore

/// Command line tool that turns the reviewed product definitions in
/// `catalog-sources/` plus live TCGdex data into a pinned catalogue snapshot.
@main
struct CatalogTool {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            print(usage)
            exit(2)
        }
        let flags = parseFlags(Array(arguments.dropFirst()))

        switch command {
        case "fetch":
            let productsPath = flags["--products"] ?? "catalog-sources/sv01.json"
            let productsURL = URL(fileURLWithPath: productsPath)
            let source = try ProductSourceFile.load(contentsOf: productsURL)
            let version = flags["--version"]
                ?? "\(source.catalogVersionPrefix)-\(Self.dayStamp())"
            let outputPath = flags["--out"]
                ?? "Sources/PackTraceCore/Resources/catalog/\(version).json"
            // A snapshot packs are pinned to is never replaced in place: a sealed
            // pack would open against different cards. Refuse when the file, or
            // another file in the same directory with this catalogue version,
            // already exists, unless the caller says so explicitly.
            if flags["--force"] == nil {
                try Self.refuseExistingVersion(version, output: URL(fileURLWithPath: outputPath))
            }
            let fetcher = CatalogFetcher()
            let result = try await fetcher.run(
                options: CatalogFetcher.Options(
                    productsFile: productsURL,
                    outputURL: URL(fileURLWithPath: outputPath),
                    catalogVersion: version,
                    concurrency: Int(flags["--concurrency"] ?? "") ?? 6,
                    verifyAssets: flags["--no-asset-check"] == nil
                ),
                log: { print($0) }
            )
            print("cards: \(result.cardCount)")
            print("catalogVersion: \(result.catalog.catalogVersion)")
            print("contentHash: \(result.catalog.contentHash)")

        case "verify":
            guard let path = flags["--catalog"] else {
                throw ToolError.missingFlag("--catalog")
            }
            let catalog = try CatalogLoader.load(contentsOf: URL(fileURLWithPath: path))
            try CatalogBuilder.validate(catalog)
            print("catalogVersion: \(catalog.catalogVersion)")
            print("contentHash: \(catalog.contentHash) (verified)")
            print("set: \(catalog.set.name) [\(catalog.set.externalSetID)] \(catalog.set.language), \(catalog.cards.count) cards")
            let withoutArt = catalog.cards.filter { !CardImageURL.hasImage($0) }.count
            let evidence = Dictionary(grouping: catalog.cards.compactMap(\.printEvidence), by: { $0 }).mapValues(\.count)
            print("cards without artwork: \(withoutArt) · print evidence: \(evidence.isEmpty ? "source flags" : evidence.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

            for recipe in catalog.recipes {
                let total = recipe.slots.reduce(0) { $0 + $1.count }
                print("recipe \(recipe.recipeID) v\(recipe.version): \(total) cards")
                for (index, slot) in recipe.slots.enumerated() {
                    let pool = recipe.pool(for: slot, in: catalog)
                    print("  slot \(index): \(slot.count)x rarities=\(slot.selector.rarities.map(\.rawValue).joined(separator: "/")) rule=\(slot.variantRule.rawValue) pool=\(pool.count)")
                }
            }
            for recipe in catalog.recipes {
                // The sets the recipe declares: its own and any subset its
                // slots name. A card from anywhere else is a mistake.
                let sets = Set(recipe.setIDs)
                var reachable = Set<String>()
                for slot in recipe.slots {
                    for card in recipe.pool(for: slot, in: catalog) {
                        for variant in card.supportedVariants {
                            if slot.variantRule == .reverse, variant != .reverse { continue }
                            if slot.variantRule == .primary, variant != card.primaryVariant { continue }
                            if slot.variantRule == .reverseIfAvailableElsePrimary,
                               variant != (card.variants.contains(.reverse) ? .reverse : card.primaryVariant) { continue }
                            reachable.insert("\(card.key.rawValue)#\(variant.rawValue)")
                        }
                    }
                }
                var targets: [String] = []
                for card in catalog.cards {
                    for variant in card.supportedVariants {
                        targets.append("\(card.key.rawValue)#\(variant.rawValue)")
                    }
                }
                let unreachable = targets.filter { !reachable.contains($0) }
                let mixed = catalog.cards.filter { !sets.contains($0.setID) }
                print("recipe \(recipe.recipeID) coverage: sets=\(sets.sorted().joined(separator: ",")) targets=\(targets.count) reachable=\(reachable.count) unreachable=\(unreachable.count) foreign-set-cards=\(mixed.count)")
                if !unreachable.isEmpty {
                    print("  unreachable sample: \(unreachable.prefix(3).joined(separator: " "))")
                }
            }

            for product in catalog.products {
                print("product \(product.packID): \(product.verification.status.displayName), recipe \(product.recipeID), eligible=\(product.isRewardEligible)")
                for evidence in product.verification.evidence {
                    print("  evidence[\(evidence.kind)] \(evidence.claim) <- \(evidence.source) \(evidence.url) (\(evidence.checkedAt))")
                }
                for item in product.verification.unverified {
                    print("  unverified: \(item.item) - \(item.note)")
                }
            }

        case "draw":
            guard let path = flags["--catalog"] else {
                throw ToolError.missingFlag("--catalog")
            }
            let catalog = try CatalogLoader.load(contentsOf: URL(fileURLWithPath: path))
            guard let recipe = catalog.recipes.first else {
                throw ToolError.missingFlag("recipe in catalog")
            }
            let seed = UInt64(flags["--seed"] ?? "") ?? 1
            let cards = try PackDrawer.draw(recipe: recipe, catalog: catalog, seed: seed)
            let byKey = Dictionary(uniqueKeysWithValues: catalog.cards.map { ($0.key, $0) })
            print("seed \(seed) -> \(cards.count) cards")
            for card in cards {
                let definition = byKey[card.cardKey]
                print("  \(card.position) slot\(card.slotIndex) \(definition?.localID ?? "?") \(definition?.name ?? "?") [\(definition?.rarity.rawValue ?? "?")] \(card.variant.rawValue)")
            }

        case "pool":
            let poolPath = flags["--pool"] ?? "Sources/PackTraceCore/Resources/pool/pool-v3.json"
            guard let catalogDir = flags["--catalogs"] else {
                throw ToolError.missingFlag("--catalogs")
            }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: catalogDir),
                includingPropertiesForKeys: nil
            )) ?? []
            let catalogs = try urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { try CatalogLoader.load(contentsOf: $0) }
            let library = try CatalogLibrary(catalogs: catalogs)
            let data = try Data(contentsOf: URL(fileURLWithPath: poolPath))
            let pool = try JSONDecoder().decode(PackPool.self, from: data)
            let resolved = try ResolvedPackPool.resolve(pool: pool, library: library)
            print("pool: \(resolved.poolVersion) price=\(resolved.pricePoints) candidates=\(resolved.candidates.count) catalogs=\(catalogs.count)")
            for candidate in resolved.candidates {
                print("  \(candidate.product.packID) set=\(candidate.product.setID) catalog=\(candidate.catalogVersion) recipe=v\(candidate.recipe.version) weight=\(candidate.weight) prints=\(candidate.supportedPrintCount) probability=\(String(format: "%.4f", resolved.probability(of: candidate.product.packID)))")
            }

        case "images":
            guard let path = flags["--catalog"] else {
                throw ToolError.missingFlag("--catalog")
            }
            let catalog = try CatalogLoader.load(contentsOf: URL(fileURLWithPath: path))
            let concurrency = Int(flags["--concurrency"] ?? "") ?? 4
            let quality = flags["--quality"] ?? "low"
            let sample = Int(flags["--sample"] ?? "") ?? 0
            let cards = sample > 0 ? Array(catalog.cards.prefix(sample)) : catalog.cards
            let report = await checkImages(cards: cards, quality: quality, concurrency: concurrency)
            print("catalog: \(catalog.catalogVersion) cards=\(catalog.cards.count) checked=\(report.checked)")
            print("images: http200=\(report.ok) decoded=\(report.decoded) failed=\(report.failed) notChecked=\(catalog.cards.count - report.checked)")
            if !report.failures.isEmpty {
                print("failures: \(report.failures.prefix(10).joined(separator: " "))")
            }

        case "artwork":
            let mode = (arguments.count > 1 && !arguments[1].hasPrefix("--")) ? arguments[1] : "verify"
            var artworkFlags = flags
            artworkFlags.removeValue(forKey: mode)
            try await ArtworkTool.run(mode: mode, flags: artworkFlags, log: { print($0) })

        case "usage":
            let mode = (arguments.count > 1 && !arguments[1].hasPrefix("--")) ? arguments[1] : "status"
            var usageFlags = flags
            usageFlags.removeValue(forKey: mode)
            try await UsageTool.run(mode: mode, flags: usageFlags, log: { print($0) })

        case "list":
            for url in CatalogLoader.bundledCatalogURLs() {
                print(url.lastPathComponent)
            }

        default:
            print(usage)
            exit(2)
        }
    }

    static let usage = """
    usage: packtrace-catalog <command> [flags]

      fetch   [--products catalog-sources/sv01.json] [--version v] [--out path] [--force]
              [--concurrency 6] [--no-asset-check]
      verify  --catalog <snapshot.json>
      images  --catalog <snapshot.json> [--quality low|high] [--sample N] [--concurrency 4]
              Decodes each card image; run explicitly, not on every build.
      pool    --catalogs <dir> [--pool Resources/pool/pool-v2.json]
              Resolves the exchange pool against local snapshots; fails on any
              broken candidate instead of dropping it.
      draw    --catalog <snapshot.json> [--seed 1]
      artwork fetch  [--directory <dir>] [--manifest <path>] [--write-manifest]
              Downloads the registered pack artwork, checks the bytes against the
              registry (format, decode, hash, pixels), normalises the size and
              installs it locally. Run explicitly; never during a build.
      artwork verify [--directory <dir>] [--manifest <path>]
              Checks the installed files against the registry. No network.
      artwork list   [--manifest <path>]
      usage list|status                     감지된 도구와 이 프로필의 연결·누적 인정량
      usage connect  --tool codex|claude-code|opencode|pi|omo|senpi|hermes|grok|kimi [--root <dir>]
              도구를 실사용 지갑에 연결한다. 연결 시점이 기준선이므로 이전 기록은
              소급 지급되지 않는다.
      usage disconnect --tool <tool>        연결 해제(다른 도구는 그대로)
      list
    """

    static func parseFlags(_ arguments: [String]) -> [String: String] {
        var flags: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    flags[argument] = arguments[index + 1]
                    index += 2
                } else {
                    flags[argument] = ""
                    index += 1
                }
            } else {
                index += 1
            }
        }
        return flags
    }

    struct ImageReport {
        var checked = 0
        var ok = 0
        var decoded = 0
        var failed = 0
        var failures: [String] = []
    }

    /// Maps every card image through a small thread pool and requires the
    /// response to be a decodable image, so an HTML error page served with
    /// HTTP 200 cannot pass as a valid asset.
    static func checkImages(cards: [CardDefinition], quality: String, concurrency: Int) async -> ImageReport {
        var report = ImageReport()
        await withTaskGroup(of: (String, Bool, Bool).self) { group in
            var index = 0
            var running = 0
            let limit = max(1, min(concurrency, 8))
            while index < limit, index < cards.count {
                let card = cards[index]
                group.addTask { await probeImage(card: card, quality: quality) }
                index += 1
                running += 1
            }
            while let (id, httpOK, decoded) = await group.next() {
                report.checked += 1
                if httpOK { report.ok += 1 }
                if decoded { report.decoded += 1 }
                if !decoded {
                    report.failed += 1
                    if report.failures.count < 20 { report.failures.append(id) }
                }
                if index < cards.count {
                    let card = cards[index]
                    group.addTask { await probeImage(card: card, quality: quality) }
                    index += 1
                } else {
                    _ = running
                }
            }
        }
        return report
    }

    static func probeImage(card: CardDefinition, quality: String) async -> (String, Bool, Bool) {
        let url = "\(card.imageBaseURL)/\(quality).webp"
        guard let parsed = URL(string: url) else { return (card.localID, false, false) }
        var request = URLRequest(url: parsed)
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return (card.localID, false, false) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0
        else { return (card.localID, true, false) }
        return (card.localID, true, true)
    }

    static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: Date())
    }

    enum ToolError: Error, CustomStringConvertible {
        case missingFlag(String)
        case versionExists(String, String)

        var description: String {
            switch self {
            case let .missingFlag(name): "missing required flag \(name)"
            case let .versionExists(version, path):
                "catalogue \(version) already exists at \(path); pass a new --version (or --force to replace a snapshot no pack uses)"
            }
        }
    }

    static func refuseExistingVersion(_ version: String, output: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: output.path) {
            throw ToolError.versionExists(version, output.path)
        }
        let siblings = (try? manager.contentsOfDirectory(at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        for file in siblings where file.pathExtension == "json" {
            if let existing = try? CatalogLoader.load(contentsOf: file), existing.catalogVersion == version {
                throw ToolError.versionExists(version, file.path)
            }
        }
    }
}
