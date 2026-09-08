import Foundation
import CoreText

/// Font selection for the cover image.
///
/// The cover is rasterized here, on this Mac, before anything is sent — the
/// title is drawn through CoreText and baked into pixels. That is why *any*
/// installed font is a legitimate choice here, unlike the EPUB stylesheet in
/// `EPUBTypography`, where a font has to exist on the reading device to have
/// any effect. Nothing is embedded and nothing is redistributed, so a font's
/// embedding permissions never enter into it.
public enum CoverFont {

    /// Shown in the picker for the empty preference.
    public static let systemFamilyLabel = "System (San Francisco)"
    /// Used when a *named* family turns out not to be installed.
    public static let fallbackFaceName = "Georgia-Bold"

    /// A face the cover can actually be drawn with.
    ///
    /// San Francisco needs its own case rather than a family name. The name
    /// that shows up in the font list — "SF Pro" — is Apple's separate
    /// developer download living in `/Library/Fonts`, so it is absent on a
    /// stock Mac. The real system font is `/System/Library/Fonts/SFNS.ttf`,
    /// which is always there but cannot be requested by name: asking CoreText
    /// for ".SFNS-Bold" silently returns Times New Roman, and CoreText logs a
    /// warning saying to use the UI-font API instead. So that is what this
    /// does.
    public enum Face: Equatable, Sendable {
        case systemUI
        case named(String)

        public func ctFont(size: CGFloat) -> CTFont {
            switch self {
            case .systemUI:
                let base = CTFontCreateUIFontForLanguage(.system, size, nil)
                    ?? CTFontCreateWithName(fallbackFaceName as CFString, size, nil)
                // The cover design leans on heavy type, and the UI font arrives
                // at regular weight.
                return CTFontCreateCopyWithSymbolicTraits(
                    base, size, nil, .traitBold, .traitBold
                ) ?? base
            case .named(let name):
                return CTFontCreateWithName(name as CFString, size, nil)
            }
        }
    }

    /// Every font family installed on this machine, alphabetically.
    ///
    /// Families rather than individual faces: a face list runs to thousands of
    /// entries, most of them weights nobody wants on a cover. The heaviest face
    /// in the chosen family is picked automatically instead.
    public static func availableFamilies() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        // Families beginning with "." are system-private and must not be shown.
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// PostScript name of the boldest face in `family`, or nil when the family
    /// is not installed.
    ///
    /// The cover design leans on heavy type, so a family resolves to its
    /// weightiest face rather than its regular one.
    public static func boldFaceName(inFamily family: String) -> String? {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: trimmed] as CFDictionary
        )
        let mandatory = Set([kCTFontFamilyNameAttribute]) as CFSet
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(
            descriptor, mandatory
        ) as? [CTFontDescriptor] ?? []

        // Ranked rather than simply "heaviest". Sorting on weight alone picks
        // condensed and italic cuts, because those carry the extreme weights in
        // large families — Helvetica Neue resolves to CondensedBlack that way,
        // which is not what "Helvetica Neue" means to someone choosing it.
        // Upright and normal-width win first; weight only breaks the tie.
        var best: (name: String, rank: (Int, Int, Float))?
        for candidate in matches {
            // CoreText matching is fuzzy, so confirm the family really matches
            // rather than trusting whatever it decided was close enough.
            let font = CTFontCreateWithFontDescriptor(candidate, 24, nil)
            guard (CTFontCopyFamilyName(font) as String) == trimmed else { continue }

            let traits = CTFontCopyTraits(font) as? [CFString: Any] ?? [:]
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.floatValue ?? 0
            let symbolic = CTFontGetSymbolicTraits(font)

            let upright = symbolic.contains(CTFontSymbolicTraits.traitItalic) ? 0 : 1
            let normalWidth = (symbolic.contains(CTFontSymbolicTraits.traitCondensed)
                || symbolic.contains(CTFontSymbolicTraits.traitExpanded)) ? 0 : 1

            let rank = (upright, normalWidth, weight)
            let name = CTFontCopyPostScriptName(font) as String
            if best == nil || rank > best!.rank {
                best = (name, rank)
            }
        }
        return best?.name
    }

    /// Resolves a stored preference to the face the cover will actually draw
    /// with. An empty preference means "use the default family"; an
    /// uninstalled family falls back rather than failing.
    ///
    /// Returns the face name and whether the request was honored, so the app
    /// can say plainly that it did not get the font that was asked for.
    public static func resolveFace(preferredFamily: String) -> (face: Face, usedFallback: Bool) {
        let requested = preferredFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty means the system font, which is part of the OS and so has no
        // failure case to fall back from.
        guard !requested.isEmpty else { return (.systemUI, false) }

        if let name = boldFaceName(inFamily: requested) {
            return (.named(name), false)
        }
        return (.named(fallbackFaceName), true)
    }

    /// Whether the family would render as asked, used to warn in Settings
    /// before a send rather than after one. The empty preference is the system
    /// font and is always available.
    public static func isAvailable(family: String) -> Bool {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || boldFaceName(inFamily: trimmed) != nil
    }
}
