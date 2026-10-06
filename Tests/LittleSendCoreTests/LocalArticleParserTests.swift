import XCTest
@testable import LittleSendCore

final class LocalReaderMappingTests: XCTestCase {

    private let requested = URL(string: "https://example.com/post")!

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func parse(_ object: [String: Any]) throws -> ParsedArticle {
        try LocalArticleParser.article(fromReadabilityJSON: json(object), requestedURL: requested)
    }

    func testMapsReadabilityOutputOntoParsedArticle() throws {
        let article = try parse([
            "ok": true,
            "title": "The Real Headline",
            "byline": "Jane Doe",
            "siteName": "Example",
            "excerpt": "A summary.",
            "content": "<p>Body text.</p>",
            "publishedTime": "2026-03-04T09:30:00Z",
            "url": "https://example.com/canonical",
        ])

        XCTAssertEqual(article.title, "The Real Headline")
        XCTAssertEqual(article.author, "Jane Doe")
        XCTAssertEqual(article.siteName, "Example")
        XCTAssertEqual(article.description, "A summary.")
        XCTAssertEqual(article.html, "<p>Body text.</p>")
        XCTAssertEqual(article.url, "https://example.com/canonical", "prefers the resolved URL")
        let expected = ISO8601DateFormatter().date(from: "2026-03-04T09:30:00Z")
        XCTAssertEqual(article.publishedDate, expected)
    }

    func testPaywallPreviewIsCarriedThrough() throws {
        let preview = try parse(["ok": true, "title": "T", "content": "<p>x</p>", "preview": true])
        XCTAssertTrue(preview.isPreview)

        let whole = try parse(["ok": true, "title": "T", "content": "<p>x</p>"])
        XCTAssertFalse(whole.isPreview, "no flag means the whole article")
    }

    /// The paywall check needs `await`, so the script is run as an async
    /// function body — an IIFE wrapper would return a Promise, not the JSON.
    func testExtractionScriptIsAnAsyncFunctionBody() {
        let script = LocalArticleParser.extractionScript
        XCTAssertFalse(script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("(function"))
        XCTAssertTrue(script.contains("await fetch(location.href"))
        XCTAssertTrue(script.contains("isAccessibleForFree"))
    }

    /// Server-side paywalls (WSJ) send only the preview, so comparing with
    /// the served page finds nothing; these signals catch them instead.
    func testExtractionScriptChecksServerSidePaywallSignals() {
        let script = LocalArticleParser.extractionScript
        XCTAssertTrue(script.contains("article:word_count"), "stated length in a meta tag")
        XCTAssertTrue(script.contains("node.wordCount"), "stated length in JSON-LD")
        XCTAssertTrue(script.contains("node.cssSelector"), "the gated section from hasPart markup")
    }

    func testBlankFieldsBecomeNil() throws {
        let article = try parse([
            "ok": true, "title": "T", "byline": "", "siteName": "   ",
            "excerpt": "", "content": "<p>x</p>", "publishedTime": "", "url": "",
        ])

        XCTAssertNil(article.author)
        XCTAssertNil(article.siteName)
        XCTAssertNil(article.description)
        XCTAssertNil(article.publishedDate)
        XCTAssertEqual(article.url, requested.absoluteString, "falls back to the requested URL")
    }

    func testSiteSuffixIsStrippedFromTheTitleJustLikeTheHostedParser() throws {
        let article = try parse([
            "ok": true,
            "title": "Some Story | The Verge",
            "siteName": "The Verge",
            "content": "<p>x</p>",
            "url": "https://www.theverge.com/x",
        ])
        XCTAssertEqual(article.title, "Some Story")
    }

    func testMissingTitleFallsBackToHost() throws {
        let article = try parse(["ok": true, "content": "<p>x</p>"])
        XCTAssertEqual(article.title, "example.com")
    }

    // MARK: - Failures

    func testNoArticleIsReportedDistinctly() {
        XCTAssertThrowsError(try parse(["ok": false, "reason": "no article"])) { error in
            guard case LocalArticleParser.Failure.noArticleFound = error else {
                return XCTFail("expected noArticleFound, got \(error)")
            }
        }
    }

    func testEmptyContentCountsAsNoArticle() {
        XCTAssertThrowsError(try parse(["ok": true, "title": "T", "content": "   "])) { error in
            guard case LocalArticleParser.Failure.noArticleFound = error else {
                return XCTFail("expected noArticleFound, got \(error)")
            }
        }
    }

    func testScriptErrorsSurfaceTheirReason() {
        XCTAssertThrowsError(try parse(["ok": false, "reason": "TypeError: boom"])) { error in
            XCTAssertTrue("\(error)".contains("boom") || (error as? LocalizedError)?.errorDescription?.contains("boom") == true)
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(
            try LocalArticleParser.article(
                fromReadabilityJSON: Data("not json".utf8), requestedURL: requested
            )
        )
    }

    // MARK: - Dates

    func testParsesCommonPublishedTimeFormats() {
        XCTAssertNotNil(LocalArticleParser.parseDate("2026-03-04T09:30:00Z"))
        XCTAssertNotNil(LocalArticleParser.parseDate("2026-03-04T09:30:00.123Z"))
        XCTAssertNotNil(LocalArticleParser.parseDate("2026-03-04"))
        XCTAssertNil(LocalArticleParser.parseDate("last Tuesday"))
    }

    // MARK: - Vendored resource

    func testReadabilityIsBundled() throws {
        let source = try LocalArticleParser.readabilitySource()
        XCTAssertTrue(source.contains("function Readability"), "vendored script looks wrong")
        XCTAssertTrue(source.contains("Apache License"), "license header must be retained")
        XCTAssertGreaterThan(source.count, 50_000)
    }
}
