import PackTraceCore
import SwiftUI

/// View-local state for the exchange flow. Kept out of the view struct so no
/// property-wrapper macros are needed (see docs/TOOLCHAIN.md).
@MainActor
final class TodayModel: ObservableObject {
    enum ExchangeState: Equatable {
        case idle
        case working
        case failed(String)

        var isWorking: Bool { self == .working }
    }

    @Published var exchangeState: ExchangeState = .idle
    @Published var lastPack: PackInstanceRecord?
    /// Series rows opened in the candidate list.
    @Published var expandedSeries: Set<String> = []

    func exchange(environment: AppEnvironment) async {
        exchangeState = .working
        if let pack = await environment.exchangeRandomPack() {
            lastPack = pack
            exchangeState = .idle
        } else {
            exchangeState = .failed(environment.lastActionError ?? "알 수 없는 오류")
            environment.lastActionError = nil
        }
    }
}

struct TodayView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = TodayModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let opening = environment.unfinishedOpenings.first {
                    resumeBanner(opening)
                }
                packPanel
                TodayUsagePanel()
                collectionRow
                footnote
            }
            .padding(22)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("오늘")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Palette.ink)
            Text("AI 사용량으로 모은 포인트로 팩을 받고, 직접 뜯어서 바인더에 넣습니다.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkMuted)
        }
    }

    private func resumeBanner(_ opening: OpeningRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Palette.accentWarm)
            VStack(alignment: .leading, spacing: 2) {
                Text("공개 중이던 팩이 있습니다 · \(opening.revealedCount)/\(opening.cards.count)장")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("저장된 결과를 그대로 이어서 보여줍니다")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button("이어서 공개") { environment.requestOpening(packID: opening.packInstanceID) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accentWarm.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accentWarm.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Getting a pack

    /// The balance, how far the next pack is, the button, and the packs the
    /// draw picks from. Candidates describe the draw; they are not a shop.
    private var packPanel: some View {
        let affordance = PackAffordance(balance: environment.balance, cost: environment.packCostPoints)
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("잔액")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.inkMuted)
                            BadgeView(
                                text: environment.profile == .demo ? "개발용 지갑 · demo" : "실사용 지갑",
                                color: environment.profile == .demo ? Palette.demoBadge : Palette.success
                            )
                        }
                        Text("\(environment.balance) P")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()
                        ProgressView(value: affordance.progress)
                            .tint(affordance.packsAvailable > 0 ? Palette.success : Palette.accent)
                            .frame(maxWidth: 260)
                        Text(affordance.caption)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.inkMuted)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            Task { await model.exchange(environment: environment) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.exchangeState.isWorking {
                                    ProgressView().controlSize(.small)
                                }
                                Text(model.exchangeState.isWorking ? "교환 중…" : "랜덤팩 받기 · \(environment.packCostPoints) P")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            model.exchangeState.isWorking
                                || environment.balance < environment.packCostPoints
                                || environment.candidateSummary.isEmpty
                        )
                        Text(environment.balance < environment.packCostPoints
                            ? "포인트 부족 · \(environment.packCostPoints - environment.balance) P 더 필요"
                            : "받은 뒤 잔액 \(environment.balance - environment.packCostPoints) P")
                            .font(.system(size: 10))
                            .foregroundStyle(environment.balance < environment.packCostPoints ? Palette.accentWarm : Palette.inkMuted)
                    }
                }

                Divider().overlay(Palette.hairline)
                candidates

                if let poolError = environment.poolError {
                    NoticeBanner(
                        title: "팩 후보 데이터 미준비",
                        message: "\(poolError)\n차감하지 않았습니다. 카탈로그·레시피가 모두 유효해야 교환할 수 있습니다.",
                        color: Palette.accentWarm,
                        icon: "tray"
                    )
                }
                if case let .failed(message) = model.exchangeState {
                    NoticeBanner(
                        title: "교환 실패 · 저장소 오류",
                        message: "\(message)\n차감과 팩 지급은 한 트랜잭션이라 일부만 반영되지 않았습니다.",
                        color: Palette.danger,
                        icon: "exclamationmark.triangle"
                    )
                }
                if let notice = environment.lastGrantNotice {
                    NoticeBanner(title: "개발용 포인트 지급", message: notice, color: Palette.demoBadge, icon: "gift")
                }
                if let pack = model.lastPack {
                    grantedPanel(pack)
                }
            }
        }
    }

    @ViewBuilder
    private var candidates: some View {
        if environment.candidateSummary.isEmpty {
            NoticeBanner(
                title: "팩 데이터 미준비",
                message: "교환 가능한 팩 상품이 카탈로그에 없습니다. 저장소 오류와는 다른 상태입니다.",
                color: Palette.accentWarm,
                icon: "tray"
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(drawRule)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                if let pool = environment.pool, pool.selection == .seriesUniform {
                    seriesCandidates(pool)
                } else {
                    candidateGrid(environment.candidateSummary)
                }
            }
        }
    }

    private typealias Candidate = (product: PackProduct, probability: Double, catalogVersion: String, recipeVersion: Int)

    private func candidateGrid(_ candidates: [Candidate]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(candidates, id: \.product.packID) { candidate in
                candidateTile(candidate.product, probability: candidate.probability, catalogVersion: candidate.catalogVersion, recipeVersion: candidate.recipeVersion)
            }
        }
    }

    /// One row per series, newest first; a row opens to the packs in it. With
    /// every era in the pool a flat grid would be a hundred tiles.
    private func seriesCandidates(_ pool: ResolvedPackPool) -> some View {
        let summary = environment.candidateSummary
        let seriesOf = Dictionary(pool.candidates.map { ($0.product.packID, $0.series ?? "") }, uniquingKeysWith: { first, _ in first })
        let release = { (candidate: Candidate) in environment.setInfo(for: candidate.product.setID)?.releaseDate ?? "" }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(pool.series.reversed(), id: \.id) { series in
                let members = summary
                    .filter { seriesOf[$0.product.packID] == series.id }
                    .sorted { (release($0), $0.product.packID) > (release($1), $1.product.packID) }
                DisclosureGroup(isExpanded: expansion(series.id)) {
                    candidateGrid(members)
                        .padding(.top, 6)
                } label: {
                    HStack(spacing: 8) {
                        Text(series.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                        Text("팩 \(members.count)종")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                        Spacer(minLength: 0)
                        Text(probabilityLabel(pool.probability(ofSeries: series.id)))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.accent)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private func expansion(_ seriesID: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedSeries.contains(seriesID) },
            set: { open in
                if open { model.expandedSeries.insert(seriesID) } else { model.expandedSeries.remove(seriesID) }
            }
        )
    }

    /// Read from the pool itself, so the text cannot drift from the weights the
    /// draw actually uses.
    private var drawRule: String {
        guard let pool = environment.pool else { return "팩 후보 목록을 사용할 수 없습니다." }
        if pool.selection == .seriesUniform {
            let equalInside = pool.series.allSatisfy { series in
                Set(pool.candidates.filter { $0.series == series.id }.map(\.weight)).count <= 1
            }
            return "시리즈 \(pool.series.count)개 중 하나를 같은 확률로 고른 뒤, 그 시리즈 안의 팩 하나를 "
                + (equalInside ? "같은 확률로" : "가중치에 비례해") + " 받습니다 · 전체 \(pool.candidates.count)종 · 숨은 보정·재추첨 없음 · pool \(pool.poolVersion)"
        }
        let weights = Set(pool.candidates.map(\.weight))
        let rule = weights.count == 1
            ? "후보 \(pool.candidates.count)종 중 하나를 같은 확률로 받습니다"
            : "후보 \(pool.candidates.count)종을 가중치에 비례해 추첨합니다"
        return "\(rule) · 숨은 보정·재추첨 없음 · pool \(pool.poolVersion)"
    }

    private func candidateTile(_ product: PackProduct, probability: Double, catalogVersion: String, recipeVersion: Int) -> some View {
        HStack(spacing: 10) {
            PackArtworkView(product: product, size: .tile)
                .frame(width: 38, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(environment.setInfo(for: product.setID)?.name ?? product.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(product.setID.uppercased()) · \(product.language.uppercased())")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                Text(probabilityLabel(probability))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.accent)
                    .monospacedDigit()
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panelRaised.opacity(0.6)))
        .help("\(product.name) · 판본 \(catalogVersion) · recipe v\(recipeVersion) · 검증 \(product.verification.status.displayName)")
    }

    /// Rounded display keeps "약 33.3%" distinct from an exact figure.
    /// Two decimals at most, so a 1/16 series reads 6.25 % and a pack deep in
    /// a large series (0.37 %) does not round to 0.4 %.
    private func probabilityLabel(_ probability: Double) -> String {
        "약 \(probability.formatted(.percent.precision(.fractionLength(0...2))))"
    }

    private func grantedPanel(_ pack: PackInstanceRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(Palette.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(environment.product(for: pack)?.name ?? pack.productID)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("받은 시각 \(pack.acquiredAt.packTraceDisplay) · 팩 ID \(pack.id.rawValue.prefix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
                Text("팩 종류는 지급 순간에 확정됩니다. 개봉할 때 다시 뽑지 않습니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button("지금 뜯기") { environment.requestOpening(pack: pack) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.success.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.success.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Collection

    private var collectionRow: some View {
        HStack(spacing: 12) {
            shortcut(
                icon: "shippingbox",
                title: "보관함",
                value: "미개봉 \(environment.sealedPacks.count)팩",
                caption: environment.sealedPacks.isEmpty ? "받은 팩이 여기에 쌓입니다" : "팩을 눌러 뜯습니다",
                tab: .vault
            )
            shortcut(
                icon: "rectangle.stack",
                title: "바인더",
                value: "고유 프린트 \(environment.collectionTotals.ownedUniquePrints)/\(environment.collectionTotals.totalPrints)",
                caption: "모은 카드 \(environment.collectionTotals.totalCopies)장 · 중복 포함",
                tab: .binder
            )
            shortcut(
                icon: "trophy",
                title: "업적",
                value: "\(environment.achievementRecords.count)/\(environment.achievements.count)",
                caption: nextAchievementCaption,
                tab: .achievements
            )
        }
    }

    /// The locked achievement closest to done, as a nudge.
    private var nextAchievementCaption: String {
        let next = environment.achievements
            .filter { environment.achievementRecords[$0.id] == nil && $0.current > 0 }
            .max { $0.fraction < $1.fraction }
        guard let next else { return "팩을 끝까지 공개하면 열립니다" }
        return "다음: \(next.definition.title) \(Int(next.fraction * 100))%"
    }

    private func shortcut(icon: String, title: String, value: String, caption: String, tab: AppEnvironment.Tab) -> some View {
        Button {
            environment.selectedTab = tab
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.inkMuted)
                    Text(value)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.inkMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var footnote: some View {
        Text("받는 팩의 종류는 위 후보 중에서 정해지고, 팩 안의 카드는 그 세트에서만 나옵니다. 팩 안 배합은 앱 자체 시뮬레이션이며 실물 봉입 확률이 아닙니다. AI 사용량은 실사용 지갑에만 적립되고 개발용 지급과 섞이지 않습니다.")
            .font(.system(size: 10))
            .foregroundStyle(Palette.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// AI usage across every connected tool (OMP is one of them): the overall
/// state, each source's state, today's accepted tokens and points, and the
/// distance to the next point. Every tool feeds one shared account.
struct TodayUsagePanel: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        let usage = environment.usage
        let overview = environment.usageOverview
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("AI 사용량")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    BadgeView(text: overview.stateLabel, color: overview.tone.color)
                    if usage.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    if overview.hasConnection {
                        Button {
                            Task { await environment.refreshUsageNow() }
                        } label: {
                            Label("새로고침", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .disabled(!environment.hasCollectableSource || usage.isScanning)
                        UsagePauseAllButton(overview: overview)
                    }
                    Button(overview.hasConnection ? "도구 관리" : "도구 연결") {
                        environment.selectedTab = .settings
                    }
                    .controlSize(.small)
                }

                if !overview.sources.isEmpty {
                    // Wraps: up to ten tools can be connected.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(overview.sources) { source in
                            BadgeView(text: "\(source.tool.displayName) · \(source.state.label)", color: source.state.tone.color)
                        }
                    }
                }

                HStack(spacing: 12) {
                    MetricTile(
                        label: "오늘 인정 토큰",
                        value: usage.todayAcceptedTokens.formatted(),
                        caption: "모든 도구 · \(usage.todayAcceptedEvents)건",
                        tint: Palette.ink
                    )
                    MetricTile(
                        label: "오늘 적립",
                        value: "+\(usage.todayAwardedPoints) P",
                        caption: "실사용 지갑",
                        tint: Palette.success
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("다음 1 P까지")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.inkMuted)
                        Text("\(usage.tokensUntilNextPoint.formatted()) 토큰")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.accent)
                            .monospacedDigit()
                        ProgressView(value: usage.progressToNextPoint)
                            .tint(Palette.accent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
                }
                .fixedSize(horizontal: false, vertical: true)

                Text(overview.summaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(overview.tone == .attention ? Palette.danger : Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if !usage.todayByTool.isEmpty {
                    TodayToolBreakdown(days: usage.todayByTool)
                }

                if !usage.toolTotals.isEmpty {
                    Text("누적 인정 토큰 · " + usage.toolTotals.map { "\($0.tool.displayName) \($0.acceptedTokens.formatted())" }.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                        .monospacedDigit()
                        .help("도구별 합계는 하나의 공통 계정을 나눈 것이며, 도구별 포인트를 따로 만들지 않습니다.")
                }

                Text("비캐시 입력 + 출력만 인정합니다 · \(usage.tokensPerPoint.formatted()) 토큰 = 1 P · 캐시 토큰 제외")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)

                if environment.profile != .production {
                    HStack(spacing: 8) {
                        Text("지금 보는 지갑은 개발용입니다. 적립은 실사용 지갑(잔액 \(environment.productionBalance) P)에 들어갑니다.")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.demoBadge)
                        Spacer(minLength: 0)
                        Button("실사용 지갑으로 전환") {
                            Task { await environment.switchProfile(to: .production) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Today's calls per tool: what was credited, and the cache tokens the rule
/// leaves out. Usage dashboards (ccusage …) count those cache reads, so their
/// "total tokens" is far larger than what earns points here.
struct TodayToolBreakdown: View {
    let days: [UsageToolDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("오늘 도구별 · 캐시 토큰은 적립하지 않습니다")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.inkMuted)
            ForEach(days) { day in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(day.tool.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 92, alignment: .leading)
                    Text("인정 \(TokenCount.compact(day.acceptedTokens))")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.accent)
                    Text("전체 \(TokenCount.compact(day.allTokens)) · 캐시 읽기 \(TokenCount.compact(day.cacheReadTokens)) · 캐시 쓰기 \(TokenCount.compact(day.cacheWriteTokens))")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(day.events.formatted())건")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                }
                .monospacedDigit()
                .help("인정 = 비캐시 입력 \(day.inputTokens.formatted()) + 출력 \(day.outputTokens.formatted()). 전체는 캐시 읽기·쓰기를 더한 값으로, 사용량 대시보드가 보여 주는 숫자와 같은 기준입니다.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.panelRaised.opacity(0.5)))
    }
}

/// Token counts at a glance in Korean units: 8.7억, 1,261만, 3,470.
enum TokenCount {
    static func compact(_ value: Int) -> String {
        let magnitude = abs(value)
        if magnitude >= 100_000_000 {
            let eok = Double(value) / 100_000_000
            return (eok >= 100 ? String(format: "%.0f", eok) : String(format: "%.1f", eok)) + "억"
        }
        if magnitude >= 10_000 {
            return (value / 10_000).formatted() + "만"
        }
        return value.formatted()
    }
}

