import Foundation

/// Turns what was typed or pasted into an article's web address.
public enum ArticleLink {
    /// The address, or nil if the text isn't one. A missing "https://" is
    /// added, and a bare host needs a dot — "localhost" is not an article.
    ///
    /// An email address is not an address: `name@kindle.com` becomes
    /// `https://name@kindle.com`, which parses as a page on kindle.com with a
    /// username. Copying your own address during setup, or any email address,
    /// would otherwise fill the link field. A real article link has no
    /// username in it, so anything that does is refused.
    public static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              let host = url.host,
              host.contains(".")
        else { return nil }
        return url
    }
}
