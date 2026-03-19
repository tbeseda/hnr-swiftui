import Foundation

struct Story: Decodable, Identifiable, Hashable, Sendable {
    let storyID: String
    let title: String
    let author: String
    let url: String?
    let points: Int
    let commentsCount: Int
    let createdAtTimestamp: Int
    let tags: [String]

    var id: String { storyID }

    var isShowHN: Bool { tags.contains("show_hn") }
    var isAskHN: Bool { tags.contains("ask_hn") }
    var isLaunchHN: Bool { tags.contains("launch_hn") }
    var isFrontPage: Bool { tags.contains("front_page") }

    /// Hostname extracted from URL, e.g. "github.com"
    var hostname: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// URL to the HN discussion page
    var hnURL: URL {
        URL(string: "https://news.ycombinator.com/item?id=\(storyID)")!
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

    enum CodingKeys: String, CodingKey {
        case storyID = "objectID"
        case title
        case author
        case url
        case points
        case commentsCount = "num_comments"
        case createdAtTimestamp = "created_at_i"
        case tags = "_tags"
    }
}

struct AlgoliaResponse: Decodable, Sendable {
    let hits: [Story]
}
