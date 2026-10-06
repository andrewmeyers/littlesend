import SwiftUI
import LittleSendCore

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    @State private var draft = SettingsDraft()
    @State private var signedOut = false
    @State private var status: Status?
    @State private var selectedAddress: String?
    @State private var newAddressText = ""
    @State private var search = ""
    /// The pane last looked at, so Settings reopens where it was left.
    @AppStorage("settingsPane") private var lastPane = Pane.general.rawValue

    private enum Status: Equatable {
        case saved
    }

    /// The sidebar's panes, System Settings style: a coloured icon for each.
    private enum Pane: String, CaseIterable, Identifiable {
        case general, destinations, account, reading, cover, images

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .destinations: return "Destinations"
            case .account: return "Mail Account"
            case .reading: return "Reading"
            case .cover: return "Cover"
            case .images: return "Images"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .destinations: return "paperplane.fill"
            case .account: return "envelope.fill"
            case .reading: return "doc.text.fill"
            case .cover: return "book.closed.fill"
            case .images: return "photo.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return .gray
            case .destinations: return .blue
            case .account: return .teal
            case .reading: return .orange
            case .cover: return .purple
            case .images: return .green
            }
        }

        /// Words a search should find this pane by, beyond its title.
        var keywords: [String] {
            switch self {
            case .general: return ["dock", "menu bar", "icon", "browser", "link", "clipboard", "sound", "chime"]
            case .destinations: return ["kindle", "email", "address", "recipient", "attach", "epub"]
            case .account: return ["sender", "from", "mail server", "smtp", "port", "username", "password", "gmail"]
            case .reading: return ["instaparser", "api key", "reader", "paywall", "sign in", "sign out", "subscription"]
            case .cover: return ["layout", "font", "size", "e-ink", "gray", "grey"]
            case .images: return ["image", "picture", "shrink", "size", "kb"]
            }
        }

        func matches(_ query: String) -> Bool {
            let query = query.trimmingCharacters(in: .whitespaces).lowercased()
            guard !query.isEmpty else { return true }
            return title.lowercased().contains(query) || keywords.contains { $0.contains(query) }
        }
    }

    /// Sidebar groups, as headings over the panes.
    private static let groups: [(title: String, panes: [Pane])] = [
        ("General", [.general]),
        ("Sending", [.destinations, .account]),
        ("Articles", [.reading, .cover, .images]),
    ]

    private var pane: Binding<Pane?> {
        Binding(
            get: { Pane(rawValue: lastPane) ?? .general },
            // Clicking empty sidebar space deselects; keep the pane instead.
            set: { if let pane = $0 { lastPane = pane.rawValue } }
        )
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
        return "\(chosen) isn't installed, so covers will use Georgia."
    }

    /// Nothing to save until something actually differs from what is stored.
    private var hasChanges: Bool {
        draft.normalized != preferences.draft.normalized
    }

    var body: some View {
        // A sidebar of panes, as System Settings does it. Each pane holds one
        // kind of thing; the old General tab had grown to six unrelated ones.
        NavigationSplitView {
            sidebar
        } detail: {
            let current = pane.wrappedValue ?? .general
            VStack(alignment: .leading, spacing: 0) {
                // The pane's name as a heading at the top left, where System
                // Settings puts it.
                Text(current.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 26)
                    // Level with the window controls, as in System Settings.
                    .padding(.top, 6)

                content(for: current)
                    .frame(maxHeight: .infinity)
                    // On the pane, which is always on screen; on the split
                    // view itself it is never put in the window at all.
                    .background(HiddenTitleBar())

                // Save and Revert sit under every pane: the draft is one
                // value, so an edit anywhere is part of the same change.
                Divider()
                footer
            }
            // Still the window's title, for the Window menu; with the toolbar
            // hidden it is not drawn over the pane as well.
            .navigationTitle(current.title)
        }
        // No toolbar: the sidebar runs to the top of the window with the
        // window controls in it, and the pane starts right under the top edge.
        .toolbar(.hidden, for: .windowToolbar)
        .frame(width: 820, height: 680)
        .onAppear { revert() }
        // Clear a stale "Saved" note as soon as the user edits again.
        .onChange(of: draft) { _, _ in
            if status == .saved { status = nil }
        }
    }

    private var sidebar: some View {
        List(selection: pane) {
            ForEach(Self.groups, id: \.title) { group in
                let panes = group.panes.filter { $0.matches(search) }
                if !panes.isEmpty {
                    Section(group.title) {
                        ForEach(panes) { pane in
                            Label {
                                Text(pane.title)
                            } icon: {
                                PaneIcon(symbol: pane.symbol, tint: pane.tint)
                            }
                            .tag(pane)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search Settings")
        .environment(\.sidebarRowSize, .large)
        // Room for "Mail Account" and the search prompt at full length.
        .frame(minWidth: 220)
        .navigationSplitViewColumnWidth(220)
        .toolbar(removing: .sidebarToggle)
    }

    @ViewBuilder
    private func content(for pane: Pane) -> some View {
        switch pane {
        case .general: generalPane
        case .destinations: destinationsPane
        case .account: accountPane
        case .reading: readingPane
        case .cover: coverPane
        case .images: imagesPane
        }
    }

    // MARK: - General

    private var generalPane: some View {
        Form {
            Section {
                Picker(selection: $draft.iconPlacement) {
                    ForEach(IconPlacement.allCases, id: \.self) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                } label: {
                    Text("Show LittleSend in")
                    Text("Menu bar only keeps LittleSend out of the Dock and ⌘Tab, but its menus won't show.")
                }

                Picker(selection: $draft.browserSource) {
                    ForEach(BrowserSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                } label: {
                    Text("Fill the link from")
                    Text("macOS asks once before LittleSend can read your browser. If no page is open, it uses the clipboard.")
                }

                Toggle(isOn: $draft.playSounds) {
                    Text("Play sounds")
                    Text("A chime when a send works, and a low tone if it fails.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Where things go

    private var destinationsPane: some View {
        Form {
            Section("Kindle") {
                LabeledContent {
                    TextField("Send to Kindle address", text: $draft.kindleAddress)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("Send to Kindle address")
                    Text("Find it on Amazon under Manage Your Content and Devices → Preferences → Personal Document Settings.")
                }
            }

            Section {
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
            } header: {
                Text("Email addresses")
            } footer: {
                SectionNote("Your address book. Pick who gets each send in the panel.")
            }

            Section("Email messages") {
                Toggle("Show images in the email", isOn: $draft.embedImagesInEmail)
                    .disabled(draft.emailRecipients.isEmpty)

                Toggle("Also attach the EPUB", isOn: $draft.attachBookToEmail)
                    .disabled(draft.emailRecipients.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials

    private var accountPane: some View {
        Form {
            Section("Sender") {
                LabeledContent {
                    TextField("From address", text: $draft.fromAddress)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text("From address")
                    Text("Add this address to your Approved Personal Document E-mail List on Amazon. If you don't, Amazon drops your sends.")
                }
            }

            Section {
                TextField("Mail server", text: $draft.smtpHost)
                TextField("Port", value: $draft.smtpPort, format: .number.grouping(.never))
                TextField("Username", text: $draft.smtpUsername)
                SecureField("Password", text: $draft.smtpPassword)
            } header: {
                Text("Outgoing mail")
            } footer: {
                SectionNote("For Gmail, turn on 2-Step Verification and use an app password. Use port 465. The password is saved as plain text in LittleSend's settings, not in the Keychain.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Reading

    private var readingPane: some View {
        Form {
            Section {
                Picker(selection: $draft.articleReader) {
                    ForEach(ArticleReader.allCases, id: \.self) { reader in
                        Text(reader.displayName).tag(reader)
                    }
                } label: {
                    Text("Read articles with")
                    Text(readerNote)
                }

                if draft.articleReader == .instaparser {
                    LabeledContent {
                        SecureField("Instaparser API key", text: $draft.instaparserAPIKey)
                            .labelsHidden()
                    } label: {
                        Text("Instaparser API key")
                        Text("Saved as plain text in LittleSend's settings.")
                    }

                    LabeledContent {
                        Link("Get a free key", destination: URL(string: "https://www.instaparser.com")!)
                    } label: {
                        Text("No key yet?")
                        Text("The free plan covers 1,000 articles a month.")
                    }
                }
            }

            Section("Paywalls") {
                LabeledContent {
                    Button("Sign In…") { SiteSignInWindow.shared.show() }
                } label: {
                    Text("Sign in to a site")
                    Text("Pay for a site? Sign in once to get full articles. LittleSend can't use Safari's sign-ins.")
                }

                LabeledContent {
                    Button("Sign Out") {
                        Task {
                            await SiteSignInWindow.signOutOfAllSites()
                            signedOut = true
                        }
                    }
                } label: {
                    Text("Sign out of all sites")
                    if signedOut {
                        Text("Signed out of all sites.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var readerNote: String {
        switch draft.articleReader {
        case .local:
            return "Reads articles on this Mac. It's free and private, and it reads every page of long articles."
        case .instaparser:
            return "Much faster, usually under a second. Instaparser sees each link you send. If it can't read one, LittleSend reads it on this Mac."
        }
    }

    // MARK: - Cover art

    private var coverPane: some View {
        Form {
            Section {
                CoverLayoutGallery(
                    selection: $draft.coverLayout,
                    fontFamily: draft.coverFontFamily,
                    eInk: draft.optimizeCoverForEInk
                )
                .frame(maxWidth: .infinity)
            } header: {
                Text("Layout")
            } footer: {
                SectionNote(draft.coverLayout.summary)
            }

            Section("Type") {
                Picker(selection: $draft.coverFontFamily) {
                    Text(CoverFont.systemFamilyLabel).tag("")
                    Divider()
                    ForEach(installedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                } label: {
                    Text("Cover font")
                    Text("Any font on this Mac works. The article uses your Kindle's own fonts.")
                }

                if let warning = coverFontWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.appLabel)
                        .foregroundStyle(.orange)
                }
            }

            Section("Rendering") {
                Picker(selection: $draft.coverSize) {
                    ForEach(CoverSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                } label: {
                    Text("Size")
                    Text(draft.coverSize.summary)
                }

                Toggle(isOn: $draft.optimizeCoverForEInk) {
                    Text("Optimize Kindle covers for e-ink")
                    Text("Kindle covers use the 16 grays an e-ink screen can show. Desktop and email covers stay in color.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Images

    private var imagesPane: some View {
        Form {
            Section {
                Toggle("Include images in the EPUB", isOn: $draft.embedImages)

                Toggle(isOn: $draft.limitImageSize) {
                    Text("Shrink large images")
                    Text("Bigger images are shrunk to fit. Each one links to the full-size original.")
                }
                .disabled(!draft.embedImages)

                LabeledContent("Maximum size") {
                    HStack(spacing: 4) {
                        TextField(
                            "size",
                            value: $draft.maxImageKilobytes,
                            format: .number.grouping(.never)
                        )
                        // The row's own label says what this is; without this
                        // the grouped form prints the field's name, "size", too.
                        .labelsHidden()
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        Text("KB")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!draft.embedImages || !draft.limitImageSize)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Save and Revert

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

/// A note under a group of rows, for something that applies to the whole
/// group rather than one row.
private struct SectionNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.appLabel)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each pane draws its own heading, System Settings style, so the window's
/// title strip goes: no centred title, and the sidebar and pane run up under
/// the window controls. SwiftUI has no way to style a `Settings` window, so
/// this reaches it from inside. The title stays set, for the Window menu.
///
/// SwiftUI puts the title strip back whenever it refreshes the window — a
/// second or two after opening, and on pane changes — so setting it once does
/// not stick. The two properties are watched and re-set whenever they change.
private struct HiddenTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Hider() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Hider: NSView {
        private var observations: [NSKeyValueObservation] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observations = []
            guard let window else { return }
            Self.hideTitle(of: window)
            observations = [
                window.observe(\.titleVisibility) { window, _ in
                    DispatchQueue.main.async { Self.hideTitle(of: window) }
                },
                window.observe(\.titlebarAppearsTransparent) { window, _ in
                    DispatchQueue.main.async { Self.hideTitle(of: window) }
                },
            ]
        }

        private static func hideTitle(of window: NSWindow) {
            // Only when needed, so re-setting does not notify again.
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        }
    }
}

/// A sidebar icon in the System Settings style: a white symbol on a small
/// coloured rounded square.
private struct PaneIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}
