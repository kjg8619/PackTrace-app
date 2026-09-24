import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Totals and catalogue lists the screens show: every set, not whichever one
/// the binder happens to have selected or the library's newest.
@Suite("수집 요약과 카탈로그 목록")
@MainActor
struct CollectionSummaryUITests {
    private func environment() async throws -> (AppEnvironment, URL) {
        let root = try StoreLocation.temporary(label: "packtrace-summary-ui").directory
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = 11
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        return (environment, root)
    }

    @Test("오늘·메뉴의 보유 합계는 모든 세트를 더한 값이고, 바인더 세트를 바꿔도 변하지 않는다")
    func totalsCoverEverySet() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        // Open packs until cards from at least two sets are owned.
        var opened = 0
        while opened < 5, environment.balance >= environment.packCostPoints {
            let pack = try #require(await environment.exchangeRandomPack())
            _ = try await environment.openPack(pack.id)
            opened += 1
        }
        await environment.refresh()
        let owned = try #require(try await environment.store?.ownedCardInstances())
        #expect(environment.collectionTotals.totalCopies == owned.count)
        #expect(environment.collectionTotals.totalPrints == environment.setSummaries.reduce(0) { $0 + $1.prints })

        let before = environment.collectionTotals
        for set in environment.setSummaries {
            await environment.selectBinderSet(set.setID)
            #expect(environment.collectionTotals == before, "바인더 세트 선택이 전체 합계를 바꾸면 안 됩니다")
        }
        // The binder's own figure is still per set.
        let perSet = environment.progress.totalCopies
        #expect(perSet <= before.totalCopies)
    }

    @Test("카드 상세의 획득일은 환경을 거쳐 그 프린트의 기록만 읽는다")
    func acquisitionDatesForOnePrint() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = try #require(await environment.exchangeRandomPack())
        let opening = try await environment.openPack(pack.id)
        let drawn = try #require(opening.cards.first)
        let dates = try #require(await environment.acquisitionDates(of: drawn.cardKey, variant: drawn.variant))
        let copies = opening.cards.filter { $0.cardKey == drawn.cardKey && $0.variant == drawn.variant }.count
        #expect(dates.count == copies)
    }

    @Test("설정의 카탈로그와 포장 아트 목록은 모든 세트를 보여 준다")
    func settingsListEveryCatalogue() async throws {
        let (environment, root) = try await environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let versions = environment.allCatalogs.map(\.catalogVersion)
        #expect(versions.count == environment.library?.catalogs.count)
        #expect(versions == versions.sorted())
        let products = environment.allCatalogs.flatMap(\.products).map(\.packID)
        #expect(environment.packArtworkStatuses.map(\.product.packID) == products)
        #expect(products.count >= 3, "sv01·sv02·sv03 상품이 모두 보여야 합니다")
    }
}
