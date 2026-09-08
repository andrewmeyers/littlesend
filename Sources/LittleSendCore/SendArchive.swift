import Foundation

/// Keeps the files produced by recent sends on disk, and nothing older.
///
/// The point is recovery: if a delivery fails, the EPUB that was built is still
/// there to send by hand. Everything past the most recent few is deleted, so
/// the folder cannot grow without bound.
public struct SendArchive {

    /// How many sends are kept. Older folders are removed after each save.
    public static let keepCount = 5

    public struct Saved: Sendable {
        public let folder: URL
        public let files: [URL]
    }

    private let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/LittleSend/Recent Sends`.
    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("LittleSend", isDirectory: true)
            .appendingPathComponent("Recent Sends", isDirectory: true)
    }

    public var location: URL { root }

    /// Writes one send's artifacts into a dated folder, then prunes.
    @discardableResult
    public func save(
        title: String,
        sourceURL: String,
        date: Date = Date(),
        epub: (fileName: String, data: Data)? = nil,
        cover: Data? = nil,
        emailHTML: String? = nil,
        summary: String? = nil
    ) throws -> Saved {
        let folder = root.appendingPathComponent(folderName(title: title, date: date), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []

        if let epub {
            let file = folder.appendingPathComponent(epub.fileName)
            try epub.data.write(to: file)
            written.append(file)
        }
        if let cover {
            let file = folder.appendingPathComponent("cover.jpg")
            try cover.write(to: file)
            written.append(file)
        }
        if let emailHTML {
            let file = folder.appendingPathComponent("email.html")
            try Data(emailHTML.utf8).write(to: file)
            written.append(file)
        }

        // A plain-text note so the folder makes sense on its own.
        var note = "\(title)\n\(sourceURL)\n\(Self.readableDate.string(from: date))\n"
        if let summary { note += "\n\(summary)\n" }
        let noteFile = folder.appendingPathComponent("about.txt")
        try Data(note.utf8).write(to: noteFile)
        written.append(noteFile)

        try prune()
        return Saved(folder: folder, files: written)
    }

    /// Existing send folders, newest first. Names begin with a sortable
    /// timestamp, so ordering by name orders by time.
    public func folders() throws -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Deletes everything past the most recent `keeping` sends.
    public func prune(keeping: Int = keepCount) throws {
        let all = try folders()
        guard all.count > keeping else { return }
        for folder in all.dropFirst(keeping) {
            try? fileManager.removeItem(at: folder)
        }
    }

    // MARK: - Naming

    /// `2026-09-05 121530 Article-Title` — sortable, and readable in Finder.
    func folderName(title: String, date: Date) -> String {
        let stamp = Self.stampDate.string(from: date)
        let slug = Self.slug(title)
        return slug.isEmpty ? stamp : "\(stamp) \(slug)"
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = title.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(cleaned.prefix(60))
    }

    private static let stampDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    private static let readableDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
