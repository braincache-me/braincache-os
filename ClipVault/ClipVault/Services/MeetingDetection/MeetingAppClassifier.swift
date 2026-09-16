import Foundation

/// Pure classification logic for meeting detection: maps the bundle ID of a
/// process that is actively capturing microphone audio to what it most likely
/// means for the user, and matches browser window titles against known
/// conferencing platforms. Kept free of AppKit/CoreAudio so it is unit-testable.
enum MeetingAppClassifier {

    /// A browser family groups the main app and its helper processes (the
    /// helpers are what actually hold the microphone in Chromium/WebKit) under
    /// the bundle ID of the window-owning main app, which is what the
    /// Accessibility title scan needs.
    struct BrowserFamily: Equatable {
        let displayName: String
        /// Bundle ID prefixes that identify the family, including helpers.
        let bundleIDPrefixes: [String]
        /// Bundle ID of the app that owns the windows (used for the AX scan).
        let mainBundleID: String
    }

    enum Classification: Equatable {
        /// A native conferencing app (Zoom, Teams, FaceTime…) — high confidence.
        case meetingApp(name: String)
        /// A browser (or one of its helper processes) — needs a tab-title check.
        case browser(BrowserFamily)
        /// Everything else: system daemons, dictation, unknown apps.
        case ignored
    }

    /// Native apps whose mic use we treat as "you are on a call".
    /// Prefix-matched so helper bundles (e.g. `com.microsoft.teams2.helper`)
    /// classify the same as their parent.
    private static let meetingAppPrefixes: [(prefix: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("Cisco-Systems.Spark", "Webex"),
        ("com.webex.", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.apple.FaceTime", "FaceTime"),
        // FaceTime's conference daemon holds the mic during calls.
        ("com.apple.avconferenced", "FaceTime"),
        ("com.skype.skype", "Skype"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.viber.osx", "Viber"),
        ("jp.naver.line.mac", "LINE"),
    ]

    static let browserFamilies: [BrowserFamily] = [
        BrowserFamily(displayName: "Chrome",
                      bundleIDPrefixes: ["com.google.Chrome"],
                      mainBundleID: "com.google.Chrome"),
        BrowserFamily(displayName: "Edge",
                      bundleIDPrefixes: ["com.microsoft.edgemac"],
                      mainBundleID: "com.microsoft.edgemac"),
        BrowserFamily(displayName: "Brave",
                      bundleIDPrefixes: ["com.brave.Browser"],
                      mainBundleID: "com.brave.Browser"),
        BrowserFamily(displayName: "Vivaldi",
                      bundleIDPrefixes: ["com.vivaldi.Vivaldi"],
                      mainBundleID: "com.vivaldi.Vivaldi"),
        BrowserFamily(displayName: "Arc",
                      bundleIDPrefixes: ["company.thebrowser.Browser", "company.thebrowser.browser"],
                      mainBundleID: "company.thebrowser.Browser"),
        BrowserFamily(displayName: "Opera",
                      bundleIDPrefixes: ["com.operasoftware.Opera"],
                      mainBundleID: "com.operasoftware.Opera"),
        BrowserFamily(displayName: "Firefox",
                      bundleIDPrefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer"],
                      mainBundleID: "org.mozilla.firefox"),
        // Safari's media capture lives in the shared WebKit GPU process. Any
        // WebKit host can own it, so the follow-up AX scan of Safari windows
        // is what decides whether this is actually a Safari meeting.
        BrowserFamily(displayName: "Safari",
                      bundleIDPrefixes: ["com.apple.Safari", "com.apple.WebKit"],
                      mainBundleID: "com.apple.Safari"),
    ]

    static func classify(bundleID: String) -> Classification {
        // Never react to ourselves (covers dev/prod variants and any helpers).
        if bundleID.hasPrefix("com.TalkFlow.") { return .ignored }
        for entry in meetingAppPrefixes where bundleID.hasPrefix(entry.prefix) {
            return .meetingApp(name: entry.name)
        }
        for family in browserFamilies {
            if family.bundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
                return .browser(family)
            }
        }
        return .ignored
    }

    // MARK: - Browser window-title matching

    /// Google Meet codes look like "abc-defg-hij" and appear in the tab/window
    /// title ("Meet – abc-defg-hij").
    private static let meetCodeRegex = try? NSRegularExpression(
        pattern: "\\b[a-z]{3}-[a-z]{4}-[a-z]{3}\\b"
    )

    /// Substrings (lowercased) in a browser window title that indicate an
    /// open conferencing tab. Only consulted while that browser is actively
    /// holding the microphone, so precision requirements are moderate.
    private static let meetingTitleMarkers: [String] = [
        "google meet",
        "meet.google",
        "zoom meeting",
        "zoom.us",
        "zoom workplace",
        "microsoft teams",
        "webex",
        "whereby",
        "jitsi",
        "meet.jit.si",
        "discord",
        "huddle",
        "gather.town",
        "around.co",
    ]

    /// True when a browser window title looks like an active conferencing tab.
    static func titleSuggestsMeeting(_ title: String) -> Bool {
        let lowered = title.lowercased()
        guard !lowered.isEmpty else { return false }
        if meetingTitleMarkers.contains(where: { lowered.contains($0) }) {
            return true
        }
        if lowered.contains("meet"),
           let regex = meetCodeRegex,
           regex.firstMatch(
               in: lowered,
               range: NSRange(lowered.startIndex..., in: lowered)
           ) != nil {
            return true
        }
        return false
    }

    static func anyTitleSuggestsMeeting(_ titles: [String]) -> Bool {
        titles.contains(where: titleSuggestsMeeting)
    }
}

/// Pure decision rules for when the "record this meeting?" bubble may appear.
enum MeetingPromptPolicy {

    /// Seconds the external mic session must persist before we prompt —
    /// filters out permission checks and app-startup blips.
    static let debounceSeconds: TimeInterval = 2.5

    /// Seconds of silence (no external mic use) before the session is
    /// considered over — short call drops don't end the session.
    static let sessionEndGraceSeconds: TimeInterval = 10

    /// Chromium exposes only the frontmost tab's title per window, so a
    /// meeting tab that is not frontmost is invisible to the AX scan. While a
    /// browser keeps holding the mic without a verified meeting title, retry
    /// the title check at this interval instead of giving up for the session.
    static let browserRecheckSeconds: TimeInterval = 10

    /// How long the bubble stays up before dismissing itself.
    static let bubbleAutoDismissSeconds: TimeInterval = 90

    /// Menu-bar bubble text after the window attached to a "Save recording"
    /// session disappeared. `saved` is `false` when the file was too short
    /// to keep. The transcription itself keeps running either way — the
    /// bubble offers to stop it because a closed meeting window usually
    /// means the meeting is over.
    static func mediaSourceLostMessage(appName: String, saved: Bool) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = app.isEmpty ? "The attached window" : "The \(app) window"
        let outcome = saved
            ? "video recording stopped and was saved."
            : "video recording stopped (nothing long enough to save)."
        return "\(subject) was closed — \(outcome) Transcription is still running. Stop it too?"
    }

    static func isSnoozed(now: Date, snoozeUntil: Date?) -> Bool {
        guard let snoozeUntil else { return false }
        return now < snoozeUntil
    }

    /// After the external mic session ends while BrainCache is still
    /// recording: offer to stop, but only when the recording plausibly is the
    /// meeting recording (system audio captured) and the voice panel is
    /// hidden — with the panel visible its own Stop button is reminder enough.
    static func shouldSuggestStop(
        voiceRecordingActive: Bool,
        includesSystemAudio: Bool,
        panelVisible: Bool
    ) -> Bool {
        voiceRecordingActive && includesSystemAudio && !panelVisible
    }

    /// Whether a freshly debounced external mic session should show the bubble.
    /// - Parameters:
    ///   - detectionEnabled: Preferences toggle.
    ///   - voicePipelineIdle: false while BrainCache itself records/transcribes.
    ///   - alreadyPromptedThisSession: the bubble fired once for this session.
    static func shouldPrompt(
        detectionEnabled: Bool,
        voicePipelineIdle: Bool,
        alreadyPromptedThisSession: Bool,
        now: Date,
        snoozeUntil: Date?
    ) -> Bool {
        detectionEnabled
            && voicePipelineIdle
            && !alreadyPromptedThisSession
            && !isSnoozed(now: now, snoozeUntil: snoozeUntil)
    }
}
