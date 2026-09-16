import XCTest
@testable import ClipVault

final class MeetingDetectionTests: XCTestCase {

    // MARK: - Bundle-ID classification

    func testClassifiesKnownMeetingApps() {
        XCTAssertEqual(
            MeetingAppClassifier.classify(bundleID: "us.zoom.xos"),
            .meetingApp(name: "Zoom")
        )
        XCTAssertEqual(
            MeetingAppClassifier.classify(bundleID: "com.microsoft.teams2"),
            .meetingApp(name: "Microsoft Teams")
        )
        XCTAssertEqual(
            MeetingAppClassifier.classify(bundleID: "com.tinyspeck.slackmacgap"),
            .meetingApp(name: "Slack")
        )
        XCTAssertEqual(
            MeetingAppClassifier.classify(bundleID: "com.apple.avconferenced"),
            .meetingApp(name: "FaceTime")
        )
    }

    func testClassifiesBrowserHelpersIntoTheirFamily() {
        // The Chromium audio service helper is what actually holds the mic.
        guard case .browser(let chromeFamily) =
                MeetingAppClassifier.classify(bundleID: "com.google.Chrome.helper") else {
            return XCTFail("Chrome helper should classify as a browser")
        }
        XCTAssertEqual(chromeFamily.mainBundleID, "com.google.Chrome")

        // Safari's capture lives in the shared WebKit GPU process.
        guard case .browser(let safariFamily) =
                MeetingAppClassifier.classify(bundleID: "com.apple.WebKit.GPU") else {
            return XCTFail("WebKit GPU process should classify as a browser")
        }
        XCTAssertEqual(safariFamily.mainBundleID, "com.apple.Safari")
    }

    func testIgnoresSystemDaemonsUnknownAppsAndSelf() {
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.apple.controlcenter"), .ignored)
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.apple.assistantd"), .ignored)
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.apple.CoreSpeech"), .ignored)
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.some.voicerecorder"), .ignored)
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: ""), .ignored)
        // Never react to our own (dev or prod) processes.
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.TalkFlow.BrainCache"), .ignored)
        XCTAssertEqual(MeetingAppClassifier.classify(bundleID: "com.TalkFlow.BrainCache.dev"), .ignored)
    }

    // MARK: - Browser window-title matching

    func testMeetingTitlesMatch() {
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("Meet – abc-defg-hij"))
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("kickoff · Google Meet – Google Chrome"))
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("Zoom Meeting"))
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("Weekly sync | Microsoft Teams"))
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("Cisco Webex Meetings"))
        XCTAssertTrue(MeetingAppClassifier.titleSuggestsMeeting("standup — Whereby"))
    }

    func testNonMeetingTitlesDoNotMatch() {
        XCTAssertFalse(MeetingAppClassifier.titleSuggestsMeeting(""))
        XCTAssertFalse(MeetingAppClassifier.titleSuggestsMeeting("Inbox (3) - Gmail - Google Chrome"))
        XCTAssertFalse(MeetingAppClassifier.titleSuggestsMeeting("Online Voice Recorder"))
        XCTAssertFalse(MeetingAppClassifier.titleSuggestsMeeting("Dictation.io - Speech to text"))
        // "meet" alone without a Meet room code is not enough.
        XCTAssertFalse(MeetingAppClassifier.titleSuggestsMeeting("How to meet new people - Blog"))
    }

    func testAnyTitleSuggestsMeeting() {
        XCTAssertTrue(MeetingAppClassifier.anyTitleSuggestsMeeting(
            ["Gmail", "Meet – abc-defg-hij"]
        ))
        XCTAssertFalse(MeetingAppClassifier.anyTitleSuggestsMeeting(["Gmail", "GitHub"]))
        XCTAssertFalse(MeetingAppClassifier.anyTitleSuggestsMeeting([]))
    }

    // MARK: - Prompt policy

    func testShouldPromptWhenAllConditionsHold() {
        XCTAssertTrue(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: true,
            voicePipelineIdle: true,
            alreadyPromptedThisSession: false,
            now: Date(timeIntervalSince1970: 1_000),
            snoozeUntil: nil
        ))
    }

    func testShouldNotPromptWhenDisabledOrBusyOrAlreadyPrompted() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: false, voicePipelineIdle: true,
            alreadyPromptedThisSession: false, now: now, snoozeUntil: nil
        ))
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: true, voicePipelineIdle: false,
            alreadyPromptedThisSession: false, now: now, snoozeUntil: nil
        ))
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: true, voicePipelineIdle: true,
            alreadyPromptedThisSession: true, now: now, snoozeUntil: nil
        ))
    }

    func testSnoozeSuppressesUntilExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let later = now.addingTimeInterval(3600)
        XCTAssertFalse(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: true, voicePipelineIdle: true,
            alreadyPromptedThisSession: false, now: now, snoozeUntil: later
        ))
        // Snooze expired — prompting allowed again.
        XCTAssertTrue(MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: true, voicePipelineIdle: true,
            alreadyPromptedThisSession: false,
            now: later.addingTimeInterval(1), snoozeUntil: later
        ))
    }

    // MARK: - Settings round-trip

    func testMeetingDetectionSettingsDefaultsAndPersistence() {
        let suiteName = "com.clipvault.tests.meetingDetection"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = Settings(defaults: defaults)

        XCTAssertTrue(settings.meetingDetectionEnabled)
        XCTAssertNil(settings.meetingPromptSnoozeUntil)
        XCTAssertEqual(settings.meetingPromptSnoozeMinutes, 60)

        settings.meetingDetectionEnabled = false
        let until = Date(timeIntervalSince1970: 2_000_000)
        settings.meetingPromptSnoozeUntil = until

        XCTAssertFalse(settings.meetingDetectionEnabled)
        XCTAssertEqual(
            settings.meetingPromptSnoozeUntil?.timeIntervalSince1970 ?? 0,
            until.timeIntervalSince1970,
            accuracy: 0.001
        )

        settings.meetingPromptSnoozeUntil = nil
        XCTAssertNil(settings.meetingPromptSnoozeUntil)

        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Detector browser resolution (with injected title reader)

    private final class StubTitleReader: BrowserWindowTitleReading {
        var titlesByBundleID: [String: [String]] = [:]
        func windowTitles(mainBundleID: String) -> [String]? {
            titlesByBundleID[mainBundleID]
        }
    }

    // MARK: - Stop suggestion after meeting end

    func testSuggestsStopWhenRecordingWithSystemAudioAndPanelHidden() {
        XCTAssertTrue(MeetingPromptPolicy.shouldSuggestStop(
            voiceRecordingActive: true, includesSystemAudio: true, panelVisible: false
        ))
    }

    func testNoStopSuggestionWhenNotRecordingOrPanelVisibleOrMicOnly() {
        // Not recording — nothing to stop.
        XCTAssertFalse(MeetingPromptPolicy.shouldSuggestStop(
            voiceRecordingActive: false, includesSystemAudio: true, panelVisible: false
        ))
        // Panel visible — its own Stop button is reminder enough.
        XCTAssertFalse(MeetingPromptPolicy.shouldSuggestStop(
            voiceRecordingActive: true, includesSystemAudio: true, panelVisible: true
        ))
        // Mic-only dictation is not a meeting recording.
        XCTAssertFalse(MeetingPromptPolicy.shouldSuggestStop(
            voiceRecordingActive: true, includesSystemAudio: false, panelVisible: false
        ))
    }

    // MARK: - Bubble anchor visibility (hidden / notch-parked status items)

    /// 1512×982 MacBook-style screen with a notch: menu bar strips left and
    /// right of the notch, and a status item parked inside the notch gap.
    private static let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
    private static let auxLeft = NSRect(x: 0, y: 958, width: 606, height: 24)
    private static let auxRight = NSRect(x: 906, y: 958, width: 606, height: 24)

    func testAnchorVisibleInRightMenuBarStrip() {
        XCTAssertTrue(MeetingPromptBubbleController.anchorIsVisible(
            buttonFrame: NSRect(x: 1400, y: 958, width: 24, height: 24),
            screenFrame: Self.screen,
            auxiliaryTopLeftArea: Self.auxLeft,
            auxiliaryTopRightArea: Self.auxRight,
            windowOcclusionVisible: true
        ))
    }

    func testAnchorParkedUnderNotchIsNotVisible() {
        XCTAssertFalse(MeetingPromptBubbleController.anchorIsVisible(
            buttonFrame: NSRect(x: 740, y: 958, width: 24, height: 24),
            screenFrame: Self.screen,
            auxiliaryTopLeftArea: Self.auxLeft,
            auxiliaryTopRightArea: Self.auxRight,
            windowOcclusionVisible: true
        ))
    }

    func testAnchorOccludedIsNotVisible() {
        XCTAssertFalse(MeetingPromptBubbleController.anchorIsVisible(
            buttonFrame: NSRect(x: 1400, y: 958, width: 24, height: 24),
            screenFrame: Self.screen,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            windowOcclusionVisible: false
        ))
    }

    func testAnchorOffScreenIsNotVisible() {
        XCTAssertFalse(MeetingPromptBubbleController.anchorIsVisible(
            buttonFrame: NSRect(x: 2000, y: 958, width: 24, height: 24),
            screenFrame: Self.screen,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            windowOcclusionVisible: true
        ))
    }

    func testAnchorVisibleOnNotchlessScreen() {
        XCTAssertTrue(MeetingPromptBubbleController.anchorIsVisible(
            buttonFrame: NSRect(x: 740, y: 958, width: 24, height: 24),
            screenFrame: Self.screen,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil,
            windowOcclusionVisible: true
        ))
    }

    func testMeetingAppWinsOverBrowser() {
        guard case .meetingApp(let name) =
                MeetingAppClassifier.classify(bundleID: "us.zoom.xos") else {
            return XCTFail("expected meeting app")
        }
        XCTAssertEqual(name, "Zoom")
        // Browsers require the extra title check; native apps never do.
        guard case .browser = MeetingAppClassifier.classify(bundleID: "com.google.Chrome.helper") else {
            return XCTFail("expected browser")
        }
    }
}
