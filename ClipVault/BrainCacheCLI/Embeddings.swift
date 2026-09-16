import Foundation

/// Minimal OpenAI-compatible embeddings client — just enough to embed a single
/// search query so the CLI can compute cosine distances against
/// `clip_embeddings`.
///
/// We don't reuse the app's `OpenAIClient` to keep the CLI lean and to avoid
/// dragging in the larger AI service surface. The endpoint and request body
/// match `OpenAIClient.createEmbedding(...)`, including the base URL the app
/// has configured (Nebius Token Factory by default) and the same 256-dimension
/// truncation for models that ignore the `dimensions` parameter.
enum EmbeddingClient {

    private static var endpoint: URL {
        let base = BrainCacheConfig.aiBaseURL
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: trimmed + "/embeddings")
            ?? URL(string: BrainCacheConfig.nebiusBaseURL + "/embeddings")!
    }

    static func embed(query: String, model: String, dimensions: Int? = nil) throws -> [Float] {
        guard let apiKey = BrainCacheConfig.openAIAPIKey() else {
            throw CLIError.missingAPIKey
        }

        var body: [String: Any] = [
            "model": model,
            "input": query,
            "encoding_format": "float",
        ]
        if let dims = dimensions {
            body["dimensions"] = dims
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = resultError {
            throw CLIError.openAITransport(error)
        }

        guard let http = resultResponse as? HTTPURLResponse else {
            throw CLIError.openAIRequestFailed(status: -1, body: "no response")
        }

        if http.statusCode == 401 {
            throw CLIError.openAIUnauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = resultData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            throw CLIError.openAIRequestFailed(status: http.statusCode, body: body)
        }

        guard let data = resultData,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = json["data"] as? [[String: Any]],
              let first = array.first,
              let vector = first["embedding"] as? [Double] else {
            throw CLIError.openAIRequestFailed(status: http.statusCode, body: "unexpected response shape")
        }

        let floats = vector.map { Float($0) }
        guard let dimensions else { return floats }
        return conform(floats, to: dimensions)
    }

    /// Matryoshka truncation + L2 normalization, mirroring
    /// `EmbeddingVectorAdapter` in the app: Qwen3-Embedding returns its full
    /// 4096-dimension vector when the server ignores `dimensions`, and the
    /// stored vectors are 256-dimensional.
    static func conform(_ vector: [Float], to dimensions: Int) -> [Float] {
        guard dimensions > 0, vector.count > dimensions else { return vector }
        let truncated = Array(vector.prefix(dimensions))
        var sumSquares: Float = 0
        for value in truncated { sumSquares += value * value }
        let magnitude = sumSquares.squareRoot()
        guard magnitude > 0 else { return truncated }
        return truncated.map { $0 / magnitude }
    }
}

/// Cosine distance helpers matching `EmbeddingStore.swift`.
///
/// The app stores Float32 vectors as raw little-endian bytes via
/// `withUnsafeBufferPointer`. We decode the same way.
enum VectorMath {

    static func dataToFloats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }
    }

    static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
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
        return 1.0 - (dot / denom)
    }
}
