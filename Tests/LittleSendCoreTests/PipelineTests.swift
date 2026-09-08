import XCTest
import ImageIO
@testable import LittleSendCore

final class InstaparserDecodingTests: XCTestCase {

    private let requested = URL(string: "https://example.com/post")!

    func testDecodesFullResponse() throws {
        let json = """
        {"url":"https://example.com/canonical","title":"The Title","site_name":"Example",
         "author":"Jane Doe","description":"Sub","html":"<p>Body</p>","date":1700000000,
         "words":420,"is_rtl":false}
        """
        let article = try InstaparserClient.decode(data: Data(json.utf8), requestedURL: requested)

        XCTAssertEqual(article.url, "https://example.com/canonical")
        XCTAssertEqual(article.title, "The Title")
        XCTAssertEqual(article.author, "Jane Doe")
        XCTAssertEqual(article.wordCount, 420)
        XCTAssertEqual(article.publishedDate, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testNullAndEmptyFieldsBecomeNil() throws {
        let json = """
        {"title":"T","html":"<p>x</p>","author":null,"site_name":"","description":"   ","date":0}
        """
        let article = try InstaparserClient.decode(data: Data(json.utf8), requestedURL: requested)

        XCTAssertNil(article.author)
        XCTAssertNil(article.siteName)
        XCTAssertNil(article.description)
        XCTAssertNil(article.publishedDate)
        XCTAssertEqual(article.url, requested.absoluteString, "falls back to the requested URL")
    }

    func testMissingTitleFallsBackToHost() throws {
        let json = #"{"html":"<p>x</p>"}"#
        let article = try InstaparserClient.decode(data: Data(json.utf8), requestedURL: requested)
        XCTAssertEqual(article.title, "example.com")
    }

    func testTextOutputIsAcceptedWhenHTMLIsAbsent() throws {
        let json = #"{"title":"T","text":"Plain body"}"#
        let article = try InstaparserClient.decode(data: Data(json.utf8), requestedURL: requested)
        XCTAssertEqual(article.html, "Plain body")
    }

    func testEmptyBodyIsRejected() {
        let json = #"{"title":"T","html":"   "}"#
        XCTAssertThrowsError(try InstaparserClient.decode(data: Data(json.utf8), requestedURL: requested))
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try InstaparserClient.decode(data: Data("not json".utf8), requestedURL: requested))
    }

    func testStatusMessagesAreActionable() {
        XCTAssertTrue(InstaparserClient.describe(status: 401, body: Data()).contains("API key"))
        XCTAssertTrue(InstaparserClient.describe(status: 409, body: Data()).contains("quota"))
        XCTAssertTrue(InstaparserClient.describe(status: 412, body: Data()).contains("could not extract"))
        XCTAssertTrue(InstaparserClient.describe(status: 429, body: Data()).contains("rate limit"))
    }

    func testServerDetailIsIncluded() {
        let body = Data(#"{"error":"bad url"}"#.utf8)
        XCTAssertTrue(InstaparserClient.describe(status: 400, body: body).contains("bad url"))
    }
}

final class ConfigurationTests: XCTestCase {

    private func configuration(
        key: String = "k", kindle: String = "me@kindle.com", from: String = "me@gmail.com",
        host: String = "smtp.gmail.com", user: String = "me@gmail.com", password: String = "p"
    ) -> SendConfiguration {
        SendConfiguration(
            instaparserAPIKey: key, kindleAddress: kindle, fromAddress: from,
            smtpHost: host, smtpPort: 465, smtpUsername: user, smtpPassword: password
        )
    }

    func testCompleteConfigurationValidates() {
        XCTAssertTrue(configuration().validationProblems.isEmpty)
    }

    func testEachMissingFieldIsReported() {
        XCTAssertTrue(configuration(key: "").validationProblems.contains { $0.contains("API key") })
        XCTAssertTrue(configuration(kindle: "not-an-email").validationProblems.contains { $0.contains("Kindle") })
        XCTAssertTrue(configuration(from: "").validationProblems.contains { $0.contains("Sender") })
        XCTAssertTrue(configuration(host: "").validationProblems.contains { $0.contains("SMTP server") })
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
