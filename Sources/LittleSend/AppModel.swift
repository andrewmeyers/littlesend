import Foundation
import AppKit
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
    /// Set when the hosted parser failed on a URL and the local reader has not
    /// been tried for it yet — drives the "Try local reader" button.
    @Published private(set) var localRetryURL: URL?
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
    func prefillFromPasteboard() {
        guard urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let contents = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.normalizedURL(from: trimmed) != nil else { return }
        urlText = trimmed
    }

    func send() {
        guard !isSending else { return }

        let raw = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.normalizedURL(from: raw) else {
            banner = Banner(kind: .failure, message: "That does not look like a web address.")
            return
        }
        start(url: url, using: .instaparser)
    }

    /// Re-runs the failed URL through the local reader. Manual by design: it
    /// loads the page in a real web view, which is slow, so it happens only
    /// when asked for.
    func retryLocally() {
        guard !isSending, let url = localRetryURL else { return }
        start(url: url, using: .localReader)
    }

    private func start(url: URL, using parser: ArticleParserChoice) {
        let problems = preferences.configuration.validationProblems
        guard problems.isEmpty else {
            banner = Banner(kind: .failure, message: problems.joined(separator: " "))
            return
        }

        isSending = true
        banner = nil
        localRetryURL = nil
        stageDescription = (parser == .localReader ? SendStage.parsingLocally : SendStage.parsing).rawValue

        let configuration = preferences.configuration
        Task {
            let sender = ArticleSender(configuration: configuration, archive: self.archive)
            do {
                let outcome = try await sender.send(url: url, using: parser) { stage in
                    Task { @MainActor in self.stageDescription = stage.rawValue }
                }
                self.finish(success: outcome, url: url)
            } catch {
                self.finish(failure: error, url: url, parser: parser)
            }
        }
    }

    private func finish(success outcome: SendOutcome, url: URL) {
        isSending = false
        stageDescription = ""
        urlText = ""

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
        if outcome.usedTextFallback { notes.append("text-only fallback") }

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
                message: "\(failure.kind.rawValue) delivery failed: \(failure.errorMessage ?? "unknown error")"
            )
        } else if outcome.usedFallbackFont {
            banner = Banner(
                kind: .warning,
                message: "Sent, but the cover font was not found — the cover used Georgia."
            )
        } else {
            banner = Banner(
                kind: .success,
                message: "Sent “\(outcome.title)” to \(Self.destinationSummary(for: outcome))."
            )
        }
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

    private func finish(failure error: Error, url: URL, parser: ArticleParserChoice) {
        isSending = false
        stageDescription = ""

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // Offer the local reader only when the hosted parser was the thing
        // that failed. A delivery failure, or the local reader failing in
        // turn, would not be helped by trying it (again).
        localRetryURL = (parser == .instaparser && error is InstaparserError) ? url : nil
        history.insert(
            HistoryEntry(
                title: url.host ?? url.absoluteString,
                url: url.absoluteString,
                date: Date(),
                state: .failed(message: message),
                archiveFolder: nil
            ),
            at: 0
        )
        history = Array(history.prefix(SendArchive.keepCount))
        banner = Banner(kind: .failure, message: message)
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
