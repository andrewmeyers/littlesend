import Foundation

/// Builds a minimal, valid EPUB 3 file from a parsed article.
///
/// The article body is normalized to XHTML and then checked for
/// well-formedness. If normalization somehow produces invalid XML, the builder
/// falls back to a plain-text rendering rather than shipping a broken book.
public enum EPUBBuilder {

    public struct Result: Sendable {
        public let data: Data
        public let fileName: String
        /// True when the XHTML failed validation and the text fallback was used.
        public let usedTextFallback: Bool
        public let embeddedImageCount: Int
        public let hasCover: Bool
    }

    public static func build(
        article: ParsedArticle,
        images: [EmbeddedImage] = [],
        cover: CoverGenerator.Cover? = nil,
        identifier: String? = nil,
        modified: Date = Date(),
        convertedHTML: String? = nil
    ) -> Result {
        // `convertedHTML` lets a caller that already ran the converter (to find
        // the images, say) skip running it again; it must be
        // `HTMLToXHTML.convert(article.html)`.
        let converted = convertedHTML ?? HTMLToXHTML.convert(article.html)
        var bodyXHTML = rewriteImageReferences(in: converted, using: images)

        var usedFallback = false
        if !isWellFormed(fragment: bodyXHTML) {
            bodyXHTML = textFallbackBody(fromXHTML: converted)
            usedFallback = true
        }

        let usedImages = usedFallback ? [] : images
        let uuid = identifier ?? "urn:uuid:\(deterministicUUID(from: article.url))"

        var zip = ZipWriter()
        // The mimetype entry must come first and be stored uncompressed.
        zip.addFile(name: "mimetype", string: "application/epub+zip")
        zip.addFile(name: "META-INF/container.xml", string: containerXML)
        zip.addFile(name: "OEBPS/style.css", string: styleSheet)
        zip.addFile(name: "OEBPS/nav.xhtml", string: navigationDocument(article: article))
        if let cover {
            zip.addFile(name: "OEBPS/\(cover.fileName)", contents: cover.data)
            zip.addFile(name: "OEBPS/cover.xhtml", string: coverDocument(article: article, cover: cover))
        }
        zip.addFile(name: "OEBPS/article.xhtml", string: articleDocument(article: article, body: bodyXHTML))
        for image in usedImages {
            zip.addFile(name: "OEBPS/\(image.relativePath)", contents: image.data)
        }
        zip.addFile(
            name: "OEBPS/content.opf",
            string: packageDocument(
                article: article, images: usedImages, cover: cover,
                identifier: uuid, modified: modified
            )
        )

        return Result(
            data: zip.finalized(),
            fileName: fileName(for: article),
            usedTextFallback: usedFallback,
            embeddedImageCount: usedImages.count,
            hasCover: cover != nil
        )
    }

    // MARK: - Images

    /// Absolute URLs of every `<img src>` in the converted XHTML.
    public static func imageURLs(inXHTML xhtml: String, relativeTo base: URL?) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for source in attributeValues(named: "src", in: xhtml) {
            let decoded = decodeXMLEntities(source)
            guard let url = URL(string: decoded, relativeTo: base)?.absoluteURL else { continue }
            guard url.scheme == "http" || url.scheme == "https" else { continue }
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }
        return urls
    }

    /// Points `<img>` elements at the embedded copies, and removes the images
    /// that could not be downloaded so no remote references remain.
    ///
    /// Each image is also wrapped in a link back to the original file, so a
    /// reader can reach the full-resolution version of anything that was
    /// downscaled on the way in. Images already inside a link are left alone,
    /// since nested anchors are invalid.
    static func rewriteImageReferences(in xhtml: String, using images: [EmbeddedImage]) -> String {
        var bySource: [String: EmbeddedImage] = [:]
        for image in images { bySource[image.sourceURL] = image }

        var result = ""
        var remainder = Substring(xhtml)
        var anchorDepth = 0

        while let openRange = remainder.range(of: "<") {
            result += remainder[..<openRange.lowerBound]
            let afterOpen = remainder[openRange.lowerBound...]

            if afterOpen.hasPrefix("<a ") || afterOpen.hasPrefix("<a>") {
                anchorDepth += 1
            } else if afterOpen.hasPrefix("</a>") {
                anchorDepth = max(0, anchorDepth - 1)
            } else if afterOpen.hasPrefix("<img") {
                guard let closeRange = afterOpen.range(of: ">") else {
                    result += afterOpen
                    remainder = Substring("")
                    break
                }
                let tag = String(afterOpen[..<closeRange.upperBound])
                result += rewrite(imageTag: tag, using: bySource, linkToSource: anchorDepth == 0)
                remainder = afterOpen[closeRange.upperBound...]
                continue
            }

            // Emit the "<" and carry on scanning from the next character.
            result += "<"
            remainder = afterOpen.dropFirst()
        }
        result += remainder
        return result
    }

    private static func rewrite(
        imageTag tag: String,
        using bySource: [String: EmbeddedImage],
        linkToSource: Bool
    ) -> String {
        guard let source = attributeValues(named: "src", in: tag).first else { return "" }
        let decoded = decodeXMLEntities(source)

        // The src may be relative in the source HTML but absolute in the map,
        // so match on suffix as well as exact equality.
        let image = bySource[decoded] ?? bySource.first { $0.key.hasSuffix(decoded) }?.value
        guard let image else { return "" }

        let rewritten = tag.replacingOccurrences(
            of: "src=\"\(source)\"", with: "src=\"\(image.relativePath)\""
        )
        guard linkToSource else { return rewritten }
        return "<a href=\"\(HTMLToXHTML.escapeAttribute(image.sourceURL))\">\(rewritten)</a>"
    }

    static func attributeValues(named name: String, in xhtml: String) -> [String] {
        var values: [String] = []
        var remainder = Substring(xhtml)
        let needle = "\(name)=\""
        while let start = remainder.range(of: needle) {
            let afterStart = remainder[start.upperBound...]
            guard let end = afterStart.firstIndex(of: "\"") else { break }
            values.append(String(afterStart[..<end]))
            remainder = afterStart[afterStart.index(after: end)...]
        }
        return values
    }

    static func decodeXMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: - Validation

    static func isWellFormed(fragment: String) -> Bool {
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><root>\(fragment)</root>"
        let parser = XMLParser(data: Data(document.utf8))
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }

    static func textFallbackBody(for article: ParsedArticle) -> String {
        textFallbackBody(fromXHTML: HTMLToXHTML.convert(article.html))
    }

    static func textFallbackBody(fromXHTML xhtml: String) -> String {
        HTMLToXHTML.plainText(fromXHTML: xhtml)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { "<p>\(HTMLToXHTML.escapeText($0))</p>" }
            .joined(separator: "\n")
    }

    // MARK: - Package documents

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// No `font-family` anywhere, deliberately. An article should be set in
    /// whatever face the reader has already chosen for reading — the Kindle's
    /// own font settings, or Apple Books', rather than one imposed here.
    private static let styleSheet = """
    body { margin: 0 1em; line-height: 1.5; }
    h1 { font-size: 1.5em; line-height: 1.25; margin: 0 0 0.2em; }
    h2 { font-size: 1.2em; margin: 1.4em 0 0.4em; }
    h3, h4, h5, h6 { font-size: 1.05em; margin: 1.2em 0 0.4em; }
    p { margin: 0 0 0.9em; text-indent: 0; }
    .kc-byline { font-size: 0.85em; margin: 0 0 0.4em; }
    .kc-source { font-size: 0.8em; margin: 0 0 1.6em; word-wrap: break-word; }
    .kc-source a { text-decoration: none; }
    blockquote { margin: 0 0 0.9em 1.2em; font-style: italic; }
    pre { white-space: pre-wrap; font-size: 0.85em; }
    code { font-size: 0.9em; }
    img { max-width: 100%; height: auto; }
    figure { margin: 1em 0; }
    figcaption { font-size: 0.8em; font-style: italic; }
    hr { border: 0; border-top: 1px solid currentColor; opacity: 0.3; margin: 1.5em 0; }
    table { border-collapse: collapse; font-size: 0.85em; }
    th, td { border: 1px solid currentColor; padding: 0.3em 0.5em; }
    """

    private static func articleDocument(article: ParsedArticle, body: String) -> String {
        let direction = article.isRightToLeft ? "rtl" : "ltr"
        var header = "<h1>\(HTMLToXHTML.escapeText(article.title))</h1>\n"

        var bylineParts: [String] = []
        if let author = article.author { bylineParts.append(HTMLToXHTML.escapeText(author)) }
        if let site = article.siteName { bylineParts.append(HTMLToXHTML.escapeText(site)) }
        if let date = article.publishedDate {
            bylineParts.append(HTMLToXHTML.escapeText(readableDateFormatter.string(from: date)))
        }
        if !bylineParts.isEmpty {
            header += "<p class=\"kc-byline\">\(bylineParts.joined(separator: " &#183; "))</p>\n"
        }

        let escapedURL = HTMLToXHTML.escapeAttribute(article.url)
        header += "<p class=\"kc-source\"><a href=\"\(escapedURL)\">\(HTMLToXHTML.escapeText(article.url))</a></p>\n"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en" dir="\(direction)">
        <head>
          <meta charset="utf-8"/>
          <title>\(HTMLToXHTML.escapeText(article.title))</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        <section epub:type="chapter">
        \(header)\(body)
        </section>
        </body>
        </html>
        """
    }

    private static func navigationDocument(article: ParsedArticle) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head>
          <meta charset="utf-8"/>
          <title>Contents</title>
        </head>
        <body>
        <nav epub:type="toc" id="toc">
          <h1>Contents</h1>
          <ol>
            <li><a href="article.xhtml">\(HTMLToXHTML.escapeText(article.title))</a></li>
          </ol>
        </nav>
        </body>
        </html>
        """
    }

    private static func packageDocument(
        article: ParsedArticle,
        images: [EmbeddedImage],
        cover: CoverGenerator.Cover?,
        identifier: String,
        modified: Date
    ) -> String {
        var metadata = """
          <dc:identifier id="pub-id">\(HTMLToXHTML.escapeText(identifier))</dc:identifier>
            <dc:title>\(HTMLToXHTML.escapeText(article.title))</dc:title>
            <dc:language>en</dc:language>
            <dc:source>\(HTMLToXHTML.escapeText(article.url))</dc:source>
        """
        if let author = article.author {
            metadata += "\n    <dc:creator>\(HTMLToXHTML.escapeText(author))</dc:creator>"
        } else if let site = article.siteName {
            metadata += "\n    <dc:creator>\(HTMLToXHTML.escapeText(site))</dc:creator>"
        }
        if let site = article.siteName {
            metadata += "\n    <dc:publisher>\(HTMLToXHTML.escapeText(site))</dc:publisher>"
        }
        if let description = article.description {
            metadata += "\n    <dc:description>\(HTMLToXHTML.escapeText(description))</dc:description>"
        }
        if let published = article.publishedDate {
            metadata += "\n    <dc:date>\(iso8601Formatter.string(from: published))</dc:date>"
        }
        metadata += "\n    <meta property=\"dcterms:modified\">\(iso8601Formatter.string(from: modified))</meta>"
        if cover != nil {
            // EPUB 2 style pointer; Kindle's converter still keys off this one.
            metadata += "\n    <meta name=\"cover\" content=\"cover-image\"/>"
        }

        var manifest = """
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="style" href="style.css" media-type="text/css"/>
            <item id="article" href="article.xhtml" media-type="application/xhtml+xml"/>
        """
        for (index, image) in images.enumerated() {
            manifest += "\n    <item id=\"img\(index)\" href=\"\(image.relativePath)\" media-type=\"\(image.mediaType)\"/>"
        }
        var spine = ""
        if let cover {
            manifest += "\n    <item id=\"cover-image\" href=\"\(cover.fileName)\" media-type=\"\(cover.mediaType)\" properties=\"cover-image\"/>"
            manifest += "\n    <item id=\"cover\" href=\"cover.xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "\n    <itemref idref=\"cover\" linear=\"no\"/>"
        }
        spine += "\n    <itemref idref=\"article\"/>"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="en">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            \(metadata)
          </metadata>
          <manifest>
            \(manifest)
          </manifest>
          <spine>\(spine)
          </spine>
        </package>
        """
    }

    private static func coverDocument(article: ParsedArticle, cover: CoverGenerator.Cover) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
        <head>
          <meta charset="utf-8"/>
          <title>Cover</title>
          <style type="text/css">
            body { margin: 0; padding: 0; text-align: center; }
            img { max-width: 100%; max-height: 100%; }
          </style>
        </head>
        <body epub:type="cover">
        <div><img src="\(cover.fileName)" alt="\(HTMLToXHTML.escapeAttribute(article.title))"/></div>
        </body>
        </html>
        """
    }

    // MARK: - Naming

    public static func fileName(for article: ParsedArticle) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = article.title.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let trimmed = String(cleaned.prefix(80))
        // Kindle shows the filename when metadata is missing, so never send "".
        let base = trimmed.isEmpty ? "article" : trimmed
        return "\(base).epub"
    }

    /// A stable UUID so re-sending the same article keeps the same book identity.
    static func deterministicUUID(from string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var second: UInt64 = 0x9e37_79b9_7f4a_7c15 ^ hash
        second = second &* 0xff51_afd7_ed55_8ccd
        second ^= second >> 33

        let high = String(format: "%016lx", hash)
        let low = String(format: "%016lx", second)
        let joined = high + low
        let hex = Array(joined)
        func slice(_ range: Range<Int>) -> String { String(hex[range]) }
        return "\(slice(0..<8))-\(slice(8..<12))-\(slice(12..<16))-\(slice(16..<20))-\(slice(20..<32))"
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let readableDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
