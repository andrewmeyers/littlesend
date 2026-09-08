import Foundation

/// Cleans up the `<title>` publishers emit, which almost always carries the
/// site's own name ("Some Story | The Verge", "Wikipedia — Article").
///
/// Two signals are used: separator-delimited segments that match the site's
/// brand, and the article's own `<h1>`, which is usually the bare headline
/// without any of the site furniture.
public enum ArticleTitle {

    /// Separators publishers use between the headline and their brand.
    static let separators = [" | ", " – ", " — ", " - ", " · ", " :: ", " « ", " » ", " • ", " / "]

    public static func clean(
        rawTitle: String,
        html: String?,
        siteName: String?,
        url: String?,
        author: String? = nil
    ) -> String {
        let raw = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return raw }

        let brands = brandTokens(siteName: siteName, url: url, author: author)

        // The article's own <h1> is the most reliable headline when it lines up
        // with the start of the <title>.
        if let heading = html.flatMap(firstHeading(in:)), isUsableHeading(heading, rawTitle: raw) {
            return heading
        }

        var title = stripBrandSegments(from: raw, brands: brands)
        title = stripBrandPrefix(from: title, brands: brands)
        return title.isEmpty ? raw : title
    }

    // MARK: - Heading extraction

    /// Text of the first `<h1>` in the document, with markup removed.
    public static func firstHeading(in html: String) -> String? {
        let characters = Array(html)
        var index = 0

        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            guard matchesOpenH1(characters, at: index) else {
                index += 1
                continue
            }
            // Skip past the opening tag.
            guard let tagEnd = characters[index...].firstIndex(of: ">") else { return nil }
            var cursor = characters.index(after: tagEnd)

            var inner = ""
            while cursor < characters.count {
                if matchesCloseH1(characters, at: cursor) { break }
                inner.append(characters[cursor])
                cursor += 1
            }

            let text = stripTags(inner)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func matchesOpenH1(_ characters: [Character], at index: Int) -> Bool {
        guard index + 3 < characters.count else { return false }
        guard characters[index] == "<",
              String(characters[index + 1]).lowercased() == "h",
              characters[index + 2] == "1"
        else { return false }
        let next = characters[index + 3]
        return next == ">" || next.isWhitespace
    }

    private static func matchesCloseH1(_ characters: [Character], at index: Int) -> Bool {
        guard index + 3 < characters.count else { return false }
        return characters[index] == "<"
            && characters[index + 1] == "/"
            && String(characters[index + 2]).lowercased() == "h"
            && characters[index + 3] == "1"
    }

    static func stripTags(_ html: String) -> String {
        var text = ""
        var insideTag = false
        for character in html {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; text.append(" "); continue }
            if !insideTag { text.append(character) }
        }
        return decodeEntities(text)
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
            ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    /// A heading is trusted only when the `<title>` clearly starts with it, so
    /// an unrelated banner heading can never replace the real title.
    static func isUsableHeading(_ heading: String, rawTitle: String) -> Bool {
        let normalizedHeading = normalize(heading)
        let normalizedTitle = normalize(rawTitle)

        guard normalizedHeading.count >= 3, heading.count <= 300 else { return false }
        guard normalizedHeading != normalizedTitle else { return false }  // nothing to gain
        // Must be the leading part of the title, so a nav or banner heading can
        // never displace it.
        guard normalizedTitle.hasPrefix(normalizedHeading) else { return false }
        // Substantial on its own, or a clear majority of the title. The first
        // test matters because site furniture can be long ("… | Some Very Long
        // Publication Name"), which a ratio alone would reject.
        return normalizedHeading.count >= 12 || normalizedHeading.count * 2 >= normalizedTitle.count
    }

    // MARK: - Brand stripping

    /// Repeatedly drops a trailing segment when it names the site.
    static func stripBrandSegments(from title: String, brands: Set<String>) -> String {
        var current = title

        // Bounded: a title never carries more than a few brand suffixes.
        for _ in 0..<3 {
            var stripped = false
            for separator in separators {
                guard let range = current.range(of: separator, options: .backwards) else { continue }
                let tail = String(current[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard matchesBrand(tail, brands: brands) else { continue }

                let head = String(current[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                guard head.count >= 3 else { continue }
                current = head
                stripped = true
                break
            }
            if !stripped { break }
        }
        return current
    }

    /// Handles the "The Verge: Some Story" shape.
    static func stripBrandPrefix(from title: String, brands: Set<String>) -> String {
        for separator in separators + [": "] {
            guard let range = title.range(of: separator) else { continue }
            let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard matchesBrand(head, brands: brands) else { continue }

            let tail = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard tail.count >= 3 else { continue }
            return tail
        }
        return title
    }

    static func matchesBrand(_ candidate: String, brands: Set<String>) -> Bool {
        let normalized = normalize(candidate)
        guard !normalized.isEmpty, normalized.count <= 40 else { return false }

        // A suffix may be written as a bare domain ("theverge.com"), so compare
        // with the trailing TLD removed too.
        var variants = [normalized, droppingLeadingThe(normalized)]
        for tld in ["com", "org", "net", "co", "couk", "io", "news", "uk", "us"] {
            guard normalized.hasSuffix(tld), normalized.count > tld.count + 2 else { continue }
            let trimmed = String(normalized.dropLast(tld.count))
            variants.append(trimmed)
            variants.append(droppingLeadingThe(trimmed))
        }
        return variants.contains { brands.contains($0) }
    }

    /// Everything that plausibly names this publication.
    static func brandTokens(siteName: String?, url: String?, author: String? = nil) -> Set<String> {
        var tokens: Set<String> = []

        func insert(_ value: String) {
            let normalized = normalize(value)
            guard !normalized.isEmpty else { return }
            tokens.insert(normalized)
            tokens.insert(droppingLeadingThe(normalized))
        }

        if let siteName { insert(siteName) }
        // Personal sites append the writer rather than a publication:
        // "Some Essay | Bill Gates". The byline names the same thing a
        // masthead would, so it strips the same way.
        if let author { insert(author) }

        if let url, let host = URL(string: url)?.host?.lowercased() {
            insert(host)
            let labels = host.split(separator: ".")
            // The registrable label: "theverge" in www.theverge.com, "wikipedia"
            // in en.wikipedia.org.
            if labels.count >= 2 {
                insert(String(labels[labels.count - 2]))
            }
            if let first = labels.first, first != "www" {
                insert(String(first))
            }
        }
        tokens.remove("")
        return tokens
    }

    static func normalize(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }

    private static func droppingLeadingThe(_ normalized: String) -> String {
        guard normalized.hasPrefix("the"), normalized.count > 5 else { return normalized }
        return String(normalized.dropFirst(3))
    }
}
