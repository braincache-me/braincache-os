import XCTest
@testable import ClipVault

// MARK: - ContentClassifier Tests

final class ContentClassifierTests: XCTestCase {

    private var classifier: ContentClassifier!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ContentClassifierTests-\(UUID().uuidString)"

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session, initialRetryDelay: 100_000)
        classifier = ContentClassifier(client: client)

        Settings.shared.openAIAPIKey = "sk-test-classifier"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        classifier = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClip(
        id: Int64 = 1,
        contentType: String = "text",
        textContent: String? = nil,
        imageDescription: String? = nil
    ) -> ClipRecord {
        ClipRecord(
            id: id,
            contentType: contentType,
            textContent: textContent,
            dataHash: "hash",
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: nil,
            byteSize: textContent?.count ?? 0,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: nil,
            imageDescription: imageDescription,
            aiProcessed: 0,
            aiProcessedAt: nil
        )
    }

    private func chatResponseJSON(tags: [String]) -> Data {
        let tagsJSON = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        let escaped = "{\\\"tags\\\": [\(tagsJSON)]}"
        // Embed as the content string in a chat response
        let json = """
        {
          "id": "chatcmpl-test",
          "choices": [
            {
              "message": { "role": "assistant", "content": "{\\"tags\\": [\(tags.map { "\\\"\($0)\\\"" }.joined(separator: ", "))]}" },
              "finish_reason": "stop"
            }
          ],
          "usage": { "prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15 }
        }
        """
        _ = escaped
        return json.data(using: .utf8)!
    }

    private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - Heuristic pre-tagging

    func testURLHeuristicTagsURL() {
        let tags = classifier.heuristicTags(for: "https://example.com/path", contentType: "text")
        XCTAssertEqual(tags, ["url"])
    }

    func testHTTPURLHeuristic() {
        let tags = classifier.heuristicTags(for: "http://foo.bar", contentType: "text")
        XCTAssertEqual(tags, ["url"])
    }

    func testFTPURLHeuristic() {
        let tags = classifier.heuristicTags(for: "ftp://files.example.com/file.zip", contentType: "text")
        XCTAssertEqual(tags, ["url"])
    }

    func testEmailHeuristicTagsEmail() {
        let tags = classifier.heuristicTags(for: "user@example.com", contentType: "text")
        XCTAssertEqual(tags, ["email-address"])
    }

    func testFilePathHeuristicAbsolute() {
        let tags = classifier.heuristicTags(for: "/Users/foo/Documents/file.txt", contentType: "text")
        XCTAssertEqual(tags, ["file-path"])
    }

    func testFilePathHeuristicTilde() {
        let tags = classifier.heuristicTags(for: "~/Documents/notes.txt", contentType: "text")
        XCTAssertEqual(tags, ["file-path"])
    }

    func testWindowsPathHeuristic() {
        let tags = classifier.heuristicTags(for: "C:\\Users\\foo\\file.txt", contentType: "text")
        XCTAssertEqual(tags, ["file-path"])
    }

    func testJSONHeuristic() {
        let tags = classifier.heuristicTags(for: "{\"key\": \"value\"}", contentType: "text")
        XCTAssertEqual(tags, ["json", "structured-data"])
    }

    func testJSONArrayHeuristic() {
        let tags = classifier.heuristicTags(for: "[1, 2, 3]", contentType: "text")
        XCTAssertEqual(tags, ["json", "structured-data"])
    }

    func testNoHeuristicForPlainText() {
        let tags = classifier.heuristicTags(for: "Hello, world! This is some regular text.", contentType: "text")
        XCTAssertTrue(tags.isEmpty)
    }

    func testEmptyTextHeuristic() {
        let tags = classifier.heuristicTags(for: "", contentType: "text")
        XCTAssertEqual(tags, ["trivial"])
    }

    func testWhitespaceOnlyHeuristic() {
        let tags = classifier.heuristicTags(for: "   \n  \t  ", contentType: "text")
        XCTAssertEqual(tags, ["trivial"])
    }

    // MARK: - Heuristic takes priority (no LLM call needed)

    func testURLClipUsesHeuristicWithoutLLMCall() async throws {
        var llmCallCount = 0
        MockURLProtocol.requestHandler = { _ in
            llmCallCount += 1
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["url"]))
        }

        let clip = makeClip(textContent: "https://github.com/openai")
        let tags = try await classifier.classify(clip: clip)
        XCTAssertEqual(tags, ["url"])
        XCTAssertEqual(llmCallCount, 0, "URL heuristic should not trigger an LLM call")
    }

    // MARK: - Empty / image-only clips

    func testEmptyTextAndNoDescriptionReturnsEmpty() async throws {
        let clip = makeClip(contentType: "image", textContent: nil, imageDescription: nil)
        let tags = try await classifier.classify(clip: clip)
        XCTAssertTrue(tags.isEmpty, "Image-only clips with no description should return empty tags")
    }

    func testImageClipWithDescriptionClassifiesDescription() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let userMsg = messages.last!["content"] as! String
            XCTAssertTrue(userMsg.contains("A bar chart showing revenue"))
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["screenshot", "chart"]))
        }

        let clip = makeClip(
            contentType: "image",
            textContent: nil,
            imageDescription: "A bar chart showing revenue over 12 months"
        )
        let tags = try await classifier.classify(clip: clip)
        XCTAssertEqual(tags, ["screenshot", "chart"])
    }

    // MARK: - Prompt construction

    func testPromptContainsTaxonomyInSystem() {
        let prompt = classifier.buildSystemPrompt()
        XCTAssertTrue(prompt.contains("code:swift"))
        XCTAssertTrue(prompt.contains("api-key"))
        XCTAssertTrue(prompt.contains("stack-trace"))
        XCTAssertTrue(prompt.contains("trivial"))
    }

    func testShortTextPromptIncludesRawText() {
        let prompt = classifier.buildUserPrompt(text: "hello", contentType: "text", isShort: true)
        XCTAssertTrue(prompt.contains("\"hello\""))
        XCTAssertTrue(prompt.contains("very short"))
    }

    func testLongTextPromptDoesNotQuote() {
        let longText = String(repeating: "a", count: 50)
        let prompt = classifier.buildUserPrompt(text: longText, contentType: "text", isShort: false)
        XCTAssertFalse(prompt.contains("very short"))
    }

    func testPromptContainsContentType() {
        let prompt = classifier.buildUserPrompt(text: "print('hello')", contentType: "text", isShort: false)
        XCTAssertTrue(prompt.contains("Content type: text"))
    }

    // MARK: - LLM call and JSON parsing

    func testClassifyCallsLLMWithCorrectModelAndNoTemperature() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-5.4-nano")
            XCTAssertNil(body["temperature"],
                         "ContentClassifier must not send temperature — reasoning models reject it")
            let format = body["response_format"] as! [String: String]
            XCTAssertEqual(format["type"], "json_object")
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["prose"]))
        }

        let clip = makeClip(textContent: "This is a longer piece of regular prose content for testing.")
        _ = try await classifier.classify(clip: clip)
    }

    func testClassifyReturnsValidatedTags() async throws {
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["code", "code:swift", "tech"]))
        }

        let clip = makeClip(textContent: "func greet() { print(\"Hello, World!\") }")
        let tags = try await classifier.classify(clip: clip)
        XCTAssertEqual(tags, ["code", "code:swift", "tech"])
    }

    func testUnknownTagsAreDiscarded() async throws {
        // LLM returns a mix of known and unknown tags
        let json = """
        {
          "id": "test",
          "choices": [{
            "message": {"role": "assistant", "content": "{\\"tags\\": [\\"code\\", \\"fake-tag\\", \\"prose\\", \\"not-real\\"]}"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in (self.makeHTTPResponse(), json) }

        let clip = makeClip(textContent: "Some code content to classify here.")
        let tags = try await classifier.classify(clip: clip)
        XCTAssertFalse(tags.contains("fake-tag"))
        XCTAssertFalse(tags.contains("not-real"))
        XCTAssertTrue(tags.contains("code"))
        XCTAssertTrue(tags.contains("prose"))
    }

    func testMaxEightTagsEnforced() async throws {
        let manyTags = ["code", "code:swift", "tech", "work", "important",
                        "prose", "key-information", "actionable", "reference-material"]
        XCTAssertGreaterThan(manyTags.count, ContentClassifier.maxTags)

        let json = """
        {
          "id": "test",
          "choices": [{
            "message": {"role": "assistant", "content": "{\\"tags\\": [\\"code\\", \\"code:swift\\", \\"tech\\", \\"work\\", \\"important\\", \\"prose\\", \\"key-information\\", \\"actionable\\", \\"reference-material\\"]}"},
            "finish_reason": "stop"
          }],
          "usage": {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { _ in (self.makeHTTPResponse(), json) }

        let clip = makeClip(textContent: "func example() { /* lots of code */ }")
        let tags = try await classifier.classify(clip: clip)
        XCTAssertLessThanOrEqual(tags.count, ContentClassifier.maxTags)
    }

    // MARK: - Truncation

    func testTruncateKeepsShortStrings() {
        let text = "Hello"
        let result = classifier.truncate(text, to: 2_000)
        XCTAssertEqual(result, "Hello")
    }

    func testTruncateCutsLongStrings() {
        let text = String(repeating: "a", count: 3_000)
        let result = classifier.truncate(text, to: 2_000)
        XCTAssertTrue(result.hasSuffix("…[truncated]"))
        XCTAssertLessThan(result.count, 3_000)
    }

    func testLongTextIsTruncatedInPrompt() async throws {
        let longText = String(repeating: "x", count: 5_000)

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let userMsg = messages.last!["content"] as! String
            XCTAssertTrue(userMsg.contains("…[truncated]"))
            XCTAssertLessThan(userMsg.count, 3_000)
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["prose"]))
        }

        let clip = makeClip(textContent: longText)
        _ = try await classifier.classify(clip: clip)
    }

    // MARK: - parseTags edge cases

    func testParseTagsWithValidJSON() throws {
        let json = "{\"tags\": [\"code\", \"tech\"]}"
        let tags = try classifier.parseTags(from: json)
        XCTAssertEqual(tags, ["code", "tech"])
    }

    func testParseTagsWithInvalidJSONReturnsTrivial() throws {
        let tags = try classifier.parseTags(from: "not valid json")
        XCTAssertEqual(tags, ["trivial"])
    }

    func testParseTagsMissingTagsKeyReturnsTrivial() throws {
        let tags = try classifier.parseTags(from: "{\"result\": []}")
        XCTAssertEqual(tags, ["trivial"])
    }

    func testParseTagsFiltersUnknown() throws {
        let json = "{\"tags\": [\"code\", \"made-up-tag\", \"prose\"]}"
        let tags = try classifier.parseTags(from: json)
        XCTAssertEqual(Set(tags), Set(["code", "prose"]))
    }

    // MARK: - Short text edge case

    func testShortTextUnder10CharsUsesShortPrompt() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let userMsg = messages.last!["content"] as! String
            XCTAssertTrue(userMsg.contains("very short"))
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["trivial"]))
        }

        let clip = makeClip(textContent: "abc")
        _ = try await classifier.classify(clip: clip)
    }
}
