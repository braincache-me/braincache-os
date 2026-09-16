import XCTest
@testable import ClipVault

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        // URLSession moves httpBody to httpBodyStream; restore it for convenience.
        var hydratedRequest = request
        if hydratedRequest.httpBody == nil, let stream = hydratedRequest.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: bufferSize)
                if bytesRead > 0 {
                    data.append(buffer, count: bytesRead)
                }
            }
            stream.close()
            hydratedRequest.httpBody = data
        }
        do {
            let (response, data) = try handler(hydratedRequest)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test Suite

final class OpenAIClientTests: XCTestCase {

    private var client: OpenAIClient!
    private var settings: Settings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OpenAIClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        client = OpenAIClient(session: session)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        MockURLProtocol.requestHandler = nil
        client = nil
        settings = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func chatResponseJSON(content: String) -> Data {
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

    private func embeddingResponseJSON(values: [Float]) -> Data {
        let nums = values.map { String($0) }.joined(separator: ",")
        let json = """
        {
          "data": [{ "embedding": [\(nums)], "index": 0 }],
          "usage": { "prompt_tokens": 8, "total_tokens": 8 }
        }
        """
        return json.data(using: .utf8)!
    }

    // MARK: - API key missing guard

    func testChatCompletionThrowsWhenNoKey() async throws {
        // settings has empty key by default; OpenAIClient.shared reads Settings.shared,
        // but our client under test is initialised separately.
        // We need to ensure Settings.shared has no key — override it temporarily.
        let originalKey = Settings.shared.openAIAPIKey
        Settings.shared.openAIAPIKey = ""
        defer { Settings.shared.openAIAPIKey = originalKey }

        do {
            _ = try await client.chatCompletion(model: "gpt-5.4-nano", messages: [])
            XCTFail("Expected apiKeyMissing error")
        } catch OpenAIError.apiKeyMissing {
            // expected
        }
    }

    func testCreateEmbeddingThrowsWhenNoKey() async throws {
        let originalKey = Settings.shared.openAIAPIKey
        Settings.shared.openAIAPIKey = ""
        defer { Settings.shared.openAIAPIKey = originalKey }

        do {
            _ = try await client.createEmbedding(model: "text-embedding-3-small", input: "hello")
            XCTFail("Expected apiKeyMissing error")
        } catch OpenAIError.apiKeyMissing {
            // expected
        }
    }

    // MARK: - Request headers

    func testChatCompletionSendsAuthorizationHeader() async throws {
        let testKey = "sk-test-key-12345"
        Settings.shared.openAIAPIKey = testKey

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(testKey)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "Hello"))
        }

        _ = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "Hi")]
        )
        Settings.shared.openAIAPIKey = ""
    }

    // MARK: - Request body structure

    func testChatCompletionBodyContainsModelAndMessages() async throws {
        Settings.shared.openAIAPIKey = "sk-test"

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "gpt-5.4-nano")
            let messages = body["messages"] as! [[String: String]]
            XCTAssertEqual(messages.first?["role"], "user")
            XCTAssertEqual(messages.first?["content"], "Test message")
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "ok"))
        }

        _ = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "Test message")]
        )
        Settings.shared.openAIAPIKey = ""
    }

    func testEmbeddingBodyContainsModelInputAndDimensions() async throws {
        Settings.shared.openAIAPIKey = "sk-test"

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "text-embedding-3-small")
            XCTAssertEqual(body["input"] as? String, "embed this")
            XCTAssertEqual(body["dimensions"] as? Int, 256)
            return (self.makeHTTPResponse(statusCode: 200), self.embeddingResponseJSON(values: [0.1, 0.2]))
        }

        _ = try await client.createEmbedding(
            model: "text-embedding-3-small",
            input: "embed this",
            dimensions: 256
        )
        Settings.shared.openAIAPIKey = ""
    }

    // MARK: - Response decoding

    func testChatCompletionDecodesContent() async throws {
        Settings.shared.openAIAPIKey = "sk-test"

        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "decoded content"))
        }

        let response = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: []
        )
        XCTAssertEqual(response.choices.first?.message.content, "decoded content")
        Settings.shared.openAIAPIKey = ""
    }

    func testEmbeddingDecodesVector() async throws {
        Settings.shared.openAIAPIKey = "sk-test"

        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(statusCode: 200), self.embeddingResponseJSON(values: [0.5, -0.3, 0.8]))
        }

        let response = try await client.createEmbedding(
            model: "text-embedding-3-small",
            input: "hello"
        )
        XCTAssertEqual(response.data.first?.embedding.count, 3)
        XCTAssertEqual(response.data.first?.embedding[0] ?? 0, 0.5, accuracy: 0.001)
        Settings.shared.openAIAPIKey = ""
    }

    // MARK: - Error handling

    func testNon429ErrorIsNotRetried() async throws {
        Settings.shared.openAIAPIKey = "sk-test"
        var callCount = 0

        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            let errorJSON = #"{"error":{"message":"Not found","type":"invalid_request_error"}}"#.data(using: .utf8)!
            return (self.makeHTTPResponse(statusCode: 404), errorJSON)
        }

        do {
            _ = try await client.chatCompletion(model: "gpt-5.4-nano", messages: [])
            XCTFail("Expected error")
        } catch OpenAIError.httpError(let code, _) {
            XCTAssertEqual(code, 404)
        }
        // Should only make 1 call — no retry on 404
        XCTAssertEqual(callCount, 1)
        Settings.shared.openAIAPIKey = ""
    }

    func test429TriggerRetries() async throws {
        Settings.shared.openAIAPIKey = "sk-test"
        var callCount = 0

        // First 2 calls return 429, third returns 200
        MockURLProtocol.requestHandler = { [weak self] _ in
            guard let self else { fatalError() }
            callCount += 1
            if callCount < 3 {
                let errorJSON = #"{"error":{"message":"Rate limited"}}"#.data(using: .utf8)!
                return (self.makeHTTPResponse(statusCode: 429), errorJSON)
            }
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "ok"))
        }

        // Use a client with near-zero retry delay to keep the test fast (0.1 ms)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let fastSession = URLSession(configuration: config)
        let fastClient = OpenAIClient(session: fastSession, initialRetryDelay: 100_000)

        let response = try await fastClient.chatCompletion(
            model: "gpt-5.4-nano",
            messages: []
        )
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(response.choices.first?.message.content, "ok")
        Settings.shared.openAIAPIKey = ""
    }

    func test5xxTriggerRetries() async throws {
        Settings.shared.openAIAPIKey = "sk-test"
        var callCount = 0

        MockURLProtocol.requestHandler = { [weak self] _ in
            guard let self else { fatalError() }
            callCount += 1
            if callCount < 2 {
                return (self.makeHTTPResponse(statusCode: 500), Data())
            }
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "ok"))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let fastSession = URLSession(configuration: config)
        let fastClient = OpenAIClient(session: fastSession, initialRetryDelay: 100_000)

        let response = try await fastClient.chatCompletion(model: "gpt-5.4-nano", messages: [])
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(response.choices.first?.message.content, "ok")
        Settings.shared.openAIAPIKey = ""
    }

    // MARK: - JSON response format

    func testChatCompletionSendsJsonResponseFormat() async throws {
        Settings.shared.openAIAPIKey = "sk-test"

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let format = body["response_format"] as! [String: String]
            XCTAssertEqual(format["type"], "json_object")
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "{}"))
        }

        _ = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: [],
            responseFormat: .json
        )
        Settings.shared.openAIAPIKey = ""
    }

    // MARK: - Vision request

    func testVisionRequestIncludesBase64Image() async throws {
        Settings.shared.openAIAPIKey = "sk-test"
        let imageData = Data([0xFF, 0xFE, 0x00, 0x01])

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let lastMessage = messages.last!
            let content = lastMessage["content"] as! [[String: Any]]
            let imageBlock = content.first!
            XCTAssertEqual(imageBlock["type"] as? String, "image_url")
            let imageURL = (imageBlock["image_url"] as! [String: String])["url"]!
            XCTAssert(imageURL.hasPrefix("data:image/png;base64,"))
            let expected = imageData.base64EncodedString()
            XCTAssert(imageURL.hasSuffix(expected))
            XCTAssertNil(body["max_tokens"], "Vision requests should use max_completion_tokens for current chat models")
            XCTAssertEqual(body["max_completion_tokens"] as? Int, 123)
            return (self.makeHTTPResponse(statusCode: 200), self.chatResponseJSON(content: "described"))
        }

        _ = try await client.chatCompletionWithVision(
            model: "gpt-5.4-mini",
            messages: [OpenAIClient.ChatMessage(role: "system", content: "Describe")],
            imageData: imageData,
            detail: "low",
            maxOutputTokens: 123
        )
        Settings.shared.openAIAPIKey = ""
    }
}

// MARK: - Settings AI key tests

final class SettingsAITests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsAITests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        super.tearDown()
    }

    func testDefaultOpenAIAPIKeyIsEmpty() {
        XCTAssertEqual(settings.openAIAPIKey, "")
    }

    func testIsAIEnabledFalseByDefault() {
        XCTAssertFalse(settings.isAIEnabled)
    }

    func testIsAIEnabledTrueWhenKeySet() {
        settings.openAIAPIKey = "sk-test-key"
        XCTAssertTrue(settings.isAIEnabled)
    }

    func testIsAIEnabledFalseWhenKeyCleared() {
        settings.openAIAPIKey = "sk-test-key"
        settings.openAIAPIKey = ""
        XCTAssertFalse(settings.isAIEnabled)
    }

    func testOpenAIAPIKeyReadWrite() {
        settings.openAIAPIKey = "sk-abc-123"
        XCTAssertEqual(settings.openAIAPIKey, "sk-abc-123")
    }

    func testOpenAIAPIKeyPersistedInDefaults() {
        settings.openAIAPIKey = "sk-persisted"
        let sameDefaults = UserDefaults(suiteName: suiteName)!
        let settings2 = Settings(defaults: sameDefaults)
        XCTAssertEqual(settings2.openAIAPIKey, "sk-persisted")
    }
}
