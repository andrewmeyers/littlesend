import Foundation

/// An editable copy of every setting. The Settings window mutates a draft and
/// commits it on Save, so a half-typed address never reaches the Keychain or
/// the send pipeline.
public struct SettingsDraft: Equatable, Sendable {
    public var kindleAddress: String
    public var fromAddress: String
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpUsername: String
    public var smtpPassword: String
    public var embedImages: Bool
    public var limitImageSize: Bool
    /// Target ceiling per embedded image, in kilobytes.
    public var maxImageKilobytes: Int
    /// Whether Kindle and Email are active for the *next* send. These are not
    /// configuration — they're intentionally editable only from the popover's
    /// destination controls, never from a Settings toggle, so Settings holds
    /// nothing but the address book: what a Kindle address is, what email
    /// addresses exist to choose from.
    public var sendToKindle: Bool
    public var sendToEmail: Bool
    public var saveToDesktop: Bool
    /// The format the Desktop copy is saved in, chosen from the Desktop chip.
    public var desktopFormat: DesktopFormat
    /// The address book: every email address that can be picked as a
    /// recipient. Order is preserved (first added, first shown).
    public var emailAddresses: [String]
    /// Lowercased addresses currently deselected. An address not in this set
    /// is selected — so a freshly added address is included by default.
    public var emailRecipientExclusions: Set<String>
    public var attachBookToEmail: Bool
    /// Embed shrunk copies of images in the email instead of linking to the
    /// originals. Guarantees they display, at the cost of message size.
    public var embedImagesInEmail: Bool
    /// Cover appearance. Only the cover is styled here: the book itself
    /// carries no fonts, so it inherits whatever the reader has set on their
    /// own device. Empty `coverFontFamily` means the built-in default.
    public var coverFontFamily: String
    public var coverLayout: CoverLayout
    public var coverSize: CoverSize
    public var optimizeCoverForEInk: Bool
    /// A sound when a send finishes.
    public var playSounds: Bool
    /// Where the URL field fills itself from when the panel opens.
    public var browserSource: BrowserSource
    /// Whether the app's icon appears in the Dock, the menu bar, or both.
    public var iconPlacement: IconPlacement
    /// Which reader turns a web page into an article.
    public var articleReader: ArticleReader
    public var instaparserAPIKey: String

    public init(
        kindleAddress: String = "",
        fromAddress: String = "",
        smtpHost: String = "",
        smtpPort: Int = 465,
        smtpUsername: String = "",
        smtpPassword: String = "",
        embedImages: Bool = true,
        limitImageSize: Bool = true,
        maxImageKilobytes: Int = 600,
        sendToKindle: Bool = true,
        sendToEmail: Bool = true,
        saveToDesktop: Bool = false,
        desktopFormat: DesktopFormat = .epub,
        emailAddresses: [String] = [],
        emailRecipientExclusions: Set<String> = [],
        attachBookToEmail: Bool = false,
        embedImagesInEmail: Bool = true,
        coverFontFamily: String = "",
        coverLayout: CoverLayout = .classic,
        coverSize: CoverSize = .standard,
        optimizeCoverForEInk: Bool = true,
        playSounds: Bool = true,
        browserSource: BrowserSource = .off,
        iconPlacement: IconPlacement = .both,
        articleReader: ArticleReader = .local,
        instaparserAPIKey: String = ""
    ) {
        self.kindleAddress = kindleAddress
        self.fromAddress = fromAddress
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.embedImages = embedImages
        self.limitImageSize = limitImageSize
        self.maxImageKilobytes = maxImageKilobytes
        self.sendToKindle = sendToKindle
        self.sendToEmail = sendToEmail
        self.saveToDesktop = saveToDesktop
        self.desktopFormat = desktopFormat
        self.emailAddresses = emailAddresses
        self.emailRecipientExclusions = emailRecipientExclusions
        self.attachBookToEmail = attachBookToEmail
        self.embedImagesInEmail = embedImagesInEmail
        self.coverFontFamily = coverFontFamily
        self.coverLayout = coverLayout
        self.coverSize = coverSize
        self.optimizeCoverForEInk = optimizeCoverForEInk
        self.playSounds = playSounds
        self.browserSource = browserSource
        self.iconPlacement = iconPlacement
        self.articleReader = articleReader
        self.instaparserAPIKey = instaparserAPIKey
    }

    public var coverStyle: CoverStyle {
        CoverStyle(
            fontFamily: Self.trim(coverFontFamily),
            layout: coverLayout,
            size: coverSize,
            optimizeForEInk: optimizeCoverForEInk
        )
    }

    /// The configured address book — every address available to pick from,
    /// regardless of whether it (or the destination) is currently selected.
    public var emailRecipients: [String] { emailAddresses }

    /// Whether the email destination can be switched on at all.
    public var canSendToEmail: Bool { !emailRecipients.isEmpty }

    /// The recipients that will actually receive this send — the configured
    /// list, minus anything deselected. Order matches the address book.
    public var selectedEmailRecipients: [String] {
        emailRecipients.filter { isRecipientSelected($0) }
    }

    public func isRecipientSelected(_ address: String) -> Bool {
        !emailRecipientExclusions.contains(address.lowercased())
    }

    public mutating func setRecipient(_ address: String, selected: Bool) {
        let key = address.lowercased()
        if selected {
            emailRecipientExclusions.remove(key)
        } else {
            emailRecipientExclusions.insert(key)
        }
    }

    /// Adds one or more addresses to the book. `text` is run through the same
    /// parser as the old free-text field, so pasting "a@x.com, b@x.com" (or a
    /// "Name <addr>" form copied from a mail client) still adds every address
    /// it finds — but the stored shape is always a plain list, never text.
    /// New addresses land selected; anything already present is left alone.
    public mutating func addEmailAddresses(from text: String) {
        let existingKeys = Set(emailAddresses.map { $0.lowercased() })
        for address in Self.parseRecipients(text) where !existingKeys.contains(address.lowercased()) {
            emailAddresses.append(address)
        }
    }

    /// Removes one address from the book, and drops any leftover selection
    /// state for it so a later re-add starts selected again.
    public mutating func removeEmailAddress(_ address: String) {
        let key = address.lowercased()
        emailAddresses.removeAll { $0.lowercased() == key }
        emailRecipientExclusions.remove(key)
    }

    /// Whether the Kindle destination can be switched on at all.
    public var canSendToKindle: Bool { SendConfiguration.looksLikeEmail(Self.trim(kindleAddress)) }

    /// Names of the destinations a send would actually reach right now —
    /// "Kindle", "Email", "Kindle and Email", or "" if nothing is active.
    /// Drives the "Send to" label so it reflects live selection rather than
    /// staying static; the caller decides how to phrase the empty case.
    public var activeDestinationNames: [String] {
        var names: [String] = []
        if sendToKindle { names.append("Kindle") }
        // Both must hold: the Email button on, and someone actually checked.
        // Recipients staying selected while the button is off must not count.
        if sendToEmail, !selectedEmailRecipients.isEmpty { names.append("Email") }
        if saveToDesktop { names.append("Desktop") }
        return names
    }

    public var activeDestinationsSummary: String {
        activeDestinationNames.joined(separator: " and ")
    }

    public static func parseRecipients(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t")) {
            let address = extractAddress(from: piece)
            guard !address.isEmpty else { continue }
            // Case-insensitive de-duplication, but keep what the user typed.
            guard seen.insert(address.lowercased()).inserted else { continue }
            result.append(address)
        }
        return result
    }

    /// Accepts a bare address or the "Name <addr@host>" form pasted from a
    /// mail client.
    static func extractAddress(from piece: String) -> String {
        let trimmed = trim(piece)
        guard let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close else {
            return trimmed
        }
        return trim(String(trimmed[trimmed.index(after: open)..<close]))
    }

    /// Cleaned-up copy — this is what actually gets stored and compared, so
    /// that trailing whitespace from a paste is never treated as a change.
    public var normalized: SettingsDraft {
        var copy = self
        copy.kindleAddress = Self.trim(kindleAddress)
        copy.fromAddress = Self.trim(fromAddress)
        copy.smtpHost = Self.trim(smtpHost)
        copy.smtpUsername = Self.trim(smtpUsername)
        copy.coverFontFamily = Self.trim(coverFontFamily)
        copy.smtpPassword = Self.normalizeAppPassword(smtpPassword)
        copy.instaparserAPIKey = Self.trim(instaparserAPIKey)

        // Trim and case-insensitively dedupe the address book, keeping the
        // first-seen spelling and order so formatting alone never registers
        // as an unsaved change.
        var seen = Set<String>()
        var addresses: [String] = []
        for address in emailAddresses {
            let trimmed = Self.trim(address)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            addresses.append(trimmed)
        }
        copy.emailAddresses = addresses
        copy.emailRecipientExclusions = emailRecipientExclusions.intersection(seen)
        return copy
    }

    /// Everything that must be filled in before a send can work, checked
    /// against the whole configuration rather than the current selection.
    ///
    /// Deliberately says nothing about *which* destination is switched on:
    /// that is chosen in the menu bar, not Settings, so nagging about it in a
    /// window that cannot change it would be unfixable noise. Neither a Kindle
    /// address nor any email address is required on its own — configure
    /// whichever you actually use. Every address in the book is checked, even
    /// deselected ones, since a typo there is worth catching wherever it sits.
    public var settingsProblems: [String] {
        let draft = normalized
        var problems: [String] = []

        if !draft.kindleAddress.isEmpty, !SendConfiguration.looksLikeEmail(draft.kindleAddress) {
            problems.append("Kindle address isn't valid.")
        }
        for address in draft.emailAddresses where !SendConfiguration.looksLikeEmail(address) {
            problems.append("“\(address)” isn't a valid email address.")
        }

        // Mail credentials only matter once a mail destination is configured.
        // Someone who only saves to the Desktop needs no SMTP at all.
        if !draft.kindleAddress.isEmpty || !draft.emailAddresses.isEmpty {
            if !SendConfiguration.looksLikeEmail(draft.fromAddress) {
                problems.append("Sender address is missing or not valid.")
            }
            if draft.smtpHost.isEmpty { problems.append("Mail server is missing.") }
            if draft.smtpUsername.isEmpty { problems.append("Mail username is missing.") }
            if draft.smtpPassword.isEmpty { problems.append("Mail password is missing.") }
        }

        // Sends still work without one — they fall back to the built-in
        // reader — but choosing Instaparser and then never reaching it is
        // worth pointing out.
        if draft.articleReader == .instaparser, draft.instaparserAPIKey.isEmpty {
            problems.append("Instaparser API key is missing.")
        }
        return problems
    }

    /// The gate for actually firing off a send — `settingsProblems` plus the
    /// requirement that some destination is currently selected.
    public var validationProblems: [String] {
        configuration.validationProblems
    }

    public var configuration: SendConfiguration {
        let draft = normalized
        return SendConfiguration(
            sendToKindle: draft.sendToKindle,
            kindleAddress: draft.kindleAddress,
            saveToDesktop: draft.saveToDesktop,
            desktopFormat: draft.desktopFormat,
            // Deselecting every recipient is what turns the destination off;
            // the pipeline needs no separate notion of an email on/off switch.
            // The master switch gates the whole destination; which of the
            // configured addresses actually receive it is a separate choice.
            emailRecipients: draft.sendToEmail ? draft.selectedEmailRecipients : [],
            attachBookToEmail: draft.attachBookToEmail,
            embedImagesInEmail: draft.embedImagesInEmail,
            fromAddress: draft.fromAddress,
            fromName: "LittleSend",
            smtpHost: draft.smtpHost,
            smtpPort: UInt16(clamping: draft.smtpPort),
            smtpUsername: draft.smtpUsername,
            smtpPassword: draft.smtpPassword,
            embedImages: draft.embedImages,
            imageSizeLimitBytes: draft.limitImageSize
                ? max(1, draft.maxImageKilobytes) * 1024
                : nil,
            coverStyle: draft.coverStyle,
            articleReader: draft.articleReader,
            instaparserAPIKey: draft.instaparserAPIKey
        )
    }

    static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Google shows app passwords as four spaced groups ("abcd efgh ijkl mnop")
    /// but the credential itself has no spaces, so a straight copy-paste fails
    /// to authenticate. Collapse that exact shape; leave every other password
    /// untouched, since a real one may legitimately contain spaces.
    public static func normalizeAppPassword(_ value: String) -> String {
        let trimmed = trim(value)
        let groups = trimmed.split(separator: " ", omittingEmptySubsequences: false)

        guard groups.count == 4,
              groups.allSatisfy({ group in
                  group.count == 4 && group.allSatisfy { $0.isLowercase && $0.isLetter }
              })
        else { return trimmed }

        return groups.joined()
    }
}
