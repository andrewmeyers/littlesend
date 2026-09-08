import Foundation
import Combine
import LittleSendCore

/// Settings storage, backed entirely by UserDefaults.
///
/// The API key and SMTP password are stored alongside everything else, in plain
/// text in the app's preferences plist. That file is readable by any process
/// running as this user and is included in backups; it is not protected the way
/// the Keychain would be.
///
/// Writes happen only through `apply(_:)`, so a half-typed value never becomes
/// the live configuration.
@MainActor
final class Preferences: ObservableObject {
    @Published private(set) var kindleAddress: String
    @Published private(set) var fromAddress: String
    @Published private(set) var smtpHost: String
    @Published private(set) var smtpPort: Int
    @Published private(set) var smtpUsername: String
    @Published private(set) var embedImages: Bool
    @Published private(set) var limitImageSize: Bool
    @Published private(set) var maxImageKilobytes: Int
    @Published private(set) var instaparserAPIKey: String
    @Published private(set) var smtpPassword: String
    @Published private(set) var sendToKindle: Bool
    @Published private(set) var sendToEmail: Bool
    @Published private(set) var saveToDesktop: Bool
    @Published private(set) var emailAddresses: [String]
    @Published private(set) var emailRecipientExclusions: Set<String>
    @Published private(set) var attachBookToEmail: Bool
    @Published private(set) var embedImagesInEmail: Bool
    @Published private(set) var coverFontFamily: String
    @Published private(set) var coverLayout: CoverLayout
    @Published private(set) var coverSize: CoverSize
    @Published private(set) var optimizeCoverForEInk: Bool

    private let defaults: UserDefaults

    private enum Keys {
        static let kindleAddress = "kindleAddress"
        static let fromAddress = "fromAddress"
        static let smtpHost = "smtpHost"
        static let smtpPort = "smtpPort"
        static let smtpUsername = "smtpUsername"
        static let embedImages = "embedImages"
        static let limitImageSize = "limitImageSize"
        static let maxImageKilobytes = "maxImageKilobytes"
        static let sendToKindle = "sendToKindle"
        static let sendToEmail = "sendToEmail"
        static let saveToDesktop = "saveToDesktop"
        static let emailAddresses = "emailAddresses"
        /// Retired free-text field, read once for migration only.
        static let legacyEmailRecipientsText = "emailRecipients"
        static let emailRecipientExclusions = "emailRecipientExclusions"
        static let attachBookToEmail = "attachBookToEmail"
        static let embedImagesInEmail = "embedImagesInEmail"
        static let coverFontFamily = "coverFontFamily"
        /// One-shot marker for the change of default cover font.
        static let coverFontDefaultMigrated = "coverFontDefaultMigrated"
        static let coverLayout = "coverLayout"
        static let coverSize = "coverSize"
        static let optimizeCoverForEInk = "optimizeCoverForEInk"
        static let instaparserAPIKey = "instaparserAPIKey"
        static let smtpPassword = "smtpPassword"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Prefilled with sensible starting values; all of it is editable.
        kindleAddress = defaults.string(forKey: Keys.kindleAddress) ?? "andrew.meyers_sig@kindle.com"
        fromAddress = defaults.string(forKey: Keys.fromAddress) ?? "andrew.meyers@gmail.com"
        smtpHost = defaults.string(forKey: Keys.smtpHost) ?? "smtp.gmail.com"
        smtpPort = defaults.object(forKey: Keys.smtpPort) as? Int ?? 465
        smtpUsername = defaults.string(forKey: Keys.smtpUsername) ?? "andrew.meyers@gmail.com"
        embedImages = defaults.object(forKey: Keys.embedImages) as? Bool ?? true
        limitImageSize = defaults.object(forKey: Keys.limitImageSize) as? Bool ?? true
        maxImageKilobytes = defaults.object(forKey: Keys.maxImageKilobytes) as? Int ?? 600
        sendToKindle = defaults.object(forKey: Keys.sendToKindle) as? Bool ?? true
        sendToEmail = defaults.object(forKey: Keys.sendToEmail) as? Bool ?? true
        // Off by default: writing files to someone's Desktop uninvited is the
        // kind of thing that should be asked for, not assumed.
        saveToDesktop = defaults.object(forKey: Keys.saveToDesktop) as? Bool ?? false

        if let stored = defaults.array(forKey: Keys.emailAddresses) as? [String] {
            emailAddresses = stored
        } else {
            // One-time migration from the old comma/newline-separated field.
            // Written back immediately, not just held in memory, so quitting
            // without opening Settings doesn't lose it on the next launch.
            let legacyText = defaults.string(forKey: Keys.legacyEmailRecipientsText) ?? ""
            let migrated = SettingsDraft.parseRecipients(legacyText)
            emailAddresses = migrated
            defaults.set(migrated, forKey: Keys.emailAddresses)
        }
        emailRecipientExclusions = Set(defaults.array(forKey: Keys.emailRecipientExclusions) as? [String] ?? [])
        attachBookToEmail = defaults.object(forKey: Keys.attachBookToEmail) as? Bool ?? false
        embedImagesInEmail = defaults.object(forKey: Keys.embedImagesInEmail) as? Bool ?? true
        // Empty means the built-in default family. A family that has since
        // been uninstalled is caught at render time, not here, so removing a
        // font cannot stop the app from launching.
        coverFontFamily = defaults.string(forKey: Keys.coverFontFamily) ?? ""
        coverLayout = defaults.string(forKey: Keys.coverLayout)
            .flatMap(CoverLayout.init(rawValue:)) ?? .classic
        coverSize = defaults.string(forKey: Keys.coverSize)
            .flatMap(CoverSize.init(rawValue:)) ?? .standard
        optimizeCoverForEInk = defaults.object(forKey: Keys.optimizeCoverForEInk) as? Bool ?? true

        var apiKey = defaults.string(forKey: Keys.instaparserAPIKey) ?? ""
        var password = defaults.string(forKey: Keys.smtpPassword) ?? ""

        // Earlier versions kept these in the Keychain. Move anything still
        // there across once and clear it, so an upgrade loses nothing and
        // nothing is left behind.
        if apiKey.isEmpty || password.isEmpty {
            let migrated = LegacyKeychain.drain()
            if apiKey.isEmpty, let value = migrated[.instaparserAPIKey] {
                apiKey = value
                defaults.set(value, forKey: Keys.instaparserAPIKey)
            }
            if password.isEmpty, let value = migrated[.smtpPassword] {
                password = value
                defaults.set(value, forKey: Keys.smtpPassword)
            }
        }

        instaparserAPIKey = apiKey
        smtpPassword = password

        // The default cover font changed from Possibility to the system font.
        // An existing install stores "" for "whatever the default is", so
        // leaving it alone would silently repaint covers in a different
        // typeface. Pin it, once, to what it was actually rendering as.
        //
        // Written straight back to defaults rather than only held in memory:
        // quitting without ever opening Settings must not lose the decision and
        // re-run this on the next launch.
        if defaults.object(forKey: Keys.coverFontDefaultMigrated) == nil {
            let isExistingInstall = defaults.object(forKey: Keys.coverLayout) != nil
                || defaults.object(forKey: Keys.kindleAddress) != nil
            if isExistingInstall, coverFontFamily.isEmpty {
                coverFontFamily = "Possibility"
                defaults.set(coverFontFamily, forKey: Keys.coverFontFamily)
            }
            defaults.set(true, forKey: Keys.coverFontDefaultMigrated)
        }
    }

    /// The current values, as an editable draft.
    var draft: SettingsDraft {
        SettingsDraft(
            kindleAddress: kindleAddress,
            fromAddress: fromAddress,
            smtpHost: smtpHost,
            smtpPort: smtpPort,
            smtpUsername: smtpUsername,
            smtpPassword: smtpPassword,
            instaparserAPIKey: instaparserAPIKey,
            embedImages: embedImages,
            limitImageSize: limitImageSize,
            maxImageKilobytes: maxImageKilobytes,
            sendToKindle: sendToKindle,
            sendToEmail: sendToEmail,
            saveToDesktop: saveToDesktop,
            emailAddresses: emailAddresses,
            emailRecipientExclusions: emailRecipientExclusions,
            attachBookToEmail: attachBookToEmail,
            embedImagesInEmail: embedImagesInEmail,
            coverFontFamily: coverFontFamily,
            coverLayout: coverLayout,
            coverSize: coverSize,
            optimizeCoverForEInk: optimizeCoverForEInk
        )
    }

    /// Commits a draft.
    func apply(_ incoming: SettingsDraft) {
        let draft = incoming.normalized

        kindleAddress = draft.kindleAddress
        fromAddress = draft.fromAddress
        smtpHost = draft.smtpHost
        smtpPort = draft.smtpPort
        smtpUsername = draft.smtpUsername
        embedImages = draft.embedImages
        limitImageSize = draft.limitImageSize
        maxImageKilobytes = draft.maxImageKilobytes
        sendToKindle = draft.sendToKindle
        sendToEmail = draft.sendToEmail
        saveToDesktop = draft.saveToDesktop
        emailAddresses = draft.emailAddresses
        emailRecipientExclusions = draft.emailRecipientExclusions
        attachBookToEmail = draft.attachBookToEmail
        embedImagesInEmail = draft.embedImagesInEmail
        coverFontFamily = draft.coverFontFamily
        coverLayout = draft.coverLayout
        coverSize = draft.coverSize
        optimizeCoverForEInk = draft.optimizeCoverForEInk
        instaparserAPIKey = draft.instaparserAPIKey
        smtpPassword = draft.smtpPassword

        defaults.set(draft.kindleAddress, forKey: Keys.kindleAddress)
        defaults.set(draft.fromAddress, forKey: Keys.fromAddress)
        defaults.set(draft.smtpHost, forKey: Keys.smtpHost)
        defaults.set(draft.smtpPort, forKey: Keys.smtpPort)
        defaults.set(draft.smtpUsername, forKey: Keys.smtpUsername)
        defaults.set(draft.embedImages, forKey: Keys.embedImages)
        defaults.set(draft.limitImageSize, forKey: Keys.limitImageSize)
        defaults.set(draft.maxImageKilobytes, forKey: Keys.maxImageKilobytes)
        defaults.set(draft.sendToKindle, forKey: Keys.sendToKindle)
        defaults.set(draft.sendToEmail, forKey: Keys.sendToEmail)
        defaults.set(draft.saveToDesktop, forKey: Keys.saveToDesktop)
        defaults.set(Array(draft.emailRecipientExclusions), forKey: Keys.emailRecipientExclusions)
        defaults.set(draft.emailAddresses, forKey: Keys.emailAddresses)
        defaults.set(draft.attachBookToEmail, forKey: Keys.attachBookToEmail)
        defaults.set(draft.embedImagesInEmail, forKey: Keys.embedImagesInEmail)
        defaults.set(draft.coverFontFamily, forKey: Keys.coverFontFamily)
        defaults.set(draft.coverLayout.rawValue, forKey: Keys.coverLayout)
        defaults.set(draft.coverSize.rawValue, forKey: Keys.coverSize)
        defaults.set(draft.optimizeCoverForEInk, forKey: Keys.optimizeCoverForEInk)
        defaults.set(draft.instaparserAPIKey, forKey: Keys.instaparserAPIKey)
        defaults.set(draft.smtpPassword, forKey: Keys.smtpPassword)
    }

    /// Edits one part of the settings and commits it immediately. Used by the
    /// destination toggles in the popover, which have no Save button of their own.
    func update(_ transform: (inout SettingsDraft) -> Void) {
        var edited = draft
        transform(&edited)
        apply(edited)
    }

    /// Convenience for the popover's recipient menu; stays reactive because
    /// `emailRecipientExclusions` is `@Published`.
    func isEmailRecipientSelected(_ address: String) -> Bool {
        !emailRecipientExclusions.contains(address.lowercased())
    }

    var configuration: SendConfiguration { draft.configuration }

    var isConfigured: Bool { draft.settingsProblems.isEmpty }
}
