import XCTest
@testable import ClipVault

final class LiveTranscriptBridgeTests: XCTestCase {

    private typealias LiveTranscript = VoiceTranscriptionService.LiveTranscript

    func testIdleWithEmptyTranscript() {
        let payload = BrainCacheLocalBridgeServer.makeLiveTranscriptPayload(
            state: .idle,
            transcript: LiveTranscript(),
            startedAt: nil,
            durationSeconds: 0,
            includesSystemAudio: false
        )
        XCTAssertEqual(payload.state, "idle")
        XCTAssertFalse(payload.isLive)
        XCTAssertNil(payload.startedAt)
        XCTAssertEqual(payload.text, "")
        XCTAssertTrue(payload.entries.isEmpty)
    }

    func testRecordingIsLiveAndCarriesPartials() {
        var transcript = LiveTranscript()
        transcript.entries = [
            .init(source: .mic, timestamp: 1, text: "Hello everyone", isFinal: true)
        ]
        transcript.micPartial = "let me share my"

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = BrainCacheLocalBridgeServer.makeLiveTranscriptPayload(
            state: .recording,
            transcript: transcript,
            startedAt: started,
            durationSeconds: 12.5,
            includesSystemAudio: false
        )

        XCTAssertEqual(payload.state, "recording")
        XCTAssertTrue(payload.isLive)
        XCTAssertEqual(payload.startedAt, ISO8601DateFormatter().string(from: started))
        XCTAssertEqual(payload.durationSeconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(payload.micPartial, "let me share my")
        XCTAssertEqual(payload.entries, [
            .init(source: "Mic", offsetSeconds: 1, text: "Hello everyone", isFinal: true)
        ])
        // Mic-only transcript renders without timestamps (matches app format).
        XCTAssertEqual(payload.text, "Hello everyone")
    }

    func testEntriesAreSortedFilteredAndTimestampedWithSystemAudio() {
        var transcript = LiveTranscript()
        transcript.entries = [
            .init(source: .system, timestamp: 65, text: "Sounds good.", isFinal: true),
            .init(source: .mic, timestamp: 2, text: "  Can you hear me?  ", isFinal: true),
            .init(source: .mic, timestamp: 90, text: "   ", isFinal: false),
        ]

        let payload = BrainCacheLocalBridgeServer.makeLiveTranscriptPayload(
            state: .transcribing,
            transcript: transcript,
            startedAt: nil,
            durationSeconds: 95,
            includesSystemAudio: true
        )

        XCTAssertEqual(payload.state, "transcribing")
        XCTAssertTrue(payload.isLive)
        XCTAssertTrue(payload.includesSystemAudio)
        // Blank entry dropped, remainder sorted by offset, text trimmed.
        XCTAssertEqual(payload.entries, [
            .init(source: "Mic", offsetSeconds: 2, text: "Can you hear me?", isFinal: true),
            .init(source: "System", offsetSeconds: 65, text: "Sounds good.", isFinal: true),
        ])
        // Mixed-source transcript uses the timestamped line format.
        XCTAssertEqual(payload.text, "[0:02 Mic] Can you hear me?\n[1:05 System] Sounds good.")
    }

    func testTerminalStatesAreNotLive() {
        let completed = BrainCacheLocalBridgeServer.makeLiveTranscriptPayload(
            state: .completed("done"),
            transcript: LiveTranscript(),
            startedAt: nil,
            durationSeconds: 0,
            includesSystemAudio: false
        )
        XCTAssertEqual(completed.state, "completed")
        XCTAssertFalse(completed.isLive)

        let failed = BrainCacheLocalBridgeServer.makeLiveTranscriptPayload(
            state: .error("network"),
            transcript: LiveTranscript(),
            startedAt: nil,
            durationSeconds: 0,
            includesSystemAudio: false
        )
        XCTAssertEqual(failed.state, "error")
        XCTAssertFalse(failed.isLive)
    }

    func testEndpointListAdvertisesLiveTranscript() {
        XCTAssertTrue(
            BrainCacheLocalBridgeServer.endpointList.contains("GET /v1/live/transcript")
        )
    }
}
