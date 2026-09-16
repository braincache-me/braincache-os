import Foundation

/// All hardcoded prompts and prompt defaults, loaded once at startup from
/// `Prompts.json` in the app bundle. Edit the JSON file and rebuild to change
/// any prompt — call sites read through `Prompts.shared.*`.
struct Prompts: Decodable {
    let rag: RAG
    let agentic: Agentic
    let classification: Classification
    let imageDescriber: ImageDescriber
    let aiAssist: AIAssist
    let askAI: AskAI
    let voiceRewrite: VoiceRewrite
    let transcriptionSummarisation: TranscriptionSummarisation
    let writingAssistant: WritingAssistant
    let searchTools: SearchTools

    struct RAG: Decodable {
        let clipboardSystem: String
        let audioTranscriptsSystem: String
        let clipboardContextLabel: String
        let audioTranscriptsContextLabel: String
        let emptyResultClipboard: String
        let emptyResultAudio: String
        let summarizeConversationTemplate: String
        let earlierSummaryPrefix: String
        let summaryFallbackEmpty: String
        let summaryFallbackTruncated: String
        let summaryFallbackError: String
    }

    struct Agentic: Decodable {
        let system: String
        let forceFinalAnswer: String
    }

    struct Classification: Decodable {
        let systemTemplate: String
        let userPromptShort: String
        let userPromptLong: String
    }

    struct ImageDescriber: Decodable {
        let system: String
    }

    struct AIAssist: Decodable {
        let system: String
        let transcriptFraming: String
        let defaultUserPrefix: String
    }

    /// Ask AI tool prompts: guidance appended to the system prompt when a
    /// tool is enabled in Preferences, plus the function-tool descriptions.
    struct AskAI: Decodable {
        let webSearchGuidance: String
        let agentHistoryGuidance: String
        let tools: Tools

        struct Tools: Decodable {
            let claudeCodeHistory: SearchTools.ToolEntry
            let codexHistory: SearchTools.ToolEntry
            let askClaudeCode: SearchTools.ToolEntry
            let askCodex: SearchTools.ToolEntry
        }
    }

    struct VoiceRewrite: Decodable {
        let system: String
    }

    struct TranscriptionSummarisation: Decodable {
        let defaultPrompt: String
    }

    struct WritingAssistant: Decodable {
        /// System prompt for the smart text-rewrite shortcut.
        let rewriteSystem: String
    }

    struct SearchTools: Decodable {
        let searchByKeyword: ToolEntry
        let searchBySemantic: ToolEntry
        let filterByApp: ToolEntry
        let filterByDateRange: ToolEntry
        let filterByTags: ToolEntry
        let filterByContentType: ToolEntry

        struct ToolEntry: Decodable {
            let description: String
            let parameters: [String: String]
        }
    }

    // MARK: - Loading

    static let shared: Prompts = load()

    private static func load() -> Prompts {
        // Try the bundle that owns this class first (works in both the main app
        // and unit-test hosts), then fall back to `Bundle.main`.
        let candidates: [Bundle] = [
            Bundle(for: PromptsAnchor.self),
            Bundle.main,
        ]
        for bundle in candidates {
            guard let url = bundle.url(forResource: "Prompts", withExtension: "json") else {
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(Prompts.self, from: data)
            } catch {
                fatalError("Prompts.json found at \(url.path) but failed to decode: \(error)")
            }
        }
        fatalError("Prompts.json not found in any bundle — check the Resources folder.")
    }
}

private final class PromptsAnchor {}

extension String {
    /// Replaces `{{key}}` occurrences with the provided values.
    /// Literal single braces (e.g. `{"tags": ...}` in the classifier prompt) are
    /// left untouched because the placeholder syntax uses doubled braces.
    func renderingTemplate(_ values: [String: String]) -> String {
        var result = self
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return result
    }
}
