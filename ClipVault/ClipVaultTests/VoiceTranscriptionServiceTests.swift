import XCTest
@testable import ClipVault

final class VoiceTranscriptionServiceTests: XCTestCase {

    func testCombinedTranscriptUsesTimelineWithSourceLabels() {
        var transcript = VoiceTranscriptionService.LiveTranscript()
        transcript.entries = [
            .init(source: .system, timestamp: 2.2, text: "Can you hear me?", isFinal: true),
            .init(source: .mic, timestamp: 1.1, text: "Yes, go ahead.", isFinal: true),
        ]

        XCTAssertEqual(
            transcript.combined,
            "[0:01 Mic] Yes, go ahead.\n[0:02 System] Can you hear me?"
        )
    }

    func testCombinedTranscriptFallsBackToLegacyTextWhenTimelineIsEmpty() {
        var transcript = VoiceTranscriptionService.LiveTranscript()
        transcript.mic = "Mic text"
        transcript.system = "System text"

        XCTAssertEqual(transcript.combined, "[Mic] Mic text\n\n[Sys] System text")
    }

    func testCombinedTranscriptOmitsLabelsWhenOnlyMicEntries() {
        var transcript = VoiceTranscriptionService.LiveTranscript()
        transcript.entries = [
            .init(source: .mic, timestamp: 0.5, text: "Hello there.", isFinal: true),
            .init(source: .mic, timestamp: 2.0, text: "How are you?", isFinal: true),
        ]

        XCTAssertEqual(transcript.combined, "Hello there. How are you?")
    }

    func testCombinedTranscriptOmitsSystemHeaderWhenOnlyMicLegacyText() {
        var transcript = VoiceTranscriptionService.LiveTranscript()
        transcript.mic = "Mic text"

        XCTAssertEqual(transcript.combined, "Mic text")
    }

    func testMicGateSuppressesLikelyEchoWhenSystemAudioIsRecent() {
        XCTAssertTrue(VoiceTranscriptionRecorder.shouldSuppressMicAudio(
            includeSystemAudio: true,
            lastSystemAudioLoudAt: 100,
            now: 100.1,
            micRMS: 0.02,
            lastSystemAudioRMS: 0.05,
            loudThreshold: 0.015,
            holdSeconds: 0.25,
            micDominanceRatio: 1.5,
            minimumDominantMicRMS: 0.02
        ))
    }

    func testMicGateLetsDominantMicSpeechBreakThroughQuietSystemAudio() {
        XCTAssertFalse(VoiceTranscriptionRecorder.shouldSuppressMicAudio(
            includeSystemAudio: true,
            lastSystemAudioLoudAt: 100,
            now: 100.1,
            micRMS: 0.035,
            lastSystemAudioRMS: 0.016,
            loudThreshold: 0.015,
            holdSeconds: 0.25,
            micDominanceRatio: 1.5,
            minimumDominantMicRMS: 0.02
        ))
    }

    func testMicGateOpensAfterHoldWindow() {
        XCTAssertFalse(VoiceTranscriptionRecorder.shouldSuppressMicAudio(
            includeSystemAudio: true,
            lastSystemAudioLoudAt: 100,
            now: 100.4,
            micRMS: 0.02,
            lastSystemAudioRMS: 0.05,
            loudThreshold: 0.015,
            holdSeconds: 0.25,
            micDominanceRatio: 1.5,
            minimumDominantMicRMS: 0.02
        ))
    }

    func testMicOnlyFinalizeIntentStillPastes() {
        XCTAssertEqual(
            VoiceTranscriptionService.effectiveFinalizeIntent(.paste, capturedSystemAudio: false),
            .paste
        )
    }

    func testSystemAudioFinalizeIntentSkipsPaste() {
        XCTAssertEqual(
            VoiceTranscriptionService.effectiveFinalizeIntent(.paste, capturedSystemAudio: true),
            .skipPaste
        )
    }

    func testSystemAudioRewriteIntentSkipsPaste() {
        XCTAssertEqual(
            VoiceTranscriptionService.effectiveFinalizeIntent(.rewriteAndPaste, capturedSystemAudio: true),
            .skipPaste
        )
    }
}
