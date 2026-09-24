import AppKit
import Foundation
import PackTraceTestSupport
import SwiftUI
import Testing

@testable import PackTraceCore
@testable import PackTraceUI

/// Every achievement has a badge of its own.
@Suite("업적 배지")
@MainActor
struct AchievementBadgeTests {
    private func catalogAndSets() throws -> (AchievementCatalog, [String]) {
        let library = try CatalogLoader.bundledLibrary()
        let sets = library.setIDs
        // Every era's first-pull achievement, whether or not a shipped set has
        // that rarity yet.
        let catalog = AchievementCatalog.v1(
            sets: sets.map { ($0, library.setInfo(for: $0)?.name ?? $0) },
            rarities: Set(AchievementCatalog.eraPulls.map { CardRarity(rawValue: $0.rarity) })
        )
        #expect(catalog.definitions.contains { $0.id == "pull.mega-hyper-rare" })
        return (catalog, sets)
    }

    @Test("모든 업적의 배지가 서로 다르다 (모양·테두리·색·그림·표기의 조합)")
    func everyBadgeIsDistinct() throws {
        let (catalog, sets) = try catalogAndSets()
        let specs = catalog.definitions.map { AchievementBadgeSpec.make(for: $0, setOrder: sets) }
        #expect(specs.count == catalog.definitions.count)
        #expect(Set(specs).count == specs.count, "같은 배지를 쓰는 업적이 있습니다")
        // Inside one category the glyph and label alone already tell them apart,
        // so two badges never differ only by colour.
        for category in AchievementCategory.allCases {
            let marks = catalog.definitions.filter { $0.category == category }
                .map { AchievementBadgeSpec.make(for: $0, setOrder: sets) }
                .map { "\($0.glyph)|\($0.label)" }
            #expect(Set(marks).count == marks.count, "\(category.displayName) 안에서 그림·표기가 겹칩니다")
        }
    }

    @Test("모양은 분류를, 테두리 금속은 보상 크기를 따른다")
    func shapeFollowsCategoryAndMetalFollowsReward() throws {
        let (catalog, sets) = try catalogAndSets()
        let expected: [AchievementCategory: AchievementBadgeSpec.Shape] = [
            .packs: .medal, .pulls: .gem, .collection: .hexagon, .sets: .shield, .stars: .star, .usage: .chip,
        ]
        for definition in catalog.definitions {
            let spec = AchievementBadgeSpec.make(for: definition, setOrder: sets)
            #expect(spec.shape == expected[definition.category], "\(definition.id)")
            #expect(spec.metal == .forReward(definition.rewardPoints))
        }
        let byReward = catalog.definitions.sorted { $0.rewardPoints < $1.rewardPoints }
            .map { AchievementBadgeSpec.make(for: $0, setOrder: sets).metal }
        #expect(byReward == byReward.sorted(), "보상이 클수록 테두리가 같거나 더 귀해야 합니다")
        // Each set's shield has its own colour.
        let shields = catalog.definitions.filter { $0.category == .sets && $0.id.hasSuffix(".100") }
            .map { AchievementBadgeSpec.make(for: $0, setOrder: sets).tint }
        #expect(Set(shields).count == sets.count)
    }

    @Test("배지 전체 렌더(옵트인)", .enabled(if: RenderProbeTests.directory != nil))
    func renderAllBadges() async throws {
        let (catalog, sets) = try catalogAndSets()
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(AchievementCategory.allCases, id: \.self) { category in
                let items = catalog.definitions.filter { $0.category == category }
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 10), alignment: .leading, spacing: 8) {
                        ForEach(items) { definition in
                            VStack(spacing: 3) {
                                AchievementBadgeView(spec: .make(for: definition, setOrder: sets), unlocked: true, size: 56)
                                Text(definition.title).font(.system(size: 8)).foregroundStyle(Palette.inkMuted).lineLimit(2).multilineTextAlignment(.center)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 16) {
                Text("잠김 예시").font(.system(size: 11)).foregroundStyle(Palette.inkMuted)
                ForEach([0.0, 0.3, 0.8], id: \.self) { fraction in
                    AchievementBadgeView(spec: .make(for: catalog.definitions[1], setOrder: sets), unlocked: false, progress: fraction, size: 56)
                }
            }
        }
        .padding(16)
        .background(Palette.backdrop)
        try ScreenProbeTests.write(try await ScreenProbeTests.snapshot(view, size: CGSize(width: 900, height: 900)), "badges-all")
    }
}
