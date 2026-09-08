import Foundation
import WebKit

/// Extracts an article by loading the page in a real WebKit view and running
/// Mozilla's Readability against the live DOM.
///
/// This exists as a manual fallback for pages the hosted parser cannot reach.
/// The advantage is not cleverness but identity: many sites refuse plain HTTP
/// clients outright — a `curl` of gatesnotes.com returns 403 with no article
/// markup at all — while serving the same URL happily to a browser. Running
/// inside WebKit means being a browser, which also means client-rendered pages
/// have executed their JavaScript by the time the DOM is read.
///
/// It is deliberately not automatic: it is far slower than an API call and
/// spins up a web view, so it runs only when asked for after a failure.
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

    /// How long to wait for the page to finish loading.
    private let timeout: TimeInterval
    /// Grace period after `didFinish` for client-rendered content to appear.
    private let settleDelay: TimeInterval

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    public init(timeout: TimeInterval = 30, settleDelay: TimeInterval = 2.5) {
        self.timeout = timeout
        self.settleDelay = settleDelay
        super.init()
    }

    public func parse(url: URL) async throws -> ParsedArticle {
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

        try await load(url: url, in: webView)

        // Let client-rendered pages populate before reading the DOM.
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))

        _ = try? await webView.evaluateJavaScript(script)
        let raw = try await webView.evaluateJavaScript(Self.extractionScript)

        guard let json = raw as? String, let data = json.data(using: .utf8) else {
            throw Failure.unreadableResult("not a string")
        }
        return try Self.article(fromReadabilityJSON: data, requestedURL: url)
    }

    // MARK: - Loading

    private func load(url: URL, in webView: WKWebView) async throws {
        let timeoutTask = Task { [timeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.failLoad(with: Failure.timedOut)
        }
        defer { timeoutTask.cancel() }

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

    /// The vendored copy of Mozilla's Readability, bundled as a resource so the
    /// fallback needs no network of its own and cannot drift underneath us.
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

    /// Readability mutates the document it is handed, so it gets a clone.
    static let extractionScript = """
    (function () {
      try {
        if (typeof Readability === "undefined") {
          return JSON.stringify({ ok: false, reason: "Readability did not load" });
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
          url: location.href
        });
      } catch (error) {
        return JSON.stringify({ ok: false, reason: String(error) });
      }
    })()
    """

    /// Maps Readability's output onto the same `ParsedArticle` the hosted
    /// parser produces, so everything downstream is identical either way.
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
