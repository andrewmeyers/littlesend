import SwiftUI

/// One place for the app's text sizes.
///
/// macOS collapses `footnote`, `caption` and `caption2` to roughly 10pt, so the
/// old `.caption`/`.caption2` pairing gave two names to one size and left most
/// of the panel at the smallest text the system offers. These three map onto
/// genuinely distinct sizes and each sits a step larger than what it replaced.
///
/// Change the scale here rather than hunting fonts through the views.
extension Font {
    /// Secondary explanatory text — the smallest thing in the app (~11pt).
    static let appHint = Font.subheadline
    /// Labels, list rows, banner copy (~12pt).
    static let appLabel = Font.callout
    /// Primary text (~13pt).
    static let appBody = Font.body
}
