import XCTest
@testable import ClipVault

final class RealtimeTranslationClientTests: XCTestCase {

    func testSessionUpdateSetsOutputLanguage() throws {
        let event = RealtimeTranslationClient.makeSessionUpdateEvent(targetLanguage: "es")

        XCTAssertEqual(event["type"] as? String, "session.update")

        let session = try XCTUnwrap(event["session"] as? [String: Any])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["language"] as? String, "es")

        // Translation sessions don't configure input transcription — that's
        // implicit on the /v1/realtime/translations endpoint.
        XCTAssertNil(audio["input"])
    }

    func testTranslationLanguageListMatchesDocumentedSet() {
        let codes = Set(Settings.Defaults.translationLanguages.map { $0.code })
        // Spot-check the 12 languages OpenAI documents for the realtime
        // translate model. If this list shrinks unexpectedly, the popup
        // would silently drop options.
        for code in ["zh", "en", "fr", "de", "hi", "id", "it", "ja", "ko", "pt", "ru", "es"] {
            XCTAssertTrue(codes.contains(code), "missing language code: \(code)")
        }
    }

    func testTranslationDefaultsAreSane() {
        XCTAssertEqual(Settings.Defaults.translationModel, "gpt-realtime-translate")
        XCTAssertEqual(Settings.Defaults.translationTargetLanguage, "en")
    }
}
