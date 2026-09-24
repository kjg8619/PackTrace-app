import AppKit
import PackTraceCore
import SwiftUI

/// How one achievement's badge looks. Every achievement gets its own
/// combination, drawn in code (no image assets):
///
/// - the outline shape says the category (medal, gem, hexagon, shield, star, chip),
/// - the rim metal says how hard it is (from the reward: bronze → prismatic),
/// - the inner colour, glyph and short label say which one it is.
struct AchievementBadgeSpec: Hashable {
    enum Shape: Hashable {
        case medal, gem, hexagon, shield, star, chip
    }

    enum Metal: Int, Hashable, Comparable {
        case bronze, silver, gold, platinum, prismatic

        static func < (lhs: Metal, rhs: Metal) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Harder achievements pay more; the rim follows the reward.
        static func forReward(_ points: Int) -> Metal {
            switch points {
            case ..<20: .bronze
            case ..<40: .silver
            case ..<80: .gold
            case ..<150: .platinum
            default: .prismatic
            }
        }

        var name: String {
            switch self {
            case .bronze: "동"
            case .silver: "은"
            case .gold: "금"
            case .platinum: "백금"
            case .prismatic: "무지개"
            }
        }
    }

    /// Inner colour as hue/saturation/brightness, so specs stay comparable.
    struct Tint: Hashable {
        var hue: Double
        var saturation: Double
        var brightness: Double

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

        static func of(_ color: NSColor) -> Tint {
            let rgb = color.usingColorSpace(.deviceRGB) ?? color
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return Tint(hue: Double(hue), saturation: Double(saturation), brightness: Double(brightness))
        }
    }

    var shape: Shape
    var metal: Metal
    var tint: Tint
    var glyph: String
    var label: String

    // MARK: - One spec per achievement

    /// `setOrder` lists the library's sets in order, so each set's shield gets
    /// its own colour around the hue circle.
    static func make(for definition: AchievementDefinition, setOrder: [String]) -> AchievementBadgeSpec {
        let metal = Metal.forReward(definition.rewardPoints)
        func spec(_ shape: Shape, _ tint: Tint, _ glyph: String, _ label: String) -> AchievementBadgeSpec {
            AchievementBadgeSpec(shape: shape, metal: metal, tint: tint, glyph: glyph, label: label)
        }
        func hue(_ value: Double, _ saturation: Double = 0.55, _ brightness: Double = 0.55) -> Tint {
            Tint(hue: value, saturation: saturation, brightness: brightness)
        }

        switch definition.rule {
        case let .packsOpened(count):
            return spec(.medal, hue(0.58), count == 1 ? "gift.fill" : "shippingbox.fill", "\(count)")
        case let .distinctSetsOpened(count):
            return spec(.medal, hue(0.72), count >= 10 ? "square.grid.3x3.fill" : "square.grid.2x2.fill", "\(count)")
        case let .firstOfRarity(rarity):
            let (glyph, label) = rarityMark(rarity)
            return spec(.gem, Tint.of(NSColor(Palette.rarityColor(rarity))).deepened, glyph, label)
        case let .highRarityPack(count):
            return spec(.gem, hue(0.83, 0.5, 0.6), "wand.and.stars", "×\(count)")
        case let .uniquePrints(count):
            let label = count < 1000 ? "\(count)" : count % 1000 == 0 ? "\(count / 1000)K" : "\(count / 1000).\(count % 1000 / 100)K"
            return spec(.hexagon, hue(0.47, 0.5, 0.5), "books.vertical.fill", label)
        case let .setCompletion(setID, percent):
            let index = setOrder.firstIndex(of: setID) ?? 0
            let spread = Double(index) / Double(max(setOrder.count, 1))
            return spec(
                .shield,
                hue(spread, 0.6, 0.55),
                percent >= 100 ? "checkmark.seal.fill" : "circle.lefthalf.filled",
                setID.uppercased()
            )
        case let .printCopies(copies):
            let stars = CardMastery.stars(copies: copies)
            return spec(.star, hue(0.12, 0.85, 0.78), "star.fill", stars <= 1 ? "★" : "★\(stars)")
        case let .starredPrints(count):
            return spec(.star, hue(0.09, 0.8, 0.72), "star.square.on.square.fill", "\(count)")
        case let .acceptedTokens(tokens):
            return spec(.chip, hue(0.55, 0.45, 0.5), "cpu", tokenLabel(tokens))
        case let .usageStreak(days):
            return spec(.chip, hue(0.03, 0.65, 0.6), "flame.fill", "\(days)")
        case let .usageTools(count):
            return spec(.chip, hue(0.36, 0.45, 0.5), "wrench.and.screwdriver.fill", "\(count)")
        }
    }

    private static func rarityMark(_ rarity: CardRarity) -> (String, String) {
        switch rarity.rawValue {
        case "Double rare": ("suit.diamond.fill", "RR")
        case "Ultra Rare": ("crown.fill", "UR")
        case "Illustration rare": ("paintbrush.pointed.fill", "IR")
        case "Special illustration rare": ("paintpalette.fill", "SIR")
        case "Hyper rare": ("sparkles", "HR")
        case "ACE SPEC Rare": ("bolt.fill", "ACE")
        case "Secret Rare": ("lock.fill", "SR")
        case "Rare Holo LV.X": ("arrow.up.circle.fill", "LV.X")
        case "Rare PRIME": ("p.circle.fill", "PRIME")
        case "LEGEND": ("rectangle.split.1x2.fill", "LEGEND")
        case "Holo Rare VMAX": ("arrow.up.left.and.arrow.down.right", "VMAX")
        case "Holo Rare VSTAR": ("star.circle.fill", "VSTAR")
        case "Amazing Rare": ("rainbow", "AMZ")
        case "Radiant Rare": ("sun.max.fill", "RAD")
        case "Shiny rare": ("sparkle", "SHINY")
        case "Mega Hyper Rare": ("m.circle.fill", "MHR")
        default: ("seal.fill", String(rarity.rawValue.prefix(2)).uppercased())
        }
    }

    private static func tokenLabel(_ tokens: Int) -> String {
        tokens >= 1_000_000 ? "\(tokens / 1_000_000)M" : "\(tokens / 1_000)K"
    }
}

private extension AchievementBadgeSpec.Tint {
    /// Rarity colours are pastel for text on dark panels; a badge's inner disc
    /// needs a deeper tone under a white glyph.
    var deepened: Self {
        Self(hue: hue, saturation: min(1, saturation * 1.1 + 0.15), brightness: brightness * 0.62)
    }
}

// MARK: - Drawing

/// One achievement's badge. Locked badges are drawn in grey with a lock and,
/// when there is progress, a ring showing how far along it is.
struct AchievementBadgeView: View {
    let spec: AchievementBadgeSpec
    var unlocked: Bool
    var progress: Double = 0
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if !unlocked, progress > 0 {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0.02), 1))
                    .stroke(Palette.accent.opacity(0.8), style: StrokeStyle(lineWidth: max(2, size * 0.05), lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size * 1.12, height: size * 1.12)
            }
            // Locked badges are drawn grey on purpose rather than through a
            // saturation filter, so they look the same wherever they render.
            badge
                .opacity(unlocked ? 1 : 0.5)
            if !unlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(Palette.ink.opacity(0.85))
                    .padding(size * 0.05)
                    .background(Circle().fill(Palette.backdrop.opacity(0.85)))
                    .offset(x: size * 0.34, y: size * 0.34)
            }
        }
        .frame(width: size * 1.16, height: size * 1.16)
        .accessibilityHidden(true)
    }

    private var badge: some View {
        let outline = BadgeOutline(shape: spec.shape)
        return ZStack {
            // Rim: the metal.
            outline
                .fill(rimFill)
                .shadow(color: .black.opacity(0.45), radius: size * 0.06, y: size * 0.04)
            // Face: the achievement's own colour.
            outline
                .fill(
                    LinearGradient(
                        colors: [faceColor.opacity(0.95), faceColor.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(size * rimInset)
            // Shine across the top half.
            outline
                .fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                .padding(size * rimInset)
            VStack(spacing: size * 0.02) {
                Image(systemName: spec.glyph)
                    .font(.system(size: size * glyphScale, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                Text(spec.label)
                    .font(.system(size: size * labelScale, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, size * 0.12)
            }
            .offset(y: labelOffset)
        }
        .frame(width: size, height: size)
    }

    private var rimInset: CGFloat {
        switch spec.shape {
        case .star: 0.12
        case .gem: 0.1
        default: 0.08
        }
    }

    private var glyphScale: CGFloat { spec.shape == .star ? 0.2 : 0.3 }
    private var labelScale: CGFloat { spec.shape == .star ? 0.14 : 0.17 }

    /// Stars and shields have their visual centre lower than their frame's.
    private var labelOffset: CGFloat {
        switch spec.shape {
        case .star: size * 0.04
        case .shield: -size * 0.03
        default: 0
        }
    }

    private var faceColor: Color {
        unlocked ? spec.tint.color : Color(white: 0.32)
    }

    private var rimFill: AnyShapeStyle {
        guard unlocked else {
            return AnyShapeStyle(LinearGradient(colors: [Color(white: 0.5), Color(white: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        return switch spec.metal {
        case .bronze:
            AnyShapeStyle(LinearGradient(colors: [Color(red: 0.86, green: 0.58, blue: 0.36), Color(red: 0.55, green: 0.32, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .silver:
            AnyShapeStyle(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .gold:
            AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.88, blue: 0.45), Color(red: 0.78, green: 0.56, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .platinum:
            AnyShapeStyle(LinearGradient(colors: [Color(red: 0.9, green: 0.98, blue: 1.0), Color(red: 0.55, green: 0.72, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .prismatic:
            AnyShapeStyle(AngularGradient(
                colors: ([.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red] as [Color]).map { $0.opacity(0.9) },
                center: .center
            ))
        }
    }
}

/// The outline of each badge family.
struct BadgeOutline: Shape {
    var shape: AchievementBadgeSpec.Shape

    func path(in rect: CGRect) -> Path {
        switch shape {
        case .medal:
            return Circle().path(in: rect)
        case .chip:
            return RoundedRectangle(cornerRadius: rect.width * 0.24, style: .continuous).path(in: rect)
        case .hexagon:
            return polygon(in: rect, sides: 6, rotation: .pi / 2)
        case .gem:
            // A cut gem: flat top, pointed bottom.
            var path = Path()
            let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
            path.move(to: CGPoint(x: x + w * 0.24, y: y + h * 0.1))
            path.addLine(to: CGPoint(x: x + w * 0.76, y: y + h * 0.1))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.38))
            path.addLine(to: CGPoint(x: x + w * 0.5, y: y + h * 0.98))
            path.addLine(to: CGPoint(x: x, y: y + h * 0.38))
            path.closeSubpath()
            return path
        case .shield:
            var path = Path()
            let w = rect.width, h = rect.height, x = rect.minX, y = rect.minY
            path.move(to: CGPoint(x: x + w * 0.5, y: y))
            path.addQuadCurve(to: CGPoint(x: x + w, y: y + h * 0.14), control: CGPoint(x: x + w * 0.8, y: y + h * 0.12))
            path.addLine(to: CGPoint(x: x + w, y: y + h * 0.48))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y + h), control: CGPoint(x: x + w * 0.96, y: y + h * 0.84))
            path.addQuadCurve(to: CGPoint(x: x, y: y + h * 0.48), control: CGPoint(x: x + w * 0.04, y: y + h * 0.84))
            path.addLine(to: CGPoint(x: x, y: y + h * 0.14))
            path.addQuadCurve(to: CGPoint(x: x + w * 0.5, y: y), control: CGPoint(x: x + w * 0.2, y: y + h * 0.12))
            path.closeSubpath()
            return path
        case .star:
            return star(in: rect, points: 5, innerRatio: 0.5)
        }
    }

    private func polygon(in rect: CGRect, sides: Int, rotation: Double) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<sides {
            let angle = Double(index) * 2 * .pi / Double(sides) + rotation
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func star(in rect: CGRect, points: Int, innerRatio: CGFloat) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let outer = min(rect.width, rect.height) / 2 * 1.04
        let inner = outer * innerRatio
        var path = Path()
        for index in 0..<(points * 2) {
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = Double(index) * .pi / Double(points) - .pi / 2
            let point = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}
