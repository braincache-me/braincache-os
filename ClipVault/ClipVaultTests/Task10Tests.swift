import XCTest
import GRDB
@testable import ClipVault

// MARK: - Task 10: Performance, Edge Cases & Polish

final class Task10Tests: XCTestCase {

    // MARK: - Token Estimation Tests

    func testEstimateTokens_empty() {
        XCTAssertEqual(OpenAIClient.estimateTokens(""), 0)
    }

    func testEstimateTokens_singleChar() {
        XCTAssertEqual(OpenAIClient.estimateTokens("a"), 1)
    }

    func testEstimateTokens_fourChars() {
        XCTAssertEqual(OpenAIClient.estimateTokens("abcd"), 1)
    }

    func testEstimateTokens_eightChars() {
        XCTAssertEqual(OpenAIClient.estimateTokens("abcdefgh"), 2)
    }

    func testEstimateTokens_typicalText() {
        let text = String(repeating: "a", count: 400)
        XCTAssertEqual(OpenAIClient.estimateTokens(text), 100)
    }

    func testEstimateTokens_largeText() {
        let text = String(repeating: "x", count: 32_000)
        XCTAssertEqual(OpenAIClient.estimateTokens(text), 8_000)
    }

    // MARK: - Cost Tracking Tests

    override func setUp() {
        super.setUp()
        // Reset cost tracking state before each test
        Settings.shared.costTrackingDate = ""
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
        Settings.shared.tokensTotalInput = 0
        Settings.shared.tokensTotalOutput = 0
        Settings.shared.tokensTotalCachedInput = 0
        Settings.shared.chatTokensTotalInput = 0
        Settings.shared.chatTokensTotalCachedInput = 0
        Settings.shared.chatTokensTotalOutput = 0
        Settings.shared.chatCostTotalUSD = 0
        Settings.shared.indexingTokensTotalInput = 0
        Settings.shared.indexingTokensTotalCachedInput = 0
        Settings.shared.indexingTokensTotalOutput = 0
        Settings.shared.indexingCostTotalUSD = 0
        Settings.shared.clearAICostHistory()
        Settings.shared.openAIAPIKey = "sk-test-task10"
    }

    override func tearDown() {
        Settings.shared.costTrackingDate = ""
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
        Settings.shared.tokensTotalInput = 0
        Settings.shared.tokensTotalOutput = 0
        Settings.shared.tokensTotalCachedInput = 0
        Settings.shared.chatTokensTotalInput = 0
        Settings.shared.chatTokensTotalCachedInput = 0
        Settings.shared.chatTokensTotalOutput = 0
        Settings.shared.chatCostTotalUSD = 0
        Settings.shared.indexingTokensTotalInput = 0
        Settings.shared.indexingTokensTotalCachedInput = 0
        Settings.shared.indexingTokensTotalOutput = 0
        Settings.shared.indexingCostTotalUSD = 0
        Settings.shared.clearAICostHistory()
        Settings.shared.openAIAPIKey = ""
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testRecordUsage_setsTokensForToday() {
        let client = OpenAIClient()
        client.recordUsage(inputTokens: 100, outputTokens: 50)
        XCTAssertEqual(Settings.shared.tokensInputToday, 100)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 50)
        XCTAssertEqual(Settings.shared.tokensTotalInput, 100)
        XCTAssertEqual(Settings.shared.tokensTotalOutput, 50)
        XCTAssertEqual(Settings.shared.costTrackingDate, Settings.todayString())
    }

    func testRecordUsage_accumulatesAcrossCallsSameDay() {
        let client = OpenAIClient()
        client.recordUsage(inputTokens: 100, outputTokens: 50)
        client.recordUsage(inputTokens: 200, outputTokens: 30)
        XCTAssertEqual(Settings.shared.tokensInputToday, 300)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 80)
        XCTAssertEqual(Settings.shared.tokensTotalInput, 300)
        XCTAssertEqual(Settings.shared.tokensTotalOutput, 80)
    }

    func testRecordUsage_resetsOnNewDay() {
        // Seed as if yesterday's usage was recorded
        Settings.shared.costTrackingDate = "1970-01-01"  // old date
        Settings.shared.tokensInputToday = 999
        Settings.shared.tokensOutputToday = 888
        Settings.shared.tokensTotalInput = 999
        Settings.shared.tokensTotalOutput = 888

        let client = OpenAIClient()
        client.recordUsage(inputTokens: 10, outputTokens: 5)

        // Daily counters reset; totals keep accumulating
        XCTAssertEqual(Settings.shared.tokensInputToday, 10)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 5)
        XCTAssertEqual(Settings.shared.tokensTotalInput, 1009)
        XCTAssertEqual(Settings.shared.tokensTotalOutput, 893)
        XCTAssertEqual(Settings.shared.costTrackingDate, Settings.todayString())
    }

    func testRecordUsage_tracksChatAndIndexingSeparately() {
        let client = OpenAIClient()

        client.recordUsage(
            model: "gpt-5.4-nano",
            category: .chat,
            inputTokens: 100,
            outputTokens: 20,
            cachedInputTokens: 40
        )
        client.recordUsage(
            model: "text-embedding-3-small",
            category: .indexing,
            inputTokens: 50,
            outputTokens: 0
        )

        XCTAssertEqual(Settings.shared.chatTokensInputToday, 100)
        XCTAssertEqual(Settings.shared.chatTokensCachedInputToday, 40)
        XCTAssertEqual(Settings.shared.chatTokensOutputToday, 20)
        XCTAssertEqual(Settings.shared.indexingTokensInputToday, 50)
        XCTAssertEqual(Settings.shared.indexingTokensCachedInputToday, 0)
        XCTAssertEqual(Settings.shared.indexingTokensOutputToday, 0)
        XCTAssertEqual(Settings.shared.tokensInputToday, 150)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 20)
        XCTAssertEqual(Settings.shared.tokensCachedInputToday, 40)
        XCTAssertGreaterThan(Settings.shared.chatCostTodayUSD, 0)
        XCTAssertGreaterThan(Settings.shared.indexingCostTodayUSD, 0)

        let daily = Settings.shared.recentDailyCostHistory(limit: 1)
        XCTAssertEqual(daily.count, 1)
        XCTAssertEqual(daily[0].key, Settings.todayString())
        XCTAssertEqual(daily[0].value.chatCostUSD, Settings.shared.chatCostTodayUSD, accuracy: 0.000_001)
        XCTAssertEqual(daily[0].value.indexingCostUSD, Settings.shared.indexingCostTodayUSD, accuracy: 0.000_001)

        let monthly = Settings.shared.recentMonthlyCostHistory(limit: 1)
        XCTAssertEqual(monthly.count, 1)
        XCTAssertEqual(monthly[0].key, Settings.monthString(for: Date()))
        XCTAssertEqual(monthly[0].value.totalCostUSD,
                       Settings.shared.chatCostTodayUSD + Settings.shared.indexingCostTodayUSD,
                       accuracy: 0.000_001)
    }

    func testRecordUsage_chatCompletionTracksTokens() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session, initialRetryDelay: 1_000)

        MockURLProtocol.requestHandler = { _ in
            let json = """
            {
                "id": "chatcmpl-test",
                "choices": [{"message": {"role": "assistant", "content": "hello"}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 42, "completion_tokens": 7, "total_tokens": 49}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        _ = try await client.chatCompletion(
            model: "gpt-5.4-nano",
            messages: [OpenAIClient.ChatMessage(role: "user", content: "hi")]
        )

        XCTAssertEqual(Settings.shared.tokensInputToday, 42)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 7)
    }

    func testRecordUsage_embeddingTracksInputTokens() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session, initialRetryDelay: 1_000)

        MockURLProtocol.requestHandler = { _ in
            let json = """
            {
                "data": [{"embedding": [0.1, 0.2, 0.3], "index": 0}],
                "usage": {"prompt_tokens": 15, "total_tokens": 15}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: URL(string: "https://api.openai.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }

        _ = try await client.createEmbedding(model: "text-embedding-3-small", input: "hello world")

        XCTAssertEqual(Settings.shared.tokensInputToday, 15)
        XCTAssertEqual(Settings.shared.tokensOutputToday, 0)
    }

    // MARK: - Heuristic Pre-tagging (XML)

    func testHeuristicTags_xmlDeclaration() {
        let classifier = ContentClassifier(client: OpenAIClient())
        let tags = classifier.heuristicTags(
            for: "<?xml version=\"1.0\"?><root><item>test</item></root>",
            contentType: "text"
        )
        XCTAssertTrue(tags.contains("xml"), "Expected 'xml' tag")
        XCTAssertTrue(tags.contains("structured-data"), "Expected 'structured-data' tag")
    }

    func testHeuristicTags_xmlElement() {
        let classifier = ContentClassifier(client: OpenAIClient())
        let tags = classifier.heuristicTags(
            for: "<configuration><key>value</key></configuration>",
            contentType: "text"
        )
        XCTAssertTrue(tags.contains("xml"), "Expected 'xml' tag for element-based XML")
        XCTAssertTrue(tags.contains("structured-data"), "Expected 'structured-data' tag")
    }

    func testHeuristicTags_xmlNotTriggeredByPlainAngleBrackets() {
        // HTML-like without closing tags should not be tagged as xml
        let classifier = ContentClassifier(client: OpenAIClient())
        let tags = classifier.heuristicTags(for: "<br> some text", contentType: "text")
        XCTAssertFalse(tags.contains("xml"), "Should not tag as xml without closing tag")
    }

    func testHeuristicTags_jsonStillWorks() {
        let classifier = ContentClassifier(client: OpenAIClient())
        let tags = classifier.heuristicTags(for: "{\"key\": \"value\"}", contentType: "text")
        XCTAssertTrue(tags.contains("json"))
        XCTAssertTrue(tags.contains("structured-data"))
    }

    func testHeuristicTags_urlStillWorks() {
        let classifier = ContentClassifier(client: OpenAIClient())
        let tags = classifier.heuristicTags(for: "https://example.com/path", contentType: "text")
        XCTAssertTrue(tags.contains("url"))
    }

    // MARK: - Quantize After Purge (PurgeScheduler)

    func testPurgeScheduler_callsQuantizeAndPreloadAfterPurge() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ClipStore(dbQueue: manager.dbQueue)
        let embeddingStore = EmbeddingStore(dbQueue: manager.dbQueue)

        var quantizeCalled = false
        var preloadCalled = false
        embeddingStore.onQuantize = { quantizeCalled = true }
        embeddingStore.onPreload = { preloadCalled = true }

        let settings = Settings(defaults: UserDefaults(suiteName: "PurgeSchedulerTest-\(UUID().uuidString)")!)
        settings.autoPurgeAgeDays = 0   // purge everything
        settings.maxHistoryCount = 0

        let scheduler = PurgeScheduler(store: store, settings: settings)
        scheduler.embeddingStore = embeddingStore

        scheduler.runPurge()

        XCTAssertTrue(quantizeCalled, "quantize() should be called after purge")
        XCTAssertTrue(preloadCalled, "preloadQuantized() should be called after purge")
    }

    // MARK: - API Key Rotation

    func testCancelAllPendingRequests_doesNotCrash() {
        let client = OpenAIClient()
        // Should not throw; URLSession.getAllTasks is always safe to call
        client.cancelAllPendingRequests()
        // Allow getAllTasks callback to run
        let exp = expectation(description: "cancel callback")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Settings.todayString

    func testTodayString_isISO8601Format() {
        let today = Settings.todayString()
        let parts = today.split(separator: "-")
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].count, 4, "Year should be 4 digits")
        XCTAssertEqual(parts[1].count, 2, "Month should be 2 digits")
        XCTAssertEqual(parts[2].count, 2, "Day should be 2 digits")
    }
}

