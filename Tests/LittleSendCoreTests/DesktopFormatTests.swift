import XCTest
import CoreGraphics
@testable import LittleSendCore

final class DesktopFormatTests: XCTestCase {

    private func article(html: String = "<p>Body.</p>") -> ParsedArticle {
        ParsedArticle(
            url: "https://example.com/articles/one",
            title: "A Title",
            siteName: "Example",
            author: "Some Author",
            description: nil,
            html: html,
            publishedDate: nil
        )
    }

    // MARK: - The format itself

    func testRawValuesAreStableForPersistence() {
        XCTAssertEqual(DesktopFormat.epub.rawValue, "epub")
        XCTAssertEqual(DesktopFormat.pdf.rawValue, "pdf")
        XCTAssertEqual(DesktopFormat.markdown.rawValue, "markdown")
        XCTAssertEqual(DesktopFormat.text.rawValue, "text")
        XCTAssertNil(DesktopFormat(rawValue: "docx"))
    }

    func testEveryFormatIsFullyNamed() {
        for format in DesktopFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty, format.rawValue)
            XCTAssertFalse(format.shortName.isEmpty, format.rawValue)
            XCTAssertFalse(format.fileExtension.isEmpty, format.rawValue)
        }
    }

    func testFileNamesShareTheEPUBStem() {
        // Every format of one article should sort together on the Desktop.
        let stem = (EPUBBuilder.fileName(for: article()) as NSString).deletingPathExtension
        XCTAssertEqual(DocumentRenderer.fileName(for: article(), format: .pdf), "\(stem).pdf")
        XCTAssertEqual(DocumentRenderer.fileName(for: article(), format: .markdown), "\(stem).md")
        XCTAssertEqual(DocumentRenderer.fileName(for: article(), format: .text), "\(stem).txt")
        XCTAssertEqual(DocumentRenderer.fileName(for: article(), format: .epub), EPUBBuilder.fileName(for: article()))
    }

    func testOnlyAnEPUBDesktopCopyNeedsABookBuilt() {
        var draft = SettingsDraft()
        draft.sendToKindle = false
        draft.saveToDesktop = true

        for format in DesktopFormat.allCases {
            draft.desktopFormat = format
            XCTAssertEqual(draft.configuration.needsBook, format == .epub, format.rawValue)
        }
    }

    // MARK: - Markdown

    private let richHTML = """
    <h2>Section</h2>
    <p>Plain <strong>bold</strong> and <em>italic</em> with a <a href="/next">link</a>.</p>
    <ul><li>One</li><li>Two<ul><li>Nested</li></ul></li></ul>
    <blockquote><p>Quoted words.</p></blockquote>
    <pre>let x = 1</pre>
    <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
    <p>Price is 5 * 3 _ok_</p>
    """

    func testMarkdownHeaderCarriesTitleMetaAndSource() {
        let markdown = DocumentRenderer.markdown(for: article())
        XCTAssertTrue(markdown.hasPrefix("# A Title\n"), markdown)
        XCTAssertTrue(markdown.contains("*Some Author · Example*"), markdown)
        XCTAssertTrue(markdown.contains("[Original article](https://example.com/articles/one)"), markdown)
    }

    func testMarkdownRendersStructure() {
        let markdown = DocumentRenderer.markdown(for: article(html: richHTML))

        // Body headings start a level below the document title.
        XCTAssertTrue(markdown.contains("### Section"), markdown)
        XCTAssertTrue(markdown.contains("Plain **bold** and *italic* with a [link](https://example.com/next)."), markdown)
        XCTAssertTrue(markdown.contains("- One"), markdown)
        XCTAssertTrue(markdown.contains("- Two"), markdown)
        XCTAssertTrue(markdown.contains("    - Nested"), markdown)
        XCTAssertTrue(markdown.contains("> Quoted words."), markdown)
        XCTAssertTrue(markdown.contains("```\nlet x = 1\n```"), markdown)
        XCTAssertTrue(markdown.contains("| A | B |"), markdown)
        XCTAssertTrue(markdown.contains("| --- | --- |"), markdown)
        XCTAssertTrue(markdown.contains("| 1 | 2 |"), markdown)
    }

    func testMarkdownEscapesProseThatWouldBecomeSyntax() {
        let markdown = DocumentRenderer.markdown(for: article(html: richHTML))
        XCTAssertTrue(markdown.contains("Price is 5 \\* 3 \\_ok\\_"), markdown)
    }

    func testRelativeLinksAreMadeAbsolute() {
        // A relative link in a file saved to the Desktop points nowhere.
        let markdown = DocumentRenderer.markdown(for: article(html: #"<p><a href="../two">Next</a></p>"#))
        XCTAssertTrue(markdown.contains("[Next](https://example.com/two)"), markdown)
    }

    // MARK: - Plain text

    func testPlainTextHasNoMarkdownSyntax() {
        let text = DocumentRenderer.plainText(for: article(html: richHTML))
        XCTAssertTrue(text.hasPrefix("A Title\n"), text)
        XCTAssertFalse(text.contains("**"), text)
        XCTAssertFalse(text.contains("]("), text)
        XCTAssertFalse(text.contains("### "), text)
        XCTAssertFalse(text.contains("```"), text)
    }

    func testPlainTextKeepsReadableStructure() {
        let text = DocumentRenderer.plainText(for: article(html: richHTML))
        XCTAssertTrue(text.contains("• One"), text)
        XCTAssertTrue(text.contains("    • Nested"), text)
        XCTAssertTrue(text.contains("with a link."), text)
        // Paragraphs are separated, not run together.
        XCTAssertTrue(text.contains("Section\n\nPlain bold"), text)
    }

    // MARK: - PDF

    @MainActor
    func testPDFIsARealPaginatedDocument() async throws {
        let paragraphs = (1...60).map {
            "<p>Paragraph \($0). A reasonably long sentence of article prose, repeated so the text runs well past a single page and forces pagination.</p>"
        }.joined()
        let data = try await PDFRenderer.render(article: article(html: paragraphs), timeout: 20)

        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")

        let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        XCTAssertGreaterThan(document.numberOfPages, 1, "a long article should span pages")
    }
}
