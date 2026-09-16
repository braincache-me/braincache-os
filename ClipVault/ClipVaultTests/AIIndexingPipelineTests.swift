import XCTest
import GRDB
@testable import ClipVault

// MARK: - AIIndexingPipelineTests

final class AIIndexingPipelineTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var clipStore: ClipStore!
    private var embeddingStore: EmbeddingStore!
    private var pipeline: AIIndexingPipeline!
    private var client: OpenAIClient!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        clipStore = ClipStore(dbQueue: dbQueue)
        embeddingStore = EmbeddingStore(dbQueue: dbQueue)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        client = OpenAIClient(session: session, initialRetryDelay: 100_000)

        pipeline = AIIndexingPipeline(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client,
            interClipDelayNanoseconds: 0,
            backfillBatchSize: 10,
            maxRetries: 3,
            retryBaseDelayNanoseconds: 1_000  // 1μs for fast tests
        )

        Settings.shared.openAIAPIKey = "sk-test-pipeline"
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        Settings.shared.openAIAPIKey = ""
        // Clear the state-change callback before stopping to prevent already-fulfilled
        // XCTestExpectations from being fulfilled again by the .idle state emitted in stop().
        pipeline.onStateChange = nil
        pipeline.stop()
        pipeline = nil
        embeddingStore = nil
        clipStore = nil
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func insertClip(text: String) throws -> Int64 {
        let hash = Hashing.sha256(data: text.data(using: .utf8)!)
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: hash,
            byteSize: text.utf8.count,
            createdAt: Date()
        )
        return try clipStore.insert(entry: entry)
    }

    private func makeClip(id: Int64, text: String) -> ClipRecord {
        ClipRecord(
            id: id,
            contentType: "text",
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: nil,
            byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: nil,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )
    }

    private func chatResponseJSON(tags: [String]) -> Data {
        // Build the content JSON-string by serialising the tags array, then embedding it as
        // a plain String value in the outer ChatResponse JSON.  This avoids the manual
        // escaping bug where bare quote characters inside tagsStr made the outer JSON invalid.
        let tagsJSON = (try? JSONSerialization.data(withJSONObject: tags)).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "[]"
        let content = #"{"tags": \#(tagsJSON)}"#
        let response: [String: Any] = [
            "id": "chatcmpl-test",
            "choices": [["message": ["role": "assistant", "content": content], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]
        ]
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func embeddingResponseJSON() -> Data {
        let values = (0..<256).map { String(Float($0) / 256.0) }.joined(separator: ", ")
        return """
        {
          "object": "list",
          "data": [{"object": "embedding", "index": 0, "embedding": [\(values)]}],
          "model": "text-embedding-3-small",
          "usage": {"prompt_tokens": 5, "total_tokens": 5}
        }
        """.data(using: .utf8)!
    }

    private func makeHTTPResponse(statusCode: Int = 200, url: String = "https://api.openai.com/v1/chat/completions") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: url)!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    /// Installs a mock handler that returns tags for /chat/completions and an embedding for /embeddings.
    private func installSuccessHandler(tags: [String] = ["code", "tech"]) {
        let tagsData = chatResponseJSON(tags: tags)
        let embData = embeddingResponseJSON()
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("embeddings") == true {
                return (self.makeHTTPResponse(url: "https://api.openai.com/v1/embeddings"), embData)
            }
            return (self.makeHTTPResponse(), tagsData)
        }
    }

    // MARK: - State Transitions

    func testPipelineStartsIdleWithNoClips() async throws {
        let expectation = self.expectation(description: "Pipeline reaches idle")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }
        pipeline.start()
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(pipeline.state, .idle)
    }

    func testPipelinePausesWhenNoAPIKey() async throws {
        Settings.shared.openAIAPIKey = ""
        let expectation = self.expectation(description: "Pipeline pauses")
        pipeline.onStateChange = { state in
            if state == .paused { expectation.fulfill() }
        }
        pipeline.start()
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(pipeline.state, .paused)
    }

    // MARK: - Single Clip Processing (processClip)

    func testProcessClipClassifiesAndEmbeds() async throws {
        installSuccessHandler(tags: ["code", "tech"])
        let clipId = try insertClip(text: "let x = 42")
        let clip = makeClip(id: clipId, text: "let x = 42")

        let stop = await pipeline.processClip(clip)

        XCTAssertFalse(stop, "Pipeline should not stop after a successful clip")
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1, "Clip should be marked as processed")
        XCTAssertNotNil(stored?.tags, "Tags should be stored")
        let embCount = try embeddingStore.count()
        XCTAssertEqual(embCount, 1, "Embedding should be stored")
    }

    func testProcessClipOrderIsDescribeThenClassifyThenEmbed() async throws {
        var callOrder: [String] = []
        MockURLProtocol.requestHandler = { request in
            if request.url?.path.contains("embeddings") == true {
                callOrder.append("embed")
                return (self.makeHTTPResponse(url: "https://api.openai.com/v1/embeddings"), self.embeddingResponseJSON())
            }
            // chat completions endpoint is used for both classify and image describe
            callOrder.append("chat")
            return (self.makeHTTPResponse(), self.chatResponseJSON(tags: ["code"]))
        }

        let clipId = try insertClip(text: "hello world")
        let clip = makeClip(id: clipId, text: "hello world")
        _ = await pipeline.processClip(clip)

        // For a text clip: classify (chat) → embed
        XCTAssertTrue(callOrder.contains("chat"), "Classification should be called")
        XCTAssertTrue(callOrder.contains("embed"), "Embedding should be called")
        if let chatIdx = callOrder.firstIndex(of: "chat"),
           let embedIdx = callOrder.firstIndex(of: "embed") {
            XCTAssertLessThan(chatIdx, embedIdx, "Classification must run before embedding")
        }
    }

    func testProcessClipMarksFailed_OnGenericError() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }
        let clipId = try insertClip(text: "will fail")
        let clip = makeClip(id: clipId, text: "will fail")

        let stop = await pipeline.processClip(clip)

        XCTAssertFalse(stop, "Pipeline should not stop on generic error")
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 2, "Clip should be marked as failed")
    }

    func testProcessClipStopsPipeline_On401() async throws {
        MockURLProtocol.requestHandler = { request in
            let errorJSON = """
            {"error": {"message": "Unauthorized", "type": "invalid_request_error", "code": "invalid_api_key"}}
            """.data(using: .utf8)!
            return (self.makeHTTPResponse(statusCode: 401), errorJSON)
        }

        let clipId = try insertClip(text: "bad key clip")
        let clip = makeClip(id: clipId, text: "bad key clip")

        let stop = await pipeline.processClip(clip)

        XCTAssertTrue(stop, "Pipeline should stop when API key is invalid (401)")
        if case .error(_) = pipeline.state {
            // expected
        } else {
            XCTFail("Pipeline state should be .error after 401")
        }
    }

    func testProcessClipMarksFailed_On429() async throws {
        MockURLProtocol.requestHandler = { request in
            let errorJSON = """
            {"error": {"message": "Rate limit exceeded", "type": "requests", "code": "rate_limit_exceeded"}}
            """.data(using: .utf8)!
            return (self.makeHTTPResponse(statusCode: 429), errorJSON)
        }

        let clipId = try insertClip(text: "rate limited clip")
        let clip = makeClip(id: clipId, text: "rate limited clip")

        let stop = await pipeline.processClip(clip)

        XCTAssertFalse(stop, "Pipeline should not stop on rate limit — just mark failed and continue")
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 2, "Clip should be marked as failed on 429")
    }

    // MARK: - Backfill Loop

    func testBackfillProcessesAllUnprocessedClips() async throws {
        installSuccessHandler(tags: ["prose"])
        let id1 = try insertClip(text: "clip alpha")
        let id2 = try insertClip(text: "clip beta")

        let expectation = self.expectation(description: "Pipeline reaches idle after processing both clips")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }
        pipeline.start()

        await fulfillment(of: [expectation], timeout: 5.0)

        let stored1 = try clipStore.fetchById(id1)
        let stored2 = try clipStore.fetchById(id2)
        XCTAssertEqual(stored1?.aiProcessed, 1, "First clip should be processed")
        XCTAssertEqual(stored2?.aiProcessed, 1, "Second clip should be processed")
        XCTAssertEqual(try embeddingStore.count(), 2)
    }

    // MARK: - Enqueue New Clip

    func testEnqueuedClipIsProcessed() async throws {
        installSuccessHandler(tags: ["url"])
        let clipId = try insertClip(text: "https://example.com")

        let expectation = self.expectation(description: "Pipeline idles after processing enqueued clip")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }

        pipeline.enqueue(clipId: clipId)

        await fulfillment(of: [expectation], timeout: 3.0)

        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1)
    }

    func testEnqueueDoesNothingWhenAPIKeyMissing() async throws {
        Settings.shared.openAIAPIKey = ""
        let clipId = try insertClip(text: "no key clip")
        pipeline.enqueue(clipId: clipId)

        // Wait a bit — pipeline should not start
        try await Task.sleep(nanoseconds: 200_000_000)

        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 0, "Clip should remain unprocessed without API key")
    }

    // MARK: - Sleep / Wake

    func testSleepPausesPipeline() {
        pipeline.handleSleep()
        XCTAssertTrue(pipeline.isSleeping)
        XCTAssertEqual(pipeline.state, .paused)
    }

    func testWakeRestartsPipeline() async throws {
        pipeline.handleSleep()
        XCTAssertTrue(pipeline.isSleeping)

        installSuccessHandler()
        let clipId = try insertClip(text: "after wake")
        _ = clipId  // suppress unused warning

        let expectation = self.expectation(description: "Pipeline idles after wake")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }

        pipeline.handleWake()

        XCTAssertFalse(pipeline.isSleeping)
        await fulfillment(of: [expectation], timeout: 3.0)
    }

    func testSleepWakeCycle() async throws {
        pipeline.handleSleep()
        XCTAssertEqual(pipeline.state, .paused)

        pipeline.handleWake()
        XCTAssertFalse(pipeline.isSleeping)
    }

    // MARK: - Re-index All

    func testReindexAllResetsAndReprocesses() async throws {
        installSuccessHandler(tags: ["tech"])
        let clipId = try insertClip(text: "reindex me")

        // First, mark it as already processed
        try clipStore.markProcessed(id: clipId, tags: "[\"old\"]", imageDescription: nil)
        var stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1)

        // Re-index should reset and re-process
        let expectation = self.expectation(description: "Pipeline idles after re-index")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }

        try pipeline.reindexAll()

        await fulfillment(of: [expectation], timeout: 5.0)

        stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1, "Clip should be re-processed")
    }

    func testReindexAllResetsAllClipsToUnprocessed() async throws {
        let id1 = try insertClip(text: "clip one")
        let id2 = try insertClip(text: "clip two")
        try clipStore.markProcessed(id: id1, tags: nil, imageDescription: nil)
        try clipStore.markFailed(id: id2)

        // Verify both are non-zero
        XCTAssertEqual(try clipStore.fetchById(id1)?.aiProcessed, 1)
        XCTAssertEqual(try clipStore.fetchById(id2)?.aiProcessed, 2)

        // Now install success handler so the pipeline can finish
        installSuccessHandler()
        let expectation = self.expectation(description: "Pipeline idles")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }
        try pipeline.reindexAll()
        await fulfillment(of: [expectation], timeout: 5.0)

        // Both should be processed
        XCTAssertEqual(try clipStore.fetchById(id1)?.aiProcessed, 1)
        XCTAssertEqual(try clipStore.fetchById(id2)?.aiProcessed, 1)
    }

    func testRepairIndexingIssuesRequeuesOnlyBrokenClips() async throws {
        installSuccessHandler(tags: ["tech"])
        let clipId = try insertClip(text: "repair me")

        // Simulate a partially indexed clip: status says processed, but the embedding is missing.
        try clipStore.markProcessed(id: clipId, tags: "[\"old\"]", imageDescription: nil)
        XCTAssertEqual(try embeddingStore.count(), 0)

        let expectation = self.expectation(description: "Pipeline idles after repair")
        pipeline.onStateChange = { state in
            if state == .idle { expectation.fulfill() }
        }

        let result = try pipeline.repairIndexingIssues()

        XCTAssertEqual(result.requeuedClipCount, 1)
        await fulfillment(of: [expectation], timeout: 5.0)

        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1)
        XCTAssertEqual(try embeddingStore.count(), 1)
    }

    func testAutomaticRepairDelaysRecentFailuresButRequeuesOldFailures() throws {
        let recentFailedId = try insertClip(text: "recent failure")
        let oldFailedId = try insertClip(text: "old failure")
        try clipStore.markFailed(id: recentFailedId)
        try clipStore.markFailed(id: oldFailedId)

        let oldTimestamp = Date().timeIntervalSince1970 - 7_200
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clips SET ai_processed_at = ? WHERE id = ?",
                arguments: [oldTimestamp, oldFailedId]
            )
        }

        let requeued = try clipStore.resetClipsNeedingAutomaticAIRepair(failedRetryDelay: 3_600)

        XCTAssertEqual(requeued, 1)
        XCTAssertEqual(try clipStore.fetchById(recentFailedId)?.aiProcessed, 2)
        XCTAssertEqual(try clipStore.fetchById(oldFailedId)?.aiProcessed, 0)
    }

    // MARK: - fetchById (ClipStore)

    func testFetchByIdReturnsExistingClip() throws {
        let id = try insertClip(text: "fetch me")
        let result = try clipStore.fetchById(id)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.textContent, "fetch me")
    }

    func testFetchByIdReturnsNilForMissingClip() throws {
        let result = try clipStore.fetchById(99999)
        XCTAssertNil(result)
    }

    // MARK: - resetAllToUnprocessed (ClipStore)

    func testResetAllToUnprocessed() throws {
        let id1 = try insertClip(text: "a")
        let id2 = try insertClip(text: "b")
        try clipStore.markProcessed(id: id1, tags: nil, imageDescription: nil)
        try clipStore.markFailed(id: id2)

        try clipStore.resetAllToUnprocessed()

        XCTAssertEqual(try clipStore.fetchById(id1)?.aiProcessed, 0)
        XCTAssertEqual(try clipStore.fetchById(id2)?.aiProcessed, 0)
        XCTAssertNil(try clipStore.fetchById(id1)?.aiProcessedAt)
        XCTAssertNil(try clipStore.fetchById(id2)?.aiProcessedAt)
    }

    // MARK: - Retry Behaviour

    func testProcessClipRetriesAndSucceedsOnSecondAttempt() async throws {
        var requestCount = 0
        let tagsData = chatResponseJSON(tags: ["code"])
        let embData = embeddingResponseJSON()

        // OpenAI client makes up to 4 HTTP attempts per call (initial + 3 retries).
        // Fail the first 4 to force the pipeline-level first attempt to fail,
        // then succeed on the pipeline's second attempt.
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            if requestCount <= 4 {
                let errorJSON = """
                {"error": {"message": "Rate limit exceeded", "type": "requests", "code": "rate_limit_exceeded"}}
                """.data(using: .utf8)!
                return (self.makeHTTPResponse(statusCode: 429), errorJSON)
            }
            if request.url?.path.contains("embeddings") == true {
                return (self.makeHTTPResponse(url: "https://api.openai.com/v1/embeddings"), embData)
            }
            return (self.makeHTTPResponse(), tagsData)
        }

        let clipId = try insertClip(text: "retry then succeed")
        let clip = makeClip(id: clipId, text: "retry then succeed")

        let stop = await pipeline.processClip(clip)

        XCTAssertFalse(stop)
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 1, "Clip should succeed after pipeline-level retry")
        XCTAssertNotNil(stored?.tags)
    }

    func testProcessClipDoesNotRetryOn401() async throws {
        MockURLProtocol.requestHandler = { request in
            let errorJSON = """
            {"error": {"message": "Unauthorized", "type": "invalid_request_error", "code": "invalid_api_key"}}
            """.data(using: .utf8)!
            return (self.makeHTTPResponse(statusCode: 401), errorJSON)
        }

        var requestCount = 0
        let original = MockURLProtocol.requestHandler
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return try original!(request)
        }

        let clipId = try insertClip(text: "bad key no retry")
        let clip = makeClip(id: clipId, text: "bad key no retry")

        let stop = await pipeline.processClip(clip)

        XCTAssertTrue(stop, "401 should stop the pipeline immediately")
        // 401 is not retried by OpenAI client, so exactly 1 HTTP request
        XCTAssertEqual(requestCount, 1, "Should not retry on 401")
    }

    func testProcessClipExhaustsRetriesThenMarksFailed() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let clipId = try insertClip(text: "all retries fail")
        let clip = makeClip(id: clipId, text: "all retries fail")

        let stop = await pipeline.processClip(clip)

        XCTAssertFalse(stop)
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 2, "Should be marked failed after all retries exhausted")
    }

    func testImageClipIsNotMarkedProcessedWhenDescriptionFails() async throws {
        let mediaDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipvault-ai-image-test-\(UUID().uuidString)", isDirectory: true)
        let mediaManager = MediaFileManager(mediaDirectory: mediaDir)
        defer { try? FileManager.default.removeItem(at: mediaDir) }

        pipeline.stop()
        pipeline = AIIndexingPipeline(
            clipStore: clipStore,
            embeddingStore: embeddingStore,
            client: client,
            mediaFileManager: mediaManager,
            interClipDelayNanoseconds: 0,
            backfillBatchSize: 10,
            maxRetries: 1,
            retryBaseDelayNanoseconds: 1_000
        )

        let filename = try mediaManager.save(Data([0x89, 0x50, 0x4E, 0x47]), extension: "png")
        var record = ClipRecord(
            id: nil,
            contentType: ClipboardContentType.image.rawValue,
            textContent: nil,
            dataHash: Hashing.sha256(data: Data([0x89, 0x50, 0x4E, 0x47])),
            mediaFileName: filename,
            fileURL: nil,
            sourceApp: nil,
            byteSize: 4,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: false
        )
        let clipId = try clipStore.insertRecord(&record)
        record.id = clipId

        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let stop = await pipeline.processClip(record)

        XCTAssertFalse(stop)
        let stored = try clipStore.fetchById(clipId)
        XCTAssertEqual(stored?.aiProcessed, 2)
        XCTAssertNil(stored?.imageDescription)
        XCTAssertEqual(try embeddingStore.count(), 0)
    }

    // MARK: - Pipeline Restart After Drain

    /// Regression test: after the runLoop exits naturally (queue empty), a
    /// subsequent enqueue() must spin up a fresh task and process the new clip.
    /// Previously the Task reference stayed non-nil and non-cancelled after
    /// completion, so startPipelineTaskIfIdle()'s guard short-circuited and
    /// new clips sat in pendingClipIds forever.
    func testEnqueueRestartsPipelineAfterNaturalDrain() async throws {
        installSuccessHandler()

        // First clip: let the pipeline drain back to .idle.
        let firstId = try insertClip(text: "first clip")
        let firstIdle = self.expectation(description: "Idle after first clip")
        pipeline.onStateChange = { state in
            if state == .idle { firstIdle.fulfill() }
        }
        pipeline.enqueue(clipId: firstId)
        await fulfillment(of: [firstIdle], timeout: 3.0)
        XCTAssertEqual(try clipStore.fetchById(firstId)?.aiProcessed, 1)

        // Second clip: must be processed too — the bug was that this never happened.
        let secondId = try insertClip(text: "second clip after drain")
        let secondIdle = self.expectation(description: "Idle after second clip")
        pipeline.onStateChange = { state in
            if state == .idle { secondIdle.fulfill() }
        }
        pipeline.enqueue(clipId: secondId)
        await fulfillment(of: [secondIdle], timeout: 3.0)
        XCTAssertEqual(
            try clipStore.fetchById(secondId)?.aiProcessed,
            1,
            "Second clip enqueued after drain must be processed (restart-after-drain regression)"
        )
    }

    // MARK: - Safety-net Timer

    /// The periodic safety-net tick should pick up unprocessed clips that
    /// somehow slipped past enqueue (e.g. AI was disabled when they were
    /// captured and got re-enabled later).
    func testSafetyNetTickProcessesMissedClips() async throws {
        installSuccessHandler()
        // Insert a clip while AI is "disabled" so enqueue is a no-op.
        Settings.shared.openAIAPIKey = ""
        let missedId = try insertClip(text: "missed during outage")
        pipeline.enqueue(clipId: missedId)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try clipStore.fetchById(missedId)?.aiProcessed, 0,
                       "Precondition: clip should not be processed yet")

        // Re-enable AI and fire the safety-net tick directly.
        Settings.shared.openAIAPIKey = "sk-test-pipeline"
        let idle = self.expectation(description: "Idle after safety-net pickup")
        pipeline.onStateChange = { state in
            if state == .idle { idle.fulfill() }
        }
        pipeline.runSafetyNetTick()
        await fulfillment(of: [idle], timeout: 3.0)

        XCTAssertEqual(
            try clipStore.fetchById(missedId)?.aiProcessed,
            1,
            "Safety-net should pick up clips that slipped past enqueue"
        )
    }

    /// Safety-net should be a no-op when nothing needs processing — avoids
    /// spinning up the pipeline task on an empty queue every interval.
    func testSafetyNetTickSkipsWhenNothingPending() async throws {
        installSuccessHandler()
        // No clips inserted → safety-net should observe nothing to do.
        // We assert by capturing state transitions: a real run would emit
        // .processing or .idle; a no-op emits nothing.
        var sawStateChange = false
        pipeline.onStateChange = { _ in sawStateChange = true }
        pipeline.runSafetyNetTick()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(sawStateChange,
                       "Safety-net tick should be a no-op when no clips are pending")
    }

    // MARK: - PipelineState Equatable

    func testPipelineStateEquatable() {
        XCTAssertEqual(PipelineState.idle, PipelineState.idle)
        XCTAssertEqual(PipelineState.paused, PipelineState.paused)
        XCTAssertEqual(PipelineState.error("msg"), PipelineState.error("msg"))
        XCTAssertNotEqual(PipelineState.error("a"), PipelineState.error("b"))
        XCTAssertEqual(
            PipelineState.processing(clipId: 1, progress: "3/10"),
            PipelineState.processing(clipId: 1, progress: "3/10")
        )
        XCTAssertNotEqual(
            PipelineState.processing(clipId: 1, progress: "3/10"),
            PipelineState.processing(clipId: 2, progress: "3/10")
        )
    }
}
