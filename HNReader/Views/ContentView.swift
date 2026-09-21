import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("minPoints") private var minPoints = 35
    @AppStorage("lastSeenStoryID") private var lastSeenStoryID = ""
    @AppStorage("showCommunityPosts") private var showCommunityPosts = true
    @AppStorage("frontPageOnly") private var frontPageOnly = false
    @AppStorage("refreshInterval") private var refreshInterval = 300
    @AppStorage("showDockBadge") private var showDockBadge = true
    @AppStorage("classifyAIStories") private var classifyAIStories = false
    @AppStorage("hideAIStories") private var hideAIStories = false
    @State private var classifierAvailable = false
    @State private var hasLoaded = false
    @State private var showFilters = false
    @State private var visitedIDs: Set<String> = []
    @State private var filterText = ""

    /// Classification is opted in (Settings) and the on-device model can run
    private var classifierEnabled: Bool { classifyAIStories && classifierAvailable }

    /// The AI filter is on and there is a classifier to back it
    private var isHidingAI: Bool { classifierEnabled && hideAIStories }

    /// Any filter beyond the points threshold is narrowing the list
    private var anyFilterActive: Bool { !showCommunityPosts || frontPageOnly || isHidingAI }

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
        .safeAreaInset(edge: .top, spacing: 0) {
            // The one classifier problem worth a notice: the filter keeps
            // working, but on whatever keyword list loaded last
            if classifyAIStories, let message = appState.remoteConfigError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let url = appState.hoveredURL {
                Text(url.absoluteString)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.bar, in: UnevenRoundedRectangle(topTrailingRadius: 6))
            }
        }
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showFilters.toggle()
                } label: {
                    // Filled while narrowing the list, the Mail convention
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                        .symbolVariant(anyFilterActive ? .fill : .none)
                }
                .help(anyFilterActive ? "Filters (active)" : "Filters")
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FilterPopover(
                        classifierAvailable: classifierAvailable,
                        shownCount: filteredStories.count,
                        totalCount: appState.stories.count,
                        aiCount: aiStoryCount
                    )
                }

                Button {
                    Task { await refresh() }
                } label: {
                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .badge(appState.newStoryCount)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isLoading)
            }
        }
        .task(id: minPoints) {
            // First run is the launch load. Later runs are threshold changes
            // from the filter panel; keying the task on the value cancels a
            // fan-out that a newer value has superseded.
            if hasLoaded {
                await appState.applyThreshold(minPoints: minPoints, classify: classifyAIStories)
            } else {
                hasLoaded = true
                classifierAvailable = StoryClassifier.unavailableReason == nil
                await refresh()
            }
        }
        .task(id: refreshInterval) {
            guard refreshInterval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(refreshInterval))
                await appState.checkForNewStories(
                    minPoints: minPoints,
                    classify: classifyAIStories,
                    hidingAI: isHidingAI
                )
                updateDockBadge()
            }
        }
        .onChange(of: appState.newStoryCount) {
            updateDockBadge()
        }
        .onChange(of: showDockBadge) {
            updateDockBadge()
        }
        .onChange(of: classifyAIStories) {
            // Re-check: the user may have just enabled Apple Intelligence
            classifierAvailable = StoryClassifier.unavailableReason == nil
            if classifierEnabled {
                appState.loadRemoteConfig()
                appState.classifyPendingStories()
            } else {
                appState.stopClassifying()
            }
            appState.recountNewStories(minPoints: minPoints, hidingAI: isHidingAI)
        }
        .onChange(of: hideAIStories) {
            // Hiding is a user action, so the latest verdicts may apply now
            if hideAIStories { appState.syncVerdictSnapshot() }
            appState.recountNewStories(minPoints: minPoints, hidingAI: isHidingAI)
        }
    }

    /// Stories after the community, front-page, and text filters
    private var visibleStories: [Story] {
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

    /// Stories on screen: `visibleStories` minus AI verdicts while hiding
    private var filteredStories: [Story] {
        guard isHidingAI else { return visibleStories }
        return visibleStories.filter { appState.verdicts[$0.storyID] != .ai }
    }

    /// Stories at the current threshold that the classifier marked AI
    private var aiStoryCount: Int {
        appState.stories.filter { appState.verdicts[$0.storyID] == .ai }.count
    }

    private var storyList: some View {
        let indexMap = storyIndexMap
        let stories = filteredStories
        let dividerID = dividerStoryID(in: stories)
        return List {
            ForEach(stories) { story in
                if story.storyID == dividerID {
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

    /// The divider sits above the first displayed story at or before the
    /// last-seen story. Item IDs increase with time, so comparing IDs keeps
    /// the divider in place when a filter hides the last-seen story itself.
    private func dividerStoryID(in stories: [Story]) -> String? {
        guard let lastSeen = Int(lastSeenStoryID) else { return nil }
        return stories.first { (Int($0.storyID) ?? 0) <= lastSeen }?.storyID
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
        // The divider moves in the same frame as the promoted stories;
        // the network pass only settles scores afterward
        lastSeenStoryID = appState.beginRefresh(
            minPoints: minPoints,
            lastSeenStoryID: lastSeenStoryID
        )
        await appState.finishRefresh(minPoints: minPoints, classify: classifyAIStories)

        // First launch ever: mark the top story seen so no divider shows
        if lastSeenStoryID.isEmpty {
            lastSeenStoryID = appState.stories.first?.storyID ?? ""
        }
    }
}
