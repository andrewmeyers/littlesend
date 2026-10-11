import SwiftUI
import LittleSendCore

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    @State private var draft = SettingsDraft()
    @State private var signedOut = false
    @State private var selectedAddress: String?
    @State private var newAddressText = ""
    @State private var search = ""
    /// The pane last looked at, so Settings reopens where it was left.
    @AppStorage("settingsPane") private var lastPane = Pane.general.rawValue

    private typealias Pane = SettingsPane

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

    var body: some View {
        // A sidebar of panes, as System Settings does it. Each pane holds one
        // kind of thing; the old General tab had grown to six unrelated ones.
        NavigationSplitView {
            sidebar
        } detail: {
            let current = pane.wrappedValue ?? .general
            VStack(alignment: .leading, spacing: 0) {
                // The pane's name as a heading at the top left, where System
                // Settings puts it, level with the window controls.
                HStack(alignment: .firstTextBaseline) {
                    Text(current.title)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    missingItems
                }
                .padding(.horizontal, 26)
                .padding(.top, 6)

                content(for: current)
                    .frame(maxHeight: .infinity)
                    // On the pane, which is always on screen; on the split
                    // view itself it is never put in the window at all.
                    .background(HiddenTitleBar())
            }
            // Still the window's title, for the Window menu; with the toolbar
            // hidden it is not drawn over the pane as well.
            .navigationTitle(current.title)
        }
        // No toolbar: the sidebar runs to the top of the window with the
        // window controls in it, and the pane starts right under the top edge.
        .toolbar(.hidden, for: .windowToolbar)
        .frame(width: 820, height: 680)
        // Saved as you go, like System Settings. The draft is still kept
        // here rather than editing the stored settings directly: storing trims
        // whitespace, and trimming the field being typed in would eat the space
        // in "abcd efgh" before the next letter arrived.
        .onAppear { draft = preferences.draft }
        .onChange(of: draft) { _, edited in
            preferences.apply(edited)
        }
        // The panel changes settings too — its destination chips — and an
        // open Settings window must take those in, or its next save would put
        // the old values back. After a save of our own the two already agree.
        .onChange(of: preferences.draft) { _, stored in
            if stored != draft.normalized {
                draft = stored
            }
        }
    }

    private var sidebar: some View {
        List(selection: pane) {
            ForEach(Self.groups, id: \.title) { group in
                let panes = group.panes.filter { $0.matches(search) }
                if !panes.isEmpty {
                    Section(group.title) {
                        ForEach(panes) { pane in
                            // Laid out by hand to System Settings' measure: a
                            // 20pt icon, a 7pt gap, rows about 32pt tall, and
                            // the selected pane's name in semibold.
                            HStack(spacing: 7) {
                                PaneIcon(symbol: pane.symbol, tint: pane.tint)
                                Text(pane.title)
                                    .fontWeight(pane == self.pane.wrappedValue ? .semibold : .regular)
                            }
                            .padding(.vertical, 1)
                            .tag(pane)
                        }
                    }
                }
            }

            if !Pane.allCases.contains(where: { $0.matches(search) }) {
                Text("No Results")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                    .selectionDisabled()
            }
        }
        // Searching moves to the first pane that matches whenever the one on
        // screen no longer does, so what was found is what is shown.
        .onChange(of: search) { _, query in
            let current = pane.wrappedValue ?? .general
            guard !current.matches(query),
                  let first = Self.groups.flatMap(\.panes).first(where: { $0.matches(query) })
            else { return }
            pane.wrappedValue = first
        }
        // Never the keyboard focus, so the selection stays the soft grey
        // System Settings uses rather than the accent colour a focused list
        // gets. Panes are picked by click or search.
        .focusable(false)
        .searchable(text: $search, placement: .sidebar, prompt: "Search Settings")
        // Standard-size labels; the room between rows comes from padding.
        .environment(\.sidebarRowSize, .medium)
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
                    Text(SettingsCopy.General.showIn)
                    Text(SettingsCopy.General.showInNote)
                }

                Picker(selection: $draft.browserSource) {
                    ForEach(BrowserSource.allCases, id: \.self) { source in
                        Text(source.displayName).tag(source)
                    }
                } label: {
                    Text(SettingsCopy.General.fillLink)
                    Text(SettingsCopy.General.fillLinkNote)
                }

                Toggle(isOn: $draft.playSounds) {
                    Text(SettingsCopy.General.sounds)
                    Text(SettingsCopy.General.soundsNote)
                }
            }

            Section(SettingsCopy.General.setupSection) {
                LabeledContent {
                    Button(SettingsCopy.General.runSetupButton) {
                        SetupWindow.shared.show(preferences: preferences)
                    }
                } label: {
                    Text(SettingsCopy.General.runSetup)
                    Text(SettingsCopy.General.runSetupNote)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Where things go

    private var destinationsPane: some View {
        Form {
            Section(SettingsCopy.Destinations.kindleSection) {
                LabeledContent {
                    TextField(SettingsCopy.Destinations.kindleAddress, text: $draft.kindleAddress)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(SettingsCopy.Destinations.kindleAddress)
                    Text(SettingsCopy.Destinations.kindleAddressNote)
                }
            }

            Section {
                emailAddressTable

                HStack {
                    TextField(
                        SettingsCopy.Destinations.addAddress,
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
                Text(SettingsCopy.Destinations.addressesSection)
            } footer: {
                SectionNote(SettingsCopy.Destinations.addressesNote)
            }

            Section(SettingsCopy.Destinations.messagesSection) {
                Toggle(SettingsCopy.Destinations.showImages, isOn: $draft.embedImagesInEmail)
                    .disabled(draft.emailRecipients.isEmpty)

                Toggle(SettingsCopy.Destinations.attachEPUB, isOn: $draft.attachBookToEmail)
                    .disabled(draft.emailRecipients.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Credentials

    private var accountPane: some View {
        Form {
            Section(SettingsCopy.Account.senderSection) {
                LabeledContent {
                    TextField(SettingsCopy.Account.fromAddress, text: $draft.fromAddress)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                } label: {
                    Text(SettingsCopy.Account.fromAddress)
                    Text(SettingsCopy.Account.fromAddressNote)
                }
            }

            Section {
                TextField(SettingsCopy.Account.server, text: $draft.smtpHost)
                TextField(SettingsCopy.Account.port, value: $draft.smtpPort, format: .number.grouping(.never))
                TextField(SettingsCopy.Account.username, text: $draft.smtpUsername)
                SecureField(SettingsCopy.Account.password, text: $draft.smtpPassword)
            } header: {
                Text(SettingsCopy.Account.outgoingSection)
            } footer: {
                SectionNote(SettingsCopy.Account.outgoingNote)
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
                    Text(SettingsCopy.Reading.readWith)
                    Text(readerNote)
                }

                if draft.articleReader == .instaparser {
                    LabeledContent {
                        SecureField(SettingsCopy.Reading.apiKey, text: $draft.instaparserAPIKey)
                            .labelsHidden()
                    } label: {
                        Text(SettingsCopy.Reading.apiKey)
                        Text(SettingsCopy.Reading.apiKeyNote)
                    }

                    LabeledContent {
                        Link(SettingsCopy.Reading.getKey, destination: URL(string: "https://www.instaparser.com")!)
                    } label: {
                        Text(SettingsCopy.Reading.noKey)
                        Text(SettingsCopy.Reading.noKeyNote)
                    }
                }
            }

            Section(SettingsCopy.Reading.paywallsSection) {
                LabeledContent {
                    Button(SettingsCopy.Reading.signInButton) { SiteSignInWindow.shared.show() }
                } label: {
                    Text(SettingsCopy.Reading.signIn)
                    Text(SettingsCopy.Reading.signInNote)
                }

                LabeledContent {
                    Button(SettingsCopy.Reading.signOutButton) {
                        Task {
                            await SiteSignInWindow.signOutOfAllSites()
                            signedOut = true
                        }
                    }
                } label: {
                    Text(SettingsCopy.Reading.signOut)
                    if signedOut {
                        Text(SettingsCopy.Reading.signedOut)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var readerNote: String {
        SettingsCopy.Reading.note(for: draft.articleReader)
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
                Text(SettingsCopy.Cover.layoutSection)
            } footer: {
                SectionNote(draft.coverLayout.summary)
            }

            Section(SettingsCopy.Cover.typeSection) {
                Picker(selection: $draft.coverFontFamily) {
                    Text(CoverFont.systemFamilyLabel).tag("")
                    Divider()
                    ForEach(installedFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                } label: {
                    Text(SettingsCopy.Cover.font)
                    Text(SettingsCopy.Cover.fontNote)
                }

                if let warning = coverFontWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.appLabel)
                        .foregroundStyle(.orange)
                }
            }

            Section(SettingsCopy.Cover.renderingSection) {
                Picker(selection: $draft.coverSize) {
                    ForEach(CoverSize.allCases, id: \.self) { size in
                        Text(size.displayName).tag(size)
                    }
                } label: {
                    Text(SettingsCopy.Cover.size)
                    Text(draft.coverSize.summary)
                }

                Toggle(isOn: $draft.optimizeCoverForEInk) {
                    Text(SettingsCopy.Cover.eInk)
                    Text(SettingsCopy.Cover.eInkNote)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Images

    private var imagesPane: some View {
        Form {
            Section {
                Toggle(SettingsCopy.Images.include, isOn: $draft.embedImages)

                Toggle(isOn: $draft.limitImageSize) {
                    Text(SettingsCopy.Images.shrink)
                    Text(SettingsCopy.Images.shrinkNote)
                }
                .disabled(!draft.embedImages)

                LabeledContent(SettingsCopy.Images.maximumSize) {
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

    /// Anything still needed before a send can work — shown beside the
    /// heading, with the details on hover. Saved settings, so it updates as
    /// fields are filled in.
    @ViewBuilder
    private var missingItems: some View {
        let problems = draft.settingsProblems
        if !problems.isEmpty {
            Label(
                "\(problems.count) item\(problems.count == 1 ? "" : "s") still needed",
                systemImage: "exclamationmark.circle"
            )
            .font(.appLabel)
            .foregroundStyle(.orange)
            .help(problems.joined(separator: "\n"))
        }
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(tint.gradient)
            )
    }
}

/// Sidebar presentation for each pane: a white symbol on a coloured square.
private extension SettingsPane {
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
}
