import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine
import LittleSendCore

/// One row in the recent-sends list.
struct HistoryEntry: Identifiable, Equatable {
    enum State: Equatable {
        case succeeded(detail: String)
        case failed(message: String)
    }

    let id = UUID()
    let title: String
    let url: String
    let date: Date
    let state: State
    /// Folder holding this send's files, while it is still one of the most recent.
    let archiveFolder: URL?

    var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

}

@MainActor
final class AppModel: ObservableObject {
    @Published var urlText = ""
    @Published var isSending = false
    @Published var stageDescription = ""
    @Published var banner: Banner?
    /// A file staged for sending. Attaching does not send: the Send button is
    /// still the thing that commits, the same as it is for a URL.
    @Published private(set) var attachedFile: URL?
    /// Where the current or most recent send stands. The menu bar icon follows
    /// this, which matters most when the panel is closed and it is the only
    /// sign that a send happened at all.
    @Published private(set) var activity: Activity = .idle
    /// Bumped when the URL field should take focus — the panel is reused, so
    /// `onAppear` fires once and cannot do it on every reopen.
    @Published private(set) var focusRequest = 0

    enum Activity: Equatable {
        case idle, sending, succeeded, failed
    }
    @Published private(set) var history: [HistoryEntry] = []

    struct Banner: Equatable {
        enum Kind { case success, failure, warning }
        let kind: Kind
        let message: String
    }

    let preferences: Preferences
    let archive: SendArchive?

    init(preferences: Preferences) {
        self.preferences = preferences
        // Archiving is best effort; the app works fine without it.
        self.archive = (try? SendArchive.defaultRoot()).map { SendArchive(root: $0) }
    }

    /// Pulls a URL off the pasteboard when the field is empty, so the common
    /// path is "copy link, open menu, hit Send".
    /// Fills the field when the panel opens: the front browser's tab if that is
    /// switched on, and the clipboard otherwise or if the browser has nothing.
    func prefill() {
        // A staged file owns the input; filling the URL behind it would put two
        // things in play at once.
        guard attachedFile == nil else { return }
        guard urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let source = preferences.browserSource
        guard source != .off else {
            prefillFromPasteboard()
            return
        }
        fill(from: source, fallingBackToClipboard: true)
    }

    /// The explicit "read my browser" action. Works even when the setting is
    /// off, because a click is exactly the moment a permission prompt belongs.
    func grabFromBrowser() {
        let source = preferences.browserSource
        fill(from: source == .off ? .automatic : source, fallingBackToClipboard: false)
    }

    private func fill(from source: BrowserSource, fallingBackToClipboard: Bool) {
        Task {
            switch await BrowserURLReader.currentURL(from: source) {
            case .found(let url):
                attachedFile = nil
                urlText = url.absoluteString
                banner = nil
            case .denied(let browser):
                banner = Banner(
                    kind: .warning,
                    message: "LittleSend can't read \(browser). Allow it in System Settings → "
                        + "Privacy & Security → Automation."
                )
                if fallingBackToClipboard { prefillFromPasteboard() }
            case .nothing:
                if fallingBackToClipboard {
                    prefillFromPasteboard()
                } else {
                    banner = Banner(
                        kind: .warning,
                        message: "No web page is open in your browser."
                    )
                }
            }
        }
    }

    func requestFocus() {
        focusRequest += 1
    }

    func prefillFromPasteboard() {
        guard urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let contents = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.normalizedURL(from: trimmed) != nil else { return }
        urlText = trimmed
    }

    /// Whether there is anything to send — a staged file, or a URL typed in.
    var canSend: Bool {
        guard !isSending else { return false }
        if attachedFile != nil { return true }
        return !urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Stages a file. A staged file takes precedence over the URL field, which
    /// the UI disables while one is attached so there is no question which of
    /// the two Send will act on.
    func attachFile(at fileURL: URL) {
        guard !isSending else { return }
        attachedFile = fileURL
        // The two inputs are exclusive, so staging a file empties the field
        // rather than leaving a URL sitting there looking like it still counts.
        urlText = ""
        banner = nil
    }

    func clearAttachedFile() {
        attachedFile = nil
    }

    func send() {
        guard !isSending else { return }

        if let file = attachedFile {
            sendFile(at: file)
            return
        }

        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.normalizedURL(from: raw) else {
            banner = Banner(kind: .failure, message: "That isn't a web address.")
            return
        }
        start(url: url)
    }

    /// Opens a file chooser and sends whatever is picked.
    ///
    /// Opened from the menu bar icon, the app may not be active, so it is
    /// activated first or the panel opens behind everything.
    func chooseFile() {
        guard !isSending else { return }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Send"
        panel.message = "Choose a file to send to your Kindle"
        panel.directoryURL = try? DesktopExporter.defaultFolder()
        // Only what Kindle can actually take, so an unsupported file is not
        // selectable rather than being refused after the fact.
        panel.allowedContentTypes = FileAttachment.kindleExtensions
            .compactMap { UTType(filenameExtension: $0) }

        // The menu bar window dismisses the moment the app resigns key, and
        // opening a panel does exactly that — so the panel cannot depend on the
        // popover still being there. `runModal()` additionally blocks the main
        // thread while that teardown runs, which is how the panel ended up not
        // appearing; `begin` is modeless and survives it.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.attachFile(at: url) }
        }
        panel.orderFrontRegardless()
    }

    /// Sends a staged file as-is to Kindle — no parsing, no EPUB, no cover.
    private func sendFile(at fileURL: URL) {
        guard !isSending else { return }

        isSending = true
        banner = nil
        activity = .sending
        stageDescription = SendStage.readingFile.rawValue

        let configuration = preferences.configuration
        let displayName = fileURL.lastPathComponent
        Task {
            let sender = ArticleSender(configuration: configuration, archive: self.archive)
            do {
                let outcome = try await sender.send(file: fileURL) { stage in
                    Task { @MainActor in self.stageDescription = stage.rawValue }
                }
                self.finish(success: outcome, url: fileURL)
            } catch {
                self.finish(
                    failure: error, url: fileURL, title: displayName
                )
            }
        }
    }

    private func start(url: URL) {
        let problems = preferences.configuration.validationProblems
        guard problems.isEmpty else {
            banner = Banner(kind: .failure, message: problems.joined(separator: " "))
            return
        }

        isSending = true
        banner = nil
        activity = .sending
        stageDescription = SendStage.parsing.rawValue

        let configuration = preferences.configuration
        Task {
            let sender = ArticleSender(configuration: configuration, archive: self.archive)
            do {
                let outcome = try await sender.send(url: url, onPage: { page in
                    Task { @MainActor in self.stageDescription = "Reading page \(page)…" }
                }) { stage in
                    Task { @MainActor in self.stageDescription = stage.rawValue }
                }
                self.finish(success: outcome, url: url)
            } catch {
                self.finish(failure: error, url: url)
            }
        }
    }

    private func finish(success outcome: SendOutcome, url: URL) {
        isSending = false
        stageDescription = ""
        urlText = ""
        attachedFile = nil

        var notes: [String] = []
        notes.append(Self.destinationSummary(for: outcome))
        if let byteCount = outcome.byteCount {
            notes.append(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
        }
        if outcome.embeddedImageCount > 0 {
            var images = "\(outcome.embeddedImageCount) image\(outcome.embeddedImageCount == 1 ? "" : "s")"
            if outcome.resizedImageCount > 0 { images += " (\(outcome.resizedImageCount) shrunk)" }
            notes.append(images)
        }
        if outcome.pageCount > 1 { notes.append("\(outcome.pageCount) pages") }
        if outcome.usedTextFallback { notes.append("text-only fallback") }
        if outcome.readerNote != nil { notes.append("read on this Mac") }
        if outcome.isPreview { notes.append("paywall: part only") }

        let partialFailures = outcome.failures
        history.insert(
            HistoryEntry(
                title: outcome.title,
                url: url.absoluteString,
                date: Date(),
                state: partialFailures.isEmpty
                    ? .succeeded(detail: notes.joined(separator: " · "))
                    : .failed(message: partialFailures
                        .map { "\($0.kind.rawValue) failed: \($0.errorMessage ?? "unknown error")" }
                        .joined(separator: " ")),
                archiveFolder: outcome.archiveFolder
            ),
            at: 0
        )
        history = Array(history.prefix(SendArchive.keepCount))

        if let failure = partialFailures.first {
            // Something did get through, so this is a warning, not an error.
            banner = Banner(
                kind: .warning,
                message: "\(failure.kind.rawValue) failed: \(failure.errorMessage ?? "unknown error")"
            )
        } else if !warnings(for: outcome).isEmpty {
            // Delivered, but not quite as asked: worth saying out loud.
            banner = Banner(
                kind: .warning,
                message: (["Sent."] + warnings(for: outcome)).joined(separator: " ")
            )
        } else {
            banner = Banner(
                kind: .success,
                message: SendCopy.success(
                    title: outcome.title,
                    destination: Self.destinationSummary(for: outcome),
                    minutes: outcome.wordCount.map(ReadingTime.minutes(forWords:))
                )
            )
        }

        // A partial failure still got something through, but it is not the
        // outcome that was asked for, so it gets the low sound and the icon's
        // attention state rather than the chime.
        let clean = partialFailures.isEmpty
        activity = clean ? .succeeded : .failed
        playSound(clean ? .success : .failure)
    }

    /// What went less than right in a send that still got through.
    private func warnings(for outcome: SendOutcome) -> [String] {
        var warnings: [String] = []
        if outcome.isPreview {
            // A paywall's preview was all the reader could see, and that is
            // what was sent. Saying so beats a short book that looks complete.
            let site = outcome.siteName ?? "This site"
            warnings.append("Only part of it came through. \(site) has a paywall.")
            warnings.append("Subscribers can sign in under Settings → General.")
        }
        // Instaparser was chosen but not used. Only worth interrupting for
        // when there is something to fix; "couldn't read this page" is not.
        if outcome.readerNoteNeedsAttention, let note = outcome.readerNote { warnings.append(note) }
        if outcome.usedFallbackFont { warnings.append("The cover font was missing, so it used Georgia.") }
        return warnings
    }

    /// "your Kindle and 2 recipients", for the banner and the history row.
    static func destinationSummary(for outcome: SendOutcome) -> String {
        var parts: [String] = []
        for delivery in outcome.successes {
            switch delivery.kind {
            case .kindle:
                parts.append("your Kindle")
            case .email:
                let count = delivery.recipients.count
                parts.append(count == 1 ? delivery.recipients[0] : "\(count) recipients")
            case .desktop:
                parts.append("your Desktop")
            }
        }
        guard !parts.isEmpty else { return "nowhere" }
        guard parts.count > 1 else { return parts[0] }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    private func finish(
        failure error: Error, url: URL, title: String? = nil
    ) {
        isSending = false
        stageDescription = ""

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        history.insert(
            HistoryEntry(
                title: title ?? url.host ?? url.absoluteString,
                url: url.absoluteString,
                date: Date(),
                state: .failed(message: message),
                archiveFolder: nil
            ),
            at: 0
        )
        history = Array(history.prefix(SendArchive.keepCount))
        banner = Banner(kind: .failure, message: message)
        activity = .failed
        playSound(.failure)
    }

    // MARK: - Feedback

    private enum Chime { case success, failure }

    /// Stock system sounds: Glass is the soft, bright one; Basso the low one
    /// macOS already uses for "that didn't work". Nothing bundled, nothing new
    /// to learn.
    private func playSound(_ chime: Chime) {
        guard preferences.playSounds else { return }
        NSSound(named: chime == .success ? "Glass" : "Basso")?.play()
    }

    /// Called once the icon has shown a result for long enough.
    func acknowledgeActivity() {
        if activity != .sending { activity = .idle }
    }

    /// Accepts input with or without a scheme, rejecting anything that is not
    /// plausibly an http(s) address.
    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.contains(".")
        else { return nil }
        return url
    }
}
