import Foundation
import GRDB

// MARK: - Hybrid Search Result

/// A single result from `hybridSearchWithFlags`, carrying a semantic-only flag so the
/// UI can mark clips that were found via vector similarity but not via FTS5 keyword match.
struct HybridSearchResult {
    /// The clip's database ID.
    let clipId: Int64
    /// True when this clip appeared in the vector results but NOT in the FTS5 results —
    /// meaning it was retrieved semantically rather than by keyword.
    let isSemanticOnly: Bool
}

// MARK: - Search Filter

/// Restricts vector/hybrid search results to clips matching specific attributes.
struct SearchFilter {
    var contentType: String? = nil
    var sourceApp: String? = nil
}

// MARK: - VectorSearchEngine

/// Performs semantic search over clip embeddings.
///
/// Two search modes:
///   - `search(query:topK:)` — pure vector similarity using exact cosine brute-force
///     (delegates to `EmbeddingStore.findNearest`; will use `vector_quantize_scan` when
///     sqlite-vector is linked).
///   - `hybridSearch(query:topK:)` — combines FTS5 keyword ranks with vector similarity
///     via Reciprocal Rank Fusion (RRF, k=60) so keyword matches are boosted while
///     semantic matches fill conceptual gaps.
///
/// Call `preloadQuantized()` at app launch (after the indexing pipeline has run) to load
/// the quantized vector index into memory for 4-5× faster approximate search once
/// sqlite-vector is linked.
final class VectorSearchEngine {

    // MARK: - Shared Instance

    static let shared = VectorSearchEngine(
        clipStore: ClipStore(dbQueue: DatabaseManager.shared.dbQueue),
        embeddingStore: EmbeddingStore(dbQueue: DatabaseManager.shared.dbQueue),
        client: .shared
    )

    // MARK: - Dependencies

    private let clipStore: ClipStore
    private let embeddingStore: EmbeddingStore
    private let embeddingGenerator: EmbeddingGenerator

    /// RRF rank fusion constant — standard value from the original RRF paper.
    static let rrfK: Int = 60

    // MARK: - Init

    init(clipStore: ClipStore, embeddingStore: EmbeddingStore, client: OpenAIClient = .shared) {
        self.clipStore = clipStore
        self.embeddingStore = embeddingStore
        self.embeddingGenerator = EmbeddingGenerator(client: client, embeddingStore: embeddingStore)
    }

    // MARK: - Pure Vector Search

    /// Embeds `query` and returns the topK nearest clip IDs sorted by cosine distance (ascending).
    ///
    /// Uses `EmbeddingStore.findNearest` for exact cosine brute-force. When sqlite-vector is
    /// linked, this will switch to `vector_quantize_scan` for fast approximate search.
    ///
    /// - Parameters:
    ///   - query: Natural language query string.
    ///   - topK: Maximum number of results to return.
    /// - Returns: Array of `(clipId, distance)` sorted by distance ascending (0 = identical, 2 = opposite).
    func search(query: String, topK: Int = 10) async throws -> [(clipId: Int64, distance: Float)] {
        let queryEmbedding = try await embeddingGenerator.embedQuery(query)
        return try embeddingStore.findNearest(to: queryEmbedding, topK: topK)
    }

    // MARK: - Hybrid Search (RRF)

    /// Runs FTS5 keyword search and vector similarity search in parallel, then merges results
    /// using Reciprocal Rank Fusion (RRF): `score = Σ 1/(k + rank_i)` with k=60.
    ///
    /// Exact keyword matches are boosted while semantic matches fill gaps for concepts not
    /// present in the literal text.
    ///
    /// - Parameters:
    ///   - query: Natural language / keyword query string.
    ///   - topK: Maximum number of results to return (applied after fusion).
    /// - Returns: Clip IDs sorted by descending fused RRF score (best first).
    func hybridSearch(query: String, topK: Int = 10) async throws -> [Int64] {
        // Run FTS5 and vector search concurrently.
        async let ftsTask = Task { try clipStore.search(query: query, limit: topK * 2) }.value
        async let vectorTask = search(query: query, topK: topK * 2)

        let ftsClips = try await ftsTask
        let vectorResults = try await vectorTask

        let ftsIds = ftsClips.compactMap { $0.id }
        let vectorIds = vectorResults.map { $0.clipId }

        return reciprocalRankFusion(ftsRanks: ftsIds, vectorRanks: vectorIds, topK: topK)
    }

    /// Hybrid search restricted to clips matching `filter` (e.g. only audio transcripts).
    ///
    /// FTS results are post-filtered in-memory by source_app/content_type; vector results go
    /// through `filteredSearch` which applies the filter at SQL level.
    func hybridSearch(query: String, topK: Int = 10, filter: SearchFilter) async throws -> [Int64] {
        async let ftsTask = Task { try clipStore.search(query: query, limit: topK * 4) }.value
        async let vectorTask = filteredSearch(query: query, filter: filter, topK: topK * 2)

        let ftsClips = try await ftsTask
        let vectorResults = try await vectorTask

        let filteredFtsClips = ftsClips.filter { clip in
            if let sourceApp = filter.sourceApp, clip.sourceApp != sourceApp { return false }
            if let contentType = filter.contentType, clip.contentType != contentType { return false }
            return true
        }

        let ftsIds = Array(filteredFtsClips.compactMap { $0.id }.prefix(topK * 2))
        let vectorIds = vectorResults.map { $0.clipId }

        return reciprocalRankFusion(ftsRanks: ftsIds, vectorRanks: vectorIds, topK: topK)
    }

    // MARK: - Hybrid Search with Semantic Flags

    /// Runs FTS5 keyword search and vector similarity search in parallel, then merges results
    /// using Reciprocal Rank Fusion (RRF). Each result is annotated with `isSemanticOnly`:
    /// true when the clip was found by the vector search but did NOT appear in the FTS5 results.
    ///
    /// - Parameters:
    ///   - query: Natural language / keyword query string.
    ///   - topK: Maximum number of results to return (applied after fusion).
    /// - Returns: Array of `HybridSearchResult` sorted by descending fused RRF score (best first).
    func hybridSearchWithFlags(query: String, topK: Int = 10) async throws -> [HybridSearchResult] {
        async let ftsTask = Task { try clipStore.search(query: query, limit: topK * 2) }.value
        async let vectorTask = search(query: query, topK: topK * 2)

        let ftsClips = try await ftsTask
        let vectorResults = try await vectorTask

        let ftsIds = ftsClips.compactMap { $0.id }
        let vectorIds = vectorResults.map { $0.clipId }
        let ftsIdSet = Set(ftsIds)

        let mergedIds = reciprocalRankFusion(ftsRanks: ftsIds, vectorRanks: vectorIds, topK: topK)

        return mergedIds.map { id in
            HybridSearchResult(clipId: id, isSemanticOnly: !ftsIdSet.contains(id))
        }
    }

    // MARK: - Filtered Search

    /// Vector similarity search with attribute filtering (content type, source app, etc.).
    ///
    /// Retrieves a wide candidate pool via `findNearest`, then filters in SQL using a JOIN.
    /// This is exact-equivalent to what sqlite-vector's composable streaming scan will do once
    /// the extension is linked:
    /// ```sql
    /// SELECT ... JOIN vector_quantize_scan(...) AS v ...
    ///            JOIN clips AS c ON e.clip_id = c.id WHERE c.content_type = ? LIMIT topK
    /// ```
    ///
    /// - Parameters:
    ///   - query: Natural language query string.
    ///   - filter: `SearchFilter` restricting by content type or source app.
    ///   - topK: Maximum results after filtering.
    /// - Returns: Filtered clip IDs sorted by cosine distance ascending.
    func filteredSearch(query: String, filter: SearchFilter, topK: Int = 10) async throws -> [(clipId: Int64, distance: Float)] {
        // Fetch a wider candidate pool so post-filtering can still return topK results.
        let candidates = try await search(query: query, topK: topK * 10)
        guard !candidates.isEmpty else { return [] }

        let candidateIds = candidates.map { $0.clipId }
        var distanceMap: [Int64: Float] = [:]
        for result in candidates { distanceMap[result.clipId] = result.distance }

        // Apply SQL-level attribute filters on the candidate clip IDs.
        let filteredIds = try await embeddingStore.dbQueue.read { db -> [Int64] in
            var conditions: [String] = [
                "c.id IN (\(candidateIds.map { _ in "?" }.joined(separator: ", ")))"
            ]
            var args: [DatabaseValueConvertible] = candidateIds.map { $0 as DatabaseValueConvertible }

            if let contentType = filter.contentType {
                conditions.append("c.content_type = ?")
                args.append(contentType)
            }
            if let sourceApp = filter.sourceApp {
                conditions.append("c.source_app = ?")
                args.append(sourceApp)
            }

            let sql = "SELECT c.id FROM clips AS c WHERE \(conditions.joined(separator: " AND "))"
            return try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }

        return filteredIds
            .compactMap { id in distanceMap[id].map { (clipId: id, distance: $0) } }
            .sorted { $0.distance < $1.distance }
            .prefix(topK)
            .map { $0 }
    }

    // MARK: - searchWithFilter (named alias for filteredSearch — used by AgenticRAGEngine)

    /// Semantic search with attribute filtering. Alias for `filteredSearch` with the same
    /// semantics: fetches a wide candidate pool then applies SQL-level attribute filters.
    ///
    /// - Parameters:
    ///   - query: Natural language query string.
    ///   - filter: `SearchFilter` restricting by content type or source app.
    ///   - topK: Maximum results after filtering.
    /// - Returns: Filtered clip IDs sorted by cosine distance ascending.
    func searchWithFilter(query: String, filter: SearchFilter, topK: Int = 10) async throws -> [(clipId: Int64, distance: Float)] {
        try await filteredSearch(query: query, filter: filter, topK: topK)
    }

    // MARK: - Preload

    /// Preloads the quantized vector index into memory for faster approximate search.
    /// No-op until sqlite-vector is linked; delegates to EmbeddingStore.
    func preloadQuantized() {
        embeddingStore.preloadQuantized()
    }

    // MARK: - RRF (internal, testable)

    /// Merges two ranked lists using Reciprocal Rank Fusion.
    ///
    /// Score: `Σ 1 / (k + rank_i)` where rank is 1-based.
    /// Items that appear in only one list still receive their partial score.
    ///
    /// - Parameters:
    ///   - ftsRanks: Clip IDs in FTS rank order (best first).
    ///   - vectorRanks: Clip IDs in vector distance order (closest first).
    ///   - topK: How many top results to return.
    func reciprocalRankFusion(ftsRanks: [Int64], vectorRanks: [Int64], topK: Int) -> [Int64] {
        var scores: [Int64: Double] = [:]

        for (rank, clipId) in ftsRanks.enumerated() {
            scores[clipId, default: 0] += 1.0 / Double(Self.rrfK + rank + 1)
        }
        for (rank, clipId) in vectorRanks.enumerated() {
            scores[clipId, default: 0] += 1.0 / Double(Self.rrfK + rank + 1)
        }

        return scores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .map { $0.key }
    }
}
