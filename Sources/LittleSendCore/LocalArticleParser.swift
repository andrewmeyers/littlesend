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
        // The app's shared, persistent store: sign-ins made in the app's
        // "Sign In to Sites" window live here, so a subscriber's reads get the
        // full article. A non-persistent store would quietly lose them.
        configuration.websiteDataStore = .default()
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
            if page.article.isPreview { article.isPreview = true }
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
        // The async form, so the script can await the paywall check's fetch.
        let raw = try await webView.callAsyncJavaScript(
            Self.extractionScript, arguments: [:], in: nil, contentWorld: .page
        )

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
    ///
    /// A page that labels itself paywalled (schema.org `isAccessibleForFree`,
    /// which publishers set so search engines may index the full text) is
    /// checked for being a preview, two ways:
    /// - Held back on the server (WSJ): the page's stated word count, or its
    ///   gated section (`hasPart` + `cssSelector`), shows far more than arrived.
    /// - Trimmed in the browser (The Verge): the page as the server sent it is
    ///   fetched again and read too, purely to compare lengths.
    /// Only the visible article is ever returned — the point is to say "only a
    /// preview came through", not to get around the paywall. A signed-in
    /// subscriber gets the full article, so no warning.
    ///
    /// Run with `callAsyncJavaScript`, so it is a function body: it `return`s
    /// its result and may `await`.
    nonisolated static let extractionScript = previewTailTrimmer + """

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

        // What the page says about itself: whether it is paywalled, which
        // part is gated (Google's `hasPart` markup), and how long it really is.
        var markedPaywalled = false, gatedSelectors = [], declaredWords = 0;
        var isFalse = function (value) {
          return value === false || (typeof value === "string" && value.toLowerCase() === "false");
        };
        var visit = function (node) {
          if (!node || typeof node !== "object") return;
          if (Array.isArray(node)) { node.forEach(visit); return; }
          if (isFalse(node.isAccessibleForFree)) {
            markedPaywalled = true;
            if (typeof node.cssSelector === "string") gatedSelectors.push(node.cssSelector);
          }
          var count = parseInt(node.wordCount, 10);
          if (count > declaredWords) declaredWords = count;
          Object.keys(node).forEach(function (key) { visit(node[key]); });
        };
        document.querySelectorAll('script[type="application/ld+json"]').forEach(function (element) {
          try { visit(JSON.parse(element.textContent)); } catch (ignored) {}
        });
        var wordMeta = document.querySelector('meta[name="article:word_count"], meta[property="article:word_count"]');
        if (wordMeta) declaredWords = Math.max(declaredWords, parseInt(wordMeta.content, 10) || 0);

        var words = function (text) { return (text || "").split(/\\s+/).filter(Boolean).length; };
        var shown = words(article.textContent);
        // Clearly shorter, not just missing a caption or two.
        var muchShorter = function (whole) { return whole - shown > 150 && shown < whole * 0.7; };

        var preview = false;
        if (markedPaywalled) {
          if (declaredWords > 0) {
            // Held back on the server (the WSJ way): the page states its
            // length, and far less than that arrived.
            preview = muchShorter(declaredWords);
          } else if (gatedSelectors.length > 0) {
            // No stated length: the gated section is missing or near empty.
            var gatedWords = 0;
            gatedSelectors.forEach(function (selector) {
              try {
                document.querySelectorAll(selector).forEach(function (element) {
                  gatedWords += words(element.textContent);
                });
              } catch (ignored) {}
            });
            preview = gatedWords < 50;
          }

          if (!preview) {
            // Trimmed in the browser (the Verge way): the page as the server
            // sent it is longer than what is on screen.
            try {
              var response = await fetch(location.href, { credentials: "include" });
              if (response.ok) {
                var served = new DOMParser().parseFromString(await response.text(), "text/html");
                var full = new Readability(served).parse();
                preview = muchShorter(full ? words(full.textContent) : 0);
              }
            } catch (ignored) {}
          }
        }

        return JSON.stringify({
          ok: true,
          title: article.title || "",
          byline: article.byline || "",
          siteName: article.siteName || "",
          excerpt: article.excerpt || "",
          // A preview ends in the paywall's own pitch; that is not article.
          content: preview ? trimPreviewTail(article.content || "") : (article.content || ""),
          publishedTime: article.publishedTime || "",
          url: location.href,
          relNext: relNext,
          anchors: anchors,
          preview: preview
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error) });
      }
    """

    /// Drops the paywall's pitch from the end of a preview — "Continue reading
    /// with a subscription", "Subscribe Now", a newsletter form, a logo, a
    /// copyright line — walking back from the end until a real paragraph.
    ///
    /// Only ever run on a preview: a whole article's closing lines are left
    /// alone. A block counts as pitch if it is inside a form, is very short,
    /// or is short and talks about subscribing, signing in or copyright.
    nonisolated static let previewTailTrimmer = """
    function trimPreviewTail(html) {
      var holder = document.createElement("div");
      holder.innerHTML = html;
      var words = function (text) { return (text || "").split(/\\s+/).filter(Boolean).length; };
      var pitch = /subscri|sign (in|up)|log ?in|continue reading|keep reading|read the full|already an? (member|subscriber)|all rights reserved|copyright|newsletter|daily digest/i;
      var blocks = holder.querySelectorAll("p, h1, h2, h3, h4, h5, h6, li, blockquote, figure, form");
      for (var i = blocks.length - 1; i >= 0; i--) {
        var block = blocks[i];
        var text = block.textContent || "";
        var count = words(text);
        var isPitch = block.closest("form") !== null || count < 4 || (count < 25 && pitch.test(text));
        if (!isPitch) break;
        block.remove();
      }
      // Containers the removed blocks leave empty go too.
      var emptied = true;
      while (emptied) {
        emptied = false;
        holder.querySelectorAll("div, section, aside, article, form").forEach(function (element) {
          if (!element.textContent.trim() && !element.querySelector("img, picture, video, svg")) {
            element.remove();
            emptied = true;
          }
        });
      }
      return holder.innerHTML;
    }
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
            publishedDate: nonEmpty(object["publishedTime"]).flatMap(Self.parseDate),
            isPreview: (object["preview"] as? Bool) ?? false
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
