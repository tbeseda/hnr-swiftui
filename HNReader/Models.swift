import Foundation

struct Story: Decodable, Identifiable, Hashable, Sendable {
    let storyID: String
    let title: String
    let author: String
    let url: String?
    let points: Int
    let commentsCount: Int
    let createdAtTimestamp: Int

    var id: String { storyID }

    /// Hostname extracted from URL, e.g. "github.com"
    var hostname: String? {
        guard let url, let host = URL(string: url)?.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// URL to the HN discussion page
    var hnURL: URL {
        URL(string: "https://news.ycombinator.com/item?id=\(storyID)")!
    }

    /// Relative time string, e.g. "2h ago", "15m ago"
    var relativeTime: String {
        let now = Int(Date().timeIntervalSince1970)
        let elapsed = now - createdAtTimestamp
        if elapsed < 60 {
            return "\(elapsed)s ago"
        } else if elapsed < 3600 {
            return "\(elapsed / 60)m ago"
        } else if elapsed < 86400 {
            return "\(elapsed / 3600)h ago"
        } else {
            return "\(elapsed / 86400)d ago"
        }
    }

    enum CodingKeys: String, CodingKey {
        case storyID = "objectID"
        case title
        case author
        case url
        case points
        case commentsCount = "num_comments"
        case createdAtTimestamp = "created_at_i"
    }
}

struct AlgoliaResponse: Decodable, Sendable {
    let hits: [Story]
}
