import SwiftUI

/// Proportions of the card back, from its width.
///
/// Pure, so the responsive rule can be tested: everything scales with the card,
/// and below `wordmarkMinWidth` the wordmark is left out rather than drawn at a
/// size where it would blur into a smudge (the deck draws backs at 150pt, the
/// spotlight at 300pt).
struct CardBackLayout: Equatable {
    var width: CGFloat

    static let aspect: CGFloat = 825.0 / 600.0
    static let wordmarkMinWidth: CGFloat = 200

    var height: CGFloat { width * Self.aspect }
    var cornerRadius: CGFloat { max(4, width * 0.04) }
    /// The foil frame, and the hairline just inside it.
    var outerInset: CGFloat { width * 0.045 }
    var innerInset: CGFloat { width * 0.075 }
    var frameLine: CGFloat { max(1, width * 0.008) }
    var hairline: CGFloat { max(0.5, width * 0.003) }
    /// Side of the diamond that holds the mark.
    var markSize: CGFloat { width * 0.3 }
    var showsWordmark: Bool { width >= Self.wordmarkMinWidth }
    var wordmarkSize: CGFloat { max(9, width * 0.04) }
    /// Below the mark, clear of it and of the frame.
    var wordmarkOffset: CGFloat { markSize * 0.72 + wordmarkSize * 1.4 }
    var ringDiameters: [CGFloat] { [0.62, 0.86, 1.12].map { width * $0 } }
    var ringLine: CGFloat { max(0.75, width * 0.004) }
}

/// PackTrace's own card back: the face of every card that has not been turned
/// over — the deck in the pack, the card waiting in the spotlight, and the back
/// side of the flip.
///
/// Original to PackTrace and deliberately unlike any trading card game's back: a
/// navy-to-slate field, faint rings, diagonal foil light, a thin foil double
/// frame and a diamond "P" mark, in the app's own palette. Built from shapes, so
/// it is sharp at any size and needs no bundled image. It carries nothing about
/// the card it hides.
struct CardBackView: View {
    /// Read out for every back: a card that has not been turned over does not say
    /// what it is.
    static let accessibilityText = SpotlightAccessibility.unrevealedLabel

    static let fieldTop = Color(red: 0.07, green: 0.10, blue: 0.19)
    static let fieldBottom = Color(red: 0.14, green: 0.16, blue: 0.26)
    static let foil = LinearGradient(
        colors: [Palette.accent, Palette.ink, Palette.accentWarm, Palette.accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    var body: some View {
        GeometryReader { proxy in
            let layout = CardBackLayout(width: proxy.size.width)
            ZStack {
                LinearGradient(colors: [Self.fieldTop, Self.fieldBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [Palette.accent.opacity(0.2), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: layout.width * 0.62
                )
                rings(layout)
                foilLight(layout)
                frame(layout)
                mark(layout)
                if layout.showsWordmark {
                    Text("PACKTRACE")
                        .font(.system(size: layout.wordmarkSize, weight: .semibold, design: .rounded))
                        .tracking(layout.wordmarkSize * 0.35)
                        .foregroundStyle(Palette.ink.opacity(0.6))
                        .fixedSize()
                        .offset(y: layout.wordmarkOffset)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous))
        }
        .aspectRatio(1 / CardBackLayout.aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText)
    }

    private func rings(_ layout: CardBackLayout) -> some View {
        ZStack {
            ForEach(Array(layout.ringDiameters.enumerated()), id: \.offset) { index, diameter in
                Circle()
                    .stroke(Palette.accent.opacity(0.16 - Double(index) * 0.04), lineWidth: layout.ringLine)
                    .frame(width: diameter, height: diameter)
            }
        }
        .frame(width: layout.width, height: layout.height)
    }

    /// Three soft diagonal bands, like light on a foil surface. Static.
    private func foilLight(_ layout: CardBackLayout) -> some View {
        let bands: [(offset: CGFloat, width: CGFloat, opacity: Double)] = [
            (-0.34, 0.1, 0.07), (-0.16, 0.035, 0.09), (0.3, 0.07, 0.05),
        ]
        // Laid out at the card's own size: the bands overhang it (they are
        // clipped with the card), but must not make this layer taller than the
        // card, or every layer centred with it would be stretched too.
        return ZStack {
            ForEach(Array(bands.enumerated()), id: \.offset) { _, band in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(band.opacity), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: layout.width * band.width, height: layout.height * 1.6)
                    .offset(x: layout.width * band.offset)
                    .rotationEffect(.degrees(28))
            }
        }
        .frame(width: layout.width, height: layout.height)
        .blendMode(.plusLighter)
    }

    private func frame(_ layout: CardBackLayout) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(2, layout.cornerRadius - layout.outerInset * 0.5), style: .continuous)
                .strokeBorder(Self.foil, lineWidth: layout.frameLine)
                .padding(layout.outerInset)
                .opacity(0.8)
            RoundedRectangle(cornerRadius: max(2, layout.cornerRadius - layout.innerInset * 0.5), style: .continuous)
                .strokeBorder(Palette.ink.opacity(0.14), lineWidth: layout.hairline)
                .padding(layout.innerInset)
        }
        .frame(width: layout.width, height: layout.height)
    }

    /// A diamond with a rounded "P" — PackTrace's mark, centred on the card.
    private func mark(_ layout: CardBackLayout) -> some View {
        let side = layout.markSize
        return ZStack {
            RoundedRectangle(cornerRadius: side * 0.14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Self.fieldTop.opacity(0.9), Palette.panelRaised],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.14, style: .continuous)
                        .strokeBorder(Self.foil, lineWidth: layout.frameLine)
                )
                .frame(width: side, height: side)
                .rotationEffect(.degrees(45))
                .shadow(color: Palette.accent.opacity(0.35), radius: side * 0.12)
            Text("P")
                .font(.system(size: side * 0.62, weight: .heavy, design: .rounded))
                .foregroundStyle(Self.foil)
                .fixedSize()
        }
    }
}
