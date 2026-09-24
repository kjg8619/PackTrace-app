import PackTraceCore
import SwiftUI

/// Which part of the settings is shown. The page used to be one long scroll
/// of ten panels; each section now holds the panels that belong together.
@MainActor
final class SettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case usage, opening, wallet, catalog

        var id: String { rawValue }

        var title: String {
            switch self {
            case .usage: "AI 사용량"
            case .opening: "개봉"
            case .wallet: "지갑·백업"
            case .catalog: "카탈로그"
            }
        }
    }

    @Published var section: Section

    init(section: Section) {
        self.section = section
    }
}

struct SettingsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: SettingsModel

    /// Opens on AI usage, which is what the "도구 연결" links elsewhere lead to.
    init(section: SettingsModel.Section = .usage) {
        _model = StateObject(wrappedValue: SettingsModel(section: section))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text("설정")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Picker("구역", selection: $model.section) {
                    ForEach(SettingsModel.Section.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider().overlay(Palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.section {
                    case .usage:
                        // Collection as a whole, then every tool in one
                        // list; OMP is a row like the others and none of them
                        // gates the others.
                        UsageOverviewSection()
                        AIToolsSection()
                    case .opening:
                        OpeningOptionsSection(settings: environment.settings)
                    case .wallet:
                        ProfileSection()
                        rulesPanel
                        walletPanel
                        BackupSection()
                    case .catalog:
                        catalogPanel
                        artworkPanel
                    }
                }
                .padding(22)
            }
        }
    }

    private var rulesPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "보상·교환 규칙 (v\(environment.store?.economy.version ?? PackEconomy.v1.version))",
                    subtitle: "값은 앱의 밸런스 시작값이며 실제 AI 비용이나 토큰 가치가 아닙니다."
                )
                ruleRow("랜덤팩 교환", "\(environment.packCostPoints) P")
                ruleRow("개발용 최초 지급", "\(environment.store?.economy.initialDemoGrantPoints ?? 0) P (demo 지갑, 1회)")
                ruleRow(
                    "AI 사용량 적립",
                    "비캐시 입력 + 출력 \(environment.usage.tokensPerPoint.formatted()) 토큰 = 1 P · 실사용 지갑 · 연결 뒤 사용량만"
                )
                ruleRow("팩 내부 배합", "앱 자체 시뮬레이션 (공식 봉입 확률 아님)")
                ruleRow("업적 보상", "업적마다 한 번 10~200 P · 끝까지 공개한 팩만 셈 · 이 프로필 지갑")
                ruleRow("중복 카드", "같은 프린트 2·3·5·8·12장에서 별 1~5개 · 카드를 소모하지 않음")
            }
        }
    }

    private var catalogPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "카탈로그",
                    subtitle: "팩 교환 시점의 판본·recipe를 팩에 고정합니다. 카탈로그가 바뀌어도 이미 받은 팩은 원래 버전으로 개봉됩니다."
                )
                if let first = environment.allCatalogs.first {
                    let catalogs = environment.allCatalogs
                    ruleRow("수록", "카탈로그 \(catalogs.count)개 · 세트 \(environment.setSummaries.count)개 · 카드 \(catalogs.reduce(0) { $0 + $1.cards.count })장")
                    // Every set the app can hand out, by series; a flat list
                    // of every era would bury the rest of the settings.
                    ForEach(catalogGroups(catalogs), id: \.group.id) { entry in
                        DetailsDisclosure(title: "\(entry.group.name) · 카탈로그 \(entry.catalogs.count)개") {
                            ForEach(entry.catalogs, id: \.catalogVersion) { catalog in
                                catalogRow(catalog)
                                Divider().overlay(Palette.hairline)
                            }
                        }
                    }
                    ruleRow("출처", "\(first.sourceName) \(first.sourceURL)")
                    Text("팩 내부 배합은 모두 PackTrace 자체 시뮬레이션입니다. 세트마다 근거와 한계가 다르며, 각 카탈로그의 \u{201C}판본·해시·레시피\u{201D}에 적었습니다.")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    // The catalogue's note describes the substitute wrapper, so
                    // it only applies while some pack is still shown with one.
                    if environment.packArtworkStatuses.contains(where: { !$0.resolution.isReal }) {
                        Text(first.products.first?.artworkSubstitute.note ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("카탈로그를 불러오지 못했습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                }
            }
        }
    }


    /// Catalogues under the series of their set, in the order the screens
    /// use; a snapshot whose set is in no group lands in the last one.
    private func catalogGroups(_ catalogs: [PackCatalog]) -> [(group: SeriesGroup, catalogs: [PackCatalog])] {
        let groups = environment.seriesGroups.isEmpty
            ? [SeriesGroup(id: SeriesGroup.otherID, name: "전체 세트", setIDs: [])]
            : environment.seriesGroups
        var result = groups.map { (group: $0, catalogs: [PackCatalog]()) }
        for catalog in catalogs.sorted(by: { $0.catalogVersion > $1.catalogVersion }) {
            let index = result.firstIndex { $0.group.setIDs.contains(catalog.set.externalSetID) } ?? result.count - 1
            result[index].catalogs.append(catalog)
        }
        return result.filter { !$0.catalogs.isEmpty }
    }

    private func catalogRow(_ catalog: PackCatalog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(catalog.set.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                BadgeView(text: catalog.set.externalSetID.uppercased(), color: Palette.accent)
                Text("카드 \(catalog.cards.count)장 · 공식 번호 \(catalog.set.officialCardCount)장 · \(catalog.set.language.uppercased())")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
                Spacer(minLength: 0)
                ForEach(catalog.products, id: \.packID) { product in
                    BadgeView(text: "검증 \(product.verification.status.displayName)", color: Palette.inkMuted)
                }
            }
            DetailsDisclosure(title: "판본·해시·레시피") {
                ruleRow("판본", catalog.catalogVersion)
                ruleRow("수집 시각", catalog.fetchedAt)
                ruleRow("내용 해시", catalog.contentHash)
                if let subsets = catalog.subsets, !subsets.isEmpty {
                    ruleRow("함께 든 세트", subsets.map { "\($0.name) (\($0.externalSetID.uppercased()))" }.joined(separator: ", "))
                }
                ForEach(catalog.products, id: \.packID) { product in
                    ruleRow("상품", product.packID)
                }
                ForEach(catalog.recipes, id: \.recipeID) { recipe in
                    ruleRow("레시피", "\(recipe.recipeID) v\(recipe.version) · \(recipe.packSize)장 · 슬롯 \(recipe.slots.count)개")
                    Text(recipe.disclaimer)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private typealias ArtworkEntry = (product: PackProduct, resolution: PackArtworkResolution)

    private func artworkGroups(_ entries: [ArtworkEntry]) -> [(name: String, entries: [ArtworkEntry])] {
        let groups = environment.seriesGroups
        guard groups.count > 1 else { return [(name: "전체 팩", entries: entries)] }
        var result = groups.map { (name: $0.name, setIDs: $0.setIDs, entries: [ArtworkEntry]()) }
        for entry in entries {
            let index = result.firstIndex { $0.setIDs.contains(entry.product.setID) } ?? result.count - 1
            result[index].entries.append(entry)
        }
        return result.filter { !$0.entries.isEmpty }.map { (name: $0.name, entries: $0.entries) }
    }

    private func artworkRow(_ entry: ArtworkEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            PackArtworkView(product: entry.product, size: .tile)
                .frame(width: 26, height: 47)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.setInfo(for: entry.product.setID)?.name ?? entry.product.packID)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if let descriptor = entry.resolution.descriptor {
                    Text("실제 포장 이미지 · \(descriptor.pixelWidth)x\(descriptor.pixelHeight) · 권리 \(descriptor.source.rights.displayName)")
                        .help("\(descriptor.displayName) · \(descriptor.source.publisher) · \(descriptor.source.retrievedAt) 확인 · \(descriptor.source.pageURL)")
                } else if let fallback = entry.resolution.fallback {
                    Text("대체 포장으로 표시 중 · \(fallback.displayMessage)")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 0)
        }
    }

    private var artworkPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "팩 포장 이미지",
                    subtitle: "실제 은박 부스터 정면 그림입니다. 별도 준비 명령으로 설치하며, 없거나 읽을 수 없으면 대체 포장으로 표시합니다. 그림 상태는 팩 내용·추첨·기록에 영향을 주지 않습니다."
                )
                if let resolver = environment.artworkResolver {
                    ruleRow(
                        "레지스트리",
                        "v\(resolver.registry.registryVersion) · 등록 \(resolver.registry.artworks.count)종 · \(resolver.directory.path)"
                    )
                } else {
                    ruleRow("레지스트리", "읽을 수 없음 · 모든 팩이 대체 포장")
                }
                let statuses = environment.packArtworkStatuses
                ruleRow("상태", "실제 포장 \(statuses.filter { $0.resolution.isReal }.count)종 · 대체 포장 \(statuses.filter { !$0.resolution.isReal }.count)종")
                ForEach(artworkGroups(statuses), id: \.name) { group in
                    DetailsDisclosure(title: "\(group.name) · \(group.entries.count)종") {
                        ForEach(group.entries, id: \.product.packID) { entry in
                            artworkRow(entry)
                        }
                    }
                }
                Text("설치·갱신: ./scripts/fetch-pack-artwork.sh · 설치 검사: ./scripts/fetch-pack-artwork.sh verify")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
                    .textSelection(.enabled)
                Text("이미지 파일은 로컬에만 보관하며 Git·원격에 올리지 않습니다. 아트워크 권리는 각 publisher에 있습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var walletPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: environment.profile == .demo ? "지갑 (demo)" : "지갑 (production)",
                    subtitle: "개발용 지갑과 실사용 지갑은 서로 다른 데이터베이스를 씁니다. 잔액은 장부 합계와 항상 일치합니다."
                )
                ruleRow("현재 잔액", "\(environment.balance) P")
                ruleRow("장부 합계", "\(environment.ledger.reduce(0) { $0 + $1.deltaPoints }) P (최근 \(environment.ledger.count)건)")
                ruleRow("이미지 캐시", "\(environment.imageStats.diskEntries)개 · \(environment.imageStats.diskBytes / 1024) KB")
                HStack {
                    Button("이미지 캐시 비우기") {
                        Task { await environment.clearImageCache() }
                    }
                    .controlSize(.small)
                    Button("데이터 새로고침") {
                        Task { await environment.refresh() }
                    }
                    .controlSize(.small)
                }
                Divider().overlay(Palette.hairline)
                Text("장부 내역")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                ForEach(environment.ledger.prefix(12)) { entry in
                    HStack(spacing: 8) {
                        Text(entry.createdAt.packTraceDisplay)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Palette.inkMuted)
                        Text(entry.reason.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.ink)
                        Spacer(minLength: 0)
                        Text(entry.deltaPoints > 0 ? "+\(entry.deltaPoints) P" : "\(entry.deltaPoints) P")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(entry.deltaPoints > 0 ? Palette.success : Palette.accentWarm)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func ruleRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Opening options. Presentation only: the stored pack result never depends on
/// these switches.
struct OpeningOptionsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "개봉 옵션",
                    subtitle: "표시 방식만 바뀝니다. 저장된 카드 결과는 어떤 설정에서도 동일합니다."
                )
                Toggle("빠르게 열기 (연출 생략)", isOn: $settings.fastOpen)
                Toggle("모션 줄이기", isOn: $settings.reduceMotion)
                Toggle("소리", isOn: $settings.soundEnabled)
                Text("팩을 뜯고 카드를 넘길 때 짧은 효과음을 냅니다. 모든 효과음은 PackTrace용으로 직접 합성한 소리이며, 모션 줄이기를 켜도 소리는 이 설정을 따릅니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                Text("키보드: Space로 뜯기/다음 카드, Esc로 닫기. 접근성 설정에서도 동일한 카드 결과를 얻습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
        }
    }
}
