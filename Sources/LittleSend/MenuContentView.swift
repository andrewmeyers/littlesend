import SwiftUI
import LittleSendCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: Preferences
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(spacing: 8) {
                TextField("https://example.com/article", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFieldFocused)
                    .onSubmit { model.send() }
                    .disabled(model.isSending)

                Button(action: model.send) {
                    if model.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSending || model.urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            destinationPicker

            if model.isSending, !model.stageDescription.isEmpty {
                Label(model.stageDescription, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let banner = model.banner {
                bannerView(banner)
            }

            if model.localRetryURL != nil, !model.isSending {
                localRetryPrompt
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
        .frame(width: 380)
        .onAppear {
            model.prefillFromPasteboard()
            urlFieldFocused = true
        }
    }

    private var header: some View {
        HStack {
            Text(headerTitle)
                .font(.headline)
                .animation(.default, value: headerTitle)
            Spacer()
            Button {
                model.urlText = ""
                model.prefillFromPasteboard()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Paste the link from the clipboard")
        }
    }

    /// The popover's title, reflecting live destination selection rather than
    /// staying fixed as "Send to Kindle" — falls back to the app name when
    /// nothing is currently selected to send to.
    private var headerTitle: String {
        let summary = preferences.draft.activeDestinationsSummary
        return summary.isEmpty ? "LittleSend" : "Send to \(summary)"
    }

    /// Destinations as selectable chips, so where a send is going is visible
    /// and changeable without opening Settings. Toggling writes straight
    /// through to the saved settings — there is one source of truth.
    private var destinationPicker: some View {
        let draft = preferences.draft

        return HStack(spacing: 6) {
            Text("Send to")
                .font(.caption)
                .foregroundStyle(.secondary)

            DestinationButton(
                title: "Kindle",
                onSymbol: "books.vertical.fill",
                offSymbol: "books.vertical",
                isOn: preferences.sendToKindle,
                enabled: draft.canSendToKindle,
                help: draft.canSendToKindle
                    ? "Send the EPUB to \(draft.kindleAddress)"
                    : "Add your Send to Kindle address in Settings",
                action: { preferences.update { $0.sendToKindle.toggle() } }
            )

            emailChip(draft: draft)

            // Needs nothing configured, so it is never disabled.
            DestinationButton(
                title: "Desktop",
                onSymbol: "folder.fill",
                offSymbol: "folder",
                isOn: preferences.saveToDesktop,
                enabled: true,
                help: "Save the EPUB to your Desktop",
                action: { preferences.update { $0.saveToDesktop.toggle() } }
            )

            Spacer()
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
            action: { preferences.update { $0.sendToEmail.toggle() } }
        ) {
            ForEach(draft.emailRecipients, id: \.self) { address in
                Toggle(address, isOn: Binding(
                    get: { preferences.isEmailRecipientSelected(address) },
                    set: { selected in
                        preferences.update { $0.setRecipient(address, selected: selected) }
                    }
                ))
            }
        }
    }

    private var emailChipTitle: String {
        let total = preferences.draft.emailRecipients.count
        let selected = preferences.draft.selectedEmailRecipients.count
        guard total > 0 else { return "Email" }
        guard selected != total else { return total == 1 ? "Email" : "Email (\(total))" }
        return "Email (\(selected)/\(total))"
    }

    private var emailChipHelp: String {
        guard preferences.draft.canSendToEmail else { return "Add email recipients in Settings" }
        guard preferences.sendToEmail else { return "Click to email this article. Use the arrow to choose recipients." }
        let selected = preferences.draft.selectedEmailRecipients
        guard !selected.isEmpty else { return "On, but no recipients are checked — use the arrow to pick who" }
        return "Email the article to \(selected.joined(separator: ", ")). Click to turn off."
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
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Offered after the hosted parser fails. Some sites refuse plain HTTP
    /// clients outright but serve a real browser fine, which is exactly what
    /// the local reader is — so it is worth a second try, on request.
    private var localRetryPrompt: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Try reading it locally?")
                    .font(.caption.bold())
                Text("Opens the page in a hidden browser and extracts it here. Slower, but works on sites that block the parser.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Try", action: model.retryLocally)
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var setupPrompt: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finish setup before sending")
                .font(.caption.bold())
            ForEach(preferences.draft.settingsProblems, id: \.self) { problem in
                Text("• \(problem)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsButton { Text("Open Settings…") }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let archive = model.archive {
                    Button("Show All") {
                        NSWorkspace.shared.open(archive.location)
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help("Files for the last \(SendArchive.keepCount) sends")
                }
            }

            ForEach(model.history) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: entry.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(entry.isFailure ? Color.red : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(detail(for: entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if let folder = entry.archiveFolder {
                        Button {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                        } label: {
                            Image(systemName: "folder")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Show the files for this send in Finder")
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
        .font(.caption)
    }
}
