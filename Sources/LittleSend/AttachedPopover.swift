import AppKit
import SwiftUI

/// The panel as a popover hanging from the menu bar icon — the default way
/// LittleSend opens.
///
/// It closes when you click away, like any menu bar popover. Dragging it away
/// from the icon pulls it off into a window of its own, which then stays put:
/// that is AppKit's own popover detaching, so the content (and anything typed
/// into it) moves with it rather than being rebuilt.
@MainActor
final class AttachedPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let host: NSHostingController<AnyView>
    private let chrome = PopoverChrome()
    /// When the popover last closed. A click on the menu bar icon closes a
    /// transient popover on mouse-down, before the icon's own action runs on
    /// mouse-up; without this, that action would see it closed and reopen it.
    private(set) var lastClosed = Date.distantPast

    init(content: AnyView) {
        host = NSHostingController(rootView: AnyView(DetachedInset(chrome: chrome) { content }))
        // The popover follows the SwiftUI content's size, growing and shrinking
        // as the panel moves between steps.
        host.sizingOptions = [.preferredContentSize]
        super.init()
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }
    /// Shown and still hanging from the icon, rather than pulled off.
    var isAttached: Bool { popover.isShown && !popover.isDetached }
    /// The popover's window — the arrowed one while attached, the standalone
    /// one once detached.
    var window: NSWindow? { popover.isShown ? host.view.window : nil }

    func show(relativeTo button: NSStatusBarButton) {
        // Frontmost first, so typing goes to the URL field and LittleSend's
        // menus take the menu bar.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        host.view.window?.makeKey()
    }

    func close() {
        popover.close()
    }

    // MARK: - NSPopoverDelegate

    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        chrome.isDetached = true
    }

    func popoverDidClose(_ notification: Notification) {
        lastClosed = Date()
        // The next open hangs from the icon again.
        chrome.isDetached = false
    }
}

/// Whether the popover has been pulled off into a window, for the content to
/// make room for that window's close button.
@MainActor
private final class PopoverChrome: ObservableObject {
    @Published var isDetached = false
}

/// Once detached, AppKit draws a close button over the content's top-left
/// corner, right against the step bar. Extra space above the content keeps it
/// clear; attached, there is no button and no extra space.
private struct DetachedInset<Content: View>: View {
    @ObservedObject var chrome: PopoverChrome
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.top, chrome.isDetached ? 18 : 0)
    }
}
