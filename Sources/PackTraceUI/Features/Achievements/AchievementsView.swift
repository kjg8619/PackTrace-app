import PackTraceCore
import SwiftUI

/// Achievements of the profile on screen, grouped by category. Unlocked ones
/// show when they were achieved and what they paid; the rest show progress.
/// Series the viewer opened or closed among the set achievements.
@MainActor
final class AchievementsModel: ObservableObject {
    @Published var seriesOverrides: [String: Bool] = [:]
}

struct AchievementsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model = AchievementsModel()

    var body: some View {
        let progress = environment.achievements
        let unlocked = progress.filter { environment.achievementRecords[$0.id] != nil }
        let earned = environment.achievementRecords.values.reduce(0) { $0 + $1.rewardPoints }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("업적")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text("달성 \(unlocked.count)/\(progress.count) · 받은 보상 \(earned) P · 끝까지 공개한 팩만 셉니다. 보상은 업적마다 한 번, 이 지갑에 들어갑니다.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.inkMuted)
                    if let error = environment.achievementError {
                        Text("업적을 확인하지 못했습니다: \(error)")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.danger)
                    }
                }
                showcase(unlocked)
                ForEach(AchievementCategory.allCases, id: \.self) { category in
                    let items = progress.filter { $0.definition.category == category }
                    if !items.isEmpty {
                        section(category, items)
                    }
                }
            }
            .padding(22)
        }
    }

    /// Every badge earned so far, in the order it was achieved.
    @ViewBuilder
    private func showcase(_ unlocked: [AchievementProgress]) -> some View {
        let earned = unlocked.sorted {
            (environment.achievementRecords[$0.id]?.achievedAt ?? .distantPast) < (environment.achievementRecords[$1.id]?.achievedAt ?? .distantPast)
        }
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("획득한 배지 \(earned.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                if earned.isEmpty {
                    Text("아직 없습니다. 팩을 끝까지 공개하면 첫 배지를 받습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 90), spacing: 8, alignment: .top)], alignment: .leading, spacing: 12) {
                        ForEach(earned) { item in
                            VStack(spacing: 4) {
                                AchievementBadgeView(spec: badge(item.definition), unlocked: true, size: 52)
                                Text(item.definition.title)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Palette.inkMuted)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            .help("\(item.definition.title) · \(item.definition.detail)")
                        }
                    }
                }
            }
        }
    }

    private func badge(_ definition: AchievementDefinition) -> AchievementBadgeSpec {
        AchievementBadgeSpec.make(for: definition, setOrder: environment.setSummaries.map(\.setID))
    }

    /// Achieved first, then the closest to done, then catalogue order —
    /// `sorted` is not stable, and ties must not swap on every refresh.
    private func ordered(_ items: [AchievementProgress]) -> [AchievementProgress] {
        items.enumerated().sorted { lhs, rhs in
            let left = environment.achievementRecords[lhs.element.id] != nil
            let right = environment.achievementRecords[rhs.element.id] != nil
            if left != right { return left }
            if lhs.element.fraction != rhs.element.fraction { return lhs.element.fraction > rhs.element.fraction }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func tiles(_ items: [AchievementProgress]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 10, alignment: .top)],
            alignment: .leading,
            spacing: 10
        ) {
            ForEach(ordered(items)) { item in
                AchievementTile(item: item, record: environment.achievementRecords[item.id], badge: badge(item.definition))
            }
        }
    }

    /// Two per set: with every era that is a few hundred, so they sit under
    /// their series, open where something is already collected.
    private func setsBySeries(_ items: [AchievementProgress]) -> some View {
        var bySet: [String: [AchievementProgress]] = [:]
        for item in items {
            if case let .setCompletion(setID, _) = item.definition.rule { bySet[setID, default: []].append(item) }
        }
        let groups = environment.seriesGroups.map { group in
            (group: group, items: group.setIDs.flatMap { bySet[$0] ?? [] })
        }.filter { !$0.items.isEmpty }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.group.id) { entry in
                let done = entry.items.filter { environment.achievementRecords[$0.id] != nil }.count
                let started = entry.items.contains { $0.current > 0 }
                let expanded = model.seriesOverrides[entry.group.id] ?? started
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        model.seriesOverrides[entry.group.id] = !expanded
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(Palette.inkMuted)
                            Text(entry.group.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text("\(done)/\(entry.items.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(Palette.inkMuted)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        tiles(entry.items)
                    }
                }
            }
        }
    }

    private func section(_ category: AchievementCategory, _ items: [AchievementProgress]) -> some View {
        let done = items.filter { environment.achievementRecords[$0.id] != nil }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(category.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("\(done)/\(items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
                    .monospacedDigit()
            }
            if category == .sets, environment.seriesGroups.count > 1 {
                setsBySeries(items)
            } else {
                tiles(items)
            }
        }
    }
}

private struct AchievementTile: View {
    let item: AchievementProgress
    let record: AchievementRecord?
    let badge: AchievementBadgeSpec

    var body: some View {
        let unlocked = record != nil
        return HStack(alignment: .top, spacing: 10) {
            AchievementBadgeView(spec: badge, unlocked: unlocked, progress: item.fraction, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.definition.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(unlocked ? Palette.ink : Palette.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("+\(record?.rewardPoints ?? item.definition.rewardPoints) P")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(unlocked ? Palette.success : Palette.inkMuted)
                }
                Text(item.definition.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(2)
                if let record {
                    Text("\(record.achievedAt.packTraceDay) 달성")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accentWarm)
                } else {
                    ProgressView(value: item.fraction)
                        .tint(Palette.accent)
                    Text("\(item.current.formatted())/\(item.target.formatted())")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.inkMuted)
                        .monospacedDigit()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(unlocked ? Palette.accentWarm.opacity(0.08) : Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(unlocked ? Palette.accentWarm.opacity(0.35) : Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Announces new unlocks until dismissed. Shown over the main window, so an
/// opening sheet covers it until the reveal is over.
struct AchievementUnlockNotice: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        let unlocks = environment.recentUnlocks
        let titles = unlocks.compactMap { record in
            environment.achievements.first { $0.id == record.achievementID }?.definition.title
        }
        let reward = unlocks.reduce(0) { $0 + $1.rewardPoints }
        let firstDefinition = unlocks.first.flatMap { record in
            environment.achievements.first { $0.id == record.achievementID }?.definition
        }
        return HStack(spacing: 10) {
            if let firstDefinition {
                AchievementBadgeView(
                    spec: AchievementBadgeSpec.make(for: firstDefinition, setOrder: environment.setSummaries.map(\.setID)),
                    unlocked: true,
                    size: 34
                )
            } else {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.accentWarm)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(unlocks.count == 1 ? "업적 달성 · \(titles.first ?? "")" : "업적 \(unlocks.count)개 달성")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(reward > 0 ? "보상 +\(reward) P" + (titles.count > 1 ? " · " + titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? " 외" : "") : "") : "기록되었습니다")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
            Button("보기") {
                environment.selectedTab = .achievements
                environment.dismissRecentUnlocks()
            }
            .controlSize(.small)
            Button {
                environment.dismissRecentUnlocks()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("닫기")
        }
        .padding(12)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accentWarm.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}
