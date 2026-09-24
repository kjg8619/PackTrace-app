import AppKit
import PackTraceCore
import SwiftUI

/// Visual language: dark slate background, foil accents, one card frame used
/// everywhere so a card always looks like the same object.
enum Palette {
    static let backdrop = Color(red: 0.055, green: 0.063, blue: 0.086)
    static let panel = Color(red: 0.098, green: 0.109, blue: 0.145)
    static let panelRaised = Color(red: 0.137, green: 0.152, blue: 0.196)
    static let hairline = Color.white.opacity(0.09)
    static let ink = Color(red: 0.93, green: 0.94, blue: 0.97)
    static let inkMuted = Color(red: 0.62, green: 0.65, blue: 0.73)
    static let accent = Color(red: 0.42, green: 0.78, blue: 0.98)
    static let accentWarm = Color(red: 0.99, green: 0.72, blue: 0.35)
    static let danger = Color(red: 0.98, green: 0.45, blue: 0.45)
    static let success = Color(red: 0.45, green: 0.86, blue: 0.62)
    static let demoBadge = Color(red: 0.62, green: 0.55, blue: 0.98)

    static func rarityColor(_ rarity: CardRarity) -> Color {
        switch rarity.rawValue {
        case "Common": Color(red: 0.72, green: 0.76, blue: 0.82)
        case "Uncommon": Color(red: 0.55, green: 0.85, blue: 0.6)
        case "Rare": Color(red: 0.45, green: 0.72, blue: 0.98)
        case "Double rare": Color(red: 0.62, green: 0.62, blue: 0.99)
        case "Ultra Rare": Color(red: 0.78, green: 0.6, blue: 0.99)
        case "Illustration rare": Color(red: 0.99, green: 0.72, blue: 0.45)
        case "Special illustration rare": Color(red: 0.99, green: 0.55, blue: 0.72)
        case "Hyper rare": Color(red: 0.99, green: 0.86, blue: 0.4)
        case "ACE SPEC Rare": Color(red: 0.98, green: 0.45, blue: 0.85)
        case "Holo Rare", "Rare Holo": Color(red: 0.4, green: 0.8, blue: 0.95)
        case "Rare Holo LV.X", "Holo Rare V", "Holo Rare VMAX", "Holo Rare VSTAR", "Rare PRIME", "LEGEND":
            Color(red: 0.72, green: 0.62, blue: 0.99)
        case "Secret Rare", "Mega Hyper Rare", "Black White Rare": Color(red: 0.99, green: 0.8, blue: 0.35)
        case "Amazing Rare", "Radiant Rare", "Futuristic Rare": Color(red: 0.99, green: 0.62, blue: 0.5)
        case "Shiny rare", "Shiny rare V", "Shiny rare VMAX", "Shiny Ultra Rare": Color(red: 0.6, green: 0.9, blue: 0.9)
        case "Full Art Trainer", "Classic Collection", "Pikachu Rare": Color(red: 0.95, green: 0.75, blue: 0.55)
        default: inkMuted
        }
    }
}

/// Shared panel container.
struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Palette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
    }
}

struct SectionTitle: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricTile: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = Palette.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.inkMuted)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.inkMuted)
                    .lineLimit(2)
            }
        }
        .padding(14)
        // Fills the row's height, so tiles side by side in a row that is
        // `.fixedSize(horizontal: false, vertical: true)` line up.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.hairline, lineWidth: 1)
        )
    }
}

struct BadgeView: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// Reference detail that most visits do not need: collapsed until asked for.
struct DetailsDisclosure<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.ink)
        }
        .tint(Palette.inkMuted)
    }
}

struct NoticeBanner: View {
    var title: String
    var message: String
    var color: Color
    var icon: String = "info.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35), lineWidth: 1))
    }
}

extension Date {
    /// Display timestamps in the user's locale; stored values stay UTC.
    var packTraceDisplay: String {
        formatted(date: .abbreviated, time: .shortened)
    }

    var packTraceDay: String {
        formatted(date: .abbreviated, time: .omitted)
    }
}
