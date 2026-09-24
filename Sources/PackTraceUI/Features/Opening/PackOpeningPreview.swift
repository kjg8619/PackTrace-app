import Combine
import Foundation
import PackTraceCore
import SwiftUI

/// Development preview: a synthetic opening result that never touches a store.
///
/// Enabled with `PACKTRACE_OPENING_PREVIEW=1`, so the animation can be run
/// repeatedly (and compared between changes) without spending points or writing
/// to a profile. Production code paths never read this.
public enum PackOpeningPreview {
    public static let environmentKey = "PACKTRACE_OPENING_PREVIEW"
    /// Second, explicit flag: with both set the preview walks itself through the
    /// whole reveal. It never applies to a stored pack.
    public static let autoplayEnvironmentKey = "PACKTRACE_OPENING_AUTOPLAY"

    public static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    /// Whether the preview should drive itself: tear, rise, every card, summary.
    /// Needs the preview flag as well, and never applies to a stored pack.
    public static var autoplayEnabled: Bool {
        autoplayEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        flag(environmentKey, in: environment)
    }

    static func autoplayEnabled(environment: [String: String]) -> Bool {
        flag(environmentKey, in: environment) && flag(autoplayEnvironmentKey, in: environment)
    }

    /// The whole rule for a scene driving itself: the synthetic preview result,
    /// with both flags. A stored pack is never opened by autoplay, whatever the
    /// environment says.
    static func autoplayAllowed(isPreviewSource: Bool, environment: [String: String]) -> Bool {
        isPreviewSource && autoplayEnabled(environment: environment)
    }

    /// Third flag, for measuring: with the preview on, every state change is
    /// written to stderr with the time since the scene started. Never applies to
    /// a stored pack.
    public static let traceEnvironmentKey = "PACKTRACE_OPENING_TRACE"

    static func traceEnabled(environment: [String: String]) -> Bool {
        flag(environmentKey, in: environment) && flag(traceEnvironmentKey, in: environment)
    }

    private static func flag(_ key: String, in environment: [String: String]) -> Bool {
        let value = environment[key]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    public struct Card: Sendable, Hashable {
        public var position: Int
        public var cardKey: CardKey
        public var variant: CardVariant
        public var isNew: Bool
    }

    public struct Result: Sendable, Identifiable {
        public var id = UUID()
        public var catalogVersion: String
        public var recipeVersion: Int
        public var product: PackProduct?
        public var cards: [Card]
    }

    /// A ten-card result taken from the bundled catalogues: the first card of
    /// every rarity tier the catalogue has, so rare reveals can be looked at
    /// without waiting for one to drop.
    public static func makeResult(library: CatalogLibrary) -> Result? {
        // The catalogue covering the most animation tiers first, then the most
        // rarity names (with every era shipped, name order would start at a
        // 5-card special set), then name order so the result is stable.
        func coverage(_ catalog: PackCatalog) -> (Int, Int) {
            (Set(catalog.cards.map { RarityAnimationProfile.tier(for: $0.rarity) }).count, Set(catalog.cards.map(\.rarity)).count)
        }
        let ordered = library.catalogs.values.sorted {
            let left = coverage($0)
            let right = coverage($1)
            return left != right ? left > right : $0.catalogVersion < $1.catalogVersion
        }
        var chosen: [Card] = []
        var seenRarities = Set<String>()
        for catalog in ordered {
            for card in catalog.cards where !seenRarities.contains(card.rarity.rawValue) {
                seenRarities.insert(card.rarity.rawValue)
                chosen.append(Card(position: chosen.count, cardKey: card.key, variant: .normal, isNew: true))
            }
            if chosen.count >= 10 { break }
        }
        guard !chosen.isEmpty else { return nil }

        // Fill up to ten with the catalogue's first cards so the stack looks real.
        if let catalog = ordered.first {
            for card in catalog.cards where chosen.count < 10 {
                chosen.append(Card(position: chosen.count, cardKey: card.key, variant: .normal, isNew: false))
            }
            return Result(
                catalogVersion: catalog.catalogVersion,
                recipeVersion: catalog.recipes.first?.version ?? 1,
                product: catalog.products.first,
                cards: chosen
            )
        }
        return nil
    }
}

/// Scene state holder.
///
/// Uses `ObservableObject` rather than `@State`: this machine builds with the
/// Command Line Tools only, where the `SwiftUIMacros` plugin behind `@State` is
/// not installed (see docs/TOOLCHAIN.md).
@MainActor
final class PackOpeningSceneModel: ObservableObject {
    @Published private(set) var engine: PackOpeningEngine?
    @Published private(set) var loadError: String?
    /// Sounds for this opening; follows the engine's semantic state only.
    private var sound: OpeningSoundDirector?
    /// Development preview measurement only (`PACKTRACE_OPENING_TRACE`).
    private var trace: AnyCancellable?

    /// Builds the engine for one opening, once.
    func prepare(
        source: PackOpeningScene.Source,
        environment: AppEnvironment,
        skipsAnimations: Bool
    ) async {
        guard engine == nil else { return }
        let timing: PackOpeningTiming = skipsAnimations ? .instant : .standard

        switch source {
        case let .preview(result):
            let cards = cards(for: result, environment: environment)
            let engine = PackOpeningEngine(
                presentation: PackOpeningPresentation(
                    openingID: nil,
                    packID: nil,
                    productName: result.product?.name ?? "미리보기 팩",
                    catalogVersion: result.catalogVersion,
                    recipeVersion: result.recipeVersion,
                    product: result.product,
                    cards: cards,
                    revealedCount: 0,
                    isPreview: true
                ),
                openPack: nil,
                resolveCards: { _ in cards },
                reveal: PreviewOpeningReveal(total: cards.count),
                timing: timing
            )
            begin(engine, environment: environment)

        case let .stored(pack):
            if let existing = environment.opening(for: pack) {
                let resolved = await Self.resolve(existing, environment: environment)
                guard !resolved.isEmpty || existing.cards.isEmpty else {
                    loadError = "카드 정보를 불러오지 못했습니다. 카탈로그 판본 \(pack.catalogVersion)을 확인하세요."
                    return
                }
                let engine = PackOpeningEngine(
                    presentation: PackOpeningPresentation(
                        openingID: existing.id,
                        packID: pack.id,
                        productName: environment.product(for: pack)?.name ?? pack.productID,
                        catalogVersion: pack.catalogVersion,
                        recipeVersion: pack.recipeVersion,
                        product: environment.product(for: pack),
                        cards: resolved,
                        revealedCount: existing.revealedCount
                    ),
                    openPack: nil,
                    resolveCards: { record in
                        await Self.resolve(record, environment: environment)
                    },
                    reveal: StoreOpeningReveal(environment: environment, openingID: existing.id),
                    timing: timing
                )
                begin(engine, environment: environment)
                return
            }

            // A sealed pack: the draw is committed when the user tears it.
            let engine = PackOpeningEngine(
                presentation: PackOpeningPresentation(
                    openingID: nil,
                    packID: pack.id,
                    productName: environment.product(for: pack)?.name ?? pack.productID,
                    catalogVersion: pack.catalogVersion,
                    recipeVersion: pack.recipeVersion,
                    product: environment.product(for: pack),
                    cards: [],
                    revealedCount: 0
                ),
                openPack: { [environment] in
                    try? await environment.openPack(pack.id)
                },
                resolveCards: { record in
                    await Self.resolve(record, environment: environment)
                },
                reveal: PreviewOpeningReveal(total: 0),
                revealAfterOpen: { [environment] record in
                    StoreOpeningReveal(environment: environment, openingID: record.id)
                },
                timing: timing
            )
            begin(engine, environment: environment)
        }
    }

    func cancel() {
        engine?.cancelAll()
        sound?.detach()
    }

    /// Hands the engine to the views and starts it. The sound director is
    /// attached first, so it hears the very first transition.
    private func begin(_ engine: PackOpeningEngine, environment: AppEnvironment) {
        let settings = environment.settings
        let sound = OpeningSoundDirector(
            timing: engine.timing,
            isEnabled: { [weak settings] in settings?.soundEnabled ?? false },
            output: { OpeningSoundPlayer.shared }
        )
        sound.attach(to: engine)
        self.sound = sound
        if engine.isPreview, PackOpeningPreview.traceEnabled(environment: ProcessInfo.processInfo.environment) {
            trace = Self.trace(engine)
        }
        self.engine = engine
        engine.start()
    }

    /// One line per state change: `[opening-trace] <ms> <state>`.
    private static func trace(_ engine: PackOpeningEngine) -> AnyCancellable {
        OpeningTrace.markStart()
        return engine.$state.sink { state in
            MainActor.assumeIsolated { OpeningTrace.log(state.name) }
        }
    }

    /// Cards for a stored opening: the draw is already decided, so this only adds
    /// artwork metadata and which prints are new.
    static func resolve(
        _ record: OpeningRecord,
        environment: AppEnvironment
    ) async -> [PackOpeningCard] {
        let firstTime = await environment.firstTimePrintKeys(openingID: record.id)
        return record.cards.compactMap { drawn in
            guard let definition = environment.card(for: drawn.cardKey) else { return nil }
            let key = "\(drawn.cardKey.rawValue)#\(drawn.variant.rawValue)"
            return PackOpeningCard(
                position: drawn.position,
                card: definition,
                variant: drawn.variant,
                isNew: firstTime.contains(key)
            )
        }
    }

    private func cards(
        for result: PackOpeningPreview.Result,
        environment: AppEnvironment
    ) -> [PackOpeningCard] {
        result.cards.compactMap { entry in
            guard let definition = environment.card(for: entry.cardKey) else { return nil }
            return PackOpeningCard(
                position: entry.position,
                card: definition,
                variant: entry.variant,
                isNew: entry.isNew
            )
        }
    }
}

/// Measurement lines for the development preview (`PACKTRACE_OPENING_PREVIEW`
/// and `PACKTRACE_OPENING_TRACE` both set): `[opening-trace] <ms> <event>` on
/// stderr, with the time since the preview scene started. Off in every normal
/// run, and a stored pack never turns it on.
@MainActor
enum OpeningTrace {
    static let isEnabled = PackOpeningPreview.traceEnabled(environment: ProcessInfo.processInfo.environment)
    private static var start = ContinuousClock.now

    static func markStart() {
        start = ContinuousClock.now
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func log(_ event: String) {
        guard isEnabled else { return }
        let line = "[opening-trace] \(milliseconds(ContinuousClock.now - start)) \(event)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
