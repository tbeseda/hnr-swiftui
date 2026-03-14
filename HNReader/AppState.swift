import Foundation

@MainActor @Observable
final class AppState {
    var stories: [Story] = []
    var isLoading = false
    var error: String?

    /// Count of new stories found by background checks
    var newStoryCount = 0

    /// Story IDs from the previous refresh -- used to detect newly qualified stories
    private(set) var previousStoryIDs: Set<String> = []

    private let client = HNClient()

    func refresh(minPoints: Int, lastSeenStoryID: String) async -> String {
        isLoading = true
        error = nil
        newStoryCount = 0

        // The current topmost story becomes the new "last seen" after refresh
        let previousTopID = stories.first?.storyID ?? lastSeenStoryID

        // Snapshot current IDs before replacing
        let currentIDs = Set(stories.map(\.storyID))

        do {
            stories = try await client.fetchStories(minPoints: minPoints)
        } catch {
            self.error = error.localizedDescription
        }

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

    /// Background check: fetch stories, count how many are newer than lastSeenStoryID
    func checkForNewStories(minPoints: Int, lastSeenStoryID: String) async {
        guard !lastSeenStoryID.isEmpty else { return }

        do {
            let fresh = try await client.fetchStories(minPoints: minPoints)
            if let divider = fresh.firstIndex(where: { $0.storyID == lastSeenStoryID }) {
                newStoryCount = divider
            } else {
                // lastSeenStoryID not in results -- all stories are newer
                newStoryCount = fresh.count
            }
        } catch {
            // Silently ignore background check failures
        }
    }
}
