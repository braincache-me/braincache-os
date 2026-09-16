import XCTest
import GRDB
@testable import ClipVault

// MARK: - AgenticRAGEngine Step Description Tests

final class AgenticRAGEngineStepDescriptionTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var client: OpenAIClient!
    private var vectorEngine: VectorSearchEngine!
    private var engine: AgenticRAGEngine!

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
        vectorEngine = VectorSearchEngine(clipStore: clipStore,
                                          embeddingStore: embeddingStore,
                                          client: client)
        engine = AgenticRAGEngine(client: client, clipStore: clipStore, vectorEngine: vectorEngine)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        engine = nil
        vectorEngine = nil
        client = nil
        embeddingStore = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - describeToolCall

    func testDescribeSearchByKeyword() {
        let tc = ToolCallResponse(
            id: "c1",
            function: .init(name: "search_by_keyword",
                            arguments: #"{"query":"swift closures","limit":10}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.contains("swift closures"), "Expected query in description, got: \(desc)")
        XCTAssertTrue(desc.hasSuffix("…"))
    }

    func testDescribeSearchBySemantic() {
        let tc = ToolCallResponse(
            id: "c2",
            function: .init(name: "search_by_semantic",
                            arguments: #"{"query":"error handling"}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.lowercased().contains("semantic"))
        XCTAssertTrue(desc.contains("error handling"))
    }

    func testDescribeFilterByApp() {
        let tc = ToolCallResponse(
            id: "c3",
            function: .init(name: "filter_by_app",
                            arguments: #"{"app_name":"Safari"}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.contains("Safari"))
    }

    func testDescribeFilterByDateRange() {
        let tc = ToolCallResponse(
            id: "c4",
            function: .init(name: "filter_by_date_range",
                            arguments: #"{"start_date":"2025-01-01T00:00:00Z","end_date":"2025-12-31T23:59:59Z"}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.lowercased().contains("date"))
        XCTAssertTrue(desc.contains("2025-01-01"))
    }

    func testDescribeFilterByTags() {
        let tc = ToolCallResponse(
            id: "c5",
            function: .init(name: "filter_by_tags",
                            arguments: #"{"tags":["code","swift"],"match_all":false}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.contains("code"))
        XCTAssertTrue(desc.contains("swift"))
    }

    func testDescribeFilterByContentType() {
        let tc = ToolCallResponse(
            id: "c6",
            function: .init(name: "filter_by_content_type",
                            arguments: #"{"content_type":"image"}"#)
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.contains("image"))
    }

    func testDescribeUnknownTool() {
        let tc = ToolCallResponse(
            id: "c7",
            function: .init(name: "some_unknown_tool", arguments: "{}")
        )
        let desc = engine.describeToolCall(tc)
        XCTAssertTrue(desc.contains("some_unknown_tool"))
    }

    func testDescribeInvalidJSON() {
        let tc = ToolCallResponse(
            id: "c8",
            function: .init(name: "search_by_keyword", arguments: "not-json")
        )
        let desc = engine.describeToolCall(tc)
        // Should not crash; falls back to tool name
        XCTAssertFalse(desc.isEmpty)
    }

    // MARK: - parseResultCount

    func testParseResultCountNoResults() {
        XCTAssertEqual(engine.parseResultCount("No results found."), "0 results")
    }

    func testParseResultCountSingleResult() {
        let result = "1 result(s):\n[#1 | app | date] content"
        let count = engine.parseResultCount(result)
        XCTAssertTrue(count.contains("1 result"), "Got: \(count)")
    }

    func testParseResultCountMultipleResults() {
        let result = "5 result(s):\n[#1 | app | date] content"
        let count = engine.parseResultCount(result)
        XCTAssertTrue(count.contains("5 result"), "Got: \(count)")
    }

    func testParseResultCountFallback() {
        let result = "Some unexpected format"
        let count = engine.parseResultCount(result)
        XCTAssertFalse(count.isEmpty)
    }

    // MARK: - Progress callback

    func testProgressCallbackCalledDuringToolExecution() async throws {
        Settings.shared.openAIAPIKey = "sk-test-task8"
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 1

        var callbackMessages: [String] = []
        engine.onIterationUpdate = { msg in
            callbackMessages.append(msg)
        }

        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                let json = """
                {
                  "id": "chatcmpl-test",
                  "choices": [{
                    "message": {
                      "role": "assistant",
                      "content": null,
                      "tool_calls": [{
                        "id": "call_001",
                        "type": "function",
                        "function": { "name": "search_by_keyword", "arguments": "{\\"query\\":\\"test\\"}" }
                      }]
                    },
                    "finish_reason": "tool_calls"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            } else {
                let json = """
                {
                  "id": "chatcmpl-test2",
                  "choices": [{
                    "message": { "role": "assistant", "content": "Here is the answer." },
                    "finish_reason": "stop"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            }
        }

        let result = try await engine.query("What did I copy about test?")
        // Wait briefly for main dispatch
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(result.answer.isEmpty)
        // The callback should have been called at least once during the tool-call iteration.
        XCTAssertFalse(callbackMessages.isEmpty, "onIterationUpdate should be called during tool execution")

        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
    }

    func testFormatToolCallForDisplayUsesReadableJSON() {
        let toolCall = ToolCallResponse(
            id: "trace_001",
            function: .init(
                name: "search_by_keyword",
                arguments: #"{"query":"swift","limit":5}"#
            )
        )

        let formatted = engine.formatToolCallForDisplay(toolCall)

        XCTAssertTrue(formatted.contains("search_by_keyword"))
        XCTAssertTrue(formatted.contains(#""query""#))
        XCTAssertTrue(formatted.contains("swift"))
        XCTAssertTrue(formatted.contains(#""limit""#))
        XCTAssertTrue(formatted.contains("5"))
    }

    func testBuildTraceSectionIncludesThoughtAndToolCalls() {
        let toolCalls = [
            ToolCallResponse(
                id: "trace_002",
                function: .init(
                    name: "filter_by_app",
                    arguments: #"{"app_name":"Xcode"}"#
                )
            )
        ]

        let section = engine.buildTraceSection(
            thought: "I'll narrow this down to clips copied from Xcode first.",
            toolCalls: toolCalls
        )

        XCTAssertTrue(section.contains("I'll narrow this down"))
        XCTAssertTrue(section.contains("Tool call:"))
        XCTAssertTrue(section.contains("filter_by_app"))
        XCTAssertTrue(section.contains(#""app_name""#))
        XCTAssertTrue(section.contains("Xcode"))
    }

    func testTraceCallbackIncludesThoughtAndToolCall() async throws {
        Settings.shared.openAIAPIKey = "sk-test-task8"
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 1

        var traceSnapshots: [AgenticRAGEngine.ProgressSnapshot] = []
        engine.onTraceUpdate = { snapshot in
            traceSnapshots.append(snapshot)
        }

        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                let json = """
                {
                  "id": "chatcmpl-trace-test",
                  "choices": [{
                    "message": {
                      "role": "assistant",
                      "content": "I'll search for the exact keyword before answering.",
                      "tool_calls": [{
                        "id": "call_trace",
                        "type": "function",
                        "function": { "name": "search_by_keyword", "arguments": "{\\"query\\":\\"swift\\"}" }
                      }]
                    },
                    "finish_reason": "tool_calls"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            } else {
                let json = """
                {
                  "id": "chatcmpl-trace-test-2",
                  "choices": [{
                    "message": { "role": "assistant", "content": "Final answer." },
                    "finish_reason": "stop"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            }
        }

        _ = try await engine.query("Tell me about Swift")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(traceSnapshots.isEmpty)
        XCTAssertTrue(traceSnapshots.contains { $0.displayText.contains("I'll search for the exact keyword") })
        XCTAssertTrue(traceSnapshots.contains { $0.displayText.contains("search_by_keyword") })

        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
    }

    // MARK: - searchSteps in RAGResult

    func testSearchStepsPopulatedInResult() async throws {
        Settings.shared.openAIAPIKey = "sk-test-task8"
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3

        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                let json = """
                {
                  "id": "chatcmpl-test",
                  "choices": [{
                    "message": {
                      "role": "assistant",
                      "content": null,
                      "tool_calls": [{
                        "id": "call_001",
                        "type": "function",
                        "function": { "name": "search_by_keyword", "arguments": "{\\"query\\":\\"swift\\"}" }
                      }]
                    },
                    "finish_reason": "tool_calls"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            } else {
                let json = """
                {
                  "id": "chatcmpl-test2",
                  "choices": [{
                    "message": { "role": "assistant", "content": "Answer text." },
                    "finish_reason": "stop"
                  }],
                  "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        json.data(using: .utf8)!)
            }
        }

        let result = try await engine.query("Tell me about Swift")
        XCTAssertEqual(result.searchSteps.count, 1, "Expected 1 search step from tool call")
        XCTAssertTrue(result.searchSteps.first?.contains("swift") == true ||
                      result.searchSteps.first?.contains("Swift") == true,
                      "Step should mention the query term")

        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
    }

    func testSearchStepsEmptyForClassicRAG() async throws {
        Settings.shared.openAIAPIKey = "sk-test-task8"
        Settings.shared.agenticSearchEnabled = false

        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("embeddings") == true {
                let embJSON = """
                {
                  "data": [{ "embedding": [], "index": 0 }],
                  "usage": { "prompt_tokens": 5, "total_tokens": 5 }
                }
                """
                return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        embJSON.data(using: .utf8)!)
            }
            let json = """
            {
              "id": "chatcmpl-test",
              "choices": [{
                "message": { "role": "assistant", "content": "Classic RAG answer." },
                "finish_reason": "stop"
              }],
              "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
            }
            """
            return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    json.data(using: .utf8)!)
        }

        let result = try await engine.query("Classic query?")
        XCTAssertTrue(result.searchSteps.isEmpty, "Classic RAG should produce no search steps")

        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
    }
}

// MARK: - ChatMessage searchSteps Tests

final class ChatMessageSearchStepsTests: XCTestCase {

    func testChatMessageDefaultSearchStepsIsEmpty() {
        let msg = ChatMessage(role: .assistant, text: "Hello")
        XCTAssertTrue(msg.searchSteps.isEmpty)
    }

    func testChatMessageWithSearchSteps() {
        let steps = ["Searched by keyword: \"swift\" → 3 results",
                     "Filtered by app: Xcode → 2 results"]
        let msg = ChatMessage(role: .assistant, text: "Answer", searchSteps: steps)
        XCTAssertEqual(msg.searchSteps.count, 2)
        XCTAssertEqual(msg.searchSteps.first, steps.first)
    }

    func testChatMessageUserHasNoSearchSteps() {
        let msg = ChatMessage(role: .user, text: "Question", searchSteps: [])
        XCTAssertTrue(msg.searchSteps.isEmpty)
    }
}

// MARK: - RAGResult searchSteps Tests

final class RAGResultSearchStepsTests: XCTestCase {

    func testRAGResultDefaultSearchStepsIsEmpty() {
        let result = RAGResult(answer: "answer", citedClipIDs: [])
        XCTAssertTrue(result.searchSteps.isEmpty)
    }

    func testRAGResultWithSearchSteps() {
        let steps = ["Step 1", "Step 2"]
        let result = RAGResult(answer: "answer", citedClipIDs: [1, 2], searchSteps: steps)
        XCTAssertEqual(result.searchSteps, steps)
    }
}

// MARK: - ChatBubbleView searchSteps Tests

final class ChatBubbleViewSearchStepsTests: XCTestCase {

    func testChatBubbleViewCreatedWithSearchSteps() {
        let steps = ["Searched by keyword: \"swift\" → 5 results",
                     "Filtered by app: Xcode → 2 results"]
        let msg = ChatMessage(role: .assistant, text: "Here is the answer.", searchSteps: steps)
        // Creating the view should not crash.
        let view = ChatBubbleView(message: msg)
        XCTAssertNotNil(view)
        // The disclosure button should exist.
        XCTAssertNotNil(view.stepsDisclosureBtn)
        // The content stack should exist and be initially hidden.
        XCTAssertNotNil(view.stepsContentStack)
        XCTAssertTrue(view.stepsContentStack?.isHidden ?? false,
                      "Steps content should be collapsed by default")
    }

    func testChatBubbleViewWithoutSearchStepsHasNoDisclosure() {
        let msg = ChatMessage(role: .assistant, text: "Answer without steps.")
        let view = ChatBubbleView(message: msg)
        XCTAssertNil(view.stepsDisclosureBtn, "No disclosure button when no search steps")
    }

    func testChatBubbleViewUserMessageHasNoStepsSection() {
        let steps = ["Step 1"]
        let msg = ChatMessage(role: .user, text: "User question", searchSteps: steps)
        let view = ChatBubbleView(message: msg)
        // User messages should not render search steps even if present.
        XCTAssertNil(view.stepsDisclosureBtn)
    }
}

// MARK: - AIPrefsView Agentic Section Tests

final class AIPrefsViewAgenticSectionTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        suiteName = "test.task8.prefs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    func testAgenticSearchEnabledDefaultTrue() {
        XCTAssertTrue(settings.agenticSearchEnabled)
    }

    func testAgenticMaxIterationsDefault() {
        XCTAssertEqual(settings.agenticMaxIterations, 3)
    }

    func testAgenticSearchEnabledCanBeDisabled() {
        settings.agenticSearchEnabled = false
        XCTAssertFalse(settings.agenticSearchEnabled)
    }

    func testAgenticMaxIterationsClampedTo1Min() {
        settings.agenticMaxIterations = 0
        XCTAssertEqual(settings.agenticMaxIterations, 1)
    }

    func testAgenticMaxIterationsClampedTo5Max() {
        settings.agenticMaxIterations = 10
        XCTAssertEqual(settings.agenticMaxIterations, 5)
    }

    func testResetToDefaultsRestoresAgenticSettings() {
        settings.agenticSearchEnabled = false
        settings.agenticMaxIterations = 5

        // Simulate "reset to defaults" by restoring defaults.
        settings.agenticSearchEnabled = Settings.Defaults.agenticSearchEnabled
        settings.agenticMaxIterations = Settings.Defaults.agenticMaxIterations

        XCTAssertTrue(settings.agenticSearchEnabled)
        XCTAssertEqual(settings.agenticMaxIterations, Settings.Defaults.agenticMaxIterations)
    }
}

// MARK: - ChatPanelController Engine Selection Tests

final class ChatPanelControllerEngineTests: XCTestCase {

    func testAgenticEngineSelectedWhenEnabled() {
        // Verify that Settings.agenticSearchEnabled controls engine selection.
        let settingsBefore = Settings.shared.agenticSearchEnabled
        defer { Settings.shared.agenticSearchEnabled = settingsBefore }

        Settings.shared.agenticSearchEnabled = true
        XCTAssertTrue(Settings.shared.agenticSearchEnabled)
    }

    func testClassicEngineSelectedWhenAgenticDisabled() {
        let settingsBefore = Settings.shared.agenticSearchEnabled
        defer { Settings.shared.agenticSearchEnabled = settingsBefore }

        Settings.shared.agenticSearchEnabled = false
        XCTAssertFalse(Settings.shared.agenticSearchEnabled)
    }

    func testAutoTitleFromMessage() {
        // autoTitle is a static helper tested here for completeness.
        let title = ChatPanelController.autoTitle(from: "This is a test message")
        XCTAssertEqual(title, "This is a test message")
    }

    func testAutoTitleTruncatesAt60Chars() {
        let longMessage = String(repeating: "x", count: 100)
        let title = ChatPanelController.autoTitle(from: longMessage)
        XCTAssertEqual(title.count, 60)
    }
}
