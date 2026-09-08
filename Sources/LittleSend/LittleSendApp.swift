import SwiftUI

@main
struct LittleSendApp: App {
    @StateObject private var model = AppModel(preferences: Preferences())

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
                .environmentObject(model.preferences)
        } label: {
            // The systemImage: convenience initializer renders at a fixed,
            // conservative size with no way to control it, and imageScale's
            // largest named step (.large) still came out visibly smaller than
            // neighboring menu bar icons. An explicit point size is the only
            // way past that ceiling.
            Image(systemName: "arrow.up.doc.fill")
                .font(.system(size: 20))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model.preferences)
        }
    }
}
