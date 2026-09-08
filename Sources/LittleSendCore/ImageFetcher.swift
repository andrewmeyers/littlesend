import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// An image downloaded from the article and stored inside the EPUB.
public struct EmbeddedImage: Sendable, Equatable {
    /// Absolute URL the image came from. Kept so the EPUB can link back to the
    /// full-resolution original.
    public let sourceURL: String
    public let fileName: String
    public let mediaType: String
    public let data: Data
    public let wasResized: Bool

    public init(
        sourceURL: String,
        fileName: String,
        mediaType: String,
        data: Data,
        wasResized: Bool = false
    ) {
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.mediaType = mediaType
        self.data = data
        self.wasResized = wasResized
    }

    /// Path inside the EPUB package, relative to the OPF document.
    public var relativePath: String { "images/\(fileName)" }

    /// Identifier used to reference this image from an HTML email body as
    /// `src="cid:…"`.
    public var contentID: String {
        let stem = fileName.split(separator: ".").first.map(String.init) ?? fileName
        return "\(stem)@littlesend"
    }
}

/// Downloads article images so the EPUB is self-contained. EPUB 3 only
/// guarantees support for JPEG, PNG, GIF and SVG, so anything else (WebP,
/// AVIF, HEIC) is transcoded to JPEG before being embedded.
public struct ImageFetcher {
    public struct Limits: Sendable {
        public var maximumCount: Int
        /// Downloads larger than this are abandoned rather than resized; it
        /// exists to stop a pathological file, not to control output size.
        public var downloadCeiling: Int
        /// Images above this are re-encoded to fit. Nil keeps originals.
        public var targetBytes: Int?
        public var timeout: TimeInterval

        public init(
            maximumCount: Int = 25,
            downloadCeiling: Int = 20 * 1024 * 1024,
            targetBytes: Int? = 600 * 1024,
            timeout: TimeInterval = 20
        ) {
            self.maximumCount = maximumCount
            self.downloadCeiling = downloadCeiling
            self.targetBytes = targetBytes
            self.timeout = timeout
        }
    }

    private let session: URLSession
    private let limits: Limits

    public init(session: URLSession = .shared, limits: Limits = Limits()) {
        self.session = session
        self.limits = limits
    }

    /// Fetches every URL it can, skipping the ones that fail. A missing image
    /// should never fail the whole send.
    public func fetch(urls: [URL]) async -> [EmbeddedImage] {
        let targets = Array(urls.prefix(limits.maximumCount))
        guard !targets.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, EmbeddedImage?).self) { group in
            for (offset, url) in targets.enumerated() {
                group.addTask { (offset, await self.fetchOne(url: url, index: offset)) }
            }
            var results: [(Int, EmbeddedImage)] = []
            for await (offset, image) in group {
                if let image { results.append((offset, image)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func fetchOne(url: URL, index: Int) async -> EmbeddedImage? {
        guard url.scheme == "https" || url.scheme == "http" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = limits.timeout
        request.setValue("LittleSend/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty,
              data.count <= limits.downloadCeiling
        else { return nil }

        guard let sniffed = Self.sniffFormat(data) else { return nil }
        let safeType = Self.epubSafeMediaType(for: sniffed)
        let overTarget = limits.targetBytes.map { data.count > $0 } ?? false

        // Small enough and already a format EPUB guarantees: keep the original.
        if let safeType, !overTarget {
            return EmbeddedImage(
                sourceURL: url.absoluteString,
                fileName: "img\(index)\(Self.fileExtension(for: safeType))",
                mediaType: safeType,
                data: data
            )
        }

        if let target = limits.targetBytes, overTarget,
           let shrunk = ImageResizer.shrink(data, toAtMost: target) {
            return EmbeddedImage(
                sourceURL: url.absoluteString,
                fileName: "img\(index)\(Self.fileExtension(for: shrunk.mediaType))",
                mediaType: shrunk.mediaType,
                data: shrunk.data,
                wasResized: true
            )
        }

        // Under the target but in a format EPUB does not guarantee (WebP, AVIF,
        // HEIC), so transcode without changing dimensions.
        if safeType == nil, let jpeg = Self.transcodeToJPEG(data) {
            return EmbeddedImage(
                sourceURL: url.absoluteString,
                fileName: "img\(index).jpg",
                mediaType: "image/jpeg",
                data: jpeg,
                wasResized: true
            )
        }

        // Resizing failed but the bytes are usable as they are.
        guard let safeType else { return nil }
        return EmbeddedImage(
            sourceURL: url.absoluteString,
            fileName: "img\(index)\(Self.fileExtension(for: safeType))",
            mediaType: safeType,
            data: data
        )
    }

    // MARK: - Format handling

    /// Identifies the format from magic bytes rather than trusting Content-Type.
    static func sniffFormat(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 12 else { return nil }

        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) { return "image/webp" }
        if Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if brand.hasPrefix("avif") || brand.hasPrefix("avis") { return "image/avif" }
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") { return "image/heic" }
        }
        if let text = String(data: data.prefix(256), encoding: .utf8), text.contains("<svg") { return "image/svg+xml" }
        return nil
    }

    /// Returns the media type unchanged when EPUB 3 supports it natively.
    static func epubSafeMediaType(for sniffed: String) -> String? {
        ["image/jpeg", "image/png", "image/gif", "image/svg+xml"].contains(sniffed) ? sniffed : nil
    }

    static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": return ".png"
        case "image/gif": return ".gif"
        case "image/svg+xml": return ".svg"
        default: return ".jpg"
        }
    }

    static func transcodeToJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
