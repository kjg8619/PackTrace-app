import Foundation
import PackTraceTestSupport
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// The vault's two layouts and its grouping. Temporary data root only.
@Suite("보관함 보기")
@MainActor
struct VaultScreenUITests {
    @Test("기본 보기는 팩 강조이고, 고른 보기는 다음 실행에도 유지된다")
    func layoutDefaultsToGalleryAndPersists() throws {
        let suite = "packtrace.tests.\(UUID().uuidString.lowercased())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettings(defaults: defaults)
        #expect(first.vaultLayout == .gallery)
        first.vaultLayout = .list
        #expect(AppSettings(defaults: defaults).vaultLayout == .list, "재실행해도 리스트 보기가 유지됩니다")
    }

    @Test("공개 중·미개봉·개봉 완료로 나누고, 반쯤 공개한 팩은 개봉 완료에 섞지 않는다")
    func sectionsSeparateUnfinishedOpenings() async throws {
        let root = try StoreLocation.temporary(label: "packtrace-vault-ui").directory
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = 5
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()

        var packs: [PackInstanceRecord] = []
        for _ in 0..<4 {
            packs.append(try #require(await environment.exchangeRandomPack()))
        }
        let store = try #require(environment.store)
        let finished = try await environment.openPack(packs[0].id)
        _ = try await store.setRevealedCount(openingID: finished.id, count: finished.cards.count)
        let halfway = try await environment.openPack(packs[1].id)
        _ = try await store.setRevealedCount(openingID: halfway.id, count: 3)
        await environment.refresh()

        let sections = VaultSections.make(packs: environment.allPacks, openings: environment.openings)
        #expect(sections.inProgress.map(\.id) == [packs[1].id])
        #expect(sections.completed.map(\.id) == [packs[0].id])
        #expect(Set(sections.sealed.map(\.id)) == Set([packs[2].id, packs[3].id]))
        #expect(sections.inProgress.count + sections.sealed.count + sections.completed.count == environment.allPacks.count)
    }

    @Test("팩이 없으면 비어 있다")
    func emptyVault() {
        #expect(VaultSections.make(packs: [], openings: []).isEmpty)
    }
}

/// The binder starts at one pack per set; each tile's figures are that set's.
@Suite("바인더 팩 선택")
@MainActor
struct BinderShelfUITests {
    @Test("세트마다 그 세트의 팩과 수집 현황이 있고, 합계는 전체 보유 수와 같다")
    func everySetHasItsPackAndProgress() async throws {
        let root = try StoreLocation.temporary(label: "packtrace-binder-ui").directory
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = makeIsolatedSettings()
        settings.lastProfile = .demo
        settings.testSeed = 11
        let environment = AppEnvironment(realm: .demo, locationRoot: root, settings: settings)
        await environment.bootstrap()
        for _ in 0..<3 {
            let pack = try #require(await environment.exchangeRandomPack())
            _ = try await environment.openPack(pack.id)
        }
        await environment.refresh()

        #expect(environment.setSummaries.count >= 3)
        for summary in environment.setSummaries {
            let product = try #require(environment.product(forSet: summary.setID), "\(summary.setID)의 팩이 없습니다")
            // A subset (Trainer Gallery …) is shown with its parent set's pack.
            #expect(product.setID == (environment.library?.parentSetID(of: summary.setID) ?? summary.setID))
            #expect(environment.setProgress[summary.setID] != nil)
        }
        let progress = environment.setProgress.values
        #expect(progress.reduce(0) { $0 + $1.totalCopies } == environment.collectionTotals.totalCopies)
        #expect(progress.reduce(0) { $0 + $1.ownedUniquePrints } == environment.collectionTotals.ownedUniquePrints)
        #expect(environment.collectionTotals.totalCopies > 0)

        // Opening a set loads that set's rows only.
        for summary in environment.setSummaries {
            await environment.selectBinderSet(summary.setID)
            #expect(environment.binderEntries.allSatisfy { $0.card.setID == summary.setID })
            #expect(environment.progress == environment.setProgress[summary.setID])
        }
    }

    @Test("수집률은 0으로 나누지 않고 100%를 넘지 않는다")
    func completionBounds() {
        #expect(BinderCompletion(nil).fraction == 0)
        #expect(BinderCompletion(BinderProgress(ownedUniquePrints: 0, totalPrints: 0, totalCopies: 0)).fraction == 0)
        let half = BinderCompletion(BinderProgress(ownedUniquePrints: 222, totalPrints: 444, totalCopies: 300))
        #expect(half.fraction == 0.5)
        #expect(half.percentText.hasPrefix("50"))
    }
}

/// The menu bar's wallet line.
@Suite("메뉴바 지갑 줄")
struct MenuBarWalletTests {
    @Test("잔액이 모자라면 다음 팩까지 남은 포인트, 넉넉하면 받을 수 있는 팩 수를 말한다")
    func affordance() {
        let short = PackAffordance(balance: 58, cost: 100)
        #expect(short.packsAvailable == 0)
        #expect(short.progress == 0.58)
        #expect(short.caption == "다음 팩까지 42 P")

        let enough = PackAffordance(balance: 358, cost: 100)
        #expect(enough.packsAvailable == 3)
        #expect(enough.progress == 1)
        #expect(enough.caption == "팩 3개를 받을 수 있습니다")

        #expect(PackAffordance(balance: 0, cost: 0).progress == 0, "비용 0이어도 나누지 않습니다")
        #expect(PackAffordance(balance: -5, cost: 100).caption == "다음 팩까지 100 P")
    }
}

/// Settings are split into sections instead of one long page.
@Suite("설정 구역")
@MainActor
struct SettingsSectionsUITests {
    @Test("설정은 AI 사용량 구역에서 열리고, 구역 이름은 겹치지 않는다")
    func opensOnUsage() {
        #expect(SettingsModel(section: .usage).section == .usage)
        let titles = SettingsModel.Section.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles == ["AI 사용량", "개봉", "지갑·백업", "카탈로그"])
    }
}
