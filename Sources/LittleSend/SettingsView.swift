import SwiftUI
import LittleSendCore

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    @State private var draft = SettingsDraft()
    @State private var signedOut = false
    @State private var status: Status?
    @State private var selectedAddress: String?
    @State private var newAddressText = ""

    private enum Status: Equatable {
        case saved
    }

    /// Enumerated once per window rather than on every redraw — there are a
    /// couple of hundred families and the list cannot change while Settings is
    /// open in any way worth chasing.
    private let installedFontFamilies = CoverFont.availableFamilies()

    /// A chosen family can be uninstalled later, and the default one may never
    /// have been installed at all. Either way the cover silently falls back, so
    /// say so here rather than letting the next cover come out wrong.
    private var coverFontWarning: String? {
        let chosen = draft.coverFontFamily.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty, !CoverFont.isAvailable(family: chosen) else { return nil }
        return "\(chosen) is not installed — covers will use Georgia instead."
    }

    /// Nothing to save until something actually differs from what is stored.
    private var hasChanges: Bool {
        draft.normalized != preferences.draft.normalized
    }

    var body: some View {
        VStack(spacing: 0) {
            // Four tabs rather than one long scroll. The form had grown to
            // seven sections spanning addresses, mail credentials, cover art
            // and image limits — unrelated things that only shared a window.
            TabView {
                destinationsTab
                    .tabItem { Label("Destinations", systemImage: "paperplane") }
                accountTab
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                coverTab
                    .tabItem { Label("Cover", systemImage: "book.closed") }
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
            }
            .frame(maxHeight: .infinity)

            // Save and Revert stay outside the tabs: the draft is one value, so
            // an edit on any tab is part of the same unsaved change.
            Divider()
            footer
        }
        .frame(width: 600, height: 650)
        .onAppear { revert() }
        // Clear a stale "Saved" note as soon as the user edits again.
        .onChange(of: draft) { _, _ in
            if status == .saved { status = nil }
        }
    }

    // MARK: - Where things go

    private var destinationsTab: some View {
        Form {
            Section("Kindle") {
                TextField("Send to Kindle address", text: $draft.kindleAddress)
                Text("Found under Manage Your Content and Devices → Preferences → Personal Document Settings. Whether Kindle is actually sent to is chosen in the menu bar, not here.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Email addresses") {
                emailAddressTable

                HStack {
                    TextField(
                        "Add address",
                        text: $newAddressText,
                        prompt: Text("someone@example.com")
                    )
                    .onSubmit(addAddress)

                    Button("Add", action: addAddress)
                        .disabled(newAddressText.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button {
                        guard let selectedAddress else { return }
                        draft.removeEmailAddress(selectedAddress)
                        self.selectedAddress = nil
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedAddress == nil)
                }

                if let malformed = newAddressWarning {
                    Label(malformed, systemImage: "exclamationmark.triangle.fill")
                        .font(.appLabel)
                        .foregroundStyle(.orange)
                }

                Text("This is the address book the menu bar's Email picker draws from — adding one here doesn't send anything by itself. Which addresses actually receive a send, and whether Kindle or Email are on at all, is chosen from the menu bar.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Email messages") {
                Toggle("Embed images in the message", isOn: $draft.embedImagesInEmail)
                    .disabled(draft.emailRecipients.isEmpty)

                Toggle("Also attach the EPUB", isOn: $draft.attachBookToEmail)
                    .disabled(draft.emailRecipients.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials

    private var accountTab: some View {
        Form {
            Section("Sender") {
                TextField("From address", text: $draft.fromAddress)
                Text("This address must be on your Approved Personal Document E-mail List, or Amazon silently drops the message.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Outgoing mail") {
                TextField("SMTP server", text: $draft.smtpHost)
                TextField("Port", value: $draft.smtpPort, format: .number.grouping(.never))
                TextField("Username", text: $draft.smtpUsername)
                SecureField("Password", text: $draft.smtpPassword)
                Text("Gmail requires an app password with 2-Step Verification on. The connection is TLS from the first byte, so use an implicit-TLS port such as 465.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section {
                Label(
                    "The mail password and Instaparser API key are saved in this app's preferences file in plain text, not the Keychain.",
                    systemImage: "info.circle"
                )
                .font(.appLabel)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cover art

    private var coverTab: some View {
        Form {
            Section("Layout") {
                CoverLayoutGallery(
                    selection: $draft.coverLayout,
                    fontFamily: draft.coverFontFamily,
                    eInk: draft.optimizeCoverForEInk
                )
                .frame(maxWidth: .infinity)

                Text(draft.coverLayout.summary)
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Type") {
                Picker("Cover font", selection: $draft.coverFontFamily) {
                    Text(CoverFont.systemFamilyLabel).tag("")
                    Divider()
                    ForEach(installedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                if let warning = coverFontWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.appLabel)
                        .foregroundStyle(.orange)
                }

                Text("The cover is drawn here and sent as an image, so any font on this Mac works — nothing has to exist on the Kindle. The article text carries no fonts at all and follows your Kindle's own font settings.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Rendering") {
                Picker("Size", selection: $draft.coverSize) {
                    ForEach(CoverSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                }

                Text(draft.coverSize.summary)
                    .font(.appLabel)
                    .foregroundStyle(.secondary)

                Toggle("Optimize Kindle covers for e-ink", isOn: $draft.optimizeCoverForEInk)

                Text("Kindle gets a dark-on-paper cover in the panel's own 16 grey levels. Desktop and email keep the colour version, since those are read on colour screens. Nothing detects your device, so pick the size yourself.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Everything else

    private var generalTab: some View {
        Form {
            Section("Reading articles") {
                Picker("Read articles with", selection: $draft.articleReader) {
                    ForEach(ArticleReader.allCases, id: \.self) { reader in
                        Text(reader.displayName).tag(reader)
                    }
                }
                .pickerStyle(.radioGroup)

                if draft.articleReader == .instaparser {
                    SecureField("Instaparser API key", text: $draft.instaparserAPIKey)
                    Link("Get a free API key", destination: URL(string: "https://www.instaparser.com")!)
                        .font(.appLabel)
                }

                Text(readerNote)
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Paywalls") {
                HStack {
                    Button("Sign In to a Site…") { SiteSignInWindow.shared.show() }
                    Spacer()
                    Button("Sign Out of All Sites") {
                        Task {
                            await SiteSignInWindow.signOutOfAllSites()
                            signedOut = true
                        }
                    }
                }
                Text(signedOut ? "Signed out of all sites." : "Pay for a site? Sign in here once to get full articles. LittleSend can't use Safari's sign-ins.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("App icon") {
                Picker("Show LittleSend in", selection: $draft.iconPlacement) {
                    ForEach(IconPlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.radioGroup)

                Text("With the menu bar icon, click it or drop a file on it to open LittleSend. With the Dock icon, click it — and LittleSend's own menus appear in the menu bar while it is in use. Menu bar only keeps it out of the Dock and the ⌘Tab switcher, which also means no LittleSend menus at the top of the screen.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("When the panel opens") {
                Picker("Fill the URL from", selection: $draft.browserSource) {
                    ForEach(BrowserSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                }

                Text("Reading a browser tab needs macOS Automation permission — the first attempt asks, and the answer is remembered under System Settings → Privacy & Security → Automation. Only browsers already running are asked, so this never opens one. The clipboard is used when the browser has nothing to offer.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Play sounds", isOn: $draft.playSounds)
                Text("A soft chime when a send lands, and a low one if it didn't.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            Section("Images") {
                Toggle("Embed images in the EPUB", isOn: $draft.embedImages)

                Toggle("Shrink large images", isOn: $draft.limitImageSize)
                    .disabled(!draft.embedImages)

                LabeledContent("Maximum size") {
                    HStack(spacing: 4) {
                        TextField(
                            "size",
                            value: $draft.maxImageKilobytes,
                            format: .number.grouping(.never)
                        )
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        Text("KB")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!draft.embedImages || !draft.limitImageSize)

                Text("Images above this are re-encoded to fit — quality first, then resolution. Each one links back to the full-resolution original. Only affects the EPUB; emailed articles reference images at their source.")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusLabel
            Spacer()
            Button("Revert", action: revert)
                .disabled(!hasChanges)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// `Table` requires `Identifiable` rows; addresses are unique after
    /// normalization, so the address itself is a perfectly good id.
    private struct AddressRow: Identifiable, Hashable {
        var address: String
        var id: String { address }
    }

    /// The actual system table type, not a hand-rolled list — add/remove sit
    /// in a toolbar below it, the standard macOS pattern for an editable
    /// address book (Login Items, Mail's blocked-senders list, and so on).
    private var readerNote: String {
        switch draft.articleReader {
        case .local:
            return "Reads articles on this Mac. It's free and private, and it reads every page of long articles."
        case .instaparser:
            return "Much faster, usually under a second. The free plan covers 1,000 articles a month. Instaparser sees each link you send. If it can't read one, LittleSend reads it on this Mac instead."
        }
    }

    private var emailAddressTable: some View {
        Table(draft.emailRecipients.map(AddressRow.init), selection: $selectedAddress) {
            TableColumn("Address") { row in
                Text(row.address)
            }
        }
        .frame(minHeight: 90, maxHeight: 140)
    }

    /// Validates what's currently typed in the "Add" field before it's
    /// actually added, so a typo is visible immediately rather than only
    /// after it silently becomes an unselectable row.
    private var newAddressWarning: String? {
        let candidates = SettingsDraft.parseRecipients(newAddressText)
        let malformed = candidates.filter { !SendConfiguration.looksLikeEmail($0) }
        guard !malformed.isEmpty else { return nil }
        return "Not a valid address: \(malformed.joined(separator: ", "))"
    }

    private func addAddress() {
        guard newAddressWarning == nil else { return }
        draft.addEmailAddresses(from: newAddressText)
        newAddressText = ""
    }

    @ViewBuilder
    private var statusLabel: some View {
        let problems = draft.settingsProblems

        if hasChanges {
            Label("Unsaved changes", systemImage: "pencil.circle")
                .font(.appLabel)
                .foregroundStyle(.secondary)
        } else if status == .saved {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.appLabel)
                .foregroundStyle(.green)
        } else if !problems.isEmpty {
            // Saved, but still not enough to send anything.
            Label("\(problems.count) item\(problems.count == 1 ? "" : "s") still needed", systemImage: "exclamationmark.circle")
                .font(.appLabel)
                .foregroundStyle(.orange)
                .help(problems.joined(separator: "\n"))
        }
    }

    private func save() {
        preferences.apply(draft)
        status = .saved
        // Re-read so the fields show exactly what was stored (trimmed values).
        draft = preferences.draft
    }

    private func revert() {
        draft = preferences.draft
        status = nil
        selectedAddress = nil
    }
}
