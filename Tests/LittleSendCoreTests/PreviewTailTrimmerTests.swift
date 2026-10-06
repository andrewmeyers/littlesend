import XCTest
import WebKit
@testable import LittleSendCore

/// Runs the reader's preview trimmer in a real WebKit view, offline, on tails
/// modelled on what WSJ and The Verge actually return.
@MainActor
final class PreviewTailTrimmerTests: XCTestCase, WKNavigationDelegate {
    private var webView: WKWebView!
    private var loaded: CheckedContinuation<Void, Never>?

    override func setUp() async throws {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString("<html><body></body></html>", baseURL: nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded?.resume()
            self.loaded = nil
        }
    }

    private func trim(_ html: String) async throws -> String {
        let result = try await webView.callAsyncJavaScript(
            LocalArticleParser.previewTailTrimmer + "\nreturn trimPreviewTail(html);",
            arguments: ["html": html], in: nil, contentWorld: .page
        )
        return try XCTUnwrap(result as? String)
    }

    private let lastParagraph = "<p>Chapek lays it all out in his memoir, which Gallery Books will publish next week, charting his nearly 30 years at Disney.</p>"

    func testWSJStyleSubscribePitchIsRemoved() async throws {
        let html = """
        <div><section><p>Bob Chapek says he never had a chance, and he has a long story to tell about why.</p>\(lastParagraph)</section>
        <p>Copyright ©2026 Dow Jones &amp; Company, Inc. All Rights Reserved. 87990cbe</p>
        <div id="overlay"><p><img src="logo.svg" alt=""></p><p>Continue reading your article with<br>a WSJ subscription</p>
        <p><a href="https://subscribe.example.com">Subscribe Now</a></p></div><div><p><h2>Videos</h2></p></div></div>
        """
        let trimmed = try await trim(html)

        XCTAssertTrue(trimmed.contains("Gallery Books"), "the last real paragraph stays")
        XCTAssertTrue(trimmed.contains("never had a chance"))
        for pitch in ["Copyright", "Continue reading", "Subscribe Now", "Videos", "logo.svg", "overlay"] {
            XCTAssertFalse(trimmed.contains(pitch), "\(pitch) should be gone")
        }
    }

    func testVergeStyleNewsletterFormIsRemoved() async throws {
        let html = """
        <div><div>\(lastParagraph)</div><div><form><div><h2>The Verge Daily</h2>
        <p><span>A free daily digest of the news that matters most.</span></p></div></form></div></div>
        """
        let trimmed = try await trim(html)

        XCTAssertTrue(trimmed.contains("Gallery Books"))
        XCTAssertFalse(trimmed.contains("The Verge Daily"))
        XCTAssertFalse(trimmed.contains("<form"))
    }

    /// A real closing paragraph that happens to mention subscribers is long,
    /// so it is not mistaken for the paywall's pitch.
    func testALongClosingParagraphMentioningSubscribersStays() async throws {
        let closing = "<p>Disney said the change would reach subscribers of its streaming service over the coming months, starting with customers in the United States and Canada before it rolls out more widely next year.</p>"
        let trimmed = try await trim("<div>\(lastParagraph)\(closing)</div>")
        XCTAssertTrue(trimmed.contains("streaming service"))
        XCTAssertTrue(trimmed.contains("Gallery Books"))
    }
}
