import AppKit
import SwiftUI

/// The app's window: a floating panel that stays put.
///
/// This replaces `MenuBarExtra`'s popover, which dismissed the instant the app
/// resigned key. That made the whole file flow awkward — picking a file up from
/// the Desktop closed the very window you were dragging it to, and the open
/// panel had to survive its own parent disappearing.
///
/// A panel at floating level stays visible while you go and find a file in the
/// Finder, which is the entire point. It is closable and toggled by the menu
/// bar icon, so it is never in the way for long.
@MainActor
final class MainPanel {
    private var panel: NSPanel?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) {
        self.makeContent = content
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Whether `window` is this panel.
    func owns(_ window: NSWindow) -> Bool { window === panel }

    /// Floating keeps the panel above other apps' windows during a drag from
    /// Finder; normal lets the app's own windows, like Settings, sit above it.
    func setFloating(_ floating: Bool) {
        panel?.level = floating ? .floating : .normal
    }

    /// Shows the panel, or hides it if it is already up.
    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible {
            panel?.orderOut(nil)
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let panel = existingOrNewPanel()
        position(panel, under: button)
        // LittleSend becomes the frontmost app when the panel opens, so its
        // name and menus take the menu bar and standard shortcuts like ⌘V go
        // straight to the URL field. Clicking the status item does not
        // activate the app on its own, so it asks explicitly.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 100),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // The point of the change: it must survive the app losing focus.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // The SwiftUI content decides the height (its width is fixed at 530 by
        // the view itself). The panel is sized from the content's measured
        // height explicitly: NSHostingView's preferredContentSize only drives
        // popovers and sheets, so an ordinary window left to it can stay at
        // its initial 100pt, with the content spilling under the title bar.
        let content = makeContent()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self, weak panel] height in
                guard let self, let panel else { return }
                self.fit(panel, toContentHeight: height)
            }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        panel.contentView = hosting

        self.panel = panel
        return panel
    }

    /// Resizes the panel to its content, keeping the top edge where it is so
    /// the panel grows and shrinks downward from the menu bar. The title bar
    /// sits over the content (full-size content view), so its safe-area inset
    /// is added on top of the SwiftUI height.
    private func fit(_ panel: NSPanel, toContentHeight height: CGFloat) {
        let titleBar = panel.contentView?.safeAreaInsets.top ?? 0
        let target = (height + titleBar).rounded(.up)
        var frame = panel.frame
        guard abs(frame.height - target) > 0.5 else { return }
        frame.origin.y = frame.maxY - target
        frame.size.height = target
        panel.setFrame(frame, display: true)
    }

    /// Drops the panel just under the menu bar icon the first time, then leaves
    /// it wherever it was dragged to.
    private func position(_ panel: NSPanel, under button: NSStatusBarButton?) {
        guard panel.frame.origin == .zero, let screen = button?.window?.screen
            ?? NSScreen.main
        else { return }

        panel.layoutIfNeeded()
        let size = panel.frame.size
        let anchorX: CGFloat
        if let frame = button?.window?.frame {
            anchorX = frame.midX - size.width / 2
        } else {
            anchorX = screen.visibleFrame.midX - size.width / 2
        }
        let y = screen.visibleFrame.maxY - size.height - 6

        panel.setFrameOrigin(NSPoint(
            x: min(max(anchorX, screen.visibleFrame.minX + 8),
                   screen.visibleFrame.maxX - size.width - 8),
            y: y
        ))
    }
}
