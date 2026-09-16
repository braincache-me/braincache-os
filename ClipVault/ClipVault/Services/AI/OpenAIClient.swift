import Foundation

// MARK: - Tool Call Models

/// A single function-call invocation returned by the model.
struct ToolCallResponse: Codable {
    struct FunctionCall: Codable {
        let name: String
        /// JSON-encoded arguments string (e.g. `{"query":"swift closures","limit":10}`).
        let arguments: String
    }

    let id: String
    let function: FunctionCall

    enum CodingKeys: String, CodingKey {
        case id
        case function = "function"
    }
}

// MARK: - Response Models

struct PromptTokensDetails: Codable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

struct ChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            /// The text response from the model. Empty string when the model responded only with tool calls.
            let content: String
            /// Non-nil when the model responded with one or more function calls.
            let toolCalls: [ToolCallResponse]?

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case toolCalls = "tool_calls"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                role = try container.decode(String.self, forKey: .role)
                // The API may return null content when finish_reason is "tool_calls".
                let rawContent = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
                // Nemotron-style reasoning models inline a `<think>…</think>`
                // block in the completion; OpenAI never does. Strip it here so
                // every consumer (RAG, classification JSON, rewrite) sees only
                // the answer.
                content = Settings.shared.isOpenAIProvider ? rawContent : ThinkTagFilter.strip(rawContent)
                toolCalls = try container.decodeIfPresent([ToolCallResponse].self, forKey: .toolCalls)
            }

            /// True when the model invoked at least one tool instead of (or in addition to) text output.
            var hasToolCalls: Bool { !(toolCalls ?? []).isEmpty }
        }
        let message: Message
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Codable {
        let promptTokens: Int
        let completionTokens: Int
        let totalTokens: Int
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens    = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens     = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    let id: String
    let choices: [Choice]
    let usage: Usage?
}

struct EmbeddingResponse: Codable {
    struct EmbeddingData: Codable {
        let embedding: [Float]
        let index: Int
    }

    struct Usage: Codable {
        let promptTokens: Int
        let totalTokens: Int
        let promptTokensDetails: PromptTokensDetails?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case totalTokens  = "total_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }
    }

    let data: [EmbeddingData]
    let usage: Usage
}

enum OpenAIError: Error, LocalizedError, Equatable {
    case apiKeyMissing
    case httpError(statusCode: Int, message: String)
    case noChoices
    case noEmbedding
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "AI API key is not configured. Add one in Preferences → AI."
        case .httpError(let statusCode, let message):
            return "AI API error (\(statusCode)): \(message)"
        case .noChoices:
            return "The AI provider returned an empty response (no choices)."
        case .noEmbedding:
            return "The AI provider returned no embedding data."
        case .decodingFailed:
            return "Failed to decode the AI provider's API response."
        }
    }
}

// MARK: - OpenAIClient

final class OpenAIClient {

    static let shared = OpenAIClient()

    private let session: URLSession
    /// Resolved from `Settings.aiBaseURL` on every call so switching provider
    /// (or editing a custom endpoint) takes effect immediately, exactly like
    /// API-key rotation.
    var baseURL: URL {
        URL(string: Settings.shared.aiBaseURL) ?? URL(fileURLWithPath: "/")
    }

    /// True when requests go to OpenAI itself. Gates the OpenAI-only surfaces
    /// (Responses API, hosted `web_search`, `reasoning.summary`) and the
    /// `<think>` stripping that open-weight reasoning models need.
    var isOpenAIProvider: Bool { Settings.shared.isOpenAIProvider }
    /// Initial retry delay in nanoseconds. Doubles on each retry (1s → 2s → 4s by default).
    let initialRetryDelay: UInt64

    init(session: URLSession = .shared, initialRetryDelay: UInt64 = 1_000_000_000) {
        self.session = session
        self.initialRetryDelay = initialRetryDelay
    }

    // MARK: - Chat Completion

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    enum ResponseFormat: String {
        case text = "text"
        case json = "json_object"
    }

    // MARK: - Token Estimation

    /// Estimates the number of tokens in `text` using the chars/4 heuristic.
    /// Returns 0 for empty input.
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }

    // MARK: - Cost Tracking

    /// Records token usage from an API response into Settings for daily and cumulative tracking.
    /// Resets daily counters automatically when the calendar date changes.
    func recordUsage(
        model: String,
        category: AIUsageCategory,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0
    ) {
        let today = Settings.todayString()
        if Settings.shared.costTrackingDate != today {
            Settings.shared.costTrackingDate = today
            Settings.shared.tokensInputToday = 0
            Settings.shared.tokensOutputToday = 0
            Settings.shared.tokensCachedInputToday = 0
            Settings.shared.chatTokensInputToday = 0
            Settings.shared.chatTokensCachedInputToday = 0
            Settings.shared.chatTokensOutputToday = 0
            Settings.shared.chatCostTodayUSD = 0
            Settings.shared.indexingTokensInputToday = 0
            Settings.shared.indexingTokensCachedInputToday = 0
            Settings.shared.indexingTokensOutputToday = 0
            Settings.shared.indexingCostTodayUSD = 0
        }

        let boundedInput = max(inputTokens, 0)
        let boundedOutput = max(outputTokens, 0)
        let boundedCached = min(max(cachedInputTokens, 0), boundedInput)
        let costUSD = OpenAIUsageCost.totalUSD(
            model: model,
            inputTokens: boundedInput,
            outputTokens: boundedOutput,
            cachedInputTokens: boundedCached
        )

        Settings.shared.tokensInputToday += boundedInput
        Settings.shared.tokensOutputToday += boundedOutput
        Settings.shared.tokensCachedInputToday += boundedCached
        Settings.shared.tokensTotalInput += boundedInput
        Settings.shared.tokensTotalOutput += boundedOutput
        Settings.shared.tokensTotalCachedInput += boundedCached

        switch category {
        case .chat:
            Settings.shared.chatTokensInputToday += boundedInput
            Settings.shared.chatTokensCachedInputToday += boundedCached
            Settings.shared.chatTokensOutputToday += boundedOutput
            Settings.shared.chatCostTodayUSD += costUSD
            Settings.shared.chatTokensTotalInput += boundedInput
            Settings.shared.chatTokensTotalCachedInput += boundedCached
            Settings.shared.chatTokensTotalOutput += boundedOutput
            Settings.shared.chatCostTotalUSD += costUSD

        case .indexing:
            Settings.shared.indexingTokensInputToday += boundedInput
            Settings.shared.indexingTokensCachedInputToday += boundedCached
            Settings.shared.indexingTokensOutputToday += boundedOutput
            Settings.shared.indexingCostTodayUSD += costUSD
            Settings.shared.indexingTokensTotalInput += boundedInput
            Settings.shared.indexingTokensTotalCachedInput += boundedCached
            Settings.shared.indexingTokensTotalOutput += boundedOutput
            Settings.shared.indexingCostTotalUSD += costUSD

        case .transcription:
            Settings.shared.transcriptionCostTodayUSD += costUSD
            Settings.shared.transcriptionCostTotalUSD += costUSD
        }

        Settings.shared.recordAICostHistory(category: category, costUSD: costUSD)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipVaultAIUsageDidChange, object: nil)
        }
    }

    func recordUsage(inputTokens: Int, outputTokens: Int) {
        recordUsage(
            model: Settings.shared.chatModel,
            category: .chat,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    // MARK: - Cancel In-flight Requests

    /// Cancels all pending URLSession tasks — called when the API key is rotated.
    func cancelAllPendingRequests() {
        session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }

    // MARK: - Chat Completion

    /// A tool-result message to return after a model-invoked function call.
    struct ToolResultMessage {
        let toolCallId: String
        let content: String
    }

    func chatCompletion(
        model: String,
        messages: [ChatMessage],
        imageData: Data? = nil,
        imageDetail: String = "low",
        maxTokens: Int? = nil,
        reasoningEffort: String? = nil,
        responseFormat: ResponseFormat = .text,
        tools: [[String: Any]]? = nil,
        toolChoice: String? = nil,
        usageCategory: AIUsageCategory = .chat
    ) async throws -> ChatResponse {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        var messagePayload: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content as Any] }
        if let imageData {
            let imageBlock: [String: Any] = [
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(imageData.base64EncodedString())",
                    "detail": imageDetail
                ]
            ]
            if let lastUserIdx = messagePayload.lastIndex(where: { ($0["role"] as? String) == "user" }) {
                let existingText = messagePayload[lastUserIdx]["content"] as? String ?? ""
                messagePayload[lastUserIdx]["content"] = [
                    ["type": "text", "text": existingText],
                    imageBlock
                ]
            } else {
                messagePayload.append([
                    "role": "user",
                    "content": [imageBlock]
                ])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messagePayload,
        ]
        // response_format is incompatible with tool-use mode; only include for plain text/JSON calls.
        if tools == nil {
            body["response_format"] = ["type": responseFormat.rawValue]
        }
        if let maxTokens { body["max_completion_tokens"] = maxTokens }
        // `reasoning_effort` is an OpenAI-only parameter; other gateways 400
        // on unknown top-level fields.
        if let reasoningEffort, !reasoningEffort.isEmpty, isOpenAIProvider {
            body["reasoning_effort"] = reasoningEffort
        }
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = toolChoice ?? "auto"
        }

        let request = try makeRequest(path: "/chat/completions", body: body)
        let data = try await performWithRetry(request: request)
        let response = try decode(ChatResponse.self, from: data)
        if let usage = response.usage {
            recordUsage(
                model: model,
                category: usageCategory,
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cachedInputTokens: usage.promptTokensDetails?.cachedTokens ?? 0
            )
        }
        return response
    }

    /// Chat completion that accepts a mixed message history (regular + tool-result messages).
    ///
    /// This low-level variant takes the raw `[[String: Any]]` messages so the agentic loop
    /// can inject `tool` role messages that don't fit `ChatMessage` (which only models
    /// user/assistant/system roles).
    func chatCompletionRaw(
        model: String,
        messages: [[String: Any]],
        maxTokens: Int? = nil,
        reasoningEffort: String? = nil,
        tools: [[String: Any]]? = nil,
        toolChoice: String? = nil,
        usageCategory: AIUsageCategory = .chat
    ) async throws -> ChatResponse {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        if let maxTokens { body["max_completion_tokens"] = maxTokens }
        // `reasoning_effort` is an OpenAI-only parameter; other gateways 400
        // on unknown top-level fields.
        if let reasoningEffort, !reasoningEffort.isEmpty, isOpenAIProvider {
            body["reasoning_effort"] = reasoningEffort
        }
        if let tools, !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = toolChoice ?? "auto"
        }

        let request = try makeRequest(path: "/chat/completions", body: body)
        let data = try await performWithRetry(request: request)
        let response = try decode(ChatResponse.self, from: data)
        if let usage = response.usage {
            recordUsage(
                model: model,
                category: usageCategory,
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cachedInputTokens: usage.promptTokensDetails?.cachedTokens ?? 0
            )
        }
        return response
    }

    // MARK: - Streaming Chat Completion

    /// Streaming chat completion (Server-Sent Events).
    ///
    /// Yields content tokens as they arrive. When `imageData` is non-nil the
    /// image is inlined into the *last* user message as an `image_url` content
    /// block (canonical vision shape) — the model sees the prompt and the
    /// image together rather than as separate turns.
    ///
    /// Records usage on completion via the `stream_options.include_usage`
    /// chunk OpenAI emits just before `[DONE]`.
    ///
    /// No mid-stream retries: streaming connections that fail partway through
    /// aren't worth restarting (the partial tokens are gone). Pre-stream
    /// failures (auth, 429 on initial connect) surface as `OpenAIError`.
    /// Streaming chat completion. `temperature` is deliberately omitted from
    /// the payload — required for reasoning-style models (gpt-5.x family) that
    /// reject the parameter outright.
    func streamChatCompletion(
        model: String,
        messages: [ChatMessage],
        imageData: Data? = nil,
        additionalImages: [Data] = [],
        imageDetail: String = "auto",
        maxTokens: Int? = nil,
        reasoningEffort: String? = nil,
        usageCategory: AIUsageCategory = .chat
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    guard Settings.shared.isAIEnabled else {
                        throw OpenAIError.apiKeyMissing
                    }

                    var messagePayload: [[String: Any]] = messages.map {
                        ["role": $0.role, "content": $0.content as Any]
                    }
                    let allImages: [Data] = ([imageData].compactMap { $0 }) + additionalImages
                    if !allImages.isEmpty {
                        let imageBlocks: [[String: Any]] = allImages.map { data in
                            let base64 = data.base64EncodedString()
                            return [
                                "type": "image_url",
                                "image_url": [
                                    "url": "data:image/jpeg;base64,\(base64)",
                                    "detail": imageDetail
                                ]
                            ]
                        }
                        // Inline images into the last user message; if the last
                        // message isn't from the user (e.g. a system-only
                        // setup), append a new user turn carrying just the
                        // images so they still reach the model.
                        if let lastUserIdx = messagePayload.lastIndex(where: { ($0["role"] as? String) == "user" }) {
                            let existingText = messagePayload[lastUserIdx]["content"] as? String ?? ""
                            var blocks: [[String: Any]] = [["type": "text", "text": existingText]]
                            blocks.append(contentsOf: imageBlocks)
                            messagePayload[lastUserIdx]["content"] = blocks
                        } else {
                            messagePayload.append([
                                "role": "user",
                                "content": imageBlocks
                            ])
                        }
                    }

                    // Open-weight reasoning models inline `<think>` blocks in
                    // the stream; the filter buffers across delta boundaries so
                    // a tag split between chunks is still removed.
                    let stripsThinkTags = !self.isOpenAIProvider
                    var thinkFilter = ThinkTagFilter()

                    var body: [String: Any] = [
                        "model": model,
                        "messages": messagePayload,
                        "stream": true,
                        "stream_options": ["include_usage": true],
                    ]
                    if let maxTokens { body["max_completion_tokens"] = maxTokens }
                    if let reasoningEffort, !reasoningEffort.isEmpty, self.isOpenAIProvider {
                        body["reasoning_effort"] = reasoningEffort
                    }

                    var request = URLRequest(url: baseURL.appendingPathComponent("/chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAIError.httpError(statusCode: 0, message: "non-HTTP response")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        // Drain a small amount of body to surface the error message.
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 4096 { break }
                        }
                        let message = self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
                        throw OpenAIError.httpError(statusCode: http.statusCode, message: message)
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let token = self.extractStreamToken(from: json), !token.isEmpty {
                            let visible = stripsThinkTags ? thinkFilter.feed(token) : token
                            if !visible.isEmpty { continuation.yield(visible) }
                        }
                        if let usage = json["usage"] as? [String: Any] {
                            let inputTokens = (usage["prompt_tokens"] as? Int) ?? 0
                            let outputTokens = (usage["completion_tokens"] as? Int) ?? 0
                            let cachedTokens = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
                            self.recordUsage(
                                model: model,
                                category: usageCategory,
                                inputTokens: inputTokens,
                                outputTokens: outputTokens,
                                cachedInputTokens: cachedTokens
                            )
                        }
                    }
                    if stripsThinkTags {
                        let tail = thinkFilter.flush()
                        if !tail.isEmpty { continuation.yield(tail) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming Responses API (Ask AI)

    /// Result of executing a local function tool, fed back to the model on
    /// the next round via `previous_response_id`.
    struct FunctionCallOutput {
        let callId: String
        let output: String
    }

    /// Streaming request against the Responses API (`POST /v1/responses`).
    ///
    /// Used by Ask AI instead of `streamChatCompletion` because the Responses
    /// API is the only surface that streams reasoning summaries ("thinking"
    /// traces, via `reasoning.summary`) and hosts the built-in `web_search`
    /// tool. Yields typed `ResponsesStreamEvent`s.
    ///
    /// First round: pass `userContentBlocks` (`input_text` / `input_image`
    /// blocks). Follow-up rounds after local function calls: pass the previous
    /// round's `previousResponseId` plus `functionOutputs` — the server
    /// replays the stored context so reasoning items don't need re-sending.
    ///
    /// Reasoning summaries require an OpenAI org verified for the feature on
    /// some models; on a 400 that names `reasoning.summary` the request is
    /// retried once without the summary field so the answer still streams
    /// (just without a thinking trace).
    func streamResponse(
        model: String,
        instructions: String,
        userContentBlocks: [[String: Any]],
        previousResponseId: String? = nil,
        functionOutputs: [FunctionCallOutput] = [],
        tools: [[String: Any]] = [],
        maxOutputTokens: Int? = nil,
        reasoningEffort: String? = nil,
        usageCategory: AIUsageCategory = .chat
    ) -> AsyncThrowingStream<ResponsesStreamEvent, Error> {
        AsyncThrowingStream<ResponsesStreamEvent, Error> { continuation in
            let task = Task {
                do {
                    guard Settings.shared.isAIEnabled else {
                        throw OpenAIError.apiKeyMissing
                    }

                    // Only OpenAI serves `/responses`. Everywhere else the same
                    // event surface is produced from a streaming chat
                    // completion — see `streamResponseViaChatCompletions`.
                    guard self.isOpenAIProvider else {
                        try await self.streamResponseViaChatCompletions(
                            model: model,
                            instructions: instructions,
                            userContentBlocks: userContentBlocks,
                            previousResponseId: previousResponseId,
                            functionOutputs: functionOutputs,
                            tools: tools,
                            maxOutputTokens: maxOutputTokens,
                            usageCategory: usageCategory,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }

                    func makeBody(includeReasoningSummary: Bool) -> [String: Any] {
                        var body: [String: Any] = [
                            "model": model,
                            "instructions": instructions,
                            "stream": true,
                            "store": true,
                        ]
                        if let previousResponseId {
                            body["previous_response_id"] = previousResponseId
                            body["input"] = functionOutputs.map {
                                [
                                    "type": "function_call_output",
                                    "call_id": $0.callId,
                                    "output": $0.output,
                                ] as [String: Any]
                            }
                        } else {
                            body["input"] = [
                                ["role": "user", "content": userContentBlocks] as [String: Any]
                            ]
                        }
                        if !tools.isEmpty { body["tools"] = tools }
                        if let maxOutputTokens { body["max_output_tokens"] = maxOutputTokens }
                        if let reasoningEffort, !reasoningEffort.isEmpty {
                            var reasoning: [String: Any] = ["effort": reasoningEffort]
                            if includeReasoningSummary { reasoning["summary"] = "auto" }
                            body["reasoning"] = reasoning
                        }
                        return body
                    }

                    func connect(_ body: [String: Any]) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
                        var request = URLRequest(url: baseURL.appendingPathComponent("/responses"))
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            throw OpenAIError.httpError(statusCode: 0, message: "non-HTTP response")
                        }
                        return (bytes, http)
                    }

                    func drainErrorMessage(_ bytes: URLSession.AsyncBytes) async throws -> String? {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 4096 { break }
                        }
                        return self.extractErrorMessage(from: data)
                    }

                    var (bytes, http) = try await connect(makeBody(includeReasoningSummary: true))
                    if !(200...299).contains(http.statusCode) {
                        let message = try await drainErrorMessage(bytes) ?? "HTTP \(http.statusCode)"
                        if http.statusCode == 400,
                           message.localizedCaseInsensitiveContains("summary") {
                            (bytes, http) = try await connect(makeBody(includeReasoningSummary: false))
                            guard (200...299).contains(http.statusCode) else {
                                let retryMessage = try await drainErrorMessage(bytes) ?? "HTTP \(http.statusCode)"
                                throw OpenAIError.httpError(statusCode: http.statusCode, message: retryMessage)
                            }
                        } else {
                            throw OpenAIError.httpError(statusCode: http.statusCode, message: message)
                        }
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty || payload == "[DONE]" { continue }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let event = ResponsesStreamParser.event(from: json)
                        else { continue }

                        if case .completed(_, let usage) = event, let usage {
                            self.recordUsage(
                                model: model,
                                category: usageCategory,
                                inputTokens: usage.inputTokens,
                                outputTokens: usage.outputTokens,
                                cachedInputTokens: usage.cachedInputTokens
                            )
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Responses-API emulation over Chat Completions

    /// Produces the `ResponsesStreamEvent` surface from a streaming chat
    /// completion, for providers that don't serve `POST /responses`.
    ///
    /// Differences from the real Responses API, all handled here:
    /// - Tools are converted from the flat Responses schema to the nested
    ///   chat-completions shape; hosted tools (`web_search`) are dropped.
    /// - There is no `reasoning.summary`, so no `.reasoningDelta` is emitted.
    /// - There is no server-side conversation store, so the message history is
    ///   kept in `ResponsesChatSessionStore` and addressed by a synthetic
    ///   response id handed back through `.completed`. A continuation round
    ///   replays that history plus one `role:"tool"` message per call.
    private func streamResponseViaChatCompletions(
        model: String,
        instructions: String,
        userContentBlocks: [[String: Any]],
        previousResponseId: String?,
        functionOutputs: [FunctionCallOutput],
        tools: [[String: Any]],
        maxOutputTokens: Int?,
        usageCategory: AIUsageCategory,
        continuation: AsyncThrowingStream<ResponsesStreamEvent, Error>.Continuation
    ) async throws {
        var messages: [[String: Any]]
        if let previousResponseId,
           let stored = ResponsesChatSessionStore.shared.messages(for: previousResponseId) {
            messages = stored
            messages.append(contentsOf: ResponsesChatCompletionsBridge.toolResultMessages(
                outputs: functionOutputs.map { ($0.callId, $0.output) }
            ))
        } else {
            messages = ResponsesChatCompletionsBridge.chatMessages(
                instructions: instructions,
                userContentBlocks: userContentBlocks
            )
        }

        let converted = ResponsesChatCompletionsBridge.chatTools(from: tools)
        ResponsesChatCompletionsBridge.logSkippedHostedTools(converted.skippedHostedTools)

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let maxOutputTokens { body["max_completion_tokens"] = maxOutputTokens }
        if !converted.tools.isEmpty {
            body["tools"] = converted.tools
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.httpError(statusCode: 0, message: "non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4096 { break }
            }
            let message = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw OpenAIError.httpError(statusCode: http.statusCode, message: message)
        }

        var thinkFilter = ThinkTagFilter()
        var accumulator = StreamingToolCallAccumulator()
        var assistantText = ""
        var usage: ResponsesUsage?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let delta = Self.streamDelta(from: json) {
                if let token = delta["content"] as? String, !token.isEmpty {
                    assistantText += token
                    let visible = thinkFilter.feed(token)
                    if !visible.isEmpty { continuation.yield(.textDelta(visible)) }
                }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    accumulator.ingest(calls)
                }
            }
            if let u = json["usage"] as? [String: Any] {
                let cached = ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
                usage = ResponsesUsage(
                    inputTokens: (u["prompt_tokens"] as? Int) ?? 0,
                    outputTokens: (u["completion_tokens"] as? Int) ?? 0,
                    cachedInputTokens: cached
                )
            }
        }

        let tail = thinkFilter.flush()
        if !tail.isEmpty { continuation.yield(.textDelta(tail)) }

        let calls = accumulator.finish()
        for call in calls {
            continuation.yield(.functionCall(callId: call.callId, name: call.name, arguments: call.arguments))
        }

        // Store the history this round produced so the next round can continue
        // it: every tool call in the assistant message must be answered by a
        // `role:"tool"` message, which the caller supplies as functionOutputs.
        var nextMessages = messages
        if calls.isEmpty {
            nextMessages.append(["role": "assistant", "content": assistantText])
        } else {
            nextMessages.append(ResponsesChatCompletionsBridge.assistantToolCallMessage(calls: calls))
        }
        let responseId = ResponsesChatSessionStore.shared.store(nextMessages)

        if let usage {
            recordUsage(
                model: model,
                category: usageCategory,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cachedInputTokens: usage.cachedInputTokens
            )
        }
        continuation.yield(.completed(responseId: responseId, usage: usage))
    }

    /// Extracts `choices[0].delta` from a chat-completions SSE chunk.
    static func streamDelta(from json: [String: Any]) -> [String: Any]? {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else { return nil }
        return first["delta"] as? [String: Any]
    }

    /// Reassembles `tool_calls` that arrive as indexed fragments across SSE
    /// deltas (id and name in the first fragment, argument JSON in pieces).
    struct StreamingToolCallAccumulator {
        private struct Partial {
            var id = ""
            var name = ""
            var arguments = ""
        }
        private var partials: [Int: Partial] = [:]
        private var order: [Int] = []

        init() {}

        mutating func ingest(_ fragments: [[String: Any]]) {
            for fragment in fragments {
                let index = (fragment["index"] as? Int) ?? order.count
                if partials[index] == nil {
                    partials[index] = Partial()
                    order.append(index)
                }
                guard var partial = partials[index] else { continue }
                if let id = fragment["id"] as? String, !id.isEmpty { partial.id = id }
                if let function = fragment["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { partial.name = name }
                    if let arguments = function["arguments"] as? String { partial.arguments += arguments }
                }
                partials[index] = partial
            }
        }

        /// Returns the completed calls in arrival order. Calls without a name
        /// are dropped; calls without an id get a synthesised one so the
        /// caller can still pair a result with them.
        func finish() -> [(callId: String, name: String, arguments: String)] {
            order.compactMap { index in
                guard let partial = partials[index], !partial.name.isEmpty else { return nil }
                let id = partial.id.isEmpty ? "call_\(index)_\(UUID().uuidString.prefix(8))" : partial.id
                let arguments = partial.arguments.isEmpty ? "{}" : partial.arguments
                return (callId: id, name: partial.name, arguments: arguments)
            }
        }
    }

    // MARK: - Chunked audio transcription (omni models)

    /// Transcribes one WAV chunk by posting it to an omni chat model.
    ///
    /// Token Factory has no `/audio/transcriptions` endpoint; the omni models
    /// instead accept an `audio_url` content part with a base64 data URI. The
    /// model card recommends `temperature` ≈ 0.2, `top_k: 1` and
    /// `chat_template_kwargs: {"enable_thinking": false}`; a server that
    /// rejects one of those extras with a 400 gets one retry without them.
    func transcribeAudioChunk(
        wavData: Data,
        model: String,
        instruction: String,
        maxTokens: Int? = nil,
        usageCategory: AIUsageCategory = .transcription
    ) async throws -> String {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        let dataURI = "data:audio/wav;base64,\(wavData.base64EncodedString())"
        let content: [[String: Any]] = [
            ["type": "audio_url", "audio_url": ["url": dataURI]],
            ["type": "text", "text": instruction],
        ]

        func makeBody(includeTuningExtras: Bool) -> [String: Any] {
            var body: [String: Any] = [
                "model": model,
                "messages": [["role": "user", "content": content] as [String: Any]],
            ]
            if let maxTokens { body["max_completion_tokens"] = maxTokens }
            if includeTuningExtras {
                body["temperature"] = 0.2
                body["top_k"] = 1
                body["chat_template_kwargs"] = ["enable_thinking": false]
            }
            return body
        }

        func send(_ body: [String: Any]) async throws -> ChatResponse {
            let request = try makeRequest(path: "/chat/completions", body: body)
            let data = try await performWithRetry(request: request)
            return try decode(ChatResponse.self, from: data)
        }

        let response: ChatResponse
        do {
            response = try await send(makeBody(includeTuningExtras: true))
        } catch OpenAIError.httpError(let status, let message) where status == 400 {
            let lower = message.lowercased()
            let namesExtra = lower.contains("top_k")
                || lower.contains("chat_template_kwargs")
                || lower.contains("temperature")
                || lower.contains("extra")
                || lower.contains("unknown")
            guard namesExtra else {
                throw OpenAIError.httpError(statusCode: status, message: message)
            }
            response = try await send(makeBody(includeTuningExtras: false))
        }

        if let usage = response.usage {
            recordUsage(
                model: model,
                category: usageCategory,
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cachedInputTokens: usage.promptTokensDetails?.cachedTokens ?? 0
            )
        }
        // `ChatResponse` already strips `<think>` blocks on non-OpenAI providers.
        return response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Extracts the content delta from a single SSE chunk JSON object.
    private func extractStreamToken(from json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any]
        else { return nil }
        return delta["content"] as? String
    }

    // MARK: - Chat Completion with Vision

    func chatCompletionWithVision(
        model: String,
        messages: [ChatMessage],
        imageData: Data,
        detail: String = "low",
        maxOutputTokens: Int? = nil,
        usageCategory: AIUsageCategory = .indexing
    ) async throws -> ChatResponse {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        let base64 = imageData.base64EncodedString()
        var allMessages: [[String: Any]] = messages.map {
            ["role": $0.role, "content": $0.content]
        }
        allMessages.append([
            "role": "user",
            "content": [
                ["type": "image_url",
                 "image_url": ["url": "data:image/png;base64,\(base64)", "detail": detail]]
            ]
        ])

        var body: [String: Any] = [
            "model": model,
            "messages": allMessages
        ]
        if let maxOutputTokens { body["max_completion_tokens"] = maxOutputTokens }

        let request = try makeRequest(path: "/chat/completions", body: body)
        let data = try await performWithRetry(request: request)
        let visionResponse = try decode(ChatResponse.self, from: data)
        if let usage = visionResponse.usage {
            recordUsage(
                model: model,
                category: usageCategory,
                inputTokens: usage.promptTokens,
                outputTokens: usage.completionTokens,
                cachedInputTokens: usage.promptTokensDetails?.cachedTokens ?? 0
            )
        }
        return visionResponse
    }

    // MARK: - Embeddings

    func createEmbedding(
        model: String,
        input: String,
        dimensions: Int? = nil,
        usageCategory: AIUsageCategory = .indexing
    ) async throws -> EmbeddingResponse {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        var body: [String: Any] = ["model": model, "input": input]
        if let dimensions { body["dimensions"] = dimensions }

        let request = try makeRequest(path: "/embeddings", body: body)
        let data = try await performWithRetry(request: request)
        var response = try decode(EmbeddingResponse.self, from: data)
        if let dimensions {
            response = EmbeddingVectorAdapter.conform(response, to: dimensions)
        }
        recordUsage(
            model: model,
            category: usageCategory,
            inputTokens: response.usage.promptTokens,
            outputTokens: 0,
            cachedInputTokens: response.usage.promptTokensDetails?.cachedTokens ?? 0
        )
        return response
    }

    // MARK: - Audio Transcription

    struct TranscriptionResponse: Codable {
        let text: String
    }

    func transcribeAudio(
        fileURL: URL,
        model: String,
        language: String? = nil
    ) async throws -> TranscriptionResponse {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }

        let request = try makeMultipartRequest(
            path: "/audio/transcriptions",
            fields: {
                var f: [(String, String)] = [("model", model), ("response_format", "json")]
                if let language { f.append(("language", language)) }
                return f
            }(),
            fileURL: fileURL,
            fileFieldName: "file",
            mimeType: "audio/wav"
        )
        let data = try await performWithRetry(request: request)
        return try decode(TranscriptionResponse.self, from: data)
    }

    func recordTranscriptionCost(model: String, durationSeconds: Double) {
        let today = Settings.todayString()
        if Settings.shared.costTrackingDate != today {
            Settings.shared.costTrackingDate = today
            Settings.shared.tokensInputToday = 0
            Settings.shared.tokensOutputToday = 0
            Settings.shared.tokensCachedInputToday = 0
            Settings.shared.chatTokensInputToday = 0
            Settings.shared.chatTokensCachedInputToday = 0
            Settings.shared.chatTokensOutputToday = 0
            Settings.shared.chatCostTodayUSD = 0
            Settings.shared.indexingTokensInputToday = 0
            Settings.shared.indexingTokensCachedInputToday = 0
            Settings.shared.indexingTokensOutputToday = 0
            Settings.shared.indexingCostTodayUSD = 0
            Settings.shared.transcriptionCostTodayUSD = 0
        }

        let costUSD = OpenAIUsageCost.transcriptionCostUSD(
            model: model, durationSeconds: durationSeconds
        )
        Settings.shared.transcriptionCostTodayUSD += costUSD
        Settings.shared.transcriptionCostTotalUSD += costUSD
        Settings.shared.recordAICostHistory(category: .transcription, costUSD: costUSD)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .clipVaultAIUsageDidChange, object: nil)
        }
    }

    // MARK: - Models List

    struct ModelInfo: Codable {
        let id: String
        /// Optional: Token Factory's `/models` listing omits `owned_by` on
        /// some entries, and a hard requirement would fail the whole decode.
        let ownedBy: String?
        enum CodingKeys: String, CodingKey {
            case id
            case ownedBy = "owned_by"
        }
    }

    struct ModelsListResponse: Codable {
        let data: [ModelInfo]
    }

    func listModels() async throws -> Data {
        guard Settings.shared.isAIEnabled else { throw OpenAIError.apiKeyMissing }
        let request = try makeGETRequest(path: "/models")
        return try await performWithRetry(request: request)
    }

    func fetchAvailableModels() async throws -> [String] {
        let data = try await listModels()
        let response = try decode(ModelsListResponse.self, from: data)
        return response.data.map { $0.id }.sorted()
    }

    static let openAIChatModels = [
        "gpt-5.4-nano", "gpt-5.4-mini", "gpt-5.4",
        "gpt-5-nano", "gpt-5-mini", "gpt-5",
        "gpt-4.1-nano", "gpt-4.1-mini", "gpt-4.1",
        "o4-mini", "o3", "o3-mini",
    ]

    static let openAIEmbeddingModels = [
        "text-embedding-3-small", "text-embedding-3-large",
    ]

    /// Nemotron / Qwen IDs offered before the live `/models` list is fetched.
    static let nebiusChatModels = [
        "nvidia/nemotron-3-super-120b-a12b",
        "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B",
        "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning",
    ]

    static let nebiusEmbeddingModels = [
        "Qwen/Qwen3-Embedding-8B",
        "BAAI/bge-en-icl",
    ]

    /// Fallback chat models for the provider the user currently has selected.
    static var defaultChatModels: [String] {
        Settings.shared.isOpenAIProvider ? openAIChatModels : nebiusChatModels
    }

    /// Fallback embedding models for the provider the user currently has selected.
    static var defaultEmbeddingModels: [String] {
        Settings.shared.isOpenAIProvider ? openAIEmbeddingModels : nebiusEmbeddingModels
    }

    /// True for IDs that look like an embedding model on any provider —
    /// OpenAI's `text-embedding-*` plus Token Factory's `Qwen/…-Embedding-…`,
    /// `BAAI/bge-…` and `intfloat/e5-…` families.
    static func looksLikeEmbeddingModel(_ model: String) -> Bool {
        let lower = model.lowercased()
        if lower.contains("embed") { return true }
        if lower.contains("bge") { return true }
        if lower.contains("/e5-") || lower.hasPrefix("e5-") { return true }
        return false
    }

    /// Filters a `/models` listing down to IDs usable for chat completions.
    ///
    /// OpenAI IDs are matched by prefix (unchanged). Token Factory IDs are
    /// namespaced (`nvidia/…`, `Qwen/…`, `BAAI/…`) — any namespaced ID is
    /// treated as a chat model unless it looks like an embedding or a
    /// non-chat modality.
    static func chatModels(from all: [String]) -> [String] {
        let prefixes = ["gpt-5", "gpt-4.1", "gpt-4o", "o3", "o4"]
        let exclude = ["realtime", "audio", "search", "transcribe", "image", "moderation", "chatgpt", "codex", "oss", "whisper", "rerank", "tts", "dall-e"]
        return all.filter { model in
            let lower = model.lowercased()
            if exclude.contains(where: { lower.contains($0) }) { return false }
            if looksLikeEmbeddingModel(model) { return false }
            if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
            // Namespaced third-party ID (vendor/model) — Token Factory shape.
            return model.contains("/")
        }
    }

    static func embeddingModels(from all: [String]) -> [String] {
        all.filter { looksLikeEmbeddingModel($0) }
    }

    // MARK: - Private helpers

    private func makeRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func makeGETRequest(path: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func performWithRetry(request: URLRequest, maxRetries: Int = 3) async throws -> Data {
        var delay: UInt64 = initialRetryDelay
        var lastError: Error = OpenAIError.httpError(statusCode: 0, message: "unknown")

        for attempt in 0...maxRetries {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: delay)
                delay = min(delay * 2, 4_000_000_000)  // cap at 4 seconds (1→2→4)
            }

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                lastError = error
                continue
            }

            guard let http = response as? HTTPURLResponse else {
                lastError = OpenAIError.httpError(statusCode: 0, message: "non-HTTP response")
                continue
            }

            if (200...299).contains(http.statusCode) {
                return data
            }

            let message = extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            lastError = OpenAIError.httpError(statusCode: http.statusCode, message: message)

            // Only retry on 429 or 5xx
            guard http.statusCode == 429 || http.statusCode >= 500 else {
                throw lastError
            }
        }
        throw lastError
    }

    private func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    private func makeMultipartRequest(
        path: String,
        fields: [(String, String)],
        fileURL: URL,
        fileFieldName: String,
        mimeType: String
    ) throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Settings.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")

        var body = Data()
        for (key, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        let fileData = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenAIError.decodingFailed
        }
    }

    static func transcriptionModels(from all: [String]) -> [String] {
        all.filter { model in
            let lower = model.lowercased()
            return lower.contains("transcribe") || lower.contains("whisper")
        }
    }

    static let defaultTranslationModels = [
        "gpt-realtime-translate",
    ]

    static func translationModels(from all: [String]) -> [String] {
        all.filter { $0.lowercased().contains("translate") }
    }
}
