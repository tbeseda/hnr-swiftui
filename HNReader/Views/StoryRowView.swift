import SwiftUI

private let storyRowViewGutterWidth: CGFloat = 10

struct StoryRowView: View {
    let story: Story
    var isNewlyQualified = false
    var isVisited = false
    var onVisit: () -> Void = {}

    @Environment(AppState.self) private var appState
    @AppStorage("openLinksInBackground") private var openLinksInBackground = false
    @AppStorage("classifyAIStories") private var classifyAIStories = false
    @State private var isExpanded = false

    var body: some View {
        let gutter = storyRowViewGutterWidth

        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(isNewlyQualified ? Color.hnOrange : .clear)
                .frame(width: 6, height: 6)
                .frame(width: gutter)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(story.title)
                        .fontWeight(.medium)
                        .foregroundStyle(isVisited ? .secondary : .primary)
                        .lineLimit(2)
                        .onTapGesture {
                            onVisit()
                            openURL(story.linkURL)
                        }
                        .linkHover(story.linkURL)

                    Spacer()

                    HStack(spacing: 4) {
                        Text(story.timeLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded.toggle() }
                    .pointerOnHover()
                }

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Label("\(story.points)", systemImage: "arrow.up")
                            .foregroundStyle(story.isFrontPage ? Color.hnOrange : .secondary)
                        Label("\(story.commentsCount)", systemImage: "bubble.right")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { openURL(story.hnURL) }
                    .linkHover(story.hnURL)

                    if let hostname = story.hostname {
                        Text(hostname)
                            .foregroundStyle(.tertiary)
                    }

                    if story.isShowHN {
                        storyTag("Show")
                    }
                    if story.isAskHN {
                        storyTag("Ask")
                    }
                    if story.isLaunchHN {
                        storyTag("Launch")
                    }

                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if isExpanded {
                    metadata
                        .padding(.top, 2)

                    if let text = story.plainStoryText {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "text.quote")
                                .foregroundStyle(.tertiary)
                            Text(text)
                                .lineLimit(6)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
                .frame(width: gutter)
        }
        .alignmentGuide(.listRowSeparatorLeading) { d in
            d[.leading] + gutter
        }
    }

    /// Story attributes not worth a place in the collapsed row: author,
    /// absolute time, full link, HN item ID, raw tags, and the AI verdict
    private var metadata: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            metadataRow("Author") {
                Text(story.author)
                    .contentShape(Rectangle())
                    .onTapGesture { openURL(authorURL) }
                    .linkHover(authorURL)
            }
            metadataRow("Posted") {
                Text(story.postedLabel)
                    .monospacedDigit()
            }
            if let url = story.url {
                metadataRow("Link") {
                    Text(url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onVisit()
                            openURL(story.linkURL)
                        }
                        .linkHover(story.linkURL)
                }
            }
            metadataRow("ID") {
                Text(story.storyID)
                    .monospacedDigit()
                    .contentShape(Rectangle())
                    .onTapGesture { openURL(story.hnURL) }
                    .linkHover(story.hnURL)
            }
            metadataRow("Tags") {
                Text(story.tags.joined(separator: ", "))
            }
            if let verdictLabel {
                metadataRow("AI") {
                    Text(verdictLabel)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataRow<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(key)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    /// The stored verdict with the stage, prompt, and model that produced
    /// it, or the pending state while classification is on. Nil hides the
    /// row when the feature is off and nothing was ever classified.
    private var verdictLabel: String? {
        guard let stored = appState.storedVerdict(for: story.storyID) else {
            return classifyAIStories ? "Not yet classified" : nil
        }
        let verdict: String
        switch stored.verdict {
        case .ai: verdict = "AI topic"
        case .notAI: verdict = "Not AI"
        case .unknown: verdict = "Unknown (model gave no answer)"
        }
        let source: String
        switch stored.source {
        case .title: source = "title keywords, "
        case .model: source = "on-device model, "
        case .page: source = "page description, "
        case nil: source = ""
        }
        let stale = stored.isCurrent ? "" : ", stale"
        return "\(verdict) (\(source)prompt v\(stored.promptVersion), model \(stored.modelVersion)\(stale))"
    }

    private var authorURL: URL {
        URL(string: "https://news.ycombinator.com/user?id=\(story.author)")!
    }

    private func openURL(_ url: URL) {
        if openLinksInBackground {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func storyTag(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}
