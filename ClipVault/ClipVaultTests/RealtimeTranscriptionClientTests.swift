import XCTest
@testable import ClipVault

final class RealtimeTranscriptionClientTests: XCTestCase {

    func testSessionUpdateUsesGARealtimeTranscriptionShape() throws {
        let event = RealtimeTranscriptionClient.makeSessionUpdateEvent(
            model: "gpt-realtime-whisper",
            language: "en",
            sampleRate: 24000
        )

        XCTAssertEqual(event["type"] as? String, "session.update")

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        XCTAssertNil(session["input_audio_format"])

        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])

        let format = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24000)

        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-realtime-whisper")
        XCTAssertEqual(transcription["language"] as? String, "en")
        XCTAssertEqual(transcription["delay"] as? String, "minimal")

        // gpt-realtime-whisper does not support server VAD; the endpoint
        // rejects the field for that model. Other models use server_vad
        // (asserted in a separate test below).
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func testFatalServerErrorRecognisesAuthFailures() {
        XCTAssertTrue(RealtimeTranscriptionClient.isFatalServerError(
            code: "invalid_api_key",
            message: "Incorrect API key provided.",
            sessionConfigured: true
        ))
        XCTAssertTrue(RealtimeTranscriptionClient.isFatalServerError(
            code: "",
            message: "Unauthorized",
            sessionConfigured: true
        ))
        XCTAssertTrue(RealtimeTranscriptionClient.isFatalServerError(
            code: "401",
            message: "",
            sessionConfigured: true
        ))
    }

    func testFatalServerErrorTreatsPreReadyErrorsAsTerminal() {
        // Before the session is configured a recurring error would just loop
        // forever — bail out so the user actually sees what went wrong.
        XCTAssertTrue(RealtimeTranscriptionClient.isFatalServerError(
            code: "invalid_request_error",
            message: "missing required parameter",
            sessionConfigured: false
        ))
    }

    func testFatalServerErrorTreatsMidSessionDropsAsRecoverable() {
        // Session expiry / server-side timeout / transient rate-limit errors
        // emitted mid-recording should reconnect, not fail the recording.
        XCTAssertFalse(RealtimeTranscriptionClient.isFatalServerError(
            code: "session_expired",
            message: "Your session expired.",
            sessionConfigured: true
        ))
        XCTAssertFalse(RealtimeTranscriptionClient.isFatalServerError(
            code: "server_error",
            message: "Internal error",
            sessionConfigured: true
        ))
        XCTAssertFalse(RealtimeTranscriptionClient.isFatalServerError(
            code: "rate_limit_exceeded",
            message: "Too many requests",
            sessionConfigured: true
        ))
    }

    func testDelayIsOnlyAddedForRealtimeWhisper() throws {
        let event = RealtimeTranscriptionClient.makeSessionUpdateEvent(
            model: "gpt-4o-mini-transcribe",
            language: nil,
            sampleRate: 24000
        )

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let transcription = try XCTUnwrap(input["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["model"] as? String, "gpt-4o-mini-transcribe")
        XCTAssertNil(transcription["language"])
        XCTAssertNil(transcription["delay"])

        let turnDetection = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(turnDetection["type"] as? String, "server_vad")
        XCTAssertEqual(turnDetection["threshold"] as? Double, 0.5)
        XCTAssertEqual(turnDetection["prefix_padding_ms"] as? Int, 300)
        XCTAssertEqual(turnDetection["silence_duration_ms"] as? Int, 500)
    }

    func testAudioResponseWatchdogDetectsActiveAudioWithoutTextAfterThreshold() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var watchdog = RealtimeAudioResponseWatchdog(
            stallInterval: 10,
            activeAudioRMSThreshold: 0.01,
            activeAudioGapResetInterval: 30
        )
        let activeAudio = Self.pcm16(samples: [Int16.max / 2, Int16.max / 2, Int16.max / 2])

        watchdog.noteOutgoingAudio(activeAudio, now: start)
        watchdog.noteOutgoingAudio(activeAudio, now: start.addingTimeInterval(9))

        XCTAssertNil(watchdog.stalled(now: start.addingTimeInterval(9), sessionReadyAt: start))

        let stall = try XCTUnwrap(watchdog.stalled(now: start.addingTimeInterval(11), sessionReadyAt: start))
        XCTAssertEqual(Int(stall.activeAge), 11)
        XCTAssertEqual(Int(stall.silentAge), 11)
    }

    func testAudioResponseWatchdogResetsAfterTextResponse() {
        let start = Date(timeIntervalSince1970: 1_000)
        var watchdog = RealtimeAudioResponseWatchdog(
            stallInterval: 10,
            activeAudioRMSThreshold: 0.01,
            activeAudioGapResetInterval: 30
        )
        let activeAudio = Self.pcm16(samples: [Int16.max / 2, Int16.max / 2, Int16.max / 2])

        watchdog.noteOutgoingAudio(activeAudio, now: start)
        watchdog.noteTextResponse(now: start.addingTimeInterval(10))
        watchdog.noteOutgoingAudio(activeAudio, now: start.addingTimeInterval(11))

        XCTAssertNil(watchdog.stalled(now: start.addingTimeInterval(20), sessionReadyAt: start))
        XCTAssertNotNil(watchdog.stalled(now: start.addingTimeInterval(22), sessionReadyAt: start))
    }

    func testAudioResponseWatchdogIgnoresSilenceAndBrokenActivityStreak() {
        let start = Date(timeIntervalSince1970: 1_000)
        var watchdog = RealtimeAudioResponseWatchdog(
            stallInterval: 10,
            activeAudioRMSThreshold: 0.01,
            activeAudioGapResetInterval: 2
        )
        let silence = Self.pcm16(samples: [0, 0, 0])
        let activeAudio = Self.pcm16(samples: [Int16.max / 2, Int16.max / 2, Int16.max / 2])

        watchdog.noteOutgoingAudio(silence, now: start)
        XCTAssertNil(watchdog.stalled(now: start.addingTimeInterval(30), sessionReadyAt: start))

        watchdog.noteOutgoingAudio(activeAudio, now: start)
        XCTAssertNil(watchdog.stalled(now: start.addingTimeInterval(3), sessionReadyAt: start))

        watchdog.noteOutgoingAudio(activeAudio, now: start.addingTimeInterval(4))
        XCTAssertNil(watchdog.stalled(now: start.addingTimeInterval(13), sessionReadyAt: start))
    }

    private static func pcm16(samples: [Int16]) -> Data {
        var data = Data()
        for sample in samples {
            var value = sample.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }
}
