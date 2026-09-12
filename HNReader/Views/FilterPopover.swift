import SwiftUI

/// The toolbar filter panel. These are view filters people flip
/// situationally, so they live next to the list and apply immediately;
/// Settings keeps the preferences that rarely change. Counts are spelled
/// out here in words instead of squeezed into toolbar badges.
struct FilterPopover: View {
    // Read here rather than passed in: only this small view re-renders as
    // the classifier's progress ticks, not the whole story list
    @Environment(AppState.self) private var appState
    @AppStorage("minPoints") private var minPoints = 35
    @AppStorage("showCommunityPosts") private var showCommunityPosts = true
    @AppStorage("frontPageOnly") private var frontPageOnly = false
    @AppStorage("classifyAIStories") private var classifyAIStories = false
    @AppStorage("hideAIStories") private var hideAIStories = false
    @FocusState private var pointsFocused: Bool

    /// The on-device model can run on this Mac
    let classifierAvailable: Bool
    let shownCount: Int
    let totalCount: Int
    let aiCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Minimum points") {
                // The formatted field commits on Enter or focus loss, not per
                // keystroke, so typing "100" doesn't fan out at 1 and 10
                TextField("Points", value: $minPoints, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                    .focused($pointsFocused)
                Stepper("Minimum points", value: $minPoints, in: 1...1000, step: 5)
                    .labelsHidden()
            }

            Toggle("Community posts", isOn: $showCommunityPosts)
            Toggle("Front page only", isOn: $frontPageOnly)

            if classifierAvailable {
                Toggle(isOn: $hideAIStories) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hide AI stories")
                        Text(aiStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Text("Showing \(shownCount) of \(totalCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 260)
        // The popover hands first responder to the points field on open,
        // selecting its text so any keystroke replaced the threshold.
        // Neither `defaultFocus(_, false)` nor resigning in `.task` at
        // appearance prevents it; the assignment lands a beat later, so
        // resign after the presentation settles.
        .task {
            try? await Task.sleep(for: .milliseconds(150))
            pointsFocused = false
        }
        .onChange(of: hideAIStories) {
            // Hiding needs verdicts, so the first use opts in to classification;
            // Settings > Experimental is the switch to turn it back off
            if hideAIStories { classifyAIStories = true }
        }
    }

    private var aiStatus: String {
        guard classifyAIStories else {
            return "Classifies titles on this Mac with Apple Intelligence"
        }
        let progress = appState.classificationProgress
        if progress.classified < progress.total {
            return "Classifying \(progress.classified) of \(progress.total) stories"
        }
        return "\(aiCount) of \(totalCount) stories are AI"
    }
}
