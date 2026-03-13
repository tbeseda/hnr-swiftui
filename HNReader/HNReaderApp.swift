import SwiftUI

@main
struct HNReaderApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .defaultSize(width: 400, height: 1000)
    }
}
