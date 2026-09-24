import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Container an artwork file claims to be, read from its leading bytes rather
/// than from its address.
public enum PackArtworkImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg
    case webp
    case unknown

    public var fileExtension: String { rawValue }
}

/// What a file turned out to be after checking, not what it was called.
public struct PackArtworkImageInfo: Hashable, Sendable {
    public var format: PackArtworkImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAlpha: Bool
    public var byteCount: Int
    public var sha256: String
}

public enum PackArtworkValidationError: Error, Equatable, Sendable {
    case tooLarge(bytes: Int, limit: Int)
    case unrecognisedFormat
    case undecodable
    case tooManyPixels(width: Int, height: Int, limit: Int)
    case hashMismatch(expected: String, actual: String)
    case dimensionMismatch(expected: String, actual: String)

    public var displayMessage: String {
        switch self {
        case let .tooLarge(bytes, limit):
            "파일이 너무 큽니다(\(bytes)바이트 > \(limit))"
        case .unrecognisedFormat:
            "이미지 형식이 아닙니다(HTML 오류 페이지 등)"
        case .undecodable:
            "이미지를 해석할 수 없습니다(손상된 파일)"
        case let .tooManyPixels(width, height, limit):
            "이미지 픽셀 수가 한도를 넘습니다(\(width)x\(height) > \(limit))"
        case let .hashMismatch(expected, actual):
            "해시 불일치(기대 \(expected.prefix(12))…, 실제 \(actual.prefix(12))…)"
        case let .dimensionMismatch(expected, actual):
            "해상도 불일치(기대 \(expected), 실제 \(actual))"
        }
    }
}

/// Checks and prepares pack artwork on the way into the local asset store.
///
/// HTTP success is not evidence, and neither is a file extension: every check
/// here reads the bytes. Decoding successfully only means the file is an image —
/// whether the rights to use it are established is `PackArtworkSource.rights`.
public enum PackArtworkValidator {
    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Container format from the leading bytes. A downloaded HTML error page is
    /// `unknown`, never an image.
    public static func format(of data: Data) -> PackArtworkImageFormat {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 8, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if bytes.count >= 3, bytes[0...2] == [0xFF, 0xD8, 0xFF] { return .jpeg }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return .webp
        }
        return .unknown
    }

    /// Reads the metadata and proves the pixels decode, without building the
    /// full-size bitmap.
    public static func inspect(
        _ data: Data,
        limits: (maxBytes: Int, maxPixelCount: Int, maxDimension: Int) = (
            PackArtworkLimits.maxSourceBytes,
            PackArtworkLimits.maxPixelCount,
            PackArtworkLimits.maxPixelDimension
        )
    ) throws -> PackArtworkImageInfo {
        guard !data.isEmpty else { throw PackArtworkValidationError.undecodable }
        guard data.count <= limits.maxBytes else {
            throw PackArtworkValidationError.tooLarge(bytes: data.count, limit: limits.maxBytes)
        }
        let format = format(of: data)
        guard format != .unknown else { throw PackArtworkValidationError.unrecognisedFormat }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PackArtworkValidationError.undecodable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw PackArtworkValidationError.undecodable }
        // Pixel limits are checked from the header, before any decode.
        guard width <= limits.maxDimension, height <= limits.maxDimension,
              width * height <= limits.maxPixelCount
        else {
            throw PackArtworkValidationError.tooManyPixels(width: width, height: height, limit: limits.maxPixelCount)
        }
        // A real decode at thumbnail size: proves the pixel data is usable.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary) != nil else {
            throw PackArtworkValidationError.undecodable
        }
        return PackArtworkImageInfo(
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            hasAlpha: (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false,
            byteCount: data.count,
            sha256: sha256(of: data)
        )
    }

    /// Resamples so the longest edge is at most `maxPixelSize`, keeping the
    /// aspect ratio and any transparency, and re-encodes as PNG. Nothing is
    /// cropped, rotated or painted over: this is a size change only.
    public static func normalise(
        _ data: Data,
        maxPixelSize: Int = PackArtworkLimits.normalizedMaxPixelSize
    ) throws -> (data: Data, width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PackArtworkValidationError.undecodable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PackArtworkValidationError.undecodable
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw PackArtworkValidationError.undecodable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PackArtworkValidationError.undecodable
        }
        return (output as Data, image.width, image.height)
    }

    /// Confirms downloaded bytes are the file the registry recorded.
    public static func verifyOriginal(
        _ data: Data,
        expectedSHA256: String,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> PackArtworkImageInfo {
        let info = try inspect(data)
        guard info.sha256 == expectedSHA256 else {
            throw PackArtworkValidationError.hashMismatch(expected: expectedSHA256, actual: info.sha256)
        }
        guard info.pixelWidth == expectedWidth, info.pixelHeight == expectedHeight else {
            throw PackArtworkValidationError.dimensionMismatch(
                expected: "\(expectedWidth)x\(expectedHeight)",
                actual: "\(info.pixelWidth)x\(info.pixelHeight)"
            )
        }
        return info
    }

    /// Confirms an installed file is the normalised image the registry records.
    public static func verifyInstalled(_ data: Data, descriptor: PackArtworkDescriptor) throws -> PackArtworkImageInfo {
        let info = try inspect(data, limits: (
            PackArtworkLimits.maxInstalledBytes,
            PackArtworkLimits.maxPixelCount,
            PackArtworkLimits.maxPixelDimension
        ))
        guard info.sha256 == descriptor.contentSHA256 else {
            throw PackArtworkValidationError.hashMismatch(
                expected: descriptor.contentSHA256,
                actual: info.sha256
            )
        }
        guard info.pixelWidth == descriptor.pixelWidth, info.pixelHeight == descriptor.pixelHeight else {
            throw PackArtworkValidationError.dimensionMismatch(
                expected: "\(descriptor.pixelWidth)x\(descriptor.pixelHeight)",
                actual: "\(info.pixelWidth)x\(info.pixelHeight)"
            )
        }
        return info
    }
}
