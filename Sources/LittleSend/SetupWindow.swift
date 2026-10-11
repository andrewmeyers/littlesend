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
    @State private var provider: MailProvider = .gmail

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
        .onAppear {
            draft = preferences.draft
            provider = MailProvider.detect(host: draft.smtpHost)
        }
        .onChange(of: draft) { _, edited in preferences.apply(edited) }
        // Picking a provider fills in its server and port.
        .onChange(of: provider) { _, chosen in
            if chosen.isSupported, let server = chosen.server {
                draft.smtpHost = server
                draft.smtpPort = Int(chosen.port)
            } else if chosen == .other, MailProvider.detect(host: draft.smtpHost) != .other {
                // Leaving a preset for "another provider": start the server
                // blank rather than showing the old provider's.
                draft.smtpHost = ""
                draft.smtpPort = 465
            }
        }
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
                    "LittleSend sends from your own email, so Amazon knows it's you.")

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Provider").gridColumnAlignment(.trailing)
                    Picker("Provider", selection: $provider) {
                        ForEach(MailProvider.allCases) { each in
                            Text(each.displayName).tag(each)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .leading)
                }

                if provider.isSupported {
                    GridRow {
                        Text("Your email")
                        TextField("you@example.com", text: $draft.fromAddress)
                    }
                    GridRow {
                        Text("App password")
                        SecureField("Paste it here", text: $draft.smtpPassword)
                    }
                    if provider == .other {
                        GridRow {
                            Text("Mail server")
                            HStack {
                                TextField("smtp.example.com", text: $draft.smtpHost)
                                Text("Port").foregroundStyle(.secondary)
                                TextField("465", value: $draft.smtpPort, format: .number.grouping(.never))
                                    .frame(width: 56)
                            }
                        }
                        GridRow {
                            Text("Username")
                            TextField("Usually your email", text: $draft.smtpUsername)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if provider.isSupported {
                note(provider.passwordNote)
                if let title = provider.passwordGuideTitle, let guide = provider.passwordGuide {
                    Link(title, destination: guide)
                        .font(.appLabel)
                }
                if provider == .other, [587, 25, 2525].contains(draft.smtpPort) {
                    warning("Port \(draft.smtpPort) doesn't work yet. Use 465 if your provider has it.")
                }
                if !draft.fromAddress.isEmpty, !SendConfiguration.looksLikeEmail(draft.fromAddress) {
                    warning("That isn't a valid email address.")
                }
            } else {
                unsupportedPanel
            }
        }
    }

    /// For iCloud and Outlook.com: say why, and give a way forward.
    private var unsupportedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(provider.unsupportedNote, systemImage: "info.circle.fill")
                .font(.appBody)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Link("Make a free Gmail account", destination: MailProvider.freeGmailSignup)
                Button("I Have One") { provider = .gmail }
            }
            note("Not now? Skip this. Articles will save to your Desktop until email is set up.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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
                    finishSubtitle)

            VStack(alignment: .leading, spacing: 8) {
                summaryRow("Kindle", kindleValid ? trimmed(draft.kindleAddress) : "Not set")
                summaryRow("Sends from", mailReady ? trimmed(draft.fromAddress) : "Not set")
                summaryRow("Desktop", desktopOn ? "Saves a copy" : "Off")
                summaryRow("Reader", draft.articleReader == .instaparser ? "Instaparser" : "Built-in reader")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            note("Change any of this later in Settings.")
        }
        // What was skipped decides where sends go: with no Kindle, or no way
        // to mail one, Kindle goes off and a Desktop copy goes on, or the very
        // first Send would be refused. Applied here so Back and forward again
        // re-decides from what is filled in now.
        .onAppear {
            draft.chooseDestinationsAfterSetup(firstRun: !preferences.setupFinished)
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
        provider.isSupported && draft.canSendMail
    }

    /// Says only what is still missing.
    private var finishSubtitle: String {
        if canSendToKindle { return "Copy a link, open LittleSend, and press Send." }
        if kindleValid { return "Articles will save to your Desktop. Add your email in Settings to send to your Kindle too." }
        return "Articles will save to your Desktop. Add your Kindle and email in Settings to send there too."
    }

    /// What the finish screen reports, matching what will actually be used.
    private var canSendToKindle: Bool { kindleValid && mailReady }

    private var desktopOn: Bool {
        var preview = draft
        preview.chooseDestinationsAfterSetup(firstRun: !preferences.setupFinished)
        return preview.saveToDesktop
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

    /// The Kindle is optional, and so is email — a Desktop copy needs neither,
    /// and someone without a usable email account still gets that. Instaparser
    /// is always optional.
    private var canSkip: Bool {
        switch step {
        case .kindle: return trimmed(draft.kindleAddress).isEmpty
        case .mail, .reader: return true
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
