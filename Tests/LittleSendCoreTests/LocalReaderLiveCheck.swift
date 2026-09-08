import XCTest
@testable import LittleSendCore

/// Drives the real local reader against a live URL. Skipped unless
/// LITTLESEND_LOCAL_URL is set, so the normal suite stays offline.
final class LocalReaderLiveCheck: XCTestCase {
    @MainActor
    func testReadsARealPage() async throws {
        guard let target = ProcessInfo.processInfo.environment["LITTLESEND_LOCAL_URL"] else {
            throw XCTSkip("LITTLESEND_LOCAL_URL not set")
        }
        let url = try XCTUnwrap(URL(string: target))
        let article = try await LocalArticleParser().parse(url: url)

        print("LOCAL title=\(article.title)")
        print("LOCAL author=\(article.author ?? "—") site=\(article.siteName ?? "—")")
        print("LOCAL date=\(article.publishedDate.map(String.init(describing:)) ?? "—")")
        print("LOCAL htmlChars=\(article.html.count)")

        XCTAssertFalse(article.title.isEmpty)
        XCTAssertGreaterThan(article.html.count, 1000)

        // The same downstream path a real send would take.
        let xhtml = HTMLToXHTML.convert(article.html)
        XCTAssertTrue(EPUBBuilder.isWellFormed(fragment: xhtml), "did not normalize to valid XHTML")

        let book = EPUBBuilder.build(article: article, cover: CoverGenerator.makeCover(article: article))
        print("LOCAL epub=\(book.fileName) bytes=\(book.data.count) textFallback=\(book.usedTextFallback)")
        XCTAssertFalse(book.usedTextFallback)
    }
}
