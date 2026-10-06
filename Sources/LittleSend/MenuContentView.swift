import SwiftUI
import LittleSendCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences
    @FocusState private var urlFieldFocused: Bool
    @State private var isDropTargeted = false
    /// Send's square, as last measured beside the address and chips. Next uses
    /// it too so the two buttons are identical, and it is stored so Next is the
    /// right size on the first Source pane after launch, before Send has been
    /// laid out at all.
    @AppStorage("squareButtonSide") private var squareSide: Double = 70
    /// True while the URL field has the cursor. Without it, the first
    /// keystroke would satisfy `hasInput` and advance the step out from
    /// under the field being typed into.
    @State private var editingURL = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // The panel follows the bar: each step shows its own controls, and
            // the steps behind it collapse to a line you can click to go back.
            switch currentStep {
            case .source:
                inputStep
            case .destination:
                SquareButtonRow(
                    title: "Send",
                    systemImage: "paperplane.fill",
                    isEnabled: model.canSend && destinationLabel != nil,
                    isBusy: model.isSending,
                    // ⌘Return, not Return: a chord can't be hit by accident,
                    // whereas plain Return would send on the same keystroke
                    // that pressed Next a moment ago.
                    shortcut: KeyboardShortcut(.return, modifiers: .command),
                    help: destinationLabel == nil ? "Pick where to send it" : "Send (⌘Return)",
                    reportsSide: Binding(
                        get: { CGFloat(squareSide) },
                        set: { squareSide = Double($0) }
                    ),
                    action: model.send
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        inputSummary
                        destinationPicker
                            .disabled(model.isSending)
                    }
                }
            }

            if model.isSending, !model.stageDescription.isEmpty {
                Label(model.stageDescription, systemImage: "arrow.triangle.2.circlepath")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }

            if let banner = model.banner {
                bannerView(banner)
            }

            if !preferences.isConfigured {
                setupPrompt
            }

            if !model.history.isEmpty {
                Divider()
                historyList
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 530)
        // Scoped to this one value so nothing else in the panel animates, and
        // off entirely under Reduce Motion — along with every symbol effect.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: currentStep)
        .symbolEffectsRemoved(reduceMotion)

        .onAppear {
            model.prefill()
            urlFieldFocused = true
        }
        // The panel is reused, so reopening does not re-run onAppear. Reopening
        // returns to the first step so a freshly filled URL can be seen and
        // edited, rather than landing on a summary of it.
        .onChange(of: model.focusRequest) { _, _ in
            guard model.attachedFile == nil else { return }
            editingURL = true
            urlFieldFocused = true
        }
        // Staging a file ends URL editing. Otherwise dropping one mid-typing
        // would leave the step on the now-empty field with the file behind it.
        .onChange(of: model.attachedFile) { _, file in
            guard file != nil else { return }
            editingURL = false
            urlFieldFocused = false
        }
    }

    /// A file well under the URL field: click to choose, or drop onto it.
    ///
    /// This works properly now that the window is a floating panel that stays
    /// open while you go and find a file. Under the old menu bar popover it
    /// could not: picking a file up from the Desktop dismissed the very window
    /// you were dragging it to.
    /// Spells out that the URL field and the file well are alternatives.
    private var orDivider: some View {
        HStack(spacing: 8) {
            VStack { Divider() }
            Text("or")
                .font(.appHint)
                .foregroundStyle(.tertiary)
            VStack { Divider() }
        }
        .padding(.vertical, -2)
    }

    private var fileDropZone: some View {
        Group {
            if let file = model.attachedFile {
                stagedFile(file)
            } else if hasTypedURL {
                collapsedDropZone
            } else {
                emptyDropZone
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isSending, let file = urls.first, file.isFileURL else { return false }
            model.attachFile(at: file)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    /// What is staged, and a way to take it back off.
    private func stagedFile(_ file: URL) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.fill")
                .foregroundStyle(Color.accentColor)
                .bounce(whenShown: file)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.lastPathComponent)
                    .font(.appLabel.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Ready to send to Kindle")
                    .font(.appHint)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.clearAttachedFile) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(model.isSending)
            .help("Remove this file")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10))
        )
    }

    /// Shrinks to a single line once a URL is being typed. The full-height
    /// well is an invitation; once the other half is in use it only needs to
    /// stay visible enough to be switched back to.
    private var collapsedDropZone: some View {
        Button(action: model.chooseFile) {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                Text("or send a file to Kindle")
                Spacer()
            }
            .font(.appLabel)
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(isDropTargeted ? 0.16 : 0.04))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(model.isSending)
        .help("Choose a file for your Kindle, or drop one here")
    }

    private var emptyDropZone: some View {
        Button(action: model.chooseFile) {
            // Compact: the icon sits beside the title rather than above it, so
            // the well ends level with the bottom of the Next button.
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                        .symbolEffect(.bounce, value: isDropTargeted)
                    Text("Drop a file here")
                }
                .font(.appLabel.weight(.medium))
                Text("or click to choose. Kindle only.")
                    .font(.appHint)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(isDropTargeted ? 0.18 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [5, 4])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(model.isSending)
        .opacity(hasTypedURL ? 0.4 : 1)
        .help("Choose a file for your Kindle, or drop one here")
    }

    /// True once something has been typed in the URL field, which is what makes
    /// the file well the inactive half.
    private var fileStaged: Bool { model.attachedFile != nil }

    /// Whether there is anything to send yet — the gate for showing
    /// destinations at all.
    private var hasInput: Bool { hasTypedURL || fileStaged }

    private var hasTypedURL: Bool {
        !model.urlText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var header: some View {
        HStack {
            ProcessBar(
                current: currentStep,
                highestSelectable: highestSelectable,
                isSending: model.isSending,
                onSelect: go(to:)
            )
            Spacer()
            Button(action: model.grabFromBrowser) {
                Label("Use the browser's tab", systemImage: "safari")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(model.isSending)
            .help("Use the link from your browser")

            Button {
                model.urlText = ""
                model.prefillFromPasteboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Paste a link")
        }
    }

    /// Moves back to a step from the bar.
    ///
    /// Only the input step has anything to return *to* — the destination chips
    /// are on screen for both of the later steps, so stepping back to them just
    /// means leaving the URL field. Both are handled by whether editing is on.
    private func go(to step: ProcessBar.Step) {
        switch step {
        case .source:
            // A staged file is edited by removing it, not by retyping.
            guard model.attachedFile == nil else { return }
            editingURL = true
            urlFieldFocused = true
        case .destination:
            editingURL = false
            urlFieldFocused = false
        }
    }

    private var inputStep: some View {
        // Next floats beside both ways of choosing a source — the URL field
        // and the file well — the way Send sits beside the address and chips.
        SquareButtonRow(
            title: "Next",
            systemImage: "arrow.right",
            isEnabled: hasInput && !model.isSending,
            shortcut: .defaultAction,
            help: "Next (Return)",
            fixedSide: CGFloat(squareSide),
            stretchesToContentHeight: true,
            action: advanceFromSource
        ) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("https://example.com/article", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($urlFieldFocused)
                    .disabled(model.isSending)
                    .onAppear { urlFieldFocused = true }
                    .onChange(of: urlFieldFocused) { _, focused in
                        // Focus starts editing; only Next or Return ends it. Tying
                        // the pane to focus alone meant a click in Finder, mid-typing,
                        // jumped the panel on to Destination.
                        if focused { editingURL = true }
                    }
                    // Return is Next. It never sends: sending is always a deliberate
                    // press of Send, on the Destination pane.
                    .onSubmit(advanceFromSource)

                if !hasTypedURL {
                    orDivider
                }
                fileDropZone
            }
        }
    }

    /// Moves on to Destination, but not with an address that could never be
    /// sent — better to hear about a typo here than after choosing where it goes.
    private func advanceFromSource() {
        guard hasInput else { return }
        if !fileStaged, AppModel.normalizedURL(from: model.urlText) == nil {
            model.banner = AppModel.Banner(kind: .failure, message: "That isn't a web address.")
            return
        }
        model.banner = nil
        go(to: .destination)
    }

    /// The finished first step, as one line you can click to reopen.
    @ViewBuilder
    private var inputSummary: some View {
        if let file = model.attachedFile {
            stagedFile(file)
        } else {
            Button {
                editingURL = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "link")
                        .foregroundStyle(Color.accentColor)
                    Text(model.urlText)
                        .font(.appLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "pencil")
                        .font(.appHint)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(model.isSending)
            .help("Edit the link")
        }
    }


    /// Where the send currently stands. Nothing entered yet is step one; an
    /// input with no destination is step two; anything else is ready to send.
    private var currentStep: ProcessBar.Step {
        // Mid-send stays on Destination, where the Send button shows progress.
        if model.isSending { return .destination }
        // Editing keeps the field on screen even once it has content.
        if !hasInput || editingURL { return .source }
        return .destination
    }

    /// The furthest step that can be jumped to: Send only once somewhere to
    /// send has actually been chosen.
    private var highestSelectable: ProcessBar.Step {
        hasInput ? .destination : .source
    }

    /// The destinations a send would actually reach, or nil when none would.
    /// A staged file is Kindle-only, whatever the other chips say.
    private var destinationLabel: String? {
        if fileStaged {
            return preferences.sendToKindle ? "Kindle" : nil
        }
        let summary = preferences.draft.activeDestinationsSummary
        return summary.isEmpty ? nil : summary
    }

    /// Destinations as selectable chips, so where a send is going is visible
    /// and changeable without opening Settings. Toggling writes straight
    /// through to the saved settings — there is one source of truth.
    /// One row in practice: the chips get 424pt beside the Send square, measured to hold every chip
    /// switched on with its widest label ("Email (99/99)", "Desktop · EPUB").
    /// Two rows remain only as a fallback for anything wider still. The chips never
    /// compress to squeeze in: a truncated "Desktop · …" would hide the one
    /// thing that chip is there to show.
    @ViewBuilder
    private var destinationPicker: some View {
        let draft = preferences.draft

        if fileStaged {
            // A file goes to Kindle as-is, so Kindle is the only destination
            // offered — not three chips with two of them greyed out.
            HStack(spacing: 8) {
                kindleChip(draft: draft)
                Text("Files go to Kindle only.")
                    .font(.appHint)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            chipRows(draft: draft)
        }
    }

    private func chipRows(draft: SettingsDraft) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                kindleChip(draft: draft)
                emailChip(draft: draft)
                desktopChip
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    kindleChip(draft: draft)
                    emailChip(draft: draft)
                }
                desktopChip
            }
        }
    }

    private func kindleChip(draft: SettingsDraft) -> some View {
        DestinationButton(
            title: "Kindle",
            onSymbol: "books.vertical.fill",
            offSymbol: "books.vertical",
            isOn: preferences.sendToKindle,
            enabled: draft.canSendToKindle,
            help: draft.canSendToKindle
                ? "Send \(fileStaged ? "the file" : "the EPUB") to \(draft.kindleAddress)"
                : "Add your Send to Kindle address in Settings",
            action: { preferences.update { $0.sendToKindle.toggle() } }
        )
    }

    /// Needs nothing configured, and is not shown for a staged file.
    private var desktopChip: some View {
        DestinationMenuButton(
            title: "Desktop · \(preferences.desktopFormat.shortName)",
            onSymbol: "folder.fill",
            offSymbol: "folder",
            isOn: preferences.saveToDesktop,
            enabled: true,
            help: "Save a \(preferences.desktopFormat.displayName) copy to your Desktop",
            action: { preferences.update { $0.saveToDesktop.toggle() } },
            optionsHelp: "Choose a format"
        ) {
            // A radio group in the popover, which is a real SwiftUI view and
            // so shows the current choice live — unlike a menu.
            Text("Save as")
                .font(.appLabel.bold())
                .foregroundStyle(.secondary)

            Picker("Format", selection: Binding(
                get: { preferences.desktopFormat },
                set: { format in preferences.update { $0.desktopFormat = format } }
            )) {
                ForEach(DesktopFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    /// Turning email on or off is a deliberate top-level action, never a side
    /// effect of checking one recipient in the list. The chevron sits inside
    /// the chip because the recipient list is that chip's own configuration —
    /// clicking the label toggles the destination, clicking the chevron opens
    /// the list.
    @ViewBuilder
    private func emailChip(draft: SettingsDraft) -> some View {
        DestinationMenuButton(
            title: emailChipTitle,
            onSymbol: "envelope.fill",
            offSymbol: "envelope",
            isOn: preferences.sendToEmail,
            enabled: draft.canSendToEmail,
            help: emailChipHelp,
            action: { preferences.update { $0.sendToEmail.toggle() } },
            optionsHelp: "Choose who gets it"
        ) {
            // Plain SwiftUI toggles in a popover, which re-render when the
            // state behind them changes — the thing a macOS menu would not do.
            Text("Send to")
                .font(.appLabel.bold())
                .foregroundStyle(.secondary)

            ForEach(draft.emailRecipients, id: \.self) { address in
                Toggle(address, isOn: Binding(
                    get: { preferences.isEmailRecipientSelected(address) },
                    set: { selected in
                        preferences.update { $0.setRecipient(address, selected: selected) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }

    /// Always "selected/total" once there is an address book, so the count
    /// reads the same way every time and the chip keeps a steady width instead
    /// of resizing as the selection changes.
    private var emailChipTitle: String {
        let total = preferences.draft.emailRecipients.count
        guard total > 0 else { return "Email" }
        let selected = preferences.draft.selectedEmailRecipients.count
        return "Email (\(selected)/\(total))"
    }

    private var emailChipHelp: String {
        guard preferences.draft.canSendToEmail else { return "Add email addresses in Settings" }
        guard preferences.sendToEmail else { return "Click to email it. Use the arrow to pick who gets it." }
        let selected = preferences.draft.selectedEmailRecipients
        guard !selected.isEmpty else { return "No one is checked. Use the arrow to pick who gets it." }
        return "Emails it to \(selected.joined(separator: ", ")). Click to turn off."
    }

    private func bannerView(_ banner: AppModel.Banner) -> some View {
        let symbol: String
        let tint: Color
        switch banner.kind {
        case .success: symbol = "checkmark.circle.fill"; tint = .green
        case .failure: symbol = "exclamationmark.triangle.fill"; tint = .red
        case .warning: symbol = "info.circle.fill"; tint = .orange
        }

        return Label {
            Text(banner.message)
                .font(.appLabel)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            // Only success gets the hop. Motion on an error reads as the app
            // being pleased with itself at the worst moment.
            if banner.kind == .success {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .bounce(whenShown: banner)
            } else {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finish setup before sending")
                .font(.appLabel.bold())
            ForEach(preferences.draft.settingsProblems, id: \.self) { problem in
                Text("• \(problem)")
                    .font(.appLabel)
                    .foregroundStyle(.secondary)
            }
            SettingsButton { Text("Open Settings…") }
                .buttonStyle(.link)
                .font(.appLabel)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.appLabel.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let archive = model.archive {
                    Button("Show All") {
                        NSWorkspace.shared.open(archive.location)
                    }
                    .buttonStyle(.link)
                    .font(.appHint)
                    .help("Files for the last \(SendArchive.keepCount) sends")
                }
            }

            ForEach(model.history) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.appHint)
                        .foregroundStyle(entry.isFailure ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.appLabel)
                            .lineLimit(1)
                        Text(detail(for: entry))
                            .font(.appHint)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if let folder = entry.archiveFolder {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        } label: {
                            Image(systemName: "folder")
                                .font(.appHint)
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                    }
                }
            }
        }
    }

    private func detail(for entry: HistoryEntry) -> String {
        switch entry.state {
        case .succeeded(let detail): return detail
        case .failed(let message): return message
        }
    }

    private var footer: some View {
        HStack {
            SettingsButton { Text("Settings…") }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.appLabel)
    }
}

/// Plays a symbol's bounce when it appears, and again whenever `id` changes.
///
/// `.symbolEffect(_:value:)` fires only on a *change* of value. A view inserted
/// with its value already set never sees one, so a success mark arriving with
/// its banner — or a file icon arriving as the file is staged — would sit
/// perfectly still. `.task(id:)` runs on appearance, which supplies the change.
private struct BounceWhenShown<ID: Equatable>: ViewModifier {
    let id: ID
    @State private var trigger = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, value: trigger)
            .task(id: id) { trigger += 1 }
    }
}

private extension View {
    func bounce<ID: Equatable>(whenShown id: ID) -> some View {
        modifier(BounceWhenShown(id: id))
    }
}
