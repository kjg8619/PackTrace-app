import Foundation

/// One exchange candidate: a real pack product pinned to the catalogue snapshot
/// that carries its card list and recipe.
public struct PackPoolCandidate: Sendable, Hashable, Codable {
    public var packID: String
    public var catalogVersion: String
    /// Relative weight. All shipping candidates use 1.
    public var weight: Int
    /// Series the product belongs to (a TCGdex series id such as `sv`), used
    /// by a series-uniform pool. Absent in packs-v1/v2.
    public var series: String?

    public init(packID: String, catalogVersion: String, weight: Int, series: String? = nil) {
        self.packID = packID
        self.catalogVersion = catalogVersion
        self.weight = weight
        self.series = series
    }
}

/// How a pool picks a candidate.
public enum PoolSelection: String, Sendable, Hashable, Codable {
    /// One draw over all candidates by weight (packs-v1, packs-v2).
    case weighted
    /// First a series, every series equally likely; then a candidate inside it
    /// by weight. A series with many sets does not crowd out one with few.
    case seriesUniform = "series-uniform"
}

/// A series as the pool presents it.
public struct PoolSeries: Sendable, Hashable, Codable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Immutable list of products a random pack can be drawn from.
///
/// The pool is a *snapshot*: it names the catalogue version each candidate was
/// verified against, so refreshing a catalogue cannot change what an already
/// received pack opens into. Changing the pool only affects future exchanges.
public struct PackPool: Sendable, Hashable, Codable {
    public var poolVersion: String
    public var pricePoints: Int
    public var economyVersion: Int
    public var note: String
    public var candidates: [PackPoolCandidate]
    /// Absent means `.weighted`.
    public var selection: PoolSelection?
    /// Series in presentation order (oldest first). Required for a
    /// series-uniform pool.
    public var series: [PoolSeries]?

    public init(
        poolVersion: String,
        pricePoints: Int,
        economyVersion: Int,
        note: String,
        candidates: [PackPoolCandidate],
        selection: PoolSelection? = nil,
        series: [PoolSeries]? = nil
    ) {
        self.poolVersion = poolVersion
        self.pricePoints = pricePoints
        self.economyVersion = economyVersion
        self.note = note
        self.candidates = candidates
        self.selection = selection
        self.series = series
    }

    /// Relative file name inside the bundled resources.
    public static let bundledFileName = "pool-v3.json"

    /// The active pool, or an earlier one still shipped (`pool-v2.json`) for
    /// checking that older draws are unchanged.
    public static func loadBundled(fileName: String = bundledFileName) throws -> PackPool {
        guard let url = Bundle.module.url(
            forResource: "pool/\(fileName)",
            withExtension: nil
        ) ?? Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "pool") else {
            throw PackTraceError.poolNotFound(fileName)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(PackPool.self, from: data)
        } catch {
            throw PackTraceError.storage("pool decode failed: \(error)")
        }
    }
}

/// A pool whose candidates were all resolved against real catalogue data.
/// Exchange uses only this type, so a pool with a broken candidate can never
/// pay out a pack that cannot be opened.
public struct ResolvedPackPool: Sendable {
    public struct Candidate: Sendable, Hashable {
        public var product: PackProduct
        public var catalogVersion: String
        public var catalogHash: String
        public var recipe: PackRecipe
        public var weight: Int
        /// Prints this product can actually hand out.
        public var supportedPrintCount: Int
        public var series: String?
    }

    public var poolVersion: String
    public var pricePoints: Int
    public var candidates: [Candidate]
    public var selection: PoolSelection = .weighted
    /// Series in presentation order; empty for a weighted pool.
    public var series: [PoolSeries] = []
    /// Stable order used for deterministic selection: packID ascending.
    public var orderedPackIDs: [String]

    public var totalWeight: Int {
        candidates.reduce(0) { $0 + $1.weight }
    }

    public func probability(of packID: String) -> Double {
        guard totalWeight > 0, let candidate = candidates.first(where: { $0.product.packID == packID }) else {
            return 0
        }
        switch selection {
        case .weighted:
            return Double(candidate.weight) / Double(totalWeight)
        case .seriesUniform:
            let members = candidates.filter { $0.series == candidate.series }
            let inSeries = members.reduce(0) { $0 + $1.weight }
            guard inSeries > 0, !series.isEmpty else { return 0 }
            return 1 / Double(series.count) * Double(candidate.weight) / Double(inSeries)
        }
    }

    /// Chance of drawing any pack from one series.
    public func probability(ofSeries id: String) -> Double {
        // Exactly 1/S when series are drawn uniformly: summing the members'
        // shares instead left floating-point error that rounded one series
        // to 6.3 % and the rest to 6.2 %.
        if selection == .seriesUniform, candidates.contains(where: { $0.series == id }), !series.isEmpty {
            return 1 / Double(series.count)
        }
        return candidates.filter { $0.series == id }.reduce(0) { $0 + probability(of: $1.product.packID) }
    }

    public func candidate(for packID: String) -> Candidate? {
        candidates.first { $0.product.packID == packID }
    }

    /// Resolves every candidate against the catalogue library. Any missing
    /// product, missing recipe, unrewardable verification status or empty
    /// weight fails the whole pool — candidates are never silently dropped.
    public static func resolve(pool: PackPool, library: CatalogLibrary) throws -> ResolvedPackPool {
        guard !pool.candidates.isEmpty else { throw PackTraceError.packPoolEmpty(poolVersion: pool.poolVersion) }
        var seen = Set<String>()
        var resolved: [Candidate] = []
        for candidate in pool.candidates {
            guard seen.insert(candidate.packID).inserted else {
                throw PackTraceError.poolInvalid(poolVersion: pool.poolVersion, reason: "duplicate candidate \(candidate.packID)")
            }
            guard candidate.weight > 0 else {
                throw PackTraceError.poolInvalid(poolVersion: pool.poolVersion, reason: "non-positive weight for \(candidate.packID)")
            }
            guard let catalog = library.catalog(version: candidate.catalogVersion) else {
                throw PackTraceError.poolInvalid(
                    poolVersion: pool.poolVersion,
                    reason: "missing catalog \(candidate.catalogVersion) for \(candidate.packID)"
                )
            }
            guard let product = catalog.product(id: candidate.packID) else {
                throw PackTraceError.poolInvalid(
                    poolVersion: pool.poolVersion,
                    reason: "missing product \(candidate.packID) in \(candidate.catalogVersion)"
                )
            }
            guard product.isRewardEligible else {
                throw PackTraceError.poolInvalid(
                    poolVersion: pool.poolVersion,
                    reason: "\(candidate.packID) verification status is \(product.verification.status.displayName)"
                )
            }
            guard let recipe = catalog.recipe(id: product.recipeID) else {
                throw PackTraceError.poolInvalid(
                    poolVersion: pool.poolVersion,
                    reason: "missing recipe \(product.recipeID) for \(candidate.packID)"
                )
            }
            try CatalogBuilder.validate(catalog)
            let prints = catalog.cards.filter { recipe.setIDs.contains($0.setID) }.reduce(0) { $0 + $1.supportedVariants.count }
            resolved.append(
                Candidate(
                    product: product,
                    catalogVersion: catalog.catalogVersion,
                    catalogHash: catalog.contentHash,
                    recipe: recipe,
                    weight: candidate.weight,
                    supportedPrintCount: prints,
                    series: candidate.series
                )
            )
        }
        let selection = pool.selection ?? .weighted
        var series: [PoolSeries] = []
        if selection == .seriesUniform {
            series = pool.series ?? []
            let declared = Set(series.map(\.id))
            guard !series.isEmpty, declared.count == series.count else {
                throw PackTraceError.poolInvalid(poolVersion: pool.poolVersion, reason: "series list missing or repeated")
            }
            for candidate in resolved {
                guard let id = candidate.series, declared.contains(id) else {
                    throw PackTraceError.poolInvalid(poolVersion: pool.poolVersion, reason: "\(candidate.product.packID) has no declared series")
                }
            }
            // Every declared series has to be drawable, or its share is lost.
            for entry in series where !resolved.contains(where: { $0.series == entry.id }) {
                throw PackTraceError.poolInvalid(poolVersion: pool.poolVersion, reason: "series \(entry.id) has no candidate")
            }
        }
        return ResolvedPackPool(
            poolVersion: pool.poolVersion,
            pricePoints: pool.pricePoints,
            candidates: resolved.sorted { $0.product.packID < $1.product.packID },
            selection: selection,
            series: series,
            orderedPackIDs: resolved.map(\.product.packID).sorted()
        )
    }

    /// Uniform pick by weight with rejection sampling, so the distribution is
    /// exact and no modulo bias creeps in. Drawable candidates are counted by
    /// *product*, never by artwork or card count.
    public func pick(seed: UInt64) throws -> Candidate {
        var generator = SplitMix64(seed: seed)
        var drawable = candidates
        if selection == .seriesUniform {
            // First the series, uniformly, in the declared order; then the
            // candidate inside it by weight, from the same generator.
            guard !series.isEmpty else { throw PackTraceError.packPoolEmpty(poolVersion: poolVersion) }
            let chosen = series[Int(generator.next(upperBound: UInt64(series.count)))].id
            drawable = candidates.filter { $0.series == chosen }
        }
        let total = UInt64(drawable.reduce(0) { $0 + $1.weight })
        guard total > 0 else { throw PackTraceError.packPoolEmpty(poolVersion: poolVersion) }
        let draw = generator.next(upperBound: total)
        var cumulative: UInt64 = 0
        for candidate in drawable {
            cumulative += UInt64(candidate.weight)
            if draw < cumulative {
                return candidate
            }
        }
        // Unreachable while weights are positive; returning the last candidate
        // keeps the contract total.
        guard let last = drawable.last else { throw PackTraceError.packPoolEmpty(poolVersion: poolVersion) }
        return last
    }
}
