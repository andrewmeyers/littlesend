import Foundation

/// Writes the EPUB straight to a folder the user actually looks at — the
/// Desktop by default.
///
/// Unlike `SendArchive`, which quietly keeps the last few sends around for
/// recovery and prunes everything older, this is a destination in its own
/// right: the file is put where it was asked to go and never cleaned up.
public struct DesktopExporter {

    public struct Saved: Sendable, Equatable {
        public let url: URL
        /// True when the intended name was taken and a numbered one was used.
        public let renamedToAvoidCollision: Bool
    }

    public enum Failure: LocalizedError {
        case noDestinationFolder
        case couldNotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .noDestinationFolder:
                return "Couldn't find your Desktop folder."
            case .couldNotWrite(let reason):
                return "Couldn't save to your Desktop: \(reason)"
            }
        }
    }

    private let folder: URL
    private let fileManager: FileManager

    public init(folder: URL, fileManager: FileManager = .default) {
        self.folder = folder
        self.fileManager = fileManager
    }

    /// The user's Desktop.
    public static func defaultFolder(fileManager: FileManager = .default) throws -> URL {
        guard let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            throw Failure.noDestinationFolder
        }
        return desktop
    }

    public var location: URL { folder }

    /// Writes `data` as `fileName`, stepping the name aside rather than
    /// overwriting anything already sitting there — sending the same article
    /// twice should leave both copies, the way a download would.
    @discardableResult
    public func save(_ data: Data, fileName: String) throws -> Saved {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let target = availableURL(for: fileName)
        do {
            try data.write(to: target.url, options: .atomic)
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
        return target
    }

    /// Finds a free name: "Article.epub", then "Article 2.epub", and so on.
    func availableURL(for fileName: String) -> Saved {
        let candidate = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: candidate.path) else {
            return Saved(url: candidate, renamedToAvoidCollision: false)
        }

        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        // Bounded so a pathological folder cannot spin here forever.
        for suffix in 2...999 {
            let numbered = ext.isEmpty ? "\(name) \(suffix)" : "\(name) \(suffix).\(ext)"
            let url = folder.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: url.path) {
                return Saved(url: url, renamedToAvoidCollision: true)
            }
        }

        // Every numbered name was taken; fall back to something unique.
        let unique = ext.isEmpty
            ? "\(name) \(UUID().uuidString.prefix(8))"
            : "\(name) \(UUID().uuidString.prefix(8)).\(ext)"
        return Saved(url: folder.appendingPathComponent(unique), renamedToAvoidCollision: true)
    }
}
