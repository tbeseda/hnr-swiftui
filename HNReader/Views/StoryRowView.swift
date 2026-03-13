import SwiftUI

struct StoryRowView: View {
    let story: Story

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(story.title)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Spacer()

                Text(story.relativeTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label("\(story.points)", systemImage: "arrow.up")
                Label("\(story.commentsCount)", systemImage: "bubble.right")

                if let hostname = story.hostname {
                    Text(hostname)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let url = story.url.flatMap(URL.init(string:)) ?? story.hnURL
            NSWorkspace.shared.open(url)
        }
    }
}
