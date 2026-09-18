import Foundation
import WebKit

/// Extracts an article by loading the page in a real WebKit view and running
/// Mozilla's Readability against the live DOM.
///
/// This is how every article is read — there is no hosted parser behind it.
/// The advantage is not cleverness but identity: many sites refuse plain HTTP
/// clients outright — a `curl` of gatesnotes.com returns 403 with no article
/// markup at all — while serving the same URL happily to a browser. Running
/// inside WebKit means being a browser, which also means client-rendered pages
/// have executed their JavaScript by the time the DOM is read.
///
/// Multi-page articles are followed to their later pages and joined into one.
/// Which links count as a later page is decided by `Pagination`, strictly
/// enough that a link to a different article is never followed.
///
/// Everything happens on this Mac: no account, no API key, and no third party
/// sees which pages are being read. The cost is a few seconds per page while
/// it loads.
@MainActor
public final class LocalArticleParser: NSObject {

    public enum Failure: LocalizedError {
        case readabilityUnavailable
        case navigationFailed(String)
        case timedOut
        case noArticleFound
        case unreadableResult(String)

        public var errorDescription: String? {
            switch self {
            case .readabilityUnavailable:
                return "The local reader is missing its Readability script."
            case .navigationFailed(let reason):
                return "The local reader could not load the page: \(reason)"
            case .timedOut:
                return "The local reader timed out loading the page."
            case .noArticleFound:
                return "The local reader could not find an article on that page."
            case .unreadableResult(let reason):
                return "The local reader returned something unusable: \(reason)"
            }
        }
    }

    /// How long to wait for a page to finish loading.
    private let timeout: TimeInterval
    /// Grace period after `didFinish` for client-rendered content to appear.
    private let settleDelay: TimeInterval
    /// The same, for later pages. The site's scripts are already warm by then.
    private let laterPageSettleDelay: TimeInterval

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?
    /// The main frame's HTTP status for the current load. An error page still
    /// "finishes loading", so without this a 404 would be read as page 4.
    private var lastStatusCode: Int?

    public init(timeout: TimeInterval = 30, settleDelay: TimeInterval = 2.5, laterPageSettleDelay: TimeInterval = 1) {
        self.timeout = timeout
        self.settleDelay = settleDelay
        self.laterPageSettleDelay = laterPageSettleDelay
        super.init()
    }

    /// - Parameter onMorePages: called with each later page's number as reading
    ///   it begins, so progress can say so.
    public func parse(
        url: URL,
        onMorePages: @Sendable (Int) -> Void = { _ in }
    ) async throws -> ParsedArticle {
        let script = try Self.readabilitySource()

        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        defer {
            webView.navigationDelegate = nil
            self.webView = nil
            self.loadContinuation = nil
        }

        // The first page has to work; if it does not, there is no article.
        let first = try await read(url, script: script, in: webView, settle: settleDelay, requireSuccess: false)
        var article = first.article

        // Matched against the address the browser actually landed on, since a
        // redirect can add "www." or a trailing slash the typed address lacked.
        guard let base = Pagination.Base(url: URL(string: article.url) ?? url) else { return article }

        var pages = [article.html]
        var fingerprints: Set<String> = [Pagination.fingerprint(ofHTML: article.html)]
        var visited: Set<String> = [Pagination.visitKey(url), Pagination.visitKey(URL(string: article.url) ?? url)]
        var candidates = first.candidates
        var expected = base.startPage + 1

        while pages.count < Pagination.maximumPages,
              let next = Pagination.nextPage(after: base, expecting: expected, candidates: candidates, visited: visited) {
            visited.insert(Pagination.visitKey(next))
            onMorePages(expected)

            // A later page failing ends the article there; it does not throw
            // away the pages already read.
            guard let page = try? await read(
                next, script: script, in: webView, settle: laterPageSettleDelay, requireSuccess: true
            ) else { break }

            // Where the browser actually ended up must still be this page of
            // this article — a site can redirect a page address to its front
            // page, or to a different story altogether.
            guard let landed = URL(string: page.article.url),
                  Pagination.pageNumber(of: landed, in: base) == expected
            else { break }
            let fingerprint = Pagination.fingerprint(ofHTML: page.article.html)
            guard !fingerprint.isEmpty, fingerprints.insert(fingerprint).inserted else { break }

            pages.append(page.article.html)
            candidates = page.candidates
            expected += 1
        }

        // Title, byline and date stay page 1's; later pages only add text.
        article.html = pages.joined(separator: "\n")
        article.pageCount = pages.count
        return article
    }

    // MARK: - Loading

    private struct Page {
        let article: ParsedArticle
        let candidates: [URL]
    }

    /// - Parameter requireSuccess: refuse an HTTP error page. Off for the first
    ///   page, which keeps its long-standing behaviour; on for later pages,
    ///   where an error page would be joined onto a real article.
    private func read(
        _ url: URL, script: String, in webView: WKWebView, settle: TimeInterval, requireSuccess: Bool
    ) async throws -> Page {
        try await load(url: url, in: webView)
        if requireSuccess, let status = lastStatusCode, status >= 400 {
            throw Failure.navigationFailed("HTTP \(status)")
        }

        // Let client-rendered pages populate before reading the DOM.
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))

        _ = try? await webView.evaluateJavaScript(script)
        let raw = try await webView.evaluateJavaScript(Self.extractionScript)

        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw Failure.unreadableResult("not a string")
        }
        return Page(
            article: try Self.article(fromReadabilityJSON: data, requestedURL: url),
            candidates: Self.nextPageCandidates(fromReadabilityJSON: data)
        )
    }

    private func load(url: URL, in webView: WKWebView) async throws {
        let timeoutTask = Task { [timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.failLoad(with: Failure.timedOut)
        }
        defer { timeoutTask.cancel() }

        lastStatusCode = nil
        try await withCheckedThrowingContinuation { continuation in
            self.loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func finishLoad() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    private func failLoad(with error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }

    // MARK: - Readability

    /// The vendored copy of Mozilla's Readability, bundled as a resource so
    /// reading needs no network of its own and cannot drift underneath us.
    nonisolated static func readabilitySource() throws -> String {
        // Inside the .app the script is copied into Contents/Resources, which
        // is what Bundle.main searches. Bundle.module is deliberately *not*
        // consulted there: SwiftPM's generated accessor looks beside the
        // bundle root and otherwise falls back to a hardcoded .build path from
        // the machine that compiled it — absent anywhere else, and it calls
        // fatalError rather than returning nil. Touching it in a shipped app
        // would turn a missing resource into a crash.
        if let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        guard !Bundle.main.bundlePath.hasSuffix(".app") else {
            throw Failure.readabilityUnavailable
        }

        // Tests and other SwiftPM contexts, where the resource bundle is real.
        guard let url = Bundle.module.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { throw Failure.readabilityUnavailable }
        return source
    }

    /// Readability mutates the document it is handed, so it gets a clone — which
    /// also leaves the page's own links intact for finding the next page.
    ///
    /// Only same-site links containing a digit are collected: a page marker is
    /// always a number, and a long article can carry hundreds of other links.
    static let extractionScript = """
    (function () {
      try {
        if (typeof Readability === "undefined") {
          return JSON.stringify({ ok: false, reason: "Readability did not load" });
        }

        var bareHost = function (host) { return host.replace(/^www\\./i, "").toLowerCase(); };
        var here = bareHost(location.hostname);

        var relNext = [];
        document.querySelectorAll('link[rel~="next" i], a[rel~="next" i]').forEach(function (element) {
          if (element.href) relNext.push(element.href);
        });

        var anchors = [], seen = {};
        var links = document.querySelectorAll("a[href]");
        for (var i = 0; i < links.length && anchors.length < 600; i++) {
          var href = links[i].href;
          if (!href || seen[href] || !/[0-9]/.test(href)) continue;
          if (bareHost(links[i].hostname || "") !== here) continue;
          seen[href] = true;
          anchors.push(href);
        }

        var article = new Readability(document.cloneNode(true)).parse();
        if (!article) return JSON.stringify({ ok: false, reason: "no article" });
        return JSON.stringify({
          ok: true,
          title: article.title || "",
          byline: article.byline || "",
          siteName: article.siteName || "",
          excerpt: article.excerpt || "",
          content: article.content || "",
          publishedTime: article.publishedTime || "",
          url: location.href,
          relNext: relNext,
          anchors: anchors
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error) });
      }
    })()
    """

    /// Maps Readability's output onto a `ParsedArticle`.
    nonisolated static func article(fromReadabilityJSON data: Data, requestedURL: URL) throws -> ParsedArticle {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableResult("malformed JSON")
        }
        guard object["ok"] as? Bool == true else {
            let reason = (object["reason"] as? String) ?? "unknown"
            throw reason == "no article" ? Failure.noArticleFound : Failure.unreadableResult(reason)
        }

        let html = (object["content"] as? String) ?? ""
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noArticleFound
        }

        let siteName = nonEmpty(object["siteName"])
        let resolvedURL = nonEmpty(object["url"]) ?? requestedURL.absoluteString
        let rawTitle = nonEmpty(object["title"])
        let title = rawTitle.map {
            ArticleTitle.clean(
                rawTitle: $0, html: html, siteName: siteName,
                url: resolvedURL, author: nonEmpty(object["byline"])
            )
        }

        return ParsedArticle(
            url: resolvedURL,
            title: (title?.isEmpty == false ? title! : requestedURL.host) ?? "Untitled",
            siteName: siteName,
            author: nonEmpty(object["byline"]),
            description: nonEmpty(object["excerpt"]),
            html: html,
            publishedDate: nonEmpty(object["publishedTime"]).flatMap(Self.parseDate)
        )
    }

    /// Links that might lead to the next page, `rel="next"` first. Whether any
    /// of them actually is the next page is `Pagination`'s decision.
    nonisolated static func nextPageCandidates(fromReadabilityJSON data: Data) -> [URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var seen = Set<String>()
        var urls: [URL] = []
        for key in ["relNext", "anchors"] {
            for text in object[key] as? [String] ?? [] {
                guard let url = URL(string: text), url.scheme != nil, seen.insert(url.absoluteString).inserted else {
                    continue
                }
                urls.append(url)
            }
        }
        return urls
    }

    nonisolated private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Readability passes `publishedTime` through from the page's own metadata,
    /// so the format is whatever the publisher used.
    nonisolated static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }

        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }

        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd"
        return plain.date(from: value)
    }
}

extension LocalArticleParser: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            lastStatusCode = http.statusCode
        }
        return .allow
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoad()
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(with: Failure.navigationFailed(error.localizedDescription))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failLoad(with: Failure.navigationFailed(error.localizedDescription))
    }
}
