import SwiftUI
import AppKit
import Combine
import LittleSendCore

/// Owns the status item and the panel.
///
/// The menu bar item is created here rather than with `MenuBarExtra`, which
/// only offers a popover that dismisses on resign-key and exposes no handle on
/// its `NSStatusItem`. Owning an `NSStatusItem` outright is entirely public
/// API, and it gives the two things the popover could not: a click that opens a
/// window which stays put, and a button that accepts dropped files directly —
/// no walking the view hierarchy to find it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: MainPanel?
    private var activityWatch: AnyCancellable?
    private var placementWatch: AnyCancellable?
    private var resetIcon: DispatchWorkItem?
    private var windowObservers: [NSObjectProtocol] = []

    /// Owned here rather than by the `App` struct. The status item and the
    /// panel are both AppKit and exist before any SwiftUI scene is shown, so
    /// hanging the model off a `@StateObject` would leave a dropped file with
    /// nowhere to go until the user had opened Settings at least once.
    let preferences = Preferences()
    private(set) lazy var model = AppModel(preferences: preferences)

    /// Before launch finishes, so a menu-bar-only app never flashes a Dock
    /// icon on the way up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(activationPolicy(for: preferences.iconPlacement))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "arrow.up.doc.fill",
            accessibilityDescription: "LittleSend"
        )
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.toolTip = "LittleSend — click to open, or drop a file to send to Kindle"

        // Straight onto the button, now that we own it.
        item.button?.registerForDraggedTypes([.fileURL])
        item.button?.window?.registerForDraggedTypes([.fileURL])
        if let button = item.button {
            let drop = FileDropView(onDrop: { [weak self] url in
                // Stage it and bring the panel up, so a file dropped on the
                // icon is visibly waiting for Send rather than vanishing into
                // a send the user never confirmed.
                guard let self else { return }
                self.model.attachFile(at: url)
                self.show()
            })
            drop.frame = button.bounds
            drop.autoresizingMask = [.width, .height]
            button.addSubview(drop)
        }

        item.isVisible = preferences.iconPlacement.showsMenuBarIcon
        statusItem = item
        // Applied live when Settings is saved, not on the next launch.
        placementWatch = preferences.$iconPlacement
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] placement in self?.applyIconPlacement(placement) }

        // The icon follows the send: a paper plane while it is in flight, then a
        // brief check or alert. With the panel closed this is the only sign a
        // send happened at all, so it is feedback first and whimsy second.
        activityWatch = model.$activity
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in self?.showIcon(for: activity) }

        panel = MainPanel(content: { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(
                MenuContentView()
                    .environmentObject(self.model)
                    .environmentObject(self.preferences)
            )
        })

        // Settings opens through SwiftUI, not through show(), so window
        // stacking follows key windows generally rather than just the panel.
        windowObservers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { self?.arrange(keyWindow: window) }
            },
        ]

        // Launching the app means wanting to use it: open the main panel, not
        // Settings.
        show()
    }

    /// Opening the app again while it is running — from Finder, Spotlight, or
    /// its Dock icon — brings up the panel. Returning false stops SwiftUI's
    /// default, which would open Settings as the only window it knows about.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel?.isVisible != true { show() }
        return false
    }

    private func activationPolicy(for placement: IconPlacement) -> NSApplication.ActivationPolicy {
        // Regular is what brings a Dock icon — and, with it, LittleSend's own
        // menus in the menu bar. Accessory has neither.
        placement.showsDockIcon ? .regular : .accessory
    }

    private func applyIconPlacement(_ placement: IconPlacement) {
        statusItem?.isVisible = placement.showsMenuBarIcon

        let policy = activationPolicy(for: placement)
        guard NSApp.activationPolicy() != policy else { return }
        // Leaving the Dock deactivates the app, which would drop the Settings
        // window this was just saved in behind whatever sits under it. Bring it
        // straight back once the switch has gone through.
        let front = NSApp.keyWindow
        NSApp.setActivationPolicy(policy)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            front?.makeKeyAndOrderFront(nil)
        }
    }

    /// The panel floats so it survives a trip to Finder, but a floating window
    /// sits above every normal one — Settings included, however it is
    /// activated. So the panel floats only while it is the window in use, and
    /// steps down to normal level whenever Settings or the file chooser takes
    /// over, letting that window come all the way to the front.
    private func arrange(keyWindow window: NSWindow?) {
        guard let window, window.styleMask.contains(.titled) else { return }
        if panel?.owns(window) == true {
            panel?.setFloating(true)
        } else {
            panel?.setFloating(false)
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
        }
    }

    private func showIcon(for activity: AppModel.Activity) {
        resetIcon?.cancel()

        let symbol: String
        let label: String
        let linger: TimeInterval?
        switch activity {
        case .idle: (symbol, label, linger) = ("arrow.up.doc.fill", "LittleSend", nil)
        case .sending: (symbol, label, linger) = ("paperplane.fill", "LittleSend — sending", nil)
        case .succeeded: (symbol, label, linger) = ("checkmark.circle.fill", "LittleSend — sent", 2.5)
        // Longer, because a failure is worth noticing and the panel may be shut.
        case .failed: (symbol, label, linger) = ("exclamationmark.circle.fill", "LittleSend — send failed", 5)
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        statusItem?.button?.image = image

        guard let linger else { return }
        let work = DispatchWorkItem { [weak self] in self?.model.acknowledgeActivity() }
        resetIcon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
    }

    @objc private func toggle() {
        if panel?.isVisible == true {
            panel?.toggle(relativeTo: statusItem?.button)
        } else {
            show()
        }
    }

    func show() {
        // Filling and focusing happen here rather than in the view's onAppear:
        // the panel is built once and reused, so onAppear fires on the first
        // open only and every reopen after it would arrive stale and unfocused.
        model.prefill()
        model.requestFocus()
        // Under the menu bar icon when there is one; otherwise near the top
        // of the screen.
        let anchor = preferences.iconPlacement.showsMenuBarIcon ? statusItem?.button : nil
        panel?.show(relativeTo: anchor)
    }
}

/// A transparent view over the status button that accepts a dragged file.
/// Clicks fall through, so the button still opens the panel.
private final class FileDropView: NSView {
    private let onDrop: (URL) -> Void

    init(onDrop: @escaping (URL) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(from: sender) else { return false }
        onDrop(url)
        return true
    }

    private func droppedURL(from sender: NSDraggingInfo) -> URL? {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first
    }
}

@main
struct LittleSendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A placeholder that is never inserted, so it shows nothing. It exists
        // to come first: with Settings as the only scene, SwiftUI treats it as
        // the app's main window and opens it at launch. The status item and
        // panel are AppKit, owned by the delegate, which opens the panel itself.
        MenuBarExtra("LittleSend", systemImage: "arrow.up.doc.fill", isInserted: .constant(false)) {
            EmptyView()
        }

        // The panel is an AppKit window, so Settings is the only real SwiftUI
        // scene.
        Settings {
            SettingsView()
                .environmentObject(delegate.preferences)
        }
        .commands {
            // An app with only a Settings scene gets no File menu from SwiftUI
            // at all, so the menu bar would jump from LittleSend to Edit.
            CommandGroup(replacing: .newItem) {
                Button("Choose File to Send…") {
                    delegate.show()
                    delegate.model.chooseFile()
                }
                .keyboardShortcut("o")
            }
        }
    }
}
