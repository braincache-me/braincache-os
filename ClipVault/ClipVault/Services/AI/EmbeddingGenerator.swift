import Foundation

/// Generates a 256-dimensional vector embedding for a clipboard clip using the
/// `text-embedding-3-small` model and stores it in `EmbeddingStore`.
///
/// Input to the embedding is built by concatenating:
///   tags | imageDescription | textContent
///
/// Tags come first so they anchor the semantic space; total input is truncated to
/// ~32,000 characters (~8,000 tokens, conservative estimate) before sending.
final class EmbeddingGenerator {

    static let model = "text-embedding-3-small"  // fallback; runtime reads Settings.shared.embeddingModel
    static let dimensions = 256
    /// Conservative char limit: 8,000 tokens × 4 chars/token = 32,000 chars.
    static let maxInputChars = 32_000

    let client: OpenAIClient
    private let embeddingStore: EmbeddingStore

    private var insertCountSinceBatchQuantize = 0
    static let quantizeBatchSize = 100

    init(client: OpenAIClient = .shared, embeddingStore: EmbeddingStore) {
        self.client = client
        self.embeddingStore = embeddingStore
    }

    // MARK: - Public API

    /// Generates an embedding for `clip`, stores it, and returns the Float32 vector.
    ///
    /// After every `quantizeBatchSize` inserts, calls `EmbeddingStore.quantize()` to
    /// rebuild the quantization index for fast approximate search.
    ///
    /// - Throws: `OpenAIError.apiKeyMissing` when no key is configured; rethrows any
    ///   network or decoding errors from `OpenAIClient`.
    @discardableResult
    func generateAndStore(clip: ClipRecord) async throws -> [Float] {
        guard let clipId = clip.id else {
            throw EmbeddingError.missingClipId
        }

        let input = buildInputString(clip: clip)
        let response = try await client.createEmbedding(
            model: Settings.shared.embeddingModel,
            input: input,
            dimensions: Self.dimensions,
            usageCategory: .indexing
        )

        guard let embeddingData = response.data.first else {
            throw OpenAIError.noEmbedding
        }

        let vector = embeddingData.embedding
        try embeddingStore.insert(
            clipId: clipId,
            embedding: vector,
            model: Settings.shared.embeddingModel,
            dimensions: Self.dimensions
        )

        insertCountSinceBatchQuantize += 1
        if insertCountSinceBatchQuantize >= Self.quantizeBatchSize {
            embeddingStore.quantize()
            insertCountSinceBatchQuantize = 0
        }

        return vector
    }

    // MARK: - Query Embedding (without storage)

    /// Embeds a raw query string for semantic search — does NOT store the result.
    ///
    /// Used by `VectorSearchEngine` to convert user queries into vectors for
    /// similarity comparison against stored clip embeddings.
    func embedQuery(_ text: String) async throws -> [Float] {
        let truncated = truncate(text, to: Self.maxInputChars)
        let response = try await client.createEmbedding(
            model: Settings.shared.embeddingModel,
            input: truncated,
            dimensions: Self.dimensions,
            usageCategory: .chat
        )
        guard let embeddingData = response.data.first else {
            throw OpenAIError.noEmbedding
        }
        return embeddingData.embedding
    }

    // MARK: - Input String Construction

    /// Builds the text input for the embedding model.
    ///
    /// Format: `tags | imageDescription | textContent`
    /// If all components are empty, returns an empty string.
    func buildInputString(clip: ClipRecord) -> String {
        let tagsString: String
        if let tagsJSON = clip.tags,
           let data = tagsJSON.data(using: .utf8),
           let tagArray = try? JSONSerialization.jsonObject(with: data) as? [String] {
            tagsString = tagArray.joined(separator: ", ")
        } else {
            tagsString = ""
        }

        let descriptionString = clip.imageDescription ?? ""
        let rawText = clip.textContent ?? ""
        let isHTML = clip.contentType == ClipboardContentType.html.rawValue
        let textString = isHTML ? rawText.strippingHTMLTags : rawText

        let parts = [tagsString, descriptionString, textString]
        let joined = parts.joined(separator: " | ")

        return truncate(joined, to: Self.maxInputChars)
    }

    // MARK: - Helpers

    /// Truncates `text` to `maxLength` characters, appending "…[truncated]" when cut.
    func truncate(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end]) + "…[truncated]"
    }
}

// MARK: - Errors

enum EmbeddingError: Error {
    case missingClipId
}
