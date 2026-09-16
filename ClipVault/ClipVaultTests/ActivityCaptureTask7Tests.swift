import XCTest
@testable import ClipVault

/// Task 7 — Onboarding copy for Activity Capture permissions guidance.
///
/// These tests verify that the permission step string constants contain the
/// key phrases that explain both the clipboard/paste and Activity Capture
/// purposes for each permission, and reflect the privacy posture of the
/// recorder (local-only, disabled by default, pause/stop anytime).
final class OnboardingPermissionsCopyTask7Tests: XCTestCase {

    // MARK: - Permissions step subtitle

    func testPermissionsSubtitleMentionsActivityCapture() {
        let subtitle = OnboardingWindowController.permissionsStepSubtitle
        XCTAssertTrue(
            subtitle.localizedCaseInsensitiveContains("Activity Capture"),
            "Subtitle should mention Activity Capture so users know it affects the recorder"
        )
    }

    func testPermissionsSubtitleMentionsOffByDefault() {
        let subtitle = OnboardingWindowController.permissionsStepSubtitle
        XCTAssertTrue(
            subtitle.localizedCaseInsensitiveContains("off by default") ||
            subtitle.localizedCaseInsensitiveContains("disabled by default"),
            "Subtitle should clarify that Activity Capture is off by default"
        )
    }

    // MARK: - Accessibility card body

    func testAccessibilityCardBodyMentionsPasteBack() {
        let body = OnboardingWindowController.accessibilityCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("paste"),
            "Accessibility body should mention paste-back so users understand the clipboard use case"
        )
    }

    func testAccessibilityCardBodyMentionsActivityCapture() {
        let body = OnboardingWindowController.accessibilityCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("Activity Capture") ||
            body.localizedCaseInsensitiveContains("recording"),
            "Accessibility body should describe its role in UI interaction capture"
        )
    }

    func testAccessibilityCardBodyMentionsControlNames() {
        let body = OnboardingWindowController.accessibilityCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("control") ||
            body.localizedCaseInsensitiveContains("role"),
            "Accessibility body should mention control names/roles for interaction logging"
        )
    }

    func testAccessibilityCardBodyMentionsOnlyWhenEnabled() {
        let body = OnboardingWindowController.accessibilityCardBody
        // Must communicate that AX inspection for recording happens only when enabled
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("enable") ||
            body.localizedCaseInsensitiveContains("when you"),
            "Accessibility body should clarify interaction capture is conditional on enabling recording"
        )
    }

    // MARK: - Screen Recording card body

    func testScreenRecordingCardBodyMentionsScreenshots() {
        let body = OnboardingWindowController.screenRecordingCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("screenshot"),
            "Screen Recording body should mention screenshots so users know why this permission is needed"
        )
    }

    func testScreenRecordingCardBodyMentionsActivityCapture() {
        let body = OnboardingWindowController.screenRecordingCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("Activity Capture") ||
            body.localizedCaseInsensitiveContains("recording"),
            "Screen Recording body should attribute the permission to Activity Capture"
        )
    }

    func testScreenRecordingCardBodyMentionsLocalOrNoNetwork() {
        let body = OnboardingWindowController.screenRecordingCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("local") ||
            body.localizedCaseInsensitiveContains("no network"),
            "Screen Recording body should reinforce that data stays local"
        )
    }

    func testScreenRecordingCardBodyMentionsOffByDefault() {
        let body = OnboardingWindowController.screenRecordingCardBody
        XCTAssertTrue(
            body.localizedCaseInsensitiveContains("off by default") ||
            body.localizedCaseInsensitiveContains("disabled by default"),
            "Screen Recording body should state that Activity Capture is off by default"
        )
    }

    // MARK: - Footer note

    func testFooterNoteMentionsDisabledByDefault() {
        let note = OnboardingWindowController.permissionsFooterNote
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("disabled by default") ||
            note.localizedCaseInsensitiveContains("off by default"),
            "Footer note should state that Activity Capture is disabled by default"
        )
    }

    func testFooterNoteMentionsLocalData() {
        let note = OnboardingWindowController.permissionsFooterNote
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("local") ||
            note.localizedCaseInsensitiveContains("your Mac"),
            "Footer note should reassure the user that data is kept local"
        )
    }

    func testFooterNoteMentionsPauseOrStop() {
        let note = OnboardingWindowController.permissionsFooterNote
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("pause") ||
            note.localizedCaseInsensitiveContains("stop"),
            "Footer note should mention that the user can pause or stop recording"
        )
    }

    func testFooterNoteMentionsPreferences() {
        let note = OnboardingWindowController.permissionsFooterNote
        XCTAssertTrue(
            note.localizedCaseInsensitiveContains("Preferences"),
            "Footer note should mention where to find permissions in Preferences"
        )
    }

    // MARK: - String distinctness

    func testCardBodiesAreDistinct() {
        XCTAssertNotEqual(
            OnboardingWindowController.accessibilityCardBody,
            OnboardingWindowController.screenRecordingCardBody,
            "Accessibility and Screen Recording cards must have distinct descriptions"
        )
    }

    func testPermissionsSubtitleIsNotEmpty() {
        XCTAssertFalse(OnboardingWindowController.permissionsStepSubtitle.isEmpty)
    }

    func testAccessibilityCardBodyIsNotEmpty() {
        XCTAssertFalse(OnboardingWindowController.accessibilityCardBody.isEmpty)
    }

    func testScreenRecordingCardBodyIsNotEmpty() {
        XCTAssertFalse(OnboardingWindowController.screenRecordingCardBody.isEmpty)
    }

    func testFooterNoteIsNotEmpty() {
        XCTAssertFalse(OnboardingWindowController.permissionsFooterNote.isEmpty)
    }
}
