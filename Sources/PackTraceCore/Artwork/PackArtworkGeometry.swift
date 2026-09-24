import CoreGraphics

/// The sealed pack's on-screen frame. Shared so the tear geometry, the artwork
/// split and the view can never drift apart.
public enum PackWrapFrame {
    public static let width: CGFloat = 300
    public static let height: CGFloat = 430
    /// Height of the torn-off strip.
    public static let stripHeight: CGFloat = 92
    /// Where the tear line crosses the pack, as a fraction of its height.
    public static var seamFraction: Double { Double(stripHeight / height) }
}

/// Where a pack picture sits inside the pack frame, and how the tear line splits
/// it. Pure geometry: the strip and the body are two masks over one image, so
/// they always share a scale and the printed artwork stays continuous.
public struct PackArtworkGeometry: Hashable, Sendable {
    public var frame: CGSize
    /// Pixel size of the artwork being drawn.
    public var artworkSize: CGSize
    /// Tear line, as a fraction of the drawn artwork's height.
    public var seamFraction: Double

    public init(
        frame: CGSize,
        artworkSize: CGSize,
        seamFraction: Double = PackWrapFrame.seamFraction
    ) {
        self.frame = frame
        self.artworkSize = artworkSize
        self.seamFraction = min(max(seamFraction, 0), 1)
    }

    /// Frame points per artwork pixel. One scale for both pieces.
    public var scale: CGFloat {
        guard artworkSize.width > 0, artworkSize.height > 0 else { return 1 }
        return min(frame.width / artworkSize.width, frame.height / artworkSize.height)
    }

    /// The largest artwork that fits the frame without distortion, centred.
    public var artRect: CGRect {
        let drawn = CGSize(width: artworkSize.width * scale, height: artworkSize.height * scale)
        return CGRect(
            x: (frame.width - drawn.width) / 2,
            y: (frame.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// Frame-space y of the tear line, measured on the artwork itself so a
    /// letter-boxed picture is still torn at the same printed height.
    public var seamY: CGFloat {
        artRect.minY + CGFloat(seamFraction) * artRect.height
    }

    public var stripWindow: CGRect {
        CGRect(x: 0, y: 0, width: frame.width, height: seamY)
    }

    public var bodyWindow: CGRect {
        CGRect(x: 0, y: seamY, width: frame.width, height: frame.height - seamY)
    }

    /// Artwork pixels above the tear line, in frame space.
    public var stripRect: CGRect { artRect.intersection(stripWindow) }

    /// Artwork pixels below the tear line, in frame space.
    public var bodyRect: CGRect { artRect.intersection(bodyWindow) }

    /// The two pieces must cover the artwork exactly once and stay at one scale.
    public var isContinuous: Bool {
        guard !artRect.isEmpty else { return true }
        let covered = stripRect.height + bodyRect.height
        return abs(covered - artRect.height) < 0.5
            && abs(stripRect.width - bodyRect.width) < 0.5
            && abs(stripRect.maxY - bodyRect.minY) < 0.5
    }

    /// True when the drawn artwork keeps the source aspect ratio.
    public var preservesArtworkAspect: Bool {
        guard artworkSize.height > 0, artRect.height > 0 else { return true }
        let source = artworkSize.width / artworkSize.height
        let drawn = artRect.width / artRect.height
        return abs(source - drawn) < 0.001
    }

    /// Maps a frame-space rectangle back to artwork pixels (top-left origin),
    /// which is what a test can crop to prove the two pieces line up.
    public func artworkPixels(forFrameRect rect: CGRect) -> CGRect {
        guard scale > 0 else { return .zero }
        let origin = CGPoint(
            x: (rect.minX - artRect.minX) / scale,
            y: (rect.minY - artRect.minY) / scale
        )
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: rect.width / scale,
            height: rect.height / scale
        )
    }

    /// Pixels each piece shows. `strip` plus `body` is the whole artwork.
    public func sourcePixelRects() -> (strip: CGRect, body: CGRect) {
        (artworkPixels(forFrameRect: stripRect), artworkPixels(forFrameRect: bodyRect))
    }
}
