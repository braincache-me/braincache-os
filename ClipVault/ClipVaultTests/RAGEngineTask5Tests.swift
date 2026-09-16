import XCTest
import GRDB
@testable import ClipVault

// MARK: - Settings RAG keys

final class SettingsRAGParametersTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        suiteName = "test.task5.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultRagTopK() {
        XCTAssertEqual(settings.ragTopK, Settings.Defaults.ragTopK)
        XCTAssertEqual(settings.ragTopK, 20)
    }

    func testDefaultRagMaxContextChars() {
        XCTAssertEqual(settings.ragMaxContextChars, Settings.Defaults.ragMaxContextChars)
        XCTAssertEqual(settings.ragMaxContextChars, 24_000)
    }

    func testDefaultRagMaxOutputTokens() {
        XCTAssertEqual(settings.ragMaxOutputTokens, Settings.Defaults.ragMaxOutputTokens)
        XCTAssertEqual(settings.ragMaxOutputTokens, 512)
    }

    // MARK: - Read / Write

    func testWriteAndReadRagTopK() {
        settings.ragTopK = 30
        XCTAssertEqual(settings.ragTopK, 30)
    }

    func testWriteAndReadRagMaxContextChars() {
        settings.ragMaxContextChars = 16_000
        XCTAssertEqual(settings.ragMaxContextChars, 16_000)
    }

    func testWriteAndReadRagMaxOutputTokens() {
        settings.ragMaxOutputTokens = 1024
        XCTAssertEqual(settings.ragMaxOutputTokens, 1024)
    }

    // MARK: - Clamping

    func testRagTopKClampedToMin() {
        settings.ragTopK = 1  // below min of 5
        XCTAssertEqual(settings.ragTopK, 5)
    }

    func testRagTopKClampedToMax() {
        settings.ragTopK = 100  // above max of 50
        XCTAssertEqual(settings.ragTopK, 50)
    }

    func testRagTopKAtBoundaryMin() {
        settings.ragTopK = 5
        XCTAssertEqual(settings.ragTopK, 5)
    }

    func testRagTopKAtBoundaryMax() {
        settings.ragTopK = 50
        XCTAssertEqual(settings.ragTopK, 50)
    }

    func testRagMaxContextCharsClampedToMin() {
        settings.ragMaxContextChars = 100  // below min of 4000
        XCTAssertEqual(settings.ragMaxContextChars, 4_000)
    }

    func testRagMaxContextCharsClampedToMax() {
        settings.ragMaxContextChars = 999_999  // above max of 128000
        XCTAssertEqual(settings.ragMaxContextChars, 128_000)
    }

    func testRagMaxContextCharsAtBoundaryMin() {
        settings.ragMaxContextChars = 4_000
        XCTAssertEqual(settings.ragMaxContextChars, 4_000)
    }

    func testRagMaxContextCharsAtBoundaryMax() {
        settings.ragMaxContextChars = 128_000
        XCTAssertEqual(settings.ragMaxContextChars, 128_000)
    }

    func testRagMaxOutputTokensClampedToMin() {
        settings.ragMaxOutputTokens = 10  // below min of 128
        XCTAssertEqual(settings.ragMaxOutputTokens, 128)
    }

    func testRagMaxOutputTokensClampedToMax() {
        settings.ragMaxOutputTokens = 99_999  // above max of 32000
        XCTAssertEqual(settings.ragMaxOutputTokens, 32_000)
    }

    func testRagMaxOutputTokensAtBoundaryMin() {
        settings.ragMaxOutputTokens = 128
        XCTAssertEqual(settings.ragMaxOutputTokens, 128)
    }

    func testRagMaxOutputTokensAtBoundaryMax() {
        settings.ragMaxOutputTokens = 32_000
        XCTAssertEqual(settings.ragMaxOutputTokens, 32_000)
    }

    // MARK: - Persistence

    func testRagTopKPersists() {
        settings.ragTopK = 35
        let settings2 = Settings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(settings2.ragTopK, 35)
    }

    // MARK: - Keys & Defaults enum coverage

    func testKeysEnumHasAllRAGKeys() {
        XCTAssertFalse(Settings.Keys.ragTopK.isEmpty)
        XCTAssertFalse(Settings.Keys.ragMaxContextChars.isEmpty)
        XCTAssertFalse(Settings.Keys.ragMaxOutputTokens.isEmpty)
    }

    func testDefaultsEnumMatchesExpectedValues() {
        XCTAssertEqual(Settings.Defaults.ragTopK, 20)
        XCTAssertEqual(Settings.Defaults.ragMaxContextChars, 24_000)
        XCTAssertEqual(Settings.Defaults.ragMaxOutputTokens, 512)
    }
}

// MARK: - RAGEngine reads dynamic Settings

final class RAGEngineDynamicSettingsTests: XCTestCase {

    private var dbQueue:        DatabaseQueue!
    private var clipStore:      ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var client:         OpenAIClient!
    private var engine:         RAGEngine!

    // Original Settings.shared values to restore
    private var originalTopK: Int = 0
    private var originalMaxContextChars: Int = 0
    private var originalMaxOutputTokens: Int = 0

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
        Settings.shared.openAIAPIKey = "sk-test-task5"

        // Save originals
        originalTopK = Settings.shared.ragTopK
        originalMaxContextChars = Settings.shared.ragMaxContextChars
        originalMaxOutputTokens = Settings.shared.ragMaxOutputTokens
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        // Restore originals
        Settings.shared.ragTopK = originalTopK
        Settings.shared.ragMaxContextChars = originalMaxContextChars
        Settings.shared.ragMaxOutputTokens = originalMaxOutputTokens
        engine         = nil
        embeddingStore = nil
        clipStore      = nil
        dbQueue        = nil
        super.tearDown()
    }

    // MARK: - buildContext respects ragMaxContextChars

    func testBuildContextRespectsSmallContextCharsLimit() {
        // Minimum allowed value is 4000 due to clamping.
        Settings.shared.ragMaxContextChars = 4_000

        let longText = String(repeating: "X", count: 3_000)
        let clips = (1...5).map { i in
            ClipRecord(
                id: Int64(i), contentType: "text", textContent: longText,
                dataHash: "h\(i)", mediaFileName: nil, fileURL: nil,
                sourceApp: nil, byteSize: longText.count,
                createdAt: Double(i) * 1_000_000, lastUsedAt: nil,
                isPinned: false, isIndexed: true,
                tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
            )
        }
        let context = engine.buildContext(clips: clips)
        XCTAssertLessThanOrEqual(context.count, 4_000,
            "Context must respect the configured ragMaxContextChars limit of 4000")
    }

    func testBuildContextRespectsLargeContextCharsLimit() {
        Settings.shared.ragMaxContextChars = 128_000  // max limit

        let longText = String(repeating: "A", count: 10_000)
        let clips = (1...5).map { i in
            ClipRecord(
                id: Int64(i), contentType: "text", textContent: longText,
                dataHash: "\(i)", mediaFileName: nil, fileURL: nil,
                sourceApp: nil, byteSize: longText.count,
                createdAt: Double(i), lastUsedAt: nil,
                isPinned: false, isIndexed: true,
                tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
            )
        }
        let context = engine.buildContext(clips: clips)
        XCTAssertLessThanOrEqual(context.count, 128_000)
    }

    func testBuildContextDefaultLimitIs24000() {
        // With default settings, the context limit should be 24000
        XCTAssertEqual(Settings.Defaults.ragMaxContextChars, 24_000)
        Settings.shared.ragMaxContextChars = Settings.Defaults.ragMaxContextChars

        let longText = String(repeating: "B", count: 6_000)
        let clips = (1...6).map { i in
            ClipRecord(
                id: Int64(i), contentType: "text", textContent: longText,
                dataHash: "\(i)", mediaFileName: nil, fileURL: nil,
                sourceApp: nil, byteSize: longText.count,
                createdAt: Double(i), lastUsedAt: nil,
                isPinned: false, isIndexed: true,
                tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
            )
        }
        let context = engine.buildContext(clips: clips)
        XCTAssertLessThanOrEqual(context.count, 24_000)
    }

    // MARK: - Query uses ragMaxOutputTokens

    func testQueryUsesConfiguredOutputTokens() async throws {
        // Insert a clip with embedding
        let hash = Hashing.sha256(data: "task5 test content".data(using: .utf8)!)
        var record = ClipRecord(
            id: nil, contentType: "text", textContent: "task5 test content",
            dataHash: hash, mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 18,
            createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
        )
        let clipId = try clipStore.insertRecord(&record)
        let vec: [Float] = Array(repeating: 0.5, count: 256)
        try embeddingStore.insert(clipId: clipId, embedding: vec)

        // Set non-default RAG params
        Settings.shared.ragMaxOutputTokens = 256

        var capturedMaxTokens: Int?
        var temperatureWasSent = false

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
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    capturedMaxTokens = json["max_completion_tokens"] as? Int
                    temperatureWasSent = json["temperature"] != nil
                }
                let data = """
                {"id":"x","object":"chat.completion","choices":[{"index":0,
                 "message":{"role":"assistant","content":"Answer #\(clipId)"},
                 "finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            }
        }

        _ = try await engine.query("What is the test content?")

        XCTAssertEqual(capturedMaxTokens, 256,
            "RAGEngine should pass Settings.shared.ragMaxOutputTokens (256) to the LLM")
        XCTAssertFalse(temperatureWasSent,
            "RAGEngine must not send temperature — newer reasoning models reject it")
    }

    func testQueryUsesDefaultOutputTokensAndTemperature() async throws {
        let hash = Hashing.sha256(data: "default params test".data(using: .utf8)!)
        var record = ClipRecord(
            id: nil, contentType: "text", textContent: "default params test",
            dataHash: hash, mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 19,
            createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: nil, imageDescription: nil, aiProcessed: 1, aiProcessedAt: nil
        )
        let clipId = try clipStore.insertRecord(&record)
        let vec: [Float] = Array(repeating: 0.6, count: 256)
        try embeddingStore.insert(clipId: clipId, embedding: vec)

        // Restore defaults
        Settings.shared.ragMaxOutputTokens = Settings.Defaults.ragMaxOutputTokens

        var capturedMaxTokens: Int?
        var temperatureWasSent = false

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
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                    capturedMaxTokens = json["max_completion_tokens"] as? Int
                    temperatureWasSent = json["temperature"] != nil
                }
                let data = """
                {"id":"x","object":"chat.completion","choices":[{"index":0,
                 "message":{"role":"assistant","content":"Default answer #\(clipId)"},
                 "finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}
                """.data(using: .utf8)!
                return (HTTPURLResponse(url: URL(string: url)!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!, data)
            }
        }

        _ = try await engine.query("Test query")

        XCTAssertEqual(capturedMaxTokens, 512,
            "Default ragMaxOutputTokens should be 512")
        XCTAssertFalse(temperatureWasSent,
            "RAGEngine must not send temperature in the default path either")
    }
}
