import Foundation

/// Builds an RFC 5322 message.
///
/// The MIME shape follows the content: a bare `text/plain` when that is all
/// there is, `multipart/alternative` when an HTML version exists, and
/// `multipart/mixed` wrapping either of those when there is an attachment.
public struct MailMessage {

    public struct Attachment {
        public var fileName: String
        public var mediaType: String
        public var data: Data

        public init(fileName: String, mediaType: String, data: Data) {
            self.fileName = fileName
            self.mediaType = mediaType
            self.data = data
        }
    }

    /// An image carried in the message body and referenced by `cid:`.
    public struct InlineImage {
        public var contentID: String
        public var fileName: String
        public var mediaType: String
        public var data: Data

        public init(contentID: String, fileName: String, mediaType: String, data: Data) {
            self.contentID = contentID
            self.fileName = fileName
            self.mediaType = mediaType
            self.data = data
        }
    }

    public var fromAddress: String
    public var fromName: String?
    public var toAddresses: [String]
    public var subject: String
    public var plainTextBody: String
    public var htmlBody: String?
    public var inlineImages: [InlineImage]
    public var attachment: Attachment?
    public var date: Date

    public init(
        fromAddress: String,
        fromName: String? = nil,
        toAddresses: [String],
        subject: String,
        plainTextBody: String,
        htmlBody: String? = nil,
        inlineImages: [InlineImage] = [],
        attachment: Attachment? = nil,
        date: Date = Date()
    ) {
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddresses = toAddresses
        self.subject = subject
        self.plainTextBody = plainTextBody
        self.htmlBody = htmlBody
        self.inlineImages = inlineImages
        self.attachment = attachment
        self.date = date
    }

    public func serialized(boundary: String = "littlesend-\(UUID().uuidString)") -> Data {
        let alternativeBoundary = "\(boundary)-alt"
        let relatedBoundary = "\(boundary)-rel"

        var headers = ""
        let safeFrom = Self.stripLineBreaks(fromAddress)
        let from = fromName.map { "\(Self.encodeHeader($0)) <\(safeFrom)>" } ?? safeFrom

        headers += "From: \(from)\r\n"
        headers += "To: \(toAddresses.map(Self.stripLineBreaks).joined(separator: ", "))\r\n"
        headers += "Subject: \(Self.encodeHeader(subject))\r\n"
        headers += "Date: \(Self.dateFormatter.string(from: date))\r\n"
        headers += "Message-ID: <\(UUID().uuidString)@\(Self.messageIDDomain(for: safeFrom))>\r\n"
        headers += "MIME-Version: 1.0\r\n"

        // Built inside out. Each block carries its own Content-Type header, so
        // it works both as the whole body and as one part of a larger message.
        var content = readableBlock(alternativeBoundary: alternativeBoundary)

        if !inlineImages.isEmpty {
            // multipart/related ties the images to the HTML that cites them.
            var related = "Content-Type: multipart/related; type=\"multipart/alternative\"; "
            related += "boundary=\"\(relatedBoundary)\"\r\n\r\n"
            related += "--\(relatedBoundary)\r\n"
            related += content
            for image in inlineImages {
                related += "--\(relatedBoundary)\r\n"
                related += inlineImageBlock(image)
            }
            related += "--\(relatedBoundary)--\r\n"
            content = related
        }

        if let attachment {
            var mixed = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            mixed += "This is a multi-part message in MIME format.\r\n"
            mixed += "--\(boundary)\r\n"
            mixed += content
            mixed += "--\(boundary)\r\n"
            mixed += attachmentBlock(attachment)
            mixed += "--\(boundary)--\r\n"
            content = mixed
        }

        return Data((headers + content).utf8)
    }

    /// The readable part: plain text alone, or plain text plus HTML wrapped in
    /// `multipart/alternative` so clients pick whichever they prefer.
    private func readableBlock(alternativeBoundary: String) -> String {
        guard let htmlBody else {
            var block = "Content-Type: text/plain; charset=\"utf-8\"\r\n"
            block += "Content-Transfer-Encoding: base64\r\n\r\n"
            block += Self.base64Lines(Data(plainTextBody.utf8))
            block += "\r\n"
            return block
        }

        var block = "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n\r\n"

        block += "--\(alternativeBoundary)\r\n"
        block += "Content-Type: text/plain; charset=\"utf-8\"\r\n"
        block += "Content-Transfer-Encoding: base64\r\n\r\n"
        block += Self.base64Lines(Data(plainTextBody.utf8))
        block += "\r\n"

        block += "--\(alternativeBoundary)\r\n"
        block += "Content-Type: text/html; charset=\"utf-8\"\r\n"
        block += "Content-Transfer-Encoding: base64\r\n\r\n"
        block += Self.base64Lines(Data(htmlBody.utf8))
        block += "\r\n"

        block += "--\(alternativeBoundary)--\r\n"
        return block
    }

    private func inlineImageBlock(_ image: InlineImage) -> String {
        let name = Self.sanitizeFileName(image.fileName)
        var block = "Content-Type: \(image.mediaType); name=\"\(name)\"\r\n"
        block += "Content-Transfer-Encoding: base64\r\n"
        block += "Content-ID: <\(Self.stripLineBreaks(image.contentID))>\r\n"
        block += "Content-Disposition: inline; filename=\"\(name)\"\r\n\r\n"
        block += Self.base64Lines(image.data)
        block += "\r\n"
        return block
    }

    private func attachmentBlock(_ attachment: Attachment) -> String {
        let name = Self.sanitizeFileName(attachment.fileName)
        var block = "Content-Type: \(attachment.mediaType); name=\"\(name)\"\r\n"
        block += "Content-Transfer-Encoding: base64\r\n"
        block += "Content-Disposition: attachment; filename=\"\(name)\"\r\n\r\n"
        block += Self.base64Lines(attachment.data)
        block += "\r\n"
        return block
    }

    /// Base64 bodies must be wrapped to stay within the 998-octet line limit.
    ///
    /// Foundation wraps while it encodes. Splitting the encoded string
    /// afterwards made one small String per 76 characters — hundreds of
    /// thousands of them for an EPUB of a few megabytes.
    static func base64Lines(_ data: Data) -> String {
        data.base64EncodedString(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
        ])
    }

    /// The domain half of the sender's address, for the right-hand side of the
    /// Message-ID.
    ///
    /// That side is conventionally the sending host's domain, and ordinary mail
    /// clients use the sender's. This used to be a fixed "littlesend.local",
    /// which is worse than merely arbitrary: ".local" is reserved for multicast
    /// DNS, so it can never resolve, and some filters score a Message-ID whose
    /// domain does not resolve as a spam signal.
    ///
    /// The fallback is ".invalid" — also unresolvable, but reserved by RFC 2606
    /// precisely to mean "deliberately not a real domain", which is the honest
    /// thing to say when there is no address to derive one from.
    static func messageIDDomain(for address: String) -> String {
        guard let at = address.lastIndex(of: "@") else { return fallbackMessageIDDomain }
        // Whatever is left must be safe to drop into a header verbatim, so keep
        // only characters that are legal in a domain and discard the rest — a
        // malformed address must not be able to inject header syntax.
        let domain = address[address.index(after: at)...].filter {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
        return domain.isEmpty ? fallbackMessageIDDomain : domain
    }

    static let fallbackMessageIDDomain = "littlesend.invalid"

    /// Header values must never contain CR or LF, which would let a crafted
    /// title or address inject additional headers.
    static func stripLineBreaks(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// RFC 2047 encoding, applied only when the header is not plain ASCII.
    static func encodeHeader(_ value: String) -> String {
        let collapsed = stripLineBreaks(value)
        if collapsed.allSatisfy({ $0.isASCII && !$0.isNewline }) {
            return collapsed
        }
        return "=?UTF-8?B?\(Data(collapsed.utf8).base64EncodedString())?="
    }

    /// Kindle keys off the filename, so keep it ASCII and free of quoting hazards.
    static func sanitizeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = name.unicodeScalars
            .map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "article.epub" : trimmed
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }()
}
