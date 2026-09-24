import PackTraceCore
import SwiftUI

/// How the vault shows packs: large pack pictures first, or compact rows with
/// every stored detail.
public enum VaultLayout: String, CaseIterable, Identifiable, Sendable {
    case gallery
    case list

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .gallery: "팩 강조"
        case .list: "리스트"
        }
    }
}

/// Packs grouped the way the vault shows them. A pack whose opening was left
/// half way is its own group: it is the one to come back to.
struct VaultSections: Equatable {
    var inProgress: [PackInstanceRecord] = []
    var sealed: [PackInstanceRecord] = []
    var completed: [PackInstanceRecord] = []

    static func make(packs: [PackInstanceRecord], openings: [OpeningRecord]) -> VaultSections {
        let unfinished = Set(openings.filter { !$0.isComplete }.map(\.packInstanceID))
        var sections = VaultSections()
        for pack in packs {
            switch pack.state {
            case .sealed: sections.sealed.append(pack)
            case .opened:
                if unfinished.contains(pack.id) {
                    sections.inProgress.append(pack)
                } else {
                    sections.completed.append(pack)
                }
            }
        }
        return sections
    }

    var isEmpty: Bool { inProgress.isEmpty && sealed.isEmpty && completed.isEmpty }
}

struct VaultView: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        VaultScreen(settings: environment.settings)
    }
}

private struct VaultScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var settings: AppSettings

    private var sections: VaultSections {
        VaultSections.make(packs: environment.allPacks, openings: environment.openings)
    }

    var body: some View {
        let sections = sections
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(sections)
                if sections.isEmpty {
                    emptyState
                } else {
                    switch settings.vaultLayout {
                    case .gallery: gallery(sections)
                    case .list: list(sections)
                    }
                }
            }
            .padding(22)
        }
    }

    private func header(_ sections: VaultSections) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("보관함")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.ink)
                Text(summaryLine(sections))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Picker("보기", selection: $settings.vaultLayout) {
                ForEach(VaultLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private func summaryLine(_ sections: VaultSections) -> String {
        var parts = ["미개봉 \(sections.sealed.count)팩"]
        if !sections.inProgress.isEmpty { parts.append("공개 중 \(sections.inProgress.count)팩") }
        parts.append("개봉 완료 \(sections.completed.count)팩")
        return parts.joined(separator: " · ") + " · 팩 종류는 받을 때 확정되고, 뜯을 때 다시 뽑지 않습니다."
    }

    private var emptyState: some View {
        Panel {
            VStack(alignment: .leading, spacing: 6) {
                Text("아직 받은 팩이 없습니다")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("오늘 화면에서 포인트로 랜덤팩을 받으면 이곳에 쌓입니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
                Button("오늘 화면으로") { environment.selectedTab = .today }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Gallery

    @ViewBuilder
    private func gallery(_ sections: VaultSections) -> some View {
        if !sections.inProgress.isEmpty {
            galleryGroup("공개 중", note: "저장된 결과를 이어서 공개합니다", packs: sections.inProgress, width: 150)
        }
        if !sections.sealed.isEmpty {
            galleryGroup("미개봉", note: "팩을 눌러 뜯습니다", packs: sections.sealed, width: 150)
        } else {
            Text("미개봉 팩이 없습니다. 오늘 화면에서 랜덤팩을 받을 수 있습니다.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.inkMuted)
        }
        if !sections.completed.isEmpty {
            galleryGroup("개봉 완료", note: "눌러서 결과를 다시 봅니다", packs: sections.completed, width: 100)
        }
    }

    private func galleryGroup(_ title: String, note: String, packs: [PackInstanceRecord], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(title) \(packs.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: width, maximum: width + 24), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(packs) { pack in
                    VaultPackTile(pack: pack, width: width)
                }
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ sections: VaultSections) -> some View {
        if !sections.inProgress.isEmpty {
            listGroup("공개 중", packs: sections.inProgress)
        }
        if !sections.sealed.isEmpty {
            listGroup("미개봉", packs: sections.sealed)
        }
        if !sections.completed.isEmpty {
            listGroup("개봉 완료", packs: sections.completed)
        }
    }

    private func listGroup(_ title: String, packs: [PackInstanceRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) \(packs.count)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            VStack(spacing: 0) {
                ForEach(Array(packs.enumerated()), id: \.element.id) { index, pack in
                    if index > 0 { Divider().overlay(Palette.hairline) }
                    VaultPackRow(pack: pack)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        }
    }
}

/// What the vault offers for a pack: tear it, resume it, or look at it again.
private enum VaultPackAction {
    case tear, resume, review

    init(pack: PackInstanceRecord, opening: OpeningRecord?) {
        if pack.state == .sealed {
            self = .tear
        } else if let opening, !opening.isComplete {
            self = .resume
        } else {
            self = .review
        }
    }

    var title: String {
        switch self {
        case .tear: "뜯기"
        case .resume: "이어서 공개"
        case .review: "결과 보기"
        }
    }
}

/// A pack shown as the object itself: the wrapper large, a short name, and
/// one action under it. The picture is the button.
private struct VaultPackTile: View {
    @EnvironmentObject private var environment: AppEnvironment
    let pack: PackInstanceRecord
    let width: CGFloat

    var body: some View {
        let product = environment.product(for: pack)
        let opening = environment.opening(for: pack)
        let action = VaultPackAction(pack: pack, opening: opening)
        let isSealed = pack.state == .sealed
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                environment.requestOpening(pack: pack)
            } label: {
                // No frame around it: the wrapper's own shape, at the printed
                // pack's proportions (about 1 : 1.8).
                PackArtworkView(product: product, size: .tile, isOpened: action == .review)
                    .frame(width: width, height: width * 1.8)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(action == .review ? 0.8 : 1)
                    .shadow(color: isSealed ? Palette.accent.opacity(0.25) : .black.opacity(0.4), radius: isSealed ? 16 : 6, y: 6)
                    .overlay(alignment: .topTrailing) {
                        if action == .resume, let opening {
                            BadgeView(text: "\(opening.revealedCount)/\(opening.cards.count)", color: Palette.accentWarm)
                                .padding(6)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(product?.name ?? pack.productID)
            .accessibilityLabel("\(product?.name ?? pack.productID), \(action.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(environment.setInfo(for: product?.setID ?? "")?.name ?? product?.name ?? pack.productID)
                    .font(.system(size: width > 120 ? 13 : 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("\(product?.setID.uppercased() ?? "-") · \(pack.acquiredAt.packTraceDay)")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }

            if action != .review {
                Button(action.title) { environment.requestOpening(pack: pack) }
                    .buttonStyle(.borderedProminent)
                    .tint(action == .resume ? Palette.accentWarm : Palette.accent)
                    .controlSize(.small)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// A pack as one row with every stored detail: edition, recipe, pool and id.
private struct VaultPackRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    let pack: PackInstanceRecord

    var body: some View {
        let product = environment.product(for: pack)
        let opening = environment.opening(for: pack)
        let action = VaultPackAction(pack: pack, opening: opening)
        return HStack(alignment: .center, spacing: 12) {
            PackThumbnail(product: product, isOpened: pack.state == .opened, width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(product?.name ?? pack.productID)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("받은 날짜 \(pack.acquiredAt.packTraceDisplay) · 팩 ID \(pack.id.rawValue.prefix(8))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.inkMuted)
                Text("판본 \(pack.catalogVersion) · recipe v\(pack.recipeVersion) · \(pack.poolVersion.map { "pool \($0)" } ?? "pool 없음(legacy)")")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let opening {
                Text("공개 \(opening.revealedCount)/\(opening.cards.count)장")
                    .font(.system(size: 10))
                    .foregroundStyle(opening.isComplete ? Palette.inkMuted : Palette.accentWarm)
            }
            BadgeView(text: pack.state.displayName, color: pack.state == .sealed ? Palette.accent : Palette.inkMuted)
            if action == .review {
                Button(action.title) { environment.requestOpening(pack: pack) }
                    .controlSize(.small)
            } else {
                Button(action.title) { environment.requestOpening(pack: pack) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// A pack in a list: the same picture the opening scene will tear.
///
/// The artwork decision (real or substitute) comes from the environment, so a
/// pack looks the same in Today, the vault, the received sheet and the opening.
struct PackThumbnail: View {
    var product: PackProduct?
    var isOpened: Bool = false
    var width: CGFloat = 62

    var body: some View {
        PackArtworkView(product: product, size: .tile, isOpened: isOpened)
            .frame(width: width, height: width * 1.5)
            .background(Palette.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: max(5, width * 0.06), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(5, width * 0.06), style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                if isOpened, width >= 44 {
                    Text("개봉")
                        .font(.system(size: width > 100 ? 10 : 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .foregroundStyle(Palette.inkMuted)
                        .padding(width > 100 ? 7 : 3)
                }
            }
    }
}
