import Foundation

/// Agentic RAG engine — wraps the classic `RAGEngine` with an LLM-driven tool-use loop.
///
/// The LLM is given a set of search tools (defined in `SearchToolDefinitions`) and can
/// invoke them across multiple iterations (`Settings.shared.agenticMaxIterations`) to
/// refine its retrieval strategy before composing a final answer.
///
/// When `Settings.shared.agenticSearchEnabled` is false the engine falls back to a
/// single-shot classic RAG call via the embedded `RAGEngine`.
final class AgenticRAGEngine {

    struct ProgressSnapshot {
        let status: String
        let displayText: String
    }

    // MARK: - Dependencies

    let client: OpenAIClient
    let clipStore: ClipStore
    let vectorEngine: VectorSearchEngine
    let classicRAGEngine: RAGEngine

    // MARK: - Progress

    /// Called on the main thread before each tool-call is executed.
    /// The string is a short human-readable description like "Searching by keyword: \"swift\"…".
    var onIterationUpdate: ((String) -> Void)?
    /// Called on the main thread with the accumulated plain-text trace shown while the model
    /// is still reasoning and calling tools.
    var onTraceUpdate: ((ProgressSnapshot) -> Void)?

    // MARK: - Init

    init(
        client: OpenAIClient = .shared,
        clipStore: ClipStore,
        vectorEngine: VectorSearchEngine = .shared
    ) {
        self.client = client
        self.clipStore = clipStore
        self.vectorEngine = vectorEngine
        self.classicRAGEngine = RAGEngine(
            client: client,
            vectorEngine: vectorEngine,
            clipStore: clipStore
        )
    }

    // MARK: - Query

    /// Answer `question` using the agentic tool-use loop, or fall back to classic RAG when
    /// `Settings.shared.agenticSearchEnabled` is false.
    func query(
        _ question: String,
        conversationHistory: [OpenAIClient.ChatMessage]? = nil
    ) async throws -> RAGResult {
        guard Settings.shared.agenticSearchEnabled else {
            return try await classicRAGEngine.query(question, conversationHistory: conversationHistory)
        }
        return try await agenticQuery(question, conversationHistory: conversationHistory)
    }

    // MARK: - Agentic Execution Loop

    /// Token count at which the agentic loop stops adding more iterations to prevent context overflow.
    static let agenticTokenWarningThreshold = 50_000

    /// Estimates the total tokens in a raw messages array using the chars/4 heuristic.
    func estimateMessageTokens(_ messages: [[String: Any]]) -> Int {
        messages.reduce(0) { total, msg in
            let content = msg["content"] as? String ?? ""
            return total + OpenAIClient.estimateTokens(content)
        }
    }

    private func agenticQuery(
        _ question: String,
        conversationHistory: [OpenAIClient.ChatMessage]?
    ) async throws -> RAGResult {
        let maxIterations = Settings.shared.agenticMaxIterations

        // Build the initial messages array in raw format so we can add tool results later.
        var messages = buildInitialMessages(question: question,
                                           conversationHistory: conversationHistory)

        var iterations = 0
        var steps: [String] = []
        var liveTraceSections: [String] = []

        while iterations < maxIterations {
            // Token cost guard: stop iterating if accumulated context is too large.
            if estimateMessageTokens(messages) > Self.agenticTokenWarningThreshold {
                break
            }

            let response = try await client.chatCompletionRaw(
                model: Settings.shared.chatModel,
                messages: messages,
                maxTokens: Settings.shared.ragMaxOutputTokens,
                reasoningEffort: Settings.shared.reasoningEffort,
                tools: SearchToolDefinitions.allTools,
                toolChoice: "auto"
            )

            guard let choice = response.choices.first else {
                throw OpenAIError.noChoices
            }

            // If model provided a text answer (no tool calls) → done.
            if !choice.message.hasToolCalls {
                let answer = choice.message.content
                return RAGResult(answer: answer,
                                 citedClipIDs: classicRAGEngine.parseCitations(from: answer),
                                 searchSteps: steps)
            }

            // Append the assistant's tool-call message to the conversation.
            let assistantMsg = makeAssistantToolCallMessage(choice.message)
            messages.append(assistantMsg)

            // Execute each tool call, collect results, and track steps.
            let toolCalls = choice.message.toolCalls ?? []
            let traceSection = buildTraceSection(
                thought: choice.message.content,
                toolCalls: toolCalls
            )
            if !traceSection.isEmpty {
                liveTraceSections.append(traceSection)
            }
            for toolCall in toolCalls {
                let description = describeToolCall(toolCall)
                DispatchQueue.main.async { [weak self] in
                    self?.onIterationUpdate?(description)
                    self?.publishTraceUpdate(
                        status: description,
                        sections: liveTraceSections
                    )
                }
                let result = await executeToolCall(toolCall)
                let resultSummary = parseResultCount(result)
                steps.append("\(description.dropLast()) → \(resultSummary)")
                let toolResultMsg: [String: Any] = [
                    "role": "tool",
                    "tool_call_id": toolCall.id,
                    "content": result
                ]
                messages.append(toolResultMsg)
            }

            iterations += 1
        }

        // Hard cap reached — force a final answer.
        let forceMsg: [String: Any] = [
            "role": "user",
            "content": Prompts.shared.agentic.forceFinalAnswer
        ]
        messages.append(forceMsg)

        let finalResponse = try await client.chatCompletionRaw(
            model: Settings.shared.chatModel,
            messages: messages,
            maxTokens: Settings.shared.ragMaxOutputTokens,
            reasoningEffort: Settings.shared.reasoningEffort,
            tools: SearchToolDefinitions.allTools,
            toolChoice: "none"
        )

        guard let finalChoice = finalResponse.choices.first else {
            throw OpenAIError.noChoices
        }

        let answer = finalChoice.message.content
        return RAGResult(answer: answer,
                         citedClipIDs: classicRAGEngine.parseCitations(from: answer),
                         searchSteps: steps)
    }

    // MARK: - Message Construction (internal, testable)

    /// Builds the initial raw messages for the agentic loop.
    ///
    /// Layout: `[system prompt]` → `[trimmed conversation history]` → `[user question]`
    func buildInitialMessages(
        question: String,
        conversationHistory: [OpenAIClient.ChatMessage]?
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": Prompts.shared.agentic.system]
        ]

        if let history = conversationHistory, !history.isEmpty {
            let limit = Settings.shared.chatContextMessageLimit
            let trimmed = Array(history.suffix(limit))
            for msg in trimmed {
                messages.append(["role": msg.role, "content": msg.content])
            }
        }

        messages.append(["role": "user", "content": question])
        return messages
    }

    // MARK: - Tool Execution (internal, testable)

    /// Dispatches a tool call to the appropriate `ClipStore` or `VectorSearchEngine` method.
    ///
    /// Returns a concise summary of the results: clip ID, first 200 chars of content,
    /// source app, and date — enough for the LLM to reason about without wasting tokens.
    func executeToolCall(_ toolCall: ToolCallResponse) async -> String {
        guard let args = parseArguments(toolCall.function.arguments) else {
            return "Error: could not parse tool arguments."
        }

        do {
            switch toolCall.function.name {
            case "search_by_keyword":
                guard let query = args["query"] as? String else {
                    return "Error: missing 'query' argument."
                }
                let limit = args["limit"] as? Int ?? 20
                let clips = try clipStore.search(query: query, limit: min(limit, 50))
                return formatClips(clips)

            case "search_by_semantic":
                guard let query = args["query"] as? String else {
                    return "Error: missing 'query' argument."
                }
                let limit = args["limit"] as? Int ?? 10
                let candidateIds = try await vectorEngine.hybridSearch(query: query, topK: min(limit, 50))
                let clips = try clipStore.fetchByIds(candidateIds)
                return formatClips(clips)

            case "filter_by_app":
                guard let appName = args["app_name"] as? String else {
                    return "Error: missing 'app_name' argument."
                }
                let limit = args["limit"] as? Int ?? 20
                let clips = try clipStore.fetchByApp(appName: appName, limit: min(limit, 50))
                return formatClips(clips)

            case "filter_by_date_range":
                guard let startStr = args["start_date"] as? String,
                      let endStr = args["end_date"] as? String else {
                    return "Error: missing 'start_date' or 'end_date' argument."
                }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                // Try with fractional seconds first, fall back to without.
                let startTs: Double
                let endTs: Double
                if let s = formatter.date(from: startStr) {
                    startTs = s.timeIntervalSince1970
                } else {
                    formatter.formatOptions = [.withInternetDateTime]
                    guard let s = formatter.date(from: startStr) else {
                        return "Error: could not parse 'start_date': \(startStr)"
                    }
                    startTs = s.timeIntervalSince1970
                }
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let e = formatter.date(from: endStr) {
                    endTs = e.timeIntervalSince1970
                } else {
                    formatter.formatOptions = [.withInternetDateTime]
                    guard let e = formatter.date(from: endStr) else {
                        return "Error: could not parse 'end_date': \(endStr)"
                    }
                    endTs = e.timeIntervalSince1970
                }
                let limit = args["limit"] as? Int ?? 20
                let clips = try clipStore.fetchByDateRange(start: startTs, end: endTs, limit: min(limit, 50))
                return formatClips(clips)

            case "filter_by_tags":
                guard let tags = args["tags"] as? [String] else {
                    return "Error: missing 'tags' argument."
                }
                let matchAll = args["match_all"] as? Bool ?? false
                let limit = args["limit"] as? Int ?? 20
                let clips = try clipStore.fetchByTags(tags: tags, matchAll: matchAll, limit: min(limit, 50))
                return formatClips(clips)

            case "filter_by_content_type":
                guard let contentType = args["content_type"] as? String else {
                    return "Error: missing 'content_type' argument."
                }
                let limit = args["limit"] as? Int ?? 20
                let clips = try clipStore.fetchByContentType(contentType: contentType, limit: min(limit, 50))
                return formatClips(clips)

            default:
                return "Error: unknown tool '\(toolCall.function.name)'."
            }
        } catch {
            return "Error executing tool '\(toolCall.function.name)': \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers (internal, testable)

    func buildTraceSection(thought: String, toolCalls: [ToolCallResponse]) -> String {
        let trimmedThought = thought.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedToolCalls = toolCalls.map(formatToolCallForDisplay)

        guard !trimmedThought.isEmpty || !formattedToolCalls.isEmpty else { return "" }

        var lines: [String] = []
        if !trimmedThought.isEmpty {
            lines.append(trimmedThought)
        }
        if !formattedToolCalls.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append(formattedToolCalls.count == 1 ? "Tool call:" : "Tool calls:")
            for formattedToolCall in formattedToolCalls {
                let callLines = formattedToolCall.components(separatedBy: "\n")
                guard let firstLine = callLines.first else { continue }
                lines.append("- \(firstLine)")
                lines.append(contentsOf: callLines.dropFirst().map { "  \($0)" })
            }
        }
        return lines.joined(separator: "\n")
    }

    func formatToolCallForDisplay(_ toolCall: ToolCallResponse) -> String {
        let arguments = formatToolCallArguments(toolCall.function.arguments)
        guard !arguments.isEmpty else {
            return toolCall.function.name
        }
        return "\(toolCall.function.name) \(arguments)"
    }

    func formatToolCallArguments(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formattedData = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let formatted = String(data: formattedData, encoding: .utf8) else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return formatted
    }

    private func publishTraceUpdate(status: String, sections: [String]) {
        let displayText = sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        guard !displayText.isEmpty else { return }
        onTraceUpdate?(ProgressSnapshot(status: status, displayText: displayText))
    }

    /// Formats clip records as a concise tool-result summary for the LLM.
    func formatClips(_ clips: [ClipRecord]) -> String {
        guard !clips.isEmpty else { return "No results found." }

        let isoFormatter: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            return f
        }()

        let lines = clips.prefix(20).compactMap { clip -> String? in
            guard let id = clip.id else { return nil }
            let date = isoFormatter.string(from: Date(timeIntervalSince1970: clip.createdAt))
            let app = clip.sourceApp ?? "unknown"
            let body = clip.textContent ?? clip.imageDescription ?? "(binary)"
            let preview = String(body.prefix(200))
            return "[#\(id) | \(app) | \(date)] \(preview)"
        }
        return "\(lines.count) result(s):\n" + lines.joined(separator: "\n")
    }

    /// Parses a JSON-encoded arguments string into a `[String: Any]` dictionary.
    func parseArguments(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// Serialises the assistant's tool-call message into the raw dict format required by the API.
    private func makeAssistantToolCallMessage(_ message: ChatResponse.Choice.Message) -> [String: Any] {
        let toolCallsArray: [[String: Any]] = (message.toolCalls ?? []).map { tc in
            [
                "id": tc.id,
                "type": "function",
                "function": [
                    "name": tc.function.name,
                    "arguments": tc.function.arguments
                ] as [String: Any]
            ]
        }
        var msg: [String: Any] = [
            "role": "assistant",
            "tool_calls": toolCallsArray
        ]
        if !message.content.isEmpty {
            msg["content"] = message.content
        }
        return msg
    }

    // MARK: - Step Description Helpers (internal, testable)

    /// Returns a short human-readable description of a tool call, ending with "…".
    /// Example: "Searching by keyword: \"swift\"…"
    func describeToolCall(_ toolCall: ToolCallResponse) -> String {
        guard let args = parseArguments(toolCall.function.arguments) else {
            return "Using \(toolCall.function.name)…"
        }
        switch toolCall.function.name {
        case "search_by_keyword":
            let q = args["query"] as? String ?? ""
            return "Searching by keyword: \"\(q)\"…"
        case "search_by_semantic":
            let q = args["query"] as? String ?? ""
            return "Semantic search: \"\(q)\"…"
        case "filter_by_app":
            let a = args["app_name"] as? String ?? ""
            return "Filtering by app: \(a)…"
        case "filter_by_date_range":
            let s = args["start_date"] as? String ?? ""
            let e = args["end_date"] as? String ?? ""
            return "Filtering by date: \(s) to \(e)…"
        case "filter_by_tags":
            let t = (args["tags"] as? [String] ?? []).joined(separator: ", ")
            return "Filtering by tags: \(t)…"
        case "filter_by_content_type":
            let ct = args["content_type"] as? String ?? ""
            return "Filtering by type: \(ct)…"
        default:
            return "Using \(toolCall.function.name)…"
        }
    }

    /// Parses the number of results from a `formatClips` output string.
    /// Returns e.g. "3 results" or "0 results".
    func parseResultCount(_ result: String) -> String {
        if result == "No results found." { return "0 results" }
        // formatClips returns "N result(s):\n..."
        if let range = result.range(of: #"^\d+ result"#, options: .regularExpression) {
            let prefix = String(result[range])
            // Normalise "1 result" / "3 result(s)"
            return prefix.hasSuffix("s") ? prefix : prefix + "s"
        }
        return "results"
    }

    // MARK: - System Prompt

    static var systemPrompt: String { Prompts.shared.agentic.system }
}
