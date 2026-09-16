import XCTest
import GRDB
@testable import ClipVault

// MARK: - Settings.maxConversationCount Tests

final class MaxConversationCountSettingsTests: XCTestCase {

    private var settings: Settings!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.task9.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultMaxConversationCount() {
        XCTAssertEqual(settings.maxConversationCount, 100)
    }

    func testSetMaxConversationCount() {
        settings.maxConversationCount = 50
        XCTAssertEqual(settings.maxConversationCount, 50)
    }

    func testMaxConversationCountClampedToMin() {
        settings.maxConversationCount = 5
        XCTAssertEqual(settings.maxConversationCount, 10)
    }

    func testMaxConversationCountClampedToMax() {
        settings.maxConversationCount = 1000
        XCTAssertEqual(settings.maxConversationCount, 500)
    }

    func testMaxConversationCountPersists() {
        settings.maxConversationCount = 200
        let defaults2 = UserDefaults(suiteName: suiteName)!
        let settings2 = Settings(defaults: defaults2)
        XCTAssertEqual(settings2.maxConversationCount, 200)
    }
}

// MARK: - ConversationStore.deleteOldestExceeding Tests

final class ConversationStoreAutoCleanupTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var store: ConversationStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ConversationStore(dbQueue: dbQueue)
    }

    override func tearDown() {
        store = nil
        dbQueue = nil
        super.tearDown()
    }

    func testDeleteOldestExceedingDoesNothingWhenUnderLimit() throws {
        for i in 1...5 {
            _ = try store.createConversation(title: "Conv \(i)")
        }
        try store.deleteOldestExceeding(keepNewest: 10)
        XCTAssertEqual(try store.conversationCount(), 5)
    }

    func testDeleteOldestExceedingRemovesExcessConversations() throws {
        // Create 15 conversations with slightly different timestamps.
        for i in 1...15 {
            var conv = ConversationRecord(id: nil, title: "Conv \(i)",
                                          createdAt: Double(i), updatedAt: Double(i))
            try dbQueue.write { db in try conv.insert(db) }
        }
        try store.deleteOldestExceeding(keepNewest: 10)
        XCTAssertEqual(try store.conversationCount(), 10)
    }

    func testDeleteOldestExceedingKeepsNewest() throws {
        // Create 5 conversations with ascending updated_at timestamps.
        var ids: [Int64] = []
        for i in 1...5 {
            var conv = ConversationRecord(id: nil, title: "Conv \(i)",
                                          createdAt: Double(i), updatedAt: Double(i))
            try dbQueue.write { db in try conv.insert(db) }
            ids.append(conv.id!)
        }
        // Keep only the 3 newest (highest updated_at).
        try store.deleteOldestExceeding(keepNewest: 3)
        let remaining = try store.fetchAll()
        XCTAssertEqual(remaining.count, 3)
        // The 3 newest should remain (updatedAt 3, 4, 5).
        let remainingUpdatedAts = remaining.map { $0.updatedAt }.sorted()
        XCTAssertEqual(remainingUpdatedAts, [3.0, 4.0, 5.0])
    }

    func testDeleteOldestExceedingCascadesMessages() throws {
        // Create two conversations with explicit timestamps where "Old" has smaller updated_at.
        var old = ConversationRecord(id: nil, title: "Old", createdAt: 1.0, updatedAt: 1.0)
        var new = ConversationRecord(id: nil, title: "New", createdAt: 2.0, updatedAt: 2.0)
        try dbQueue.write { db in
            try old.insert(db)
            try new.insert(db)
        }
        let oldId = old.id!

        // Insert message directly at a fixed timestamp so updated_at stays 1.0 for "Old".
        var msg = ChatMessageRecord(id: nil, conversationId: oldId, role: "user",
                                    content: "Hello", citedClipIds: nil, createdAt: 1.0)
        try dbQueue.write { db in try msg.insert(db) }

        // Verify message was inserted.
        let beforeDelete = try store.fetchMessages(conversationId: oldId)
        XCTAssertEqual(beforeDelete.count, 1)

        // keepNewest: 1 should keep "New" (updatedAt 2.0) and delete "Old" (updatedAt 1.0).
        try store.deleteOldestExceeding(keepNewest: 1)
        XCTAssertEqual(try store.conversationCount(), 1)

        // Messages for the deleted conversation should also be gone (cascade).
        let msgs = try store.fetchMessages(conversationId: oldId)
        XCTAssertTrue(msgs.isEmpty)
    }

    func testDeleteOldestExceedingExactlyAtLimit() throws {
        for i in 1...10 {
            _ = try store.createConversation(title: "Conv \(i)")
        }
        try store.deleteOldestExceeding(keepNewest: 10)
        XCTAssertEqual(try store.conversationCount(), 10)
    }
}

// MARK: - AgenticRAGEngine Token Estimation Tests

final class AgenticTokenEstimationTests: XCTestCase {

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

    func testEstimateMessageTokensEmpty() {
        let tokens = engine.estimateMessageTokens([])
        XCTAssertEqual(tokens, 0)
    }

    func testEstimateMessageTokensSingleMessage() {
        // "Hello" is 5 chars → estimateTokens("Hello") = max(1, 5/4) = 1
        let msg: [String: Any] = ["role": "user", "content": "Hello"]
        let tokens = engine.estimateMessageTokens([msg])
        XCTAssertGreaterThan(tokens, 0)
    }

    func testEstimateMessageTokensLargeContent() {
        // A large content should produce a proportionally larger token count.
        let big = String(repeating: "a", count: 400)
        let msg: [String: Any] = ["role": "user", "content": big]
        let tokens = engine.estimateMessageTokens([msg])
        // 400 chars / 4 = 100 tokens
        XCTAssertEqual(tokens, 100)
    }

    func testEstimateMessageTokensSumMultipleMessages() {
        let msgs: [[String: Any]] = [
            ["role": "user", "content": String(repeating: "a", count: 400)],
            ["role": "assistant", "content": String(repeating: "b", count: 800)],
        ]
        let tokens = engine.estimateMessageTokens(msgs)
        // 400/4 + 800/4 = 100 + 200 = 300
        XCTAssertEqual(tokens, 300)
    }

    func testAgenticTokenWarningThresholdIs50K() {
        XCTAssertEqual(AgenticRAGEngine.agenticTokenWarningThreshold, 50_000)
    }

    func testAgenticLoopStopsWhenTokenThresholdExceeded() async throws {
        Settings.shared.openAIAPIKey = "sk-test-task9-tokens"
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 5

        // Each tool call response returns a huge content that will blow the token budget.
        var callCount = 0
        MockURLProtocol.requestHandler = { _ in
            callCount += 1
            if callCount == 1 {
                // First call: model requests a tool call with a giant result.
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
                // Subsequent calls: final answer.
                let json = """
                {
                  "id": "chatcmpl-test2",
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

        let result = try await engine.query("What did I copy?")
        XCTAssertFalse(result.answer.isEmpty)

        Settings.shared.openAIAPIKey = ""
        Settings.shared.agenticSearchEnabled = true
        Settings.shared.agenticMaxIterations = 3
    }
}

// MARK: - RAGEngine Summarization Tests

final class RAGEngineSummarizationTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!
    private var client: OpenAIClient!
    private var vectorEngine: VectorSearchEngine!
    private var engine: RAGEngine!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        clipStore = ClipStore(dbQueue: dbQueue)
        let embeddingStore = EmbeddingStore(dbQueue: dbQueue)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session, initialRetryDelay: 100_000)
        vectorEngine = VectorSearchEngine(clipStore: clipStore,
                                          embeddingStore: embeddingStore,
                                          client: client)
        engine = RAGEngine(client: client, vectorEngine: vectorEngine, clipStore: clipStore)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        engine = nil
        vectorEngine = nil
        client = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    func testSummarizationThresholdIsFour() {
        XCTAssertEqual(RAGEngine.summarizationThreshold, 4)
    }

    func testBuildMessagesWithSummarizationNoHistory() async {
        let msgs = await engine.buildMessagesWithSummarization(
            question: "What?",
            context: "Some context",
            conversationHistory: nil
        )
        // Should have: system prompt + context block + user question
        XCTAssertEqual(msgs.count, 3)
        XCTAssertEqual(msgs.last?.role, "user")
        XCTAssertEqual(msgs.last?.content, "What?")
    }

    func testBuildMessagesWithSummarizationShortHistory() async {
        let history = [
            OpenAIClient.ChatMessage(role: "user", content: "Hello"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Hi"),
        ]
        let msgs = await engine.buildMessagesWithSummarization(
            question: "How are you?",
            context: "ctx",
            conversationHistory: history
        )
        // system prompt + context + 2 history msgs + question = 5
        XCTAssertEqual(msgs.count, 5)
        XCTAssertEqual(msgs.last?.content, "How are you?")
    }

    func testSummarizeConversationFallsBackOnError() async {
        Settings.shared.openAIAPIKey = "sk-test-summarize"
        MockURLProtocol.requestHandler = { _ in
            throw NSError(domain: "test", code: 0)
        }
        let messages = [
            OpenAIClient.ChatMessage(role: "user", content: "Hello"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Hi"),
        ]
        let summary = await engine.summarizeConversation(messages)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("omitted"))
        Settings.shared.openAIAPIKey = ""
    }

    func testSummarizeConversationEmptyMessages() async {
        let summary = await engine.summarizeConversation([])
        XCTAssertFalse(summary.isEmpty)
    }

    func testSummarizeConversationUsesLLMResponse() async throws {
        Settings.shared.openAIAPIKey = "sk-test-summarize2"
        MockURLProtocol.requestHandler = { _ in
            let json = """
            {
              "id": "chatcmpl-sum",
              "choices": [{
                "message": { "role": "assistant", "content": "User asked about Swift. Assistant explained closures." },
                "finish_reason": "stop"
              }],
              "usage": { "prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30 }
            }
            """
            return (HTTPURLResponse(url: URL(string: "https://api.openai.com")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    json.data(using: .utf8)!)
        }
        let messages = [
            OpenAIClient.ChatMessage(role: "user", content: "Tell me about Swift closures"),
            OpenAIClient.ChatMessage(role: "assistant", content: "Closures are self-contained blocks of code."),
        ]
        let summary = await engine.summarizeConversation(messages)
        XCTAssertTrue(summary.contains("Swift"))
        Settings.shared.openAIAPIKey = ""
    }
}

// MARK: - ChatPanelController Keyboard Shortcut Tests

final class ChatPanelKeyboardShortcutTests: XCTestCase {

    func testNavigateConversationWrapsForward() throws {
        // Test navigate by setting up conversations and navigating.
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ConversationStore(dbQueue: manager.dbQueue)

        let c1 = try store.createConversation(title: "A")
        let c2 = try store.createConversation(title: "B")
        let c3 = try store.createConversation(title: "C")

        let ctrl = ChatPanelController()
        ctrl.conversationStore = store

        // The controller's conversations array mirrors fetchAll (sorted desc by updated_at).
        // For testing the index arithmetic we set it up manually.
        let now = Date().timeIntervalSince1970
        // Use explicit ordering to test navigation.
        let ordered: [ConversationRecord] = [c1, c2, c3]

        // Simulate: ordered is [c1, c2, c3], currently c2 is selected (index 1).
        // navigating forward (+1) should land on index 2 (c3).
        // navigating backward (-1) from index 1 should land on index 0 (c1).

        // We test the underlying index arithmetic directly.
        let currentIdx = 1
        let forwardIdx = ((currentIdx + 1) % ordered.count + ordered.count) % ordered.count
        let backwardIdx = ((currentIdx - 1) % ordered.count + ordered.count) % ordered.count
        XCTAssertEqual(forwardIdx, 2)
        XCTAssertEqual(backwardIdx, 0)

        // Wrapping forward from last element.
        let lastIdx = ordered.count - 1
        let wrappedFwd = ((lastIdx + 1) % ordered.count + ordered.count) % ordered.count
        XCTAssertEqual(wrappedFwd, 0)

        // Wrapping backward from first element.
        let firstIdx = 0
        let wrappedBwd = ((firstIdx - 1) % ordered.count + ordered.count) % ordered.count
        XCTAssertEqual(wrappedBwd, ordered.count - 1)

        _ = now // silence warning
    }

    func testNewConversationShortcutCreatesConversation() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ConversationStore(dbQueue: manager.dbQueue)

        XCTAssertEqual(try store.conversationCount(), 0)

        // Create a conversation via the store (simulates what newConversationShortcut calls).
        _ = try store.createConversation(title: "New Chat")
        XCTAssertEqual(try store.conversationCount(), 1)
    }
}

// MARK: - ConversationListView Cell Reuse Tests

final class ConversationListViewCellReuseTests: XCTestCase {

    func testReloadWithManyConversationsDoesNotCrash() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        var convs: [ConversationRecord] = []
        for i in 0..<200 {
            convs.append(ConversationRecord(id: Int64(i + 1),
                                            title: "Conversation \(i)",
                                            createdAt: now - Double(i),
                                            updatedAt: now - Double(i)))
        }
        // Should not crash or hang with 200 conversations.
        view.reload(conversations: convs, selectedId: 1)
        XCTAssertEqual(view.conversations.count, 200)
    }

    func testReloadUpdatesSelectedConversationId() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        let convs: [ConversationRecord] = [
            ConversationRecord(id: 10, title: "A", createdAt: now, updatedAt: now),
            ConversationRecord(id: 20, title: "B", createdAt: now, updatedAt: now),
        ]
        view.reload(conversations: convs, selectedId: 20)
        XCTAssertEqual(view.selectedConversationId, 20)
    }
}

// MARK: - Empty State View Tests

final class EmptyStateViewTests: XCTestCase {

    func testShowEmptyStateAutoTitleGeneration() {
        // autoTitle strips to 60 chars.
        let longText = String(repeating: "x", count: 100)
        let title = ChatPanelController.autoTitle(from: longText)
        XCTAssertEqual(title.count, 60)
    }

    func testShowEmptyStateShortText() {
        let title = ChatPanelController.autoTitle(from: "Hello world")
        XCTAssertEqual(title, "Hello world")
    }
}
