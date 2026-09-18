import Foundation
import AppKit
import WebKit
import ImageIO
import UniformTypeIdentifiers

/// A paginated PDF of an article, for the Desktop destination.
///
/// Rendered through WebKit's own print path rather than by snapshotting the
/// page. `WKWebView.createPDF` produces a single page as tall as the article,
/// and cutting that into sheets slices lines of text and pictures in half;
/// printing lets WebKit break pages between lines and keep images whole.
///
/// Images are embedded in the document itself as data URIs, at no more than
/// 300 dpi across the text column, so the PDF carries its own pictures and
/// nothing is fetched while it is laid out.
///
/// Printing a web view needs a window for it to lay out in — a `WKWebView`
/// printed without one gives blank pages — so the view is hosted in a
/// borderless window parked far off every screen. It is never visible, and it
/// is closed as soon as the file is written.
@MainActor
public final class PDFRenderer: NSObject {

    public enum Failure: LocalizedError {
        case loadFailed(String)
        case timedOut
        case printFailed

        public var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): return "Could not lay out the PDF: \(reason)"
            case .timedOut: return "Timed out laying out the PDF."
            case .printFailed: return "Could not write the PDF."
            }
        }
    }

    /// Print resolution for embedded images.
    nonisolated public static let imageDPI: CGFloat = 300

    /// - Parameter images: full-resolution originals. Each is brought down to
    ///   300 dpi at the column width; none is enlarged.
    public static func render(
        article: ParsedArticle,
        images: [EmbeddedImage] = [],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        try await PDFRenderer().render(article: article, images: images, timeout: timeout)
    }

    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    private func render(article: ParsedArticle, images: [EmbeddedImage], timeout: TimeInterval) async throws -> Data {
        // Windows need an application object; the app has one, a test run may not.
        _ = NSApplication.shared

        let printInfo = Self.printInfo()
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let maxPixels = Self.maxPixelWidth(forColumnWidth: width)
        let html = Self.document(for: article, images: images, maxPixelWidth: maxPixels)

        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: width, height: 800),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        // WebKit decodes each image at the size it is drawn in device pixels,
        // and prints that decoded copy — measured at 1008 pixels for a
        // 2100-pixel image in a 504-point column: two pixels per point, 144 dpi
        // rather than 300. So the page is laid out zoomed until an image
        // spanning the column decodes at 300 dpi, and the print is scaled back
        // down to the paper. It is page zoom, so the text reflows at the same
        // column width and line and page breaks come out exactly as unzoomed;
        // only the image decoding changes.
        let zoom = max(1, CGFloat(maxPixels) / (width * window.backingScaleFactor))
        window.setContentSize(NSSize(width: width * zoom, height: 800))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width * zoom, height: 800))
        webView.pageZoom = zoom
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderFrontRegardless()
        defer {
            webView.navigationDelegate = nil
            window.orderOut(nil)
            window.close()
        }

        try await load(html, base: URL(string: article.url), in: webView, timeout: timeout)
        // Large embedded images still need a moment to decode and lay out.
        try? await Task.sleep(nanoseconds: 700_000_000)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("littlesend-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Without an explicit frame the print view can be zero-sized.
        operation.view?.frame = webView.bounds

        let watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishPrint(false)
        }
        defer { watchdog.cancel() }

        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            printContinuation = continuation
            operation.runModal(
                for: window,
                delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                contextInfo: nil
            )
        }

        guard succeeded, let data = try? Data(contentsOf: output), !data.isEmpty else {
            throw Failure.printFailed
        }
        return data
    }

    // MARK: - Loading

    private func load(_ html: String, base: URL?, in webView: WKWebView, timeout: TimeInterval) async throws {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finishLoad(throwing: Failure.timedOut)
        }
        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: base)
        }
    }

    private func finishLoad(throwing error: Error? = nil) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: - Printing

    @objc private func printOperationDidRun(
        _ operation: NSPrintOperation,
        success: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        finishPrint(success)
    }

    private func finishPrint(_ success: Bool) {
        guard let continuation = printContinuation else { return }
        printContinuation = nil
        continuation.resume(returning: success)
    }

    /// The Mac's own default paper size — Letter or A4 — with ¾-inch margins.
    static func printInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    // MARK: - Images

    /// The widest an image needs to be: the text column at 300 dpi. Wider is
    /// pixels the page cannot show. Nothing narrower is enlarged, since
    /// upscaling adds bytes without adding detail.
    nonisolated static func maxPixelWidth(forColumnWidth points: CGFloat) -> Int {
        Int((points / 72 * imageDPI).rounded(.up))
    }

    /// Replaces each image's web address with the image itself, as a data URI.
    nonisolated static func embed(_ images: [EmbeddedImage], in xhtml: String, base: URL?, maxPixelWidth: Int) -> String {
        guard !images.isEmpty else { return xhtml }

        var dataURIs: [String: String] = [:]
        for image in images where dataURIs[image.sourceURL] == nil {
            let ready = printReady(image, maxPixelWidth: maxPixelWidth)
            dataURIs[image.sourceURL] = "data:\(ready.mediaType);base64,\(ready.data.base64EncodedString())"
        }

        guard let tagPattern = try? NSRegularExpression(pattern: "<img\\b[^>]*>", options: .caseInsensitive),
              let srcPattern = try? NSRegularExpression(pattern: "\\bsrc=\"([^\"]*)\"", options: .caseInsensitive),
              let srcsetPattern = try? NSRegularExpression(pattern: "\\s+srcset=\"[^\"]*\"", options: .caseInsensitive)
        else { return xhtml }

        let source = xhtml as NSString
        var output = ""
        var cursor = 0
        for match in tagPattern.matches(in: xhtml, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            var tag = source.substring(with: match.range)

            let tagString = tag as NSString
            if let src = srcPattern.firstMatch(in: tag, range: NSRange(location: 0, length: tagString.length)) {
                let raw = tagString.substring(with: src.range(at: 1))
                if let absolute = URL(string: decodeEntities(raw), relativeTo: base)?.absoluteURL.absoluteString,
                   let uri = dataURIs[absolute] {
                    tag = tagString.replacingCharacters(in: src.range(at: 1), with: uri)
                    // A srcset would let WebKit reach back to the network for
                    // a different rendition and undo the embedding.
                    tag = srcsetPattern.stringByReplacingMatches(
                        in: tag, range: NSRange(location: 0, length: (tag as NSString).length), withTemplate: ""
                    )
                }
            }

            output += tag
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }

    /// An image at no more than 300 dpi across the text column.
    ///
    /// Width is measured the way the image will appear, so a portrait photo
    /// stored sideways with an EXIF rotation is judged by its displayed width,
    /// not its stored one.
    nonisolated static func printReady(_ image: EmbeddedImage, maxPixelWidth: Int) -> (data: Data, mediaType: String) {
        let original = (data: image.data, mediaType: image.mediaType)
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let storedWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let storedHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { return original }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let sideways = (5...8).contains(orientation)
        let width = sideways ? storedHeight : storedWidth
        let height = sideways ? storedWidth : storedHeight
        guard width > maxPixelWidth else { return original }

        // The decoder's ceiling applies to the longer side, so that side is
        // scaled by the same ratio the width needs.
        let scale = CGFloat(maxPixelWidth) / CGFloat(width)
        let longest = Int((CGFloat(max(width, height)) * scale).rounded(.down))
        guard let resized = ImageResizer.makeImage(from: source, maxPixelSize: longest) else { return original }

        switch resized.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            if let jpeg = ImageResizer.encodeJPEG(resized, quality: 0.92) { return (jpeg, "image/jpeg") }
        default:
            if let png = encodePNG(resized) { return (png, "image/png") }
        }
        return original
    }

    nonisolated private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Document

    /// Built per call rather than shared: a `DateFormatter` is not Sendable,
    /// and these helpers are nonisolated so tests can call them directly.
    nonisolated private static func longDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    nonisolated static func document(
        for article: ParsedArticle,
        images: [EmbeddedImage] = [],
        maxPixelWidth: Int = 2100
    ) -> String {
        var meta: [String] = []
        if let author = article.author { meta.append(author) }
        if let site = article.siteName { meta.append(site) }
        if let date = article.publishedDate { meta.append(longDate(date)) }

        let metaLine = meta.isEmpty
            ? ""
            : "<p class=\"meta\">\(HTMLToXHTML.escapeText(meta.joined(separator: " · ")))</p>"
        let direction = article.isRightToLeft ? "rtl" : "ltr"
        let body = embed(
            images,
            in: HTMLToXHTML.convert(article.html),
            base: URL(string: article.url),
            maxPixelWidth: maxPixelWidth
        )

        return """
        <!DOCTYPE html>
        <html dir="\(direction)">
        <head><meta charset="utf-8"><style>\(css)</style></head>
        <body>
        <h1 class="title">\(HTMLToXHTML.escapeText(article.title))</h1>
        \(metaLine)
        <p class="source">\(HTMLToXHTML.escapeText(article.url))</p>
        \(body)
        </body>
        </html>
        """
    }

    /// Print-oriented: serif body, and the CSS page-break hints WebKit honours
    /// when it paginates — keep images and figures whole, never strand a
    /// heading at the foot of a page.
    nonisolated static let css = """
    body { font: 11.5pt/1.55 ui-serif, Georgia, serif; color: #111; margin: 0; }
    h1.title { font: 700 21pt/1.2 system-ui, -apple-system, sans-serif; margin: 0 0 6pt; }
    p.meta { font: 9.5pt system-ui, -apple-system, sans-serif; color: #555; margin: 0 0 2pt; }
    p.source { font: 8.5pt system-ui, -apple-system, sans-serif; color: #888; margin: 0 0 20pt; word-break: break-all; }
    h2, h3, h4, h5, h6 { font-family: system-ui, -apple-system, sans-serif; page-break-after: avoid; margin: 16pt 0 6pt; }
    p { margin: 0 0 9pt; orphans: 3; widows: 3; }
    img { max-width: 100%; height: auto; page-break-inside: avoid; }
    figure { margin: 12pt 0; page-break-inside: avoid; }
    figcaption { font: 9pt system-ui, -apple-system, sans-serif; color: #555; margin-top: 4pt; }
    blockquote { margin: 0 0 9pt 14pt; padding-left: 10pt; border-left: 2pt solid #ccc; color: #333; }
    pre { white-space: pre-wrap; font-size: 9pt; }
    table { border-collapse: collapse; page-break-inside: avoid; }
    th, td { border: 0.5pt solid #bbb; padding: 3pt 6pt; }
    a { color: inherit; text-decoration: none; }
    """
}

extension PDFRenderer: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoad(throwing: Failure.loadFailed(error.localizedDescription))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishLoad(throwing: Failure.loadFailed(error.localizedDescription))
    }
}
