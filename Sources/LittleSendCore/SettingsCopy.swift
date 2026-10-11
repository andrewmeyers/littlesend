import Foundation

/// The panes of the Settings window.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general, destinations, account, reading, cover, images

    public var id: Self { self }

    public var title: String {
        switch self {
        case .general: return "General"
        case .destinations: return "Destinations"
        case .account: return "Mail Account"
        case .reading: return "Reading"
        case .cover: return "Cover"
        case .images: return "Images"
        }
    }

    /// Every piece of text the pane shows — headings, row titles,
    /// descriptions, notes and the choices in its menus — so search finds a
    /// setting by anything written about it. Built from `SettingsCopy`, which
    /// the window draws its text from too, so the two cannot drift apart.
    public var searchableText: [String] {
        switch self {
        case .general: return SettingsCopy.General.all
        case .destinations: return SettingsCopy.Destinations.all
        case .account: return SettingsCopy.Account.all
        case .reading: return SettingsCopy.Reading.all
        case .cover: return SettingsCopy.Cover.all
        case .images: return SettingsCopy.Images.all
        }
    }

    /// Words people search for that the pane's own text does not use.
    var synonyms: [String] {
        switch self {
        case .general: return ["appearance", "chime", "beep", "startup", "first run", "onboarding", "welcome", "wizard", "walkthrough", "setup"]
        case .destinations: return ["recipients", "contacts", "inbox"]
        case .account: return ["smtp", "credentials", "login", "app password", "server", "tls", "ssl"]
        case .reading: return ["parser", "readability", "subscription", "login", "token", "speed", "fast"]
        case .cover: return ["typeface", "artwork", "grey", "eink", "resolution", "colour"]
        case .images: return ["pictures", "photos", "kilobytes", "compression", "resize"]
        }
    }

    /// Whether every word of `query` appears somewhere in the pane, ignoring
    /// case and accents. An empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = Self.haystacks[self] ?? ""
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Built once: the text cannot change while the app runs.
    private static let haystacks: [SettingsPane: String] = Dictionary(
        uniqueKeysWithValues: allCases.map { pane in
            (pane, fold(([pane.title] + pane.searchableText + pane.synonyms).joined(separator: " ")))
        }
    )

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// The text of the Settings window, kept in one place so search can index
/// exactly what the window shows. Written for a 9th-grade reading level.
public enum SettingsCopy {
    public enum General {
        public static let showIn = "Show LittleSend in"
        public static let showInNote = "Menu bar only keeps LittleSend out of the Dock and ⌘Tab, but its menus won't show."
        public static let fillLink = "Fill the link from"
        public static let fillLinkNote = "macOS asks once before LittleSend can read your browser. If no page is open, it uses the clipboard."
        public static let sounds = "Play sounds"
        public static let soundsNote = "A chime when a send works, and a low tone if it fails."
        public static let setupSection = "Setup"
        public static let runSetup = "Run setup again"
        public static let runSetupNote = "Go through the first-run steps again. Your details are already filled in."
        public static let runSetupButton = "Start…"

        static var all: [String] {
            [showIn, showInNote, fillLink, fillLinkNote, sounds, soundsNote,
             setupSection, runSetup, runSetupNote]
                + IconPlacement.allCases.map(\.displayName)
                + BrowserSource.allCases.map(\.displayName)
        }
    }

    public enum Destinations {
        public static let kindleSection = "Kindle"
        public static let kindleAddress = "Send to Kindle address"
        public static let kindleAddressNote = "Find it on Amazon under Manage Your Content and Devices → Preferences → Personal Document Settings."
        public static let addressesSection = "Email addresses"
        public static let addAddress = "Add address"
        public static let addressesNote = "Your address book. Pick who gets each send in the panel."
        public static let messagesSection = "Email messages"
        public static let showImages = "Show images in the email"
        public static let attachEPUB = "Also attach the EPUB"

        static var all: [String] {
            [kindleSection, kindleAddress, kindleAddressNote, addressesSection, addAddress,
             addressesNote, messagesSection, showImages, attachEPUB]
        }
    }

    public enum Account {
        public static let senderSection = "Sender"
        public static let fromAddress = "From address"
        public static let fromAddressNote = "Add this address to your Approved Personal Document E-mail List on Amazon. If you don't, Amazon drops your sends."
        public static let outgoingSection = "Outgoing mail"
        public static let server = "Mail server"
        public static let port = "Port"
        public static let username = "Username"
        public static let password = "Password"
        public static let outgoingNote = "For Gmail, turn on 2-Step Verification and use an app password. Use port 465. Port 587 doesn't work yet. The password is saved as plain text in LittleSend's settings, not in the Keychain."

        static var all: [String] {
            [senderSection, fromAddress, fromAddressNote, outgoingSection, server, port,
             username, password, outgoingNote]
                + MailProvider.allCases.map(\.displayName)
        }
    }

    public enum Reading {
        public static let readWith = "Read articles with"
        public static let localNote = "Reads articles on this Mac. It's free and private, and it reads every page of long articles."
        public static let instaparserNote = "Much faster, usually under a second. Instaparser sees each link you send. If it can't read one, LittleSend reads it on this Mac."
        public static let apiKey = "Instaparser API key"
        public static let apiKeyNote = "Saved as plain text in LittleSend's settings."
        public static let noKey = "No key yet?"
        public static let noKeyNote = "The free plan covers 1,000 articles a month."
        public static let getKey = "Get a free key"
        public static let paywallsSection = "Paywalls"
        public static let signIn = "Sign in to a site"
        public static let signInNote = "Pay for a site? Sign in once to get full articles. LittleSend can't use Safari's sign-ins."
        public static let signInButton = "Sign In…"
        public static let signOut = "Sign out of all sites"
        public static let signOutButton = "Sign Out"
        public static let signedOut = "Signed out of all sites."

        public static func note(for reader: ArticleReader) -> String {
            reader == .instaparser ? instaparserNote : localNote
        }

        static var all: [String] {
            [readWith, localNote, instaparserNote, apiKey, apiKeyNote, noKey, noKeyNote, getKey,
             paywallsSection, signIn, signInNote, signOut]
                + ArticleReader.allCases.map(\.displayName)
        }
    }

    public enum Cover {
        public static let layoutSection = "Layout"
        public static let typeSection = "Type"
        public static let font = "Cover font"
        public static let fontNote = "Any font on this Mac works. The article uses your Kindle's own fonts."
        public static let renderingSection = "Rendering"
        public static let size = "Size"
        public static let eInk = "Optimize Kindle covers for e-ink"
        public static let eInkNote = "Kindle covers use the 16 grays an e-ink screen can show. Desktop and email covers stay in color."

        static var all: [String] {
            [layoutSection, typeSection, font, fontNote, renderingSection, size, eInk, eInkNote,
             CoverFont.systemFamilyLabel]
                + CoverLayout.allCases.flatMap { [$0.displayName, $0.summary] }
                + CoverSize.allCases.flatMap { [$0.displayName, $0.summary] }
        }
    }

    public enum Images {
        public static let include = "Include images in the EPUB"
        public static let shrink = "Shrink large images"
        public static let shrinkNote = "Bigger images are shrunk to fit. Each one links to the full-size original."
        public static let maximumSize = "Maximum size"

        static var all: [String] {
            [include, shrink, shrinkNote, maximumSize, "KB"]
        }
    }
}
