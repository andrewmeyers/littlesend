import Foundation

/// Converts the loose HTML that article extractors emit into well-formed XHTML
/// suitable for an EPUB.
///
/// This is deliberately a small tag-rewriting scanner rather than a full HTML5
/// parser. It guarantees well-formed output by construction: every emitted tag
/// is normalized, every attribute is quoted and escaped, unknown elements are
/// unwrapped, and an element stack closes anything the source left open.
public enum HTMLToXHTML {

    /// Elements kept as-is in the output.
    static let allowed: Set<String> = [
        "p", "div", "span", "a", "em", "i", "strong", "b", "u", "s", "strike",
        "blockquote", "pre", "code", "kbd", "samp", "var",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "dl", "dt", "dd",
        "img", "figure", "figcaption", "br", "hr",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption", "col", "colgroup",
        "sub", "sup", "small", "cite", "q", "abbr", "time", "mark", "del", "ins",
        "section", "article", "aside", "header", "footer", "nav", "main", "ruby", "rt", "rp",
    ]

    /// Elements dropped together with all of their content.
    static let discarded: Set<String> = [
        "script", "style", "noscript", "iframe", "form", "input", "button", "select",
        "textarea", "object", "embed", "video", "audio", "canvas", "svg", "math",
        "template", "dialog", "menu", "link", "meta", "title", "base", "param",
        "source", "track", "picture",
    ]

    /// Elements nested deeper than this are unwrapped. libxml2 — and therefore
    /// `XMLParser`, and most EPUB readers — refuse documents nested past ~256
    /// levels, and no real article needs anywhere near that.
    static let maximumNestingDepth = 100

    /// Elements that never have children and must be emitted self-closed.
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Attributes preserved on output. Everything else (event handlers, data-*,
    /// framework noise) is dropped so the XHTML stays clean and predictable.
    static let allowedAttributes: Set<String> = [
        "href", "src", "alt", "title", "colspan", "rowspan", "datetime",
        "cite", "lang", "dir", "id", "start", "reversed", "value",
    ]

    /// Named character references beyond the five XML predefines, mapped to the
    /// numeric references XML understands.
    static let namedEntities: [String: Int] = [
        "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165,
        "brvbar": 166, "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171,
        "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176, "plusmn": 177,
        "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183,
        "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
        "frac34": 190, "iquest": 191, "times": 215, "divide": 247,
        "agrave": 224, "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
        "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234, "euml": 235,
        "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239, "ntilde": 241,
        "ograve": 242, "oacute": 243, "ocirc": 244, "otilde": 245, "ouml": 246, "oslash": 248,
        "ugrave": 249, "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253, "yuml": 255,
        "szlig": 223, "Agrave": 192, "Aacute": 193, "Auml": 196, "Eacute": 201,
        "Ouml": 214, "Uuml": 220, "Ccedil": 199, "Ntilde": 209,
        "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205,
        "lrm": 8206, "rlm": 8207, "ndash": 8211, "mdash": 8212,
        "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
        "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230,
        "permil": 8240, "prime": 8242, "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250,
        "oline": 8254, "frasl": 8260, "euro": 8364, "trade": 8482,
        "larr": 8592, "uarr": 8593, "rarr": 8594, "darr": 8595, "harr": 8596,
        "minus": 8722, "le": 8804, "ge": 8805, "ne": 8800, "asymp": 8776,
        "infin": 8734, "hearts": 9829, "diams": 9830, "clubs": 9827, "spades": 9824,
        "alpha": 945, "beta": 946, "gamma": 947, "delta": 948, "pi": 960, "sigma": 963,
        "omega": 969, "Omega": 937, "mu": 956, "lambda": 955,
    ]

    /// Rewrites `html` as an XHTML fragment.
    ///
    /// The scan runs over UTF-8 bytes. Every byte that means anything here —
    /// `<`, `>`, `&`, quotes, `=`, `/`, ASCII letters and spaces — is ASCII,
    /// and no byte of a multi-byte UTF-8 sequence is, so text between them can
    /// be copied through untouched. Working in `Character`s instead paid for
    /// grapheme breaking on every character of the article, and for a String
    /// append for each one.
    public static func convert(_ html: String) -> String {
        var scanner = Scanner(source: Array(html.utf8))
        return scanner.run()
    }

    // MARK: - Scanner

    private struct Scanner {
        let source: [UInt8]
        var index = 0
        var output: [UInt8] = []
        var openElements: [String] = []

        init(source: [UInt8]) {
            self.source = source
            output.reserveCapacity(source.count + source.count / 8)
        }

        mutating func run() -> String {
            while index < source.count {
                if source[index] == ASCIIByte.lessThan {
                    if consumeComment() { continue }
                    if consumeDoctype() { continue }
                    if consumeTag() { continue }
                    // A bare "<" that does not start a tag: emit it as text.
                    emit("&lt;")
                    index += 1
                } else {
                    consumeText()
                }
            }
            while let name = openElements.popLast() {
                emit("</\(name)>")
            }
            return String(decoding: output, as: UTF8.self)
        }

        mutating func emit(_ string: String) {
            output.append(contentsOf: string.utf8)
        }

        // MARK: Text

        mutating func consumeText() {
            let start = index
            while index < source.count, source[index] != ASCIIByte.lessThan { index += 1 }
            HTMLToXHTML.appendEscapedText(source[start..<index], to: &output)
        }

        // MARK: Comments and doctype

        mutating func consumeComment() -> Bool {
            guard matches("<!--") else { return false }
            index += 4
            while index < source.count {
                if source[index] == ASCIIByte.hyphen, matches("-->") {
                    index += 3
                    return true
                }
                index += 1
            }
            return true
        }

        mutating func consumeDoctype() -> Bool {
            guard matches("<!") || matches("<?") else { return false }
            while index < source.count, source[index] != ASCIIByte.greaterThan { index += 1 }
            if index < source.count { index += 1 }
            return true
        }

        // MARK: Tags

        mutating func consumeTag() -> Bool {
            guard index + 1 < source.count else { return false }
            var cursor = index + 1
            let isClosing = source[cursor] == ASCIIByte.slash
            if isClosing { cursor += 1 }
            // HTML tag names begin with an ASCII letter; "<é" or "< 3" is text.
            guard cursor < source.count, ASCIIByte.isLetter(source[cursor]) else { return false }

            let nameStart = cursor
            while cursor < source.count, ASCIIByte.isLetterOrDigit(source[cursor]) { cursor += 1 }
            let name = String(decoding: source[nameStart..<cursor], as: UTF8.self).lowercased()

            index = cursor
            let attributes = isClosing ? [:] : parseAttributes()
            let selfClosed = skipToTagEnd()

            if isClosing {
                emitEndTag(name)
                return true
            }

            if discarded.contains(name) {
                // Skip the element's entire content when it has one.
                if !voidElements.contains(name) && !selfClosed {
                    skipElementContent(named: name)
                }
                return true
            }

            guard allowed.contains(name) else {
                // Unknown element: unwrap it, keeping its children.
                return true
            }

            if !voidElements.contains(name), openElements.count >= maximumNestingDepth {
                // Too deep to emit: unwrap this level but keep the content.
                return true
            }

            emitStartTag(name, attributes: attributes, selfClosed: selfClosed)
            return true
        }

        mutating func parseAttributes() -> [String: String] {
            var attributes: [String: String] = [:]
            while index < source.count {
                skipWhitespace()
                guard index < source.count else { break }
                if source[index] == ASCIIByte.greaterThan || source[index] == ASCIIByte.slash { break }

                let nameStart = index
                while index < source.count,
                      !ASCIIByte.isWhitespace(source[index]),
                      source[index] != ASCIIByte.equals,
                      source[index] != ASCIIByte.greaterThan,
                      source[index] != ASCIIByte.slash {
                    index += 1
                }
                if index == nameStart {
                    index += 1
                    continue
                }
                let name = String(decoding: source[nameStart..<index], as: UTF8.self).lowercased()

                skipWhitespace()
                var value = name  // boolean attribute: value defaults to its own name
                if index < source.count, source[index] == ASCIIByte.equals {
                    index += 1
                    skipWhitespace()
                    value = parseAttributeValue()
                }
                if attributes[name] == nil, isValidAttributeName(name) {
                    attributes[name] = value
                }
            }
            return attributes
        }

        mutating func parseAttributeValue() -> String {
            guard index < source.count else { return "" }
            let quote = source[index]
            if quote == ASCIIByte.doubleQuote || quote == ASCIIByte.singleQuote {
                index += 1
                let start = index
                while index < source.count, source[index] != quote { index += 1 }
                let value = String(decoding: source[start..<index], as: UTF8.self)
                if index < source.count { index += 1 }
                return value
            }
            let start = index
            while index < source.count, !ASCIIByte.isWhitespace(source[index]), source[index] != ASCIIByte.greaterThan {
                index += 1
            }
            return String(decoding: source[start..<index], as: UTF8.self)
        }

        /// Advances past `>`, reporting whether the tag was self-closing.
        mutating func skipToTagEnd() -> Bool {
            var selfClosed = false
            while index < source.count, source[index] != ASCIIByte.greaterThan {
                if source[index] == ASCIIByte.slash { selfClosed = true }
                index += 1
            }
            if index < source.count { index += 1 }
            return selfClosed
        }

        mutating func skipElementContent(named name: String) {
            var depth = 1
            while index < source.count, depth > 0 {
                guard source[index] == ASCIIByte.lessThan else {
                    index += 1
                    continue
                }
                if matchesTag(name, closing: true) {
                    depth -= 1
                    _ = skipToTagEnd()
                } else if matchesTag(name, closing: false) {
                    depth += 1
                    _ = skipToTagEnd()
                } else {
                    index += 1
                }
            }
        }

        // MARK: Emitting

        mutating func emitStartTag(_ name: String, attributes: [String: String], selfClosed: Bool) {
            var tag = "<\(name)"
            for key in attributes.keys.sorted() where allowedAttributes.contains(key) {
                tag += " \(key)=\"\(escapeAttribute(attributes[key]!))\""
            }
            if voidElements.contains(name) {
                tag += "/>"
                emit(tag)
                return
            }
            tag += ">"
            emit(tag)
            if selfClosed {
                emit("</\(name)>")
            } else {
                openElements.append(name)
            }
        }

        mutating func emitEndTag(_ name: String) {
            guard !voidElements.contains(name), allowed.contains(name) else { return }
            guard let position = openElements.lastIndex(of: name) else { return }
            // Close everything the source left open inside this element.
            while openElements.count > position {
                let open = openElements.removeLast()
                emit("</\(open)>")
            }
        }

        // MARK: Helpers

        mutating func skipWhitespace() {
            while index < source.count, ASCIIByte.isWhitespace(source[index]) { index += 1 }
        }

        /// Whether `string` (ASCII) appears at the current position.
        func matches(_ string: String) -> Bool {
            var cursor = index
            for byte in string.utf8 {
                guard cursor < source.count, source[cursor] == byte else { return false }
                cursor += 1
            }
            return true
        }

        /// Whether a start or end tag for `name` (lowercase ASCII) begins at
        /// the current position, in any letter case.
        func matchesTag(_ name: String, closing: Bool) -> Bool {
            guard index < source.count, source[index] == ASCIIByte.lessThan else { return false }
            var cursor = index + 1
            if closing {
                guard cursor < source.count, source[cursor] == ASCIIByte.slash else { return false }
                cursor += 1
            }
            for byte in name.utf8 {
                guard cursor < source.count, ASCIIByte.lowercased(source[cursor]) == byte else { return false }
                cursor += 1
            }
            // Ensure the tag name ended rather than matching a longer name.
            guard cursor < source.count else { return true }
            let following = source[cursor]
            return ASCIIByte.isWhitespace(following) || following == ASCIIByte.greaterThan || following == ASCIIByte.slash
        }
    }

    /// The ASCII bytes the scanners care about.
    private enum ASCIIByte {
        static let lessThan = UInt8(ascii: "<")
        static let greaterThan = UInt8(ascii: ">")
        static let slash = UInt8(ascii: "/")
        static let equals = UInt8(ascii: "=")
        static let hyphen = UInt8(ascii: "-")
        static let ampersand = UInt8(ascii: "&")
        static let semicolon = UInt8(ascii: ";")
        static let hash = UInt8(ascii: "#")
        static let doubleQuote = UInt8(ascii: "\"")
        static let singleQuote = UInt8(ascii: "'")
        static let newline = UInt8(ascii: "\n")

        static func isLetter(_ byte: UInt8) -> Bool {
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
        }

        static func isLetterOrDigit(_ byte: UInt8) -> Bool {
            isLetter(byte) || (byte >= 0x30 && byte <= 0x39)
        }

        /// HTML's whitespace: space, tab, LF, VT, FF, CR.
        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
        }

        static func lowercased(_ byte: UInt8) -> UInt8 {
            byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
    }

    // MARK: - Escaping

    static func isValidAttributeName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Escapes text content, converting HTML named entities into numeric ones
    /// and neutralizing any ampersand that does not begin a valid reference.
    static func escapeText(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        appendEscapedText(bytes[...], to: &output)
        return String(decoding: output, as: UTF8.self)
    }

    /// `escapeText`, appending UTF-8 to `output`. Slice indices are positions
    /// in the parent array, so the walk runs from `startIndex`, not from 0.
    static func appendEscapedText(_ bytes: ArraySlice<UInt8>, to output: inout [UInt8]) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == ASCIIByte.lessThan {
                output.append(contentsOf: "&lt;".utf8)
                index += 1
            } else if byte == ASCIIByte.greaterThan {
                output.append(contentsOf: "&gt;".utf8)
                index += 1
            } else if byte == ASCIIByte.ampersand {
                if let (replacement, length) = entityReference(in: bytes, at: index) {
                    output.append(contentsOf: replacement.utf8)
                    index += length
                } else {
                    output.append(contentsOf: "&amp;".utf8)
                    index += 1
                }
            } else {
                output.append(byte)
                index += 1
            }
        }
    }

    static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Reads an entity reference beginning at `start`, returning its XML-safe
    /// form and the number of bytes consumed.
    private static func entityReference(in bytes: ArraySlice<UInt8>, at start: Int) -> (String, Int)? {
        var cursor = start + 1
        guard cursor < bytes.endIndex else { return nil }

        if bytes[cursor] == ASCIIByte.hash {
            cursor += 1
            let isHex = cursor < bytes.endIndex
                && (bytes[cursor] == UInt8(ascii: "x") || bytes[cursor] == UInt8(ascii: "X"))
            if isHex { cursor += 1 }
            let digitsStart = cursor
            while cursor < bytes.endIndex, bytes[cursor] != ASCIIByte.semicolon {
                cursor += 1
                if cursor - digitsStart > 8 { return nil }
            }
            guard cursor < bytes.endIndex, cursor > digitsStart else { return nil }
            let digits = String(decoding: bytes[digitsStart..<cursor], as: UTF8.self)
            guard let value = UInt32(digits, radix: isHex ? 16 : 10), isValidXMLScalar(value) else { return nil }
            return ("&#\(value);", cursor - start + 1)
        }

        let nameStart = cursor
        while cursor < bytes.endIndex, bytes[cursor] != ASCIIByte.semicolon {
            cursor += 1
            if cursor - nameStart > 12 { return nil }
        }
        guard cursor < bytes.endIndex, cursor > nameStart else { return nil }
        let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)

        if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
            return ("&\(name);", cursor - start + 1)
        }
        if let scalar = namedEntities[name] {
            return ("&#\(scalar);", cursor - start + 1)
        }
        return nil
    }

    /// XML 1.0 forbids most control characters, so references to them are dropped.
    private static func isValidXMLScalar(_ value: UInt32) -> Bool {
        value == 0x9 || value == 0xA || value == 0xD
            || (value >= 0x20 && value <= 0xD7FF)
            || (value >= 0xE000 && value <= 0xFFFD)
            || (value >= 0x10000 && value <= 0x10FFFF)
    }

    /// Elements that end a line of prose. Everything else is inline, and
    /// removing its tags must not introduce a space.
    static let blockElements: Set<String> = [
        "p", "div", "br", "hr", "li", "tr", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "aside", "header", "footer", "figure",
        "figcaption", "dt", "dd", "ul", "ol", "dl", "table", "caption",
    ]

    /// Strips all markup, used for the plain-text fallback and for the
    /// plain-text alternative of the HTML email.
    public static func plainText(_ html: String) -> String {
        plainText(fromXHTML: convert(html))
    }

    /// `plainText(_:)` for markup that has already been through `convert`,
    /// so a caller holding the XHTML does not pay for a second conversion.
    static func plainText(fromXHTML xhtml: String) -> String {
        let bytes = Array(xhtml.utf8)
        var textBytes: [UInt8] = []
        textBytes.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            guard bytes[index] == ASCIIByte.lessThan else {
                let start = index
                while index < bytes.count, bytes[index] != ASCIIByte.lessThan { index += 1 }
                textBytes.append(contentsOf: bytes[start..<index])
                continue
            }

            // Read the tag name so block boundaries can become line breaks.
            var cursor = index + 1
            if cursor < bytes.count, bytes[cursor] == ASCIIByte.slash { cursor += 1 }
            let nameStart = cursor
            while cursor < bytes.count, ASCIIByte.isLetterOrDigit(bytes[cursor]) { cursor += 1 }
            let name = String(decoding: bytes[nameStart..<cursor], as: UTF8.self)
            while cursor < bytes.count, bytes[cursor] != ASCIIByte.greaterThan { cursor += 1 }
            index = cursor < bytes.count ? cursor + 1 : bytes.count

            // Inline tags vanish without a trace; block tags end the line.
            if blockElements.contains(name.lowercased()) {
                textBytes.append(ASCIIByte.newline)
            }
        }
        let text = String(decoding: textBytes, as: UTF8.self)

        let decoded = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&#8217;", with: "\u{2019}")
            .replacingOccurrences(of: "&#8212;", with: "\u{2014}")
            .replacingOccurrences(of: "&amp;", with: "&")

        return decoded
            .components(separatedBy: .newlines)
            .map { line in
                // Collapse the whitespace runs left behind by removed markup.
                line.split(separator: " ", omittingEmptySubsequences: true)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
