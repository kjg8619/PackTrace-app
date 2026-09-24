import PackTraceCore
import SwiftUI

/// View-local state for the binder: which set is open, the filter and the
/// enlarged card. No set is open when the binder is shown: it starts at the
/// shelf of packs.
@MainActor
final class BinderModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, owned, missing
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "전체"
            case .owned: "보유"
            case .missing: "미보유"
            }
        }
    }

    @Published var openedSetID: String?
    @Published var filter: Filter = .all
    @Published var selected: BinderEntry?
    /// Series the viewer opened or closed on the shelf. Until then the newest
    /// series and any series with a card in it start open.
    @Published var seriesOverrides: [String: Bool] = [:]
    /// Card search across every set; results replace the shelf while the
    /// query has text.
    @Published var query = ""
    @Published var results: [BinderEntry] = []
    @Published var resultTotal = 0

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Owned share of a set's supported prints, for labels and bars.
struct BinderCompletion: Equatable {
    var owned: Int
    var total: Int

    init(_ progress: BinderProgress?) {
        owned = progress?.ownedUniquePrints ?? 0
        total = progress?.totalPrints ?? 0
    }

    var fraction: Double { total > 0 ? min(1, Double(owned) / Double(total)) : 0 }

    var percentText: String {
        (fraction * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

struct BinderView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: BinderModel

    /// `startingSet` opens straight into one set's page (the set's rows must
    /// already be selected); otherwise the binder starts at the shelf.
    init(startingSet: String? = nil, startingQuery: String = "") {
        let model = BinderModel()
        model.openedSetID = startingSet
        model.query = startingQuery
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            if let setID = model.openedSetID {
                BinderSetPage(setID: setID, model: model)
            } else {
                BinderShelf(model: model)
            }
        }
        .sheet(item: $model.selected) { entry in
            BinderCardDetail(entry: entry)
                .environmentObject(environment)
                .environmentObject(environment.settings)
        }
    }
}

/// The binder's first screen: one pack per set, with how much of it is
/// collected. Choosing a pack opens that set's cards.
private struct BinderShelf: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: BinderModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("바인더")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text(summaryLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkMuted)
                }
                searchField
                if model.isSearching {
                    BinderSearchResults(model: model)
                } else if environment.seriesGroups.count > 1 {
                    let groups = environment.seriesGroups
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        seriesSection(group, isNewest: index == 0)
                    }
                } else {
                    grid(environment.seriesGroups.first?.setIDs ?? environment.setSummaries.map(\.setID))
                }
                if environment.setSummaries.isEmpty {
                    Text("카탈로그를 불러오지 못해 표시할 세트가 없습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                }
            }
            .padding(22)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.inkMuted)
            TextField("모든 세트에서 카드 찾기 · 이름, 세트, 번호 (예: pikachu, sv01 025)", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if model.isSearching {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.inkMuted)
                .help("검색 지우기")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hairline, lineWidth: 1))
        // A short pause after typing, then one search (every set is ~20k cards).
        .task(id: "\(model.query)|\(environment.collectionTotals.totalCopies)") {
            guard model.isSearching else {
                model.results = []
                model.resultTotal = 0
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await environment.searchCards(model.query)
            guard !Task.isCancelled else { return }
            model.results = found.entries
            model.resultTotal = found.total
        }
    }

    private func grid(_ setIDs: [String]) -> some View {
        let summaries = Dictionary(environment.setSummaries.map { ($0.setID, $0) }, uniquingKeysWith: { first, _ in first })
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190, maximum: 230), spacing: 20, alignment: .top)],
            alignment: .leading,
            spacing: 24
        ) {
            ForEach(setIDs.compactMap { summaries[$0] }) { summary in
                BinderSetTile(summary: summary) {
                    Task { await open(summary.setID) }
                }
            }
        }
    }

    private func seriesSection(_ group: SeriesGroup, isNewest: Bool) -> some View {
        var owned = 0
        var total = 0
        for setID in group.setIDs {
            owned += environment.setProgress[setID]?.ownedUniquePrints ?? 0
            total += environment.setProgress[setID]?.totalPrints ?? 0
        }
        let expanded = model.seriesOverrides[group.id] ?? (isNewest || owned > 0)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                model.seriesOverrides[group.id] = !expanded
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Palette.inkMuted)
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("세트 \(group.setIDs.count) · 수집 \(owned)/\(total)")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name) 시리즈, 세트 \(group.setIDs.count)개, \(expanded ? "펼침" : "접힘")")
            if expanded {
                grid(group.setIDs)
            }
        }
    }

    private var summaryLine: String {
        let totals = environment.collectionTotals
        return "팩을 고르면 그 세트의 카드 바인더가 열립니다 · 전체 고유 프린트 \(totals.ownedUniquePrints)/\(totals.totalPrints) · 누적 \(totals.totalCopies)장"
    }

    /// Loads the set's rows before switching, so the page never shows the
    /// previous set's cards under the new title.
    private func open(_ setID: String) async {
        await environment.selectBinderSet(setID)
        model.filter = .all
        model.openedSetID = setID
    }
}

private struct BinderSetTile: View {
    @EnvironmentObject private var environment: AppEnvironment
    let summary: SetSummary
    let action: () -> Void

    var body: some View {
        let completion = BinderCompletion(environment.setProgress[summary.setID])
        let copies = environment.setProgress[summary.setID]?.totalCopies ?? 0
        // A subset (Trainer Gallery, Shiny Vault …) has no pack of its own and
        // is shown with its set's pack, so it says so instead of looking like
        // the same set twice.
        let parent = environment.library?.parentSetID(of: summary.setID)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                PackArtworkView(product: environment.product(forSet: summary.setID), size: .tile)
                    .frame(width: 150, height: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(parent == nil ? 1 : 0.55)
                    .overlay(alignment: .bottom) {
                        if parent != nil {
                            Text("서브세트")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Palette.panelRaised))
                                .overlay(Capsule().stroke(Palette.accent.opacity(0.6), lineWidth: 1))
                                .foregroundStyle(Palette.accent)
                                .padding(.bottom, 12)
                        }
                    }
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(summary.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // One line: the name gives way, not the id
                        // ("SWSH12.5GG" broke in two on a narrow tile).
                        BadgeView(text: summary.setID.uppercased(), color: Palette.accent)
                            .fixedSize()
                    }
                    if let parent {
                        Text("\(environment.setInfo(for: parent)?.name ?? parent.uppercased()) 팩에서 나옴")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                            .lineLimit(1)
                    }
                    ProgressView(value: completion.fraction)
                        .tint(completion.owned > 0 ? Palette.success : Palette.inkMuted)
                    HStack(spacing: 6) {
                        Text("수집 \(completion.owned)/\(completion.total) · \(completion.percentText)")
                            .help("보유 고유 프린트 / 이 세트의 앱 지원 프린트")
                        Spacer(minLength: 0)
                        Text("누적 \(copies)장")
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.name) 바인더, 고유 프린트 \(completion.owned)/\(completion.total)")
    }
}

/// Cards from every set matching the shelf's search, with each card's set.
private struct BinderSearchResults: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var model: BinderModel

    private var visible: [BinderEntry] {
        switch model.filter {
        case .all: model.results
        case .owned: model.results.filter { $0.quantity > 0 }
        case .missing: model.results.filter { $0.quantity == 0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(model.resultTotal > model.results.count
                     ? "찾은 프린트 \(model.resultTotal.formatted())개 중 처음 \(model.results.count)개"
                     : "찾은 프린트 \(model.resultTotal.formatted())개")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
                Picker("", selection: $model.filter) {
                    ForEach(BinderModel.Filter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .labelsHidden()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126, maximum: 160), spacing: 14)], spacing: 16) {
                ForEach(visible) { entry in
                    Button {
                        model.selected = entry
                    } label: {
                        VStack(spacing: 6) {
                            CardFaceView(
                                card: entry.card,
                                variant: entry.variant,
                                quantity: entry.quantity > 0 ? entry.quantity : nil,
                                stars: CardMastery.stars(copies: entry.quantity)
                            )
                            .opacity(entry.quantity > 0 ? 1 : 0.42)
                            // The card's caption has the set id and number;
                            // the set's name says which set that is.
                            Text(environment.setInfo(for: entry.card.setID)?.name ?? entry.card.setID.uppercased())
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inkMuted)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if visible.isEmpty {
                Text(model.results.isEmpty ? "찾는 카드가 없습니다." : "이 조건에 맞는 카드가 없습니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
            }
        }
    }
}

/// One set's cards, with a way back to the shelf.
private struct BinderSetPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    let setID: String
    @ObservedObject var model: BinderModel

    private var visibleEntries: [BinderEntry] {
        switch model.filter {
        case .all: environment.binderEntries
        case .owned: environment.binderEntries.filter { $0.quantity > 0 }
        case .missing: environment.binderEntries.filter { $0.quantity == 0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.hairline)
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 126, maximum: 160), spacing: 14)],
                    spacing: 16
                ) {
                    ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            model.selected = entry
                        } label: {
                            CardFaceView(
                                card: entry.card,
                                variant: entry.variant,
                                quantity: entry.quantity > 0 ? entry.quantity : nil,
                                stars: CardMastery.stars(copies: entry.quantity)
                            )
                            .opacity(entry.quantity > 0 ? 1 : 0.42)
                            .overlay(alignment: .topLeading) {
                                if entry.quantity == 0 {
                                    BadgeView(text: "미보유", color: Palette.inkMuted)
                                        .padding(6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        // Warm the next few rows so scrolling does not wait on the network.
                        .task(id: entry.id) {
                            await prefetch(around: index)
                        }
                    }
                }
                .padding(22)
                if visibleEntries.isEmpty {
                    Text(model.filter == .owned ? "이 세트에서 아직 모은 카드가 없습니다." : "표시할 카드가 없습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                        .padding(.horizontal, 22)
                }
            }
        }
    }

    /// Fetches the thumbnails the user is about to scroll into view. The cache
    /// coalesces and skips anything already decoded, so this is cheap to repeat.
    private func prefetch(around index: Int) async {
        guard let cache = environment.imageCache else { return }
        let window = visibleEntries.dropFirst(index + 1).prefix(8)
        guard !window.isEmpty else { return }
        let urls = window.filter { CardImageURL.hasImage($0.card) }.map { CardImageURL.url(for: $0.card, quality: .thumbnail) }
        await cache.prefetch(urls, quality: .thumbnail)
    }

    private var header: some View {
        let summary = environment.setSummaries.first { $0.setID == setID }
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.openedSetID = nil
            } label: {
                Label("모든 팩", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.accent)
            .keyboardShortcut(.cancelAction)

            HStack(alignment: .center, spacing: 14) {
                PackThumbnail(product: environment.product(forSet: setID), width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(summary?.name ?? setID.uppercased())
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Palette.ink)
                        BadgeView(text: setID.uppercased(), color: Palette.accent)
                    }
                    Text(completionLine(summary))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 0)
                Picker("", selection: $model.filter) {
                    ForEach(BinderModel.Filter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
        .padding(22)
    }

    /// Counts are per set and describe the app's supported prints (primary plus
    /// reverse where the data has one), never the total physical print run.
    private func completionLine(_ summary: SetSummary?) -> String {
        let progress = environment.progress
        let completion = BinderCompletion(progress)
        var line = "보유 고유 프린트 \(completion.owned)/\(completion.total) (\(completion.percentText)) · 누적 \(progress.totalCopies)장"
        if let summary {
            line += " · 카드 \(summary.cards)장 · 앱 지원 프린트 \(summary.prints)"
        }
        if let info = environment.setInfo(for: setID) {
            line += " · TCGdex \(info.externalSetID) \(info.language.uppercased())"
        }
        return line
    }
}

struct BinderCardDetail: View {
    let entry: BinderEntry

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = DetailModel()

    @MainActor
    final class DetailModel: ObservableObject {
        @Published var acquiredDates: [Date] = []
        @Published var datesUnavailable = false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            CardArtworkView(
                card: entry.card,
                quality: .full,
                cornerRadius: 12,
                fallbackQuality: .thumbnail,
                allowsRetry: true
            )
            .frame(width: 320)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.card.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        BadgeView(text: entry.card.rarity.displayName, color: Palette.rarityColor(entry.card.rarity))
                        BadgeView(text: entry.variant.displayName, color: Palette.accent)
                        BadgeView(
                            text: "\(entry.card.setID.uppercased()) \(entry.card.localID)",
                            color: Palette.inkMuted
                        )
                    }
                }
                infoRow(label: "보유 수량", value: "\(entry.quantity)장")
                infoRow(label: "별", value: starLine)
                infoRow(
                    label: "획득일",
                    value: model.datesUnavailable
                        ? "획득 기록을 읽지 못했습니다"
                        : model.acquiredDates.isEmpty
                            ? (entry.quantity > 0 ? entry.firstAcquiredAt.packTraceDay : "-")
                            : model.acquiredDates.map(\.packTraceDay).joined(separator: ", ")
                )
                infoRow(label: "변형 가능", value: entry.card.variants.map(\.displayName).joined(separator: ", "))
                infoRow(label: "이미지 URL", value: CardImageURL.url(for: entry.card, quality: .full))
                Spacer(minLength: 0)
                HStack {
                    Button("닫기") { dismiss() }
                    Spacer()
                    Text(entry.quantity > 0 ? "이미 소유한 카드입니다" : "아직 보유하지 않은 카드입니다")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                }
            }
            .frame(width: 320, alignment: .leading)
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 500)
        .background(Palette.backdrop)
        .task {
            // Through the environment, like every other read: the view does not
            // talk to the store, and a failure is shown rather than read as "none".
            if let dates = await environment.acquisitionDates(of: entry.card.key, variant: entry.variant) {
                model.acquiredDates = dates
                model.datesUnavailable = false
            } else {
                model.datesUnavailable = true
            }
        }
    }

    /// Stars come from duplicate copies of this print; nothing is consumed.
    private var starLine: String {
        let stars = CardMastery.stars(copies: entry.quantity)
        let filled = String(repeating: "★", count: stars) + String(repeating: "☆", count: CardMastery.maxStars - stars)
        guard let next = CardMastery.copiesToNextStar(copies: entry.quantity) else { return "\(filled) · 최대" }
        return "\(filled) · 다음 별까지 \(next)장"
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
