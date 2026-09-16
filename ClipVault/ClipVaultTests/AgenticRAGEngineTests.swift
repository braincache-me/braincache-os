import XCTest
import GRDB
@testable import ClipVault

// MARK: - Settings Tests (agenticMaxIterations / agenticSearchEnabled)

final class AgenticSettingsTests: XCTestCase {

    private var settings: Settings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.task7.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultAgenticMaxIterations() {
        XCTAssertEqual(settings.agenticMaxIterations, 3)
    }

    func testSetAgenticMaxIterations() {
        settings.agenticMaxIterations = 5
        XCTAssertEqual(settings.agenticMaxIterations, 5)
    }

    func testAgenticMaxIterationsClampedToMin() {
        settings.agenticMaxIterations = 0
        XCTAssertEqual(settings.agenticMaxIterations, 1)
    }

    func testAgenticMaxIterationsClampedToMax() {
        settings.agenticMaxIterations = 99
        XCTAssertEqual(settings.agenticMaxIterations, 5)
    }

    func testAgenticMaxIterationsPersists() {
        settings.agenticMaxIterations = 2
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let settings2 = Settings(defaults: defaults2)
        XCTAssertEqual(settings2.agenticMaxIterations, 2)
    }

    func testDefaultAgenticSearchEnabled() {
        XCTAssertTrue(settings.agenticSearchEnabled)
    }

    func testSetAgenticSearchEnabledFalse() {
        settings.agenticSearchEnabled = false
        XCTAssertFalse(settings.agenticSearchEnabled)
    }

    func testAgenticSearchEnabledPersists() {
        settings.agenticSearchEnabled = false
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let settings2 = Settings(defaults: defaults2)
        XCTAssertFalse(settings2.agenticSearchEnabled)
    }
}

// MARK: - OpenAIClient Tool-Call Support Tests

final class OpenAIClientToolCallTests: XCTestCase {

    private var client: OpenAIClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session, initialRetryDelay: 100_000)
        Settings.shared.openAIAPIKey = "sk-test-agentic"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        client = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func toolCallResponseJSON(toolName: String, args: String, toolCallId: String = "call_abc") -> Data {
        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "\(toolCallId)",
                    "type": "function",
                    "function": { "name": "\(toolName)", "arguments": "\(args)" }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ],
          "usage": { "prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30 }
        }
        """
        return json.data(using: .utf8)!
    }

    private func textResponseJSON(content: String) -> Data {
        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "message": { "role": "assistant", "content": "\(content)" },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        }
        """
        return json.data(using: .utf8)!
    }

    // MARK: - Tool Calls Decoded

    func testToolCallResponseIsParsedCorrectly() async throws {
        MockURLProtocol.requestHandler = { _ in
            let args = "{\\\"query\\\":\\\"swift closures\\\",\\\"limit\\\":10}"
            return (self.makeHTTPResponse(statusCode: 200),
                    self.toolCallResponseJSON(toolName: "search_by_keyword", args: args))
        }

        let response = try await client.chatCompletionRaw(
            model: "gpt-5.4-nano",
            messages: [["role": "user", "content": "hello"]],
            tools: SearchToolDefinitions.allTools
        )

        let choice = try XCTUnwrap(response.choices.first)
        XCTAssertTrue(choice.message.hasToolCalls)
        XCTAssertEqual(choice.message.toolCalls?.count, 1)
        XCTAssertEqual(choice.message.toolCalls?.first?.function.name, "search_by_keyword")
        XCTAssertEqual(choice.message.toolCalls?.first?.id, "call_abc")
        XCTAssertEqual(choice.message.content, "")
    }

    func testNullContentDoesNotCrash() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (self.makeHTTPResponse(statusCode: 200),
                    self.toolCallResponseJSON(toolName: "filter_by_app", args: "{\\\"app_name\\\":\\\"Safari\\\"}"))
        }

        let response = try await client.chatCompletionRaw(
            model: "gpt-5.4-nano",
            messages: [["role": "user", "content": "test"]],
            tools: SearchToolDefinitions.allTools
        )
        let choice = try XCTUnwrap(response.choices.first)
        // content should be "" not crash
        XCTAssertEqual(choice.message.content, "")
    }

    func testPlainTextResponseHasNoToolCalls() async throws {
        MockURLProtocol.requestHandler = { _ in
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "Here is the answer."))
        }

        let response = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "question")]
        )

        let choice = try XCTUnwrap(response.choices.first)
        XCTAssertFalse(choice.message.hasToolCalls)
        XCTAssertNil(choice.message.toolCalls)
        XCTAssertEqual(choice.message.content, "Here is the answer.")
    }

    func testChatCompletionRawSendsToolsInBody() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            if let body = request.httpBody {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "ok"))
        }

        _ = try await client.chatCompletionRaw(
            model: "gpt-5.4-nano",
            messages: [["role": "user", "content": "test"]],
            tools: SearchToolDefinitions.allTools,
            toolChoice: "auto"
        )

        let body = try XCTUnwrap(capturedBody)
        XCTAssertNotNil(body["tools"])
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
    }

    func testChatCompletionRawToolChoiceNone() async throws {
        var capturedBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            if let body = request.httpBody {
                capturedBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "final answer"))
        }

        _ = try await client.chatCompletionRaw(
            model: "gpt-5.4-nano",
            messages: [["role": "user", "content": "test"]],
            tools: SearchToolDefinitions.allTools,
            toolChoice: "none"
        )

        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(body["tool_choice"] as? String, "none")
    }
}

// MARK: - AgenticRAGEngine Unit Tests

final class AgenticRAGEngineTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var client: OpenAIClient!
    private var vectorEngine: VectorSearchEngine!
    private var engine: AgenticRAGEngine!
    private var settings: Settings!
    private var suiteName: String!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        clipStore = ClipStore(dbQueue: dbQueue)
        embeddingStore = EmbeddingStore(dbQueue: dbQueue)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session, initialRetryDelay: 100_000)

        vectorEngine = VectorSearchEngine(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client
        )
        engine = AgenticRAGEngine(client: client, clipStore: clipStore, vectorEngine: vectorEngine)

        suiteName = "test.task7.agentic.\(UUID().uuidString)"
        Settings.shared.openAIAPIKey = "sk-test-agentic-rag"
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
        engine = nil
        vectorEngine = nil
        client = nil
        embeddingStore = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func textResponseJSON(content: String) -> Data {
        let escaped = content.replacingOccurrences(of: "\"", with: "\\\"")
        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "message": { "role": "assistant", "content": "\(escaped)" },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        }
        """
        return json.data(using: .utf8)!
    }

    private func toolCallJSON(toolName: String, args: [String: Any], toolCallId: String = "call_001") -> Data {
        let argsData = try! JSONSerialization.data(withJSONObject: args)
        let argsStr = String(data: argsData, encoding: .utf8)!
            .replacingOccurrences(of: "\"", with: "\\\"")

        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": null,
                "tool_calls": [
                  {
                    "id": "\(toolCallId)",
                    "type": "function",
                    "function": { "name": "\(toolName)", "arguments": "\(argsStr)" }
                  }
                ]
              },
              "finish_reason": "tool_calls"
            }
          ],
          "usage": { "prompt_tokens": 20, "completion_tokens": 10, "total_tokens": 30 }
        }
        """
        return json.data(using: .utf8)!
    }

    @discardableResult
    private func insertClip(text: String, sourceApp: String? = nil, tags: String? = nil) throws -> Int64 {
        let hash = Hashing.sha256(data: (text + (sourceApp ?? "")).data(using: .utf8)!)
        var record = ClipRecord(
            id: nil,
            contentType: "text",
            textContent: text,
            dataHash: hash,
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: sourceApp,
            byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: tags,
            imageDescription: nil,
            aiProcessed: 1,
            aiProcessedAt: Date().timeIntervalSince1970
        )
        return try clipStore.insertRecord(&record)
    }

    // MARK: - Fallback to classic RAG

    func testFallsBackToClassicRAGWhenDisabled() async throws {
        Settings.shared.agenticSearchEnabled = false

        // Mock the embedding call (classic RAG does hybridSearch → embedQuery).
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("embeddings") == true {
                let embJSON = """
                {
                  "data": [{ "embedding": [], "index": 0 }],
                  "usage": { "prompt_tokens": 5, "total_tokens": 5 }
                }
                """
                return (self.makeHTTPResponse(statusCode: 200), embJSON.data(using: .utf8)!)
            }
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "Classic RAG answer."))
        }

        // No clips in DB → hybridSearch returns [] → classic RAG returns "not found" message.
        let result = try await engine.query("what did I copy?")
        XCTAssertFalse(result.answer.isEmpty)
    }

    // MARK: - buildInitialMessages

    func testBuildInitialMessagesIncludesSystemAndQuestion() {
        let messages = engine.buildInitialMessages(question: "What is Swift?", conversationHistory: nil)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "What is Swift?")
    }

    func testBuildInitialMessagesIncludesHistory() {
        let history = [
            OpenAIClient.ChatMessage(role: "user", content: "Hello"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Hi there!")
        ]
        let messages = engine.buildInitialMessages(question: "Follow up?", conversationHistory: history)
        // system + 2 history + user question
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[1]["content"] as? String, "Hello")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[3]["role"] as? String, "user")
        XCTAssertEqual(messages[3]["content"] as? String, "Follow up?")
    }

    func testBuildInitialMessagesTrimsHistoryToLimit() {
        let originalLimit = Settings.shared.chatContextMessageLimit
        Settings.shared.chatContextMessageLimit = 2
        defer { Settings.shared.chatContextMessageLimit = originalLimit }

        let history = [
            OpenAIClient.ChatMessage(role: "user", content: "Msg 1"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Resp 1"),
            OpenAIClient.ChatMessage(role: "user", content: "Msg 2"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Resp 2"),
        ]
        let messages = engine.buildInitialMessages(question: "Current question", conversationHistory: history)
        // system + 2 history (last 2) + user question = 4
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[1]["content"] as? String, "Msg 2")
        XCTAssertEqual(messages[2]["content"] as? String, "Resp 2")
    }

    // MARK: - parseArguments

    func testParseArgumentsValidJSON() {
        let json = #"{"query":"swift","limit":10}"#
        let args = engine.parseArguments(json)
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "swift")
        XCTAssertEqual(args?["limit"] as? Int, 10)
    }

    func testParseArgumentsInvalidJSON() {
        let args = engine.parseArguments("not json")
        XCTAssertNil(args)
    }

    func testParseArgumentsEmptyJSON() {
        let args = engine.parseArguments("{}")
        XCTAssertNotNil(args)
        XCTAssertTrue(args?.isEmpty ?? false)
    }

    // MARK: - formatClips

    func testFormatClipsEmptyReturnsNoResults() {
        let result = engine.formatClips([])
        XCTAssertEqual(result, "No results found.")
    }

    func testFormatClipsIncludesClipIdAndApp() throws {
        try insertClip(text: "Hello world", sourceApp: "com.apple.Safari")
        let clips = try clipStore.fetchRecent(limit: 10)
        let result = engine.formatClips(clips)
        XCTAssertTrue(result.contains("#"))
        XCTAssertTrue(result.contains("com.apple.Safari"))
        XCTAssertTrue(result.contains("Hello world"))
    }

    func testFormatClipsTruncatesPreviewTo200Chars() throws {
        let longText = String(repeating: "x", count: 500)
        try insertClip(text: longText)
        let clips = try clipStore.fetchRecent(limit: 10)
        let result = engine.formatClips(clips)
        // The 200-char preview should be in the output, not the full 500 chars.
        XCTAssertTrue(result.contains(String(repeating: "x", count: 200)))
        // Should not contain 201st char in a single run.
        XCTAssertFalse(result.contains(String(repeating: "x", count: 201)))
    }

    // MARK: - executeToolCall — keyword search

    func testExecuteToolCallKeywordSearch() async throws {
        try insertClip(text: "Swift concurrency async await", sourceApp: "Xcode")

        let toolCall = ToolCallResponse(
            id: "call_kw",
            function: ToolCallResponse.FunctionCall(name: "search_by_keyword",
                                                     arguments: "{\"query\":\"Swift concurrency\"}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertFalse(result.isEmpty)
        // Should contain results or "No results found."
        XCTAssertTrue(result.contains("result") || result.contains("Swift"))
    }

    func testExecuteToolCallKeywordSearchMissingQuery() async throws {
        let toolCall = ToolCallResponse(
            id: "call_kw",
            function: ToolCallResponse.FunctionCall(name: "search_by_keyword", arguments: "{}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("Error"))
    }

    // MARK: - executeToolCall — filter_by_app

    func testExecuteToolCallFilterByApp() async throws {
        try insertClip(text: "Safari clipboard content", sourceApp: "com.apple.Safari")
        try insertClip(text: "Xcode content", sourceApp: "com.apple.dt.Xcode")

        let toolCall = ToolCallResponse(
            id: "call_app",
            function: ToolCallResponse.FunctionCall(name: "filter_by_app",
                                                     arguments: "{\"app_name\":\"Safari\"}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("Safari") || result.contains("result"))
    }

    func testExecuteToolCallFilterByAppMissingArg() async throws {
        let toolCall = ToolCallResponse(
            id: "call_app",
            function: ToolCallResponse.FunctionCall(name: "filter_by_app", arguments: "{}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("Error"))
    }

    // MARK: - executeToolCall — filter_by_tags

    func testExecuteToolCallFilterByTags() async throws {
        try insertClip(text: "function foo() {}", tags: "[\"code\"]")

        let toolCall = ToolCallResponse(
            id: "call_tags",
            function: ToolCallResponse.FunctionCall(name: "filter_by_tags",
                                                     arguments: "{\"tags\":[\"code\"]}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertFalse(result.isEmpty)
    }

    func testExecuteToolCallFilterByTagsMissingArg() async throws {
        let toolCall = ToolCallResponse(
            id: "call_tags",
            function: ToolCallResponse.FunctionCall(name: "filter_by_tags", arguments: "{}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("Error"))
    }

    // MARK: - executeToolCall — filter_by_content_type

    func testExecuteToolCallFilterByContentType() async throws {
        try insertClip(text: "plain text clip")

        let toolCall = ToolCallResponse(
            id: "call_ct",
            function: ToolCallResponse.FunctionCall(name: "filter_by_content_type",
                                                     arguments: "{\"content_type\":\"text\"}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - executeToolCall — filter_by_date_range

    func testExecuteToolCallFilterByDateRange() async throws {
        try insertClip(text: "recent clip")

        let now = Date()
        let past = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(3600)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let startStr = formatter.string(from: past)
        let endStr = formatter.string(from: future)

        let args = "{\"start_date\":\"\(startStr)\",\"end_date\":\"\(endStr)\"}"
        let toolCall = ToolCallResponse(
            id: "call_dr",
            function: ToolCallResponse.FunctionCall(name: "filter_by_date_range", arguments: args)
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertFalse(result.isEmpty)
        XCTAssertFalse(result.contains("Error:"), "Got unexpected error: \(result)")
    }

    func testExecuteToolCallFilterByDateRangeMissingArgs() async throws {
        let toolCall = ToolCallResponse(
            id: "call_dr",
            function: ToolCallResponse.FunctionCall(name: "filter_by_date_range",
                                                     arguments: "{\"start_date\":\"2024-01-01T00:00:00Z\"}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("Error"))
    }

    // MARK: - executeToolCall — unknown tool

    func testExecuteToolCallUnknownTool() async throws {
        let toolCall = ToolCallResponse(
            id: "call_unknown",
            function: ToolCallResponse.FunctionCall(name: "nonexistent_tool", arguments: "{}")
        )
        let result = await engine.executeToolCall(toolCall)
        XCTAssertTrue(result.contains("unknown tool"))
    }

    // MARK: - Single-round query (model answers directly without tool calls)

    func testQueryDirectAnswerNoToolCalls() async throws {
        Settings.shared.agenticSearchEnabled = true

        MockURLProtocol.requestHandler = { _ in
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "The answer is 42."))
        }

        let result = try await engine.query("What is the answer?")
        XCTAssertEqual(result.answer, "The answer is 42.")
        XCTAssertTrue(result.citedClipIDs.isEmpty)
    }

    func testQueryDirectAnswerWithCitations() async throws {
        Settings.shared.agenticSearchEnabled = true

        MockURLProtocol.requestHandler = { _ in
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "The clip #42 has the answer."))
        }

        let result = try await engine.query("What is in #42?")
        XCTAssertEqual(result.answer, "The clip #42 has the answer.")
        XCTAssertEqual(result.citedClipIDs, [42])
    }

    // MARK: - Multi-round query (tool call then answer)

    func testQueryToolCallThenAnswer() async throws {
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3

        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                // First call: model invokes a tool
                return (self.makeHTTPResponse(statusCode: 200),
                        self.toolCallJSON(toolName: "search_by_keyword",
                                          args: ["query": "swift", "limit": 10]))
            } else {
                // Second call: model provides the final answer
                return (self.makeHTTPResponse(statusCode: 200),
                        self.textResponseJSON(content: "Found results about Swift #1."))
            }
        }

        let result = try await engine.query("Tell me about Swift")
        XCTAssertEqual(result.answer, "Found results about Swift #1.")
        XCTAssertEqual(result.citedClipIDs, [1])
        XCTAssertEqual(callCount, 2)
    }

    // MARK: - Iteration cap enforcement

    func testQueryIterationCapForcesAnswer() async throws {
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 2

        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount <= 2 {
                // Model keeps calling tools
                return (self.makeHTTPResponse(statusCode: 200),
                        self.toolCallJSON(toolName: "search_by_keyword",
                                          args: ["query": "test \(callCount)", "limit": 5]))
            } else {
                // Final forced answer
                return (self.makeHTTPResponse(statusCode: 200),
                        self.textResponseJSON(content: "Based on gathered info, here is the answer."))
            }
        }

        let result = try await engine.query("Search forever")
        // Should stop after 2 iterations + 1 forced final answer call = 3 total
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(result.answer, "Based on gathered info, here is the answer.")
    }

    // MARK: - Conversation history in agentic mode

    func testQueryIncludesConversationHistory() async throws {
        Settings.shared.agenticSearchEnabled = true

        var capturedMessages: [[String: Any]]?
        MockURLProtocol.requestHandler = { request in
            if let body = request.httpBody,
               let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let msgs = json["messages"] as? [[String: Any]] {
                capturedMessages = msgs
            }
            return (self.makeHTTPResponse(statusCode: 200),
                    self.textResponseJSON(content: "Answer with context."))
        }

        let history = [
            OpenAIClient.ChatMessage(role: "user", content: "Prior question"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Prior answer")
        ]

        _ = try await engine.query("Follow up", conversationHistory: history)

        // messages: [system, prior-user, prior-assistant, current-user]
        let messages = try XCTUnwrap(capturedMessages)
        XCTAssertGreaterThanOrEqual(messages.count, 4)
        let roles = messages.map { $0["role"] as? String }
        XCTAssertTrue(roles.contains("system"))
        XCTAssertTrue(roles.contains("user"))
        XCTAssertTrue(roles.contains("assistant"))
    }
}
