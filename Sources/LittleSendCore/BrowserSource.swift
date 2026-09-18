import Foundation

/// Where the URL field fills itself from when the panel opens.
///
/// Reading another app's tab means sending it an Apple Event, which macOS gates
/// behind Automation permission — the "LittleSend wants to control Safari"
/// prompt. That is why this is off by default and asks rather than assumes.
public enum BrowserSource: String, CaseIterable, Codable, Sendable {
    case off
    case automatic
    case safari
    case chrome
    case brave
    case edge
    case vivaldi

    public var displayName: String {
        switch self {
        case .off: return "Clipboard only"
        case .automatic: return "Whichever browser is open"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        }
    }

    /// The browsers a given setting will actually try, in order.
    public var candidates: [BrowserSource] {
        switch self {
        case .off: return []
        // Safari first, then the Chromium family. Only ones that are installed
        // are contacted, so this order costs nothing for browsers you lack.
        case .automatic: return [.safari, .chrome, .brave, .edge, .vivaldi]
        default: return [self]
        }
    }

    public var bundleIdentifier: String? {
        switch self {
        case .off, .automatic: return nil
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        }
    }

    /// The app's name as AppleScript knows it — this is what `tell application`
    /// resolves, and it is not always the bundle name.
    public var scriptingName: String? {
        switch self {
        case .off, .automatic: return nil
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave Browser"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        }
    }

    /// Safari addresses the front document; every Chromium browser addresses
    /// the active tab of the front window. Both forms were compiled against the
    /// real dictionaries for Safari and Chrome; the other three share Chrome's.
    public var script: String? {
        guard let name = scriptingName else { return nil }
        switch self {
        case .safari:
            return "tell application \"\(name)\" to return URL of front document"
        default:
            return "tell application \"\(name)\" to return URL of active tab of front window"
        }
    }
}
