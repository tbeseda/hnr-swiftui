import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("minPoints") private var minPoints = 35
    @AppStorage("lastSeenStoryID") private var lastSeenStoryID = ""
    @AppStorage("showCommunityPosts") private var showCommunityPosts = true
    @AppStorage("frontPageOnly") private var frontPageOnly = false
    @AppStorage("refreshInterval") private var refreshInterval = 300
    @AppStorage("showDockBadge") private var showDockBadge = true
    @State private var visitedIDs: Set<String> = []
    @State private var filterText = ""

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
        .frame(minWidth: 550, minHeight: 400)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .padding(.horizontal, 4)
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .overlay(alignment: .topTrailing) {
                                if appState.newStoryCount > 0 {
                                    Text("\(appState.newStoryCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(Color.hnOrange, in: Capsule())
                                        .fixedSize()
                                        .offset(x: 10, y: -6)
                                }
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
        .task(id: refreshInterval) {
            guard refreshInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                await appState.checkForNewStories(minPoints: minPoints)
                updateDockBadge()
            }
        }
        .onChange(of: minPoints) {
            Task { await refresh() }
        }
        .onChange(of: appState.newStoryCount) {
            updateDockBadge()
        }
        .onChange(of: showDockBadge) {
            updateDockBadge()
        }
    }

    private var filteredStories: [Story] {
        let query = filterText.lowercased()
        return appState.stories.filter { story in
            if !showCommunityPosts && (story.isShowHN || story.isAskHN || story.isLaunchHN) {
                return false
            }
            if frontPageOnly && !story.isFrontPage {
                return false
            }
            if !query.isEmpty {
                return story.title.lowercased().contains(query)
                    || story.hostname?.lowercased().contains(query) == true
            }
            return true
        }
    }

    private var storyList: some View {
        let indexMap = storyIndexMap
        return List {
            ForEach(filteredStories) { story in
                if story.storyID == lastSeenStoryID {
                    UnreadDivider()
                        .listRowSeparator(.hidden)
                }
                StoryRowView(
                    story: story,
                    isNewlyQualified: isNewlyQualified(story, indexMap: indexMap),
                    isVisited: visitedIDs.contains(story.storyID),
                    onVisit: { visitedIDs.insert(story.storyID) }
                )
            }
        }
    }

    /// Map of story ID to index in the full story list, computed once per render
    private var storyIndexMap: [String: Int] {
        Dictionary(uniqueKeysWithValues: appState.stories.enumerated().map { ($1.storyID, $0) })
    }

    /// Story is newly qualified if it's below the divider and wasn't in the previous refresh
    private func isNewlyQualified(_ story: Story, indexMap: [String: Int]) -> Bool {
        guard !appState.previousStoryIDs.isEmpty else { return false }
        guard let divider = indexMap[lastSeenStoryID],
              let idx = indexMap[story.storyID],
              idx >= divider else {
            return false
        }
        return !appState.previousStoryIDs.contains(story.storyID)
    }

    private func updateDockBadge() {
        NSApp.dockTile.badgeLabel = showDockBadge && appState.newStoryCount > 0
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
