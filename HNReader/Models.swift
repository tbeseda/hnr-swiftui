import Foundation

struct Story: Identifiable, Hashable, Sendable, Codable {
    let storyID: String
    let title: String
    let author: String
    let url: String?
    let points: Int
    let commentsCount: Int
    let createdAtTimestamp: Int
    let tags: [String]
    let storyText: String?

    var id: String { storyID }

    var isShowHN: Bool { tags.contains("show_hn") }
    var isAskHN: Bool { tags.contains("ask_hn") }
    var isLaunchHN: Bool { tags.contains("launch_hn") }
    var isFrontPage: Bool { tags.contains("front_page") }

    /// Self-post text with HTML stripped and entities decoded
    var plainStoryText: String? {
        guard let storyText, !storyText.isEmpty else { return nil }
        var text = storyText
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#x2F;", with: "/")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Hostname extracted from URL, e.g. "github.com"
    var hostname: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// URL to the HN discussion page
    var hnURL: URL {
        URL(string: "https://news.ycombinator.com/item?id=\(storyID)")!
    }

    /// The story's external URL, falling back to the HN discussion page
    var linkURL: URL {
        url.flatMap(URL.init(string:)) ?? hnURL
    }

    /// Relative time for today's stories, short day-of-week + time for older
    var timeLabel: String {
        let date = Date(timeIntervalSince1970: Double(createdAtTimestamp))

        if Calendar.current.isDateInToday(date) {
            let elapsed = Int(Date().timeIntervalSince1970) - createdAtTimestamp
            if elapsed < 60 {
                return "\(elapsed)s ago"
            } else if elapsed < 3600 {
                return "\(elapsed / 60)m ago"
            } else {
                return "\(elapsed / 3600)h ago"
            }
        }

        return Self.olderDateFormatter.string(from: date)
    }

    private static let olderDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    /// Builds a Story from a Firebase API item, or nil for non-stories
    /// and deleted/dead items. Tags are derived: the Firebase API has no
    /// tag field, but Show/Ask/Launch HN are title conventions and
    /// front-page membership comes from the top-stories ranking.
    init?(item: HNItem, isFrontPage: Bool) {
        guard item.type == "story",
              item.deleted != true, item.dead != true,
              let title = item.title,
              let time = item.time else { return nil }

        var tags = ["story"]
        let lowered = title.lowercased()
        if lowered.hasPrefix("show hn") { tags.append("show_hn") }
        if lowered.hasPrefix("ask hn") { tags.append("ask_hn") }
        if lowered.hasPrefix("launch hn") { tags.append("launch_hn") }
        if isFrontPage { tags.append("front_page") }

        self.storyID = String(item.id)
        self.title = title
        self.author = item.by ?? ""
        self.url = item.url
        self.points = item.score ?? 0
        self.commentsCount = item.descendants ?? 0
        self.createdAtTimestamp = time
        self.tags = tags
        self.storyText = item.text
    }
}
