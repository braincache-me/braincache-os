import XCTest
@testable import ClipVault

/// Covers the provider abstraction: per-provider defaults, model
/// classification for Token Factory IDs, embedding conforming, the
/// Responses → Chat Completions bridge, and `<think>` stripping.
final class AIProviderTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "AIProviderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // MARK: - Provider defaults

    func testDefaultProviderIsNebius() {
        XCTAssertEqual(settings.aiProvider, .nebius)
        XCTAssertEqual(settings.aiBaseURL, "https://api.tokenfactory.nebius.com/v1")
        XCTAssertFalse(settings.isOpenAIProvider)
    }

    func testNebiusDefaultModelsAreNemotron() {
        XCTAssertEqual(settings.chatModel, "nvidia/nemotron-3-super-120b-a12b")
        XCTAssertEqual(settings.classificationModel, "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B")
        XCTAssertEqual(settings.visionModel, "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning")
        XCTAssertEqual(settings.transcriptionModel, "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning")
        XCTAssertEqual(settings.embeddingModel, "Qwen/Qwen3-Embedding-8B")
        XCTAssertEqual(settings.voiceRewriteModel, "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B")
    }

    func testOpenAIProviderRestoresOpenAIDefaults() {
        settings.aiProvider = .openai
        XCTAssertTrue(settings.isOpenAIProvider)
        XCTAssertEqual(settings.aiBaseURL, "https://api.openai.com/v1")
        XCTAssertEqual(settings.chatModel, "gpt-5.4-nano")
        XCTAssertEqual(settings.visionModel, "gpt-5.4-mini")
        XCTAssertEqual(settings.embeddingModel, "text-embedding-3-small")
        XCTAssertEqual(settings.transcriptionModel, "gpt-realtime-whisper")
        XCTAssertEqual(settings.translationModel, "gpt-realtime-translate")
    }

    func testSwitchingProviderResetsStoredModelSelections() {
        settings.chatModel = "nvidia/some-custom-model"
        settings.embeddingModel = "BAAI/bge-en-icl"
        settings.cachedModelList = ["nvidia/a", "nvidia/b"]

        settings.aiProvider = .openai

        XCTAssertEqual(settings.chatModel, "gpt-5.4-nano",
                       "a Nemotron ID must not stay selected after switching to OpenAI")
        XCTAssertEqual(settings.embeddingModel, "text-embedding-3-small")
        XCTAssertTrue(settings.cachedModelList.isEmpty)
    }

    func testSwitchingBackToNebiusRestoresNemotronDefaults() {
        settings.aiProvider = .openai
        settings.chatModel = "gpt-5.4"
        settings.aiProvider = .nebius
        XCTAssertEqual(settings.chatModel, "nvidia/nemotron-3-super-120b-a12b")
    }

    func testCustomProviderUsesEditableBaseURL() {
        settings.aiProvider = .custom
        settings.aiBaseURL = "https://gateway.internal/v1  "
        XCTAssertEqual(settings.aiBaseURL, "https://gateway.internal/v1")
        XCTAssertFalse(settings.isOpenAIProvider)
    }

    func testCustomProviderPointedAtOpenAIIsDetected() {
        settings.aiProvider = .custom
        settings.aiBaseURL = "https://api.openai.com/v1"
        XCTAssertTrue(settings.isOpenAIProvider)
    }

    func testBaseURLIsNotEditableForBuiltInProviders() {
        settings.aiProvider = .nebius
        settings.aiBaseURL = "https://example.com/v1"
        XCTAssertEqual(settings.aiBaseURL, "https://api.tokenfactory.nebius.com/v1")
    }

    func testChunkedTranscriptionWindowDefaultAndClamping() {
        XCTAssertEqual(settings.chunkedTranscriptionWindowSeconds, 12)
        settings.chunkedTranscriptionWindowSeconds = 1
        XCTAssertEqual(settings.chunkedTranscriptionWindowSeconds, 4)
        settings.chunkedTranscriptionWindowSeconds = 999
        XCTAssertEqual(settings.chunkedTranscriptionWindowSeconds, 60)
        settings.chunkedTranscriptionWindowSeconds = 20
        XCTAssertEqual(settings.chunkedTranscriptionWindowSeconds, 20)
    }

    func testAPIKeyStorageKeyIsUnchanged() {
        XCTAssertEqual(Settings.Keys.openAIAPIKey, "openAIAPIKey",
                       "the Keychain/defaults key must stay stable for backward compatibility")
    }

    // MARK: - Model classification

    func testChatModelsIncludesTokenFactoryIDs() {
        let all = [
            "nvidia/nemotron-3-super-120b-a12b",
            "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B",
            "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning",
            "Qwen/Qwen3-Embedding-8B",
            "BAAI/bge-en-icl",
            "gpt-5.4-nano",
            "gpt-4o-realtime-preview",
            "text-embedding-3-small",
        ]
        let chat = OpenAIClient.chatModels(from: all)
        XCTAssertTrue(chat.contains("nvidia/nemotron-3-super-120b-a12b"))
        XCTAssertTrue(chat.contains("nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning"))
        XCTAssertTrue(chat.contains("gpt-5.4-nano"))
        XCTAssertFalse(chat.contains("Qwen/Qwen3-Embedding-8B"))
        XCTAssertFalse(chat.contains("BAAI/bge-en-icl"))
        XCTAssertFalse(chat.contains("text-embedding-3-small"))
        XCTAssertFalse(chat.contains("gpt-4o-realtime-preview"))
    }

    func testEmbeddingModelsMatchesQwenAndBGEAndE5() {
        let all = [
            "Qwen/Qwen3-Embedding-8B",
            "BAAI/bge-en-icl",
            "intfloat/e5-mistral-7b-instruct",
            "text-embedding-3-large",
            "nvidia/nemotron-3-super-120b-a12b",
        ]
        let embeddings = OpenAIClient.embeddingModels(from: all)
        XCTAssertEqual(Set(embeddings), Set([
            "Qwen/Qwen3-Embedding-8B",
            "BAAI/bge-en-icl",
            "intfloat/e5-mistral-7b-instruct",
            "text-embedding-3-large",
        ]))
    }

    // MARK: - Embedding conforming

    func testEmbeddingTruncatesToRequestedDimensionsAndNormalizes() {
        let vector = (0..<4096).map { Float($0 % 17) + 1 }
        let conformed = EmbeddingVectorAdapter.conform(vector, to: 256)
        XCTAssertEqual(conformed.count, 256)

        var magnitude: Float = 0
        for value in conformed { magnitude += value * value }
        XCTAssertEqual(magnitude.squareRoot(), 1.0, accuracy: 0.0001)

        // Direction is preserved: ratios between the kept components survive.
        XCTAssertEqual(conformed[1] / conformed[0], vector[1] / vector[0], accuracy: 0.0001)
    }

    func testEmbeddingLeavesCorrectlySizedVectorsAlone() {
        let vector: [Float] = [3, 4]
        XCTAssertEqual(EmbeddingVectorAdapter.conform(vector, to: 2), vector)
        XCTAssertEqual(EmbeddingVectorAdapter.conform(vector, to: 8), vector)
    }

    func testEmbeddingNormalizeLeavesZeroVectorAlone() {
        let zero: [Float] = [0, 0, 0]
        XCTAssertEqual(EmbeddingVectorAdapter.normalize(zero), zero)
    }

    // MARK: - Responses → Chat Completions tool conversion

    func testResponsesFunctionToolIsNestedForChatCompletions() {
        let tools = AskAIToolDefinitions.tools(
            webSearch: false, claudeCodeHistory: true, codexHistory: false
        )
        let converted = ResponsesChatCompletionsBridge.chatTools(from: tools)
        XCTAssertTrue(converted.skippedHostedTools.isEmpty)
        XCTAssertEqual(converted.tools.count, tools.count)

        let first = try? XCTUnwrap(converted.tools.first)
        XCTAssertEqual(first?["type"] as? String, "function")
        let function = first?["function"] as? [String: Any]
        XCTAssertNotNil(function?["name"] as? String)
        XCTAssertNotNil(function?["parameters"] as? [String: Any])
        XCTAssertNil(first?["name"], "the flat Responses name must move under `function`")
    }

    func testHostedWebSearchToolIsSkipped() {
        let tools = AskAIToolDefinitions.tools(
            webSearch: true, claudeCodeHistory: false, codexHistory: false
        )
        let converted = ResponsesChatCompletionsBridge.chatTools(from: tools)
        XCTAssertEqual(converted.skippedHostedTools, ["web_search"])
        XCTAssertTrue(converted.tools.isEmpty)
    }

    func testContentBlocksAreConvertedToChatParts() {
        let blocks: [[String: Any]] = [
            ["type": "input_text", "text": "hello"],
            ["type": "input_image", "image_url": "data:image/jpeg;base64,AAA", "detail": "auto"],
        ]
        let parts = ResponsesChatCompletionsBridge.chatContentParts(from: blocks)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "hello")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let imageURL = parts[1]["image_url"] as? [String: Any]
        XCTAssertEqual(imageURL?["url"] as? String, "data:image/jpeg;base64,AAA")
    }

    func testToolRoundTripProducesOneResultPerCall() {
        let calls = [
            (callId: "call_1", name: "search_claude_code_history", arguments: "{\"query\":\"x\"}"),
            (callId: "call_2", name: "ask_codex", arguments: "{\"question\":\"y\"}"),
        ]
        let assistant = ResponsesChatCompletionsBridge.assistantToolCallMessage(calls: calls)
        let toolCalls = assistant["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(toolCalls?.count, 2)
        XCTAssertEqual(assistant["role"] as? String, "assistant")

        let results = ResponsesChatCompletionsBridge.toolResultMessages(
            outputs: calls.map { ($0.callId, "result for \($0.name)") }
        )
        XCTAssertEqual(results.count, calls.count)
        XCTAssertEqual(results.map { $0["tool_call_id"] as? String }, ["call_1", "call_2"])
        XCTAssertTrue(results.allSatisfy { ($0["role"] as? String) == "tool" })
    }

    func testChatSessionStoreRoundTripsAndEvicts() {
        let store = ResponsesChatSessionStore(maxSessions: 2)
        let first = store.store([["role": "user", "content": "1"]])
        let second = store.store([["role": "user", "content": "2"]])
        let third = store.store([["role": "user", "content": "3"]])

        XCTAssertNil(store.messages(for: first), "the oldest session should be evicted")
        XCTAssertEqual(store.messages(for: second)?.count, 1)
        XCTAssertEqual(store.messages(for: third)?.first?["content"] as? String, "3")
    }

    func testStreamingToolCallAccumulatorReassemblesFragments() {
        var accumulator = OpenAIClient.StreamingToolCallAccumulator()
        accumulator.ingest([["index": 0, "id": "call_a", "function": ["name": "ask_codex", "arguments": "{\"que"]]])
        accumulator.ingest([["index": 0, "function": ["arguments": "stion\":\"hi\"}"]]])
        accumulator.ingest([["index": 1, "id": "call_b", "function": ["name": "ask_claude_code", "arguments": "{}"]]])

        let calls = accumulator.finish()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].callId, "call_a")
        XCTAssertEqual(calls[0].name, "ask_codex")
        XCTAssertEqual(calls[0].arguments, "{\"question\":\"hi\"}")
        XCTAssertEqual(calls[1].callId, "call_b")
    }

    func testStreamDeltaExtraction() {
        let json: [String: Any] = ["choices": [["delta": ["content": "hi"]]]]
        XCTAssertEqual(OpenAIClient.streamDelta(from: json)?["content"] as? String, "hi")
        XCTAssertNil(OpenAIClient.streamDelta(from: ["choices": []]))
    }

    // MARK: - Think-tag stripping

    func testStripRemovesWholeThinkBlock() {
        XCTAssertEqual(
            ThinkTagFilter.strip("<think>plan the answer</think>Hello world"),
            "Hello world"
        )
    }

    func testStripLeavesPlainTextUntouched() {
        XCTAssertEqual(ThinkTagFilter.strip("Hello world"), "Hello world")
    }

    func testThinkTagSplitAcrossDeltaBoundariesIsRemoved() {
        var filter = ThinkTagFilter()
        var output = ""
        for chunk in ["Ans", "<thi", "nk>hidden", " reasoning</thi", "nk>wer: 42"] {
            output += filter.feed(chunk)
        }
        output += filter.flush()
        XCTAssertEqual(output, "Answer: 42")
    }

    func testTextIsNotHeldBackUnnecessarily() {
        var filter = ThinkTagFilter()
        XCTAssertEqual(filter.feed("plain text "), "plain text ")
        XCTAssertEqual(filter.flush(), "")
    }

    func testUnterminatedThinkBlockIsDropped() {
        var filter = ThinkTagFilter()
        XCTAssertEqual(filter.feed("<think>still thinking"), "")
        XCTAssertEqual(filter.flush(), "")
    }

    func testMultipleThinkBlocksAreRemoved() {
        XCTAssertEqual(
            ThinkTagFilter.strip("a<think>x</think>b<think>y</think>c"),
            "abc"
        )
    }

    // MARK: - Omni model resolution

    func testFirstOmniModelPicksCaseInsensitiveMatch() {
        let models = ["nvidia/nemotron-3-super-120b-a12b", "nvidia/Nemotron-3-Nano-OMNI-30B", "Qwen/Qwen3-Embedding-8B"]
        XCTAssertEqual(OmniModelResolver.firstOmniModel(in: models), "nvidia/Nemotron-3-Nano-OMNI-30B")
        XCTAssertNil(OmniModelResolver.firstOmniModel(in: ["gpt-5.4-nano"]))
    }

    func testModelNotFoundDetection() {
        XCTAssertTrue(OmniModelResolver.isModelNotFound(
            OpenAIError.httpError(statusCode: 404, message: "The model `x` does not exist")))
        XCTAssertTrue(OmniModelResolver.isModelNotFound(
            OpenAIError.httpError(statusCode: 400, message: "Unknown model: nvidia/foo")))
        XCTAssertFalse(OmniModelResolver.isModelNotFound(
            OpenAIError.httpError(statusCode: 429, message: "rate limited")))
        XCTAssertFalse(OmniModelResolver.isModelNotFound(OpenAIError.apiKeyMissing))
    }
}
