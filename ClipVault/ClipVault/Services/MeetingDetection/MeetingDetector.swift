import AppKit
import Foundation

/// Detects that an online meeting has (probably) started by watching for other
/// processes capturing the microphone, and asks the bubble UI to offer
/// recording. The pipeline:
///
/// 1. `MicUsageMonitor` (macOS 14+ CoreAudio process objects) reports every
///    external process with an active input stream.
/// 2. `MeetingAppClassifier` keeps only known conferencing apps and browsers.
/// 3. A rising edge starts a debounce; if the session survives it, native
///    meeting apps prompt immediately, browsers prompt only when one of their
///    window titles looks like a conferencing tab (AX scan, no extra
///    permission) — this is what separates a Meet call from a dictation site.
/// 4. "Not now" snoozes prompting; the session must end (mic released for a
///    grace period) before a new prompt can fire.
final class MeetingDetector {

    static let shared = MeetingDetector()

    /// What the bubble should say. `platformName` is e.g. "Zoom" or "Chrome".
    struct Detection: Equatable {
        let platformName: String
    }

    /// Injected by AppDelegate: shows the bubble for a detection.
    var onMeetingDetected: ((Detection) -> Void)?
    /// Injected by AppDelegate: the external mic session ended (hide bubble).
    var onMeetingEnded: (() -> Void)?

    private var monitor: AnyObject?
    private let titleReader: BrowserWindowTitleReading
    private let now: () -> Date

    // Session state (main-thread only).
    private var sessionActive = false
    private var promptedThisSession = false
    private var debounceWorkItem: DispatchWorkItem?
    private var sessionEndWorkItem: DispatchWorkItem?
    private var lastInterestingProcesses: [MicAudioProcess] = []

    static var isSupported: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    init(titleReader: BrowserWindowTitleReading = BrowserWindowTitleReader(),
         now: @escaping () -> Date = Date.init) {
        self.titleReader = titleReader
        self.now = now
    }

    func start() {
        guard Settings.shared.meetingDetectionEnabled, monitor == nil else { return }
        guard #available(macOS 14.0, *) else { return }
        let monitor = MicUsageMonitor()
        monitor.onChange = { [weak self] processes in
            DispatchQueue.main.async {
                self?.handleMicProcessesChanged(processes)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    func stop() {
        if #available(macOS 14.0, *) {
            (monitor as? MicUsageMonitor)?.stop()
        }
        monitor = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        sessionEndWorkItem?.cancel()
        sessionEndWorkItem = nil
        sessionActive = false
        promptedThisSession = false
    }

    /// Re-evaluate the Preferences toggle (called when it changes).
    func settingsDidChange() {
        if Settings.shared.meetingDetectionEnabled {
            start()
        } else {
            stop()
            onMeetingEnded?()
        }
    }

    /// "Not now" pressed: keep quiet for the configured interval.
    func snooze() {
        let minutes = Settings.shared.meetingPromptSnoozeMinutes
        Settings.shared.meetingPromptSnoozeUntil =
            now().addingTimeInterval(TimeInterval(minutes) * 60)
    }

    // MARK: - Session tracking

    private func handleMicProcessesChanged(_ processes: [MicAudioProcess]) {
        let interesting = processes.filter {
            MeetingAppClassifier.classify(bundleID: $0.bundleID) != .ignored
        }
        NSLog("MeetingDetector: mic processes=%@ interesting=%@",
              processes.map(\.bundleID).joined(separator: ","),
              interesting.map(\.bundleID).joined(separator: ","))
        lastInterestingProcesses = interesting

        if interesting.isEmpty {
            scheduleSessionEndIfNeeded()
        } else {
            sessionEndWorkItem?.cancel()
            sessionEndWorkItem = nil
            if !sessionActive {
                sessionActive = true
                promptedThisSession = false
                scheduleDebouncedEvaluation()
            }
        }
    }

    private func scheduleDebouncedEvaluation() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.evaluateSession() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MeetingPromptPolicy.debounceSeconds, execute: item
        )
    }

    private func scheduleSessionEndIfNeeded() {
        guard sessionActive, sessionEndWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sessionEndWorkItem = nil
            guard self.lastInterestingProcesses.isEmpty else { return }
            self.sessionActive = false
            self.promptedThisSession = false
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.onMeetingEnded?()
        }
        sessionEndWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MeetingPromptPolicy.sessionEndGraceSeconds, execute: item
        )
    }

    /// Runs after the debounce: decide whether this mic session is a meeting
    /// worth prompting for.
    private func evaluateSession() {
        debounceWorkItem = nil
        guard sessionActive, !lastInterestingProcesses.isEmpty else {
            NSLog("MeetingDetector: evaluate skipped (sessionActive=%d, count=%d)",
                  sessionActive ? 1 : 0, lastInterestingProcesses.count)
            return
        }

        guard MeetingPromptPolicy.shouldPrompt(
            detectionEnabled: Settings.shared.meetingDetectionEnabled,
            voicePipelineIdle: VoiceTranscriptionService.shared.state == .idle,
            alreadyPromptedThisSession: promptedThisSession,
            now: now(),
            snoozeUntil: Settings.shared.meetingPromptSnoozeUntil
        ) else {
            NSLog("MeetingDetector: policy said no (enabled=%d idle=%d prompted=%d snoozed=%d)",
                  Settings.shared.meetingDetectionEnabled ? 1 : 0,
                  VoiceTranscriptionService.shared.state == .idle ? 1 : 0,
                  promptedThisSession ? 1 : 0,
                  MeetingPromptPolicy.isSnoozed(
                      now: now(), snoozeUntil: Settings.shared.meetingPromptSnoozeUntil
                  ) ? 1 : 0)
            return
        }

        guard let detection = resolveDetection() else {
            NSLog("MeetingDetector: no detection resolved (browser without meeting title?) — recheck in %.0fs",
                  MeetingPromptPolicy.browserRecheckSeconds)
            scheduleBrowserRecheck()
            return
        }
        NSLog("MeetingDetector: MEETING DETECTED platform=%@", detection.platformName)
        promptedThisSession = true
        onMeetingDetected?(detection)
    }

    /// A browser is still holding the mic but no window title confirmed a
    /// meeting (the tab is probably not frontmost in its window). Try again
    /// while the session lasts; reuses `debounceWorkItem` so session end and
    /// `stop()` cancel the retry the same way they cancel the debounce.
    private func scheduleBrowserRecheck() {
        guard sessionActive, debounceWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.evaluateSession() }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MeetingPromptPolicy.browserRecheckSeconds, execute: item
        )
    }

    /// Native meeting apps win over browsers. A browser only counts when a
    /// window title looks like a conferencing tab; when Accessibility is
    /// unavailable we can't verify, so we prompt anyway — the bubble is a
    /// question, not an action, and a rare false positive beats silence.
    private func resolveDetection() -> Detection? {
        var browserFamilies: [MeetingAppClassifier.BrowserFamily] = []
        for process in lastInterestingProcesses {
            switch MeetingAppClassifier.classify(bundleID: process.bundleID) {
            case .meetingApp(let name):
                return Detection(platformName: name)
            case .browser(let family):
                if !browserFamilies.contains(family) {
                    browserFamilies.append(family)
                }
            case .ignored:
                continue
            }
        }
        for family in browserFamilies {
            let maybeTitles = titleReader.windowTitles(mainBundleID: family.mainBundleID)
            NSLog("MeetingDetector: titles for %@: %@",
                  family.mainBundleID, maybeTitles?.joined(separator: " | ") ?? "<nil>")
            guard let titles = maybeTitles else {
                // Not running (stale helper / non-Safari WebKit host) — skip;
                // unless nothing is verifiable at all, handled below.
                continue
            }
            if MeetingAppClassifier.anyTitleSuggestsMeeting(titles) {
                return Detection(platformName: family.displayName)
            }
        }
        // No verifiable browser had a meeting-looking window. If verification
        // was impossible (no Accessibility), fall back to a generic prompt.
        if !browserFamilies.isEmpty, !AccessibilityChecker.isGranted {
            return Detection(platformName: browserFamilies[0].displayName)
        }
        return nil
    }
}
