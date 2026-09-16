import Foundation
import GRDB

/// Stores and retrieves Float32 vector embeddings in the `clip_embeddings` table.
///
/// Embeddings are stored as raw-byte BLOBs (Float32 × dimensions, little-endian).
/// Vector similarity search is implemented as Swift-side brute-force cosine distance.
///
/// When sqlite-vector is loaded via VectorExtensionLoader, the `quantize()` and
/// `preloadQuantized()` methods will delegate to the SQL extension for SIMD-accelerated
/// approximate search. Until then they are no-ops and `findNearest` performs exact
/// linear scan — correct for all dataset sizes, fast enough for tens of thousands of clips.
final class EmbeddingStore {

    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - CRUD

    /// Inserts or replaces an embedding for the given clip ID.
    func insert(clipId: Int64, embedding: [Float], model: String = "text-embedding-3-small", dimensions: Int = 256) throws {
        let data = EmbeddingStore.floatsToData(embedding)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO clip_embeddings (clip_id, embedding, model, dimensions)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [clipId, data, model, dimensions]
            )
        }
    }

    /// Returns the stored embedding for the given clip, or nil if none exists.
    func fetchEmbedding(clipId: Int64) throws -> [Float]? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT embedding FROM clip_embeddings WHERE clip_id = ?",
                arguments: [clipId]
            ) else { return nil }
            guard let data = row["embedding"] as? Data else { return nil }
            return EmbeddingStore.dataToFloats(data)
        }
    }

    /// Explicitly deletes the embedding for a clip (also removed automatically by CASCADE).
    func deleteEmbedding(clipId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM clip_embeddings WHERE clip_id = ?",
                arguments: [clipId]
            )
        }
    }

    /// Returns the total number of stored embeddings.
    func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clip_embeddings") ?? 0
        }
    }

    // MARK: - Vector Search

    /// Returns the topK clip IDs closest to `queryEmbedding` by cosine distance (ascending).
    ///
    /// Uses brute-force linear scan with Swift-side dot-product arithmetic.
    /// When sqlite-vector is active this will be replaced by `vector_quantize_scan`
    /// for O(1) approximate search via quantized in-memory index.
    func findNearest(to queryEmbedding: [Float], topK: Int) throws -> [(clipId: Int64, distance: Float)] {
        let rows = try dbQueue.read { db -> [(Int64, Data)] in
            let fetched = try Row.fetchAll(db, sql: "SELECT clip_id, embedding FROM clip_embeddings")
            return fetched.compactMap { row -> (Int64, Data)? in
                guard let clipId = row["clip_id"] as? Int64,
                      let data = row["embedding"] as? Data else { return nil }
                return (clipId, data)
            }
        }

        let results: [(Int64, Float)] = rows.map { (clipId, data) in
            let vec = EmbeddingStore.dataToFloats(data)
            return (clipId, cosineDistance(queryEmbedding, vec))
        }
        .sorted { $0.1 < $1.1 }

        return Array(results.prefix(topK)).map { (clipId: $0.0, distance: $0.1) }
    }

    // MARK: - Quantization Lifecycle

    /// Called after `quantize()` completes. Useful for testing.
    var onQuantize: (() -> Void)?
    /// Called after `preloadQuantized()` completes. Useful for testing.
    var onPreload: (() -> Void)?

    /// Rebuilds the sqlite-vector quantization index after bulk inserts or deletes.
    /// No-op until sqlite-vector is linked; EmbeddingStore.findNearest uses exact search.
    func quantize() {
        // Uncomment when sqlite-vector is loaded:
        // try? dbQueue.write { db in
        //     try db.execute(sql: "SELECT vector_quantize('clip_embeddings', 'embedding')")
        // }
        onQuantize?()
    }

    /// Preloads the quantized vector index into memory for 4-5× faster approximate search.
    /// No-op until sqlite-vector is linked.
    func preloadQuantized() {
        // Uncomment when sqlite-vector is loaded:
        // try? dbQueue.read { db in
        //     try db.execute(sql: "SELECT vector_quantize_preload('clip_embeddings', 'embedding')")
        // }
        onPreload?()
    }

    // MARK: - Float ↔ Data Encoding

    /// Encodes a Float32 array as a raw-byte Data blob (platform byte order, same as sqlite-vector).
    static func floatsToData(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decodes a raw-byte Data blob back into a Float32 array.
    static func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    // MARK: - Private

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1.0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot   += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 1.0 }
        return 1.0 - (dot / denom)   // cosine distance: 0 = identical, 2 = opposite
    }
}
