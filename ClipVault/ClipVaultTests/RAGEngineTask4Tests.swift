import XCTest
import GRDB
@testable import ClipVault

// MARK: - Settings.chatContextMessageLimit

final class ChatContextMessageLimitSettingsTests: XCTestCase {

    private var settings: Settings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.task4.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultChatContextMessageLimit() {
        XCTAssertEqual(settings.chatContextMessageLimit, 20)
    }

    func testSetChatContextMessageLimit() {
        settings.chatContextMessageLimit = 10
        XCTAssertEqual(settings.chatContextMessageLimit, 10)
    }

    func testChatContextMessageLimitPersists() {
        settings.chatContextMessageLimit = 5
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let settings2 = Settings(defaults: defaults2)
        XCTAssertEqual(settings2.chatContextMessageLimit, 5)
    }

    func testChatContextMessageLimitZero() {
        settings.chatContextMessageLimit = 0
        XCTAssertEqual(settings.chatContextMessageLimit, 0)
    }

    func testChatContextMessageLimitLargeValue() {
        settings.chatContextMessageLimit = 50
        XCTAssertEqual(settings.chatContextMessageLimit, 50)
    }
}

// MARK: - RAGEngine.buildMessages

final class RAGEngineBuildMessagesTests: XCTestCase {

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
        Settings.shared.openAIAPIKey = "sk-test-task4"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        Settings.shared.chatContextMessageLimit = 20
        engine         = nil
        embeddingStore = nil
        clipStore      = nil
        dbQueue        = nil
        super.tearDown()
    }

    // MARK: - No history

    func testBuildMessagesNoHistoryHasSystemAndUser() {
        let msgs = engine.buildMessages(question: "Test?", context: "ctx", conversationHistory: nil)
        XCTAssertEqual(msgs.count, 3, "system prompt + context block + user question")
        XCTAssertEqual(msgs[0].role, "system")
        XCTAssertEqual(msgs[1].role, "system")
        XCTAssertEqual(msgs[2].role, "user")
        XCTAssertEqual(msgs[2].content, "Test?")
    }

    func testBuildMessagesNoHistoryContextIsInSystemMessage() {
        let msgs = engine.buildMessages(question: "Q", context: "My context", conversationHistory: nil)
        XCTAssertTrue(msgs[1].content.contains("My context"))
        XCTAssertEqual(msgs[1].role, "system")
    }

    func testBuildMessagesNilHistorySameAsEmptyResult() {
        let withNil   = engine.buildMessages(question: "Q", context: "c", conversationHistory: nil)
        let withEmpty = engine.buildMessages(question: "Q", context: "c", conversationHistory: [])
        // Both should produce the same 3-message layout (system + context + question).
        XCTAssertEqual(withNil.count, withEmpty.count)
        XCTAssertEqual(withNil.last?.content, withEmpty.last?.content)
    }

    // MARK: - With history

    func testBuildMessagesWithHistoryPlacesHistoryBeforeQuestion() {
        let history = [
            OpenAIClient.ChatMessage(role: "user",      content: "Prior question"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Prior answer"),
        ]
        let msgs = engine.buildMessages(question: "New Q", context: "ctx", conversationHistory: history)
        // Expected: system, system, user(prior), assistant(prior), user(new)
        XCTAssertEqual(msgs.count, 5)
        XCTAssertEqual(msgs[2].role, "user")
        XCTAssertEqual(msgs[2].content, "Prior question")
        XCTAssertEqual(msgs[3].role, "assistant")
        XCTAssertEqual(msgs[3].content, "Prior answer")
        XCTAssertEqual(msgs[4].role, "user")
        XCTAssertEqual(msgs[4].content, "New Q")
    }

    func testBuildMessagesSystemPromptIsFirst() {
        let msgs = engine.buildMessages(question: "Q", context: "c", conversationHistory: nil)
        XCTAssertTrue(msgs[0].content.contains("BrainCache Assistant"))
    }

    // MARK: - History trimming

    func testBuildMessagesTrimsHistoryToLimit() {
        Settings.shared.chatContextMessageLimit = 3
        // Provide 6 history messages
        let history = (1...6).map { i in
            OpenAIClient.ChatMessage(role: i % 2 == 0 ? "assistant" : "user", content: "msg\(i)")
        }
        let msgs = engine.buildMessages(question: "Q", context: "c", conversationHistory: history)
        // Expected: system + context + 3 history + question = 6 total
        XCTAssertEqual(msgs.count, 6)
        // The last 3 history messages should be kept (msg4, msg5, msg6)
        XCTAssertEqual(msgs[2].content, "msg4")
        XCTAssertEqual(msgs[3].content, "msg5")
        XCTAssertEqual(msgs[4].content, "msg6")
        XCTAssertEqual(msgs[5].content, "Q")
    }

    func testBuildMessagesKeepsAllWhenHistoryBelowLimit() {
        Settings.shared.chatContextMessageLimit = 20
        let history = (1...5).map { i in
            OpenAIClient.ChatMessage(role: "user", content: "msg\(i)")
        }
        let msgs = engine.buildMessages(question: "Q", context: "c", conversationHistory: history)
        // system + context + 5 history + question = 8
        XCTAssertEqual(msgs.count, 8)
    }

    func testBuildMessagesLimitZeroDropsAllHistory() {
        Settings.shared.chatContextMessageLimit = 0
        let history = [OpenAIClient.ChatMessage(role: "user", content: "old")]
        let msgs = engine.buildMessages(question: "Q", context: "c", conversationHistory: history)
        // system + context + question = 3 (no history)
        XCTAssertEqual(msgs.count, 3)
    }

    // MARK: - Token overflow

    func testBuildMessagesReducesHistoryOnTokenOverflow() {
        Settings.shared.chatContextMessageLimit = 100

        // Create a history where each message is ~50K tokens (200K chars).
        // Two such messages would exceed safeTokenLimit (100K tokens).
        let bigContent = String(repeating: "A", count: 200_000) // ~50K tokens each
        let history = [
            OpenAIClient.ChatMessage(role: "user",      content: bigContent),
            OpenAIClient.ChatMessage(role: "assistant", content: bigContent),
            OpenAIClient.ChatMessage(role: "user",      content: bigContent),
        ]

        let msgs = engine.buildMessages(question: "Q", context: "small", conversationHistory: history)
        // With 3 × 50K = 150K tokens of history, token overflow should drop messages
        // from the front until we're under 100K tokens. The system prompt + context + question
        // is negligible; so all 3 history msgs (150K tokens) > 100K limit → trim until fits
        // or empty.
        let historyMsgsInResult = msgs.dropFirst(2).dropLast() // remove system × 2 and question
        // All 3 messages push over the limit; at minimum history should be reduced
        XCTAssertLessThan(historyMsgsInResult.count, 3, "Overflow should have reduced history count")
    }

    // MARK: - Full query integration (with mock)

    func testQueryWithNilHistorySucceeds() async throws {
        // Insert a clip and embedding so hybridSearch returns results
        let hash = Hashing.sha256(data: "hello".data(using: .utf8)!)
        var record = ClipRecord(
            id: nil, contentType: "text", textContent: "hello",
            dataHash: hash, mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 5,
            createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
        )
        let clipId = try clipStore.insertRecord(&record)
        let vec: [Float] = Array(repeating: 0.3, count: 256)
        try embeddingStore.insert(clipId: clipId, embedding: vec)

        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/embeddings") {
                let values = vec.map { String($0) }.joined(separator: ", ")
                let data = """
                {"object":"list","data":[{"object":"embedding","index":0,"embedding":[\(values)]}],
                 "model":"text-embedding-3-small","usage":{"prompt_tokens":1,"total_tokens":1}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            } else {
                let data = """
                {"id":"x","object":"chat.completion","choices":[{"index":0,
                 "message":{"role":"assistant","content":"Answer #\(clipId)"},
                 "finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            }
        }

        let result = try await engine.query("What did I copy?", conversationHistory: nil)
        XCTAssertFalse(result.answer.isEmpty)
    }

    func testQueryWithHistoryPassesHistoryMessages() async throws {
        // Insert clip + embedding
        let hash = Hashing.sha256(data: "world".data(using: .utf8)!)
        var record = ClipRecord(
            id: nil, contentType: "text", textContent: "world",
            dataHash: hash, mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 5,
            createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
        )
        let clipId = try clipStore.insertRecord(&record)
        let vec: [Float] = Array(repeating: 0.4, count: 256)
        try embeddingStore.insert(clipId: clipId, embedding: vec)

        // Capture the request body to verify history is included
        var capturedRequestBody: [String: Any]?

        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/embeddings") {
                let values = vec.map { String($0) }.joined(separator: ", ")
                let data = """
                {"object":"list","data":[{"object":"embedding","index":0,"embedding":[\(values)]}],
                 "model":"text-embedding-3-small","usage":{"prompt_tokens":1,"total_tokens":1}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            } else {
                // Chat completion — capture the body
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    capturedRequestBody = json
                }
                let data = """
                {"id":"x","object":"chat.completion","choices":[{"index":0,
                 "message":{"role":"assistant","content":"Follow-up answer"},
                 "finish_reason":"stop"}],"usage":{"prompt_tokens":20,"completion_tokens":5,"total_tokens":25}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            }
        }

        let history = [
            OpenAIClient.ChatMessage(role: "user",      content: "First question"),
            OpenAIClient.ChatMessage(role: "assistant", content: "First answer"),
        ]

        _ = try await engine.query("Follow-up question", conversationHistory: history)

        // Verify that the captured messages array includes the history content
        guard let captured = capturedRequestBody,
              let messages = captured["messages"] as? [[String: Any]] else {
            XCTFail("Failed to capture request body")
            return
        }
        let contents = messages.compactMap { $0["content"] as? String }
        XCTAssertTrue(contents.contains("First question"), "History question should appear in request")
        XCTAssertTrue(contents.contains("First answer"),   "History answer should appear in request")
        XCTAssertTrue(contents.contains("Follow-up question"), "Current question should appear in request")
    }
}

// MARK: - ChatPanelController history wiring

final class ChatPanelHistoryWiringTests: XCTestCase {

    private var store: ConversationStore!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ConversationStore(dbQueue: dbQueue)
    }

    func testHistoryFetchedBeforeCurrentMessage() throws {
        // Simulate the wiring: create a conversation, add two messages, then verify
        // that fetching before adding the third gives exactly those two messages.
        let conv = try store.createConversation(title: "Test")
        let cid = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: cid, role: "user",      content: "Q1")
        try store.appendMessage(conversationId: cid, role: "assistant", content: "A1")

        // This is what ChatPanelController does before adding the new user message:
        let records = try store.fetchMessages(conversationId: cid)
        let history = records.map { OpenAIClient.ChatMessage(role: $0.role, content: $0.content) }

        // Then we persist the new message:
        try store.appendMessage(conversationId: cid, role: "user", content: "Q2")

        // History should only contain Q1 + A1, not Q2
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].content, "Q1")
        XCTAssertEqual(history[1].content, "A1")
    }

    func testNextSendIncludesPriorMessages() throws {
        let conv = try store.createConversation(title: "Test")
        let cid = try XCTUnwrap(conv.id)

        // First turn
        try store.appendMessage(conversationId: cid, role: "user",      content: "First")
        try store.appendMessage(conversationId: cid, role: "assistant", content: "Answer 1")

        // Before second turn, fetch history
        let historyBeforeSecond = try store.fetchMessages(conversationId: cid)
        XCTAssertEqual(historyBeforeSecond.count, 2)

        // Second turn persisted
        try store.appendMessage(conversationId: cid, role: "user",      content: "Second")
        try store.appendMessage(conversationId: cid, role: "assistant", content: "Answer 2")

        // Before third turn, fetch history
        let historyBeforeThird = try store.fetchMessages(conversationId: cid)
        XCTAssertEqual(historyBeforeThird.count, 4)
        XCTAssertEqual(historyBeforeThird.map(\.content), ["First", "Answer 1", "Second", "Answer 2"])
    }

    func testEmptyConversationHistoryIsNil() throws {
        let conv = try store.createConversation(title: "New")
        let cid = try XCTUnwrap(conv.id)

        // No messages yet — simulate ChatPanelController history fetch
        let records = (try? store.fetchMessages(conversationId: cid)) ?? []
        let history: [OpenAIClient.ChatMessage]? = records.isEmpty ? nil :
            records.map { OpenAIClient.ChatMessage(role: $0.role, content: $0.content) }

        XCTAssertNil(history, "New conversation should produce nil history (no prior messages)")
    }
}
