import Foundation

enum CLIError: Error, CustomStringConvertible {
    case databaseMissing(path: String)
    case activityRootNotConfigured
    case dateParseFailed(String)
    case missingAPIKey
    case openAIRequestFailed(status: Int, body: String)
    case openAIUnauthorized
    case openAITransport(Error)
    case invalidEmbeddingDimensions(expected: Int, got: Int)
    case invalidRegex(String, underlying: String)
    case unknownClip(Int64)

    var description: String {
        switch self {
        case .databaseMissing(let path):
            return """
            BrainCache database not found at:
              \(path)

            Has BrainCache been launched at least once on this Mac? If you're
            running a development build, pass --dev to point the CLI at
            ~/Library/Application Support/ClipVault-Dev/.
            """
        case .activityRootNotConfigured:
            return """
            Activity Capture has not been configured.

            Open BrainCache → Preferences → Activity Capture and enable it,
            then choose a folder for the activity logs.
            """
        case .dateParseFailed(let raw):
            return "Could not parse date '\(raw)'. Expected YYYY-MM-DD or an ISO-8601 datetime."
        case .missingAPIKey:
            return """
            No OpenAI API key found.

            Vector search and AI commands need a key. Either:
              1. Set OPENAI_API_KEY in your environment, or
              2. Configure it in BrainCache → Preferences → AI.
            """
        case .openAIRequestFailed(let status, let body):
            return "OpenAI request failed with HTTP \(status):\n\(body)"
        case .openAIUnauthorized:
            return "OpenAI rejected the API key (HTTP 401). Update the key in BrainCache → Preferences → AI."
        case .openAITransport(let error):
            return "Network error talking to OpenAI: \(error.localizedDescription)"
        case .invalidEmbeddingDimensions(let expected, let got):
            return """
            Embedding dimension mismatch: stored clips use \(expected)-dim vectors but the query
            returned \(got). Did the embedding model change in BrainCache Preferences?
            """
        case .invalidRegex(let pattern, let underlying):
            return "Invalid regular expression /\(pattern)/: \(underlying)"
        case .unknownClip(let id):
            return "No clip with id=\(id)."
        }
    }
}
