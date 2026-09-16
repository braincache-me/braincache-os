import XCTest
@testable import ClipVault

/// Covers the chunked (non-realtime) transcription path used on providers
/// without a realtime WebSocket: the pure PCM helpers and the client's
/// chunking / ordering behaviour driven by a fake transport.
final class ChunkedTranscriptionTests: XCTestCase {

    // MARK: - Fixtures

    /// Generates `seconds` of a mono 24 kHz PCM16 sine wave.
    private func tone(seconds: Double, sampleRate: Int = 24_000, frequency: Double = 440, amplitude: Double = 0.5) -> Data {
        let count = Int(Double(sampleRate) * seconds)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for index in 0..<count {
            let value = sin(2 * Double.pi * frequency * Double(index) / Double(sampleRate)) * amplitude
            samples.append(Int16(value * Double(Int16.max)))
        }
        return PCM16Audio.data(from: samples)
    }

    private func silence(seconds: Double, sampleRate: Int = 24_000) -> Data {
        Data(count: Int(Double(sampleRate) * seconds) * 2)
    }

    // MARK: - PCM16 helpers

    func testSampleRoundTrip() {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 1234]
        XCTAssertEqual(PCM16Audio.samples(PCM16Audio.data(from: samples)), samples)
    }

    func testDurationMatchesSampleRate() {
        let data = tone(seconds: 2)
        XCTAssertEqual(PCM16Audio.duration(data, sampleRate: 24_000), 2.0, accuracy: 0.001)
    }

    func testResampleProducesExpectedSampleCount() {
        let input = tone(seconds: 1)
        let output = PCM16Audio.resample(input, from: 24_000, to: 16_000)
        XCTAssertEqual(PCM16Audio.sampleCount(output), 16_000)
    }

    func testResampleIsIdentityForSameRate() {
        let input = tone(seconds: 0.1)
        XCTAssertEqual(PCM16Audio.resample(input, from: 16_000, to: 16_000), input)
    }

    func testResamplePreservesSignalShape() {
        // A 440 Hz tone resampled to 16 kHz must keep roughly the same energy.
        let input = tone(seconds: 0.5)
        let output = PCM16Audio.resample(input, from: 24_000, to: 16_000)
        XCTAssertEqual(PCM16Audio.rms(output), PCM16Audio.rms(input), accuracy: 0.02)
    }

    func testRMSIsZeroForSilenceAndPositiveForTone() {
        XCTAssertEqual(PCM16Audio.rms(silence(seconds: 0.1)), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(PCM16Audio.rms(tone(seconds: 0.1)), 0.2)
    }

    // MARK: - WAV encoding

    func testWAVHeaderIsWellFormed() {
        let pcm = tone(seconds: 0.25, sampleRate: 16_000)
        let wav = PCM16Audio.wav(pcm16: pcm, sampleRate: 16_000)

        XCTAssertEqual(wav.count, pcm.count + 44)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")

        func uint32(at offset: Int) -> UInt32 {
            let bytes = Array(wav[offset..<(offset + 4)])
            return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        }
        func uint16(at offset: Int) -> UInt16 {
            let bytes = Array(wav[offset..<(offset + 2)])
            return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        }

        XCTAssertEqual(uint32(at: 4), UInt32(36 + pcm.count))    // RIFF size
        XCTAssertEqual(uint32(at: 16), 16)                       // PCM fmt size
        XCTAssertEqual(uint16(at: 20), 1)                        // PCM format tag
        XCTAssertEqual(uint16(at: 22), 1)                        // mono
        XCTAssertEqual(uint32(at: 24), 16_000)                   // sample rate
        XCTAssertEqual(uint32(at: 28), 32_000)                   // byte rate
        XCTAssertEqual(uint16(at: 32), 2)                        // block align
        XCTAssertEqual(uint16(at: 34), 16)                       // bits per sample
        XCTAssertEqual(uint32(at: 40), UInt32(pcm.count))         // data size
    }

    // MARK: - Split-point search

    func testSplitPrefersQuietestFrameInTrailingWindow() {
        // 5 s of tone, then 0.4 s of silence, then 0.4 s of tone. The cut
        // should land inside the silent stretch rather than at the very end.
        var buffer = tone(seconds: 5)
        buffer.append(silence(seconds: 0.4))
        buffer.append(tone(seconds: 0.4))

        let finder = SilenceSplitFinder()
        let offset = finder.splitOffset(in: buffer, sampleRate: 24_000)
        let cutSecond = Double(offset / 2) / 24_000

        XCTAssertGreaterThan(cutSecond, 5.0)
        XCTAssertLessThan(cutSecond, 5.4)
    }

    func testSplitOfUniformBufferTakesEverything() {
        let buffer = tone(seconds: 3)
        let finder = SilenceSplitFinder()
        let offset = finder.splitOffset(in: buffer, sampleRate: 24_000)
        XCTAssertGreaterThan(offset, 0)
        XCTAssertLessThanOrEqual(offset, buffer.count)
    }

    func testSplitOfEmptyBufferIsZero() {
        XCTAssertEqual(SilenceSplitFinder().splitOffset(in: Data(), sampleRate: 24_000), 0)
    }

    func testSplitIsSampleAligned() {
        let buffer = tone(seconds: 4)
        let offset = SilenceSplitFinder().splitOffset(in: buffer, sampleRate: 24_000)
        XCTAssertEqual(offset % 2, 0)
    }

    // MARK: - Ordered emission

    func testOrderedEmitterHoldsBackOutOfOrderResults() {
        var emitter = OrderedSegmentEmitter()
        let first = emitter.reserve()
        let second = emitter.reserve()
        let third = emitter.reserve()

        XCTAssertEqual(emitter.complete(sequence: second, text: "two"), [])
        XCTAssertEqual(emitter.complete(sequence: third, text: "three"), [])
        XCTAssertEqual(emitter.complete(sequence: first, text: "one"), ["one", "two", "three"])
        XCTAssertTrue(emitter.isDrained)
    }

    func testOrderedEmitterSkipsEmptyResultsButKeepsOrder() {
        var emitter = OrderedSegmentEmitter()
        let first = emitter.reserve()
        let second = emitter.reserve()
        XCTAssertEqual(emitter.complete(sequence: first, text: ""), [])
        XCTAssertEqual(emitter.complete(sequence: second, text: "kept"), ["kept"])
        XCTAssertTrue(emitter.isDrained)
    }

    // MARK: - Client behaviour

    /// Transport that records every request and lets a test gate the first
    /// response so a later chunk can finish first.
    private final class FakeTransport: ChunkedTranscriptionTransport {
        private let lock = NSLock()
        private(set) var receivedWAVs: [Data] = []
        private(set) var receivedInstructions: [String] = []
        var responses: [String] = []
        var errorForCall: [Int: Error] = [:]
        /// Seconds the nth call sleeps before returning, to force out-of-order completion.
        var delayForCall: [Int: Double] = [:]

        func transcribe(wav: Data, model: String, instruction: String) async throws -> String {
            lock.lock()
            let index = receivedWAVs.count
            receivedWAVs.append(wav)
            receivedInstructions.append(instruction)
            let response = index < responses.count ? responses[index] : "chunk\(index)"
            let error = errorForCall[index]
            let delay = delayForCall[index]
            lock.unlock()

            if let delay {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if let error { throw error }
            return response
        }

        var callCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return receivedWAVs.count
        }
    }

    private func withTestAPIKey(_ body: () throws -> Void) rethrows {
        let previous = Settings.shared.openAIAPIKey
        Settings.shared.openAIAPIKey = "test-key-chunked"
        defer { Settings.shared.openAIAPIKey = previous }
        try body()
    }

    func testChunksAreEmittedInSubmissionOrderDespiteOutOfOrderResponses() throws {
        try withTestAPIKey {
            let transport = FakeTransport()
            transport.responses = ["first segment", "second segment"]
            // Make the first request finish *after* the second.
            transport.delayForCall = [0: 0.4]

            let client = ChunkedTranscriptionClient(
                source: .mic,
                model: "nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning",
                transport: transport,
                windowSeconds: 2
            )

            var emitted: [String] = []
            let bothArrived = expectation(description: "two segments emitted")
            bothArrived.expectedFulfillmentCount = 2
            client.onCompleted = { text in
                emitted.append(text)
                bothArrived.fulfill()
            }

            client.start()
            client.sendAudio(tone(seconds: 5))
            client.stop()

            wait(for: [bothArrived], timeout: 10)
            XCTAssertEqual(emitted, ["first segment", "second segment"])
        }
    }

    func testSilentChunksAreNeverSent() throws {
        try withTestAPIKey {
            let transport = FakeTransport()
            let client = ChunkedTranscriptionClient(
                source: .mic,
                model: "omni",
                transport: transport,
                windowSeconds: 1
            )
            client.start()
            client.sendAudio(silence(seconds: 6))

            let settled = expectation(description: "settled")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
            wait(for: [settled], timeout: 5)
            XCTAssertEqual(transport.callCount, 0)
        }
    }

    func testStopFlushesTheTrailingBuffer() throws {
        try withTestAPIKey {
            let transport = FakeTransport()
            transport.responses = ["tail"]
            let client = ChunkedTranscriptionClient(
                source: .mic,
                model: "omni",
                transport: transport,
                windowSeconds: 30
            )

            let emitted = expectation(description: "tail emitted")
            client.onCompleted = { text in
                XCTAssertEqual(text, "tail")
                emitted.fulfill()
            }
            client.start()
            client.sendAudio(tone(seconds: 2))   // shorter than the window
            client.stop()

            wait(for: [emitted], timeout: 10)
            XCTAssertEqual(transport.callCount, 1)
        }
    }

    func testSentAudioIsWAVAtSixteenKilohertz() throws {
        try withTestAPIKey {
            let transport = FakeTransport()
            let client = ChunkedTranscriptionClient(
                source: .mic, model: "omni", transport: transport, windowSeconds: 30
            )
            let sent = expectation(description: "chunk sent")
            client.onCompleted = { _ in sent.fulfill() }
            client.start()
            client.sendAudio(tone(seconds: 1))
            client.stop()
            wait(for: [sent], timeout: 10)

            let wav = try XCTUnwrap(transport.receivedWAVs.first)
            XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
            let rateBytes = Array(wav[24..<28])
            let rate = UInt32(rateBytes[0]) | UInt32(rateBytes[1]) << 8
                | UInt32(rateBytes[2]) << 16 | UInt32(rateBytes[3]) << 24
            XCTAssertEqual(rate, 16_000)
        }
    }

    func testTransientFailureDoesNotEndTheSession() throws {
        try withTestAPIKey {
            let transport = FakeTransport()
            transport.responses = ["", "second"]
            transport.errorForCall = [0: OpenAIError.httpError(statusCode: 500, message: "boom")]

            let client = ChunkedTranscriptionClient(
                source: .mic, model: "omni", transport: transport, windowSeconds: 2
            )

            var errors: [Error] = []
            client.onError = { errors.append($0) }
            let emitted = expectation(description: "second segment emitted")
            client.onCompleted = { text in
                XCTAssertEqual(text, "second")
                emitted.fulfill()
            }

            client.start()
            client.sendAudio(tone(seconds: 5))
            client.stop()

            wait(for: [emitted], timeout: 10)
            XCTAssertTrue(errors.isEmpty, "a single 5xx must not abort a long recording")
        }
    }

    // MARK: - Prompt

    func testTranscriptionInstruction() {
        let client = ChunkedTranscriptionClient(source: .mic, model: "omni", transport: FakeTransport())
        XCTAssertEqual(client.instruction, "Transcribe this audio verbatim. Output only the transcript.")
    }

    func testTranslationInstructionNamesTargetLanguage() {
        let client = ChunkedTranscriptionClient(
            source: .system, model: "omni", targetLanguage: "es", transport: FakeTransport()
        )
        XCTAssertEqual(
            client.instruction,
            "Transcribe this audio and translate it to Spanish. Output only the translation."
        )
    }

    func testUnknownLanguageCodeFallsBackToTheRawCode() {
        XCTAssertEqual(ChunkedTranscriptionClient.languageName(for: "zz"), "zz")
    }

    func testChunkedClientConformsToTheStreamingClientProtocol() {
        let client: RealtimeAudioStreamingClient = ChunkedTranscriptionClient(
            source: .system, model: "omni", transport: FakeTransport()
        )
        XCTAssertEqual(client.source, .system)
    }
}
