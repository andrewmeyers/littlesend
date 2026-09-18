import AppKit
import LittleSendCore

/// Reads the frontmost tab's address out of a browser.
///
/// Two rules shape this. Only *running* browsers are asked, because sending an
/// Apple Event to an app that is not running launches it — reaching for a URL
/// must never open Safari on someone. And the script runs off the main actor,
/// because a busy browser can take a moment to answer and the panel should not
/// freeze while it does.
enum BrowserURLReader {

    enum Outcome: Equatable {
        case found(URL)
        /// Nothing to report: no browser running, or no window open.
        case nothing
        /// macOS refused the Apple Event. Carries the browser's name so the
        /// message can say which permission to grant.
        case denied(String)
    }

    /// AppleScript's "not authorised to send Apple events" error.
    private static let notAuthorized = -1743

    static func currentURL(from source: BrowserSource) async -> Outcome {
        var denial: String?

        for browser in source.candidates {
            guard let script = browser.script, let name = browser.scriptingName else { continue }
            guard isRunning(browser) else { continue }

            let result = await run(script)
            switch result {
            case .text(let text):
                if let url = normalized(text) { return .found(url) }
            case .error(let code):
                // Remember a refusal but keep trying: another browser may be
                // permitted, and a denial is only worth reporting if nothing
                // worked at all.
                if code == notAuthorized { denial = denial ?? name }
            }
        }

        return denial.map(Outcome.denied) ?? .nothing
    }

    /// Running, not merely installed.
    private static func isRunning(_ browser: BrowserSource) -> Bool {
        guard let identifier = browser.bundleIdentifier else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty
    }

    private enum ScriptResult: Sendable {
        case text(String)
        case error(Int)
    }

    private static func run(_ script: String) async -> ScriptResult {
        await Task.detached(priority: .userInitiated) { () -> ScriptResult in
            var error: NSDictionary?
            // Built inside the task: NSAppleScript is not safe to share across
            // threads.
            guard let apple = NSAppleScript(source: script) else { return .error(0) }
            let output = apple.executeAndReturnError(&error)

            if let error {
                return .error(error[NSAppleScript.errorNumber] as? Int ?? 0)
            }
            return .text(output.stringValue ?? "")
        }.value
    }

    /// Browsers happily report "favorites://" or an empty new tab; only a real
    /// web address is worth putting in the field.
    private static func normalized(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.contains(".") == true
        else { return nil }
        return url
    }
}
