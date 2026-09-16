import AppKit
import ApplicationServices
import os

/// The lifecycle state of the activity capture coordinator.
enum ActivityCaptureState: Equatable {
    /// Capture has never started (initial state).
    case idle
    /// Capture is actively recording events.
    case recording
    /// Capture is temporarily paused by the user.
    case paused
}

// MARK: - Coordinator

/// Central coordinator for UI activity recording.
///
/// Owns global `NSEvent` monitors for mouse clicks and keyboard shortcuts,
/// drives `ActivityElementInspector` for AX metadata at click positions,
/// and receives focus-change callbacks from `ActivityFocusObserver`.
/// All captured events are forwarded to `ActivityLogWriter`.
///
/// Screenshot capture is driven by `WindowScreenshotService` (optional) via
/// `ScreenshotCapturePolicy`. Screenshots are triggered on app-switch,
/// window-focus change, title change, idle resume, and periodic fallback.
///
/// BrainCache's own windows are excluded from capture by default.
/// Apps listed in `excludedBundleIDs` are silently skipped.
///
/// Secure text fields never have their value recorded — the `controlValue`
/// is always `nil` when `isSecureField` is true.
final class ActivityCaptureCoordinator {

    // MARK: - State

    private(set) var state: ActivityCaptureState = .idle

    // MARK: - Dependencies (injectable for testing)

    let logWriter: ActivityLogWriter
    let axInspector: ActivityAXInspecting
    let focusObserver: ActivityFocusObserver

    /// The bundle ID of BrainCache itself — events from this app are always excluded.
    let ownBundleID: String

    /// Returns the current list of excluded bundle IDs (read at event time).
    let excludedBundleIDs: () -> [String]

    // MARK: - Screenshot dependencies

    /// Screenshot capture service. `nil` disables all screenshot functionality.
    var screenshotService: WindowScreenshotCapturing?

    /// Root URL for the `screenshots/` directory. Required for screenshot capture.
    var screenshotsURL: URL?

    /// Whether screenshots are currently enabled (reads Settings by default; injectable for tests).
    var screenshotsEnabled: () -> Bool

    // MARK: - Meeting audio recording dependencies

    /// Mic activity monitor. `nil` disables meeting audio detection.
    var micMonitor: MicActivityMonitoring?

    /// Meeting audio recorder. `nil` disables raw-audio meeting recording.
    var meetingRecorder: MeetingAudioRecording?

    /// Meeting transcript recorder. `nil` disables transcript meeting recording.
    var transcriptRecorder: MeetingTranscriptRecording?

    /// Root URL for the `recordings/` directory.
    var recordingsURL: URL?

    /// Root URL for the `transcripts/` directory.
    var transcriptsURL: URL?

    /// What to do when mic activity is detected (reads Settings by default).
    var meetingAudioMode: () -> ActivityCaptureAudioMode = { Settings.shared.activityCaptureAudioMode }

    // MARK: - Click OCR dependency

    /// Optional click-region OCR service. `nil` disables text-under-cursor enrichment.
    var clickOCR: ClickTextRecognizing?

    /// Whether click OCR is currently enabled (reads Settings by default; injectable for tests).
    var clickOCREnabled: () -> Bool = { Settings.shared.activityCaptureClickOCREnabled }

    /// Dedicated queue for Vision OCR so it never blocks the main thread.
    private let ocrQueue = DispatchQueue(
        label: "com.braincache.activity.click-ocr",
        qos: .userInitiated
    )

    // MARK: - Screenshot policy and idle tracking

    private(set) var capturePolicy: ScreenshotCapturePolicy

    /// Timestamp of the last mouse or keyboard activity (for idle detection).
    /// Internal (not private) so tests can seed a past date to trigger idle detection.
    var lastActivityDate = Date()

    // MARK: - Current app context (updated by focus observer)

    // Internal (not private) so tests can seed context without going through the focus observer.
    var currentAppName: String = ""
    var currentBundleID: String = ""
    var currentWindowTitle: String = ""

    /// Timestamp of the last `appActivated` we emitted, used to suppress
    /// the redundant `windowFocused` that macOS often fires immediately after.
    var lastAppActivatedDate: Date?
    /// Bundle ID matching `lastAppActivatedDate` — only same-bundle focus events
    /// within the window are suppressed.
    var lastAppActivatedBundleID: String = ""

    /// Timestamp of the last emitted `periodicCapture`. The next periodic fires
    /// only when `lastActivityDate > lastPeriodicCaptureDate` — i.e. something
    /// happened since the previous tick.
    var lastPeriodicCaptureDate: Date?
    /// Last resolved page URL for the frontmost browser tab. Updated on focus
    /// events and clicks so non-AX events (idleResumed, sessionStopped) can
    /// still carry the most recent URL.
    var currentURL: String?

    // MARK: - Keystroke aggregation

    let keystrokeAggregator: KeystrokeAggregator

    // MARK: - Click aggregation

    let clickAggregator: ClickAggregator

    // MARK: - NSEvent monitors

    private var globalMouseMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMonitor: Any?  // for BrainCache-owned windows (to absorb / skip)

    // MARK: - Periodic timer

    private var periodicTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(
        label: "com.braincache.activity.screenshot.timer",
        qos: .utility
    )

    // MARK: - Sleep / wake observers

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    // MARK: - Diagnostic logging

    /// Set to true to suppress NSLog output (useful for noise-free unit tests).
    var suppressDiagnosticLogs: Bool = false

    /// `os.Logger` so release-build messages survive into the unified log.
    /// NSLog from sandbox-style release binaries is dropped by the persistence
    /// policy, so anything we care about for production diagnosis needs this.
    private static let logger = Logger(subsystem: "com.braincache.activity", category: "coordinator")

    private func log(_ message: String) {
        guard !suppressDiagnosticLogs else { return }
        Self.logger.log("\(message, privacy: .public)")
        NSLog("ActivityCaptureCoordinator: %@", message)
    }

    // MARK: - Init

    init(
        logWriter: ActivityLogWriter,
        axInspector: ActivityAXInspecting = ActivityElementInspector(),
        focusObserver: ActivityFocusObserver = ActivityFocusObserver(),
        ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.TalkFlow.BrainCache",
        excludedBundleIDs: @escaping () -> [String] = { Settings.shared.activityCaptureExcludedBundleIDs },
        screenshotService: WindowScreenshotCapturing? = nil,
        screenshotsURL: URL? = nil,
        screenshotsEnabled: @escaping () -> Bool = { Settings.shared.activityCaptureScreenshotsEnabled },
        clickOCR: ClickTextRecognizing? = nil,
        keystrokeAggregator: KeystrokeAggregator = KeystrokeAggregator(),
        clickAggregator: ClickAggregator = ClickAggregator()
    ) {
        self.logWriter = logWriter
        self.axInspector = axInspector
        self.focusObserver = focusObserver
        self.ownBundleID = ownBundleID
        self.excludedBundleIDs = excludedBundleIDs
        self.screenshotService = screenshotService
        self.screenshotsURL = screenshotsURL
        self.screenshotsEnabled = screenshotsEnabled
        self.clickOCR = clickOCR
        self.capturePolicy = ScreenshotCapturePolicy()
        self.keystrokeAggregator = keystrokeAggregator
        self.clickAggregator = clickAggregator
        wireKeystrokeAggregator()
        wireClickAggregator()
    }

    deinit {
        stopMonitors()
        periodicTimer?.cancel()
        removeSleepWakeObservers()
    }

    // MARK: - Lifecycle

    /// Start capture: install event monitors, wire focus observer, emit `sessionStarted`.
    func start() {
        guard state == .idle else { return }
        state = .recording
        capturePolicy = ScreenshotCapturePolicy()
        lastActivityDate = Date()

        wireFocusObserver()
        focusObserver.start()
        installMonitors()
        startPeriodicTimer()
        installSleepWakeObservers()
        startMicMonitorIfNeeded()

        // Seed current context from frontmost app (may be nil before first activation event).
        if let app = NSWorkspace.shared.frontmostApplication {
            currentAppName = app.localizedName ?? app.bundleIdentifier ?? ""
            currentBundleID = app.bundleIdentifier ?? ""
        }

        emit(event(
            type: .sessionStarted,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
    }

    /// Pause capture: remove monitors but keep the focus observer running.
    func pause() {
        guard state == .recording else { return }
        keystrokeAggregator.flush()
        clickAggregator.flush()
        stopMeetingRecordingIfActive()
        micMonitor?.stop()
        state = .paused
        stopPeriodicTimer()
        removeMonitors()
        emit(event(
            type: .sessionPaused,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
    }

    /// Resume capture after a pause.
    func resume() {
        guard state == .paused else { return }
        state = .recording
        lastActivityDate = Date()  // reset idle tracker on resume
        installMonitors()
        startPeriodicTimer()
        startMicMonitorIfNeeded()
        emit(event(
            type: .sessionResumed,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
    }

    /// Stop capture entirely: remove all monitors and emit `sessionStopped`.
    func stop() {
        guard state != .idle else { return }
        keystrokeAggregator.flush()
        clickAggregator.flush()
        stopMeetingRecordingIfActive()
        micMonitor?.stop()
        let wasRecording = state == .recording
        state = .idle

        stopPeriodicTimer()
        removeSleepWakeObservers()
        if wasRecording {
            removeMonitors()
        }
        focusObserver.stop()

        // Emit sessionStopped before stopping the writer so it gets flushed.
        emit(event(
            type: .sessionStopped,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
        logWriter.stop()
    }

    // MARK: - handleEvent (internal, also used by tests)

    /// Process a click at the given screen coordinates.
    ///
    /// - Parameters:
    ///   - point: Screen position (flipped, from top-left).
    ///   - eventType: `.leftClick`, `.rightClick`, or `.otherClick`.
    func handleClickAt(_ point: CGPoint, eventType: ActivityEventType) {
        guard state == .recording else { return }
        checkAndHandleIdleResume()
        guard !shouldExclude(bundleID: currentBundleID) else { return }

        let axResult = axInspector.inspect(at: point)

        // Use window title from AX if available, otherwise use tracked context.
        let windowTitle = axResult.windowTitle ?? currentWindowTitle

        if let resolvedURL = axResult.url {
            currentURL = resolvedURL
        }

        let controlValue = axResult.isSecureField ? nil : axResult.value

        // Window-relative coordinates (top-left origin) so downstream tools can
        // align clicks with screenshots. Nil when the window frame is unknown.
        let windowClick: (x: Double, y: Double)? = axResult.windowFrame.map { frame in
            (Double(point.x - frame.origin.x), Double(point.y - frame.origin.y))
        }

        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let shouldRunOCR =
            !axResult.isSecureField &&
            clickOCR != nil &&
            clickOCREnabled() &&
            targetPID > 0

        let emitEvent: (String?) -> Void = { [weak self] nearbyText in
            guard let self else { return }
            let e = ActivityEvent(
                appName: self.currentAppName,
                bundleID: self.currentBundleID,
                windowTitle: windowTitle,
                eventType: eventType,
                controlRole: axResult.role,
                controlName: axResult.bestControlName,
                controlValue: controlValue,
                clickX: Double(point.x),
                clickY: Double(point.y),
                windowClickX: windowClick?.x,
                windowClickY: windowClick?.y,
                nearbyText: nearbyText,
                url: axResult.url ?? self.currentURL,
                windowIdentifier: nil,
                triggerMetadata: nil
            )
            self.clickAggregator.append(e)
        }

        if shouldRunOCR, let ocr = clickOCR {
            ocrQueue.async { [weak self] in
                let text = ocr.recognizeText(at: point, ownerPID: targetPID)
                DispatchQueue.main.async {
                    guard self != nil else { return }
                    emitEvent(text)
                }
            }
        } else {
            emitEvent(nil)
        }
    }

    /// Process a key-down event. Keyboard shortcuts are emitted immediately;
    /// plain text keystrokes are buffered and consolidated by `KeystrokeAggregator`.
    func handleKeyDown(_ nsEvent: NSEvent) {
        guard state == .recording else { return }
        checkAndHandleIdleResume()
        guard !shouldExclude(bundleID: currentBundleID) else { return }

        // Any keystroke is a clean boundary for a click burst.
        clickAggregator.flush()

        if let summary = Self.keyShortcutSummary(for: nsEvent) {
            keystrokeAggregator.flush()
            let e = ActivityEvent(
                appName: currentAppName,
                bundleID: currentBundleID,
                windowTitle: currentWindowTitle,
                eventType: .keyShortcut,
                controlRole: nil,
                controlName: summary,
                controlValue: nil
            )
            emit(e)
        } else if let chars = nsEvent.characters, !chars.isEmpty {
            let isSecure = axInspector.isSecureFieldFocused()
            guard !isSecure else { return }
            let ctx = KeystrokeAggregator.Context(
                appName: currentAppName,
                bundleID: currentBundleID,
                windowTitle: currentWindowTitle
            )
            keystrokeAggregator.append(chars, context: ctx)
        }
    }

    // MARK: - Exclusion check

    func shouldExclude(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if bundleID == ownBundleID { return true }
        return excludedBundleIDs().contains(bundleID)
    }

    // MARK: - Key shortcut summary

    /// Returns a human-readable shortcut string for a key event that has modifier keys,
    /// or `nil` if the event is plain text input (no modifiers or only Shift).
    ///
    /// Examples: `"⌘C"`, `"⌃⌥⌘T"`, `"⌘⇧S"`.
    static func keyShortcutSummary(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        let hasOption = flags.contains(.option)
        let hasFn = flags.contains(.function)

        // Only record if at least one "meaningful" modifier is held.
        // Plain Shift + alphanumeric is just capitalized text — skip it.
        guard hasCommand || hasControl || hasOption || hasFn else { return nil }

        var parts: [String] = []
        if hasControl  { parts.append("⌃") }
        if hasOption   { parts.append("⌥") }
        if hasCommand  { parts.append("⌘") }
        if flags.contains(.shift) { parts.append("⇧") }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        parts.append(key)
        return parts.joined()
    }

    // MARK: - Private: keystroke aggregator wiring

    private func wireKeystrokeAggregator() {
        keystrokeAggregator.onFlush = { [weak self] text, context, inputID in
            guard let self = self else { return }
            let e = ActivityEvent(
                appName: context.appName,
                bundleID: context.bundleID,
                windowTitle: context.windowTitle,
                eventType: .textInput,
                controlRole: nil,
                controlName: inputID.uuidString,
                controlValue: text
            )
            self.emit(e)
        }
    }

    private func wireClickAggregator() {
        clickAggregator.onFlush = { [weak self] event in
            self?.emit(event)
        }
    }

    // MARK: - Private: focus observer wiring

    private func wireFocusObserver() {
        focusObserver.onFocusChange = { [weak self] event in
            self?.handleFocusEvent(event)
        }
    }

    private func handleFocusEvent(_ focusEvent: ActivityFocusObserver.FocusEvent) {
        keystrokeAggregator.flush()
        clickAggregator.flush()

        let eventType: ActivityEventType
        let appName: String
        let bundleID: String
        let windowTitle: String

        switch focusEvent.kind {
        case .appActivated(let a, let b, let w):
            appName = a; bundleID = b; windowTitle = w
            eventType = .appActivated

        case .windowFocused(let a, let b, let w):
            appName = a; bundleID = b; windowTitle = w
            eventType = .windowFocused

        case .windowTitleChanged(let a, let b, let w):
            appName = a; bundleID = b; windowTitle = w
            eventType = .windowTitleChanged
        }

        // Always update context even for excluded apps — we need the correct
        // app name for subsequent events.
        currentAppName = appName
        currentBundleID = bundleID
        currentWindowTitle = windowTitle

        // Don't record focus events for excluded apps.
        guard state == .recording, !shouldExclude(bundleID: bundleID) else { return }

        // Focus changes count as activity — keeps the next periodic tick alive
        // for users who navigate windows without clicking.
        lastActivityDate = Date()

        // Suppress the redundant `windowFocused` that fires right after an
        // `appActivated` for the same bundle (macOS posts both for one switch).
        if eventType == .windowFocused,
           bundleID == lastAppActivatedBundleID,
           let last = lastAppActivatedDate,
           Date().timeIntervalSince(last) < 0.2 {
            return
        }
        if eventType == .appActivated {
            lastAppActivatedDate = Date()
            lastAppActivatedBundleID = bundleID
        }

        // Refresh URL from AX. Only safe when the focus event's bundleID still
        // matches the frontmost app — otherwise we'd be reading another app's
        // page. Falls back to the cached `currentURL` for non-browser apps.
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier == bundleID,
           frontApp.processIdentifier > 0 {
            if let resolvedURL = axInspector.currentURL(forPID: frontApp.processIdentifier) {
                currentURL = resolvedURL
            } else if eventType == .appActivated {
                // Browser → non-browser switch: forget the stale URL.
                currentURL = nil
            }
        }

        emit(event(type: eventType, appName: appName, bundleID: bundleID, windowTitle: windowTitle))

        // Trigger a screenshot on focus-change events.
        let screenshotTrigger: ScreenshotTrigger
        switch focusEvent.kind {
        case .appActivated:     screenshotTrigger = .appSwitch
        case .windowFocused:    screenshotTrigger = .windowFocused
        case .windowTitleChanged: screenshotTrigger = .titleChanged
        }
        maybeCapture(trigger: screenshotTrigger, windowID: nil, appName: appName, bundleID: bundleID, windowTitle: windowTitle)
    }

    // MARK: - Private: idle detection

    private func checkAndHandleIdleResume() {
        let now = Date()
        let threshold = Double(Settings.shared.activityCaptureIdleThresholdSeconds)
        let elapsed = now.timeIntervalSince(lastActivityDate)
        lastActivityDate = now

        guard threshold > 0, elapsed >= threshold else { return }
        guard state == .recording, !shouldExclude(bundleID: currentBundleID) else { return }

        emit(event(
            type: .idleResumed,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
        maybeCapture(
            trigger: .idleResumed,
            windowID: nil,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        )
    }

    // MARK: - Private: periodic timer

    private func startPeriodicTimer() {
        let interval = Settings.shared.activityCaptureFallbackIntervalSeconds
        guard interval > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + .seconds(interval),
            repeating: .seconds(interval),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.handlePeriodicTimer()
            }
        }
        timer.resume()
        periodicTimer = timer
    }

    private func stopPeriodicTimer() {
        periodicTimer?.cancel()
        periodicTimer = nil
    }

    private func handlePeriodicTimer() {
        guard state == .recording, !shouldExclude(bundleID: currentBundleID) else { return }

        // Skip if nothing has happened since the last periodic capture.
        // The first tick always fires (lastPeriodicCaptureDate is nil).
        if let lastPeriodic = lastPeriodicCaptureDate,
           lastActivityDate <= lastPeriodic {
            return
        }
        lastPeriodicCaptureDate = Date()

        // Flush any in-flight click burst so it appears before this snapshot row.
        clickAggregator.flush()

        emit(event(
            type: .periodicCapture,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        ))
        maybeCapture(
            trigger: .periodicCapture,
            windowID: nil,
            appName: currentAppName,
            bundleID: currentBundleID,
            windowTitle: currentWindowTitle
        )
    }

    // MARK: - Private: screenshot capture

    private func maybeCapture(
        trigger: ScreenshotTrigger,
        windowID: String?,
        appName: String,
        bundleID: String,
        windowTitle: String
    ) {
        guard let service = screenshotService,
              let screenshotsURL = screenshotsURL,
              screenshotsEnabled() else { return }

        let quality = Settings.shared.activityCaptureJPEGQuality
        let scale = Settings.shared.activityCaptureScale
        let fallback = Settings.shared.activityCaptureFallbackIntervalSeconds

        let normalizedTitle = ActivityFocusObserver.normalizeTitle(windowTitle)
        guard capturePolicy.shouldCapture(
            trigger: trigger,
            windowIdentifier: windowID,
            windowTitle: normalizedTitle,
            minimumIntervalSeconds: 2.0,
            fallbackIntervalSeconds: fallback
        ) else { return }

        // Record the capture *before* the async task so back-to-back triggers
        // within the minimum-interval window are correctly blocked. If we wait
        // until after captureAndSave returns, a burst of title-change events
        // all read the same stale lastCaptureDate and slip through the gate.
        // Trade-off: a failed capture briefly suppresses the next trigger
        // (until the next legitimate event), which is preferable to letting
        // duplicate captures pile up.
        capturePolicy.recordCapture(
            windowIdentifier: windowID,
            windowTitle: normalizedTitle,
            trigger: trigger
        )

        let triggerString = trigger.rawValue

        Task { [weak self] in
            let path = await service.captureAndSave(
                appName: appName,
                bundleID: bundleID,
                trigger: triggerString,
                screenshotsURL: screenshotsURL,
                quality: quality,
                scale: scale
            )
            if path == nil {
                self?.log("screenshot capture returned nil for trigger=\(triggerString) app=\(appName)")
            }
            guard let self = self, let path = path else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let screenshotEvent = ActivityEvent(
                    appName: appName,
                    bundleID: bundleID,
                    windowTitle: windowTitle,
                    eventType: .screenshotCaptured,
                    screenshotPath: path,
                    triggerMetadata: triggerString
                )
                self.emit(screenshotEvent)
            }
        }
    }

    // MARK: - Private: sleep / wake observers

    private func installSleepWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter

        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleSleep()
        }

        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }
    }

    private func removeSleepWakeObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        if let obs = sleepObserver { ws.removeObserver(obs); sleepObserver = nil }
        if let obs = wakeObserver  { ws.removeObserver(obs); wakeObserver = nil }
    }

    private func handleSleep() {
        guard state == .recording else { return }
        // Stop the periodic timer so it does not fire while the Mac is asleep.
        stopPeriodicTimer()
        log("periodic timer suspended for sleep")
    }

    private func handleWake() {
        guard state == .recording else { return }
        // Reset idle clock and restart the periodic timer after wake.
        lastActivityDate = Date()
        startPeriodicTimer()
        log("periodic timer restarted after wake")
    }

    // MARK: - Private: monitors

    private func installMonitors() {
        guard globalMouseMonitor == nil else { return }

        // Global mouse monitor — receives clicks in other apps.
        // Global monitors fire on a private background thread; dispatch to main so all
        // mutable coordinator state (currentBundleID, lastActivityDate, etc.) is accessed
        // on the same thread as the focus observer and periodic timer callbacks.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] nsEvent in
            DispatchQueue.main.async { [weak self] in
                self?.handleGlobalMouseEvent(nsEvent)
            }
        }
        if globalMouseMonitor == nil {
            log("global mouse monitor returned nil — Accessibility permission may be missing")
        }

        // Global key monitor — receives key events from other apps.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] nsEvent in
            DispatchQueue.main.async { [weak self] in
                self?.handleKeyDown(nsEvent)
            }
        }
        if globalKeyMonitor == nil {
            log("global key monitor returned nil — Accessibility permission may be missing")
        }

        // Local monitor — absorbs BrainCache's own events so they are not re-recorded.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] nsEvent in
            // We do NOT call handleClickAt / handleKeyDown here — own events are excluded.
            _ = self  // suppress warning
            return nsEvent
        }
    }

    private func removeMonitors() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = globalKeyMonitor   { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
        if let m = localMonitor       { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    private func stopMonitors() {
        removeMonitors()
    }

    private func handleGlobalMouseEvent(_ nsEvent: NSEvent) {
        guard state == .recording else { return }

        let eventType: ActivityEventType
        switch nsEvent.type {
        case .leftMouseDown:  eventType = .leftClick
        case .rightMouseDown: eventType = .rightClick
        default:              eventType = .otherClick
        }

        // NSEvent.locationInWindow for global monitors returns AppKit screen coordinates
        // (origin at bottom-left of the primary screen). AXUIElementCopyElementAtPosition
        // expects Quartz/CoreGraphics coordinates (origin at top-left). Flip the Y axis.
        let raw = nsEvent.locationInWindow
        let primaryScreenHeight = NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let location = CGPoint(x: raw.x, y: primaryScreenHeight - raw.y)
        handleClickAt(location, eventType: eventType)
    }

    // MARK: - Private: meeting audio / transcript recording

    private func startMicMonitorIfNeeded() {
        let mode = meetingAudioMode()
        guard let monitor = micMonitor else {
            log("mic monitor not installed — meeting recording disabled")
            return
        }
        guard mode != .off else {
            log("meeting recording mode=off — not starting mic monitor")
            return
        }

        MeetingAudioRecorder.requestMicPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.log("mic permission denied — meeting recording disabled")
                return
            }
            // Treat the *mic being released* as the stop trigger, with a
            // configurable debounce so a brief mute/pause doesn't end the
            // meeting prematurely.
            monitor.silenceDebounceSeconds = TimeInterval(Settings.shared.activityCaptureMicReleaseDelay)
            monitor.onMicBecameActive = { [weak self] in
                self?.handleMicBecameActive()
            }
            monitor.onMicBecameInactive = { [weak self] in
                self?.handleMicBecameInactive()
            }
            monitor.start()
            self.log("mic activity monitor started (mode=\(mode.rawValue), release-delay=\(Int(monitor.silenceDebounceSeconds))s)")
        }
    }

    private func handleMicBecameActive() {
        let mode = meetingAudioMode()
        log("mic active (state=\(state), mode=\(mode.rawValue), app=\(currentAppName))")
        guard state == .recording else { return }
        switch mode {
        case .off:
            return
        case .audio:
            startMeetingAudioRecording()
        case .transcript:
            startMeetingTranscriptRecording()
        }
    }

    private func handleMicBecameInactive() {
        log("mic released (after debounce) — stopping any active meeting recording")
        stopMeetingRecordingIfActive()
    }

    private func startMeetingAudioRecording() {
        guard let recorder = meetingRecorder else {
            log("audio mode: no meetingRecorder configured — skipping")
            return
        }
        guard let recordingsURL = recordingsURL else {
            log("audio mode: no recordingsURL configured (check folder access) — skipping")
            return
        }
        guard !recorder.isRecording else {
            log("audio mode: recorder already running — skipping")
            return
        }

        do {
            let fileURL = try recorder.startRecording(outputDirectory: recordingsURL)
            log("meeting recording started: \(fileURL.lastPathComponent)")
            emit(ActivityEvent(
                appName: currentAppName,
                bundleID: currentBundleID,
                windowTitle: currentWindowTitle,
                eventType: .meetingRecordingStarted,
                triggerMetadata: fileURL.lastPathComponent
            ))
        } catch {
            log("meeting recording failed to start: \(error.localizedDescription)")
        }
    }

    private func startMeetingTranscriptRecording() {
        guard let recorder = transcriptRecorder else {
            log("transcript mode: no transcriptRecorder configured — skipping")
            return
        }
        guard let transcriptsURL = transcriptsURL else {
            log("transcript mode: no transcriptsURL configured (check folder access) — skipping")
            return
        }
        guard !recorder.isRecording else {
            log("transcript mode: recorder already running — skipping")
            return
        }

        do {
            let fileURL = try recorder.startRecording(outputDirectory: transcriptsURL)
            log("meeting transcript started: \(fileURL.lastPathComponent)")
            emit(ActivityEvent(
                appName: currentAppName,
                bundleID: currentBundleID,
                windowTitle: currentWindowTitle,
                eventType: .meetingTranscriptStarted,
                triggerMetadata: fileURL.lastPathComponent
            ))
        } catch {
            log("meeting transcript failed to start: \(error.localizedDescription)")
        }
    }

    private func stopMeetingRecordingIfActive() {
        if let recorder = meetingRecorder, recorder.isRecording {
            if let result = recorder.stopRecording() {
                log("meeting recording stopped: \(result.relativePath) (\(Int(result.duration))s)")
                emit(ActivityEvent(
                    appName: currentAppName,
                    bundleID: currentBundleID,
                    windowTitle: currentWindowTitle,
                    eventType: .meetingRecordingStopped,
                    audioPath: result.relativePath,
                    triggerMetadata: String(format: "%.1fs", result.duration)
                ))
            } else {
                log("meeting recording stopped (discarded — too short)")
            }
        }
        if let recorder = transcriptRecorder, recorder.isRecording {
            if let result = recorder.stopRecording() {
                log("meeting transcript stopped: \(result.relativePath) (\(Int(result.duration))s)")
                emit(ActivityEvent(
                    appName: currentAppName,
                    bundleID: currentBundleID,
                    windowTitle: currentWindowTitle,
                    eventType: .meetingTranscriptStopped,
                    transcriptPath: result.relativePath,
                    triggerMetadata: String(format: "%.1fs", result.duration)
                ))
            } else {
                log("meeting transcript stopped (discarded — too short or empty)")
            }
        }
    }

    // MARK: - Private: event builder helpers

    private func event(
        type: ActivityEventType,
        appName: String,
        bundleID: String,
        windowTitle: String,
        url: String? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            eventType: type,
            url: url ?? currentURL
        )
    }

    private func emit(_ event: ActivityEvent) {
        logWriter.append(event)
    }
}
