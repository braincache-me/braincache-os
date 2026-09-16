import Foundation
import os

/// Recovers from a wrong omni model ID.
///
/// `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning` is the ID BrainCache ships
/// as the default for image description and chunked voice transcription, but
/// Token Factory occasionally renames model revisions. When a request fails
/// with a model-not-found style error, this resolver asks `GET /models` for the
/// live catalogue, picks the first ID containing "omni", persists it into
/// whichever Settings slot was pointing at the bad ID, and lets the caller
/// retry once.
enum OmniModelResolver {

    private static let logger = Logger(subsystem: "com.braincache.ai", category: "omni-resolver")

    /// True when `error` looks like "that model doesn't exist", as opposed to a
    /// transport, auth or rate-limit failure.
    static func isModelNotFound(_ error: Error) -> Bool {
        guard case OpenAIError.httpError(let status, let message) = error else { return false }
        guard status == 400 || status == 404 else { return false }
        let lower = message.lowercased()
        return lower.contains("model")
            && (lower.contains("not found")
                || lower.contains("does not exist")
                || lower.contains("unknown")
                || lower.contains("invalid"))
    }

    /// Picks the first ID that looks like an omni model, case-insensitively.
    static func firstOmniModel(in models: [String]) -> String? {
        models.first { $0.range(of: "omni", options: .caseInsensitive) != nil }
    }

    /// Fetches the live model list, picks an omni ID, and writes it into every
    /// Settings slot that still points at `failedModel`.
    ///
    /// - Returns: the resolved model ID, or nil when nothing matched.
    @discardableResult
    static func resolveAndPersist(
        failedModel: String,
        client: OpenAIClient = .shared
    ) async -> String? {
        guard !Settings.shared.isOpenAIProvider else { return nil }
        let models: [String]
        do {
            models = try await client.fetchAvailableModels()
        } catch {
            logger.log("model list fetch failed while resolving omni ID: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let resolved = firstOmniModel(in: models), resolved != failedModel else { return nil }

        Settings.shared.cachedModelList = models
        if Settings.shared.visionModel == failedModel {
            Settings.shared.visionModel = resolved
        }
        if Settings.shared.transcriptionModel == failedModel {
            Settings.shared.transcriptionModel = resolved
        }
        if Settings.shared.translationModel == failedModel {
            Settings.shared.translationModel = resolved
        }
        logger.log("omni model \(failedModel, privacy: .public) not found; switched to \(resolved, privacy: .public)")
        return resolved
    }
}
