import AppKit
import SwiftUI
import Testing

@testable import PackTraceUI

/// PackTrace's own card back: its responsive layout, that it says nothing about
/// the card, and that it renders at the two sizes the opening uses.
@Suite("카드 뒷면")
@MainActor
struct CardBackTests {
    @Test("작은 뒷면은 마크만, 큰 뒷면은 워드마크까지 그린다")
    func wordmarkOnlyWhereItReads() {
        let deck = CardBackLayout(width: 150)
        let spotlight = CardBackLayout(width: 300)
        #expect(deck.showsWordmark == false, "150pt에서는 글자가 뭉개집니다")
        #expect(spotlight.showsWordmark)
        #expect(spotlight.wordmarkSize >= 9)
        for layout in [deck, spotlight] {
            // The frame sits inside the card, the hairline inside the frame, and
            // the mark stays well clear of both.
            #expect(layout.outerInset > 0 && layout.outerInset < layout.innerInset)
            #expect(layout.innerInset < layout.width / 4)
            // The diamond is the mark rotated 45°, so its reach is side × √2 / 2.
            let markReach = layout.markSize * 2.squareRoot() / 2
            #expect(markReach < layout.width / 2 - layout.innerInset, "마크가 테두리에 닿습니다")
            #expect(abs(layout.height - layout.width * 825 / 600) < 0.001)
        }
        // The wordmark sits below the mark and above the bottom frame.
        let reach = spotlight.markSize * 2.squareRoot() / 2
        #expect(spotlight.wordmarkOffset > reach)
        #expect(spotlight.wordmarkOffset + spotlight.wordmarkSize < spotlight.height / 2 - spotlight.innerInset)
    }

    @Test("뒷면의 접근성 문구는 카드 정보를 담지 않는다")
    func accessibilityIsTheUnrevealedLabel() {
        #expect(CardBackView.accessibilityText == SpotlightAccessibility.unrevealedLabel)
        #expect(CardBackView.accessibilityText == "미공개 카드")
    }

    @Test("150pt와 300pt에서 모서리까지 온전히 렌더된다")
    func rendersAtDeckAndSpotlightSizes() throws {
        for width in [CGFloat(150), 300] {
            let renderer = ImageRenderer(content: CardBackView().frame(width: width))
            renderer.scale = 1
            let image = try #require(renderer.cgImage, "\(width)pt 렌더 실패")
            #expect(image.width == Int(width))
            #expect(abs(image.height - Int((width * 825 / 600).rounded())) <= 1)

            let pixels = try Pixels(image)
            // Rounded corners: the very corner is outside the card.
            #expect(pixels.alpha(x: 0, y: 0) < 0.1, "\(width)pt: 모서리가 잘리지 않았습니다")
            #expect(pixels.alpha(x: image.width - 1, y: image.height - 1) < 0.1)
            // The field is opaque everywhere inside, including next to the edges.
            #expect(pixels.alpha(x: image.width / 2, y: 2) > 0.95, "\(width)pt: 위쪽 테두리 안이 비었습니다")
            #expect(pixels.alpha(x: 2, y: image.height / 2) > 0.95)
            // The mark is brighter than the field around it, at the centre.
            let centre = pixels.luminance(x: image.width / 2, y: image.height / 2)
            let field = pixels.luminance(x: image.width / 2, y: Int(Double(image.height) * 0.12))
            #expect(centre > field, "\(width)pt: 가운데 마크가 보이지 않습니다")

            // All four sides of the foil frame are on the card: each side's line
            // is brighter than the field just inside it. (A layer taller than the
            // card once pushed the top and bottom sides off it.)
            let layout = CardBackLayout(width: width)
            let line = Int(layout.outerInset + layout.frameLine / 2)
            let gap = max(2, Int((layout.innerInset - layout.outerInset) / 2))
            let midX = image.width / 2
            let midY = image.height / 2
            let sides: [(name: String, onLine: (Int, Int), inside: (Int, Int))] = [
                ("top", (midX, line), (midX, line + gap)),
                ("bottom", (midX, image.height - 1 - line), (midX, image.height - 1 - line - gap)),
                ("left", (line, midY), (line + gap, midY)),
                ("right", (image.width - 1 - line, midY), (image.width - 1 - line - gap, midY)),
            ]
            for side in sides {
                let onLine = pixels.luminance(x: side.onLine.0, y: side.onLine.1)
                let inside = pixels.luminance(x: side.inside.0, y: side.inside.1)
                #expect(onLine > inside + 0.08, "\(width)pt: \(side.name) 테두리가 없습니다 (\(onLine) vs \(inside))")
            }
        }
    }
}

/// RGBA8 pixels of a rendered image, for coarse checks only.
struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        // The context writes into the buffer only inside this closure, where the
        // pointer is valid. Row 0 of a bitmap context's memory is the top row.
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CocoaError(.featureUnsupported) }
        bytes = buffer
    }

    /// `y` counts from the top, like the view.
    private func index(_ x: Int, _ y: Int) -> Int {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        return (cy * width + cx) * 4
    }

    func alpha(x: Int, y: Int) -> Double {
        Double(bytes[index(x, y) + 3]) / 255
    }

    func luminance(x: Int, y: Int) -> Double {
        let i = index(x, y)
        return (0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1]) + 0.0722 * Double(bytes[i + 2])) / 255
    }
}
