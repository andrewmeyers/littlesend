import Foundation

/// Carries settings across a change of bundle identifier.
///
/// macOS keeps an app's preferences under its bundle ID, so renaming
/// `com.kindleclip.KindleClip` to `com.andrewmeyers.LittleSend` would start
/// everyone over with empty settings. On first launch under the new ID, every
/// value from the old domain is copied in — the Kindle address, mail login,
/// Instaparser key, window positions, all of it. The old domain is left in
/// place, so running an older build still finds its settings.
public enum SettingsMigration {
    public static let previousDomain = "com.kindleclip.KindleClip"
    /// Set once the copy has been tried, so it never runs again — not even to
    /// put back a value the user has since cleared.
    static let doneKey = "migratedSettingsFrom"

    /// - Parameters:
    ///   - defaults: where settings live now.
    ///   - source: reads another app's preferences domain; `UserDefaults
    ///     .standard` can, outside the sandbox.
    public static func run(
        into defaults: UserDefaults,
        from domain: String = previousDomain,
        source: UserDefaults = .standard
    ) {
        guard defaults.string(forKey: doneKey) == nil else { return }
        defer { defaults.set(domain, forKey: doneKey) }

        guard let old = source.persistentDomain(forName: domain), !old.isEmpty else { return }
        // Anything already set under the new ID wins.
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
