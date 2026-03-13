import Foundation
import SwiftUI

extension Color {
    /// HN orange: #f97316
    static let hnOrange = Color(red: 0xF9 / 255, green: 0x73 / 255, blue: 0x16 / 255)
}

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

    /// Relative time for today's stories, MM-dd HH:mm for older
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

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
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
