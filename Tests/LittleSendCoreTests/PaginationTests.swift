import XCTest
@testable import LittleSendCore

final class PaginationTests: XCTestCase {

    private func base(_ address: String) throws -> Pagination.Base {
        try XCTUnwrap(Pagination.Base(url: XCTUnwrap(URL(string: address))), address)
    }

    private func next(
        from address: String,
        expecting page: Int = 2,
        _ candidates: [String],
        visited: Set<String> = []
    ) throws -> String? {
        Pagination.nextPage(
            after: try base(address),
            expecting: page,
            candidates: candidates.compactMap(URL.init(string:)),
            visited: visited
        )?.absoluteString
    }

    // MARK: - Following the article's own pages

    func testTrailingPageNumber() throws {
        XCTAssertEqual(try next(from: "https://example.com/story", ["https://example.com/story/2"]),
                       "https://example.com/story/2")
    }

    func testPageSegment() throws {
        XCTAssertEqual(try next(from: "https://example.com/story/", ["https://example.com/story/page/2/"]),
                       "https://example.com/story/page/2/")
    }

    func testQueryPageKeepingTheOtherParameters() throws {
        XCTAssertEqual(
            try next(from: "https://example.com/read?id=7", ["https://example.com/read?id=7&page=2"]),
            "https://example.com/read?id=7&page=2"
        )
    }

    func testQueryOrderDoesNotMatter() throws {
        XCTAssertNotNil(try next(from: "https://example.com/read?a=1&b=2", ["https://example.com/read?b=2&page=2&a=1"]))
    }

    func testWWWAndSchemeDifferencesAreTheSameSite() throws {
        XCTAssertNotNil(try next(from: "https://www.example.com/story", ["http://example.com/story/2"]))
    }

    func testLaterPagesAreMatchedAgainstTheFirst() throws {
        XCTAssertNotNil(try next(from: "https://example.com/story", expecting: 3, ["https://example.com/story/3"]))
    }

    func testStartingOnAnExplicitLaterPage() throws {
        XCTAssertEqual(try base("https://example.com/story?page=3").startPage, 3)
        XCTAssertEqual(try base("https://example.com/story/page/4").startPage, 4)
        XCTAssertNotNil(try next(from: "https://example.com/story/page/4", expecting: 5, ["https://example.com/story/page/5"]))
    }

    // MARK: - Never the wrong page

    func testNextArticleIsRejectedEvenWhenMarkedRelNext() throws {
        // Older WordPress themes put rel="next" on every post, pointing at the
        // following post. That is a different article and must not be stitched on.
        XCTAssertNil(try next(from: "https://example.com/2024/09/my-story", ["https://example.com/2024/09/another-story"]))
    }

    func testDateInThePathIsNotAPageNumber() throws {
        XCTAssertEqual(try base("https://example.com/2024/09/14").startPage, 1)
        XCTAssertNil(try next(from: "https://example.com/2024/09/14", expecting: 15, ["https://example.com/2024/09/15"]))
        XCTAssertNil(try next(from: "https://example.com/2024/09/14", ["https://example.com/2024/09/15"]))
    }

    func testWordPressPostIDIsNotAPage() throws {
        XCTAssertNil(try next(from: "https://example.com/?p=123", ["https://example.com/?p=124"]))
        XCTAssertNil(try next(from: "https://example.com/?p=123", ["https://example.com/?p=123&p=2"]))
    }

    func testOutOfSequencePageIsRejected() throws {
        XCTAssertNil(try next(from: "https://example.com/story", expecting: 2, ["https://example.com/story/3"]))
    }

    func testOtherSitesAreRejected() throws {
        XCTAssertNil(try next(from: "https://example.com/story", ["https://example.net/story/2"]))
        XCTAssertNil(try next(from: "https://example.com/story", ["https://evil.example.com/story/2"]))
    }

    func testDeeperPathsAreNotPages() throws {
        XCTAssertNil(try next(from: "https://example.com/story", ["https://example.com/story/2/comments"]))
        XCTAssertNil(try next(from: "https://example.com/story", ["https://example.com/story-2"]))
        XCTAssertNil(try next(from: "https://example.com/story", ["https://example.com/story/page/two"]))
    }

    func testChangedQueryIsADifferentArticle() throws {
        XCTAssertNil(try next(from: "https://example.com/read?id=7", ["https://example.com/read?id=8&page=2"]))
    }

    func testNonWebAddressesAreRejected() throws {
        XCTAssertNil(Pagination.Base(url: URL(string: "file:///tmp/story")!))
        XCTAssertNil(try next(from: "https://example.com/story", ["javascript:next()", "mailto:a@b.com"]))
    }

    // MARK: - Choosing among candidates

    func testFirstMatchingCandidateWins() throws {
        XCTAssertEqual(
            try next(from: "https://example.com/story", [
                "https://example.com/another-story",
                "https://example.com/story/2#top",
                "https://example.com/story?page=2",
            ]),
            "https://example.com/story/2#top"
        )
    }

    func testAlreadyReadPagesAreSkipped() throws {
        let read = Pagination.visitKey(URL(string: "https://example.com/story/2#top")!)
        XCTAssertEqual(
            try next(from: "https://example.com/story", ["https://example.com/story/2", "https://example.com/story?page=2"],
                     visited: [read]),
            "https://example.com/story?page=2"
        )
    }

    // MARK: - Recognising a repeated page

    func testFingerprintIgnoresMarkupAndWhitespace() {
        XCTAssertEqual(
            Pagination.fingerprint(ofHTML: "<p>The  quick\n<b>brown</b> fox.</p>"),
            Pagination.fingerprint(ofHTML: "<div><p>The quick brown fox.</p></div>")
        )
    }

    func testFingerprintOfEmptyContentIsEmpty() {
        XCTAssertEqual(Pagination.fingerprint(ofHTML: "<p>  </p>"), "")
    }

    func testDifferentPagesHaveDifferentFingerprints() {
        XCTAssertNotEqual(
            Pagination.fingerprint(ofHTML: "<p>Page one begins here.</p>"),
            Pagination.fingerprint(ofHTML: "<p>Page two carries on.</p>")
        )
    }

    // MARK: - Reading candidates out of the page

    func testRelNextLinksComeBeforeOrdinaryLinks() throws {
        let json = """
        {"ok":true,"relNext":["https://example.com/story/2"],
         "anchors":["https://example.com/story?page=2","https://example.com/story/2","not a url"]}
        """
        let candidates = LocalArticleParser.nextPageCandidates(fromReadabilityJSON: Data(json.utf8))
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://example.com/story/2",
            "https://example.com/story?page=2",
        ])
    }

    func testMissingCandidateFieldsMeanNoCandidates() {
        XCTAssertEqual(LocalArticleParser.nextPageCandidates(fromReadabilityJSON: Data(#"{"ok":true}"#.utf8)), [])
    }
}
