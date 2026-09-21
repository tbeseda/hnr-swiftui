import Foundation

/// Configuration the app fetches from this repo on GitHub, so keyword lists
/// can change without a release. Namespaced by top-level key (`aiKeywords`
/// today) so other settings can join later; unknown keys are ignored, and
/// `schemaVersion` moves only for a change an older app can't read. The
/// same file ships in the bundle as the fallback and as the defaults until
/// a fetch lands.
struct RemoteConfig: Decodable, Sendable {
    static let url = URL(string: "https://raw.githubusercontent.com/tbeseda/hnr-swiftui/main/HNReader/RemoteConfig.json")!
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let aiKeywords: AIKeywords

    /// The copy built into this version of the app. A missing or malformed
    /// resource is a build problem, so this traps rather than degrades.
    static let bundled: RemoteConfig = {
        let url = Bundle.main.url(forResource: "RemoteConfig", withExtension: "json")!
        return try! decode(Data(contentsOf: url))
    }()

    /// Fetches the current file from GitHub. Throws for network failures,
    /// non-200 responses, malformed JSON, an unsupported schema, and keyword
    /// fragments that don't compile; the caller reports all of them.
    static func fetch() async throws -> RemoteConfig {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RemoteConfigError.httpStatus(http.statusCode)
        }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> RemoteConfig {
        let config = try JSONDecoder().decode(RemoteConfig.self, from: data)
        guard config.schemaVersion == supportedSchemaVersion else {
            throw RemoteConfigError.unsupportedSchema(config.schemaVersion)
        }
        return config
    }

    /// One line for the notice. Decoding errors name the key, since the
    /// file is edited by hand.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing \"\(path(context, key))\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "wrong value at \"\(path(context))\""
        case .dataCorrupted(let context):
            let at = path(context)
            return at.isEmpty ? context.debugDescription : "\(context.debugDescription) at \"\(at)\""
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func path(_ context: DecodingError.Context, _ key: (any CodingKey)? = nil) -> String {
        (context.codingPath + [key].compactMap { $0 }).map(\.stringValue).joined(separator: ".")
    }
}

enum RemoteConfigError: LocalizedError {
    case httpStatus(Int)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): "HTTP \(code)"
        case .unsupportedSchema(let version): "schema version \(version) needs a newer app"
        }
    }
}

/// The classifier's keyword lists, compiled. Fragments are ICU regex syntax
/// (`LLMs?`, `Fable \d`). `terms` are wrapped in `\b...\b` and matched
/// case-sensitively, so AI doesn't hit "aim" or lowercase prose; `phrases`
/// and `hosts` match anywhere, case-insensitively, the latter against the
/// story's hostname. `NSRegularExpression` is immutable and `Sendable`, so
/// the compiled lists live in the classifier and compile once per load
/// (Swift `Regex` is neither, and costs ~0.5 ms to compile). Its `\b` is
/// the simple `\w`/`\W` kind, which splits "Claude's" and "5.1" where Swift
/// `Regex`'s default Unicode boundaries treat each as one word.
struct AIKeywords: Decodable, Sendable {
    private let terms: NSRegularExpression?
    private let phrases: NSRegularExpression?
    private let hosts: NSRegularExpression?

    private enum CodingKeys: String, CodingKey {
        case terms, phrases, hosts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terms = try Self.compile(container, .terms, wholeWord: true, options: [])
        phrases = try Self.compile(container, .phrases, options: .caseInsensitive)
        hosts = try Self.compile(container, .hosts, options: .caseInsensitive)
    }

    /// The text names AI outright: a whole-word term or a phrase
    func matches(_ text: String) -> Bool {
        terms.matches(text) || phrases.matches(text)
    }

    func matchesHost(_ host: String) -> Bool {
        hosts.matches(host)
    }

    /// Joins a list into one alternation. An empty list compiles to nil
    /// rather than to `(?:)`, which would match everything.
    private static func compile(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys,
        wholeWord: Bool = false,
        options: NSRegularExpression.Options
    ) throws -> NSRegularExpression? {
        let fragments = try container.decode([String].self, forKey: key)
        guard !fragments.isEmpty else { return nil }
        let body = "(?:" + fragments.joined(separator: "|") + ")"
        do {
            return try NSRegularExpression(pattern: wholeWord ? "\\b\(body)\\b" : body, options: options)
        } catch {
            let bad = fragments.first { (try? NSRegularExpression(pattern: $0, options: options)) == nil } ?? body
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "invalid pattern \"\(bad)\"")
        }
    }
}

private extension Optional where Wrapped == NSRegularExpression {
    func matches(_ text: String) -> Bool {
        self?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
