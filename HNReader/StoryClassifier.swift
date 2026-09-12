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

/// A verdict pinned to the prompt and model version that produced it, so a
/// prompt change or a new OS model triggers reclassification
struct StoredVerdict: Codable, Sendable {
    let verdict: AIVerdict
    let promptVersion: Int
    let modelVersion: String

    var isCurrent: Bool {
        promptVersion == StoryClassifier.promptVersion
            && modelVersion == StoryClassifier.modelVersion
    }
}

/// Classifies a story as AI-topic or not, in two stages: a keyword pass for
/// titles and hosts that name AI outright, then Apple's on-device model for
/// the rest.
///
/// Why two stages (measured Sept 2026 on the "26.4" model, 82 hard negatives
/// = generic titles a permissive prompt had flagged, 44 clear positives): a
/// rubric-style prompt flagged 69 of the 82 negatives. A strict "default is
/// no" prompt flagged 0 of 82 but missed 15 of 44 positives, most of which
/// literally contain "AI" or an AI company name. Keywords catch 37 of those
/// 44 with 0 false positives, so combined the set scores 0 false positives
/// and 4 misses (AI coding tools the title never names). The keyword pass
/// also settles ~20% of the store in microseconds.
///
/// The prompt shape is deliberate too: one plain-text yes/no prompt per
/// story, fresh session each time, greedy sampling, ~300 ms, 0 refusals
/// over 200 titles. Structured (@Generable) output with a rubric was refused
/// 30-100% of the time, batching titles tripped the guardrail every time,
/// and adding page description or body text lowered accuracy. Keep it title
/// + hostname, one story per prompt, plain text out.
struct StoryClassifier: Sendable {
    /// Bump when `instructions`, the prompt format, or the keyword lists change
    static let promptVersion = 2

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

    /// The title or host names AI outright, so no model call is needed.
    /// Short tokens are case-sensitive so "aim", GPT disk partitions in
    /// lowercase prose, and the like don't match; phrases and hosts aren't.
    /// Deliberately absent: Cursor, Grok, Haiku, Astra, agent, model -- all
    /// common words or names in other contexts. The model handles those.
    /// (Literals stay inline: `Regex` isn't `Sendable`, so it can't be a
    /// static constant under strict concurrency.)
    static func namesAI(_ story: Story) -> Bool {
        story.title.contains(/\b(AI|AGI|LLMs?|GPT|ChatGPT|OpenAI|Anthropic|Claude|Gemini|DeepMind|DeepSeek|Qwen|Llama|Mistral|Midjourney|Copilot|Codex|Ollama)\b/)
            || story.title.contains(/machine learning|artificial intelligence|deep learning|neural net|language model|generative|chatbot|agentic|stable diffusion|diffusion model|vllm|hugging ?face/.ignoresCase())
            || story.hostname?.contains(/openai|anthropic|claude|chatgpt|deepseek|deepmind|mistral\.ai|huggingface|ollama|midjourney/.ignoresCase()) == true
    }

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

    func classify(_ story: Story) async -> AIVerdict {
        if Self.namesAI(story) { return .ai }

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
}
