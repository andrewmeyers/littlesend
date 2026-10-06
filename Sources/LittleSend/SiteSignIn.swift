import AppKit
import SwiftUI
import WebKit

/// A small browser for signing in to sites you subscribe to.
///
/// The built-in reader is a WebKit view with the app's default website data
/// store, and so is this — the two share cookies. Signing in here once means
/// later reads of that site see what a subscriber sees, instead of a paywall's
/// preview. Safari's own sign-ins live in Safari's store and cannot be shared
/// with another app, which is why this window has to exist at all.
@MainActor
final class SiteSignInWindow: NSObject, NSWindowDelegate {
    static let shared = SiteSignInWindow()

    private var window: NSWindow?

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Signs out of everything signed in to here — which, since the reader
    /// shares the store, also clears its cookies and cache. Nothing else is
    /// kept there.
    static func signOutOfAllSites() async {
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In to Sites"
        window.contentViewController = NSHostingController(rootView: SignInBrowserView())
        // The hosting controller shrinks the window to the view's minimum
        // size; a sign-in page needs room, so restore the intended size.
        window.setContentSize(NSSize(width: 1000, height: 760))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// A fresh browser next time, rather than one parked on a sign-in page.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

@MainActor
private final class SignInBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    @Published var address = ""
    @Published var canGoBack = false
    @Published var isLoading = false
    @Published var hasPage = false

    override init() {
        let configuration = WKWebViewConfiguration()
        // The store the reader uses. This line is the whole point.
        configuration.websiteDataStore = .default()
        // Some sign-in pages, Google's among them, refuse anything that does
        // not look like a full browser.
        configuration.applicationNameForUserAgent = Self.safariIdentity
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func go() {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        let withScheme = typed.contains("://") ? typed : "https://" + typed
        guard let url = URL(string: withScheme) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        webView.goBack()
    }

    /// "Version/26.0 Safari/605.1.15", matching the Safari on this Mac when
    /// there is one.
    private static var safariIdentity: String {
        let version = Bundle(path: "/Applications/Safari.app")?
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }

    private func refresh() {
        canGoBack = webView.canGoBack
        if let url = webView.url, url.scheme?.hasPrefix("http") == true {
            address = url.absoluteString
            hasPage = true
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    // MARK: - WKUIDelegate

    /// "Sign in with Google" and the like open a new window. There is only
    /// this one, so the sign-in page loads here instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        webView.load(navigationAction.request)
        return nil
    }
}

private struct SignInBrowserView: View {
    @StateObject private var browser = SignInBrowser()
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: browser.goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(!browser.canGoBack)
                .help("Back")

                TextField("Site address, like theverge.com", text: $browser.address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit(browser.go)

                if browser.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)

            Divider()

            ZStack {
                WebViewHost(webView: browser.webView)
                if !browser.hasPage {
                    hint
                }
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear { addressFocused = true }
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in to sites you pay for")
                .font(.title3.weight(.semibold))
            Text("Type a site's address above and sign in as usual. Then LittleSend gets the full article from that site.")
                .font(.appBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
