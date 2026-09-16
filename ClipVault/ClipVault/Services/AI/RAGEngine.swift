import Foundation

// MARK: - RAGResult

/// The result of a RAG query: the generated answer, the IDs of cited clips, and (for agentic
/// queries) the human-readable list of tool-call steps the agent took.
struct RAGResult {
    let answer: String
    let citedClipIDs: [Int64]
    /// Descriptions of each tool call made during an agentic query, e.g.
    /// "Searched by keyword: \"swift\" → 3 results". Empty for classic RAG.
    var searchSteps: [String]

    init(answer: String, citedClipIDs: [Int64], searchSteps: [String] = []) {
        self.answer = answer
        self.citedClipIDs = citedClipIDs
        self.searchSteps = searchSteps
    }
}

// MARK: - RAGTopic

/// Selects the system prompt and context block label used by `RAGEngine`.
///
/// `clipboard` (default) keeps the original wording for the existing /ask-over-clipboard flow.
/// `audioTranscripts` rewrites the prompt and context label so the LLM understands it is
/// answering questions about voice transcripts, not arbitrary clipboard items.
enum RAGTopic {
    case clipboard
    case audioTranscripts

    var systemPrompt: String {
        switch self {
        case .clipboard:        return Prompts.shared.rag.clipboardSystem
        case .audioTranscripts: return Prompts.shared.rag.audioTranscriptsSystem
        }
    }

    var contextLabel: String {
        switch self {
        case .clipboard:        return Prompts.shared.rag.clipboardContextLabel
        case .audioTranscripts: return Prompts.shared.rag.audioTranscriptsContextLabel
        }
    }
}

// MARK: - RAGEngine

/// Retrieval-Augmented Generation engine for "Chat with Data".
///
/// Workflow:
///   1. Embed the user question via `EmbeddingGenerator`.
///   2. Retrieve top-20 candidate clips via `VectorSearchEngine.hybridSearch`.
///   3. Build a context window (≤ 24,000 chars) formatted per clip.
///   4. Call `gpt-5.4-nano` with a system prompt, the context, and the question.
///   5. Return the answer + clip IDs parsed from `#ID` citation markers.
final class RAGEngine {

    // MARK: - Configuration

    static let model = "gpt-5.4-nano"  // fallback; runtime reads Settings.shared.chatModel
    /// Default top-K (documentation only; runtime reads Settings.shared.ragTopK).
    static let topK = 20
    /// Default context char limit (documentation only; runtime reads Settings.shared.ragMaxContextChars).
    static let maxContextChars = 24_000
    /// Maximum total tokens sent per request — a conservative cap well below model limits.
    static let safeTokenLimit = 100_000
    static var systemPrompt: String { Prompts.shared.rag.clipboardSystem }

    // MARK: - Dependencies

    private let client: OpenAIClient
    private let vectorEngine: VectorSearchEngine
    private let clipStore: ClipStore

    // MARK: - Init

    init(client: OpenAIClient = .shared,
         vectorEngine: VectorSearchEngine = .shared,
         clipStore: ClipStore) {
        self.client = client
        self.vectorEngine = vectorEngine
        self.clipStore = clipStore
    }

    // MARK: - Query

    /// Answer `question` using clips from the vector store.
    ///
    /// - Parameters:
    ///   - question: The user's current question.
    ///   - conversationHistory: Prior turn messages to include for context. Trimmed to
    ///     `Settings.shared.chatContextMessageLimit` from the end; reduced further if total
    ///     token count would exceed `safeTokenLimit`.
    /// - Returns: `RAGResult` with answer text and parsed citation IDs.
    /// - Throws: `OpenAIError.apiKeyMissing` when no key is set; rethrows network/decode errors.
    func query(_ question: String,
               conversationHistory: [OpenAIClient.ChatMessage]? = nil,
               filter: SearchFilter? = nil,
               topic: RAGTopic = .clipboard) async throws -> RAGResult {
        // 1. Retrieve candidate clip IDs via hybrid search (optionally scoped by filter).
        let candidateIDs: [Int64]
        if let filter {
            candidateIDs = try await vectorEngine.hybridSearch(
                query: question,
                topK: Settings.shared.ragTopK,
                filter: filter
            )
        } else {
            candidateIDs = try await vectorEngine.hybridSearch(
                query: question,
                topK: Settings.shared.ragTopK
            )
        }
        guard !candidateIDs.isEmpty else {
            let empty: String
            switch topic {
            case .clipboard:        empty = Prompts.shared.rag.emptyResultClipboard
            case .audioTranscripts: empty = Prompts.shared.rag.emptyResultAudio
            }
            return RAGResult(answer: empty, citedClipIDs: [])
        }

        // 2. Fetch full clip records.
        let clips = try fetchClips(ids: candidateIDs)

        // 3. Build context window.
        let context = buildContext(clips: clips)

        // 4. Assemble the messages array (system + context + optional history + question).
        // When history overflow is detected, earlier messages are summarised via a cheap LLM call.
        let messages = await buildMessagesWithSummarization(question: question,
                                                             context: context,
                                                             conversationHistory: conversationHistory,
                                                             topic: topic)

        // 5. Call the LLM.
        let response = try await client.chatCompletion(
            model: Settings.shared.chatModel,
            messages: messages,
            maxTokens: Settings.shared.ragMaxOutputTokens,
            reasoningEffort: Settings.shared.reasoningEffort
        )

        guard let choice = response.choices.first else {
            throw OpenAIError.noChoices
        }

        let answer = choice.message.content
        let cited  = parseCitations(from: answer)

        return RAGResult(answer: answer, citedClipIDs: cited)
    }

    // MARK: - Message Assembly (internal, testable)

    /// Builds the `messages` array sent to the LLM.
    ///
    /// Layout: `[system prompt] → [RAG context block] → [trimmed history] → [current question]`
    ///
    /// History is trimmed to the last `Settings.shared.chatContextMessageLimit` messages.
    /// If the estimated token count would exceed `safeTokenLimit`, messages are dropped from
    /// the front of the history until it fits. Context is included as a separate system message
    /// so it is clearly delineated from the conversation turns.
    func buildMessages(question: String,
                       context: String,
                       conversationHistory: [OpenAIClient.ChatMessage]?,
                       topic: RAGTopic = .clipboard) -> [OpenAIClient.ChatMessage] {
        var base: [OpenAIClient.ChatMessage] = [
            OpenAIClient.ChatMessage(role: "system", content: topic.systemPrompt),
            OpenAIClient.ChatMessage(role: "system", content: "\(topic.contextLabel):\n\(context)"),
        ]

        if let history = conversationHistory, !history.isEmpty {
            let limit = Settings.shared.chatContextMessageLimit
            var trimmed = Array(history.suffix(limit))

            // Token overflow: estimate base cost (system msgs + question) and drop history
            // from the front until the total fits within safeTokenLimit.
            let baseTokens = base.reduce(0) { $0 + OpenAIClient.estimateTokens($1.content) }
                + OpenAIClient.estimateTokens(question)

            while !trimmed.isEmpty {
                let historyTokens = trimmed.reduce(0) { $0 + OpenAIClient.estimateTokens($1.content) }
                if baseTokens + historyTokens <= Self.safeTokenLimit { break }
                trimmed = Array(trimmed.dropFirst())
            }

            base.append(contentsOf: trimmed)
        }

        base.append(OpenAIClient.ChatMessage(role: "user", content: question))
        return base
    }

    // MARK: - Summarisation-based Message Assembly (internal, testable)

    /// Minimum number of history messages that must be dropped before summarisation is attempted.
    /// Below this threshold, messages are simply dropped (cheaper than an extra API call).
    static let summarizationThreshold = 4

    /// Async variant of `buildMessages` that summarises overflow history instead of dropping it.
    ///
    /// When more than `summarizationThreshold` history messages would be discarded to stay within
    /// `safeTokenLimit`, a cheap LLM call summarises the discarded portion and inserts the summary
    /// as a "system" message before the remaining history turns.
    func buildMessagesWithSummarization(
        question: String,
        context: String,
        conversationHistory: [OpenAIClient.ChatMessage]?,
        topic: RAGTopic = .clipboard
    ) async -> [OpenAIClient.ChatMessage] {
        var base: [OpenAIClient.ChatMessage] = [
            OpenAIClient.ChatMessage(role: "system", content: topic.systemPrompt),
            OpenAIClient.ChatMessage(role: "system", content: "\(topic.contextLabel):\n\(context)"),
        ]

        guard let history = conversationHistory, !history.isEmpty else {
            base.append(OpenAIClient.ChatMessage(role: "user", content: question))
            return base
        }

        let limit = Settings.shared.chatContextMessageLimit
        let trimmed = Array(history.suffix(limit))

        // Determine how many messages can fit.
        let baseTokens = base.reduce(0) { $0 + OpenAIClient.estimateTokens($1.content) }
            + OpenAIClient.estimateTokens(question)

        var fittingHistory = trimmed
        var droppedCount = 0
        while !fittingHistory.isEmpty {
            let historyTokens = fittingHistory.reduce(0) { $0 + OpenAIClient.estimateTokens($1.content) }
            if baseTokens + historyTokens <= Self.safeTokenLimit { break }
            fittingHistory = Array(fittingHistory.dropFirst())
            droppedCount += 1
        }

        // Summarise dropped portion when it is large enough to be worth a summary call.
        if droppedCount > Self.summarizationThreshold {
            let droppedMessages = Array(trimmed.prefix(droppedCount))
            let summary = await summarizeConversation(droppedMessages)
            base.append(OpenAIClient.ChatMessage(role: "system",
                                                  content: "\(Prompts.shared.rag.earlierSummaryPrefix)\(summary)"))
        }

        base.append(contentsOf: fittingHistory)
        base.append(OpenAIClient.ChatMessage(role: "user", content: question))
        return base
    }

    /// Generates a 2-sentence summary of `messages` using the LLM.
    ///
    /// Falls back to a placeholder string when the API call fails (e.g. offline, bad key).
    func summarizeConversation(_ messages: [OpenAIClient.ChatMessage]) async -> String {
        guard !messages.isEmpty else { return Prompts.shared.rag.summaryFallbackEmpty }
        let transcript = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        let prompt = Prompts.shared.rag.summarizeConversationTemplate
            .renderingTemplate(["transcript": transcript])
        let summaryMessages = [OpenAIClient.ChatMessage(role: "user", content: prompt)]
        do {
            let response = try await client.chatCompletion(
                model: Settings.shared.chatModel,
                messages: summaryMessages,
                maxTokens: 150
            )
            return response.choices.first?.message.content ?? Prompts.shared.rag.summaryFallbackTruncated
        } catch {
            return Prompts.shared.rag.summaryFallbackError
        }
    }

    // MARK: - Context Building (internal, testable)

    /// Formats clip records into the context block sent to the LLM.
    ///
    /// Format per clip: `[#ID | tags | sourceApp | date]\ncontent`
    /// Clips are appended in order until `maxContextChars` is reached.
    func buildContext(clips: [ClipRecord]) -> String {
        var parts: [String] = []
        var totalChars = 0

        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            return f
        }()

        for clip in clips {
            guard let id = clip.id else { continue }

            let tags: String
            if let tagsJSON = clip.tags,
               let data = tagsJSON.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                tags = arr.joined(separator: ", ")
            } else {
                tags = ""
            }

            let app   = clip.sourceApp ?? "unknown"
            let date  = isoFormatter.string(from: Date(timeIntervalSince1970: clip.createdAt))
            let body  = clip.textContent ?? clip.imageDescription ?? ""

            let entry = "[#\(id) | \(tags) | \(app) | \(date)]\n\(body)"

            // Stop adding if we'd overflow the context window.
            if totalChars + entry.count > Settings.shared.ragMaxContextChars { break }
            parts.append(entry)
            totalChars += entry.count
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Citation Parsing (internal, testable)

    /// Extracts all `#123`-style citation IDs from an LLM response string.
    func parseCitations(from text: String) -> [Int64] {
        var result: [Int64] = []
        var seen = Set<Int64>()

        // Match #digits sequences (e.g. #42, #1234).
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "#" {
                let next = text.index(after: index)
                if next < text.endIndex && text[next].isNumber {
                    var end = next
                    while end < text.endIndex && text[end].isNumber {
                        end = text.index(after: end)
                    }
                    if let value = Int64(text[next..<end]) {
                        if seen.insert(value).inserted {
                            result.append(value)
                        }
                    }
                    index = end
                    continue
                }
            }
            index = text.index(after: index)
        }

        return result
    }

    // MARK: - Helpers

    private func fetchClips(ids: [Int64]) throws -> [ClipRecord] {
        try ids.compactMap { id in
            try clipStore.fetchById(id)
        }
    }
}
