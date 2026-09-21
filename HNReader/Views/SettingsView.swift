import SwiftUI

/// Preferences that rarely change. View filters (points threshold, community
/// posts, front page, AI) live in the toolbar filter panel instead.
struct SettingsView: View {
    @AppStorage("openLinksInBackground") private var openLinksInBackground = false
    @AppStorage("refreshInterval") private var refreshInterval = 300
    @AppStorage("showDockBadge") private var showDockBadge = true
    @AppStorage("classifyAIStories") private var classifyAIStories = false
    @Environment(AppState.self) private var appState

    @State private var classifierUnavailableReason: String?

    var body: some View {
        Form {
            Section("Behavior") {
                Picker("Background refresh", selection: $refreshInterval) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
                Toggle("Dock icon badge", isOn: $showDockBadge)
                Toggle("Open links in background", isOn: .constant(false))
                    .disabled(true)
                    .help("Not yet supported — browsers override background open requests")
            }

            Section {
                Toggle("Classify stories with Apple Intelligence", isOn: $classifyAIStories)
                    .disabled(classifierUnavailableReason != nil)
            } header: {
                Text("Experimental")
            } footer: {
                Text(classifierStatus)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350)
        .fixedSize()
        .onAppear {
            openLinksInBackground = false
            classifierUnavailableReason = StoryClassifier.unavailableReason
        }
    }

    private var classifierStatus: String {
        if let reason = classifierUnavailableReason {
            return reason
        }
        guard classifyAIStories else {
            return "Runs the on-device model in the background so the toolbar filter panel can hide AI stories. Turning on Hide AI stories there enables this too. Titles never leave this Mac; the app does fetch page descriptions for the past week's stories, and its keyword list from GitHub."
        }
        let progress = appState.classificationProgress
        let status = "\(progress.classified) of \(progress.total) stories classified. Hide or show them from the toolbar filter panel. Turn this off to stop classifying."
        guard let configError = appState.remoteConfigError else { return status }
        return status + "\n\n" + configError
    }
}
