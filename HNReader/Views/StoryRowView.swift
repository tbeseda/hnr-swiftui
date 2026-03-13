import SwiftUI

struct StoryRowView: View {
    let story: Story
    var isNewlyQualified = false

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
                        .lineLimit(2)

                    Spacer()

                    Text(story.timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Label("\(story.points)", systemImage: "arrow.up")
                        .onTapGesture { NSWorkspace.shared.open(story.hnURL) }
                    Label("\(story.commentsCount)", systemImage: "bubble.right")
                        .onTapGesture { NSWorkspace.shared.open(story.hnURL) }

                    if let hostname = story.hostname {
                        Text(hostname)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let url = story.url.flatMap(URL.init(string:)) ?? story.hnURL
            NSWorkspace.shared.open(url)
        }
    }
}
