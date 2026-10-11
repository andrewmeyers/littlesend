import Foundation

/// The email providers setup knows how to configure.
///
/// LittleSend's mail connection starts encrypted from the first byte
/// (implicit TLS, port 465). It does not do STARTTLS, which is the only way in
/// to iCloud Mail and Outlook.com (both port 587), so those two are listed to
/// say so plainly and point to a way around, rather than left to fail with a
/// vague connection error. Server details are from each provider's own help
/// pages, checked October 2026.
public enum MailProvider: String, CaseIterable, Identifiable, Sendable {
    case gmail, yahoo, fastmail, icloud, outlook, other

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .yahoo: return "Yahoo Mail"
        case .fastmail: return "Fastmail"
        case .icloud: return "iCloud Mail"
        case .outlook: return "Outlook.com"
        case .other: return "Another provider"
        }
    }

    public var server: String? {
        switch self {
        case .gmail: return "smtp.gmail.com"
        case .yahoo: return "smtp.mail.yahoo.com"
        case .fastmail: return "smtp.fastmail.com"
        case .icloud: return "smtp.mail.me.com"
        case .outlook: return "smtp-mail.outlook.com"
        case .other: return nil
        }
    }

    /// The port each provider documents; 587 for the two LittleSend can't use.
    public var port: UInt16 {
        switch self {
        case .icloud, .outlook: return 587
        default: return 465
        }
    }

    /// Whether LittleSend can send through it. "Another provider" is assumed
    /// to work; a wrong guess shows up as an error on the first send.
    public var isSupported: Bool {
        self != .icloud && self != .outlook
    }

    /// What to know about the password, in a sentence or two.
    public var passwordNote: String {
        switch self {
        case .gmail:
            return "Gmail needs an app password, not your usual one. Turn on 2-Step Verification, then make an app password and paste it here."
        case .yahoo:
            return "Yahoo needs an app password, not your usual one. Make one under External connections in your Yahoo Account Security page."
        case .fastmail:
            return "Fastmail needs an app password, not your usual one. In Settings, open Privacy & Security, then Manage app passwords and access."
        case .other:
            return "Many providers need an app password, not your usual one. Check your provider's help pages. Use a port that starts encrypted right away, usually 465."
        case .icloud, .outlook:
            return ""
        }
    }

    public var passwordGuideTitle: String? {
        switch self {
        case .gmail: return "Make a Gmail app password"
        case .yahoo: return "How to make a Yahoo app password"
        case .fastmail: return "How to make a Fastmail app password"
        default: return nil
        }
    }

    public var passwordGuide: URL? {
        switch self {
        case .gmail: return URL(string: "https://myaccount.google.com/apppasswords")
        case .yahoo: return URL(string: "https://help.yahoo.com/kb/SLN15241.html")
        case .fastmail: return URL(string: "https://www.fastmail.help/hc/en-us/articles/360058752854-App-passwords")
        default: return nil
        }
    }

    /// Shown instead of the sign-in fields for the providers that can't work.
    public var unsupportedNote: String {
        "\(displayName) only offers a kind of connection LittleSend can't use yet. "
            + "Easy fix: make a free Gmail account just for sending. "
            + "It only mails your articles, and you can keep using \(displayName) for everything else."
    }

    public static let freeGmailSignup = URL(string: "https://accounts.google.com/signup")!

    /// The provider a saved server belongs to. A new install has Gmail's
    /// server filled in, so an empty one counts as Gmail too.
    public static func detect(host: String) -> MailProvider {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty { return .gmail }
        return allCases.first { $0.server == host } ?? .other
    }
}
