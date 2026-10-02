import Foundation

/// Renders a parsed article as an email body.
///
/// Unlike the EPUB, this keeps images as absolute remote URLs: mail clients
/// fetch them on demand, and inlining megabytes of base64 into every message
/// would be wasteful.
///
/// Responsiveness is carried by **inline** styles rather than the stylesheet,
/// because several mail clients drop `<style>` blocks entirely. The stylesheet
/// is kept as an enhancement — media queries for small screens — but nothing
/// essential depends on it.
public enum ArticleEmailRenderer {

    /// The system UI stack, listing each platform's native face before the
    /// generic fallbacks.
    public static let fontStack = """
    -apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Roboto, \
    'Helvetica Neue', Arial, 'Noto Sans', sans-serif
    """

    /// Applied to every image so a 2000px-wide photo cannot force the layout
    /// wider than the screen. `height:auto` keeps the aspect ratio once the
    /// width is constrained.
    static let imageStyle = "max-width:100%;height:auto;display:block;margin:1.2em auto;"

    static let contentWidth = 680

    public struct Rendered {
        public let html: String
        public let plainText: String
        public let subject: String
    }

    /// - Parameter inlineImages: downloaded (and, where needed, shrunk) copies
    ///   to embed. Anything not in this list stays a remote URL, so a failed
    ///   download degrades to the original behaviour rather than a broken image.
    public static func render(
        article: ParsedArticle,
        inlineImages: [EmbeddedImage] = [],
        convertedHTML: String? = nil
    ) -> Rendered {
        // As in `EPUBBuilder.build`: pass the converted markup to skip
        // converting it again.
        let converted = convertedHTML ?? HTMLToXHTML.convert(article.html)
        let base = URL(string: article.url)
        var body = absolutizeURLs(in: converted, relativeTo: base)
        body = rewriteToContentIDs(in: body, using: inlineImages)
        body = applyInlineStyles(to: body)

        var byline: [String] = []
        if let author = article.author { byline.append(author) }
        if let site = article.siteName { byline.append(site) }
        if let date = article.publishedDate { byline.append(dateFormatter.string(from: date)) }

        let escapedURL = HTMLToXHTML.escapeAttribute(article.url)

        var header = """
        <h1 class="kc-title" style="font-family:\(fontStack);font-size:26px;\
        line-height:1.25;font-weight:700;margin:0 0 10px;">\
        \(HTMLToXHTML.escapeText(article.title))</h1>
        """
        if !byline.isEmpty {
            header += """
            \n<p style="font-size:14px;color:#5f6368;margin:0 0 6px;">\
            \(HTMLToXHTML.escapeText(byline.joined(separator: " · ")))</p>
            """
        }
        // Long URLs are the classic cause of horizontal scroll on phones.
        header += """
        \n<p style="font-size:13px;margin:0 0 28px;word-break:break-word;overflow-wrap:anywhere;">\
        <a href="\(escapedURL)" style="color:#0b57d0;text-decoration:none;">\
        \(HTMLToXHTML.escapeText(article.url))</a></p>
        """

        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <meta name="color-scheme" content="light dark"/>
        <title>\(HTMLToXHTML.escapeText(article.title))</title>
        <style>
          /* Enhancement only; every rule that matters is also inline. */
          img, figure, video { max-width: 100% !important; height: auto !important; }
          table { max-width: 100% !important; }
          pre { white-space: pre-wrap !important; word-wrap: break-word !important; }
          a { word-break: break-word; }
          @media only screen and (max-width: 620px) {
            .kc-wrap { padding: 16px !important; }
            .kc-body { font-size: 17px !important; }
            .kc-title { font-size: 22px !important; }
          }
        </style>
        </head>
        <body style="margin:0;padding:0;background:#ffffff;color:#1f1f1f;\
        -webkit-text-size-adjust:100%;text-size-adjust:100%;">
        <div class="kc-wrap" style="padding:24px;">
        <div class="kc-body" style="max-width:\(contentWidth)px;margin:0 auto;\
        font-family:\(fontStack);font-size:16px;line-height:1.65;color:#1f1f1f;">
        \(header)\(body)
        <hr style="border:0;border-top:1px solid #e0e0e0;margin:32px 0 12px;"/>
        <p style="color:#80868b;font-size:12px;margin:0;">Sent by LittleSend.</p>
        </div>
        </div>
        </body>
        </html>
        """

        var plain = article.title + "\n"
        if !byline.isEmpty { plain += byline.joined(separator: " · ") + "\n" }
        plain += article.url + "\n\n"
        plain += HTMLToXHTML.plainText(fromXHTML: converted)
        plain += "\n\n—\nSent by LittleSend."

        return Rendered(html: html, plainText: plain, subject: article.title)
    }

    /// Repoints `<img src>` at the embedded copies carried in the message.
    static func rewriteToContentIDs(in xhtml: String, using images: [EmbeddedImage]) -> String {
        guard !images.isEmpty else { return xhtml }

        var result = xhtml
        for image in images {
            let escaped = HTMLToXHTML.escapeAttribute(image.sourceURL)
            for variant in Set([image.sourceURL, escaped]) {
                result = result.replacingOccurrences(
                    of: "src=\"\(variant)\"",
                    with: "src=\"cid:\(image.contentID)\""
                )
            }
        }
        return result
    }

    // MARK: - Inline styling

    /// Adds the inline styles the layout depends on. The converter strips
    /// `style` attributes from the source, so nothing here is overwriting the
    /// publisher's own CSS — these are the only inline styles in the body.
    static func applyInlineStyles(to xhtml: String) -> String {
        var result = xhtml
        result = injectStyle(imageStyle, intoTag: "img", in: result, selfClosing: true)
        result = injectStyle(
            "max-width:100%;border-collapse:collapse;font-size:14px;",
            intoTag: "table", in: result
        )
        result = injectStyle(
            "white-space:pre-wrap;word-wrap:break-word;overflow-x:auto;font-size:14px;",
            intoTag: "pre", in: result
        )
        result = injectStyle(
            "margin:1.2em 0;padding:0 0 0 1em;border-left:3px solid #dadce0;color:#3c4043;",
            intoTag: "blockquote", in: result
        )
        result = injectStyle("margin:1.2em 0;", intoTag: "figure", in: result)
        result = injectStyle(
            "font-size:13px;color:#5f6368;text-align:center;",
            intoTag: "figcaption", in: result
        )
        return result
    }

    /// Inserts `style="…"` into every occurrence of `<tag …>`.
    static func injectStyle(
        _ style: String,
        intoTag tag: String,
        in xhtml: String,
        selfClosing: Bool = false
    ) -> String {
        let terminator = selfClosing ? "/>" : ">"
        var result = ""
        var remainder = Substring(xhtml)

        while let open = remainder.range(of: "<\(tag)") {
            // Guard against matching a longer name (<tablet> for <table>).
            let afterName = remainder[open.upperBound...]
            guard let next = afterName.first, next == ">" || next == "/" || next.isWhitespace else {
                result += remainder[..<open.upperBound]
                remainder = afterName
                continue
            }

            result += remainder[..<open.upperBound]
            guard let close = afterName.range(of: terminator) else {
                result += afterName
                remainder = Substring("")
                break
            }

            result += afterName[..<close.lowerBound]
            result += " style=\"\(style)\""
            result += terminator
            remainder = afterName[close.upperBound...]
        }
        result += remainder
        return result
    }

    // MARK: - URLs

    /// Rewrites relative `src` and `href` values against the article URL, so
    /// images and links still resolve once the markup leaves its original page.
    static func absolutizeURLs(in xhtml: String, relativeTo base: URL?) -> String {
        guard let base else { return xhtml }
        var result = xhtml
        for attribute in ["src", "href"] {
            for value in EPUBBuilder.attributeValues(named: attribute, in: xhtml) {
                let decoded = EPUBBuilder.decodeXMLEntities(value)
                guard !decoded.hasPrefix("http://"), !decoded.hasPrefix("https://"),
                      !decoded.hasPrefix("data:"), !decoded.hasPrefix("mailto:"),
                      !decoded.hasPrefix("#"), !decoded.isEmpty,
                      let absolute = URL(string: decoded, relativeTo: base)?.absoluteURL
                else { continue }
                result = result.replacingOccurrences(
                    of: "\(attribute)=\"\(value)\"",
                    with: "\(attribute)=\"\(HTMLToXHTML.escapeAttribute(absolute.absoluteString))\""
                )
            }
        }
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}
