import Foundation
import CoreGraphics

/// Arrangement of the elements on the cover.
public enum CoverLayout: String, CaseIterable, Codable, Sendable {
    /// Title anchored low and left, kicker at the top, rule above the byline.
    case classic
    /// The same furniture, centred on both axes.
    case centered
    /// Title reversed out of a solid band across the middle.
    case banded
    /// Title alone, centred. No kicker, rule, byline or date.
    case minimal

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .centered: return "Centered"
        case .banded: return "Banded"
        case .minimal: return "Minimal"
        }
    }

    public var summary: String {
        switch self {
        case .classic: return "Title low and left, source above it."
        case .centered: return "Everything centered."
        case .banded: return "Title in a color band."
        case .minimal: return "Just the title."
        }
    }
}

/// Pixel dimensions of the rendered cover.
///
/// Every case keeps Amazon's recommended 1.6:1 height-to-width ratio for cover
/// art, so the choice is sharpness against file size and never a change of
/// shape.
///
/// Worth knowing what this can and cannot do: nothing here detects your device,
/// because no such API exists — the file is mailed to Amazon, not handed to a
/// Kindle. And a cover is shown as a thumbnail in the library grid, so the size
/// mostly matters at the moment a book is opened. `standard` is already at or
/// above every current Kindle's panel, including the Scribe, which is why it
/// stays the default.
public enum CoverSize: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case large

    public var pixelSize: CGSize {
        switch self {
        case .compact: return CGSize(width: 1000, height: 1600)
        case .standard: return CGSize(width: 1600, height: 2560)
        case .large: return CGSize(width: 2000, height: 3200)
        }
    }

    public var displayName: String {
        let size = pixelSize
        return "\(displayLabel) (\(Int(size.width)) × \(Int(size.height)))"
    }

    private var displayLabel: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    public var summary: String {
        switch self {
        case .compact:
            return "About a third the file size. Fits the basic Kindle and Paperwhite."
        case .standard:
            return "Amazon's recommended size. Sharp on every Kindle, even the Scribe."
        case .large:
            return "Extra sharp, for big screens like an iPad or Mac."
        }
    }
}

/// Everything the cover renderer needs beyond the article itself.
public struct CoverStyle: Equatable, Sendable {
    public var fontFamily: String
    public var layout: CoverLayout
    public var size: CoverSize
    /// Render dark-on-paper in device grey levels instead of light-on-colour.
    /// On by default: the Kindle is the destination this app exists for, and
    /// its panel is a reflective 16-level greyscale.
    public var optimizeForEInk: Bool

    public init(
        fontFamily: String = "",
        layout: CoverLayout = .classic,
        size: CoverSize = .standard,
        optimizeForEInk: Bool = true
    ) {
        self.fontFamily = fontFamily
        self.layout = layout
        self.size = size
        self.optimizeForEInk = optimizeForEInk
    }

    public static let `default` = CoverStyle()
}
