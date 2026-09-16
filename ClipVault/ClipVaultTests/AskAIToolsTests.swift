import XCTest
@testable import ClipVault

// MARK: - ResponsesStreamParser

final class ResponsesStreamParserTests: XCTestCase {

    func testParsesReasoningSummaryDelta() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.reasoning_summary_text.delta",
            "delta": "Considering the transcript…",
        ])
        XCTAssertEqual(event, .reasoningDelta("Considering the transcript…"))
    }

    func testParsesOutputTextDelta() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.output_text.delta",
            "delta": "Hello",
        ])
        XCTAssertEqual(event, .textDelta("Hello"))
    }

    func testEmptyDeltaIsIgnored() {
        XCTAssertNil(ResponsesStreamParser.event(from: [
            "type": "response.output_text.delta",
            "delta": "",
        ]))
    }

    func testParsesWebSearchCallItemAdded() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.output_item.added",
            "item": ["type": "web_search_call", "id": "ws_1"],
        ])
        XCTAssertEqual(event, .webSearchStarted)
    }

    func testMessageItemAddedIsIgnored() {
        XCTAssertNil(ResponsesStreamParser.event(from: [
            "type": "response.output_item.added",
            "item": ["type": "message"],
        ]))
    }

    func testParsesFunctionCallItemDone() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.output_item.done",
            "item": [
                "type": "function_call",
                "call_id": "call_abc",
                "name": "search_claude_code_history",
                "arguments": "{\"query\":\"migration\"}",
            ],
        ])
        XCTAssertEqual(event, .functionCall(
            callId: "call_abc",
            name: "search_claude_code_history",
            arguments: "{\"query\":\"migration\"}"
        ))
    }

    func testParsesCompletedWithUsage() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.completed",
            "response": [
                "id": "resp_123",
                "usage": [
                    "input_tokens": 100,
                    "output_tokens": 40,
                    "input_tokens_details": ["cached_tokens": 25],
                ],
            ],
        ])
        XCTAssertEqual(event, .completed(
            responseId: "resp_123",
            usage: ResponsesUsage(inputTokens: 100, outputTokens: 40, cachedInputTokens: 25)
        ))
    }

    func testParsesFailedResponse() {
        let event = ResponsesStreamParser.event(from: [
            "type": "response.failed",
            "response": ["error": ["message": "rate limited"]],
        ])
        XCTAssertEqual(event, .failed(message: "rate limited"))
    }

    func testParsesErrorEvent() {
        let event = ResponsesStreamParser.event(from: [
            "type": "error",
            "message": "boom",
        ])
        XCTAssertEqual(event, .failed(message: "boom"))
    }

    func testUnknownEventTypeIsIgnored() {
        XCTAssertNil(ResponsesStreamParser.event(from: ["type": "response.in_progress"]))
        XCTAssertNil(ResponsesStreamParser.event(from: [:]))
    }
}

// MARK: - AgentHistorySearchService

final class AgentHistorySearchServiceTests: XCTestCase {

    private var tempRoot: URL!
    private var claudeRoot: URL!
    private var codexRoot: URL!
    private var service: AgentHistorySearchService!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentHistoryTests-\(UUID().uuidString)")
        claudeRoot = tempRoot.appendingPathComponent(".claude")
        codexRoot = tempRoot.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: claudeRoot.appendingPathComponent("projects/my-project"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codexRoot.appendingPathComponent("sessions/2026/08/01"),
            withIntermediateDirectories: true
        )
        service = AgentHistorySearchService(claudeRoot: claudeRoot, codexRoot: codexRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func writeClaudeSession(_ lines: [String], file: String = "session-1.jsonl") throws {
        let url = claudeRoot.appendingPathComponent("projects/my-project/\(file)")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeCodexSession(_ lines: [String]) throws {
        let url = codexRoot.appendingPathComponent("sessions/2026/08/01/rollout-1.jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsMatchInClaudeStyleTranscript() throws {
        try writeClaudeSession([
            #"{"type":"user","timestamp":"2026-08-01T10:00:00Z","message":{"role":"user","content":"please fix the GRDB migration crash"}}"#,
            #"{"type":"assistant","timestamp":"2026-08-01T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"I added a v5 migration block."}]}}"#,
        ])

        let matches = service.search(source: .claudeCode, query: "migration", limit: 10)
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].file.contains("session-1.jsonl"))
        XCTAssertTrue(matches.contains { $0.role == "assistant" && $0.snippet.contains("v5 migration block") })
        XCTAssertTrue(matches.contains { $0.timestamp == "2026-08-01T10:00:00Z" })
    }

    func testFindsMatchInCodexStyleTranscript() throws {
        try writeCodexSession([
            #"{"timestamp":"2026-08-01T09:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Deployed the talkflow server with pm2."}]}}"#,
        ])

        let matches = service.search(source: .codex, query: "talkflow", limit: 10)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].role, "assistant")
        XCTAssertTrue(matches[0].snippet.contains("talkflow server"))
    }

    func testSearchIsCaseInsensitive() throws {
        try writeClaudeSession([
            #"{"message":{"role":"user","content":"Refactor the PasteService class"}}"#,
        ])
        XCTAssertEqual(service.search(source: .claudeCode, query: "pasteservice", limit: 5).count, 1)
    }

    func testRespectsLimit() throws {
        let lines = (0..<10).map {
            #"{"message":{"role":"user","content":"widget request number \#($0)"}}"#
        }
        try writeClaudeSession(lines)
        let matches = service.search(source: .claudeCode, query: "widget", limit: 3)
        XCTAssertEqual(matches.count, 3)
    }

    func testNoMatchesReturnsEmpty() throws {
        try writeClaudeSession([#"{"message":{"role":"user","content":"hello world"}}"#])
        XCTAssertTrue(service.search(source: .claudeCode, query: "nonexistent-term", limit: 5).isEmpty)
    }

    func testMissingRootReturnsEmpty() {
        let missing = AgentHistorySearchService(
            claudeRoot: tempRoot.appendingPathComponent("nope"),
            codexRoot: tempRoot.appendingPathComponent("nada")
        )
        XCTAssertTrue(missing.search(source: .claudeCode, query: "anything", limit: 5).isEmpty)
        XCTAssertTrue(missing.search(source: .codex, query: "anything", limit: 5).isEmpty)
    }

    func testEmptyQueryReturnsEmpty() throws {
        try writeClaudeSession([#"{"message":{"role":"user","content":"hello"}}"#])
        XCTAssertTrue(service.search(source: .claudeCode, query: "   ", limit: 5).isEmpty)
    }

    func testSnippetCentersOnMatchAndAddsEllipses() {
        let long = String(repeating: "a", count: 500) + " NEEDLE " + String(repeating: "b", count: 500)
        let snippet = AgentHistorySearchService.snippet(around: "needle", in: long)
        XCTAssertTrue(snippet.contains("NEEDLE"))
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertLessThan(snippet.count, 400)
    }

    func testFormatResultsListsMatches() {
        let matches = [
            AgentHistoryMatch(file: "projects/x/s.jsonl", timestamp: "2026-08-01T10:00:00Z",
                              role: "assistant", snippet: "did the thing"),
        ]
        let text = AgentHistorySearchService.formatResults(
            matches, query: "thing", sourceLabel: "Claude Code CLI history (~/.claude)"
        )
        XCTAssertTrue(text.contains("1 match"))
        XCTAssertTrue(text.contains("projects/x/s.jsonl"))
        XCTAssertTrue(text.contains("did the thing"))
    }

    func testFormatResultsEmptyExplains() {
        let text = AgentHistorySearchService.formatResults(
            [], query: "ghost", sourceLabel: "Codex CLI history (~/.codex)"
        )
        XCTAssertTrue(text.contains("No matches"))
        XCTAssertTrue(text.contains("ghost"))
    }
}

// MARK: - AskAIToolDefinitions / Executor

final class AskAIToolDefinitionsTests: XCTestCase {

    func testNoFlagsMeansNoTools() {
        XCTAssertTrue(AskAIToolDefinitions.tools(
            webSearch: false, claudeCodeHistory: false, codexHistory: false
        ).isEmpty)
    }

    func testAllFlagsProduceFiveTools() {
        let tools = AskAIToolDefinitions.tools(
            webSearch: true, claudeCodeHistory: true, codexHistory: true
        )
        XCTAssertEqual(tools.count, 5)
        XCTAssertEqual(tools[0]["type"] as? String, "web_search")
        XCTAssertEqual(tools[1]["name"] as? String, "search_claude_code_history")
        XCTAssertEqual(tools[2]["name"] as? String, "ask_claude_code")
        XCTAssertEqual(tools[3]["name"] as? String, "search_codex_history")
        XCTAssertEqual(tools[4]["name"] as? String, "ask_codex")
        // Responses API function tools are flat — no nested "function" wrapper.
        XCTAssertNil(tools[1]["function"])
        XCTAssertEqual(tools[1]["type"] as? String, "function")
    }

    func testHistoryFlagGatesBothSearchAndAskTools() {
        let claudeOnly = AskAIToolDefinitions.tools(
            webSearch: false, claudeCodeHistory: true, codexHistory: false
        )
        XCTAssertEqual(
            claudeOnly.compactMap { $0["name"] as? String },
            ["search_claude_code_history", "ask_claude_code"]
        )
    }

    func testAskToolSchemaRequiresQuestion() throws {
        let tool = AskAIToolDefinitions.askCodexTool
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["question"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["question"])
        XCTAssertNotNil(properties["project_path"])
    }

    func testHistoryToolSchemaRequiresQuery() throws {
        let tool = AskAIToolDefinitions.claudeCodeHistoryTool
        let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["query"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertNotNil(properties["query"])
        XCTAssertNotNil(properties["limit"])
        XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
    }

    func testSystemPromptAddendumMentionsEnabledTools() {
        XCTAssertEqual(AskAIToolDefinitions.systemPromptAddendum(
            webSearch: false, claudeCodeHistory: false, codexHistory: false
        ), "")

        let webOnly = AskAIToolDefinitions.systemPromptAddendum(
            webSearch: true, claudeCodeHistory: false, codexHistory: false
        )
        XCTAssertTrue(webOnly.contains("web_search"))
        XCTAssertFalse(webOnly.contains("search_claude_code_history"))

        let historyOnly = AskAIToolDefinitions.systemPromptAddendum(
            webSearch: false, claudeCodeHistory: true, codexHistory: true
        )
        XCTAssertTrue(historyOnly.contains("search_claude_code_history"))
        XCTAssertTrue(historyOnly.contains("How did you do that?"))
    }

    func testExecutorDispatchesToHistoryService() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExecutorTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let claudeRoot = tempRoot.appendingPathComponent(".claude/projects/p")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try #"{"message":{"role":"assistant","content":"fixed the sparkle updater"}}"#
            .write(to: claudeRoot.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)

        let service = AgentHistorySearchService(
            claudeRoot: tempRoot.appendingPathComponent(".claude"),
            codexRoot: tempRoot.appendingPathComponent(".codex")
        )
        let output = AskAIToolExecutor.execute(
            name: "search_claude_code_history",
            argumentsJSON: #"{"query":"sparkle","limit":5}"#,
            historyService: service
        )
        XCTAssertTrue(output.contains("sparkle updater"))
    }

    func testExecutorRejectsUnknownToolAndMissingQuery() {
        let service = AgentHistorySearchService()
        XCTAssertTrue(AskAIToolExecutor.execute(
            name: "search_claude_code_history", argumentsJSON: "{}", historyService: service
        ).contains("missing required"))
        XCTAssertTrue(AskAIToolExecutor.execute(
            name: "bogus_tool", argumentsJSON: #"{"query":"x"}"#, historyService: service
        ).contains("unknown tool"))
    }

    func testActivitySummaryNamesTheSearch() {
        XCTAssertEqual(
            AskAIToolExecutor.activitySummary(
                name: "search_codex_history", argumentsJSON: #"{"query":"deploy"}"#
            ),
            "Searched Codex history for \"deploy\""
        )
        XCTAssertEqual(
            AskAIToolExecutor.activitySummary(
                name: "ask_claude_code", argumentsJSON: #"{"question":"how did you fix it?"}"#
            ),
            "Asked Claude Code: \"how did you fix it?\""
        )
    }

    func testStatusDetailPerTool() {
        XCTAssertEqual(AskAIToolExecutor.statusDetail(name: "ask_claude_code"), "Asking Claude Code…")
        XCTAssertEqual(AskAIToolExecutor.statusDetail(name: "ask_codex"), "Asking Codex…")
        XCTAssertEqual(AskAIToolExecutor.statusDetail(name: "search_codex_history"), "Searching agent history…")
    }

    func testExecutorAskToolRequiresQuestion() {
        let output = AskAIToolExecutor.execute(
            name: "ask_claude_code", argumentsJSON: "{}",
            historyService: AgentHistorySearchService()
        )
        XCTAssertTrue(output.contains("missing required"))
    }
}

// MARK: - AgentCLIBridge

final class AgentCLIBridgeTests: XCTestCase {

    func testClaudeArgumentsMatchPrescribedInvocation() {
        XCTAssertEqual(
            AgentCLIBridge.buildArguments(agent: .claude, question: "how did you do that?"),
            ["-p", "--continue", "--model", "opus", "--effort", "low", "how did you do that?"]
        )
    }

    func testCodexArgumentsResumeLastReadOnly() {
        XCTAssertEqual(
            AgentCLIBridge.buildArguments(agent: .codex, question: "q"),
            ["exec", "resume", "--last", "--sandbox", "read-only", "--skip-git-repo-check", "q"]
        )
    }

    func testQuestionIsPassedAsSingleArgumentNotShellParsed() {
        // The question goes through as one argv element, so shell metacharacters
        // are inert — no quoting or escaping is applied or needed.
        let args = AgentCLIBridge.buildArguments(agent: .claude, question: "a; rm -rf ~ && echo $HOME")
        XCTAssertEqual(args.last, "a; rm -rf ~ && echo $HOME")
    }

    func testAskWithNonexistentProjectPathReturnsError() {
        let bridge = AgentCLIBridge()
        // Only meaningful when a CLI is installed; without one the binary
        // error takes precedence, which is also an acceptable outcome.
        let output = bridge.ask(
            agent: .claude, question: "q", projectPath: "/nonexistent/path/\(UUID().uuidString)"
        )
        XCTAssertTrue(output.hasPrefix("Error:"))
    }
}

// MARK: - Thinking block rendering

final class AIAssistThinkingBlockTests: XCTestCase {

    func testThinkingBlockEscapesHTMLAndConvertsNewlines() {
        let block = AIAssistWindowController.thinkingBlock("a < b & c\nnext", open: true)
        XCTAssertTrue(block.contains("a &lt; b &amp; c<br>next"))
        XCTAssertTrue(block.hasPrefix("<details open>"))
        XCTAssertTrue(block.contains("<summary"))
    }

    func testThinkingBlockCollapsedWhenNotOpen() {
        let block = AIAssistWindowController.thinkingBlock("t", open: false)
        XCTAssertTrue(block.hasPrefix("<details>"))
    }
}
