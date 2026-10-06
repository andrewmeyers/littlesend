import XCTest
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

final class ArticleReadingTests: XCTestCase {
    private let url = URL(string: "https://example.com/post")!

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private func article(_ title: String) -> ParsedArticle {
        ParsedArticle(url: url.absoluteString, title: title, html: "<p>x</p>")
    }

    func testBuiltInReaderNeverCallsInstaparser() async throws {
        let result = try await ArticleReading.read(
            url: url, reader: .local, instaparserAPIKey: "key",
            instaparser: { _, _ in XCTFail("Instaparser was called"); return self.article("remote") },
            local: { _ in self.article("local") }
        )
        XCTAssertEqual(result.article.title, "local")
        XCTAssertNil(result.note)
    }

    func testInstaparserIsUsedWithTheTrimmedKey() async throws {
        let result = try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "  abc123 \n",
            instaparser: { _, key in
                XCTAssertEqual(key, "abc123")
                return self.article("remote")
            },
            local: { _ in XCTFail("fell back needlessly"); return self.article("local") }
        )
        XCTAssertEqual(result.article.title, "remote")
        XCTAssertNil(result.note)
    }

    func testMissingKeyReadsLocallyAndSaysSo() async throws {
        let result = try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "   ",
            instaparser: { _, _ in XCTFail("called without a key"); return self.article("remote") },
            local: { _ in self.article("local") }
        )
        XCTAssertEqual(result.article.title, "local")
        XCTAssertTrue(result.note?.contains("No Instaparser API key") == true)
    }

    /// A rejected key, a spent quota or an outage must not stop the send —
    /// and the reason must reach the user so the key can be fixed.
    func testInstaparserFailureFallsBackWithTheReason() async throws {
        let rejected = InstaparserError(
            statusCode: 401,
            message: InstaparserClient.describe(status: 401, body: Data())
        )
        let result = try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "bad",
            instaparser: { _, _ in throw rejected },
            local: { _ in self.article("local") }
        )
        XCTAssertEqual(result.article.title, "local")
        XCTAssertTrue(result.note?.contains("API key") == true)
        XCTAssertTrue(result.note?.hasSuffix("Read on this Mac instead.") == true)
    }

    func testBuiltInReaderFailureAfterFallbackIsThrown() async {
        do {
            _ = try await ArticleReading.read(
                url: url, reader: .instaparser, instaparserAPIKey: "key",
                instaparser: { _, _ in throw Failure(errorDescription: "remote down") },
                local: { _ in throw Failure(errorDescription: "page not found") }
            )
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "page not found")
        }
    }
}

final class ArticleReadingAttentionTests: XCTestCase {
    private let url = URL(string: "https://example.com/post")!
    private func article() -> ParsedArticle { ParsedArticle(url: url.absoluteString, title: "T", html: "<p>x</p>") }

    private func fallback(status: Int?) async throws -> ArticleReading.Result {
        try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "key",
            instaparser: { _, _ in
                throw InstaparserError(statusCode: status, message: "Instaparser failed.")
            },
            local: { _ in self.article() }
        )
    }

    /// Things the user can fix get a warning.
    func testFixableFailuresNeedAttention() async throws {
        for status in [401, 403, 409] {
            let result = try await fallback(status: status)
            XCTAssertTrue(result.needsAttention, "HTTP \(status)")
            XCTAssertNotNil(result.note)
        }
        let noKey = try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "",
            instaparser: { _, _ in self.article() }, local: { _ in self.article() }
        )
        XCTAssertTrue(noKey.needsAttention)
    }

    /// A page Instaparser cannot read, a brief rate limit, an outage or a
    /// dropped connection are noted in the history but do not warn.
    func testUnfixableFailuresAreQuiet() async throws {
        for status in [412, 429, 500, 503, nil] as [Int?] {
            let result = try await fallback(status: status)
            XCTAssertFalse(result.needsAttention, "HTTP \(String(describing: status))")
            XCTAssertNotNil(result.note, "still recorded for the history")
        }
    }

    func testSuccessNeedsNoAttention() async throws {
        let result = try await ArticleReading.read(
            url: url, reader: .instaparser, instaparserAPIKey: "key",
            instaparser: { _, _ in self.article() }, local: { _ in self.article() }
        )
        XCTAssertFalse(result.needsAttention)
        XCTAssertNil(result.note)
    }
}
