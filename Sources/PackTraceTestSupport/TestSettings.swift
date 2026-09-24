import Foundation
import PackTraceUI

/// Settings backed by a throwaway UserDefaults suite, so tests never read or
/// write the developer's real preferences (including the last used profile).
@MainActor
public func makeIsolatedSettings() -> AppSettings {
    let suite = "packtrace.tests.\(UUID().uuidString.lowercased())"
    return AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
}

import PackTraceCore

public extension PackTraceStore {
    /// Pool over every catalogue this store was built with. Test convenience:
    /// production code resolves its pool from the bundled pool resource.
    nonisolated func testPool(poolVersion: String = "test-pool") throws -> ResolvedPackPool {
        let library = self.library
        let pool = PackPool(
            poolVersion: poolVersion,
            pricePoints: economy.packCostPoints,
            economyVersion: economy.version,
            note: "test pool over the store's catalogues",
            candidates: library.catalogs.values.sorted { $0.catalogVersion < $1.catalogVersion }.flatMap { catalog in
                catalog.products.map {
                    PackPoolCandidate(packID: $0.packID, catalogVersion: catalog.catalogVersion, weight: 1)
                }
            }
        )
        return try ResolvedPackPool.resolve(pool: pool, library: library)
    }
}
