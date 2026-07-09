import Foundation

@MainActor @Observable
final class AppState {
    var stories: [Story] = []
    var isLoading = false
    var error: String?
    var hoveredURL: URL?

    /// Count of new stories found by background checks
    var newStoryCount = 0

    /// Story IDs from the previous refresh -- used to detect newly qualified stories
    private(set) var previousStoryIDs: Set<String> = []

    private let client = HNClient()

    /// Canonical accumulation of every qualifying story the app has seen,
    /// keyed by ID and persisted across launches. The HN API's ranked lists
    /// forget stories after ~2 days, so without this store, infrequent
    /// refreshes would show gaps.
    private var storedStories: [String: Story] = [:]

    /// IDs fetched this session and found below the threshold, kept so
    /// refreshes and background checks skip them while they stay unranked
    private var checkedIDs: Set<Int> = []
    private var checkedMinPoints: Int?

    /// Stories older than this age out of the store and the displayed list
    private static let storeHorizonSeconds = 14 * 24 * 3600

    init() {
        storedStories = Self.loadStore()
    }

    /// Phase 1 of a refresh, synchronous so the UI updates in one frame:
    /// promotes stored stories (background-check finds) into the displayed
    /// list and returns the ID that becomes the new unread divider -- the
    /// story that was on top when refresh was invoked.
    func beginRefresh(minPoints: Int, lastSeenStoryID: String) -> String {
        isLoading = true
        error = nil
        newStoryCount = 0
        resetCheckedIDsIfThresholdChanged(minPoints)

        // The current topmost story becomes the new "last seen"
        let previousTopID = stories.first?.storyID ?? lastSeenStoryID

        // Snapshot displayed IDs before promoting, so newly promoted
        // stories get the "newly qualified" marker immediately
        let currentIDs = Set(stories.map(\.storyID))
        stories = displayList(minPoints: minPoints)
        if !currentIDs.isEmpty {
            previousStoryIDs = currentIDs
        }

        return previousTopID
    }

    /// Phase 2: settle scores and discover risers over the network,
    /// then re-render from the store
    func finishRefresh(minPoints: Int) async {
        do {
            let result = try await client.fetchStories(minPoints: minPoints, checkedIDs: checkedIDs)
            checkedIDs.formUnion(result.belowThresholdIDs)
            for story in result.qualifying {
                storedStories[story.storyID] = story
            }
            pruneStore()
            saveStore()
        } catch {
            self.error = error.localizedDescription
        }

        // Display from the store even when the fetch failed -- stale stories
        // beat an error screen when offline
        stories = displayList(minPoints: minPoints)
        isLoading = false
    }

    /// Background check: find qualifying stories newer than the current top of
    /// the displayed list, fold them into the store, and update the count.
    /// The displayed list only changes on user-initiated refresh.
    func checkForNewStories(minPoints: Int) async {
        guard let topID = stories.first?.storyID, let referenceID = Int(topID) else { return }

        resetCheckedIDsIfThresholdChanged(minPoints)

        do {
            let knownIDs = Set(storedStories.keys.compactMap(Int.init).filter { $0 > referenceID })
            let result = try await client.fetchNewStories(
                minPoints: minPoints,
                newerThan: referenceID,
                knownIDs: knownIDs,
                checkedIDs: checkedIDs
            )

            checkedIDs.formUnion(result.belowThresholdIDs)
            if !result.qualifying.isEmpty {
                for story in result.qualifying {
                    storedStories[story.storyID] = story
                }
                saveStore()
            }

            newStoryCount = storedStories.values
                .filter { (Int($0.storyID) ?? 0) > referenceID && $0.points >= minPoints }
                .count
        } catch {
            // Silently ignore background check failures
        }
    }

    /// Cached below-threshold verdicts are only valid for the threshold
    /// they were checked against
    private func resetCheckedIDsIfThresholdChanged(_ minPoints: Int) {
        if checkedMinPoints != minPoints {
            checkedIDs = []
            checkedMinPoints = minPoints
        }
    }

    private func displayList(minPoints: Int) -> [Story] {
        storedStories.values
            .filter { $0.points >= minPoints }
            .sorted {
                if $0.createdAtTimestamp != $1.createdAtTimestamp {
                    return $0.createdAtTimestamp > $1.createdAtTimestamp
                }
                return $0.storyID > $1.storyID
            }
    }

    // MARK: - Store persistence

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HNReader", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "stories.json")
    }

    private static func loadStore() -> [String: Story] {
        guard let data = try? Data(contentsOf: storeURL),
              let stories = try? JSONDecoder().decode([Story].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: stories.map { ($0.storyID, $0) })
    }

    private func saveStore() {
        guard let data = try? JSONEncoder().encode(Array(storedStories.values)) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    private func pruneStore() {
        let cutoff = Int(Date().timeIntervalSince1970) - Self.storeHorizonSeconds
        storedStories = storedStories.filter { $0.value.createdAtTimestamp >= cutoff }
    }
}
