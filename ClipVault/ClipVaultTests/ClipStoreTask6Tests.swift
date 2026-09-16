import XCTest
import GRDB
@testable import ClipVault

// MARK: - ClipStore Filtered Fetch Tests (Task 6)

final class ClipStoreTask6Tests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        clipStore = ClipStore(dbQueue: dbQueue)
    }

    override func tearDown() {
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func insertClip(
        text: String,
        contentType: String = "text",
        sourceApp: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970,
        tags: String? = nil
    ) throws -> Int64 {
        let hash = Hashing.sha256(data: (text + contentType + (sourceApp ?? "") + "\(createdAt)").data(using: .utf8)!)
        var record = ClipRecord(
            id: nil,
            contentType: contentType,
            textContent: text,
            dataHash: hash,
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: sourceApp,
            byteSize: text.utf8.count,
            createdAt: createdAt,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: tags,
            imageDescription: nil,
            aiProcessed: 1,
            aiProcessedAt: createdAt
        )
        return try clipStore.insertRecord(&record)
    }

    // MARK: - fetchByApp

    func testFetchByAppReturnsMatchingClips() throws {
        let safariId = try insertClip(text: "from safari", sourceApp: "com.apple.Safari")
        let xcodeId  = try insertClip(text: "from xcode",  sourceApp: "com.apple.dt.Xcode")
        _ = xcodeId

        let results = try clipStore.fetchByApp(appName: "Safari")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.id, safariId)
    }

    func testFetchByAppIsCaseInsensitive() throws {
        let id = try insertClip(text: "slack message", sourceApp: "com.tinyspeck.slackmacgap")

        let results = try clipStore.fetchByApp(appName: "Slack")
        XCTAssertTrue(results.contains { $0.id == id }, "LIKE match should be case-insensitive")
    }

    func testFetchByAppReturnsEmptyWhenNoMatch() throws {
        _ = try insertClip(text: "clip", sourceApp: "com.apple.Safari")

        let results = try clipStore.fetchByApp(appName: "NonExistentApp")
        XCTAssertTrue(results.isEmpty)
    }

    func testFetchByAppRespectsLimit() throws {
        for i in 0..<5 {
            _ = try insertClip(text: "clip \(i)", sourceApp: "com.apple.Safari", createdAt: Double(i))
        }

        let results = try clipStore.fetchByApp(appName: "Safari", limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testFetchByAppExcludesNilSourceApp() throws {
        _ = try insertClip(text: "no app", sourceApp: nil)
        _ = try insertClip(text: "safari clip", sourceApp: "com.apple.Safari")

        let results = try clipStore.fetchByApp(appName: "Safari")
        XCTAssertTrue(results.allSatisfy { $0.sourceApp != nil })
    }

    // MARK: - fetchByDateRange

    func testFetchByDateRangeReturnsClipsInRange() throws {
        let now = Date().timeIntervalSince1970
        let inRangeId  = try insertClip(text: "in range",  createdAt: now - 3600)   // 1 hour ago
        let outOfRangeId = try insertClip(text: "too old", createdAt: now - 86400)  // 24 hours ago

        let results = try clipStore.fetchByDateRange(
            start: now - 7200,   // 2 hours ago
            end:   now
        )

        let ids = results.compactMap { $0.id }
        XCTAssertTrue(ids.contains(inRangeId), "Clip in range should be returned")
        XCTAssertFalse(ids.contains(outOfRangeId), "Old clip should be excluded")
    }

    func testFetchByDateRangeIncludesBoundaryValues() throws {
        let ts = Date().timeIntervalSince1970
        let id = try insertClip(text: "boundary clip", createdAt: ts)

        let results = try clipStore.fetchByDateRange(start: ts, end: ts)
        XCTAssertTrue(results.contains { $0.id == id }, "BETWEEN is inclusive of boundaries")
    }

    func testFetchByDateRangeReturnsEmptyForEmptyRange() throws {
        let now = Date().timeIntervalSince1970
        _ = try insertClip(text: "recent clip", createdAt: now)

        let results = try clipStore.fetchByDateRange(
            start: now - 86400,
            end:   now - 3600
        )
        XCTAssertTrue(results.isEmpty, "Recent clip outside range should not appear")
    }

    func testFetchByDateRangeRespectsLimit() throws {
        let now = Date().timeIntervalSince1970
        for i in 0..<5 {
            _ = try insertClip(text: "clip \(i)", createdAt: now - Double(i * 10))
        }

        let results = try clipStore.fetchByDateRange(
            start: now - 100,
            end: now,
            limit: 3
        )
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - fetchByTags

    func testFetchByTagsAnyMatch() throws {
        let codeId = try insertClip(text: "swift code", tags: "[\"code\",\"swift\"]")
        let urlId  = try insertClip(text: "some url",   tags: "[\"url\"]")
        _ = try insertClip(text: "no tags", tags: nil)

        let results = try clipStore.fetchByTags(tags: ["code", "url"], matchAll: false)
        let ids = results.compactMap { $0.id }

        XCTAssertTrue(ids.contains(codeId), "Clip tagged 'code' should match")
        XCTAssertTrue(ids.contains(urlId),  "Clip tagged 'url' should match")
    }

    func testFetchByTagsAllMatch() throws {
        let bothId  = try insertClip(text: "code and swift", tags: "[\"code\",\"swift\"]")
        let codeOnlyId = try insertClip(text: "just code",   tags: "[\"code\"]")

        let results = try clipStore.fetchByTags(tags: ["code", "swift"], matchAll: true)
        let ids = results.compactMap { $0.id }

        XCTAssertTrue(ids.contains(bothId),       "Clip with both tags should match")
        XCTAssertFalse(ids.contains(codeOnlyId),  "Clip with only one tag should be excluded")
    }

    func testFetchByTagsReturnsEmptyForEmptyTagList() throws {
        _ = try insertClip(text: "tagged clip", tags: "[\"code\"]")

        let results = try clipStore.fetchByTags(tags: [])
        XCTAssertTrue(results.isEmpty, "Empty tag list should return no results")
    }

    func testFetchByTagsIgnoresNullTagsColumn() throws {
        _ = try insertClip(text: "no tags clip", tags: nil)

        let results = try clipStore.fetchByTags(tags: ["code"])
        XCTAssertTrue(results.isEmpty, "Clips with NULL tags should not match")
    }

    func testFetchByTagsRespectsLimit() throws {
        for i in 0..<5 {
            _ = try insertClip(text: "clip \(i)", createdAt: Double(i), tags: "[\"code\"]")
        }

        let results = try clipStore.fetchByTags(tags: ["code"], limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - fetchByContentType

    func testFetchByContentTypeReturnsMatchingClips() throws {
        let textId  = try insertClip(text: "text clip",  contentType: "text")
        let imageId = try insertClip(text: "image clip", contentType: "image")
        _ = imageId

        let results = try clipStore.fetchByContentType(contentType: "text")
        XCTAssertTrue(results.contains { $0.id == textId }, "Text clip should be returned")
        XCTAssertFalse(results.contains { $0.id == imageId }, "Image clip should be excluded")
    }

    func testFetchByContentTypeReturnsEmptyForUnknownType() throws {
        _ = try insertClip(text: "text clip", contentType: "text")

        let results = try clipStore.fetchByContentType(contentType: "video")
        XCTAssertTrue(results.isEmpty)
    }

    func testFetchByContentTypeRespectsLimit() throws {
        for i in 0..<5 {
            _ = try insertClip(text: "html \(i)", contentType: "html", createdAt: Double(i))
        }

        let results = try clipStore.fetchByContentType(contentType: "html", limit: 2)
        XCTAssertEqual(results.count, 2)
    }

    func testFetchByContentTypeOrdersPinnedFirst() throws {
        let now = Date().timeIntervalSince1970
        let unpinnedId = try insertClip(text: "unpinned", contentType: "text", createdAt: now)
        let pinnedId   = try insertClip(text: "pinned",   contentType: "text", createdAt: now - 10)
        // Pin the older clip
        try clipStore.pinClip(id: pinnedId)

        let results = try clipStore.fetchByContentType(contentType: "text")
        XCTAssertEqual(results.first?.id, pinnedId, "Pinned clips should appear first")
        _ = unpinnedId
    }
}

// MARK: - SearchToolDefinitions Tests

final class SearchToolDefinitionsTests: XCTestCase {

    func testAllToolsContainsSixEntries() {
        XCTAssertEqual(SearchToolDefinitions.allTools.count, 6)
    }

    func testToolNamesSetContainsSixEntries() {
        XCTAssertEqual(SearchToolDefinitions.toolNames.count, 6)
    }

    func testAllToolNamesAreInToolNamesSet() {
        for tool in SearchToolDefinitions.allTools {
            guard let function = tool["function"] as? [String: Any],
                  let name = function["name"] as? String else {
                XCTFail("Tool missing 'function.name' key")
                continue
            }
            XCTAssertTrue(
                SearchToolDefinitions.toolNames.contains(name),
                "Tool '\(name)' not found in toolNames set"
            )
        }
    }

    func testEachToolHasTypeFunction() {
        for tool in SearchToolDefinitions.allTools {
            XCTAssertEqual(tool["type"] as? String, "function")
        }
    }

    func testEachToolHasDescription() {
        for tool in SearchToolDefinitions.allTools {
            guard let function = tool["function"] as? [String: Any] else {
                XCTFail("Missing 'function' key")
                continue
            }
            let description = function["description"] as? String
            XCTAssertNotNil(description, "Tool '\(function["name"] ?? "unknown")' missing description")
            XCTAssertFalse(description?.isEmpty ?? true)
        }
    }

    func testEachToolHasParameters() {
        for tool in SearchToolDefinitions.allTools {
            guard let function = tool["function"] as? [String: Any] else {
                XCTFail("Missing 'function' key")
                continue
            }
            let params = function["parameters"] as? [String: Any]
            XCTAssertNotNil(params, "Tool '\(function["name"] ?? "unknown")' missing parameters")
        }
    }

    func testEachToolParametersHaveRequired() {
        for tool in SearchToolDefinitions.allTools {
            guard let function = tool["function"] as? [String: Any],
                  let params = function["parameters"] as? [String: Any] else {
                XCTFail("Malformed tool definition")
                continue
            }
            let required = params["required"] as? [String]
            XCTAssertNotNil(required, "Tool '\(function["name"] ?? "unknown")' parameters missing 'required' array")
            XCTAssertFalse(required?.isEmpty ?? true, "Required array should not be empty")
        }
    }

    func testSearchByKeywordRequiresQuery() {
        guard let function = SearchToolDefinitions.searchByKeyword["function"] as? [String: Any],
              let params = function["parameters"] as? [String: Any],
              let required = params["required"] as? [String] else {
            XCTFail("Malformed searchByKeyword definition")
            return
        }
        XCTAssertTrue(required.contains("query"))
    }

    func testFilterByDateRangeRequiresBothDates() {
        guard let function = SearchToolDefinitions.filterByDateRange["function"] as? [String: Any],
              let params = function["parameters"] as? [String: Any],
              let required = params["required"] as? [String] else {
            XCTFail("Malformed filterByDateRange definition")
            return
        }
        XCTAssertTrue(required.contains("start_date"))
        XCTAssertTrue(required.contains("end_date"))
    }

    func testFilterByTagsRequiresTags() {
        guard let function = SearchToolDefinitions.filterByTags["function"] as? [String: Any],
              let params = function["parameters"] as? [String: Any],
              let required = params["required"] as? [String] else {
            XCTFail("Malformed filterByTags definition")
            return
        }
        XCTAssertTrue(required.contains("tags"))
    }

    func testFilterByContentTypeHasEnum() {
        guard let function = SearchToolDefinitions.filterByContentType["function"] as? [String: Any],
              let params = function["parameters"] as? [String: Any],
              let properties = params["properties"] as? [String: Any],
              let contentTypeProp = properties["content_type"] as? [String: Any],
              let enumValues = contentTypeProp["enum"] as? [String] else {
            XCTFail("filterByContentType missing content_type enum")
            return
        }
        XCTAssertTrue(enumValues.contains("text"))
        XCTAssertTrue(enumValues.contains("image"))
        XCTAssertTrue(enumValues.contains("html"))
    }

    func testToolDefinitionsCanBeSerializedToJSON() {
        for tool in SearchToolDefinitions.allTools {
            XCTAssertTrue(
                JSONSerialization.isValidJSONObject(tool),
                "Tool definition must be JSON-serializable for the OpenAI API"
            )
        }
    }
}

// MARK: - VectorSearchEngine.searchWithFilter Tests (Task 6)

final class SearchWithFilterTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var engine: VectorSearchEngine!
    private var client: OpenAIClient!

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

        engine = VectorSearchEngine(clipStore: clipStore, embeddingStore: embeddingStore, client: client)
        Settings.shared.openAIAPIKey = "sk-test-search-with-filter"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        engine = nil
        embeddingStore = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    private func insertClip(text: String, contentType: String = "text") throws -> Int64 {
        let hash = Hashing.sha256(data: (text + contentType).data(using: .utf8)!)
        var record = ClipRecord(
            id: nil, contentType: contentType, textContent: text,
            dataHash: hash, mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil, isPinned: false, isIndexed: true
        )
        return try clipStore.insertRecord(&record)
    }

    private func makeEmbeddingResponse(vector: [Float]) -> Data {
        let values = vector.map { String($0) }.joined(separator: ", ")
        let json = """
        {
          "object": "list",
          "data": [{"object": "embedding", "index": 0, "embedding": [\(values)]}],
          "model": "text-embedding-3-small",
          "usage": {"prompt_tokens": 5, "total_tokens": 5}
        }
        """
        return json.data(using: .utf8)!
    }

    private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/embeddings")!,
            statusCode: statusCode, httpVersion: nil, headerFields: nil
        )!
    }

    func testSearchWithFilterByContentTypeOnlyReturnsMatchingType() async throws {
        let textId  = try insertClip(text: "text content", contentType: "text")
        let imageId = try insertClip(text: "image content", contentType: "image")

        let textVec:  [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let imageVec: [Float] = [0.9, 0.1] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: textId,  embedding: textVec)
        try embeddingStore.insert(clipId: imageId, embedding: imageVec)

        let queryVec: [Float] = [0.95, 0.05] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let results = try await engine.searchWithFilter(
            query: "find text",
            filter: SearchFilter(contentType: "text"),
            topK: 10
        )

        XCTAssertTrue(results.allSatisfy { $0.clipId == textId })
        XCTAssertFalse(results.contains { $0.clipId == imageId })
    }

    func testSearchWithFilterProducesSameResultsAsFilteredSearch() async throws {
        let id1 = try insertClip(text: "clip one", contentType: "text")
        let id2 = try insertClip(text: "clip two", contentType: "text")

        let vec1: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let vec2: [Float] = [0.8, 0.2] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: id1, embedding: vec1)
        try embeddingStore.insert(clipId: id2, embedding: vec2)

        let queryVec: [Float] = [0.95, 0.05] + Array(repeating: 0, count: 254)

        // searchWithFilter call
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }
        let searchWithFilterResults = try await engine.searchWithFilter(
            query: "q", filter: SearchFilter(contentType: "text"), topK: 5
        )

        // filteredSearch call (reference)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }
        let filteredSearchResults = try await engine.filteredSearch(
            query: "q", filter: SearchFilter(contentType: "text"), topK: 5
        )

        XCTAssertEqual(
            searchWithFilterResults.map { $0.clipId },
            filteredSearchResults.map { $0.clipId },
            "searchWithFilter should return identical results to filteredSearch"
        )
    }

    func testSearchWithFilterReturnsEmptyWhenNoEmbeddings() async throws {
        _ = try insertClip(text: "no embedding clip", contentType: "text")

        let queryVec: [Float] = Array(repeating: 0.5, count: 256)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let results = try await engine.searchWithFilter(
            query: "anything", filter: SearchFilter(contentType: "text"), topK: 5
        )
        XCTAssertTrue(results.isEmpty)
    }
}

// MARK: - AgenticRAGEngine Stub Tests

final class AgenticRAGEngineStubTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        clipStore = ClipStore(dbQueue: dbQueue)
        Settings.shared.openAIAPIKey = "sk-test-agentic-stub"
    }

    override func tearDown() {
        Settings.shared.openAIAPIKey = ""
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    func testAgenticRAGEngineCanBeInstantiated() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session)

        let embeddingStore = EmbeddingStore(dbQueue: dbQueue)
        let vectorEngine = VectorSearchEngine(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client
        )
        let engine = AgenticRAGEngine(
            client: client,
            clipStore: clipStore,
            vectorEngine: vectorEngine
        )

        XCTAssertNotNil(engine, "AgenticRAGEngine should be instantiable")
    }

    func testAgenticRAGEngineExposesClassicRAGEngine() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session)

        let embeddingStore = EmbeddingStore(dbQueue: dbQueue)
        let vectorEngine = VectorSearchEngine(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client
        )
        let engine = AgenticRAGEngine(
            client: client,
            clipStore: clipStore,
            vectorEngine: vectorEngine
        )

        XCTAssertNotNil(engine.classicRAGEngine)
    }
}
