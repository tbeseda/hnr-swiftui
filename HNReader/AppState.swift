import Foundation

@MainActor @Observable
final class AppState {
    var stories: [Story] = []
    var isLoading = false
    var error: String?

    private let client = HNClient()

    func refresh(minPoints: Int, lastSeenStoryID: String) async -> String {
        isLoading = true
        error = nil

        // The current topmost story becomes the new "last seen" after refresh
        let previousTopID = stories.first?.storyID ?? lastSeenStoryID

        do {
            stories = try await client.fetchStories(minPoints: minPoints)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false

        // Return the ID that should become the new lastSeenStoryID
        // On first launch (no previous ID), use the current top story so no divider shows
        if previousTopID.isEmpty {
            return stories.first?.storyID ?? ""
        }
        return previousTopID
    }
}
