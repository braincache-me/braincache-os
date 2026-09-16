import XCTest
import GRDB
@testable import ClipVault

// MARK: - VectorSearchEngineTests

final class VectorSearchEngineTests: XCTestCase {

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

        Settings.shared.openAIAPIKey = "sk-test-vector-search"
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

    // MARK: - Helpers

    private func insertClip(text: String, contentType: String = "text", sourceApp: String? = nil) throws -> Int64 {
        let hash = Hashing.sha256(data: text.data(using: .utf8)!)
        var record = ClipRecord(
            id: nil,
            contentType: contentType,
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
            tags: nil,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )
        return try clipStore.insertRecord(&record)
    }

    private func makeEmbeddingResponse(vector: [Float]) -> Data {
        let values = vector.map { String($0) }.joined(separator: ", ")
        let json = """
        {
          "object": "list",
          "data": [
            {
              "object": "embedding",
              "index": 0,
              "embedding": [\(values)]
            }
          ],
          "model": "text-embedding-3-small",
          "usage": { "prompt_tokens": 5, "total_tokens": 5 }
        }
        """
        return json.data(using: .utf8)!
    }

    private func makeHTTPResponse(statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.openai.com/v1/embeddings")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    // MARK: - vector_full_scan equivalent: findNearest returns correct nearest neighbours

    func testSearchReturnsNearestNeighboursInOrder() async throws {
        let id1 = try insertClip(text: "clip one")
        let id2 = try insertClip(text: "clip two")
        let id3 = try insertClip(text: "clip three")

        // Fixed embeddings: id1 points along X, id2 along Y, id3 midway between X and Y.
        let vec1: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let vec2: [Float] = [0.0, 1.0] + Array(repeating: 0, count: 254)
        let vec3: [Float] = [0.7, 0.7] + Array(repeating: 0, count: 254)

        try embeddingStore.insert(clipId: id1, embedding: vec1)
        try embeddingStore.insert(clipId: id2, embedding: vec2)
        try embeddingStore.insert(clipId: id3, embedding: vec3)

        // Query close to vec1: id1 should rank first, id3 second, id2 last.
        let queryVec: [Float] = [0.9, 0.1] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let results = try await engine.search(query: "test query", topK: 3)

        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].clipId, id1, "id1 should be nearest to query close to vec1")
        XCTAssertLessThan(results[0].distance, results[1].distance, "Distances should be ascending")
        XCTAssertLessThan(results[1].distance, results[2].distance)
    }

    func testSearchTopKLimitsResults() async throws {
        for i in 0..<5 {
            let id = try insertClip(text: "clip \(i)")
            let vec: [Float] = Array(repeating: Float(i) / 5.0, count: 256)
            try embeddingStore.insert(clipId: id, embedding: vec)
        }

        let queryVec: [Float] = Array(repeating: 0.5, count: 256)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let results = try await engine.search(query: "any query", topK: 2)
        XCTAssertEqual(results.count, 2, "TopK=2 should return at most 2 results")
    }

    func testSearchReturnsEmptyWhenNoEmbeddingsStored() async throws {
        let queryVec: [Float] = Array(repeating: 0.1, count: 256)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let results = try await engine.search(query: "nothing here", topK: 10)
        XCTAssertEqual(results.count, 0, "No embeddings stored → no results")
    }

    // MARK: - RRF fusion logic

    func testRRFFusionCombinesRanksCorrectly() {
        // id 1 appears first in both lists → should get highest score.
        // id 2 appears 2nd in FTS and 3rd in vector.
        // id 3 appears 3rd in FTS only.
        // id 4 appears 2nd in vector only.
        let ftsRanks: [Int64]    = [1, 2, 3]
        let vectorRanks: [Int64] = [1, 4, 2]

        let fused = engine.reciprocalRankFusion(ftsRanks: ftsRanks, vectorRanks: vectorRanks, topK: 4)

        XCTAssertEqual(fused.first, 1, "ID 1 must rank first (appears first in both lists)")
        XCTAssertTrue(fused.contains(2), "ID 2 must appear (in both lists)")
        XCTAssertTrue(fused.contains(3) || fused.contains(4), "IDs from single-list should appear too")
    }

    func testRRFFusionTopKLimitsOutput() {
        let ftsRanks: [Int64]    = [1, 2, 3, 4, 5]
        let vectorRanks: [Int64] = [5, 4, 3, 2, 1]

        let fused = engine.reciprocalRankFusion(ftsRanks: ftsRanks, vectorRanks: vectorRanks, topK: 3)
        XCTAssertEqual(fused.count, 3)
    }

    func testRRFFusionWithEmptyFTSList() {
        let ftsRanks: [Int64]    = []
        let vectorRanks: [Int64] = [10, 20, 30]

        let fused = engine.reciprocalRankFusion(ftsRanks: ftsRanks, vectorRanks: vectorRanks, topK: 3)
        XCTAssertEqual(fused, vectorRanks, "With empty FTS, vector order should dominate")
    }

    func testRRFFusionWithEmptyVectorList() {
        let ftsRanks: [Int64]    = [10, 20, 30]
        let vectorRanks: [Int64] = []

        let fused = engine.reciprocalRankFusion(ftsRanks: ftsRanks, vectorRanks: vectorRanks, topK: 3)
        XCTAssertEqual(fused, ftsRanks, "With empty vector, FTS order should dominate")
    }

    func testRRFFusionScoreBoostForDoublyRankedItems() {
        // id 99 is ranked 1st in both lists → should outscore id 1 (1st in FTS) and id 2 (1st in vector)
        let ftsRanks: [Int64]    = [99, 1]
        let vectorRanks: [Int64] = [99, 2]

        let fused = engine.reciprocalRankFusion(ftsRanks: ftsRanks, vectorRanks: vectorRanks, topK: 3)
        XCTAssertEqual(fused.first, 99, "ID ranked 1st in both lists should have the highest fused score")
    }

    // MARK: - Filtered search (streaming mode with WHERE filter)

    func testFilteredSearchByContentType() async throws {
        let textId = try insertClip(text: "a text clip", contentType: "text")
        let imageId = try insertClip(text: "an image clip", contentType: "image")

        let textVec: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let imageVec: [Float] = [0.9, 0.1] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: textId, embedding: textVec)
        try embeddingStore.insert(clipId: imageId, embedding: imageVec)

        // Query close to both — filter to text only.
        let queryVec: [Float] = [0.95, 0.05] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let filter = SearchFilter(contentType: "text")
        let results = try await engine.filteredSearch(query: "text things", filter: filter, topK: 10)

        XCTAssertTrue(results.allSatisfy { $0.clipId == textId }, "Filtered results must only contain text clips")
        XCTAssertFalse(results.contains(where: { $0.clipId == imageId }), "Image clip should be excluded by content type filter")
    }

    func testFilteredSearchBySourceApp() async throws {
        let xcodeId = try insertClip(text: "xcode clip", sourceApp: "com.apple.dt.Xcode")
        let safariId = try insertClip(text: "safari clip", sourceApp: "com.apple.Safari")

        let xcodeVec: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let safariVec: [Float] = [0.9, 0.1] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: xcodeId, embedding: xcodeVec)
        try embeddingStore.insert(clipId: safariId, embedding: safariVec)

        let queryVec: [Float] = [0.95, 0.05] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        let filter = SearchFilter(sourceApp: "com.apple.dt.Xcode")
        let results = try await engine.filteredSearch(query: "code things", filter: filter, topK: 10)

        XCTAssertFalse(results.isEmpty, "Should find the Xcode clip")
        XCTAssertTrue(results.allSatisfy { $0.clipId == xcodeId }, "Should only return clips from Xcode")
    }

    func testFilteredSearchReturnsEmptyWhenNoMatch() async throws {
        let id = try insertClip(text: "some clip", contentType: "text")
        let vec: [Float] = Array(repeating: 0.5, count: 256)
        try embeddingStore.insert(clipId: id, embedding: vec)

        let queryVec: [Float] = Array(repeating: 0.5, count: 256)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        // Filter to "image" type — no image clips stored.
        let filter = SearchFilter(contentType: "image")
        let results = try await engine.filteredSearch(query: "anything", filter: filter, topK: 10)
        XCTAssertEqual(results.count, 0, "Filtering to a type with no clips returns empty array")
    }

    // MARK: - Hybrid search

    func testHybridSearchReturnsMergedResults() async throws {
        let id1 = try insertClip(text: "machine learning transformer")
        let id2 = try insertClip(text: "neural network deep learning")

        // Insert embeddings: id1 close to query, id2 far.
        let vec1: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let vec2: [Float] = [0.0, 1.0] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: id1, embedding: vec1)
        try embeddingStore.insert(clipId: id2, embedding: vec2)

        // Mock query embedding close to vec1.
        let queryVec: [Float] = [0.99, 0.01] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        // FTS query "transformer" matches id1; vector query is also close to id1.
        let results = try await engine.hybridSearch(query: "transformer", topK: 2)

        XCTAssertFalse(results.isEmpty, "Hybrid search should return results")
        XCTAssertTrue(results.contains(id1), "id1 (both FTS and vector match) should appear in results")
    }

    func testHybridSearchFallsBackToVectorOnlyWhenFTSEmpty() async throws {
        // Insert a clip whose text does NOT match the FTS query, but has a near vector.
        let id = try insertClip(text: "completely unrelated content xyz123")
        let vec: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        try embeddingStore.insert(clipId: id, embedding: vec)

        let queryVec: [Float] = [0.99, 0.01] + Array(repeating: 0, count: 254)
        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.makeEmbeddingResponse(vector: queryVec))
        }

        // FTS for "transformer" won't match "completely unrelated content xyz123"
        let results = try await engine.hybridSearch(query: "transformer", topK: 5)

        // Vector component should still surface the clip.
        XCTAssertTrue(results.contains(id), "Vector match should surface clip even when FTS misses it")
    }

    // MARK: - preloadQuantized (smoke test — no-op until extension is linked)

    func testPreloadQuantizedDoesNotCrash() {
        engine.preloadQuantized()  // Should not throw or crash.
    }
}
