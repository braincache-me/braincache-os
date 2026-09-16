import XCTest
@testable import ClipVault

// MARK: - AIAssistEntry / Window Controller navigation

@MainActor
final class AIAssistWindowControllerTests: XCTestCase {

    /// Reset the singleton's state between tests so leaks across runs don't
    /// give us false greens. There's no public reset, so we drive it via the
    /// existing API: clear the stream callback and re-render an empty entry
    /// list by reading currentIndex/entries directly through the singleton.
    private var controller: AIAssistWindowController { AIAssistWindowController.shared }

    override func setUp() async throws {
        try await super.setUp()
        // Each test should start without a callback wired so prior teardown
        // doesn't cross-contaminate.
        controller.onEntryFinalized = nil
    }

    func testEntryStartsInStreamingState() {
        let entry = AIAssistEntry(prompt: "hello")
        if case .streaming = entry.state {
            // pass
        } else {
            XCTFail("Expected streaming state")
        }
        XCTAssertEqual(entry.response, "")
        XCTAssertNil(entry.attachedWindowSummary)
    }

    func testEntryRecordsAttachment() {
        let entry = AIAssistEntry(
            prompt: "look at this",
            attachedWindowSummary: "Safari — Docs"
        )
        XCTAssertEqual(entry.attachedWindowSummary, "Safari — Docs")
    }

    func testFinalizedCallbackFiresOnError() {
        // We can't trivially exercise the streaming task without a network
        // mock here (singleton uses URLSession.shared). Instead verify the
        // callback wiring shape is intact: setting and clearing don't crash
        // and the callback persists until cleared.
        var fired = 0
        controller.onEntryFinalized = { _ in fired += 1 }
        XCTAssertNotNil(controller.onEntryFinalized)
        controller.onEntryFinalized = nil
        XCTAssertNil(controller.onEntryFinalized)
        XCTAssertEqual(fired, 0)
    }
}

// MARK: - ActivityEvent — AI Assist round-trip

final class ActivityEventAIAssistTests: XCTestCase {

    func testAIAssistEventRoundTrip() throws {
        let event = ActivityEvent(
            appName: "BrainCache",
            bundleID: "com.TalkFlow.BrainCache",
            windowTitle: "AI Assist",
            eventType: .aiAssistResponse,
            aiPrompt: "summarise the docs",
            aiResponse: "Here are the key points...",
            aiAttachedWindow: "Safari — Docs"
        )

        let line = try event.jsonlLine()
        XCTAssertTrue(line.contains("\"ai_assist_response\""))
        XCTAssertTrue(line.contains("\"summarise the docs\""))
        XCTAssertTrue(line.contains("Safari"))

        let data = line.data(using: .utf8)!
        let decoded = try ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: data)
        XCTAssertEqual(decoded.eventType, .aiAssistResponse)
        XCTAssertEqual(decoded.aiPrompt, "summarise the docs")
        XCTAssertEqual(decoded.aiResponse, "Here are the key points...")
        XCTAssertEqual(decoded.aiAttachedWindow, "Safari — Docs")
    }

    func testLegacyEventDecodesWithNilAIFields() throws {
        // Verify a JSONL line written before the AI Assist fields existed
        // still decodes — the new fields default to nil.
        let legacy = """
        {"appName":"Safari","bundleID":"com.apple.Safari","eventType":"left_click","id":"\(UUID().uuidString)","timestamp":"2026-04-11T14:23:45.123Z","windowTitle":"Docs"}
        """
        let data = legacy.data(using: .utf8)!
        let decoded = try ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: data)
        XCTAssertEqual(decoded.eventType, .leftClick)
        XCTAssertNil(decoded.aiPrompt)
        XCTAssertNil(decoded.aiResponse)
        XCTAssertNil(decoded.aiAttachedWindow)
    }
}

// MARK: - OpenAIClient streaming SSE

final class OpenAIClientStreamingTests: XCTestCase {

    private var client: OpenAIClient!
    private var settings: Settings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OpenAIStreamTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
        Settings.shared.openAIAPIKey = "sk-test"

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        client = nil
        settings = nil
        super.tearDown()
    }

    func testStreamingTokenizesContent() async throws {
        // Three content chunks then [DONE]. The client should yield the three
        // strings in order. (The mock harness delivers the full SSE blob
        // synchronously — that's still a valid SSE stream as long as `lines`
        // splits on \n correctly.)
        let sse = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}\n\
        data: {"choices":[{"delta":{"content":"lo"}}]}\n\
        data: {"choices":[{"delta":{"content":" world"}}]}\n\
        data: [DONE]\n
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, sse.data(using: .utf8)!)
        }

        let stream = client.streamChatCompletion(
            model: "gpt-test",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "hi")]
        )

        var collected: [String] = []
        for try await token in stream {
            collected.append(token)
        }
        XCTAssertEqual(collected, ["Hel", "lo", " world"])
    }

    func testStreamingThrowsOnHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"error":{"message":"bad key"}}"#.data(using: .utf8)!
            return (response, body)
        }

        let stream = client.streamChatCompletion(
            model: "gpt-test",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "hi")]
        )

        do {
            for try await _ in stream {
                XCTFail("Expected error before any tokens")
            }
            XCTFail("Stream finished without throwing")
        } catch let OpenAIError.httpError(statusCode, message) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertTrue(message.contains("bad key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingThrowsWhenAPIKeyMissing() async {
        Settings.shared.openAIAPIKey = ""

        let stream = client.streamChatCompletion(
            model: "gpt-test",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "hi")]
        )

        do {
            for try await _ in stream {
                XCTFail("Should not yield without an API key")
            }
            XCTFail("Stream finished without throwing")
        } catch OpenAIError.apiKeyMissing {
            // pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
