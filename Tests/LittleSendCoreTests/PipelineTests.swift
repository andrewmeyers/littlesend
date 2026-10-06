import XCTest
import ImageIO
@testable import LittleSendCore

final class ConfigurationTests: XCTestCase {

    private func configuration(
        kindle: String = "me@kindle.com", from: String = "me@gmail.com",
        host: String = "smtp.gmail.com", user: String = "me@gmail.com", password: String = "p"
    ) -> SendConfiguration {
        SendConfiguration(
            kindleAddress: kindle, fromAddress: from,
            smtpHost: host, smtpPort: 465, smtpUsername: user, smtpPassword: password
        )
    }

    func testCompleteConfigurationValidates() {
        XCTAssertTrue(configuration().validationProblems.isEmpty)
    }

    func testEachMissingFieldIsReported() {
        XCTAssertTrue(configuration(kindle: "not-an-email").validationProblems.contains { $0.contains("Kindle") })
        XCTAssertTrue(configuration(from: "").validationProblems.contains { $0.contains("Sender") })
        XCTAssertTrue(configuration(host: "").validationProblems.contains { $0.contains("Mail server") })
        XCTAssertTrue(configuration(password: "").validationProblems.contains { $0.contains("password") })
    }

    func testEmailShapeCheck() {
        XCTAssertTrue(SendConfiguration.looksLikeEmail("a@b.com"))
        XCTAssertFalse(SendConfiguration.looksLikeEmail("a@b"))
        XCTAssertFalse(SendConfiguration.looksLikeEmail("@b.com"))
        XCTAssertFalse(SendConfiguration.looksLikeEmail("a@@b.com"))
    }
}

final class CoverGeneratorTests: XCTestCase {

    private func article(title: String = "A Reasonably Long Article Title About Things") -> ParsedArticle {
        ParsedArticle(
            url: "https://example.com/post", title: title, siteName: "Example",
            author: "Jane Doe", html: "<p>x</p>",
            publishedDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testColourCoverIsAJPEGOfTheExpectedSize() throws {
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), optimizeForEInk: false)
        )

        XCTAssertEqual(cover.mediaType, "image/jpeg")
        XCTAssertEqual(cover.fileName, "cover.jpg")
        XCTAssertEqual([UInt8](cover.data.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")
        XCTAssertGreaterThan(cover.data.count, 5_000)

        let source = try XCTUnwrap(CGImageSourceCreateWithData(cover.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(CoverGenerator.size.width))
        XCTAssertEqual(image.height, Int(CoverGenerator.size.height))
    }

    func testEInkCoverIsALosslessPNG() throws {
        // Lossless matters here specifically: the greys are chosen to land on
        // the panel's own levels, and JPEG moves them off.
        let cover = try XCTUnwrap(
            CoverGenerator.makeCover(article: article(), optimizeForEInk: true)
        )

        XCTAssertEqual(cover.mediaType, "image/png")
        XCTAssertEqual(cover.fileName, "cover.png")
        XCTAssertEqual([UInt8](cover.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "not a PNG")

        let source = try XCTUnwrap(CGImageSourceCreateWithData(cover.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, Int(CoverGenerator.size.width))
        XCTAssertEqual(image.height, Int(CoverGenerator.size.height))
    }

    func testHandlesExtremeTitlesWithoutFailing() throws {
        XCTAssertNotNil(CoverGenerator.makeCover(article: article(title: "")))
        XCTAssertNotNil(CoverGenerator.makeCover(article: article(title: String(repeating: "Long ", count: 60))))
        XCTAssertNotNil(CoverGenerator.makeCover(article: article(title: "日本語のタイトル")))
    }

    func testTintIsStablePerDomain() {
        let first = CoverGenerator.accentColor(for: article())
        let second = CoverGenerator.accentColor(for: article(title: "Different Title"))
        XCTAssertEqual(first.background.components, second.background.components)
    }

    func testPossibilityBoldResolvesOnThisMachine() {
        // Guards against a silent CoreText substitution going unnoticed.
        XCTAssertTrue(
            CoverGenerator.isDisplayFontAvailable,
            "Possibility-Bold is not installed; covers would fall back to Georgia"
        )
    }
}

final class ImageFormatTests: XCTestCase {

    func testSniffsCommonFormats() {
        XCTAssertEqual(ImageFetcher.sniffFormat(Data([0xFF, 0xD8, 0xFF] + [UInt8](repeating: 0, count: 13))), "image/jpeg")
        XCTAssertEqual(ImageFetcher.sniffFormat(Data([0x89, 0x50, 0x4E, 0x47] + [UInt8](repeating: 0, count: 12))), "image/png")
        XCTAssertEqual(ImageFetcher.sniffFormat(Data(Array("GIF89a".utf8) + [UInt8](repeating: 0, count: 10))), "image/gif")

        var webp = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)
        webp += [UInt8](repeating: 0, count: 4)
        XCTAssertEqual(ImageFetcher.sniffFormat(Data(webp)), "image/webp")
    }

    func testRejectsNonImageData() {
        XCTAssertNil(ImageFetcher.sniffFormat(Data("<html><body>404</body></html>".utf8)))
        XCTAssertNil(ImageFetcher.sniffFormat(Data()))
    }

    func testOnlyCoreEPUBTypesPassThroughUntouched() {
        XCTAssertEqual(ImageFetcher.epubSafeMediaType(for: "image/png"), "image/png")
        XCTAssertEqual(ImageFetcher.epubSafeMediaType(for: "image/jpeg"), "image/jpeg")
        XCTAssertNil(ImageFetcher.epubSafeMediaType(for: "image/webp"), "WebP must be transcoded")
        XCTAssertNil(ImageFetcher.epubSafeMediaType(for: "image/avif"))
    }
}
