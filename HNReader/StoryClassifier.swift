import Foundation
import FoundationModels

/// Verdict of the on-device AI-topic classifier for one story
enum AIVerdict: String, Codable, Sendable {
    case ai
    case notAI
    /// The model refused, tripped a guardrail, or answered off-format. The
    /// filter fails open: unknown stories are shown.
    case unknown
}

/// Which stage of the classifier produced a verdict, for the expanded row
enum VerdictSource: String, Codable, Sendable {
    /// The title or hostname matched the keyword lists
    case title
    /// The on-device model judged the title
    case model
    /// The page's description matched the keyword lists after the model said no
    case page
}

/// A verdict pinned to the prompt and model version that produced it, so a
/// prompt change or a new OS model triggers reclassification
struct StoredVerdict: Codable, Sendable {
    let verdict: AIVerdict
    /// Nil on verdicts written before stages were recorded
    let source: VerdictSource?
    let promptVersion: Int
    let modelVersion: String

    var isCurrent: Bool {
        promptVersion == StoryClassifier.promptVersion
            && modelVersion == StoryClassifier.modelVersion
    }
}

/// Classifies a story as AI-topic or not, in three stages: the keyword
/// lists over the title and host, Apple's on-device model over the title,
/// and for recent stories the model said no to, the same keyword lists over
/// the page's description tags.
///
/// Why keywords first (measured Sept 2026 on the "26.4" model, 82 hard
/// negatives = generic titles a permissive prompt had flagged, 44 clear
/// positives): a rubric-style prompt flagged 69 of the 82 negatives. A
/// strict "default is no" prompt flagged 0 of 82 but missed 15 of 44
/// positives, most of which literally contain "AI" or an AI company name.
/// Keywords catch those with 0 false positives and settle ~25% of the store
/// in microseconds.
///
/// Why the page stage is keywords too (measured 21 Sept 2026, 80 newest
/// stories both title stages had passed): the strict prompt shown the page
/// excerpt said yes to 2 of 70, saying no even to "After Anthropic made
/// Fable 5 permanently available". The keyword lists over the description
/// tags flipped 8, six of them AI ("Left-pad strings with TypeSafe AI's
/// Jev"), one wrong. Body text and HN comments were mostly passing mentions.
///
/// The prompt shape is deliberate: one plain-text yes/no prompt per story,
/// fresh session each time, greedy sampling, ~300 ms, 0 refusals over 200
/// titles. Structured (@Generable) output with a rubric was refused 30-100%
/// of the time, batching titles tripped the guardrail every time, and page
/// text in the prompt lowered accuracy. Keep it title + hostname, one story
/// per prompt, plain text out.
struct StoryClassifier: Sendable {
    /// Bump when `instructions`, the prompt format, the stages, or the
    /// built-in keyword lists change
    static let promptVersion = 3

    /// Apple ships distinct on-device models at 26.0, 26.4, and 27.0. Pinning
    /// verdicts to this coarse version rather than the exact OS build avoids a
    /// full reclassification on every point release.
    static var modelVersion: String {
        if #available(macOS 27, *) { return "27.0" }
        if #available(macOS 26.4, *) { return "26.4" }
        return "26.0"
    }

    /// Why the classifier can't run right now, or nil when it can
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model is still downloading"
        case .unavailable:
            return "Apple Intelligence is unavailable"
        }
    }

    /// Stories older than this skip the page stage. The fetch is a request
    /// to the story's host from the user's IP for a story they may never
    /// click, so it is spent on the week's stories, the ones actually read.
    static let pageHorizon: TimeInterval = 7 * 24 * 3600

    /// Read at most this much of a page while looking for `</head>`.
    /// Measured Sept 2026: heads ended by 6 KB at the median, 58 KB at p90,
    /// 247 KB at the worst.
    private static let pageByteLimit = 256 * 1024

    private static let descriptionKeys: Set<String> = [
        "og:description", "twitter:description", "description", "og:title",
    ]

    /// Keyword lists from `RemoteConfig`, compiled
    let keywords: AIKeywords

    /// Separate from `HNClient`'s session: two connections per host, a
    /// short timeout, no cookies or cache, and a User-Agent that says who
    /// is asking. Measured Sept 2026: 75 of 80 hosts answer it.
    private static let pageSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 6
        config.httpShouldSetCookies = false
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        config.httpAdditionalHeaders = [
            "User-Agent": "HNReader/\(version) (macOS; +https://github.com/tbeseda/hnr-swiftui)",
            "Accept": "text/html",
        ]
        return URLSession(configuration: config)
    }()

    /// Strict on purpose: the model sees only titles the keyword pass
    /// didn't settle, and on generic titles it must say no. Rubric bullets
    /// adapted from unslop.news (github.com/leiDnedyA/hn-without-ai).
    private static let instructions = """
    You decide whether a Hacker News submission is about artificial intelligence, from its title alone.

    The default answer is no. Answer yes only when the title itself clearly refers to AI:
    - LLMs, chatbots, generative AI, diffusion models, agents, prompting, RAG, embeddings
    - AI companies, models, or products (OpenAI, Anthropic, Claude, GPT, Gemini, Llama, Copilot, Cursor, Midjourney, ...)
    - AI funding, regulation, safety, hype, backlash, job displacement, or AI-generated media
    - Tooling whose primary purpose is building, serving, or running AI models

    Everything else is no: programming languages, developer tools, hardware, operating systems, security, science, business, politics, and products with no AI angle in the title. A vague or generic title is no. Do not guess at AI content that the title does not mention.
    """

    /// Stage one alone: the verdict when the title or host names AI, else
    /// nil. `AppState` also uses this to apply a new keyword list to stored
    /// verdicts without a model pass.
    func keywordVerdict(for story: Story) -> StoredVerdict? {
        let hit = keywords.matches(story.title) || story.hostname.map(keywords.matchesHost) == true
        return hit ? verdict(.ai, source: .title) : nil
    }

    func classify(_ story: Story) async -> StoredVerdict {
        if let verdict = keywordVerdict(for: story) { return verdict }

        // The page fetch overlaps the model call and is cancelled unawaited
        // when the model says yes, so the pass stays model-bound
        let recent = Date().timeIntervalSince1970 - Double(story.createdAtTimestamp) < Self.pageHorizon
        async let page: String? = recent ? await pageDescription(of: story) : nil
        let fromModel = await modelVerdict(for: story)
        if fromModel != .ai, let description = await page, keywords.matches(description) {
            return verdict(.ai, source: .page)
        }
        return verdict(fromModel, source: .model)
    }

    private func modelVerdict(for story: Story) async -> AIVerdict {
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = """
        Title: \(story.title)
        Site: \(story.hostname ?? "(self post)")
        Is this submission about AI? Answer only yes or no.
        """

        // Refusals, guardrail violations, and context errors all fail open
        guard let response = try? await session.respond(
            to: prompt,
            options: GenerationOptions(sampling: .greedy)
        ) else { return .unknown }

        let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if answer.hasPrefix("yes") { return .ai }
        if answer.hasPrefix("no") { return .notAI }
        return .unknown
    }

    /// The page's description tags and og:title, entity-decoded and joined,
    /// or nil when the page can't be read or has none. Reads the response
    /// only until `</head>` (or the byte limit): the tags live there, and
    /// the rest of the page is the bulk of the bytes.
    private func pageDescription(of story: Story) async -> String? {
        guard let url = story.url.flatMap(URL.init(string:)),
              url.scheme == "http" || url.scheme == "https",
              let (bytes, response) = try? await Self.pageSession.bytes(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.contains("html") ?? true
        else { return nil }

        var data = Data()
        let headEnd = Array("</head>".utf8)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= Self.pageByteLimit { break }
                // ASCII-lowercase the tail before comparing: `| 0x20` maps
                // letters to lowercase and leaves `<`, `/`, `>` alone
                if byte == UInt8(ascii: ">"), data.count >= headEnd.count,
                   data.suffix(headEnd.count).map({ $0 | 0x20 }).elementsEqual(headEnd) {
                    break
                }
            }
        } catch {
            // A connection dropped mid-body still leaves a usable head
            if Task.isCancelled { return nil }
        }

        let html = String(decoding: data, as: UTF8.self)
        let values = html.matches(of: /<meta\b[^>]*>/.ignoresCase()).compactMap { match -> String? in
            let tag = match.output
            guard let key = tag.firstMatch(of: /\b(?:property|name)\s*=\s*["']([^"']+)["']/.ignoresCase())?.1,
                  Self.descriptionKeys.contains(key.lowercased()),
                  let content = tag.firstMatch(of: /\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')/.ignoresCase()),
                  let value = content.1 ?? content.2, !value.isEmpty
            else { return nil }
            return String(value)
        }
        return values.isEmpty ? nil : values.joined(separator: "\n").decodingHTMLEntities
    }

    private func verdict(_ verdict: AIVerdict, source: VerdictSource) -> StoredVerdict {
        StoredVerdict(
            verdict: verdict,
            source: source,
            promptVersion: Self.promptVersion,
            modelVersion: Self.modelVersion
        )
    }
}
