import XCTest
@testable import LittleSendCore

/// End-to-end check against a real web page: read it locally, normalize it,
/// fetch its images, build the EPUB. Skipped unless LITTLESEND_LIVE_URL is set,
/// so the normal suite stays offline and fast:
///
///   LITTLESEND_LIVE_URL=https://… swift test --filter LiveSmokeTests
///
/// Set LITTLESEND_LIVE_OUTPUT to a directory to keep the generated .epub and
/// cover .jpg for inspection.
final class LiveSmokeTests: XCTestCase {

    @MainActor
    func testReadsAndBuildsARealArticle() async throws {
        guard let target = ProcessInfo.processInfo.environment["LITTLESEND_LIVE_URL"], !target.isEmpty else {
            throw XCTSkip("LITTLESEND_LIVE_URL not set")
        }
        let url = try XCTUnwrap(URL(string: target))

        let article = try await LocalArticleParser().parse(url: url)
        XCTAssertFalse(article.title.isEmpty)
        XCTAssertFalse(article.html.isEmpty)

        let xhtml = HTMLToXHTML.convert(article.html)
        XCTAssertTrue(
            EPUBBuilder.isWellFormed(fragment: xhtml),
            "real-world HTML did not normalize to well-formed XHTML"
        )

        let imageURLs = EPUBBuilder.imageURLs(inXHTML: xhtml, relativeTo: URL(string: article.url))
        let images = await ImageFetcher().fetch(urls: imageURLs)
        let cover = CoverGenerator.makeCover(article: article)
        let book = EPUBBuilder.build(article: article, images: images, cover: cover)

        XCTAssertFalse(book.usedTextFallback, "fell back to plain text on a real article")
        XCTAssertTrue(book.hasCover)

        if let directory = ProcessInfo.processInfo.environment["LITTLESEND_LIVE_OUTPUT"] {
            let base = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try book.data.write(to: base.appendingPathComponent(book.fileName))
            let email = ArticleEmailRenderer.render(article: article)
            try Data(email.html.utf8).write(to: base.appendingPathComponent("email.html"))
            try Data(email.plainText.utf8).write(to: base.appendingPathComponent("email.txt"))
            if let cover {
                try cover.data.write(to: base.appendingPathComponent(cover.fileName))
            }
            print("""
            LIVE: title=\(article.title)
            LIVE: author=\(article.author ?? "—") site=\(article.siteName ?? "—")
            LIVE: words=\(ReadingTime.wordCount(ofHTML: article.html)) images=\(imageURLs.count) embedded=\(book.embeddedImageCount)
            LIVE: file=\(book.fileName) bytes=\(book.data.count)
            """)
        }
    }
}
