import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import LittleSendCore

final class ImageResizerTests: XCTestCase {

    /// A noisy image, so it does not compress down to nothing and actually
    /// exercises the size loop.
    private func makeImage(width: Int, height: Int, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))

        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        for x in stride(from: 0, to: width, by: 4) {
            for y in stride(from: 0, to: height, by: 4) {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                context.setFillColor(
                    red: CGFloat(seed & 0xFF) / 255,
                    green: CGFloat((seed >> 8) & 0xFF) / 255,
                    blue: CGFloat((seed >> 16) & 0xFF) / 255,
                    alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }

        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func dimensions(of data: Data) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    func testLargeImageIsBroughtUnderTheLimit() throws {
        let original = try makeImage(width: 2400, height: 1600)
        XCTAssertGreaterThan(original.count, 600 * 1024, "test image is not big enough to be interesting")

        let result = try XCTUnwrap(ImageResizer.shrink(original, toAtMost: 600 * 1024))

        XCTAssertLessThanOrEqual(result.data.count, 600 * 1024)
        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertTrue(result.wasResized)
    }

    func testAspectRatioIsPreserved() throws {
        let original = try makeImage(width: 2400, height: 1200)
        let result = try XCTUnwrap(ImageResizer.shrink(original, toAtMost: 120 * 1024))
        let size = try dimensions(of: result.data)

        XCTAssertEqual(Double(size.width) / Double(size.height), 2.0, accuracy: 0.02)
    }

    func testQualityIsGivenUpBeforeResolution() throws {
        // A limit that a re-encode alone can reach must not cost any pixels.
        let original = try makeImage(width: 900, height: 600)
        let result = try XCTUnwrap(ImageResizer.shrink(original, toAtMost: 200 * 1024))
        let size = try dimensions(of: result.data)

        XCTAssertLessThanOrEqual(result.data.count, 200 * 1024)
        XCTAssertEqual(size.width, 900, "resolution should survive when quality alone suffices")
    }

    func testVerySmallLimitStillReturnsAUsableImage() throws {
        // Better a degraded image than a hole where the picture was.
        let original = try makeImage(width: 2000, height: 2000)
        let result = try XCTUnwrap(ImageResizer.shrink(original, toAtMost: 4 * 1024))

        XCTAssertGreaterThan(result.data.count, 0)
        XCTAssertNotNil(CGImageSourceCreateWithData(result.data as CFData, nil))
    }

    func testNonImageDataIsRejected() {
        XCTAssertNil(ImageResizer.shrink(Data("not an image".utf8), toAtMost: 600 * 1024))
        XCTAssertNil(ImageResizer.shrink(Data(), toAtMost: 600 * 1024))
    }

    func testNonPositiveLimitIsRejected() throws {
        let original = try makeImage(width: 100, height: 100)
        XCTAssertNil(ImageResizer.shrink(original, toAtMost: 0))
    }

    func testOutputIsAlwaysDecodable() throws {
        let original = try makeImage(width: 1800, height: 1200)
        for limit in [600, 300, 100, 30] {
            let result = try XCTUnwrap(ImageResizer.shrink(original, toAtMost: limit * 1024))
            XCTAssertNotNil(
                CGImageSourceCreateWithData(result.data as CFData, nil),
                "output at \(limit)KB did not decode"
            )
        }
    }

    // MARK: - Settings plumbing

    func testLimitIsCarriedIntoTheConfiguration() {
        var draft = SettingsDraft(
            kindleAddress: "k@kindle.com", fromAddress: "me@x.com",
            smtpHost: "h", smtpPort: 465, smtpUsername: "u", smtpPassword: "p",
            instaparserAPIKey: "key"
        )
        draft.limitImageSize = true
        draft.maxImageKilobytes = 600
        XCTAssertEqual(draft.configuration.imageSizeLimitBytes, 600 * 1024)

        draft.maxImageKilobytes = 250
        XCTAssertEqual(draft.configuration.imageSizeLimitBytes, 250 * 1024)
    }

    func testSwitchingTheLimitOffEmbedsOriginals() {
        var draft = SettingsDraft(
            kindleAddress: "k@kindle.com", fromAddress: "me@x.com",
            smtpHost: "h", smtpPort: 465, smtpUsername: "u", smtpPassword: "p",
            instaparserAPIKey: "key"
        )
        draft.limitImageSize = false
        XCTAssertNil(draft.configuration.imageSizeLimitBytes)
    }

    func testZeroOrNegativeSizeIsClampedRatherThanDisablingImages() {
        var draft = SettingsDraft(
            kindleAddress: "k@kindle.com", fromAddress: "me@x.com",
            smtpHost: "h", smtpPort: 465, smtpUsername: "u", smtpPassword: "p",
            instaparserAPIKey: "key"
        )
        draft.limitImageSize = true
        draft.maxImageKilobytes = 0
        XCTAssertEqual(draft.configuration.imageSizeLimitBytes, 1024)

        draft.maxImageKilobytes = -50
        XCTAssertEqual(draft.configuration.imageSizeLimitBytes, 1024)
    }
}

final class ImageSourceLinkTests: XCTestCase {

    private let image = EmbeddedImage(
        sourceURL: "https://cdn.example.com/photos/big.jpg",
        fileName: "img0.jpg",
        mediaType: "image/jpeg",
        data: Data([0xFF, 0xD8, 0xFF]),
        wasResized: true
    )

    func testImageIsWrappedInALinkToTheOriginal() {
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<p><img src="https://cdn.example.com/photos/big.jpg"/></p>"#,
            using: [image]
        )
        XCTAssertEqual(
            output,
            #"<p><a href="https://cdn.example.com/photos/big.jpg"><img src="images/img0.jpg"/></a></p>"#
        )
    }

    func testImageAlreadyInsideALinkIsNotWrappedAgain() {
        // Nested anchors are invalid; the publisher's own link wins.
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<a href="https://example.com/story"><img src="https://cdn.example.com/photos/big.jpg"/></a>"#,
            using: [image]
        )
        XCTAssertEqual(
            output,
            #"<a href="https://example.com/story"><img src="images/img0.jpg"/></a>"#
        )
        XCTAssertEqual(output.components(separatedBy: "<a ").count - 1, 1)
    }

    func testLinkingResumesAfterAnAnchorCloses() {
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<a href="/x">text</a><img src="https://cdn.example.com/photos/big.jpg"/>"#,
            using: [image]
        )
        XCTAssertTrue(output.contains(#"<a href="https://cdn.example.com/photos/big.jpg"><img"#))
    }

    func testUndownloadedImagesAreStillRemoved() {
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<p><img src="https://other.example.com/missing.png"/></p>"#,
            using: [image]
        )
        XCTAssertEqual(output, "<p></p>")
    }

    func testSourceURLWithMarkupCharactersIsEscaped() {
        let tricky = EmbeddedImage(
            sourceURL: "https://cdn.example.com/a.jpg?w=1&h=2",
            fileName: "img0.jpg", mediaType: "image/jpeg", data: Data()
        )
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<img src="https://cdn.example.com/a.jpg?w=1&amp;h=2"/>"#,
            using: [tricky]
        )
        XCTAssertTrue(output.contains("&amp;"))
        XCTAssertTrue(EPUBBuilder.isWellFormed(fragment: output), output)
    }

    func testSurroundingMarkupIsUntouched() {
        let output = EPUBBuilder.rewriteImageReferences(
            in: #"<h2>Heading</h2><p>Text with &lt; entity</p>"#,
            using: [image]
        )
        XCTAssertEqual(output, #"<h2>Heading</h2><p>Text with &lt; entity</p>"#)
    }
}
