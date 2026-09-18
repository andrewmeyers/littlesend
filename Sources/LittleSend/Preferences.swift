import Foundation
import Combine
import LittleSendCore

/// Settings storage, backed entirely by UserDefaults.
///
/// The SMTP password is stored alongside everything else, in plain
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
    @Published private(set) var smtpPassword: String
    @Published private(set) var sendToKindle: Bool
    @Published private(set) var sendToEmail: Bool
    @Published private(set) var saveToDesktop: Bool
    @Published private(set) var desktopFormat: DesktopFormat
    @Published private(set) var emailAddresses: [String]
    @Published private(set) var emailRecipientExclusions: Set<String>
    @Published private(set) var attachBookToEmail: Bool
    @Published private(set) var embedImagesInEmail: Bool
    @Published private(set) var coverFontFamily: String
    @Published private(set) var coverLayout: CoverLayout
    @Published private(set) var coverSize: CoverSize
    @Published private(set) var optimizeCoverForEInk: Bool
    @Published private(set) var playSounds: Bool
    @Published private(set) var browserSource: BrowserSource
    @Published private(set) var iconPlacement: IconPlacement

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
        static let desktopFormat = "desktopFormat"
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
        static let playSounds = "playSounds"
        static let browserSource = "browserSource"
        static let iconPlacement = "iconPlacement"
        static let smtpPassword = "smtpPassword"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Empty until set, so nothing personal ships in the app. The Gmail server
        // and port are the one prefill — they are the same for every Gmail user.
        kindleAddress = defaults.string(forKey: Keys.kindleAddress) ?? ""
        fromAddress = defaults.string(forKey: Keys.fromAddress) ?? ""
        smtpHost = defaults.string(forKey: Keys.smtpHost) ?? "smtp.gmail.com"
        smtpPort = defaults.object(forKey: Keys.smtpPort) as? Int ?? 465
        smtpUsername = defaults.string(forKey: Keys.smtpUsername) ?? ""
        embedImages = defaults.object(forKey: Keys.embedImages) as? Bool ?? true
        limitImageSize = defaults.object(forKey: Keys.limitImageSize) as? Bool ?? true
        maxImageKilobytes = defaults.object(forKey: Keys.maxImageKilobytes) as? Int ?? 600
        sendToKindle = defaults.object(forKey: Keys.sendToKindle) as? Bool ?? true
        sendToEmail = defaults.object(forKey: Keys.sendToEmail) as? Bool ?? true
        // Off by default: writing files to someone's Desktop uninvited is the
        // kind of thing that should be asked for, not assumed.
        saveToDesktop = defaults.object(forKey: Keys.saveToDesktop) as? Bool ?? false
        // EPUB by default, which is what the Desktop destination always wrote.
        desktopFormat = defaults.string(forKey: Keys.desktopFormat)
            .flatMap(DesktopFormat.init(rawValue:)) ?? .epub

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
        playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
        // Off unless asked for: switching it on is what triggers the macOS
        // Automation prompt, and that should follow a deliberate choice.
        browserSource = defaults.string(forKey: Keys.browserSource)
            .flatMap(BrowserSource.init(rawValue:)) ?? .off
        iconPlacement = defaults.string(forKey: Keys.iconPlacement)
            .flatMap(IconPlacement.init(rawValue:)) ?? .both

        var password = defaults.string(forKey: Keys.smtpPassword) ?? ""

        // Earlier versions kept secrets in the Keychain. Drain it every launch,
        // which also clears the retired Instaparser key if it is still there,
        // and carry the password across if it has not been already.
        let legacy = LegacyKeychain.drain()
        if password.isEmpty, let value = legacy[.smtpPassword] {
            password = value
            defaults.set(value, forKey: Keys.smtpPassword)
        }
        smtpPassword = password

        // Instaparser is gone. Its API key was stored in plain text, so it is
        // deleted outright rather than left sitting in the preferences file.
        defaults.removeObject(forKey: "instaparserAPIKey")

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
            embedImages: embedImages,
            limitImageSize: limitImageSize,
            maxImageKilobytes: maxImageKilobytes,
            sendToKindle: sendToKindle,
            sendToEmail: sendToEmail,
            saveToDesktop: saveToDesktop,
            desktopFormat: desktopFormat,
            emailAddresses: emailAddresses,
            emailRecipientExclusions: emailRecipientExclusions,
            attachBookToEmail: attachBookToEmail,
            embedImagesInEmail: embedImagesInEmail,
            coverFontFamily: coverFontFamily,
            coverLayout: coverLayout,
            coverSize: coverSize,
            optimizeCoverForEInk: optimizeCoverForEInk,
            playSounds: playSounds,
            browserSource: browserSource,
            iconPlacement: iconPlacement
        )
    }

    /// Assigns only when the value actually changed.
    ///
    /// Every `@Published` write fires `objectWillChange`, and `apply` touches
    /// 22 of them. Writing them all unconditionally meant one checkbox in the
    /// recipient menu published 22 changes and rebuilt the popover body — and
    /// the `ForEach` behind the open menu — over and over while the menu was
    /// still up, which is how its checkmarks ended up out of step with the
    /// state they were bound to.
    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>, _ value: T) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }

    /// Commits a draft.
    func apply(_ incoming: SettingsDraft) {
        let draft = incoming.normalized

        set(\.kindleAddress, draft.kindleAddress)
        set(\.fromAddress, draft.fromAddress)
        set(\.smtpHost, draft.smtpHost)
        set(\.smtpPort, draft.smtpPort)
        set(\.smtpUsername, draft.smtpUsername)
        set(\.embedImages, draft.embedImages)
        set(\.limitImageSize, draft.limitImageSize)
        set(\.maxImageKilobytes, draft.maxImageKilobytes)
        set(\.sendToKindle, draft.sendToKindle)
        set(\.sendToEmail, draft.sendToEmail)
        set(\.saveToDesktop, draft.saveToDesktop)
        set(\.desktopFormat, draft.desktopFormat)
        set(\.emailAddresses, draft.emailAddresses)
        set(\.emailRecipientExclusions, draft.emailRecipientExclusions)
        set(\.attachBookToEmail, draft.attachBookToEmail)
        set(\.embedImagesInEmail, draft.embedImagesInEmail)
        set(\.coverFontFamily, draft.coverFontFamily)
        set(\.coverLayout, draft.coverLayout)
        set(\.coverSize, draft.coverSize)
        set(\.optimizeCoverForEInk, draft.optimizeCoverForEInk)
        set(\.playSounds, draft.playSounds)
        set(\.browserSource, draft.browserSource)
        set(\.iconPlacement, draft.iconPlacement)
        set(\.smtpPassword, draft.smtpPassword)

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
        defaults.set(draft.desktopFormat.rawValue, forKey: Keys.desktopFormat)
        defaults.set(Array(draft.emailRecipientExclusions), forKey: Keys.emailRecipientExclusions)
        defaults.set(draft.emailAddresses, forKey: Keys.emailAddresses)
        defaults.set(draft.attachBookToEmail, forKey: Keys.attachBookToEmail)
        defaults.set(draft.embedImagesInEmail, forKey: Keys.embedImagesInEmail)
        defaults.set(draft.coverFontFamily, forKey: Keys.coverFontFamily)
        defaults.set(draft.coverLayout.rawValue, forKey: Keys.coverLayout)
        defaults.set(draft.coverSize.rawValue, forKey: Keys.coverSize)
        defaults.set(draft.optimizeCoverForEInk, forKey: Keys.optimizeCoverForEInk)
        defaults.set(draft.playSounds, forKey: Keys.playSounds)
        defaults.set(draft.browserSource.rawValue, forKey: Keys.browserSource)
        defaults.set(draft.iconPlacement.rawValue, forKey: Keys.iconPlacement)
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
