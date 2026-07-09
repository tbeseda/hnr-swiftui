import Foundation

struct HNClient: Sendable {
    private static let baseURL = "https://hacker-news.firebaseio.com/v0"

    /// How many of the top-ranked stories count as "front page"
    private static let frontPageCount = 30

    // The API is HTTP/1.1 only, so item fan-out speed is bounded by
    // connection count. Measured July 2026: 40 connections halve the
    // fan-out time vs 20; 64 is slower again, so 40 is the sweet spot.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 40
        return URLSession(configuration: config)
    }()

    /// Fetches the union of HN "top" (~500, front-page ranking), "best"
    /// (~200, highest-scoring recent), and "new" (~500, every submission
    /// regardless of score) story lists and splits items at the points
    /// threshold. `checkedIDs` (fetched earlier this session, below
    /// threshold) are skipped unless currently ranked -- unranked scores
    /// are effectively frozen, so a story can't cross the threshold
    /// without first re-entering the rankings.
    func fetchStories(minPoints: Int, checkedIDs: Set<Int> = []) async throws -> FetchResult {
        async let topList = fetchIDs("topstories")
        async let bestList = fetchIDs("beststories")
        async let newList = fetchIDs("newstories")
        let (top, best, new) = try await (topList, bestList, newList)

        let ranked = Set(top).union(best)
        let candidates = ranked.union(new).filter {
            !checkedIDs.contains($0) || ranked.contains($0)
        }

        let items = await fetchItems(Array(candidates))
        return Self.split(items, minPoints: minPoints, frontPageIDs: Set(top.prefix(Self.frontPageCount)))
    }

    /// Finds qualifying stories submitted after the reference ID. Item IDs
    /// increase monotonically, so only list IDs above the reference need
    /// fetching: newstories covers every submission (~8h deep) and
    /// topstories catches older risers. `knownIDs` (already stored) are
    /// never fetched; `checkedIDs` follow the same ranked-recheck rule as
    /// in `fetchStories`.
    func fetchNewStories(
        minPoints: Int,
        newerThan referenceID: Int,
        knownIDs: Set<Int>,
        checkedIDs: Set<Int>
    ) async throws -> FetchResult {
        async let topList = fetchIDs("topstories")
        async let newList = fetchIDs("newstories")
        let (top, new) = try await (topList, newList)

        let ranked = Set(top)
        let candidates = ranked.union(new).filter { id in
            id > referenceID
                && !knownIDs.contains(id)
                && (!checkedIDs.contains(id) || ranked.contains(id))
        }

        let items = await fetchItems(Array(candidates))
        return Self.split(items, minPoints: minPoints, frontPageIDs: Set(top.prefix(Self.frontPageCount)))
    }

    private static func split(_ items: [HNItem], minPoints: Int, frontPageIDs: Set<Int>) -> FetchResult {
        var qualifying: [Story] = []
        var belowThreshold: [Int] = []
        for item in items {
            if let story = Story(item: item, isFrontPage: frontPageIDs.contains(item.id)),
               story.points >= minPoints {
                qualifying.append(story)
            } else {
                belowThreshold.append(item.id)
            }
        }
        return FetchResult(qualifying: qualifying, belowThresholdIDs: belowThreshold)
    }

    private func fetchIDs(_ list: String) async throws -> [Int] {
        try JSONDecoder().decode([Int].self, from: await fetch(path: "\(list).json"))
    }

    /// Fetches items concurrently, dropping failures and non-stories
    private func fetchItems(_ ids: [Int]) async -> [HNItem] {
        await withTaskGroup(of: HNItem?.self) { group in
            for id in ids {
                group.addTask { try? await fetchItem(id) }
            }
            var items: [HNItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    private func fetchItem(_ id: Int) async throws -> HNItem? {
        let data = try await fetch(path: "item/\(id).json")
        // Deleted or unpropagated items return literal "null"
        if data == Data("null".utf8) { return nil }
        return try JSONDecoder().decode(HNItem.self, from: data)
    }

    private func fetch(path: String) async throws -> Data {
        guard let url = URL(string: "\(Self.baseURL)/\(path)") else {
            throw HNClientError.invalidURL
        }

        let (data, response) = try await Self.session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HNClientError.requestFailed(statusCode: code)
        }

        return data
    }
}

/// Result of an item fan-out, split at the points threshold
struct FetchResult: Sendable {
    let qualifying: [Story]
    /// Fetched but below the points threshold -- callers cache these to
    /// avoid refetching while the story stays unranked
    let belowThresholdIDs: [Int]
}

/// Raw item from the HN Firebase API -- most fields are absent on
/// deleted/dead items, so everything but `id` is optional
struct HNItem: Decodable, Sendable {
    let id: Int
    let type: String?
    let by: String?
    let title: String?
    let url: String?
    let score: Int?
    let descendants: Int?
    let time: Int?
    let text: String?
    let dead: Bool?
    let deleted: Bool?
}

enum HNClientError: Error, LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Failed to build API URL"
        case .requestFailed(let code): "HN API returned status \(code)"
        }
    }
}
