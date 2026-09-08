import SwiftUI
import AppKit

/// A button that opens the Settings scene and brings it to the front.
///
/// `SettingsLink` is SwiftUI's own way to open Settings, and it is what does
/// the opening here. The single AppKit call is activation: a menubar-only app
/// (`LSUIElement`) is never the active application, so without it the Settings
/// window opens *behind* whatever the user is working in. SwiftUI has no
/// equivalent API, and activating before the link runs means the window is
/// ordered into an app that is already frontmost.
struct SettingsButton<Label: View>: View {
    @ViewBuilder var label: () -> Label

    var body: some View {
        SettingsLink(label: label)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate()
            })
    }
}
