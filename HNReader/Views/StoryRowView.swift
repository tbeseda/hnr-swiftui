import SwiftUI

private let storyRowViewGutterWidth: CGFloat = 10

struct StoryRowView: View {
    let story: Story
    var isNewlyQualified = false
    var isVisited = false
    var onVisit: () -> Void = {}

    @AppStorage("openLinksInBackground") private var openLinksInBackground = false
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
                            let url = story.url.flatMap(URL.init(string:)) ?? story.hnURL
                            openURL(url)
                        }
                        .pointerOnHover()

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
                    Label("\(story.points)", systemImage: "arrow.up")
                        .foregroundStyle(story.isFrontPage ? Color.hnOrange : .secondary)
                        .onTapGesture { openURL(story.hnURL) }
                        .pointerOnHover()
                    Label("\(story.commentsCount)", systemImage: "bubble.right")
                        .onTapGesture { openURL(story.hnURL) }
                        .pointerOnHover()

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
                    Label(story.author, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            openURL(URL(string: "https://news.ycombinator.com/user?id=\(story.author)")!)
                        }
                        .pointerOnHover()
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
