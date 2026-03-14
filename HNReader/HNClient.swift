import Foundation

struct HNClient: Sendable {
    private static let baseURL = "https://hn.algolia.com/api/v1"

    func fetchStories(minPoints: Int, limit: Int = 200) async throws -> [Story] {
        guard var components = URLComponents(string: "\(Self.baseURL)/search_by_date") else {
            throw HNClientError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "numericFilters", value: "points>=\(minPoints)"),
            URLQueryItem(name: "hitsPerPage", value: "\(limit)"),
        ]

        guard let url = components.url else {
            throw HNClientError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw HNClientError.requestFailed(statusCode: code)
        }

        let decoded = try JSONDecoder().decode(AlgoliaResponse.self, from: data)
        return decoded.hits
    }
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
