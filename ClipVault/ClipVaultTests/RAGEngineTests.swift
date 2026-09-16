import XCTest
import GRDB
@testable import ClipVault

// MARK: - RAGEngineTests

final class RAGEngineTests: XCTestCase {

    private var dbQueue:        DatabaseQueue!
    private var clipStore:      ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var client:         OpenAIClient!
    private var engine:         RAGEngine!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue        = manager.dbQueue
        clipStore      = ClipStore(dbQueue: dbQueue)
        embeddingStore = EmbeddingStore(dbQueue: dbQueue)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session, initialRetryDelay: 100_000)

        let vectorEngine = VectorSearchEngine(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client
        )
        engine = RAGEngine(client: client, vectorEngine: vectorEngine, clipStore: clipStore)

        Settings.shared.openAIAPIKey = "sk-test-rag"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        engine         = nil
        embeddingStore = nil
        clipStore      = nil
        dbQueue        = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertClip(text: String,
                             tags: String? = nil,
                             sourceApp: String? = nil) throws -> Int64 {
        let hash = Hashing.sha256(data: text.data(using: .utf8)!)
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
            aiProcessedAt: nil
        )
        return try clipStore.insertRecord(&record)
    }

    private func makeEmbeddingResponse(vector: [Float]) -> Data {
        let values = vector.map { String($0) }.joined(separator: ", ")
        return """
        {
          "object": "list",
          "data": [{ "object": "embedding", "index": 0, "embedding": [\(values)] }],
          "model": "text-embedding-3-small",
          "usage": { "prompt_tokens": 5, "total_tokens": 5 }
        }
        """.data(using: .utf8)!
    }

    private func makeChatResponse(content: String) -> Data {
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        {
          "id": "chatcmpl-test",
          "object": "chat.completion",
          "choices": [{
            "index": 0,
            "message": { "role": "assistant", "content": "\(escaped)" },
            "finish_reason": "stop"
          }],
          "usage": { "prompt_tokens": 50, "completion_tokens": 20, "total_tokens": 70 }
        }
        """.data(using: .utf8)!
    }

    private func makeHTTPResponse(url: String = "https://api.openai.com/v1/embeddings",
                                   statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!,
                        statusCode: statusCode,
                        httpVersion: nil,
                        headerFields: nil)!
    }

    // MARK: - Citation Parsing

    func testParseCitationsExtractsSingleID() {
        let text = "Based on entry #42, the answer is yes."
        let ids = engine.parseCitations(from: text)
        XCTAssertEqual(ids, [42])
    }

    func testParseCitationsExtractsMultipleIDs() {
        let text = "See #1, #23, and #456 for details."
        let ids = engine.parseCitations(from: text)
        XCTAssertEqual(ids, [1, 23, 456])
    }

    func testParseCitationsDeduplicates() {
        let text = "Entries #5 and #5 say the same thing."
        let ids = engine.parseCitations(from: text)
        XCTAssertEqual(ids, [5])
    }

    func testParseCitationsReturnsEmptyWhenNoCitations() {
        let text = "There are no citation markers here."
        let ids = engine.parseCitations(from: text)
        XCTAssertTrue(ids.isEmpty)
    }

    func testParseCitationsIgnoresHashWithoutDigits() {
        let text = "This is a #hashtag but not an ID."
        // "#hashtag" starts with non-digit after #, so should be skipped.
        let ids = engine.parseCitations(from: text)
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Context Window Building

    func testBuildContextFormatsEntriesCorrectly() throws {
        _ = try insertClip(text: "Hello world", tags: "[\"code\"]", sourceApp: "com.apple.Xcode")
        let clip = try clipStore.fetchById(1) ?? {
            var r = ClipRecord(id: 1, contentType: "text", textContent: "Hello world",
                               dataHash: "x", mediaFileName: nil, fileURL: nil,
                               sourceApp: "com.apple.Xcode", byteSize: 11,
                               createdAt: 1000000, lastUsedAt: nil,
                               isPinned: false, isIndexed: true,
                               tags: "[\"code\"]", imageDescription: nil,
                               aiProcessed: 1, aiProcessedAt: nil)
            return r
        }()

        let context = engine.buildContext(clips: [clip])
        XCTAssertTrue(context.contains("Hello world"), "Context should include text content")
        XCTAssertTrue(context.contains("com.apple.Xcode"), "Context should include source app")
    }

    func testBuildContextRespectsSizeLimit() {
        // Create clips whose combined content would exceed the 24,000-char limit.
        let longText = String(repeating: "A", count: 6_000)
        var clips: [ClipRecord] = []
        for i in 1...5 {
            clips.append(ClipRecord(
                id: Int64(i), contentType: "text", textContent: longText,
                dataHash: "\(i)", mediaFileName: nil, fileURL: nil,
                sourceApp: nil, byteSize: longText.utf8.count,
                createdAt: Double(i) * 1000, lastUsedAt: nil,
                isPinned: false, isIndexed: true,
                tags: nil, imageDescription: nil,
                aiProcessed: 1, aiProcessedAt: nil
            ))
        }
        let context = engine.buildContext(clips: clips)
        XCTAssertLessThanOrEqual(context.count, RAGEngine.maxContextChars,
                                 "Context must not exceed maxContextChars")
    }

    func testBuildContextUsesImageDescriptionWhenNoTextContent() {
        let clip = ClipRecord(
            id: 99, contentType: "image", textContent: nil,
            dataHash: "hash", mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 1024,
            createdAt: 0, lastUsedAt: nil,
            isPinned: false, isIndexed: false,
            tags: nil, imageDescription: "A screenshot of Xcode",
            aiProcessed: 1, aiProcessedAt: nil
        )
        let context = engine.buildContext(clips: [clip])
        XCTAssertTrue(context.contains("A screenshot of Xcode"),
                      "Context should fall back to imageDescription")
    }

    func testBuildContextEmptyWhenNoClips() {
        let context = engine.buildContext(clips: [])
        XCTAssertTrue(context.isEmpty)
    }

    // MARK: - No Results Case

    func testQueryReturnsNoResultsMessageWhenEmbeddingsEmpty() async throws {
        // No embeddings stored → hybridSearch returns [] → RAGEngine returns fixed message.
        let queryVec: [Float] = Array(repeating: 0.1, count: 256)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let result = try await engine.query("What did I copy last week?")
        XCTAssertFalse(result.answer.isEmpty)
        XCTAssertTrue(result.citedClipIDs.isEmpty)
    }

    // MARK: - Full Query (with mock LLM)

    func testQueryReturnsCitedClipIDs() async throws {
        let id = try insertClip(text: "my-api-key-12345")
        let vec: [Float] = Array(repeating: 0.5, count: 256)
        try embeddingStore.insert(clipId: id, embedding: vec)

        var callCount = 0
        MockURLProtocol.requestHandler = { request in
            callCount += 1
            let url = request.url?.absoluteString ?? ""
            if url.contains("/embeddings") {
                return (self.makeHTTPResponse(url: url), self.makeEmbeddingResponse(vector: vec))
            } else {
                // Chat completion
                let content = "The API key was #\(id)."
                return (self.makeHTTPResponse(url: url), self.makeChatResponse(content: content))
            }
        }

        let result = try await engine.query("What was the API key I copied?")
        XCTAssertTrue(result.answer.contains("#\(id)"), "Answer should contain citation")
        XCTAssertTrue(result.citedClipIDs.contains(id), "Cited IDs should include the clip")
    }
}

// MARK: - ChatPanelControllerTests

final class ChatPanelControllerTests: XCTestCase {

    private var controller: ChatPanelController!

    override func setUp() {
        super.setUp()
        controller = ChatPanelController()
    }

    override func tearDown() {
        controller = nil
        super.tearDown()
    }

    // MARK: - Message Append Logic

    func testAppendMessageAddsToHistory() {
        XCTAssertEqual(controller.messages.count, 0)

        let msg = ChatMessage(role: .user, text: "Hello")
        controller.appendMessage(msg)

        XCTAssertEqual(controller.messages.count, 1)
        XCTAssertEqual(controller.messages[0].text, "Hello")
    }

    func testAppendMultipleMessagesPreservesOrder() {
        let msgs: [ChatMessage] = [
            ChatMessage(role: .user,      text: "Q1"),
            ChatMessage(role: .assistant, text: "A1", citedIDs: [1, 2]),
            ChatMessage(role: .user,      text: "Q2"),
        ]
        msgs.forEach { controller.appendMessage($0) }

        XCTAssertEqual(controller.messages.count, 3)
        XCTAssertEqual(controller.messages[0].role, .user)
        XCTAssertEqual(controller.messages[1].role, .assistant)
        XCTAssertEqual(controller.messages[1].citedIDs, [1, 2])
        XCTAssertEqual(controller.messages[2].text, "Q2")
    }

    func testConversationStateIsEmptyInitially() {
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testBottomScrollOriginYUsesZeroForNonFlippedDocumentView() {
        let originY = ChatPanelController.bottomScrollOriginY(
            documentBounds: NSRect(x: 0, y: 0, width: 320, height: 1200),
            visibleHeight: 400,
            isFlipped: false
        )

        XCTAssertEqual(originY, 0)
    }

    func testBottomScrollOriginYUsesMaxOffsetForFlippedDocumentView() {
        let originY = ChatPanelController.bottomScrollOriginY(
            documentBounds: NSRect(x: 0, y: 0, width: 320, height: 1200),
            visibleHeight: 400,
            isFlipped: true
        )

        XCTAssertEqual(originY, 800)
    }
}
