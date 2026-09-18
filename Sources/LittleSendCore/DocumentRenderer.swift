import Foundation

/// Markdown and plain-text copies of an article, for the Desktop destination.
///
/// Both are rendered from the same XHTML the EPUB uses. `HTMLToXHTML` already
/// guarantees that is well-formed, so it can be read with a real XML parser
/// into a small tree — which is what makes nesting come out right: a list
/// inside a quotation, emphasis inside a link. Pattern-matching tags in the raw
/// HTML would get those wrong.
///
/// If parsing fails anyway, the body falls back to `HTMLToXHTML.plainText`,
/// the same fallback the EPUB uses, so a copy is always written.
public enum DocumentRenderer {

    public static func markdown(for article: ParsedArticle) -> String {
        render(article, style: .markdown)
    }

    public static func plainText(for article: ParsedArticle) -> String {
        render(article, style: .plain)
    }

    /// The EPUB's naming with the extension swapped, so every format of one
    /// article sorts together on the Desktop.
    public static func fileName(for article: ParsedArticle, format: DesktopFormat) -> String {
        let stem = (EPUBBuilder.fileName(for: article) as NSString).deletingPathExtension
        return "\(stem).\(format.fileExtension)"
    }

    enum Style { case markdown, plain }

    // MARK: - Assembly

    static func render(_ article: ParsedArticle, style: Style) -> String {
        var sections = [header(article, style: style)]

        let body: String
        if let root = Tree.parse(HTMLToXHTML.convert(article.html)) {
            body = Emitter(style: style, base: URL(string: article.url)).blocks(root.children)
        } else {
            body = HTMLToXHTML.plainText(article.html)
        }
        if !body.isEmpty { sections.append(body) }

        return sections.joined(separator: "\n\n") + "\n"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    static func header(_ article: ParsedArticle, style: Style) -> String {
        var meta: [String] = []
        if let author = article.author { meta.append(author) }
        if let site = article.siteName { meta.append(site) }
        if let date = article.publishedDate { meta.append(dateFormatter.string(from: date)) }

        switch style {
        case .markdown:
            var lines = ["# \(Emitter.escape(article.title))"]
            if !meta.isEmpty { lines.append("*\(Emitter.escape(meta.joined(separator: " · ")))*") }
            lines.append("[Original article](\(Emitter.linkSafe(article.url)))")
            return lines.joined(separator: "\n\n")
        case .plain:
            var lines = [article.title]
            if !meta.isEmpty { lines.append(meta.joined(separator: " · ")) }
            lines.append(article.url)
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - Tree

/// A minimal element tree read from well-formed XHTML.
final class Tree {
    /// Lowercased element name, or "#text" for character data.
    let name: String
    let attributes: [String: String]
    let text: String
    var children: [Tree] = []

    init(name: String, attributes: [String: String] = [:], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.text = text
    }

    static func parse(_ xhtml: String) -> Tree? {
        guard let data = "<root>\(xhtml)</root>".data(using: .utf8) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Tree?
        private var stack: [Tree] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let node = Tree(name: elementName.lowercased(), attributes: attributes)
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                root = node
            }
            stack.append(node)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            if !stack.isEmpty { stack.removeLast() }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.children.append(Tree(name: "#text", text: string))
        }
    }
}

// MARK: - Emitter

struct Emitter {
    let style: DocumentRenderer.Style
    let base: URL?

    /// Elements that start a new block. `br` is deliberately absent: it is a
    /// line break inside a paragraph, not a paragraph of its own.
    static let blockNames: Set<String> = [
        "p", "div", "section", "article", "aside", "header", "footer", "main", "nav",
        "figure", "figcaption", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
        "blockquote", "pre", "hr", "table", "thead", "tbody", "tfoot", "tr", "caption",
        "dl", "dt", "dd",
    ]

    // MARK: Blocks

    func blocks(_ nodes: [Tree]) -> String {
        var output: [String] = []
        var inlineRun: [Tree] = []

        func flush() {
            let text = paragraph(inline(inlineRun))
            if !text.isEmpty { output.append(text) }
            inlineRun.removeAll()
        }

        for node in nodes {
            if Self.blockNames.contains(node.name) {
                flush()
                let rendered = block(node)
                if !rendered.isEmpty { output.append(rendered) }
            } else {
                inlineRun.append(node)
            }
        }
        flush()
        return output.joined(separator: "\n\n")
    }

    private func block(_ node: Tree) -> String {
        switch node.name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = paragraph(inline(node.children))
            guard !text.isEmpty else { return "" }
            guard style == .markdown else { return text }
            // The article's own title is the document's only level-one
            // heading, so headings in the body start a level down.
            let level = Int(node.name.dropFirst()) ?? 1
            return String(repeating: "#", count: min(6, level + 1)) + " " + text

        case "p", "caption", "dt", "dd":
            return paragraph(inline(node.children))

        case "figcaption":
            let text = paragraph(inline(node.children))
            return style == .markdown && !text.isEmpty ? "*\(text)*" : text

        case "ul", "ol":
            return list(node, depth: 0)

        case "blockquote":
            let inner = blocks(node.children)
            guard !inner.isEmpty else { return "" }
            return inner.components(separatedBy: "\n").map { line in
                switch style {
                case .markdown: return line.isEmpty ? ">" : "> " + line
                case .plain: return line.isEmpty ? "" : "    " + line
                }
            }.joined(separator: "\n")

        case "pre":
            let code = rawText(node).trimmingCharacters(in: .newlines)
            guard !code.isEmpty else { return "" }
            return style == .markdown ? "```\n\(code)\n```" : code

        case "hr":
            return style == .markdown ? "---" : "* * *"

        case "table":
            return table(node)

        case "tr":
            return row(node).joined(separator: style == .markdown ? " | " : "\t")

        default:
            // Containers — div, section, figure, li out of place — contribute
            // only their contents.
            return blocks(node.children)
        }
    }

    private func list(_ node: Tree, depth: Int) -> String {
        let ordered = node.name == "ol"
        let indent = String(repeating: "    ", count: depth)
        var lines: [String] = []
        var number = 1

        for item in node.children where item.name == "li" {
            let marker: String
            switch style {
            case .markdown: marker = ordered ? "\(number). " : "- "
            case .plain: marker = ordered ? "\(number). " : "• "
            }
            number += 1

            var own: [Tree] = []
            var nested: [String] = []
            for part in item.children {
                if part.name == "ul" || part.name == "ol" {
                    nested.append(list(part, depth: depth + 1))
                } else {
                    own.append(part)
                }
            }

            let text = blocks(own)
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            lines.append(indent + marker + text)
            lines.append(contentsOf: nested.filter { !$0.isEmpty })
        }
        return lines.joined(separator: "\n")
    }

    private func table(_ node: Tree) -> String {
        let rows = collectRows(node).filter { !$0.isEmpty }
        guard !rows.isEmpty else { return "" }

        guard style == .markdown else {
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }

        // A Markdown table needs a header row and a separator, and every row
        // padded to the same number of columns.
        let columns = rows.map(\.count).max() ?? 1
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: "", count: columns - cells.count)
            return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                .joined(separator: " | ") + " |"
        }
        var output = [line(rows[0]), line(Array(repeating: "---", count: columns))]
        output.append(contentsOf: rows.dropFirst().map(line))
        return output.joined(separator: "\n")
    }

    private func collectRows(_ node: Tree) -> [[String]] {
        node.children.flatMap { child -> [[String]] in
            switch child.name {
            case "tr": return [row(child)]
            case "thead", "tbody", "tfoot": return collectRows(child)
            default: return []
            }
        }
    }

    private func row(_ node: Tree) -> [String] {
        node.children
            .filter { $0.name == "td" || $0.name == "th" }
            .map { paragraph(inline($0.children)) }
    }

    // MARK: Inline

    func inline(_ nodes: [Tree]) -> String {
        nodes.map(inlineNode).joined()
    }

    private func inlineNode(_ node: Tree) -> String {
        switch node.name {
        case "#text":
            let collapsed = node.text.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            )
            return style == .markdown ? Self.escape(collapsed) : collapsed

        case "strong", "b":
            return wrap(inline(node.children), in: "**")

        case "em", "i":
            return wrap(inline(node.children), in: "*")

        case "code":
            let code = rawText(node)
            return style == .markdown ? "`\(code)`" : code

        case "a":
            let text = inline(node.children)
            guard style == .markdown,
                  let href = node.attributes["href"],
                  let url = absolute(href),
                  !text.trimmingCharacters(in: .whitespaces).isEmpty
            else { return text }
            return "[\(text)](\(url))"

        case "img":
            guard let src = node.attributes["src"], let url = absolute(src) else { return "" }
            let alt = node.attributes["alt"] ?? ""
            switch style {
            case .markdown: return "![\(Self.escape(alt))](\(url))"
            case .plain: return alt.isEmpty ? "" : "[Image: \(alt)]"
            }

        case "br":
            return style == .markdown ? "  \n" : "\n"

        default:
            return inline(node.children)
        }
    }

    /// Emphasis markers must hug the text: `** bold**` is not bold in Markdown,
    /// so surrounding spaces move outside the markers.
    private func wrap(_ text: String, in marker: String) -> String {
        guard style == .markdown else { return text }
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return text }
        let lead = text.hasPrefix(" ") ? " " : ""
        let trail = text.hasSuffix(" ") ? " " : ""
        return lead + marker + core + marker + trail
    }

    /// Trims a paragraph and each of its lines, keeping a Markdown hard break's
    /// trailing spaces intact.
    private func paragraph(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                let trimmedStart = String(line.drop(while: { $0 == " " }))
                if style == .markdown, trimmedStart.hasSuffix("  ") {
                    return trimmedStart
                }
                return trimmedStart.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rawText(_ node: Tree) -> String {
        node.name == "#text" ? node.text : node.children.map(rawText).joined()
    }

    private func absolute(_ reference: String) -> String? {
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("javascript:"),
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL
        else { return nil }
        return Self.linkSafe(url.absoluteString)
    }

    /// Parentheses and spaces end a Markdown link destination early.
    static func linkSafe(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    /// Backslash-escapes the characters that would otherwise turn prose into
    /// Markdown syntax.
    static func escape(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_[]<".contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }
}
