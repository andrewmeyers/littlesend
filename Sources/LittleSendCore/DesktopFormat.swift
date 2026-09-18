import Foundation

/// The format the Desktop copy of an article is saved in.
///
/// Chosen from the Desktop chip in the panel, alongside the destination itself,
/// rather than in Settings: where a send goes and what shape it arrives in are
/// the same decision.
public enum DesktopFormat: String, CaseIterable, Codable, Sendable {
    case epub
    case pdf
    case markdown
    case text

    public var displayName: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .text: return "Plain Text"
        }
    }

    /// For the chip, where space is tight.
    public var shortName: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .markdown: return "MD"
        case .text: return "TXT"
        }
    }

    public var fileExtension: String {
        switch self {
        case .epub: return "epub"
        case .pdf: return "pdf"
        case .markdown: return "md"
        case .text: return "txt"
        }
    }
}
