import Foundation

enum AIUsageCategory: String {
    case chat
    case indexing
    case transcription
}

struct OpenAIModelPricing {
    let inputUSDPerMillion: Double
    let cachedInputUSDPerMillion: Double
    let outputUSDPerMillion: Double
}

enum OpenAIUsageCost {
    static func totalUSD(
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int = 0
    ) -> Double {
        guard let pricing = pricing(for: model) else { return 0 }

        let boundedInput = max(inputTokens, 0)
        let boundedOutput = max(outputTokens, 0)
        let boundedCached = min(max(cachedInputTokens, 0), boundedInput)
        let uncachedInput = max(boundedInput - boundedCached, 0)

        return (Double(uncachedInput) / 1_000_000.0 * pricing.inputUSDPerMillion)
            + (Double(boundedCached) / 1_000_000.0 * pricing.cachedInputUSDPerMillion)
            + (Double(boundedOutput) / 1_000_000.0 * pricing.outputUSDPerMillion)
    }

    static func pricing(for model: String) -> OpenAIModelPricing? {
        let normalized = model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return knownPrices.first(where: { normalized.hasPrefix($0.key) })?.value
    }

    // MARK: - Audio Transcription (per-minute pricing)

    struct AudioModelPricing {
        let usdPerMinute: Double
    }

    static func transcriptionCostUSD(model: String, durationSeconds: Double) -> Double {
        guard let pricing = audioPricing(for: model) else { return 0 }
        return max(0, durationSeconds / 60.0) * pricing.usdPerMinute
    }

    static func audioPricing(for model: String) -> AudioModelPricing? {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return knownAudioPrices.first(where: { normalized.hasPrefix($0.key) })?.value
    }

    private static let knownAudioPrices: [(key: String, value: AudioModelPricing)] = [
        ("gpt-realtime-whisper", AudioModelPricing(usdPerMinute: 0.006)),
        ("gpt-4o-transcribe", AudioModelPricing(usdPerMinute: 0.006)),
        ("gpt-4o-mini-transcribe", AudioModelPricing(usdPerMinute: 0.003)),
        ("whisper-1", AudioModelPricing(usdPerMinute: 0.006)),
    ]

    static let defaultTranscriptionModels = [
        "gpt-realtime-whisper", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-1",
    ]

    private static let knownPrices: [(key: String, value: OpenAIModelPricing)] = [
        ("text-embedding-3-large", OpenAIModelPricing(inputUSDPerMillion: 0.13, cachedInputUSDPerMillion: 0.13, outputUSDPerMillion: 0)),
        ("text-embedding-3-small", OpenAIModelPricing(inputUSDPerMillion: 0.02, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 0)),
        ("text-embedding-ada-002", OpenAIModelPricing(inputUSDPerMillion: 0.10, cachedInputUSDPerMillion: 0.10, outputUSDPerMillion: 0)),
        ("gpt-5.4-pro", OpenAIModelPricing(inputUSDPerMillion: 30, cachedInputUSDPerMillion: 30, outputUSDPerMillion: 180)),
        ("gpt-5.4-mini", OpenAIModelPricing(inputUSDPerMillion: 0.75, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 4.5)),
        ("gpt-5.4-nano", OpenAIModelPricing(inputUSDPerMillion: 0.20, cachedInputUSDPerMillion: 0.02, outputUSDPerMillion: 1.25)),
        ("gpt-5.4", OpenAIModelPricing(inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 0.25, outputUSDPerMillion: 15)),
        ("gpt-5.2-pro", OpenAIModelPricing(inputUSDPerMillion: 21, cachedInputUSDPerMillion: 21, outputUSDPerMillion: 168)),
        ("gpt-5.2", OpenAIModelPricing(inputUSDPerMillion: 1.75, cachedInputUSDPerMillion: 0.175, outputUSDPerMillion: 14)),
        ("gpt-5.1", OpenAIModelPricing(inputUSDPerMillion: 1.25, cachedInputUSDPerMillion: 0.125, outputUSDPerMillion: 10)),
        ("gpt-5-pro", OpenAIModelPricing(inputUSDPerMillion: 15, cachedInputUSDPerMillion: 15, outputUSDPerMillion: 120)),
        ("gpt-5-mini", OpenAIModelPricing(inputUSDPerMillion: 0.25, cachedInputUSDPerMillion: 0.025, outputUSDPerMillion: 2)),
        ("gpt-5-nano", OpenAIModelPricing(inputUSDPerMillion: 0.05, cachedInputUSDPerMillion: 0.005, outputUSDPerMillion: 0.4)),
        ("gpt-5", OpenAIModelPricing(inputUSDPerMillion: 1.25, cachedInputUSDPerMillion: 0.125, outputUSDPerMillion: 10)),
        ("gpt-4.1-mini", OpenAIModelPricing(inputUSDPerMillion: 0.4, cachedInputUSDPerMillion: 0.1, outputUSDPerMillion: 1.6)),
        ("gpt-4.1-nano", OpenAIModelPricing(inputUSDPerMillion: 0.1, cachedInputUSDPerMillion: 0.025, outputUSDPerMillion: 0.4)),
        ("gpt-4.1", OpenAIModelPricing(inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 8)),
        ("gpt-4o-mini", OpenAIModelPricing(inputUSDPerMillion: 0.15, cachedInputUSDPerMillion: 0.075, outputUSDPerMillion: 0.6)),
        ("gpt-4o-2024-05-13", OpenAIModelPricing(inputUSDPerMillion: 5, cachedInputUSDPerMillion: 5, outputUSDPerMillion: 15)),
        ("gpt-4o", OpenAIModelPricing(inputUSDPerMillion: 2.5, cachedInputUSDPerMillion: 1.25, outputUSDPerMillion: 10)),
        ("o3-pro", OpenAIModelPricing(inputUSDPerMillion: 20, cachedInputUSDPerMillion: 20, outputUSDPerMillion: 80)),
        ("o3-mini", OpenAIModelPricing(inputUSDPerMillion: 1.1, cachedInputUSDPerMillion: 0.55, outputUSDPerMillion: 4.4)),
        ("o3", OpenAIModelPricing(inputUSDPerMillion: 2, cachedInputUSDPerMillion: 0.5, outputUSDPerMillion: 8)),
        ("o4-mini", OpenAIModelPricing(inputUSDPerMillion: 1.1, cachedInputUSDPerMillion: 0.275, outputUSDPerMillion: 4.4))
    ]
}
