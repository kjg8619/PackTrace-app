import PackTraceCore
import SwiftUI

/// Shown once after an exchange commits: which real pack the draw produced.
/// Deliberately short — the pack is already in the vault whether or not this is
/// dismissed, and nothing here can change the result.
struct ReceivedPackSheet: View {
    let pack: PackInstanceRecord

    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @StateObject private var model = AppearanceModel()

    /// Short appearance state. Kept in a small model because this build has no
    /// `@State` (see docs/TOOLCHAIN.md).
    @MainActor
    final class AppearanceModel: ObservableObject {
        @Published var appeared = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("팩을 받았습니다")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    Text("종류는 이미 확정되어 보관함에 들어갔습니다. 뜯을 때 다시 뽑지 않습니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 0)
                if let pool = environment.pool {
                    BadgeView(text: "pool \(pool.poolVersion)", color: Palette.demoBadge)
                }
            }

            HStack(alignment: .top, spacing: 18) {
                PackThumbnail(product: environment.product(for: pack), width: 120)
                    .scaleEffect(model.appeared ? 1 : 0.9)
                    .opacity(model.appeared ? 1 : 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(environment.product(for: pack)?.name ?? pack.productID)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    HStack(spacing: 6) {
                        BadgeView(text: "세트 \(pack.productID.setLabel)", color: Palette.accent)
                        BadgeView(text: "판본 \(pack.catalogVersion)", color: Palette.demoBadge)
                        BadgeView(text: "recipe v\(pack.recipeVersion)", color: Palette.inkMuted)
                    }
                    Text(setLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkMuted)
                    if let product = environment.product(for: pack) {
                        Text(environment.packArtwork(for: product).statusText)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("받은 시각 \(pack.acquiredAt.packTraceDisplay) · 팩 ID \(pack.id.rawValue.prefix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button("보관하기") { dismiss() }
                    .buttonStyle(.borderedProminent)
                Button("지금 개봉하기") {
                    environment.requestOpening(pack: pack)
                    dismiss()
                }
                Spacer(minLength: 0)
                if let candidate = environment.pool?.candidate(for: pack.productID) {
                    Text("이 팩에서 나올 수 있는 프린트 \(candidate.supportedPrintCount)종 · 배합은 앱 시뮬레이션")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.inkMuted)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(Palette.backdrop)
        .onAppear {
            // The same rule as the opening: the app's own settings or the
            // system's Reduce Motion.
            if environment.settings.skipsAnimations(systemReduceMotion: systemReduceMotion) {
                model.appeared = true
            } else {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { model.appeared = true }
            }
        }
    }

    private var setLine: String {
        guard let setID = environment.product(for: pack)?.setID, let info = environment.setInfo(for: setID) else {
            return "세트 정보 없음"
        }
        return "\(info.name) · \(info.language.uppercased()) · \(info.releaseDate)"
    }
}

extension String {
    /// `tpcgi-en-sv02-booster` → `sv02` for compact labels.
    var setLabel: String {
        let parts = split(separator: "-")
        return parts.count >= 3 ? String(parts[2]) : self
    }
}
