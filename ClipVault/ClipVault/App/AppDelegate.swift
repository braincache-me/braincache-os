import AppKit
import Carbon.HIToolbox
import GRDB
import HotKey
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemManager: StatusItemManager?
    /// Menu-bar button — anchor for hint bubbles shown by other controllers.
    var statusBarButton: NSStatusBarButton? { statusItemManager?.statusButton }
    private var clipboardMonitor: ClipboardMonitor?
    private(set) var clipStore: ClipStore?
    private let hotkeyManager = HotkeyManager()
    private var voiceHotKey: HotKey?
    private var voiceRewriteHotKey: HotKey?
    private var aiRewriteHotKey: HotKey?
    // Internal so the status-menu extension can trigger AI rewrite.
    let writingCoordinator = WritingAssistantCoordinator()
    private var purgeScheduler: PurgeScheduler?
    private var aiPipeline: AIIndexingPipeline?
    private let activityFolderAccess = ActivityCaptureFolderAccess()
    // Internal so StatusMenuBuilder extension can access coordinator state for menu refresh.
    var activityCoordinator: ActivityCaptureCoordinator?
    private var activityHistoryStore: ActivityHistoryStore?
    private let activityCleanupService = ActivityCaptureCleanupService()
    private let localBridgeServer = BrainCacheLocalBridgeServer.shared
    // Held strong so Sparkle's background polling timer stays alive; exposed to
    // StatusMenuBuilder so the "Check for Updates…" menu item can target it.
    var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip accessibility and UI setup when running unit tests to avoid modal dialogs
        // blocking the test runner's main thread.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard !isRunningTests else { return }

        setupEditMenu()

        registerLaunchAtLoginIfNeeded()

        // Start Sparkle. The controller polls SUFeedURL on its own timer
        // (configured via SUScheduledCheckInterval in Info.plist) and verifies
        // updates with the EdDSA public key in SUPublicEDKey. We pass self as
        // userDriverDelegate so we can activate the app when Sparkle is about
        // to show an update window — without this, LSUIElement = true keeps
        // BrainCache inactive and the window opens behind other apps.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        updaterController?.updater.checkForUpdatesInBackground()

        let existingDatabaseAtLaunch = {
            guard let url = try? DatabaseManager.databaseURL() else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }()

        var didApplyPendingRestore = false
        do {
            let backupManager = try ClipVaultBackupManager.live()
            do {
                didApplyPendingRestore = try backupManager.applyPendingRestoreIfNeeded()
            } catch {
                try? backupManager.clearPendingRestore()
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Backup Import Failed"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Backup Import Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        let resolvedOnboardingState = Settings.OnboardingState.resolvedForLaunch(
            current: Settings.shared.onboardingState,
            hasExistingData: existingDatabaseAtLaunch || didApplyPendingRestore
        )
        if Settings.shared.onboardingState != resolvedOnboardingState {
            Settings.shared.onboardingState = resolvedOnboardingState
        }
        let shouldShowOnboarding = resolvedOnboardingState == .pending

        // Restore security-scoped folder access for the activity recorder (best-effort at launch).
        // Always attempt this regardless of activityCaptureEnabled so the Activity History window
        // can read existing log files even when capture is currently disabled.
        do {
            try activityFolderAccess.resolveAccess()
        } catch {
            NSLog("ClipVault: ActivityCapture folder access unavailable at launch: \(error)")
        }

        // Wire the Activity History store to the history window controller.
        let historyStore = ActivityHistoryStore(folderAccess: activityFolderAccess)
        activityHistoryStore = historyStore
        ActivityHistoryWindowController.shared.store = historyStore
        ActivityHistoryWindowController.shared.connectStore()

        // Start the activity capture coordinator if the preconditions are met.
        startActivityCaptureIfNeeded()

        // Run retention-based cleanup of old recorder data (best-effort, background).
        activityCleanupService.performCleanupIfNeeded(folderAccess: activityFolderAccess)

        // Setup storage
        do {
            try DatabaseManager.shared.setup()
            clipStore = ClipStore(dbQueue: DatabaseManager.shared.dbQueue)
            localBridgeServer.configure(clipStore: clipStore)
            do {
                try localBridgeServer.startIfProvisioned()
            } catch {
                NSLog("ClipVault: Failed to start local AI skill bridge: \(error)")
            }
        } catch {
            NSLog("ClipVault: Failed to set up database: \(error)")
        }

        // Setup clipboard monitor
        let monitor = ClipboardMonitor()
        monitor.delegate = self
        monitor.start()
        clipboardMonitor = monitor

        // Setup status bar
        statusItemManager = StatusItemManager()
        statusItemManager?.setup()
        // Sync icon with initial recorder state.
        if let coordinator = activityCoordinator {
            statusItemManager?.updateRecorderState(coordinator.state)
        }

        // Pre-create search panel (show/hide only — never re-created)
        let conversationStore = ConversationStore(dbQueue: DatabaseManager.shared.dbQueue)
        SearchPanelController.shared.clipStore = clipStore
        SearchPanelController.shared.pasteService = PasteService()
        SearchPanelController.shared.clipboardMonitor = monitor
        SearchPanelController.shared.conversationStore = conversationStore
        SearchPanelController.shared.setup()

        // Pre-create chat panel
        ChatPanelController.shared.clipStore = clipStore
        ChatPanelController.shared.conversationStore = conversationStore
        ChatPanelController.shared.setup()

        // Pre-create voice recording panel
        VoiceTranscriptionService.shared.clipStore = clipStore
        VoiceTranscriptionService.shared.pasteService = PasteService()
        VoiceTranscriptionService.shared.clipboardMonitor = monitor
        VoiceRecordingPanelController.shared.setup()

        // Wire the Writing Assistant's smart-rewrite service to the monitor so
        // its own paste is not re-captured as a new clipboard entry.
        writingCoordinator.rewriteService.clipboardMonitor = monitor

        // Let the AI Assist window pull clipboard items captured during the
        // active recording so each Ask AI call carries them as extra context.
        AIAssistWindowController.shared.clipStore = clipStore

        // Setup global hotkeys
        hotkeyManager.keyDownHandler = { [weak self] in
            self?.openSearchPanel()
        }
        hotkeyManager.register()
        registerVoiceHotkey()
        registerVoiceRewriteHotkey()
        registerAIRewriteHotkey()
        writingCoordinator.startWritingAssistantHotkeyMonitor()

        // Observe hotkey changes from Preferences
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: .clipVaultHotkeyDidChange,
            object: nil
        )

        // Wire Preferences window with ClipStore
        PreferencesWindowController.shared.clipStore = clipStore

        // Start daily purge scheduler
        if let store = clipStore {
            let scheduler = PurgeScheduler(store: store)
            // Wire embedding store so purge re-quantizes the vector index after bulk deletes.
            scheduler.embeddingStore = EmbeddingStore(dbQueue: DatabaseManager.shared.dbQueue)
            scheduler.start()
            purgeScheduler = scheduler
        }

        // Start AI indexing pipeline (only if API key is configured)
        if clipStore != nil, Settings.shared.isAIEnabled {
            let pipeline = AIIndexingPipeline.shared
            pipeline.start()
            aiPipeline = pipeline
        }

        // Preload quantized vector index into memory for faster search.
        VectorSearchEngine.shared.preloadQuantized()

        // Restart pipeline when API key changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(apiKeyDidChange),
            name: .clipVaultAPIKeyDidChange,
            object: nil
        )

        // Observe activity capture enable/disable changes (e.g. from Preferences toggle).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activityCaptureEnabledDidChange),
            name: .activityCaptureEnabledDidChange,
            object: nil
        )

        // Observe activity capture pause/resume changes (e.g. from Preferences toggle).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activityCapturePausedDidChange),
            name: .activityCapturePausedDidChange,
            object: nil
        )

        // Observe voice recording state / panel visibility for menu bar updates.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceRecordingDidChange),
            name: .voiceRecordingStateDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceRecordingDidChange),
            name: .voiceRecordingPanelVisibilityDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(writingAssistantRewriteDidChange(_:)),
            name: .writingAssistantRewriteStateDidChange,
            object: nil
        )

        // Meeting detection: when another app grabs the microphone, drop a
        // bubble under the menu bar icon offering to record the meeting.
        setupMeetingDetection()

        if shouldShowOnboarding {
            OnboardingWindowController.shared.show { [weak self] in
                self?.finishInitialLaunch(
                    didApplyPendingRestore: didApplyPendingRestore,
                    requestAccessibilityIfNeeded: false
                )
            }
        } else {
            finishInitialLaunch(
                didApplyPendingRestore: didApplyPendingRestore,
                requestAccessibilityIfNeeded: true
            )
        }
    }

    // MARK: - Meeting detection

    /// Connects the detector to the bubble and the bubble's buttons to the
    /// voice recording pipeline. "Record" starts a mic + system-audio
    /// recording; system-audio recordings are save-only on finalize, so the
    /// transcript lands in clips instead of being pasted into the call.
    private func setupMeetingDetection() {
        guard MeetingDetector.isSupported else { return }

        let bubble = MeetingPromptBubbleController.shared
        bubble.anchorProvider = { [weak self] in
            self?.statusItemManager?.statusButton
        }
        bubble.onRecord = {
            VoiceRecordingPanelController.shared.startRecording(forcingSystemAudio: true)
        }
        bubble.onDismiss = {
            MeetingDetector.shared.snooze()
        }
        bubble.onStopRecording = {
            // Bring the panel back so the user sees transcription finish.
            VoiceRecordingPanelController.shared.show()
            VoiceRecordingPanelController.shared.stopRecording()
        }

        MeetingDetector.shared.onMeetingDetected = { detection in
            MeetingPromptBubbleController.shared.show(platformName: detection.platformName)
        }
        MeetingDetector.shared.onMeetingEnded = {
            let bubble = MeetingPromptBubbleController.shared
            bubble.hide()
            let service = VoiceTranscriptionService.shared
            if MeetingPromptPolicy.shouldSuggestStop(
                voiceRecordingActive: service.state == .recording,
                includesSystemAudio: service.isSystemAudioEnabled,
                panelVisible: VoiceRecordingPanelController.shared.isPanelVisible
            ) {
                bubble.showStopSuggestion()
            }
        }
        MeetingDetector.shared.start()
    }

    private func finishInitialLaunch(
        didApplyPendingRestore: Bool,
        requestAccessibilityIfNeeded: Bool
    ) {
        if requestAccessibilityIfNeeded && !AccessibilityChecker.isGranted {
            _ = NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                AccessibilityOnboardingAlert.make().runModal()
                if didApplyPendingRestore {
                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "Backup Imported"
                    alert.informativeText = "BrainCache restored your backup successfully."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
                _ = NSApp.setActivationPolicy(.accessory)
            }
            return
        }

        if didApplyPendingRestore {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Backup Imported"
            alert.informativeText = "BrainCache restored your backup successfully."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Launch at Login

    /// Launch-at-login is on by default: on the first launch (no explicit
    /// user choice recorded yet) the app registers itself as a login item.
    /// This runs only once — afterwards the user's choice (the Preferences
    /// checkbox or removal in System Settings > Login Items) is respected.
    /// Dev builds (`scripts/dev-run.sh`) never self-register.
    private func registerLaunchAtLoginIfNeeded() {
        guard BuildVariant.isProd else { return }
        guard #available(macOS 13.0, *) else { return }
        guard !Settings.shared.isLaunchAtLoginConfigured else { return }
        do {
            try SMAppService.mainApp.register()
            Settings.shared.launchAtLogin = true
        } catch {
            // Record the attempt either way so we don't re-prompt the
            // system on every launch; the user can still enable it from
            // Preferences > General.
            Settings.shared.launchAtLogin = false
            NSLog("ClipVault: launch-at-login default registration failed: %@",
                  error.localizedDescription)
        }
    }

    // MARK: - Edit menu

    /// Install a minimal Edit menu so standard text-editing key equivalents (Cmd+C/V/X/A/Z)
    /// work inside the non-activating floating panels even when the app has no menu bar.
    /// Each item targets `nil` so actions are dispatched through the first-responder chain.
    private func setupEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")),
                         keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func openSearchPanel() {
        // Capture the frontmost app *before* the panel steals focus.
        AppDetector.shared.captureCurrentApp()
        SearchPanelController.shared.toggle()
    }

    @objc func hotkeyDidChange() {
        hotkeyManager.unregister()
        hotkeyManager.register()
        registerVoiceHotkey()
        registerVoiceRewriteHotkey()
        registerAIRewriteHotkey()
    }

    // MARK: - Voice Hotkey

    private func registerVoiceHotkey() {
        voiceHotKey = nil
        let keyCode = Settings.shared.voiceHotkeyKeyCode
        let modifiers = Settings.shared.voiceHotkeyModifiers
        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            NSLog("AppDelegate: unknown voice hotkey carbon key code %d", keyCode)
            return
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 0x100000 != 0 { flags.insert(.command) }
        if modifiers & 0x020000 != 0 { flags.insert(.shift) }
        if modifiers & 0x080000 != 0 { flags.insert(.option) }
        if modifiers & 0x040000 != 0 { flags.insert(.control) }

        let hk = HotKey(key: key, modifiers: flags)
        hk.keyDownHandler = {
            let service = VoiceTranscriptionService.shared
            let panel = VoiceRecordingPanelController.shared
            switch service.state {
            case .recording:
                // When system audio is being captured, Option+Space toggles
                // panel visibility instead of stopping — long meetings are
                // recorded in the background and the user reaches for Stop in
                // the menu bar or in the panel itself.
                if service.isSystemAudioEnabled {
                    if panel.isPanelVisible {
                        panel.hideKeepingRecording()
                    } else {
                        panel.show()
                    }
                } else {
                    panel.stopRecording()
                }
            case .transcribing:
                // Don't interrupt an in-flight transcription.
                break
            case .idle:
                panel.startRecording()
            case .completed, .error:
                // Force a clean reset so a stuck end-state can't lock out the hotkey.
                service.cancel()
                panel.startRecording()
            }
        }
        voiceHotKey = hk
    }

    // MARK: - Voice Rewrite Hotkey (record → AI cleanup → paste)

    private func registerVoiceRewriteHotkey() {
        voiceRewriteHotKey = nil
        let keyCode = Settings.shared.voiceRewriteHotkeyKeyCode
        let modifiers = Settings.shared.voiceRewriteHotkeyModifiers
        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            NSLog("AppDelegate: unknown voice-rewrite hotkey carbon key code %d", keyCode)
            return
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 0x100000 != 0 { flags.insert(.command) }
        if modifiers & 0x020000 != 0 { flags.insert(.shift) }
        if modifiers & 0x080000 != 0 { flags.insert(.option) }
        if modifiers & 0x040000 != 0 { flags.insert(.control) }

        let hk = HotKey(key: key, modifiers: flags)
        hk.keyDownHandler = {
            let service = VoiceTranscriptionService.shared
            let panel = VoiceRecordingPanelController.shared
            // The rewrite flow is dictation-only: cleaning up grammar in a
            // multi-speaker meeting transcript would either lose speaker
            // labels or mangle them. When the user has system audio armed
            // (currently capturing it, or its panel toggle is on), the
            // shortcut becomes a silent no-op.
            if panel.isSystemAudioCapturing { return }
            switch service.state {
            case .recording:
                // Mic-only path only — guarded above. Stop now so the
                // pending rewrite intent kicks off the LLM cleanup pass.
                panel.stopRecording()
            case .transcribing:
                break
            case .idle:
                panel.startRecording(forcingSystemAudio: false, finalizeIntent: .rewriteAndPaste)
            case .completed, .error:
                service.cancel()
                panel.startRecording(forcingSystemAudio: false, finalizeIntent: .rewriteAndPaste)
            }
        }
        voiceRewriteHotKey = hk
    }

    // MARK: - AI Rewrite Hotkey (focused-text rewrite via Writing Assistant)

    private func registerAIRewriteHotkey() {
        aiRewriteHotKey = nil
        let keyCode = Settings.shared.aiRewriteHotkeyKeyCode
        let modifiers = Settings.shared.aiRewriteHotkeyModifiers
        guard let key = Key(carbonKeyCode: UInt32(keyCode)) else {
            NSLog("AppDelegate: unknown AI-rewrite hotkey carbon key code %d", keyCode)
            return
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 0x100000 != 0 { flags.insert(.command) }
        if modifiers & 0x020000 != 0 { flags.insert(.shift) }
        if modifiers & 0x080000 != 0 { flags.insert(.option) }
        if modifiers & 0x040000 != 0 { flags.insert(.control) }

        let hk = HotKey(key: key, modifiers: flags)
        hk.keyDownHandler = { [weak self] in
            _ = self?.writingCoordinator.handleRewriteHotkey()
        }
        aiRewriteHotKey = hk
    }

    @objc func apiKeyDidChange() {
        guard clipStore != nil else { return }
        // Cancel any in-flight requests from the previous key before re-routing.
        OpenAIClient.shared.cancelAllPendingRequests()
        if Settings.shared.isAIEnabled {
            if aiPipeline == nil {
                let pipeline = AIIndexingPipeline.shared
                pipeline.start()
                aiPipeline = pipeline
            } else {
                aiPipeline?.triggerRepairAndBackfillIfNeeded()
            }
        } else {
            aiPipeline?.stop()
        }
        statusItemManager?.refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        voiceHotKey = nil
        voiceRewriteHotKey = nil
        aiRewriteHotKey = nil
        writingCoordinator.stopWritingAssistantHotkeyMonitor()
        clipboardMonitor?.stop()
        clipboardMonitor = nil
        purgeScheduler?.stop()
        purgeScheduler = nil
        aiPipeline?.stop()
        aiPipeline = nil
        localBridgeServer.stop()
        tearDownActivityCapture()
        MeetingDetector.shared.stop()
        statusItemManager = nil
    }

    // MARK: - Activity Capture lifecycle

    /// Start the coordinator if all preconditions are met.
    /// Safe to call multiple times — no-ops if already running.
    func startActivityCaptureIfNeeded() {
        guard activityCoordinator == nil,
              Settings.shared.activityCaptureEnabled,
              AccessibilityChecker.isGranted,
              let logsURL = activityFolderAccess.logsURL
        else { return }

        let writer = ActivityLogWriter()
        writer.start(logsURL: logsURL)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            screenshotService: WindowScreenshotService(),
            screenshotsURL: activityFolderAccess.screenshotsURL,
            clickOCR: ClickOCRService()
        )
        coordinator.micMonitor = MicActivityMonitor()
        coordinator.meetingRecorder = MeetingAudioRecorder()
        coordinator.recordingsURL = activityFolderAccess.recordingsURL
        coordinator.transcriptRecorder = MeetingTranscriptRecorder()
        coordinator.transcriptsURL = activityFolderAccess.transcriptsURL

        if Settings.shared.activityCapturePaused {
            coordinator.start()
            coordinator.pause()
        } else {
            coordinator.start()
        }
        activityCoordinator = coordinator

        // Persist AI Assist responses to the activity log so they show up
        // alongside the voice transcripts that produced them. We capture the
        // writer here (not via `activityCoordinator?.logWriter`) so the
        // closure doesn't restart logging if the coordinator is later torn
        // down — onEntryFinalized is cleared in tearDownActivityCapture.
        AIAssistWindowController.shared.onEntryFinalized = { [weak writer] entry in
            guard let writer else { return }
            let event = ActivityEvent(
                appName: "BrainCache",
                bundleID: Bundle.main.bundleIdentifier ?? "com.TalkFlow.BrainCache",
                windowTitle: "AI Assist",
                eventType: .aiAssistResponse,
                aiPrompt: entry.prompt,
                aiResponse: entry.response,
                aiAttachedWindow: entry.attachedWindowSummary
            )
            writer.append(event)
        }
    }

    /// Tear down the coordinator on termination or forced stop (no Settings/notification side-effects).
    private func tearDownActivityCapture() {
        activityCoordinator?.stop()
        activityCoordinator = nil
        AIAssistWindowController.shared.onEntryFinalized = nil
    }

    // MARK: - Activity Capture notification handlers

    @objc private func activityCaptureEnabledDidChange() {
        if Settings.shared.activityCaptureEnabled {
            if activityCoordinator == nil {
                // Re-resolve folder access in case the bookmark was updated.
                try? activityFolderAccess.resolveAccess()
                startActivityCaptureIfNeeded()
            }
        } else {
            tearDownActivityCapture()
        }
        let newState = activityCoordinator?.state ?? .idle
        statusItemManager?.updateRecorderState(newState)
    }

    @objc private func activityCapturePausedDidChange() {
        if Settings.shared.activityCapturePaused {
            activityCoordinator?.pause()
        } else {
            activityCoordinator?.resume()
        }
        let newState = activityCoordinator?.state ?? .idle
        statusItemManager?.updateRecorderState(newState)
    }

    // MARK: - Activity Capture menu actions

    @objc func startActivityCaptureAction() {
        Settings.shared.activityCaptureEnabled = true
        Settings.shared.activityCapturePaused = false
        do {
            try activityFolderAccess.resolveAccess()
        } catch {
            NSLog("ClipVault: ActivityCapture folder access unavailable: \(error)")
            // Revert the setting — we can't actually start without a valid log folder.
            Settings.shared.activityCaptureEnabled = false
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Activity Capture Folder Not Found"
            alert.informativeText = "Please choose a log folder in Preferences \u{2192} General before starting Activity Capture."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        startActivityCaptureIfNeeded()
        let newState = activityCoordinator?.state ?? .idle
        statusItemManager?.updateRecorderState(newState)
        NotificationCenter.default.post(name: .activityCaptureEnabledDidChange, object: nil)
    }

    @objc func pauseActivityCaptureAction() {
        guard activityCoordinator?.state == .recording else { return }
        Settings.shared.activityCapturePaused = true
        activityCoordinator?.pause()
        statusItemManager?.updateRecorderState(.paused)
        NotificationCenter.default.post(name: .activityCapturePausedDidChange, object: nil)
    }

    @objc func resumeActivityCaptureAction() {
        guard activityCoordinator?.state == .paused else { return }
        Settings.shared.activityCapturePaused = false
        activityCoordinator?.resume()
        statusItemManager?.updateRecorderState(.recording)
        NotificationCenter.default.post(name: .activityCapturePausedDidChange, object: nil)
    }

    @objc func stopActivityCaptureAction() {
        guard let coordinator = activityCoordinator, coordinator.state != .idle else { return }
        Settings.shared.activityCaptureEnabled = false
        Settings.shared.activityCapturePaused = false
        tearDownActivityCapture()
        statusItemManager?.updateRecorderState(.idle)
        NotificationCenter.default.post(name: .activityCaptureEnabledDidChange, object: nil)
    }

    // MARK: - Voice recording menu actions

    @objc func voiceRecordingDidChange() {
        let panel = VoiceRecordingPanelController.shared
        let active: Bool
        switch VoiceTranscriptionService.shared.state {
        case .recording, .transcribing:
            active = true
        case .idle, .completed, .error:
            active = false
        }
        statusItemManager?.updateVoiceRecordingState(
            active: active,
            panelVisible: panel.isPanelVisible
        )
    }

    @objc private func writingAssistantRewriteDidChange(_ notification: Notification) {
        let active = notification.userInfo?["isRewriting"] as? Bool ?? false
        statusItemManager?.updateWritingRewriteState(active: active)
    }

    @objc func stopVoiceRecordingAction() {
        VoiceRecordingPanelController.shared.stopRecording()
    }

    @objc func showVoiceRecordingPanelAction() {
        VoiceRecordingPanelController.shared.show()
    }

    @objc func startVoiceRecordingAction() {
        VoiceRecordingPanelController.shared.startRecording(forcingSystemAudio: false)
    }

    @objc func startVoiceRecordingWithSystemAudioAction() {
        VoiceRecordingPanelController.shared.startRecording(forcingSystemAudio: true)
    }
}

// LSUIElement = true keeps BrainCache inactive by default, so Sparkle's update
// windows would open behind the frontmost app. Activating before the check (for
// user-initiated runs) and on the will-show hook (for scheduled background
// checks that surface an update) brings them forward.
extension AppDelegate: SPUStandardUserDriverDelegate {
    @objc func checkForUpdatesAction(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        updaterController?.checkForUpdates(sender)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: ClipboardMonitorDelegate {
    private static let insertQueue = DispatchQueue(label: "com.clipvault.insert", qos: .utility)

    func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
        guard let store = clipStore else { return }
        let pipeline = aiPipeline
        Self.insertQueue.async {
            do {
                let clipId = try store.insert(entry: entry)
                pipeline?.enqueue(clipId: clipId)
            } catch {
                NSLog("ClipVault: Failed to insert clip: \(error)")
            }
        }
    }
}
