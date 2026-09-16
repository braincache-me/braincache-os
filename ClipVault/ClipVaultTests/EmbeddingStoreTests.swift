import XCTest
import GRDB
@testable import ClipVault

// MARK: - Migration v4 Tests

final class MigrationV4Tests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)
    }

    // MARK: - Schema verification

    func testV4ColumnsExistOnClipsTable() throws {
        try dbQueue.read { db in
            // Verify new columns were added by migration v4
            let columns = try db.columns(in: "clips").map { $0.name }
            XCTAssertTrue(columns.contains("tags"), "clips table must have tags column")
            XCTAssertTrue(columns.contains("image_description"), "clips table must have image_description column")
            XCTAssertTrue(columns.contains("ai_processed"), "clips table must have ai_processed column")
            XCTAssertTrue(columns.contains("ai_processed_at"), "clips table must have ai_processed_at column")
        }
    }

    func testClipEmbeddingsTableExists() throws {
        try dbQueue.read { db in
            let exists = try db.tableExists("clip_embeddings")
            XCTAssertTrue(exists, "clip_embeddings table must be created by migration v4")
        }
    }

    func testClipEmbeddingsColumnsCorrect() throws {
        try dbQueue.read { db in
            let columns = try db.columns(in: "clip_embeddings").map { $0.name }
            XCTAssertTrue(columns.contains("clip_id"))
            XCTAssertTrue(columns.contains("embedding"))
            XCTAssertTrue(columns.contains("model"))
            XCTAssertTrue(columns.contains("dimensions"))
        }
    }

    func testAiProcessedDefaultsToZero() throws {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: "hello",
            dataHash: Hashing.sha256(data: "hello".data(using: .utf8)!),
            byteSize: 5,
            createdAt: Date()
        )
        let id = try store.insert(entry: entry)
        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.id, id)
        XCTAssertEqual(records.first?.aiProcessed, 0)
        XCTAssertNil(records.first?.tags)
        XCTAssertNil(records.first?.imageDescription)
        XCTAssertNil(records.first?.aiProcessedAt)
    }

    // MARK: - FTS5 rebuild

    func testFTSSearchStillWorksAfterV4Rebuild() throws {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: "unique banana mango text",
            dataHash: Hashing.sha256(data: "unique banana mango text".data(using: .utf8)!),
            byteSize: 24,
            createdAt: Date()
        )
        try store.insert(entry: entry)

        let results = try store.search(query: "banana", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].textContent, "unique banana mango text")
    }

    func testFTSIndexesImageDescriptionAfterUpdate() throws {
        let entry = ClipboardEntry(
            contentType: .image,
            textContent: nil,
            dataHash: Hashing.sha256(data: "fake-image-data".data(using: .utf8)!),
            byteSize: 15,
            createdAt: Date()
        )
        let id = try store.insert(entry: entry)

        // Set an image description via markProcessed
        try store.markProcessed(id: id, tags: nil, imageDescription: "a beautiful sunset over the ocean")

        // FTS should now find the clip via its image description
        let results = try store.search(query: "sunset", limit: 10)
        XCTAssertEqual(results.count, 1, "Image description should be indexed in FTS after markProcessed")
    }

    func testFTSTriggerInsertIncludesImageDescription() throws {
        // Insert a clip that already has an imageDescription (simulating a future direct insert)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO clips
                        (content_type, data_hash, byte_size, created_at, is_pinned, is_indexed,
                         text_content, image_description, ai_processed)
                    VALUES
                        ('image', 'hashXYZ', 100, \(Date().timeIntervalSince1970), 0, 1,
                         NULL, 'diagram showing system architecture', 0)
                """
            )
        }

        let results = try store.search(query: "architecture", limit: 10)
        XCTAssertEqual(results.count, 1, "Clips with image_description should be found by FTS search")
    }

    func testFTSTriggerDeleteCleansUpBothColumns() throws {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: "deletable entry with uniqueword99",
            dataHash: Hashing.sha256(data: "deletable entry with uniqueword99".data(using: .utf8)!),
            byteSize: 33,
            createdAt: Date()
        )
        let id = try store.insert(entry: entry)
        var results = try store.search(query: "uniqueword99", limit: 10)
        XCTAssertEqual(results.count, 1)

        try store.deleteById(id)
        results = try store.search(query: "uniqueword99", limit: 10)
        XCTAssertEqual(results.count, 0, "Deleted clip must be removed from FTS index")
    }
}

// MARK: - EmbeddingStore Tests

final class EmbeddingStoreTests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var embeddingStore: EmbeddingStore!
    var clipStore: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        embeddingStore = EmbeddingStore(dbQueue: dbQueue)
        clipStore = ClipStore(dbQueue: dbQueue)
    }

    // MARK: - Float ↔ Data encoding

    func testFloatsToDataRoundtrip() {
        let original: [Float] = [1.0, -0.5, 0.25, 0.0, 3.14]
        let data = EmbeddingStore.floatsToData(original)
        let restored = EmbeddingStore.dataToFloats(data)
        XCTAssertEqual(original, restored)
    }

    func testFloatDataSize() {
        let floats = Array(repeating: Float(1.0), count: 256)
        let data = EmbeddingStore.floatsToData(floats)
        XCTAssertEqual(data.count, 256 * 4, "256 Float32 values should occupy 1024 bytes")
    }

    func testEmptyFloatArrayRoundtrip() {
        let data = EmbeddingStore.floatsToData([])
        let restored = EmbeddingStore.dataToFloats(data)
        XCTAssertEqual(restored, [])
    }

    // MARK: - Insert / Fetch / Delete

    func testInsertAndFetchRoundtrip() throws {
        let clipId = try insertTestClip(text: "for embedding")
        let embedding: [Float] = (0..<256).map { Float($0) / 256.0 }
        try embeddingStore.insert(clipId: clipId, embedding: embedding)

        let fetched = try embeddingStore.fetchEmbedding(clipId: clipId)
        let fetchedVec = try XCTUnwrap(fetched)
        XCTAssertEqual(fetchedVec.count, 256)
        XCTAssertEqual(fetchedVec.first!, embedding.first!, accuracy: 1e-6)
        XCTAssertEqual(fetchedVec.last!, embedding.last!, accuracy: 1e-6)
    }

    func testFetchNonExistentReturnsNil() throws {
        let result = try embeddingStore.fetchEmbedding(clipId: 9999)
        XCTAssertNil(result)
    }

    func testDeleteEmbedding() throws {
        let clipId = try insertTestClip(text: "to delete embedding")
        try embeddingStore.insert(clipId: clipId, embedding: [0.1, 0.2, 0.3])

        XCTAssertNotNil(try embeddingStore.fetchEmbedding(clipId: clipId))
        try embeddingStore.deleteEmbedding(clipId: clipId)
        XCTAssertNil(try embeddingStore.fetchEmbedding(clipId: clipId))
    }

    func testInsertOrReplaceUpdatesExisting() throws {
        let clipId = try insertTestClip(text: "replace test")
        let first: [Float] = [1.0, 0.0, 0.0]
        let second: [Float] = [0.0, 1.0, 0.0]

        try embeddingStore.insert(clipId: clipId, embedding: first)
        try embeddingStore.insert(clipId: clipId, embedding: second)

        let fetched = try embeddingStore.fetchEmbedding(clipId: clipId)
        XCTAssertEqual(fetched?[0] ?? 99, 0.0, accuracy: 1e-6, "Should be replaced with second embedding")
        XCTAssertEqual(fetched?[1] ?? 99, 1.0, accuracy: 1e-6)
    }

    // MARK: - Count

    func testCountReturnsZeroInitially() throws {
        XCTAssertEqual(try embeddingStore.count(), 0)
    }

    func testCountIncreasesAfterInsert() throws {
        let id1 = try insertTestClip(text: "count test 1")
        let id2 = try insertTestClip(text: "count test 2")
        try embeddingStore.insert(clipId: id1, embedding: [1.0])
        try embeddingStore.insert(clipId: id2, embedding: [2.0])
        XCTAssertEqual(try embeddingStore.count(), 2)
    }

    // MARK: - CASCADE delete

    func testCascadeDeleteRemovesEmbeddingWhenClipDeleted() throws {
        let clipId = try insertTestClip(text: "cascade delete test")
        try embeddingStore.insert(clipId: clipId, embedding: [0.5, 0.5])

        XCTAssertEqual(try embeddingStore.count(), 1)
        try clipStore.deleteById(clipId)
        XCTAssertEqual(try embeddingStore.count(), 0, "Embedding must be cascade-deleted with clip")
    }

    // MARK: - findNearest (cosine similarity)

    func testFindNearestReturnsClosestVector() throws {
        let id1 = try insertTestClip(text: "vec a")
        let id2 = try insertTestClip(text: "vec b")
        let id3 = try insertTestClip(text: "vec c")

        // Three unit vectors: right, up, diagonal
        try embeddingStore.insert(clipId: id1, embedding: [1.0, 0.0])   // points right
        try embeddingStore.insert(clipId: id2, embedding: [0.0, 1.0])   // points up
        try embeddingStore.insert(clipId: id3, embedding: [1.0, 1.0])   // diagonal

        // Query pointing right — id1 should be nearest (distance ~0)
        let results = try embeddingStore.findNearest(to: [1.0, 0.0], topK: 3)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results[0].clipId, id1, "Vector [1,0] must be closest to query [1,0]")
        XCTAssertLessThan(results[0].distance, 0.01, "Distance to identical vector must be near 0")
    }

    func testFindNearestRespectTopK() throws {
        for i in 0..<5 {
            let id = try insertTestClip(text: "topk \(i)")
            try embeddingStore.insert(clipId: id, embedding: [Float(i), Float(i)])
        }
        let results = try embeddingStore.findNearest(to: [1.0, 0.0], topK: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testFindNearestReturnsEmptyWhenNoEmbeddings() throws {
        let results = try embeddingStore.findNearest(to: [1.0, 0.0], topK: 10)
        XCTAssertEqual(results.count, 0)
    }

    func testFindNearestSortedByDistanceAscending() throws {
        let id1 = try insertTestClip(text: "sorted a")
        let id2 = try insertTestClip(text: "sorted b")
        let id3 = try insertTestClip(text: "sorted c")

        try embeddingStore.insert(clipId: id1, embedding: [1.0, 0.0])
        try embeddingStore.insert(clipId: id2, embedding: [0.0, 1.0])
        try embeddingStore.insert(clipId: id3, embedding: [-1.0, 0.0])

        let results = try embeddingStore.findNearest(to: [1.0, 0.0], topK: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertLessThanOrEqual(results[0].distance, results[1].distance)
        XCTAssertLessThanOrEqual(results[1].distance, results[2].distance)
        // Opposite vector should have the largest distance (~2.0)
        XCTAssertEqual(results[2].clipId, id3)
    }

    // MARK: - No-op stubs

    func testQuantizeDoesNotCrash() {
        embeddingStore.quantize()  // must not throw or crash
    }

    func testPreloadQuantizedDoesNotCrash() {
        embeddingStore.preloadQuantized()  // must not throw or crash
    }

    // MARK: - Helpers

    private func insertTestClip(text: String) throws -> Int64 {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            byteSize: text.utf8.count,
            createdAt: Date()
        )
        return try clipStore.insert(entry: entry)
    }
}

// MARK: - ClipStore AI Processing Method Tests

final class ClipStoreAITests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)
    }

    private func insertClip(text: String) throws -> Int64 {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            byteSize: text.utf8.count,
            createdAt: Date()
        )
        return try store.insert(entry: entry)
    }

    // MARK: - fetchUnprocessed

    func testFetchUnprocessedReturnsNewClips() throws {
        try insertClip(text: "unprocessed clip")
        let unprocessed = try store.fetchUnprocessed(limit: 10)
        XCTAssertEqual(unprocessed.count, 1)
        XCTAssertEqual(unprocessed[0].aiProcessed, 0)
    }

    func testFetchUnprocessedExcludesProcessedClips() throws {
        let id1 = try insertClip(text: "processed clip")
        try insertClip(text: "unprocessed clip")
        try store.markProcessed(id: id1, tags: "[\"code\"]", imageDescription: nil)

        let unprocessed = try store.fetchUnprocessed(limit: 10)
        XCTAssertEqual(unprocessed.count, 1)
        XCTAssertEqual(unprocessed[0].textContent, "unprocessed clip")
    }

    func testFetchUnprocessedExcludesFailedClips() throws {
        let id = try insertClip(text: "failed clip")
        try store.markFailed(id: id)

        let unprocessed = try store.fetchUnprocessed(limit: 10)
        XCTAssertEqual(unprocessed.count, 0, "Failed clips (ai_processed=2) must not appear in fetchUnprocessed")
    }

    func testFetchUnprocessedRespectsLimit() throws {
        for i in 0..<10 {
            try insertClip(text: "clip \(i)")
        }
        let unprocessed = try store.fetchUnprocessed(limit: 3)
        XCTAssertEqual(unprocessed.count, 3)
    }

    func testFetchUnprocessedEmptyStoreReturnsEmpty() throws {
        let unprocessed = try store.fetchUnprocessed(limit: 10)
        XCTAssertEqual(unprocessed.count, 0)
    }

    // MARK: - markProcessed

    func testMarkProcessedSetsAiProcessed1() throws {
        let id = try insertClip(text: "to process")
        try store.markProcessed(id: id, tags: nil, imageDescription: nil)

        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.aiProcessed, 1)
    }

    func testMarkProcessedSavesTags() throws {
        let id = try insertClip(text: "swift code snippet")
        try store.markProcessed(id: id, tags: "[\"code\",\"code:swift\"]", imageDescription: nil)

        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.tags, "[\"code\",\"code:swift\"]")
    }

    func testMarkProcessedSavesImageDescription() throws {
        let id = try insertClip(text: nil)  // image clip
        try store.markProcessed(id: id, tags: "[\"screenshot\"]", imageDescription: "screenshot of Xcode IDE")

        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.imageDescription, "screenshot of Xcode IDE")
    }

    func testMarkProcessedSetsTimestamp() throws {
        let before = Date().timeIntervalSince1970
        let id = try insertClip(text: "timestamp test")
        try store.markProcessed(id: id, tags: nil, imageDescription: nil)
        let after = Date().timeIntervalSince1970

        let records = try store.fetchRecent(limit: 1)
        let ts = records.first?.aiProcessedAt
        XCTAssertNotNil(ts)
        XCTAssertGreaterThanOrEqual(ts!, before)
        XCTAssertLessThanOrEqual(ts!, after)
    }

    // MARK: - markFailed

    func testMarkFailedSetsAiProcessed2() throws {
        let id = try insertClip(text: "will fail")
        try store.markFailed(id: id)

        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.aiProcessed, 2)
    }

    func testMarkFailedSetsTimestamp() throws {
        let before = Date().timeIntervalSince1970
        let id = try insertClip(text: "fail timestamp")
        try store.markFailed(id: id)
        let after = Date().timeIntervalSince1970

        let records = try store.fetchRecent(limit: 1)
        let ts = records.first?.aiProcessedAt
        XCTAssertNotNil(ts)
        XCTAssertGreaterThanOrEqual(ts!, before)
        XCTAssertLessThanOrEqual(ts!, after)
    }

    func testMarkFailedDoesNotClearTags() throws {
        let id = try insertClip(text: "partial process")
        try store.markProcessed(id: id, tags: "[\"code\"]", imageDescription: nil)
        // Simulate a re-processing failure (shouldn't clear existing tags)
        try store.markFailed(id: id)

        let records = try store.fetchRecent(limit: 1)
        XCTAssertEqual(records.first?.aiProcessed, 2)
        // Tags set by markProcessed should still be there (markFailed only updates status/timestamp)
        XCTAssertEqual(records.first?.tags, "[\"code\"]")
    }

    // MARK: - ClipRecord default values

    func testClipRecordAIFieldsDefaultToUnprocessed() throws {
        // Verify newly inserted clips have default AI field values
        let id = try insertClip(text: "defaults check")
        let records = try store.fetchRecent(limit: 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.aiProcessed, 0)
        XCTAssertNil(record.tags)
        XCTAssertNil(record.imageDescription)
        XCTAssertNil(record.aiProcessedAt)
    }

    // MARK: - Helper for image clip

    private func insertClip(text: String?) throws -> Int64 {
        let data = text ?? "fake-image-bytes"
        let hash = Hashing.sha256(data: data.data(using: .utf8)!)
        let entry = ClipboardEntry(
            contentType: text == nil ? .image : .text,
            textContent: text,
            dataHash: hash,
            byteSize: data.utf8.count,
            createdAt: Date()
        )
        return try store.insert(entry: entry)
    }
}
