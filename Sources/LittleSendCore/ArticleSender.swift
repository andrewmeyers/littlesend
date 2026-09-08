import Foundation

/// Everything the pipeline needs, gathered from Settings and the Keychain.
public struct SendConfiguration: Sendable {
    public var instaparserAPIKey: String

    // Destinations. At least one must be active.
    public var sendToKindle: Bool
    public var kindleAddress: String
    /// Write the EPUB to a folder the user sees (the Desktop).
    public var saveToDesktop: Bool
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

    public init(
        instaparserAPIKey: String,
        sendToKindle: Bool = true,
        kindleAddress: String,
        saveToDesktop: Bool = false,
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
        coverStyle: CoverStyle = .default
    ) {
        self.instaparserAPIKey = instaparserAPIKey
        self.sendToKindle = sendToKindle
        self.kindleAddress = kindleAddress
        self.saveToDesktop = saveToDesktop
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
    }

    /// True when an EPUB has to be produced at all.
    public var needsBook: Bool {
        sendToKindle || saveToDesktop || (attachBookToEmail && !emailRecipients.isEmpty)
    }

    /// True when images must be downloaded, for either destination.
    public var needsImages: Bool {
        guard embedImages else { return false }
        return needsBook || (embedImagesInEmail && !emailRecipients.isEmpty)
    }

    /// Human-readable reasons the configuration is not yet usable.
    public var validationProblems: [String] {
        var problems: [String] = []
        if instaparserAPIKey.isEmpty { problems.append("Instaparser API key is missing.") }

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

/// Which parser to run. The local reader is a manual fallback, never the
/// default — it is much slower and spins up a web view.
public enum ArticleParserChoice: String, Sendable {
    case instaparser
    case localReader
}

public enum SendStage: String, Sendable {
    case parsing = "Parsing article…"
    case parsingLocally = "Reading page locally…"
    case fetchingImages = "Fetching images…"
    case buildingBook = "Building EPUB…"
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
    public let deliveries: [DeliveryResult]
    /// Folder holding this send's files, when archiving is on.
    public let archiveFolder: URL?

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

    public func send(
        url: URL,
        using parser: ArticleParserChoice = .instaparser,
        progress: @Sendable (SendStage) -> Void = { _ in }
    ) async throws -> SendOutcome {
        let problems = configuration.validationProblems
        guard problems.isEmpty else {
            throw SMTPError(code: nil, message: problems.joined(separator: " "))
        }

        let article: ParsedArticle
        switch parser {
        case .instaparser:
            progress(.parsing)
            let client = InstaparserClient(apiKey: configuration.instaparserAPIKey, session: session)
            article = try await client.parse(url: url)
        case .localReader:
            progress(.parsingLocally)
            article = try await LocalArticleParser().parse(url: url)
        }

        var book: EPUBBuilder.Result?
        var cover: CoverGenerator.Cover?
        var images: [EmbeddedImage] = []

        // Downloaded once and shared: the EPUB stores them as files, the email
        // carries the same bytes inline.
        if configuration.needsImages {
            let xhtml = HTMLToXHTML.convert(article.html)
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
                return (EPUBBuilder.build(article: article, images: images, cover: art), art)
            }

            let wantsEInk = configuration.coverStyle.optimizeForEInk && configuration.sendToKindle
            let wantsColor = configuration.saveToDesktop
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
        var deliveries: [DeliveryResult] = []

        if configuration.sendToKindle, let kindleBook = eInkBook ?? colorBook {
            deliveries.append(await deliverToKindle(article: article, book: kindleBook))
        }
        if configuration.saveToDesktop, let desktopBook = colorBook ?? eInkBook {
            deliveries.append(saveToDesktop(book: desktopBook))
        }
        var emailHTML: String?
        if !configuration.emailRecipients.isEmpty {
            let rendered = ArticleEmailRenderer.render(
                article: article,
                inlineImages: configuration.embedImagesInEmail ? images : []
            )
            emailHTML = rendered.html
            deliveries.append(
                await deliverToEmail(
                    // Email lands on a phone or laptop screen, so it gets the
                    // colour book for the same reason the Desktop copy does.
                    article: article, book: colorBook ?? eInkBook,
                    images: images, rendered: rendered
                )
            )
        }

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
            deliveries: deliveries,
            archiveFolder: archiveFolder
        )
    }

    // MARK: - Destinations

    /// Writes the EPUB where the user can see it. Unlike the mail
    /// destinations there is no network involved, so this is synchronous.
    private func saveToDesktop(book: EPUBBuilder.Result) -> DeliveryResult {
        let exporter: DesktopExporter
        do {
            exporter = try desktopExporter ?? DesktopExporter(folder: DesktopExporter.defaultFolder())
        } catch {
            return DeliveryResult(
                kind: .desktop,
                recipients: [],
                errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        do {
            let saved = try exporter.save(book.data, fileName: book.fileName)
            // The path rides along in `recipients` so the popover can show and
            // reveal exactly which file was written.
            return DeliveryResult(kind: .desktop, recipients: [saved.url.path], errorMessage: nil)
        } catch {
            return DeliveryResult(
                kind: .desktop,
                recipients: [],
                errorMessage: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return DeliveryResult(kind: kind, recipients: recipients, errorMessage: message)
        }
    }
}
