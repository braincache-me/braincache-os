import Foundation

/// Makes an embedding response fit BrainCache's fixed 256-dimension storage.
///
/// OpenAI honours the `dimensions` request parameter natively. Token Factory's
/// default embedding model (`Qwen/Qwen3-Embedding-8B`) is a 4096-dimension
/// model that supports Matryoshka truncation: the request still asks for 256
/// dimensions, but if the server returns the full vector we truncate to the
/// first 256 values and re-normalize to unit length ourselves — otherwise the
/// cosine distances stored in `clip_embeddings` would be meaningless.
enum EmbeddingVectorAdapter {

    /// Truncates `vector` to `dimensions` values and L2-normalizes the result.
    ///
    /// Vectors already at (or below) the requested size are returned unchanged:
    /// a shorter vector cannot be padded meaningfully, and a provider that
    /// honoured `dimensions` has already normalized its output.
    static func conform(_ vector: [Float], to dimensions: Int) -> [Float] {
        guard dimensions > 0, vector.count > dimensions else { return vector }
        return normalize(Array(vector.prefix(dimensions)))
    }

    /// Scales `vector` to unit length. A zero vector is returned unchanged.
    static func normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for value in vector { sumSquares += value * value }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// Applies `conform(_:to:)` to every vector in an embeddings response.
    static func conform(_ response: EmbeddingResponse, to dimensions: Int) -> EmbeddingResponse {
        let adapted = response.data.map {
            EmbeddingResponse.EmbeddingData(
                embedding: conform($0.embedding, to: dimensions),
                index: $0.index
            )
        }
        return EmbeddingResponse(data: adapted, usage: response.usage)
    }
}
