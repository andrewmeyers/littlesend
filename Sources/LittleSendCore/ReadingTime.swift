import Foundation
import NaturalLanguage

/// How long an article takes to read.
///
/// Words are counted with `NLTokenizer` rather than by splitting on spaces.
/// Splitting on whitespace counts a Japanese or Chinese article as a handful of
/// "words" — those languages do not put spaces between them — and would call a
/// twenty-minute read a one-minute one.
public enum ReadingTime {

    /// Average silent reading speed for non-fiction, in words per minute
    /// (Brysbaert, 2019). An estimate, and presented as one.
    public static let wordsPerMinute = 238

    public static func wordCount(ofHTML html: String) -> Int {
        wordCount(ofText: plainText(fromHTML: html))
    }

    public static func wordCount(ofText text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { _, _ in
            count += 1
            return true
        }
        return count
    }

    /// Whole minutes, never less than one — "a 0-minute read" is not a thing.
    public static func minutes(forWords words: Int) -> Int {
        max(1, Int((Double(words) / Double(wordsPerMinute)).rounded()))
    }

    /// Tags out, the handful of entities that affect word boundaries decoded.
    /// Scripts and styles go entirely, so their contents are not counted as
    /// prose.
    static func plainText(fromHTML html: String) -> String {
        var text = html
        // (?s) lets `.` cross newlines; a real <script> block spans many lines.
        for pattern in ["(?s)<script\\b[^>]*>.*?</script>", "(?s)<style\\b[^>]*>.*?</style>"] {
            text = text.replacingOccurrences(
                of: pattern, with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&mdash;", " — "), ("&ndash;", " – "), ("&hellip;", "…"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
    }
}
