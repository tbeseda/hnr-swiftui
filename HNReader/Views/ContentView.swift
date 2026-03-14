import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("minPoints") private var minPoints = 35
    @AppStorage("lastSeenStoryID") private var lastSeenStoryID = ""
    @State private var visitedIDs: Set<String> = []

    var body: some View {
        Group {
            if appState.isLoading && appState.stories.isEmpty {
                ProgressView("Loading stories...")
            } else if let error = appState.error, appState.stories.isEmpty {
                VStack(spacing: 8) {
                    Text("Failed to load stories")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await refresh() }
                    }
                }
            } else {
                storyList
            }
        }
        .frame(minWidth: 380, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .overlay(alignment: .topTrailing) {
                            if appState.newStoryCount > 0 {
                                Text("\(appState.newStoryCount)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.hnOrange, in: Capsule())
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isLoading)
            }
        }
        .task {
            await refresh()
        }
        .task(id: "background-check") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await appState.checkForNewStories(
                    minPoints: minPoints,
                    lastSeenStoryID: lastSeenStoryID
                )
                updateDockBadge()
            }
        }
        .onChange(of: appState.newStoryCount) {
            updateDockBadge()
        }
    }

    private var storyList: some View {
        List {
            ForEach(appState.stories) { story in
                if story.storyID == lastSeenStoryID {
                    UnreadDivider()
                        .listRowSeparator(.hidden)
                }
                StoryRowView(
                    story: story,
                    isNewlyQualified: isNewlyQualified(story),
                    isVisited: visitedIDs.contains(story.storyID),
                    onVisit: { visitedIDs.insert(story.storyID) }
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up")
                TextField("", value: $minPoints, format: .number)
                    .frame(width: 32)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await refresh() } }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .overlay {
            if appState.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding()
            }
        }
    }

    /// Story is newly qualified if it's below the divider and wasn't in the previous refresh
    private func isNewlyQualified(_ story: Story) -> Bool {
        guard !appState.previousStoryIDs.isEmpty else { return false }
        // Only applies to stories at or below the divider (previously seen region)
        let dividerIndex = appState.stories.firstIndex { $0.storyID == lastSeenStoryID }
        let storyIndex = appState.stories.firstIndex { $0.storyID == story.storyID }
        guard let divider = dividerIndex, let idx = storyIndex, idx >= divider else {
            return false
        }
        return !appState.previousStoryIDs.contains(story.storyID)
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = appState.newStoryCount > 0
            ? "\(appState.newStoryCount)"
            : nil
    }

    private func refresh() async {
        lastSeenStoryID = await appState.refresh(
            minPoints: minPoints,
            lastSeenStoryID: lastSeenStoryID
        )
    }
}
