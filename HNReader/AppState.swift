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

    /// AI-topic verdicts the displayed list is filtered by. A snapshot of
    /// `storedVerdicts` taken wherever `stories` is assigned, so verdicts
    /// landing in the background never remove a story mid-session -- they
    /// take effect at the next refresh, like everything else.
    private(set) var verdicts: [String: AIVerdict] = [:]

    private let client = HNClient()
    private let classifier = StoryClassifier()

    /// Canonical accumulation of every qualifying story the app has seen,
    /// keyed by ID and persisted across launches. The HN API's ranked lists
    /// forget stories after ~2 days, so without this store, infrequent
    /// refreshes would show gaps.
    private var storedStories: [String: Story] = [:]

    /// Verdicts for stored stories, persisted next to the store and written
    /// by the background classifier pass
    private var storedVerdicts: [String: StoredVerdict] = [:]
    private var classifyTask: Task<Void, Never>?

    /// IDs fetched this session and found below the threshold, kept so
    /// refreshes and background checks skip them while they stay unranked
    private var checkedIDs: Set<Int> = []
    private var checkedMinPoints: Int?

    /// Stories older than this age out of the store and the displayed list
    private static let storeHorizonSeconds = 14 * 24 * 3600

    init() {
        storedStories = Self.loadStore()
        storedVerdicts = Self.loadVerdicts()
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
        syncVerdictSnapshot()
        stories = displayList(minPoints: minPoints)
        if !currentIDs.isEmpty {
            previousStoryIDs = currentIDs
        }

        return previousTopID
    }

    /// Phase 2: settle scores and discover risers over the network, then
    /// re-render from the store. With `classify` on, a background pass then
    /// picks up whatever the fan-out stored.
    func finishRefresh(minPoints: Int, classify: Bool) async {
        do {
            let result = try await client.fetchStories(minPoints: minPoints, checkedIDs: checkedIDs)
            checkedIDs.formUnion(result.belowThresholdIDs)
            for story in result.qualifying {
                storedStories[story.storyID] = story
            }
            pruneStore()
            saveStore()
            saveVerdicts()
        } catch {
            // Superseded by a newer threshold change: that task owns the
            // state from here, including `isLoading`
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }

        // Display from the store even when the fetch failed -- stale stories
        // beat an error screen when offline
        syncVerdictSnapshot()
        stories = displayList(minPoints: minPoints)
        isLoading = false
        if classify { classifyPendingStories() }
    }

    /// Threshold change from the filter panel. Re-renders from the store at
    /// once (raising the bar needs no network: the store already holds
    /// everything above the old one), then fans out for stories that now
    /// qualify when the bar was lowered. No `beginRefresh`, so the unread
    /// divider and the new-story count stay put -- changing a filter is not
    /// "I've read these".
    func applyThreshold(minPoints: Int, classify: Bool) async {
        let previous = checkedMinPoints
        resetCheckedIDsIfThresholdChanged(minPoints)
        error = nil
        syncVerdictSnapshot()
        stories = displayList(minPoints: minPoints)

        // Either branch settles `isLoading`: a superseded fan-out that this
        // change cancelled returned early and left it set
        if let previous, minPoints < previous {
            isLoading = true
            await finishRefresh(minPoints: minPoints, classify: classify)
        } else {
            isLoading = false
        }
    }

    /// Background check: find qualifying stories newer than the current top of
    /// the displayed list, fold them into the store, and update the count.
    /// The displayed list only changes on user-initiated refresh. With
    /// `classify` on, the few new finds are classified here, before the
    /// count, so a count that excludes AI stories is right when the badge
    /// updates rather than a second later.
    func checkForNewStories(minPoints: Int, classify: Bool, hidingAI: Bool) async {
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
                if classify { await classifyNow(result.qualifying) }
            }

            recountNewStories(minPoints: minPoints, hidingAI: hidingAI)
        } catch {
            // Silently ignore background check failures
        }

        // Anything still pending (a backlog, or finds classifyNow skipped)
        if classify { classifyPendingStories() }
    }

    /// Stored stories newer than the top of the displayed list that the next
    /// refresh would show -- the toolbar and dock badge number. While hiding,
    /// stories already classified AI don't count, since refresh would hide them.
    func recountNewStories(minPoints: Int, hidingAI: Bool) {
        guard let topID = stories.first?.storyID, let referenceID = Int(topID) else { return }
        newStoryCount = storedStories.values
            .filter {
                (Int($0.storyID) ?? 0) > referenceID
                    && $0.points >= minPoints
                    && !(hidingAI && storedVerdicts[$0.storyID]?.verdict == .ai)
            }
            .count
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

    // MARK: - AI classification

    /// Copies stored verdicts into the display snapshot. Called wherever
    /// `stories` is assigned and when the user turns hiding on -- both are
    /// user actions, which keeps the rule that the list only changes on
    /// user action, never from background work.
    func syncVerdictSnapshot() {
        verdicts = storedVerdicts.mapValues(\.verdict)
    }

    /// Stored stories with a verdict from the current prompt and model, out
    /// of all stored stories -- the Settings status line
    var classificationProgress: (classified: Int, total: Int) {
        let classified = storedStories.keys.filter { storedVerdicts[$0]?.isCurrent == true }.count
        return (classified, storedStories.count)
    }

    /// Starts a background pass over stored stories lacking a current
    /// verdict, newest first, one at a time (~300 ms each). A no-op while a
    /// pass is running; the running pass re-derives the pending list every
    /// iteration, so stories stored mid-pass are picked up. Results reach the
    /// displayed list only at the next refresh, via the `verdicts` snapshot.
    func classifyPendingStories() {
        guard classifyTask == nil, StoryClassifier.unavailableReason == nil else { return }

        classifyTask = Task {
            var unsaved = 0
            while !Task.isCancelled, let story = nextPendingStory() {
                await classifyAndStore(story)
                unsaved += 1
                if unsaved >= 25 {
                    saveVerdicts()
                    unsaved = 0
                }
            }
            if unsaved > 0 { saveVerdicts() }
            // A cancelled pass was already cleared by stopClassifying, and a
            // newer pass may own the slot by now
            if !Task.isCancelled { classifyTask = nil }
        }
    }

    func stopClassifying() {
        classifyTask?.cancel()
        classifyTask = nil
    }

    /// Classifies specific stories right away, awaiting each one. For the
    /// handful a background check finds; the backlog pass skips stories
    /// classified here because it re-derives its pending list.
    private func classifyNow(_ stories: [Story]) async {
        guard StoryClassifier.unavailableReason == nil else { return }
        for story in stories where storedVerdicts[story.storyID]?.isCurrent != true {
            await classifyAndStore(story)
        }
        saveVerdicts()
    }

    private func classifyAndStore(_ story: Story) async {
        let verdict = await classifier.classify(story)
        storedVerdicts[story.storyID] = StoredVerdict(
            verdict: verdict,
            promptVersion: StoryClassifier.promptVersion,
            modelVersion: StoryClassifier.modelVersion
        )
    }

    /// Newest stored story without a verdict from the current prompt and model
    private func nextPendingStory() -> Story? {
        storedStories.values
            .filter { storedVerdicts[$0.storyID]?.isCurrent != true }
            .max { $0.createdAtTimestamp < $1.createdAtTimestamp }
    }

    // MARK: - Store persistence

    private static var storeURL: URL { fileURL("stories.json") }
    private static var verdictsURL: URL { fileURL("verdicts.json") }

    private static func fileURL(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HNReader", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: name)
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

    private static func loadVerdicts() -> [String: StoredVerdict] {
        guard let data = try? Data(contentsOf: verdictsURL),
              let verdicts = try? JSONDecoder().decode([String: StoredVerdict].self, from: data) else {
            return [:]
        }
        return verdicts
    }

    private func saveVerdicts() {
        guard let data = try? JSONEncoder().encode(storedVerdicts) else { return }
        try? data.write(to: Self.verdictsURL, options: .atomic)
    }

    /// Ages stories out of the store and drops verdicts that no longer have a story
    private func pruneStore() {
        let cutoff = Int(Date().timeIntervalSince1970) - Self.storeHorizonSeconds
        storedStories = storedStories.filter { $0.value.createdAtTimestamp >= cutoff }
        storedVerdicts = storedVerdicts.filter { storedStories[$0.key] != nil }
    }
}
