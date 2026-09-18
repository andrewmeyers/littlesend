import Foundation

/// Finds the next page of a multi-page article — conservatively.
///
/// The danger in following "next" links is not missing a page; it is grabbing
/// the wrong one. The same markup that marks page 2 of an article often marks
/// the next *article* — older WordPress themes put `<link rel="next">` on every
/// post, pointing at the following post — and stitching an unrelated story onto
/// the end of a book is worse than stopping at page 1.
///
/// So a link is followed only when its address is the first page's address with
/// a page number added, and that number is the next one in sequence:
///
///     /story        →  /story/2  →  /story/3
///     /story        →  /story/page/2
///     /story?id=7   →  /story?id=7&page=2
///
/// `rel="next"` links are tried before ordinary links, but both must pass that
/// same test. A link to another article, another date, or another site cannot.
public enum Pagination {

    /// Pages read at most, counting the first.
    ///
    /// Generous on purpose. Long-form reviews run well past 10 — MacStories'
    /// iOS and iPadOS 27 review is 16 pages — and a cap that cuts one off
    /// mid-section is a silent failure. Runaway reading is already prevented by
    /// the address rule and by stopping at repeated text, so this only bounds
    /// the time a genuinely enormous article can take.
    public static let maximumPages = 50

    /// Query parameters that carry a page number. Deliberately not `p`, which
    /// WordPress uses for post IDs: `?p=124` is the next *post*, not page 124.
    static let pageQueryKeys: Set<String> = ["page", "pg", "pagenum", "pagenumber", "page_num"]

    /// The first page's address with any page marker taken off — what every
    /// later page must match.
    public struct Base: Equatable, Sendable {
        let host: String
        let path: String
        let query: [String]
        /// The page the reader started on. Usually 1.
        public let startPage: Int

        public init?(url: URL) {
            guard let parts = Parts(url) else { return nil }
            var path = parts.path
            var start = parts.queryPage ?? 1

            // `/page/N` is explicit enough to read as a page even on the first
            // address. A bare trailing number is not: /2024/09/14 is a date, and
            // taking 14 as the page would make /2024/09/15 look like page 15.
            if parts.queryPage == nil, let range = path.range(of: "/page/", options: .backwards),
               let number = Pagination.pageNumber(String(path[range.upperBound...])) {
                path = String(path[..<range.lowerBound])
                start = number
            }

            host = parts.host
            self.path = path
            query = parts.otherQuery
            startPage = start
        }
    }

    /// The first candidate that is exactly page `page` of the article at
    /// `base` and has not been read already.
    public static func nextPage(
        after base: Base,
        expecting page: Int,
        candidates: [URL],
        visited: Set<String>
    ) -> URL? {
        candidates.first { url in
            pageNumber(of: url, in: base) == page && !visited.contains(visitKey(url))
        }
    }

    /// Which page of `base` this address is, or nil if it is not a page of that
    /// article at all.
    static func pageNumber(of url: URL, in base: Base) -> Int? {
        guard let parts = Parts(url), parts.host == base.host, parts.otherQuery == base.query else {
            return nil
        }

        var pathPage: Int?
        if parts.path != base.path {
            guard parts.path.hasPrefix(base.path + "/") else { return nil }
            let tail = String(parts.path.dropFirst(base.path.count))
            if tail.hasPrefix("/page/") {
                pathPage = pageNumber(String(tail.dropFirst("/page/".count)))
            } else {
                pathPage = pageNumber(String(tail.dropFirst()))
            }
            // Anything else after the article's path — /story/2/comments,
            // /story-sequel — is a different page, not a numbered one.
            guard pathPage != nil else { return nil }
        }

        switch (parts.queryPage, pathPage) {
        case (nil, nil): return 1
        case let (query?, nil): return query
        case let (nil, path?): return path
        default: return nil
        }
    }

    /// An address with its fragment removed, for remembering what was read.
    public static func visitKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    /// Enough of a page's text to recognise it again. A site that ignores the
    /// page number and serves page 1 at every address would otherwise have the
    /// article repeated ten times over.
    public static func fingerprint(ofHTML html: String) -> String {
        HTMLToXHTML.plainText(html)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(80)
            .joined(separator: " ")
    }

    /// Digits only, within a sane range.
    private static func pageNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(text), (1...9999).contains(number)
        else { return nil }
        return number
    }

    /// An address broken into the parts pages are compared on.
    struct Parts {
        /// Lowercased, without a leading "www.".
        let host: String
        /// Without a trailing slash.
        let path: String
        /// Every query item except a page marker, sorted, so order is ignored.
        let otherQuery: [String]
        let queryPage: Int?

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  var host = components.host?.lowercased(), !host.isEmpty
            else { return nil }
            if host.hasPrefix("www.") { host.removeFirst(4) }

            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }

            var other: [String] = []
            var page: Int?
            for item in components.percentEncodedQueryItems ?? [] {
                if Pagination.pageQueryKeys.contains(item.name.lowercased()) {
                    // Two page markers, or one that is not a number, is not an
                    // address this can reason about.
                    guard page == nil, let number = item.value.flatMap(Pagination.pageNumber) else {
                        return nil
                    }
                    page = number
                } else {
                    other.append("\(item.name)=\(item.value ?? "")")
                }
            }

            self.host = host
            self.path = path
            self.otherQuery = other.sorted()
            self.queryPage = page
        }
    }
}
