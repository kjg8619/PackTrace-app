import Foundation
import PackTraceCore

/// Where reveal progress is persisted while the animation plays.
///
/// The scene never writes to the database itself: the engine asks this for the
/// next stored count, so the animation's states and the stored result stay in
/// the same order (the result is committed before it is shown).
@MainActor
public protocol PackOpeningRevealing {
    /// Stores `count` revealed cards and reports whether the write succeeded.
    func reveal(upTo count: Int) async -> Bool
}

/// Reveal sink backed by the real store, through `AppEnvironment`.
@MainActor
public struct StoreOpeningReveal: PackOpeningRevealing {
    private let environment: AppEnvironment
    private let openingID: OpeningID

    public init(environment: AppEnvironment, openingID: OpeningID) {
        self.environment = environment
        self.openingID = openingID
    }

    public func reveal(upTo count: Int) async -> Bool {
        guard var record = environment.openings.first(where: { $0.id == openingID }) else { return false }
        guard count > record.revealedCount else { return true }
        if count >= record.cards.count {
            return await environment.revealAll(record) != nil
        }
        // One stored step at a time keeps `revealed_count` the source of truth.
        while record.revealedCount < count {
            guard let next = await environment.revealNext(record) else { return false }
            record = next
        }
        return true
    }
}

/// Reveal sink for the development preview and for tests: nothing is stored.
@MainActor
public final class PreviewOpeningReveal: PackOpeningRevealing {
    public private(set) var revealedCount = 0
    private let total: Int

    public init(total: Int) {
        self.total = total
    }

    public func reveal(upTo count: Int) async -> Bool {
        revealedCount = min(max(count, revealedCount), total)
        return true
    }
}
