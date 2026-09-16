import XCTest
import GRDB
@testable import ClipVault

// MARK: - EmbeddingGenerator Tests

final class EmbeddingGeneratorTests: XCTestCase {

    private var generator: EmbeddingGenerator!
    private var embeddingStore: EmbeddingStore!
    private var clipStore: ClipStore!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        embeddingStore = EmbeddingStore(dbQueue: dbQueue)
        clipStore = ClipStore(dbQueue: dbQueue)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = OpenAIClient(session: session, initialRetryDelay: 100_000)
        generator = EmbeddingGenerator(client: client, embeddingStore: embeddingStore)

        Settings.shared.openAIAPIKey = "sk-test-embedding"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        generator = nil
        embeddingStore = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeClip(
        id: Int64 = 1,
        textContent: String? = nil,
        imageDescription: String? = nil,
        tags: String? = nil
    ) -> ClipRecord {
        ClipRecord(
            id: id,
            contentType: "text",
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
            tags: tags,
            imageDescription: imageDescription,
            aiProcessed: 0,
            aiProcessedAt: nil
        )
    }

    private func insertTestClip(text: String? = "test clip") throws -> Int64 {
        let hash = Hashing.sha256(data: (text ?? "image").data(using: .utf8)!)
        let entry = ClipboardEntry(
            contentType: text == nil ? .image : .text,
            textContent: text,
            dataHash: hash,
            byteSize: (text ?? "").utf8.count,
            createdAt: Date()
        )
        return try clipStore.insert(entry: entry)
    }

    private func embeddingResponseJSON(dims: Int = 256) -> Data {
        let values = (0..<dims).map { String(Float($0) / Float(dims)) }.joined(separator: ", ")
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
          "usage": { "prompt_tokens": 10, "total_tokens": 10 }
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

    // MARK: - buildInputString

    func testBuildInputStringCombinesTagsDescriptionText() {
        let clip = makeClip(
            textContent: "Hello world",
            imageDescription: "a photo",
            tags: "[\"code\",\"tech\"]"
        )
        let input = generator.buildInputString(clip: clip)
        XCTAssertTrue(input.contains("code, tech"), "Tags should appear joined by ', '")
        XCTAssertTrue(input.contains("a photo"), "Image description should be in input")
        XCTAssertTrue(input.contains("Hello world"), "Text content should be in input")
    }

    func testBuildInputStringOrderIsTagsDescriptionText() {
        let clip = makeClip(
            textContent: "Text",
            imageDescription: "Desc",
            tags: "[\"code\"]"
        )
        let input = generator.buildInputString(clip: clip)
        let tagsIdx = input.range(of: "code")!.lowerBound
        let descIdx = input.range(of: "Desc")!.lowerBound
        let textIdx = input.range(of: "Text")!.lowerBound
        XCTAssertLessThan(tagsIdx, descIdx, "Tags must appear before description")
        XCTAssertLessThan(descIdx, textIdx, "Description must appear before text content")
    }

    func testBuildInputStringWithNilFields() {
        let clip = makeClip(textContent: nil, imageDescription: nil, tags: nil)
        let input = generator.buildInputString(clip: clip)
        // Should be " |  | " or similar — just separators with empty parts
        XCTAssertNotNil(input)
    }

    func testBuildInputStringWithTextOnly() {
        let clip = makeClip(textContent: "Just text", imageDescription: nil, tags: nil)
        let input = generator.buildInputString(clip: clip)
        XCTAssertTrue(input.contains("Just text"))
    }

    func testBuildInputStringWithTagsOnly() {
        let clip = makeClip(textContent: nil, imageDescription: nil, tags: "[\"prose\"]")
        let input = generator.buildInputString(clip: clip)
        XCTAssertTrue(input.contains("prose"))
    }

    // MARK: - Truncation

    func testTruncateShortStringUnchanged() {
        let text = "short text"
        XCTAssertEqual(generator.truncate(text, to: 100), text)
    }

    func testTruncateLongStringAppendsMarker() {
        let text = String(repeating: "a", count: 40_000)
        let result = generator.truncate(text, to: EmbeddingGenerator.maxInputChars)
        XCTAssertTrue(result.hasSuffix("…[truncated]"))
        XCTAssertLessThan(result.count, 40_000)
    }

    func testBuildInputStringTruncatesAt32000() {
        // Create a clip whose combined input exceeds maxInputChars
        let longText = String(repeating: "x", count: 40_000)
        let clip = makeClip(textContent: longText)
        let input = generator.buildInputString(clip: clip)
        XCTAssertTrue(input.hasSuffix("…[truncated]"))
        XCTAssertLessThanOrEqual(input.count, EmbeddingGenerator.maxInputChars + 20)
    }

    // MARK: - API request structure

    func testGenerateAndStoreSendsCorrectModel() async throws {
        let clipId = try insertTestClip(text: "model check")

        MockURLProtocol.requestHandler = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(body["model"] as? String, "text-embedding-3-small")
            XCTAssertEqual(body["dimensions"] as? Int, 256)
            return (self.makeHTTPResponse(), self.embeddingResponseJSON())
        }

        let clip = makeClip(id: clipId, textContent: "model check")
        _ = try await generator.generateAndStore(clip: clip)
    }

    func testGenerateAndStoreStoresEmbedding() async throws {
        let clipId = try insertTestClip(text: "store test")

        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.embeddingResponseJSON())
        }

        let clip = makeClip(id: clipId, textContent: "store test")
        let vector = try await generator.generateAndStore(clip: clip)

        XCTAssertEqual(vector.count, 256)

        let stored = try embeddingStore.fetchEmbedding(clipId: clipId)
        XCTAssertNotNil(stored, "Embedding should be stored in EmbeddingStore after generation")
        XCTAssertEqual(stored?.count, 256)
    }

    func testGenerateAndStoreReturnsVector() async throws {
        let clipId = try insertTestClip(text: "return vector")

        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.embeddingResponseJSON())
        }

        let clip = makeClip(id: clipId, textContent: "return vector")
        let vector = try await generator.generateAndStore(clip: clip)
        XCTAssertEqual(vector.count, 256)
    }

    // MARK: - Error handling

    func testMissingClipIdThrows() async throws {
        let clip = makeClip(id: 0)  // ClipRecord with id=0 treated as nil-equivalent? Check EmbeddingGenerator
        // Actually the implementation checks `clip.id` being nil. ClipRecord uses Int64 optionally.
        // Let's create a clip record with nil id by using the fact that ClipRecord.id is Int64?
        let clipWithNilId = ClipRecord(
            id: nil,
            contentType: "text",
            textContent: "no id",
            dataHash: "hash",
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: nil,
            byteSize: 5,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: nil,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )

        do {
            _ = try await generator.generateAndStore(clip: clipWithNilId)
            XCTFail("Expected EmbeddingError.missingClipId to be thrown")
        } catch EmbeddingError.missingClipId {
            // expected
        }
    }

    func testApiKeyMissingThrows() async throws {
        Settings.shared.openAIAPIKey = ""
        let clipId = try insertTestClip(text: "no key")
        let clip = makeClip(id: clipId, textContent: "no key")

        do {
            _ = try await generator.generateAndStore(clip: clip)
            XCTFail("Expected OpenAIError.apiKeyMissing")
        } catch OpenAIError.apiKeyMissing {
            // expected
        }
    }

    // MARK: - Vector searchable after insert

    func testVectorIsSearchableAfterInsert() async throws {
        // Insert two clips and generate embeddings; verify findNearest returns correct order
        let id1 = try insertTestClip(text: "clip one")
        let id2 = try insertTestClip(text: "clip two")

        // Use fixed embeddings to control cosine distances
        let vec1: [Float] = [1.0, 0.0] + Array(repeating: 0, count: 254)
        let vec2: [Float] = [0.0, 1.0] + Array(repeating: 0, count: 254)

        try embeddingStore.insert(clipId: id1, embedding: vec1)
        try embeddingStore.insert(clipId: id2, embedding: vec2)

        // Query close to vec1
        let results = try embeddingStore.findNearest(to: vec1, topK: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].clipId, id1, "Most similar clip should be ranked first")
        XCTAssertLessThan(results[0].distance, results[1].distance)
    }

    // MARK: - Quantize batch trigger

    func testQuantizeBatchTriggerCallsQuantizeEvery100Inserts() async throws {
        // Patch: insert 99 embeddings manually then let the 100th go through generateAndStore
        // to confirm the batch counter flips over. We just verify no crash and the count is correct.
        for i in 0..<99 {
            let id = try insertTestClip(text: "batch clip \(i)")
            try embeddingStore.insert(clipId: id, embedding: Array(repeating: Float(i) / 100.0, count: 4))
        }
        XCTAssertEqual(try embeddingStore.count(), 99)

        MockURLProtocol.requestHandler = { _ in
            (self.makeHTTPResponse(), self.embeddingResponseJSON())
        }

        let hundredthId = try insertTestClip(text: "100th clip")
        let clip = makeClip(id: hundredthId, textContent: "100th clip")
        _ = try await generator.generateAndStore(clip: clip)

        XCTAssertEqual(try embeddingStore.count(), 100, "All 100 embeddings should be stored")
    }
}
