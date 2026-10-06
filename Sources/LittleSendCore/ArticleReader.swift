import Foundation

/// How a web article is turned into readable text.
public enum ArticleReader: String, CaseIterable, Codable, Sendable {
    /// Readability in a hidden WebKit view on this Mac: private, free, and it
    /// follows articles split across several pages.
    case local
    /// Instaparser's Article API: much faster (well under a second against
    /// several for the built-in reader, measured on real sends), but it needs
    /// an account and API key, sees every address sent through it, and cannot
    /// extract some sites at all — those fall back to the built-in reader.
    case instaparser

    public var displayName: String {
        switch self {
        case .local: return "Built-in reader"
        case .instaparser: return "Instaparser"
        }
    }
}

/// Reads an article with the chosen reader, falling back to this Mac's own.
///
/// Instaparser is offered because it is quicker, not because it is the only
/// way in — so a missing key, a rejected key, a spent quota or an outage never
/// stops a send. The article is read locally instead, and the note says why,
/// so a key that needs fixing does not go unnoticed behind a send that worked.
public enum ArticleReading {
    public struct Result: Sendable {
        public let article: ParsedArticle
        /// Set when Instaparser was chosen but the built-in reader was used.
        public let note: String?
    }

    public static func read(
        url: URL,
        reader: ArticleReader,
        instaparserAPIKey: String,
        instaparser: (URL, String) async throws -> ParsedArticle,
        local: (URL) async throws -> ParsedArticle
    ) async throws -> Result {
        guard reader == .instaparser else {
            return Result(article: try await local(url), note: nil)
        }

        let key = instaparserAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return Result(
                article: try await local(url),
                note: "No Instaparser API key, so it was read on this Mac."
            )
        }

        do {
            return Result(article: try await instaparser(url, key), note: nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Result(article: try await local(url), note: "\(reason) Read on this Mac instead.")
        }
    }
}
