import XCTest
@testable import LittleSendCore

final class EPUBBuilderTests: XCTestCase {

    private func article(
        title: String = "A Test Article",
        html: String = "<p>Body text.</p>",
        author: String? = "Jane Doe",
        url: String = "https://example.com/post"
    ) -> ParsedArticle {
        ParsedArticle(
            url: url,
            title: title,
            siteName: "Example",
            author: author,
            description: "A description",
            html: html,
            publishedDate: Date(timeIntervalSince1970: 1_700_000_000),
            wordCount: 2
        )
    }

    // MARK: - ZIP container

    func testProducesReadableZipWithMimetypeFirst() throws {
        let result = EPUBBuilder.build(article: article())
        let entries = try ZipInspector.entries(in: result.data)

        XCTAssertEqual(entries.first?.name, "mimetype")
        XCTAssertEqual(entries.first.map { String(decoding: $0.contents, as: UTF8.self) }, "application/epub+zip")

        let names = Set(entries.map(\.name))
        XCTAssertTrue(names.contains("META-INF/container.xml"))
        XCTAssertTrue(names.contains("OEBPS/content.opf"))
        XCTAssertTrue(names.contains("OEBPS/article.xhtml"))
        XCTAssertTrue(names.contains("OEBPS/nav.xhtml"))
    }

    func testUnzipAcceptsTheArchive() throws {
        let result = EPUBBuilder.build(article: article())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlesend-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("book.epub")
        try result.data.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", file.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "unzip rejected the EPUB")
    }

    // MARK: - Document validity

    func testEveryXMLDocumentIsWellFormed() throws {
        let messy = """
        <div><p>Unclosed<p>Another & one<br><img src="https://example.com/a.png">
        <script>bad & wrong</script><ul><li>x</ul></div>
        """
        let result = EPUBBuilder.build(article: article(html: messy))
        let entries = try ZipInspector.entries(in: result.data)

        for entry in entries where entry.name.hasSuffix(".xhtml") || entry.name.hasSuffix(".opf") || entry.name.hasSuffix(".xml") {
            let parser = XMLParser(data: entry.contents)
            XCTAssertTrue(parser.parse(), "\(entry.name) is not well-formed XML")
        }
        XCTAssertFalse(result.usedTextFallback)
    }

    func testTitleWithMarkupCharactersIsEscapedInMetadata() throws {
        let result = EPUBBuilder.build(article: article(title: "Ampersands & <angle> \"quotes\""))
        let entries = try ZipInspector.entries(in: result.data)
        let opf = try XCTUnwrap(entries.first { $0.name == "OEBPS/content.opf" })

        let parser = XMLParser(data: opf.contents)
        XCTAssertTrue(parser.parse(), "OPF broke on a title containing markup characters")
    }

    func testFallsBackToTextWhenBodyCannotBeMadeValid() {
        // A lone valid body still parses; assert the fallback path renders text.
        let fallback = EPUBBuilder.textFallbackBody(for: article(html: "<p>Hello & goodbye</p>"))
        XCTAssertTrue(EPUBBuilder.isWellFormed(fragment: fallback))
        XCTAssertTrue(fallback.contains("&amp;"))
    }

    // MARK: - Images

    func testImageURLsAreResolvedAgainstTheArticle() {
        let xhtml = HTMLToXHTML.convert("""
        <p><img src="/a.png"/><img src="https://cdn.example.com/b.jpg"/><img src="data:image/png;base64,xx"/></p>
        """)
        let urls = EPUBBuilder.imageURLs(inXHTML: xhtml, relativeTo: URL(string: "https://example.com/post"))
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/a.png",
            "https://cdn.example.com/b.jpg",
        ])
    }

    func testUndownloadableImagesAreRemovedNotLeftRemote() throws {
        let html = "<p>text</p><img src=\"https://example.com/missing.png\">"
        let result = EPUBBuilder.build(article: article(html: html), images: [])
        let entries = try ZipInspector.entries(in: result.data)
        let document = try XCTUnwrap(entries.first { $0.name == "OEBPS/article.xhtml" })
        let text = String(decoding: document.contents, as: UTF8.self)

        XCTAssertFalse(text.contains("missing.png"), "a remote image reference survived")
        XCTAssertTrue(text.contains("text"))
    }

    func testEmbeddedImagesAreRewrittenAndPackaged() throws {
        let image = EmbeddedImage(
            sourceURL: "https://example.com/a.png",
            fileName: "img0.png",
            mediaType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let html = "<p><img src=\"https://example.com/a.png\"></p>"
        let result = EPUBBuilder.build(article: article(html: html), images: [image])
        let entries = try ZipInspector.entries(in: result.data)

        XCTAssertTrue(entries.contains { $0.name == "OEBPS/images/img0.png" })
        let document = try XCTUnwrap(entries.first { $0.name == "OEBPS/article.xhtml" })
        XCTAssertTrue(String(decoding: document.contents, as: UTF8.self).contains("src=\"images/img0.png\""))

        let opf = try XCTUnwrap(entries.first { $0.name == "OEBPS/content.opf" })
        XCTAssertTrue(String(decoding: opf.contents, as: UTF8.self).contains("images/img0.png"))
        XCTAssertEqual(result.embeddedImageCount, 1)
    }

    func testRelativeImageSourceIsMatchedToItsAbsoluteDownload() throws {
        let image = EmbeddedImage(
            sourceURL: "https://example.com/photos/a.png",
            fileName: "img0.png",
            mediaType: "image/png",
            data: Data([0x89])
        )
        let rewritten = EPUBBuilder.rewriteImageReferences(
            in: "<img src=\"/photos/a.png\"/>", using: [image]
        )
        // Also wrapped in a link back to the full-resolution original.
        XCTAssertEqual(
            rewritten,
            "<a href=\"https://example.com/photos/a.png\"><img src=\"images/img0.png\"/></a>"
        )
    }

    // MARK: - Cover

    func testCoverIsPackagedAndDeclared() throws {
        // Both formats, because the cover's file name and media type change
        // with the palette and the manifest has to follow them rather than
        // assuming ".jpg".
        for eInk in [true, false] {
            let cover = try XCTUnwrap(
                CoverGenerator.makeCover(article: article(), optimizeForEInk: eInk)
            )
            let result = EPUBBuilder.build(article: article(), cover: cover)
            let entries = try ZipInspector.entries(in: result.data)

            XCTAssertTrue(entries.contains { $0.name == "OEBPS/\(cover.fileName)" }, cover.fileName)
            XCTAssertTrue(entries.contains { $0.name == "OEBPS/cover.xhtml" })

            let opf = String(
                decoding: try XCTUnwrap(entries.first { $0.name == "OEBPS/content.opf" }).contents,
                as: UTF8.self
            )
            XCTAssertTrue(opf.contains("href=\"\(cover.fileName)\""), cover.fileName)
            XCTAssertTrue(opf.contains("media-type=\"\(cover.mediaType)\""), cover.mediaType)
            XCTAssertTrue(opf.contains("properties=\"cover-image\""))
            XCTAssertTrue(opf.contains("<meta name=\"cover\" content=\"cover-image\"/>"))
            XCTAssertTrue(result.hasCover)
        }
    }

    // MARK: - Naming and identity

    func testFileNameIsSafeAndNonEmpty() {
        XCTAssertEqual(EPUBBuilder.fileName(for: article(title: "Hello, World! / Part 2")), "Hello-World-Part-2.epub")
        XCTAssertEqual(EPUBBuilder.fileName(for: article(title: "***")), "article.epub")
        XCTAssertTrue(EPUBBuilder.fileName(for: article(title: String(repeating: "x", count: 300))).count <= 85)
    }

    func testIdentifierIsStableForTheSameURL() {
        let first = EPUBBuilder.deterministicUUID(from: "https://example.com/post")
        let second = EPUBBuilder.deterministicUUID(from: "https://example.com/post")
        let other = EPUBBuilder.deterministicUUID(from: "https://example.com/other")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 36)
    }

    func testMissingAuthorFallsBackToSiteNameAsCreator() throws {
        let result = EPUBBuilder.build(article: article(author: nil))
        let entries = try ZipInspector.entries(in: result.data)
        let opf = String(decoding: try XCTUnwrap(entries.first { $0.name == "OEBPS/content.opf" }).contents, as: UTF8.self)
        XCTAssertTrue(opf.contains("<dc:creator>Example</dc:creator>"))
    }
}
