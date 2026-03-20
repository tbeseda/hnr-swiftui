import SwiftUI

@main
struct HNReaderApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 550, height: NSScreen.main?.visibleFrame.height ?? 800)

        Settings {
            SettingsView()
        }
    }
}
