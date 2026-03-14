import SwiftUI

struct StoryRowView: View {
    let story: Story
    var isNewlyQualified = false
    var isVisited = false
    var onVisit: () -> Void = {}

    private static let gutterWidth: CGFloat = 14

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(isNewlyQualified ? Color.hnOrange : .clear)
                .frame(width: 6, height: 6)
                .frame(width: Self.gutterWidth)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(story.title)
                        .fontWeight(.medium)
                        .foregroundStyle(isVisited ? .secondary : .primary)
                        .lineLimit(2)

                    Spacer()

                    Text(story.timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Label("\(story.points)", systemImage: "arrow.up")
                        .foregroundStyle(story.isFrontPage ? Color.hnOrange : .secondary)
                        .onTapGesture { NSWorkspace.shared.open(story.hnURL) }
                    Label("\(story.commentsCount)", systemImage: "bubble.right")
                        .onTapGesture { NSWorkspace.shared.open(story.hnURL) }

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
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onVisit()
            let url = story.url.flatMap(URL.init(string:)) ?? story.hnURL
            NSWorkspace.shared.open(url)
        }
        .pointerOnHover()
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
