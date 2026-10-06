import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Shrinks oversized images so an article with a dozen full-resolution photos
/// does not produce a book too large to email.
///
/// Quality is given up before resolution: the first attempts re-encode at the
/// original pixel size with progressively lower JPEG quality, and only then
/// does the image start losing pixels. That order keeps text in screenshots
/// readable for as long as possible.
public enum ImageResizer {

    /// Pixel ceilings tried in order. The first entry means "keep the original
    /// dimensions".
    static let pixelSteps: [Int?] = [nil, 2400, 1800, 1400, 1000, 700, 500]

    /// Quality steps tried at each pixel size.
    static let qualitySteps: [CGFloat] = [0.75, 0.55, 0.4]

    /// When the first quality step comes out more than this many times over
    /// the limit, the lower ones are skipped at that pixel size. Dropping from
    /// 0.75 to 0.4 saves roughly half, not two thirds, so they could not get
    /// there — and at full resolution each wasted encode of a large photo is
    /// the slowest thing the resizer does.
    static let hopelessOvershoot = 3

    public struct Result: Sendable, Equatable {
        public let data: Data
        public let mediaType: String
        /// False when the original was already small enough to keep untouched.
        public let wasResized: Bool
    }

    /// Returns an image no larger than `limit` bytes, or nil if the data cannot
    /// be decoded at all. If even the smallest attempt exceeds `limit`, the
    /// smallest attempt is returned rather than dropping the image entirely.
    public static func shrink(_ data: Data, toAtMost limit: Int) -> Result? {
        guard limit > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return nil }

        var smallest: Data?

        for (step, pixelLimit) in pixelSteps.enumerated() {
            guard let image = makeImage(from: source, maxPixelSize: pixelLimit) else { continue }
            // The last size always runs every quality, so the best-effort
            // result below is as small as it ever was.
            let isLastStep = step == pixelSteps.count - 1

            for quality in qualitySteps {
                guard let encoded = encodeJPEG(image, quality: quality) else { continue }
                if encoded.count <= limit {
                    return Result(data: encoded, mediaType: "image/jpeg", wasResized: true)
                }
                if encoded.count < (smallest?.count ?? Int.max) {
                    smallest = encoded
                }
                if !isLastStep, encoded.count / hopelessOvershoot > limit { break }
            }
        }

        // Best effort: still over the limit, but far smaller than the original.
        guard let smallest else { return nil }
        return Result(data: smallest, mediaType: "image/jpeg", wasResized: true)
    }

    /// Decodes at full size, or downsamples during decode when a ceiling is
    /// given — which avoids ever holding the full-resolution bitmap.
    static func makeImage(from source: CGImageSource, maxPixelSize: Int?) -> CGImage? {
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
