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

    /// Background check: count stories newer than the current top of the displayed list
    func checkForNewStories(minPoints: Int) async {
        guard let topID = stories.first?.storyID else { return }

        do {
            let fresh = try await client.fetchStories(minPoints: minPoints)
            if let topIndex = fresh.firstIndex(where: { $0.storyID == topID }) {
                newStoryCount = topIndex
            } else {
                // Current top story not in results -- all stories are newer
                newStoryCount = fresh.count
            }
        } catch {
            // Silently ignore background check failures
        }
    }
}
