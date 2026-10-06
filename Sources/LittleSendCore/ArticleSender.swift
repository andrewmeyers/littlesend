import Foundation

/// Everything the pipeline needs, gathered from Settings.
public struct SendConfiguration: Sendable {
    // Destinations. At least one must be active.
    public var sendToKindle: Bool
    public var kindleAddress: String
    /// Write the EPUB to a folder the user sees (the Desktop).
    public var saveToDesktop: Bool
    /// Which format the Desktop copy is saved in.
    public var desktopFormat: DesktopFormat
    public var emailRecipients: [String]
    public var attachBookToEmail: Bool
    /// Embed shrunk images in the email rather than linking to the originals.
    public var embedImagesInEmail: Bool

    public var fromAddress: String
    public var fromName: String?
    public var smtpHost: String
    public var smtpPort: UInt16
    public var smtpUsername: String
    public var smtpPassword: String
    public var embedImages: Bool
    /// Ceiling for each embedded image. Nil embeds originals untouched.
    public var imageSizeLimitBytes: Int?
    /// Font, layout and pixel size for the cover image.
    public var coverStyle: CoverStyle
    /// Which reader turns the web page into an article.
    public var articleReader: ArticleReader
    public var instaparserAPIKey: String

    public init(
        sendToKindle: Bool = true,
        kindleAddress: String,
        saveToDesktop: Bool = false,
        desktopFormat: DesktopFormat = .epub,
        emailRecipients: [String] = [],
        attachBookToEmail: Bool = false,
        embedImagesInEmail: Bool = true,
        fromAddress: String,
        fromName: String? = nil,
        smtpHost: String,
        smtpPort: UInt16,
        smtpUsername: String,
        smtpPassword: String,
        embedImages: Bool = true,
        imageSizeLimitBytes: Int? = 600 * 1024,
        coverStyle: CoverStyle = .default,
        articleReader: ArticleReader = .local,
        instaparserAPIKey: String = ""
    ) {
        self.sendToKindle = sendToKindle
        self.kindleAddress = kindleAddress
        self.saveToDesktop = saveToDesktop
        self.desktopFormat = desktopFormat
        self.emailRecipients = emailRecipients
        self.attachBookToEmail = attachBookToEmail
        self.embedImagesInEmail = embedImagesInEmail
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUsername = smtpUsername
        self.smtpPassword = smtpPassword
        self.embedImages = embedImages
        self.imageSizeLimitBytes = imageSizeLimitBytes
        self.coverStyle = coverStyle
        self.articleReader = articleReader
        self.instaparserAPIKey = instaparserAPIKey
    }

    /// True when an EPUB has to be produced at all.
    public var needsBook: Bool {
        // Only a Desktop copy saved *as* an EPUB needs one; the other formats
        // are rendered straight from the article.
        sendToKindle || (saveToDesktop && desktopFormat == .epub)
            || (attachBookToEmail && !emailRecipients.isEmpty)
    }

    /// True when images must be downloaded, for either destination.
    public var needsImages: Bool {
        guard embedImages else { return false }
        return needsBook || (embedImagesInEmail && !emailRecipients.isEmpty)
    }

    /// Human-readable reasons the configuration is not yet usable.
    public var validationProblems: [String] {
        var problems: [String] = []
        if !sendToKindle, !saveToDesktop, emailRecipients.isEmpty {
            problems.append("No destination is selected — pick one in the menu bar.")
        }
        if sendToKindle, !Self.looksLikeEmail(kindleAddress) {
            problems.append("Kindle address is missing or malformed.")
        }
        for recipient in emailRecipients where !Self.looksLikeEmail(recipient) {
            problems.append("Email recipient “\(recipient)” is malformed.")
        }

        // Saving to the Desktop never opens a connection, so mail credentials
        // are only required when something is actually being mailed.
        if sendToKindle || !emailRecipients.isEmpty {
            if !Self.looksLikeEmail(fromAddress) { problems.append("Sender address is missing or malformed.") }
            if smtpHost.isEmpty { problems.append("SMTP server is missing.") }
            if smtpUsername.isEmpty { problems.append("SMTP username is missing.") }
            if smtpPassword.isEmpty { problems.append("SMTP password is missing.") }
        }
        return problems
    }

    public static func looksLikeEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }
}

public enum SendStage: String, CaseIterable, Sendable {
    case parsing = "Reading article…"
    case fetchingImages = "Fetching images…"
    case buildingBook = "Building EPUB…"
    case readingFile = "Reading file…"
    case sending = "Sending…"
}

/// The result for one destination. Destinations are independent: email still
/// goes out when Kindle fails, and vice versa.
public struct DeliveryResult: Sendable {
    public enum Kind: String, Sendable {
        case kindle = "Kindle"
        case email = "Email"
        case desktop = "Desktop"
    }

    public let kind: Kind
    public let recipients: [String]
    public let errorMessage: String?

    public var succeeded: Bool { errorMessage == nil }
}

public struct SendOutcome: Sendable {
    public let title: String
    public let fileName: String?
    public let byteCount: Int?
    public let embeddedImageCount: Int
    public let resizedImageCount: Int
    public let usedTextFallback: Bool
    public let usedFallbackFont: Bool
    public let hasCover: Bool
    /// Words in the article, for a reading-time estimate. Nil for a file sent
    /// as-is, which is never opened here.
    public let wordCount: Int?
    /// Web pages the article was read from; 1 unless it was paginated.
    public let pageCount: Int
    public let deliveries: [DeliveryResult]
    /// Folder holding this send's files, when archiving is on.
    public let archiveFolder: URL?
    /// Why the built-in reader was used when Instaparser was chosen.
    public var readerNote: String? = nil
    /// The reason is one the user can fix, so it deserves a warning.
    public var readerNoteNeedsAttention = false
    /// Only a paywall's preview could be read, not the whole article.
    public var isPreview = false
    /// The publication's name, for saying whose paywall it was.
    public var siteName: String? = nil

    public var failures: [DeliveryResult] { deliveries.filter { !$0.succeeded } }
    public var successes: [DeliveryResult] { deliveries.filter(\.succeeded) }
}

/// Runs the full URL → destinations pipeline.
public struct ArticleSender {
    private let configuration: SendConfiguration
    private let session: URLSession
    private let archive: SendArchive?
    private let desktopExporter: DesktopExporter?

    public init(
        configuration: SendConfiguration,
        session: URLSession = .shared,
        archive: SendArchive? = nil,
        desktopExporter: DesktopExporter? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.archive = archive
        self.desktopExporter = desktopExporter
    }

    /// Sends a local file as-is to Kindle.
    ///
    /// Kindle only, by design. No parsing, no EPUB, no cover: Send to Kindle
    /// already converts the formats it accepts, and rebuilding a PDF or a Word
    /// document as an EPUB would lose more than it gained. The other
    /// destinations do not apply — email has its own attachment flow, and
    /// copying a local file back to the Desktop is not a delivery.
    public func send(
        file fileURL: URL,
        progress: @Sendable (SendStage) -> Void = { _ in }
    ) async throws -> SendOutcome {
        guard configuration.sendToKindle else {
            throw FileAttachment.Failure.kindleNotSelected
        }
        guard SendConfiguration.looksLikeEmail(configuration.kindleAddress) else {
            throw SMTPError(code: nil, message: "Kindle address is missing or malformed.")
        }

        progress(.readingFile)
        // Reading is synchronous and can be slow on a large file, so it is kept
        // off the caller's actor rather than blocking the UI mid-send.
        let attachment = try await Task.detached { try FileAttachment(contentsOf: fileURL) }.value

        // Refused here rather than at Amazon, which drops what it cannot
        // convert without sending back so much as a bounce.
        guard attachment.isAcceptedByKindle else {
            throw FileAttachment.Failure.unsupportedByKindle(attachment.fileExtension)
        }

        progress(.sending)
        let delivery = await deliver(
            kind: .kindle,
            recipients: [configuration.kindleAddress],
            message: fileMessage(attachment, to: [configuration.kindleAddress])
        )

        return SendOutcome(
            title: attachment.displayTitle,
            fileName: attachment.fileName,
            byteCount: attachment.byteCount,
            embeddedImageCount: 0,
            resizedImageCount: 0,
            usedTextFallback: false,
            usedFallbackFont: false,
            hasCover: false,
            wordCount: nil,
            pageCount: 1,
            deliveries: [delivery],
            archiveFolder: nil
        )
    }

    private func fileMessage(_ attachment: FileAttachment, to recipients: [String]) -> MailMessage {
        MailMessage(
            fromAddress: configuration.fromAddress,
            fromName: configuration.fromName,
            toAddresses: recipients,
            subject: attachment.displayTitle,
            plainTextBody: "\(attachment.fileName)\n\nSent by LittleSend.",
            attachment: MailMessage.Attachment(
                fileName: attachment.fileName,
                mediaType: attachment.mediaType,
                data: attachment.data
            )
        )
    }

    public func send(
        url: URL,
        onPage: @Sendable (Int) -> Void = { _ in },
        progress: @Sendable (SendStage) -> Void = { _ in }
    ) async throws -> SendOutcome {
        let problems = configuration.validationProblems
        guard problems.isEmpty else {
            throw SMTPError(code: nil, message: problems.joined(separator: " "))
        }

        // Read on this Mac by default, in a hidden WebKit view running
        // Readability: no account, and no third party learns what is being
        // read. Instaparser is the optional faster route, and falls back here.
        progress(.parsing)
        let reading = try await ArticleReading.read(
            url: url,
            reader: configuration.articleReader,
            instaparserAPIKey: configuration.instaparserAPIKey,
            instaparser: { url, key in
                try await InstaparserClient(apiKey: key, session: session).parse(url: url)
            },
            local: { url in
                // Later pages report their number rather than a fixed stage: a
                // long review can take a minute, and a count that climbs shows
                // it has not hung.
                try await LocalArticleParser().parse(url: url) { page in onPage(page) }
            }
        )
        let article = reading.article

        var book: EPUBBuilder.Result?
        var cover: CoverGenerator.Cover?
        var images: [EmbeddedImage] = []

        // Converted once and handed to everything below. The converter walks
        // the article character by character, and the books, the email and
        // the image list would otherwise each repeat that on the same input.
        let xhtml = HTMLToXHTML.convert(article.html)

        // Downloaded once and shared: the EPUB stores them as files, the email
        // carries the same bytes inline.
        if configuration.needsImages {
            let imageURLs = EPUBBuilder.imageURLs(inXHTML: xhtml, relativeTo: URL(string: article.url))
            if !imageURLs.isEmpty {
                progress(.fetchingImages)
                let limits = ImageFetcher.Limits(targetBytes: configuration.imageSizeLimitBytes)
                images = await ImageFetcher(session: session, limits: limits).fetch(urls: imageURLs)
            }
        }

        // Two books, at most, and only when they would actually differ. The
        // Kindle's panel wants flat greys; a Desktop copy is opened on a colour
        // screen, where the palette this app has always used is simply better.
        // Building twice costs another EPUB assembly and nothing else — the
        // images are already downloaded and shared between them.
        var eInkBook: EPUBBuilder.Result?
        var colorBook: EPUBBuilder.Result?

        if configuration.needsBook {
            progress(.buildingBook)

            func makeBook(eInk: Bool) -> (EPUBBuilder.Result, CoverGenerator.Cover?) {
                let art = CoverGenerator.makeCover(
                    article: article,
                    fontFamily: configuration.coverStyle.fontFamily,
                    layout: configuration.coverStyle.layout,
                    size: configuration.coverStyle.size,
                    optimizeForEInk: eInk
                )
                return (EPUBBuilder.build(article: article, images: images, cover: art, convertedHTML: xhtml), art)
            }

            let wantsEInk = configuration.coverStyle.optimizeForEInk && configuration.sendToKindle
            let wantsColor = (configuration.saveToDesktop && configuration.desktopFormat == .epub)
                || (configuration.attachBookToEmail && !configuration.emailRecipients.isEmpty)
                || !configuration.coverStyle.optimizeForEInk

            if wantsEInk {
                let made = makeBook(eInk: true)
                eInkBook = made.0
                cover = made.1
            }
            if wantsColor {
                let made = makeBook(eInk: false)
                colorBook = made.0
                // The archived cover shows whichever book was built; when both
                // exist the Kindle one is what was actually sent, so it wins.
                if cover == nil { cover = made.1 }
            }
            // Neither flag can be false while `needsBook` is true, but a
            // fallback keeps this total rather than relying on that argument.
            book = eInkBook ?? colorBook
        }

        progress(.sending)

        // Captured by the concurrent work below, which may not share a `var`.
        let sharedImages = images
        let rendered: ArticleEmailRenderer.Rendered? = configuration.emailRecipients.isEmpty
            ? nil
            : ArticleEmailRenderer.render(
                article: article,
                inlineImages: configuration.embedImagesInEmail ? sharedImages : [],
                convertedHTML: xhtml
            )
        let emailHTML = rendered?.html

        // The destinations share nothing, so they run side by side: each mail
        // destination is its own SMTP session uploading its own copy, and a PDF
        // Desktop copy downloads images of its own. Done one after another, the
        // send took as long as all of them added together.
        let kindleBook = configuration.sendToKindle ? eInkBook ?? colorBook : nil
        // Email lands on a phone or laptop screen, so it gets the colour book
        // for the same reason the Desktop copy does.
        let screenBook = colorBook ?? eInkBook

        async let kindleDelivery = { () async -> DeliveryResult? in
            guard let kindleBook else { return nil }
            return await deliverToKindle(article: article, book: kindleBook)
        }()
        async let desktopDelivery = { () async -> DeliveryResult? in
            guard configuration.saveToDesktop else { return nil }
            return await saveDesktopCopy(article: article, book: screenBook, convertedHTML: xhtml)
        }()
        async let emailDelivery = { () async -> DeliveryResult? in
            guard let rendered else { return nil }
            return await deliverToEmail(article: article, book: screenBook, images: sharedImages, rendered: rendered)
        }()

        // Reported in a fixed order, whichever finishes first.
        let deliveries = [await kindleDelivery, await desktopDelivery, await emailDelivery].compactMap { $0 }

        // Saved even when delivery failed, so a rejected send still leaves the
        // EPUB behind to send by hand.
        let archiveFolder = saveToArchive(
            article: article, book: book, cover: cover,
            emailHTML: emailHTML, deliveries: deliveries
        )

        // Only a total failure is an error; a partial one is reported per row.
        if deliveries.allSatisfy({ !$0.succeeded }), let first = deliveries.first {
            throw SMTPError(code: nil, message: first.errorMessage ?? "Delivery failed.")
        }

        return SendOutcome(
            title: article.title,
            fileName: book?.fileName,
            byteCount: book?.data.count,
            embeddedImageCount: book?.embeddedImageCount ?? 0,
            resizedImageCount: images.filter(\.wasResized).count,
            usedTextFallback: book?.usedTextFallback ?? false,
            usedFallbackFont: cover?.usedFallbackFont ?? false,
            hasCover: book?.hasCover ?? false,
            wordCount: ReadingTime.wordCount(ofHTML: article.html),
            pageCount: article.pageCount,
            deliveries: deliveries,
            archiveFolder: archiveFolder,
            readerNote: reading.note,
            readerNoteNeedsAttention: reading.needsAttention,
            isPreview: article.isPreview,
            siteName: article.siteName
        )
    }

    // MARK: - Destinations

    /// Writes the Desktop copy in whichever format was chosen for it. Async
    /// only because a PDF fetches full-size images and renders through WebKit.
    private func saveDesktopCopy(
        article: ParsedArticle,
        book: EPUBBuilder.Result?,
        convertedHTML: String
    ) async -> DeliveryResult {
        let format = configuration.desktopFormat
        let data: Data
        do {
            switch format {
            case .epub:
                guard let book else {
                    throw DesktopExporter.Failure.couldNotWrite("the EPUB was not built")
                }
                data = book.data
            case .pdf:
                // The originals, not the copies shrunk for the EPUB: those are
                // cut to a byte budget, and a printed page needs pixels. The
                // renderer brings them down to 300 dpi itself.
                let urls = EPUBBuilder.imageURLs(
                    inXHTML: convertedHTML,
                    relativeTo: URL(string: article.url)
                )
                let originals = await ImageFetcher(
                    session: session,
                    limits: ImageFetcher.Limits(targetBytes: nil)
                ).fetch(urls: urls)
                data = try await PDFRenderer.render(article: article, images: originals)
            case .markdown:
                data = Data(DocumentRenderer.markdown(for: article).utf8)
            case .text:
                data = Data(DocumentRenderer.plainText(for: article).utf8)
            }
        } catch {
            return DeliveryResult(
                kind: .desktop,
                recipients: [],
                errorMessage: Self.describe(error)
            )
        }
        return saveToDesktop(data: data, fileName: DocumentRenderer.fileName(for: article, format: format))
    }

    private func saveToDesktop(data: Data, fileName: String) -> DeliveryResult {
        let exporter: DesktopExporter
        do {
            exporter = try desktopExporter ?? DesktopExporter(folder: DesktopExporter.defaultFolder())
        } catch {
            return DeliveryResult(
                kind: .desktop,
                recipients: [],
                errorMessage: Self.describe(error)
            )
        }

        do {
            let saved = try exporter.save(data, fileName: fileName)
            // The path rides along in `recipients` so the popover can show and
            // reveal exactly which file was written.
            return DeliveryResult(kind: .desktop, recipients: [saved.url.path], errorMessage: nil)
        } catch {
            return DeliveryResult(
                kind: .desktop,
                recipients: [],
                errorMessage: Self.describe(error)
            )
        }
    }

    private func deliverToKindle(article: ParsedArticle, book: EPUBBuilder.Result) async -> DeliveryResult {
        let message = MailMessage(
            fromAddress: configuration.fromAddress,
            fromName: configuration.fromName,
            toAddresses: [configuration.kindleAddress],
            // Send to Kindle ignores the subject for EPUB, but a useful one
            // makes the sent-mail record readable.
            subject: article.title,
            plainTextBody: "\(article.title)\n\(article.url)\n\nSent by LittleSend.",
            attachment: MailMessage.Attachment(
                fileName: book.fileName,
                mediaType: "application/epub+zip",
                data: book.data
            )
        )
        return await deliver(kind: .kindle, recipients: [configuration.kindleAddress], message: message)
    }

    private func deliverToEmail(
        article: ParsedArticle,
        book: EPUBBuilder.Result?,
        images: [EmbeddedImage],
        rendered: ArticleEmailRenderer.Rendered
    ) async -> DeliveryResult {
        let embedded = configuration.embedImagesInEmail ? images : []

        let inlineImages = embedded.map {
            MailMessage.InlineImage(
                contentID: $0.contentID,
                fileName: $0.fileName,
                mediaType: $0.mediaType,
                data: $0.data
            )
        }

        var attachment: MailMessage.Attachment?
        if configuration.attachBookToEmail, let book {
            attachment = MailMessage.Attachment(
                fileName: book.fileName,
                mediaType: "application/epub+zip",
                data: book.data
            )
        }

        let message = MailMessage(
            fromAddress: configuration.fromAddress,
            fromName: configuration.fromName,
            toAddresses: configuration.emailRecipients,
            subject: rendered.subject,
            plainTextBody: rendered.plainText,
            htmlBody: rendered.html,
            inlineImages: inlineImages,
            attachment: attachment
        )
        return await deliver(kind: .email, recipients: configuration.emailRecipients, message: message)
    }

    /// Best effort: a failure to write files must never fail a send that the
    /// recipient already received.
    private func saveToArchive(
        article: ParsedArticle,
        book: EPUBBuilder.Result?,
        cover: CoverGenerator.Cover?,
        emailHTML: String?,
        deliveries: [DeliveryResult]
    ) -> URL? {
        guard let archive else { return nil }

        let summary = deliveries
            .map { "\($0.kind.rawValue): \($0.errorMessage ?? "delivered")" }
            .joined(separator: "\n")

        return try? archive.save(
            title: article.title,
            sourceURL: article.url,
            epub: book.map { (fileName: $0.fileName, data: $0.data) },
            cover: cover?.data,
            emailHTML: emailHTML,
            summary: summary
        ).folder
    }

    /// The message shown for a failed destination.
    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func deliver(
        kind: DeliveryResult.Kind,
        recipients: [String],
        message: MailMessage
    ) async -> DeliveryResult {
        let smtp = SMTPClient(configuration: SMTPConfiguration(
            host: configuration.smtpHost,
            port: configuration.smtpPort,
            username: configuration.smtpUsername,
            password: configuration.smtpPassword
        ))
        do {
            try await smtp.send(
                envelopeFrom: configuration.fromAddress,
                recipients: recipients,
                message: message.serialized()
            )
            return DeliveryResult(kind: kind, recipients: recipients, errorMessage: nil)
        } catch {
            return DeliveryResult(kind: kind, recipients: recipients, errorMessage: Self.describe(error))
        }
    }
}
