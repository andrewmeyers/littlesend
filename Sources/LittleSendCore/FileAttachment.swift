import Foundation

/// A local file being sent as-is, rather than an article being built into one.
///
/// Nothing is converted here. Send to Kindle already converts the formats it
/// accepts on Amazon's side, and re-wrapping a PDF or a Word document into an
/// EPUB would lose more than it gained.
public struct FileAttachment: Sendable {

    public enum Failure: LocalizedError {
        case unreadable(String)
        case empty
        case tooLarge(bytes: Int, limit: Int)
        case kindleNotSelected
        case unsupportedByKindle(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason):
                return "Could not read that file: \(reason)"
            case .empty:
                return "That file is empty."
            case .tooLarge(let bytes, let limit):
                let f = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                let l = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
                return "That file is \(f); the limit is about \(l) once encoded for mail."
            case .kindleNotSelected:
                return "Turn on Kindle first — files are sent to Kindle only."
            case .unsupportedByKindle(let ext):
                let kind = ext.isEmpty ? "that kind of file" : ".\(ext) files"
                return "Kindle does not accept \(kind). It takes EPUB, PDF, DOC, DOCX, "
                    + "TXT, RTF, HTML and common image formats."
            }
        }
    }

    /// Practical ceiling on the raw file.
    ///
    /// Amazon accepts up to 50 MB, but the mail provider in front of it is the
    /// real constraint: Gmail caps a message at 25 MB, and base64 inflates an
    /// attachment by about a third. Catching it here gives a sentence that says
    /// what happened, instead of an SMTP rejection halfway through the upload.
    public static let sizeLimitBytes = 18 * 1024 * 1024

    /// Extensions Send to Kindle accepts. Anything else is refused up front,
    /// because Amazon drops what it cannot convert without telling anyone.
    public static let kindleExtensions: Set<String> = [
        "epub", "pdf", "doc", "docx", "txt", "rtf", "htm", "html",
        "jpg", "jpeg", "png", "gif", "bmp",
    ]

    public let fileName: String
    public let data: Data
    public let mediaType: String

    public var byteCount: Int { data.count }

    public var fileExtension: String {
        (fileName as NSString).pathExtension.lowercased()
    }

    public var isAcceptedByKindle: Bool {
        Self.kindleExtensions.contains(fileExtension)
    }

    public init(fileName: String, data: Data, mediaType: String) {
        self.fileName = fileName
        self.data = data
        self.mediaType = mediaType
    }

    public init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        guard !data.isEmpty else { throw Failure.empty }
        guard data.count <= Self.sizeLimitBytes else {
            throw Failure.tooLarge(bytes: data.count, limit: Self.sizeLimitBytes)
        }

        self.init(
            fileName: MailMessage.sanitizeFileName(url.lastPathComponent),
            data: data,
            mediaType: Self.mediaType(forExtension: url.pathExtension)
        )
    }

    /// The title shown in history and used as the mail subject: the file name
    /// without its extension, which is what Kindle will label it as too.
    public var displayTitle: String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? fileName : stem
    }

    static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "epub": return "application/epub+zip"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "txt": return "text/plain"
        case "rtf": return "application/rtf"
        case "htm", "html": return "text/html"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "bmp": return "image/bmp"
        default: return "application/octet-stream"
        }
    }
}
