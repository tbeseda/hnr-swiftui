import SwiftUI

struct SettingsView: View {
    @AppStorage("minPoints") private var minPoints = 35
    @AppStorage("showCommunityPosts") private var showCommunityPosts = true
    @AppStorage("frontPageOnly") private var frontPageOnly = false
    @AppStorage("openLinksInBackground") private var openLinksInBackground = false
    @AppStorage("refreshInterval") private var refreshInterval = 300
    @AppStorage("showDockBadge") private var showDockBadge = true

    @State private var draft = Draft()

    struct Draft {
        var minPoints = 35
        var showCommunityPosts = true
        var frontPageOnly = false
        var openLinksInBackground = false
        var refreshInterval = 300
        var showDockBadge = true
    }

    var body: some View {
        Form {
            Section("Stories") {
                TextField("Minimum points", value: $draft.minPoints, format: .number)
                Toggle("Show community posts", isOn: $draft.showCommunityPosts)
                Toggle("Front page only", isOn: $draft.frontPageOnly)
            }

            Section("Behavior") {
                Picker("Background refresh", selection: $draft.refreshInterval) {
                    Text("Never").tag(0)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
                Toggle("Dock icon badge", isOn: $draft.showDockBadge)
                Toggle("Open links in background", isOn: .constant(false))
                    .disabled(true)
                    .help("Not yet supported — browsers override background open requests")
            }
        }
        .formStyle(.grouped)
        .frame(width: 350)
        .fixedSize()
        .onAppear {
            draft.minPoints = minPoints
            draft.showCommunityPosts = showCommunityPosts
            draft.frontPageOnly = frontPageOnly
            draft.refreshInterval = refreshInterval
            draft.showDockBadge = showDockBadge
        }
        .onDisappear {
            minPoints = draft.minPoints
            showCommunityPosts = draft.showCommunityPosts
            frontPageOnly = draft.frontPageOnly
            openLinksInBackground = false
            refreshInterval = draft.refreshInterval
            showDockBadge = draft.showDockBadge
        }
    }
}
