import AppKit
import SwiftUI
import LittleSendCore

/// The first-run setup: a few short steps from nothing to a working send.
///
/// A window of its own rather than part of the panel. Setup means going off
/// to Amazon and Google to copy things, and a popover closes the moment you
/// click away; this stays put. Every field saves as it is typed, as in
/// Settings, so closing it early keeps whatever was filled in.
@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    static let shared = SetupWindow()

    /// What happens after the last step — opening the panel, set by the app
    /// delegate so setup can hand over to the app.
    var onFinish: () -> Void = {}

    private var window: NSWindow?

    func show(preferences: Preferences) {
        let window = self.window ?? makeWindow(preferences: preferences)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(preferences: Preferences) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up LittleSend"
        window.contentViewController = NSHostingController(
            rootView: SetupView(preferences: preferences) { [weak self] in self?.finish() }
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Not minimizable or resizable: those buttons would be grey dots.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        return window
    }

    private func finish() {
        window?.close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct SetupView: View {
    @ObservedObject var preferences: Preferences
    var onFinish: () -> Void

    @State private var draft = SettingsDraft()
    @State private var step: Step = .kindle
    @State private var copied = false

    enum Step: Int, CaseIterable {
        case kindle, mail, approve, reader, done
    }

    private static let amazonSettings = URL(string: "https://www.amazon.com/mycd")!
    private static let gmailAppPasswords = URL(string: "https://myaccount.google.com/apppasswords")!
    private static let instaparser = URL(string: "https://www.instaparser.com")!

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .kindle: kindleStep
                case .mail: mailStep
                case .approve: approveStep
                case .reader: readerStep
                case .done: doneStep
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            buttons
                .padding(16)
        }
        .frame(width: 560, height: 470)
        // Saved as typed, like Settings; the draft stays here so storing,
        // which trims, never rewrites the field mid-word.
        .onAppear { draft = preferences.draft }
        .onChange(of: draft) { _, edited in preferences.apply(edited) }
        // Opened from Settings, setup can sit beside it: take in anything
        // changed there, or the next keystroke here would put old values back.
        .onChange(of: preferences.draft) { _, stored in
            if stored != draft.normalized { draft = stored }
        }
        // The username is the email address for Gmail and most others, so it
        // follows the From address until it is changed by hand.
        .onChange(of: draft.fromAddress) { old, new in
            if draft.smtpUsername.isEmpty || draft.smtpUsername == old {
                draft.smtpUsername = new
            }
        }
        // A key means wanting Instaparser; no key, the built-in reader.
        .onChange(of: draft.instaparserAPIKey) { _, key in
            draft.articleReader = key.trimmingCharacters(in: .whitespaces).isEmpty ? .local : .instaparser
        }
    }

    // MARK: - Steps

    private var kindleStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("books.vertical.fill", .blue, "Where should articles go?",
                    "LittleSend emails articles to your Kindle. Each Kindle has its own email address.")

            TextField("yourname@kindle.com", text: $draft.kindleAddress)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

            note("Find it on Amazon under Manage Your Content and Devices → Preferences → Personal Document Settings.")
            Link("Open Amazon", destination: Self.amazonSettings)
                .font(.appLabel)

            if !draft.kindleAddress.isEmpty, !kindleValid {
                warning("That isn't a valid email address.")
            }
            Spacer()
            note("No Kindle? Skip this. You can still email articles or save them to your Desktop.")
        }
    }

    private var mailStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("envelope.fill", .teal, "Which email sends them?",
                    "LittleSend sends from your own email, so Amazon knows it's you. Gmail works best.")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Your email").gridColumnAlignment(.trailing)
                    TextField("you@gmail.com", text: $draft.fromAddress)
                }
                GridRow {
                    Text("App password")
                    SecureField("16 letters", text: $draft.smtpPassword)
                }
                GridRow {
                    Text("Mail server")
                    HStack {
                        TextField("smtp.gmail.com", text: $draft.smtpHost)
                        Text("Port").foregroundStyle(.secondary)
                        TextField("465", value: $draft.smtpPort, format: .number.grouping(.never))
                            .frame(width: 56)
                    }
                }
                GridRow {
                    Text("Username")
                    TextField("you@gmail.com", text: $draft.smtpUsername)
                }
            }
            .textFieldStyle(.roundedBorder)

            note("Gmail needs an app password, not your usual one. Turn on 2-Step Verification, then make an app password and paste it here.")
            Link("Make a Gmail app password", destination: Self.gmailAppPasswords)
                .font(.appLabel)

            if !draft.fromAddress.isEmpty, !SendConfiguration.looksLikeEmail(draft.fromAddress) {
                warning("That isn't a valid email address.")
            }
        }
    }

    private var approveStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("checkmark.shield.fill", .green, "Let Amazon accept your sends",
                    "Amazon only takes documents from addresses you approve.")

            Text("Add **\(trimmed(draft.fromAddress))** to your Approved Personal Document E-mail List on Amazon.")
                .font(.appBody)
            note("It's on the same page as your Kindle address. If you skip this, Amazon drops your sends without telling you.")

            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(trimmed(draft.fromAddress), forType: .string)
                    copied = true
                }
                Link("Open Amazon", destination: Self.amazonSettings)
            }
        }
    }

    private var readerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("bolt.fill", .orange, "Want faster reading?",
                    "LittleSend reads each article itself in a few seconds. With Instaparser it takes under a second.")

            SecureField("Instaparser API key (optional)", text: $draft.instaparserAPIKey)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)

            note("Instaparser's free plan covers 1,000 articles a month. It sees each link you send.")
            Link("Get a free key", destination: Self.instaparser)
                .font(.appLabel)
            Spacer()
            note("Not sure? Skip this. You can add a key later in Settings → Reading.")
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("paperplane.fill", .blue, "You're all set",
                    kindleValid
                        ? "Copy a link, open LittleSend, and press Send."
                        : "Articles will save to your Desktop. Add a Kindle or email addresses anytime in Settings.")

            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Kindle", kindleValid ? trimmed(draft.kindleAddress) : "Not set")
                summaryRow("Sends from", mailReady ? trimmed(draft.fromAddress) : "Not set")
                summaryRow("Desktop", draft.saveToDesktop ? "Saves a copy" : "Off")
                summaryRow("Reader", draft.articleReader == .instaparser ? "Instaparser" : "Built-in reader")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            note("Change any of this later in Settings.")
        }
        // With no Kindle there is nowhere to send to — no email addresses are
        // added here — so a Desktop copy is the destination, or Send would
        // have nothing to do on the very first try.
        .onAppear {
            if !kindleValid { draft.saveToDesktop = true }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            stepDots
            Spacer()
            if step != .kindle, step != .done {
                Button("Back") { move(by: -1) }
            }
            if canSkip {
                Button("Skip") { move(by: 1) }
            }
            Button(step == .done ? "Start Using LittleSend" : "Continue") {
                if step == .done {
                    preferences.markSetupFinished()
                    onFinish()
                } else {
                    move(by: 1)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(visibleSteps, id: \.self) { each in
                Circle()
                    .fill(each == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \((visibleSteps.firstIndex(of: step) ?? 0) + 1) of \(visibleSteps.count)")
    }

    // MARK: - Rules

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kindleValid: Bool {
        SendConfiguration.looksLikeEmail(trimmed(draft.kindleAddress))
    }

    private var mailReady: Bool {
        SendConfiguration.looksLikeEmail(trimmed(draft.fromAddress))
            && !trimmed(draft.smtpHost).isEmpty
            && !trimmed(draft.smtpUsername).isEmpty
            && !trimmed(draft.smtpPassword).isEmpty
    }

    /// Approving the sender only matters when there is both a Kindle and a
    /// sender to approve.
    private var visibleSteps: [Step] {
        Step.allCases.filter { $0 != .approve || (kindleValid && mailReady) }
    }

    private var canContinue: Bool {
        switch step {
        case .kindle: return kindleValid
        case .mail: return mailReady
        case .approve, .reader, .done: return true
        }
    }

    /// The Kindle is optional, and so is email when there is no Kindle to
    /// send to — Desktop copies need neither. Instaparser is always optional.
    private var canSkip: Bool {
        switch step {
        case .kindle: return trimmed(draft.kindleAddress).isEmpty
        case .mail: return !kindleValid
        case .reader: return true
        case .approve, .done: return false
        }
    }

    private func move(by offset: Int) {
        let steps = visibleSteps
        guard let index = steps.firstIndex(of: step) else {
            step = .kindle
            return
        }
        let target = index + offset
        guard steps.indices.contains(target) else { return }
        copied = false
        step = steps[target]
    }

    // MARK: - Pieces

    private func heading(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.appBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.appLabel)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.appLabel)
            .foregroundStyle(.orange)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
        }
        .font(.appBody)
    }
}
