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

    func refresh(minPoints: Int, lastSeenStoryID: String) async -> String {
        isLoading = true
        error = nil
        newStoryCount = 0
        resetCheckedIDsIfThresholdChanged(minPoints)

        // The current topmost story becomes the new "last seen" after refresh
        let previousTopID = stories.first?.storyID ?? lastSeenStoryID

        // Snapshot current IDs before replacing
        let currentIDs = Set(stories.map(\.storyID))

        // Surface what the store already knows immediately (background-check
        // finds, threshold changes); the network pass settles scores after
        stories = displayList(minPoints: minPoints)

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

        // Only track previous IDs after the first load (not on launch)
        if !currentIDs.isEmpty {
            previousStoryIDs = currentIDs
        }

        isLoading = false

        // Return the ID that should become the new lastSeenStoryID
        // On first launch (no previous ID), use the current top story so no divider shows
        if previousTopID.isEmpty {
            return stories.first?.storyID ?? ""
        }
        return previousTopID
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
