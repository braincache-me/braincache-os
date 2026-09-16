import Foundation

/// Minimal OpenAI embeddings client — just enough to embed a single search
/// query so the CLI can compute cosine distances against `clip_embeddings`.
///
/// We don't reuse the app's `OpenAIClient` to keep the CLI lean and to avoid
/// dragging in the larger AI service surface. The endpoint and request body
/// match `OpenAIClient.embeddings(...)`.
enum EmbeddingClient {

    private static let endpoint = URL(string: "https://api.openai.com/v1/embeddings")!

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

        return vector.map { Float($0) }
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
