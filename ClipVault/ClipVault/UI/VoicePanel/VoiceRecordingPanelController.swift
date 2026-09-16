import AppKit

final class VoiceRecordingPanelController {

    static let shared = VoiceRecordingPanelController()

    private(set) var window: VoiceRecordingPanelWindow?
    private var waveformView: WaveformView?
    private var micPopup: NSPopUpButton?
    private var systemAudioSwitch: NSSwitch?
    private var systemAudioLabel: NSTextField?
    private var systemAudioWarning: NSImageView?
    private var systemAudioHoverTarget: HoverTrackingView?
    private var systemAudioTooltip: TooltipBubble?
    private var systemAudioTooltipShowWorkItem: DispatchWorkItem?
    private var translatePopup: NSPopUpButton?
    private var translateIcon: NSImageView?
    private var transcriptPopOutButton: NSButton?
    private var transcriptPopover: NSPopover?
    private var transcriptPopoverTextView: NSTextView?
    private var stopButton: NSButton?
    private var rewriteButton: NSButton?
    private var hideButton: NSButton?
    private var attachWindowButton: NSButton?
    private var askAIButton: NSButton?
    private var askAIChevronButton: NSButton?
    private var customPromptPopover: NSPopover?
    private var customPromptTextView: NSTextView?
    private var aiAssistHandoffGeneration = 0
    private var pendingAIWindow: CapturableWindow?
    private var windowPickerPopover: WindowPickerPopover?
    /// "Save recording" checkbox (top-left). While checked the session is
    /// written to disk — audio only, or the attached window as video.
    private var recordMediaCheckbox: NSButton?
    /// Folder glyph next to the checkbox: reveals the live file, or the
    /// recordings folder when nothing is being written.
    private var revealRecordingButton: NSButton?
    /// The checkbox was ticked while no session was running — start the
    /// media recording as soon as the next session begins.
    private var mediaRecordingArmed = false
    private var statusLabel: NSTextField?
    private var statusBanner: NSView?
    private var statusBannerIcon: NSImageView?
    private var durationLabel: NSTextField?
    private var durationTimer: Timer?
    private var statusResetWorkItem: DispatchWorkItem?
    private var transcriptScroll: NSScrollView?
    private var transcriptTextView: NSTextView?

    // MARK: - AI Assist drawer
    //
    // The AI Assist response + history view used to live in a standalone
    // floating window. It is now embedded as a collapsible drawer hanging
    // off the bottom of this panel — the drawer starts collapsed and
    // auto-expands the first time Ask AI is pressed, after which a chevron
    // in the drawer header lets the user toggle it.
    private var aiDrawerContainer: NSView?
    private var aiDrawerHeader: NSView?
    private var aiDrawerChevron: NSImageView?
    private var aiDrawerHeaderLabel: NSTextField?
    private var aiDrawerEmbedHost: NSView?
    private var aiDrawerResizeGrip: NSView?
    private var aiDrawerHeightConstraint: NSLayoutConstraint?
    private var aiDrawerResizeGripHeightConstraint: NSLayoutConstraint?
    private var aiDrawerExpanded = false
    /// Becomes true the first time `expandAIDrawer()` is called (i.e. after
    /// the user's first Ask AI). Until then the drawer is fully hidden so
    /// the panel keeps its compact 222pt height. Once true, the drawer
    /// header stays visible — giving the user a persistent toggle — even
    /// when the body is collapsed.
    private var aiDrawerHasContent = false
    /// Current expanded-body height in points. Mutable so the resize grip
    /// at the top of the drawer can shrink / grow the AI Assist area.
    private var aiDrawerBodyHeight: CGFloat = 360
    private var aiDrawerResizeStartBodyHeight: CGFloat = 360

    /// Current transcript-scroll height in points. The resize grip splits
    /// the drag 50/50 between this and `aiDrawerBodyHeight` so the whole
    /// panel grows (transcript area + AI drawer body) when the user drags.
    private var transcriptScrollHeight: CGFloat = 96
    private var transcriptScrollHeightConstraint: NSLayoutConstraint?
    private var aiDrawerResizeStartScrollHeight: CGFloat = 96

    private static let aiDrawerHeaderHeight: CGFloat = 26
    private static let aiDrawerGripHeight: CGFloat = 6
    /// Breathing room between the bottom of the drawer and the bottom edge
    /// of the panel chrome. Without this the "Show AI Response" header sits
    /// flush against the window's bottom edge, which is exactly where macOS
    /// reserves a ~4–6pt strip for the bottom-edge resize handle — so
    /// clicks meant for the header get swallowed by the resize gesture.
    private static let aiDrawerBottomPadding: CGFloat = 8
    /// Minimum useful AI body height. Set high enough that an answer is
    /// actually readable when the user resizes the panel down to its
    /// floor — at 140pt the body would clip the answer header + a couple
    /// of lines, which reads as "the AI response disappeared".
    private static let aiDrawerMinBodyHeight: CGFloat = 220
    private static let aiDrawerMaxBodyHeight: CGFloat = 1400
    private static let transcriptMinHeight: CGFloat = 96
    private static let transcriptMaxHeight: CGFloat = 1200
    private static let transcriptBaseHeight: CGFloat = 96
    private static let screenshotOnlyPrompt = "No transcript was provided. Use the attached screenshot as the primary context and help the user with what is visible."

    /// `true` while a programmatic `setFrame` is in flight so the
    /// `windowDidResize` observer doesn't redistribute heights we just set
    /// ourselves.
    private var isApplyingProgrammaticResize = false

    // Streaming-delta UI debouncing. Realtime transcription emits multiple
    // deltas per second; rebuilding the attributed transcript and re-laying
    // it out on every delta is O(n²) over the recording's lifetime, so we
    // coalesce updates to a fixed cadence.
    private var pendingLiveTranscript: VoiceTranscriptionService.LiveTranscript?
    private var renderDebounceWorkItem: DispatchWorkItem?
    // A ~7 fps text cadence still feels live and avoids AppKit layout churn
    // during long dictation or two-source meeting transcription.
    private let renderDebounceInterval: TimeInterval = 0.15
    // UTF-16 length of the text most recently pushed into `transcriptTextView`.
    // Used by `applyTranscript` to fast-path append-only updates.
    private var lastRenderedLength: Int = 0

    private let service = VoiceTranscriptionService.shared

    /// Intent passed to `service.stopAndTranscribe(intent:)` for the current
    /// session. Set in `startRecording(forcingSystemAudio:finalizeIntent:)` and
    /// reset to `.paste` after each stop. Lets the Option+Shift+Space hotkey
    /// route the dictation through an LLM cleanup pass before paste, while
    /// leaving the default Option+Space flow untouched.
    private var pendingFinalizeIntent: VoiceTranscriptionService.FinalizeIntent = .paste

    /// Per-source realtime state. The panel surfaces "Reconnecting…" whenever
    /// any source is in `.reconnecting`, so the user knows a transient drop
    /// is being recovered rather than the recording being silently broken.
    private var clientStates: [RealtimeTranscriptionClient.Source: RealtimeTranscriptionClient.State] = [:]

    // MARK: - Setup

    func setup() {
        let panel = VoiceRecordingPanelWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: VoiceRecordingPanelWindow.panelWidth,
                                height: VoiceRecordingPanelWindow.panelHeight),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.positionAtBottomCenter(height: currentPanelHeight)
        buildContentView(in: panel)
        window = panel

        // State changes drive the panel lifecycle (e.g. .completed triggers hide())
        // so this callback stays wired for the lifetime of the controller.
        service.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.handleStateChange(state) }
        }
        // Per-source realtime state — drives the inline "Reconnecting…"
        // banner so the user can tell a 5 s socket flap apart from a
        // transcription that has silently stopped working.
        service.onClientStateChange = { [weak self] source, state in
            self?.handleClientStateChange(source: source, state: state)
        }
        // Media file lifecycle — keeps the checkbox honest and surfaces the
        // "your window went away" hint in the menu bar.
        service.onMediaRecordingStopped = { [weak self] event in
            self?.handleMediaRecordingStopped(event)
        }

        // AI Assist runs in its own standalone window. The drawer wiring on
        // the panel intentionally stays unused — `AIAssistWindowController`
        // falls back to creating an `AIAssistWindow` when `embedHost` is nil.
        applyDrawerLayout(animated: false)

        // Track manual user resizes (drag from any edge / corner) so we can
        // distribute the new height between transcript scroll and AI drawer
        // body. We don't snap the bottom edge back to the screen anchor
        // here — see the comment on `panelWindowDidResize`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelWindowDidResize(_:)),
            name: NSWindow.didResizeNotification,
            object: panel
        )
    }

    private var liveUICallbacksAttached = false

    /// Wires the high-frequency UI callbacks (per-buffer audio levels, per-token
    /// transcript deltas) so the panel renders live updates. Call when the panel
    /// becomes visible.
    private func attachLiveUICallbacks() {
        guard !liveUICallbacksAttached else { return }
        liveUICallbacksAttached = true
        service.audioLevelCallback = { [weak self] level in
            self?.waveformView?.appendLevel(level)
        }
        service.systemAudioLevelCallback = { [weak self] level in
            self?.waveformView?.appendSystemLevel(level)
        }
        service.onTranscriptUpdate = { [weak self] live in
            DispatchQueue.main.async {
                self?.scheduleRenderTranscript(live)
            }
        }
        // Sync the just-attached view to whatever the service has accumulated
        // while we were detached. Render immediately rather than debounced
        // so the user sees the existing transcript without delay.
        renderTranscript(service.transcript)
        lastRenderedLength = transcriptTextView?.textStorage?.length ?? 0
    }

    /// Detaches the high-frequency UI callbacks while the panel is hidden so
    /// per-buffer level updates and per-token transcript deltas don't trigger
    /// AppKit layout work for an off-screen view. The service keeps building
    /// `transcript` internally; we re-render it on the next attach.
    private func detachLiveUICallbacks() {
        guard liveUICallbacksAttached else { return }
        liveUICallbacksAttached = false
        service.audioLevelCallback = nil
        service.systemAudioLevelCallback = nil
        service.onTranscriptUpdate = nil
        renderDebounceWorkItem?.cancel()
        renderDebounceWorkItem = nil
        pendingLiveTranscript = nil
    }

    private func scheduleRenderTranscript(_ live: VoiceTranscriptionService.LiveTranscript) {
        pendingLiveTranscript = live
        guard renderDebounceWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderDebounceWorkItem = nil
            guard let pending = self.pendingLiveTranscript else { return }
            self.pendingLiveTranscript = nil
            self.renderTranscript(pending)
            if let popover = self.transcriptPopover, popover.isShown {
                self.refreshTranscriptPopover()
            }
        }
        renderDebounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + renderDebounceInterval, execute: work)
    }

    /// Force the pending debounced render to run synchronously. Called when
    /// recording state transitions (e.g. .transcribing, .completed) so the
    /// user sees the final transcript without waiting for the debounce.
    private func flushPendingRender() {
        renderDebounceWorkItem?.cancel()
        renderDebounceWorkItem = nil
        if let pending = pendingLiveTranscript {
            pendingLiveTranscript = nil
            renderTranscript(pending)
            if let popover = transcriptPopover, popover.isShown {
                refreshTranscriptPopover()
            }
        }
    }

    // MARK: - Show / Hide

    var isPanelVisible: Bool {
        window?.isVisible ?? false
    }

    func show() {
        guard let panel = window else { return }
        refreshMicDevices()
        refreshSystemAudioTooltip()
        syncTranslatePopupSelection()
        attachLiveUICallbacks()
        panel.showWithAnimation(height: currentPanelHeight)
        NotificationCenter.default.post(name: .voiceRecordingPanelVisibilityDidChange, object: nil)
    }

    /// Keeps the system-audio controls in sync with the Screen Recording
    /// permission state. When permission is missing we surface the requirement
    /// inline (warning icon + tooltip) instead of via a popup banner.
    private func refreshSystemAudioTooltip() {
        let granted = AccessibilityChecker.isScreenRecordingGranted
        let tip = granted
            ? "Capture system audio"
            : "Enable Screen Recording for BrainCache in System Settings to capture system audio"
        systemAudioSwitch?.toolTip = tip
        systemAudioLabel?.toolTip = tip
        systemAudioWarning?.toolTip = tip
        systemAudioWarning?.isHidden = granted
    }

    func hide() {
        detachLiveUICallbacks()
        transcriptPopover?.performClose(nil)
        customPromptPopover?.performClose(nil)
        windowPickerPopover?.close()
        durationTimer?.invalidate()
        durationTimer = nil
        waveformView?.setMode(.idle)
        waveformView?.reset()
        durationLabel?.stringValue = "0:00"
        statusResetWorkItem?.cancel()
        statusResetWorkItem = nil
        hideSystemAudioTooltip()
        setBanner("")
        clearTranscript()
        // Stale attach selection shouldn't carry across sessions.
        if pendingAIWindow != nil {
            pendingAIWindow = nil
            refreshAttachWindowButton()
        }
        mediaRecordingArmed = false
        refreshMediaRecordingUI()
        window?.hideWithAnimation {}
        NotificationCenter.default.post(name: .voiceRecordingPanelVisibilityDidChange, object: nil)
    }

    /// Hide the panel without resetting recording UI state — used while a
    /// recording is in progress so the waveform/transcript resume cleanly when
    /// the panel is shown again.
    func hideKeepingRecording() {
        detachLiveUICallbacks()
        transcriptPopover?.performClose(nil)
        customPromptPopover?.performClose(nil)
        window?.hideWithAnimation {}
        NotificationCenter.default.post(name: .voiceRecordingPanelVisibilityDidChange, object: nil)
    }

    // MARK: - Recording Control

    /// Start a recording.
    /// - Parameters:
    ///   - forcingSystemAudio: when non-nil, overrides the panel's Sys toggle
    ///     (used by the menu bar's "Start with System Audio" entry point).
    ///     Otherwise the toggle's current state is used.
    ///   - finalizeIntent: how the transcript should be handled when the
    ///     recording stops. Defaults to `.paste` so existing entry points
    ///     keep their behaviour; `.rewriteAndPaste` is used by the
    ///     Option+Shift+Space hotkey to LLM-clean the dictation before paste.
    func startRecording(
        forcingSystemAudio: Bool? = nil,
        finalizeIntent: VoiceTranscriptionService.FinalizeIntent = .paste
    ) {
        AppDetector.shared.captureCurrentApp()
        let includeSystem = forcingSystemAudio ?? (systemAudioSwitch?.state == .on)
        if let forced = forcingSystemAudio {
            systemAudioSwitch?.state = forced ? .on : .off
        }
        pendingFinalizeIntent = finalizeIntent
        updateHotkeyAffordances()
        clearTranscript()
        service.startRecording(includeSystemAudio: includeSystem)
        if mediaRecordingArmed {
            mediaRecordingArmed = false
            if case .recording = service.state {
                startMediaRecordingFromUI()
            }
        }
        refreshMediaRecordingUI()
        show()
    }

    func stopRecording() {
        let intent = pendingFinalizeIntent
        pendingFinalizeIntent = .paste
        service.stopAndTranscribe(intent: intent)
    }

    // MARK: - Content View

    private func buildContentView(in panel: NSPanel) {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        // Live transcript
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: VoiceRecordingPanelWindow.panelWidth - 24,
            height: 96
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 11)
        textView.textColor = .white.withAlphaComponent(0.92)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 96)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: VoiceRecordingPanelWindow.panelWidth - 24,
            height: .greatestFiniteMagnitude
        )

        scroll.documentView = textView
        effectView.addSubview(scroll)
        transcriptScroll = scroll
        transcriptTextView = textView

        // Waveform
        let waveform = WaveformView()
        waveform.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(waveform)
        waveformView = waveform

        // Bottom bar
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.wantsLayer = true
        bottomBar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        bottomBar.layer?.cornerRadius = 10
        effectView.addSubview(bottomBar)

        // Mic icon
        let micIcon = NSImageView()
        micIcon.translatesAutoresizingMaskIntoConstraints = false
        micIcon.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone")
        micIcon.contentTintColor = .white
        micIcon.imageScaling = .scaleProportionallyDown
        bottomBar.addSubview(micIcon)

        // Mic device popup
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.font = .systemFont(ofSize: 10)
        popup.isBordered = false
        popup.appearance = NSAppearance(named: .darkAqua)
        popup.target = self
        popup.action = #selector(micDeviceChanged)
        bottomBar.addSubview(popup)
        micPopup = popup

        // System audio switch
        let sysLabel = NSTextField(labelWithString: "System audio")
        sysLabel.translatesAutoresizingMaskIntoConstraints = false
        sysLabel.font = .systemFont(ofSize: 9, weight: .medium)
        sysLabel.textColor = .white.withAlphaComponent(0.7)
        bottomBar.addSubview(sysLabel)
        systemAudioLabel = sysLabel

        let sysWarning = NSImageView()
        sysWarning.translatesAutoresizingMaskIntoConstraints = false
        sysWarning.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Screen Recording permission required"
        )
        sysWarning.contentTintColor = NSColor.systemYellow
        sysWarning.imageScaling = .scaleProportionallyDown
        sysWarning.isHidden = true
        bottomBar.addSubview(sysWarning)
        systemAudioWarning = sysWarning

        let sysSwitch = NSSwitch(frame: .zero)
        sysSwitch.translatesAutoresizingMaskIntoConstraints = false
        sysSwitch.target = self
        sysSwitch.action = #selector(systemAudioToggled(_:))
        sysSwitch.state = .off
        sysSwitch.toolTip = "Capture system audio"
        bottomBar.addSubview(sysSwitch)
        systemAudioSwitch = sysSwitch

        // Translate language popup — sits between the system-audio cluster
        // and the duration label. "Off" leaves the recording in transcription
        // mode; picking a language enables realtime translation to that
        // language. Persisted in Settings.translationEnabled/TargetLanguage.
        let translateIconView = NSImageView()
        translateIconView.translatesAutoresizingMaskIntoConstraints = false
        translateIconView.image = NSImage(
            systemSymbolName: "globe",
            accessibilityDescription: "Translate"
        )
        translateIconView.contentTintColor = .white.withAlphaComponent(0.75)
        translateIconView.imageScaling = .scaleProportionallyDown
        translateIconView.toolTip = "Translate the spoken audio into the selected language"
        bottomBar.addSubview(translateIconView)
        translateIcon = translateIconView

        let translatePop = NSPopUpButton()
        translatePop.translatesAutoresizingMaskIntoConstraints = false
        translatePop.font = .systemFont(ofSize: 10)
        translatePop.isBordered = false
        translatePop.appearance = NSAppearance(named: .darkAqua)
        translatePop.target = self
        translatePop.action = #selector(translateLanguageChanged(_:))
        translatePop.toolTip = "Translate the spoken audio into the selected language"
        rebuildTranslateMenu(into: translatePop)
        bottomBar.addSubview(translatePop)
        translatePopup = translatePop

        // Transparent hover overlay covering the entire system-audio cluster.
        // System tooltips on a `.nonactivatingPanel` are unreliable, so we
        // drive our own bubble on enter/exit.
        let hoverTarget = HoverTrackingView()
        hoverTarget.translatesAutoresizingMaskIntoConstraints = false
        hoverTarget.onEnter = { [weak self] in self?.scheduleSystemAudioTooltip() }
        hoverTarget.onExit = { [weak self] in self?.hideSystemAudioTooltip() }
        bottomBar.addSubview(hoverTarget, positioned: .above, relativeTo: sysSwitch)
        systemAudioHoverTarget = hoverTarget

        // Duration label — top-right corner, above the transcript. Doesn't
        // share the bottom bar with the audio/translate controls so it can't
        // get pushed off-screen when those grow.
        let durLabel = NSTextField(labelWithString: "0:00")
        durLabel.translatesAutoresizingMaskIntoConstraints = false
        durLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        durLabel.textColor = .white.withAlphaComponent(0.85)
        durLabel.alignment = .right
        effectView.addSubview(durLabel)
        durationLabel = durLabel

        // Pop-out transcript button — sits to the left of the timer. Opens
        // an NSPopover with the live transcript at a comfortable size,
        // so the user can read or copy long transcripts without resizing
        // the recording panel.
        let popOut = NSButton()
        popOut.translatesAutoresizingMaskIntoConstraints = false
        popOut.bezelStyle = .inline
        popOut.isBordered = false
        popOut.imagePosition = .imageOnly
        popOut.image = NSImage(
            systemSymbolName: "rectangle.expand.vertical",
            accessibilityDescription: "Show transcript"
        ) ?? NSImage(
            systemSymbolName: "text.viewfinder",
            accessibilityDescription: "Show transcript"
        )
        popOut.contentTintColor = .white.withAlphaComponent(0.7)
        popOut.toolTip = "Show full transcript"
        popOut.target = self
        popOut.action = #selector(toggleTranscriptPopover(_:))
        effectView.addSubview(popOut)
        transcriptPopOutButton = popOut

        // "Save recording" — top-left. Ticking it starts writing the session
        // to disk from that moment (audio, or the attached window as video);
        // unticking finalises the file. See `recordMediaToggled`.
        let saveCheckbox = NSButton(
            checkboxWithTitle: "Save recording",
            target: self,
            action: #selector(recordMediaToggled(_:))
        )
        saveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        saveCheckbox.controlSize = .small
        saveCheckbox.appearance = NSAppearance(named: .darkAqua)
        saveCheckbox.attributedTitle = NSAttributedString(
            string: "Save recording",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            ]
        )
        saveCheckbox.setContentCompressionResistancePriority(.required, for: .horizontal)
        effectView.addSubview(saveCheckbox)
        recordMediaCheckbox = saveCheckbox

        let reveal = NSButton()
        reveal.translatesAutoresizingMaskIntoConstraints = false
        reveal.bezelStyle = .inline
        reveal.isBordered = false
        reveal.imagePosition = .imageOnly
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Show recordings")
        reveal.contentTintColor = .white.withAlphaComponent(0.7)
        reveal.target = self
        reveal.action = #selector(revealRecordingTapped)
        effectView.addSubview(reveal)
        revealRecordingButton = reveal

        // 📎 Attach window — top-right zone, sibling of the Ask AI pill.
        // Lives outside the bottom bar so the recording controls (mic/system
        // audio/translate/Stop) stay uncluttered.
        let attach = NSButton()
        attach.translatesAutoresizingMaskIntoConstraints = false
        attach.bezelStyle = .inline
        attach.isBordered = false
        attach.imagePosition = .imageOnly
        attach.image = NSImage(
            systemSymbolName: "paperclip",
            accessibilityDescription: "Attach a window screenshot"
        )
        attach.contentTintColor = .white.withAlphaComponent(0.8)
        attach.toolTip = "Attach a window screenshot to the AI request"
        attach.target = self
        attach.action = #selector(attachWindowTapped(_:))
        effectView.addSubview(attach)
        attachWindowButton = attach

        // ✨ Ask AI — primary AI Assist action. Compact pill in the top zone
        // so it reads as a primary CTA without competing with the red Stop.
        let askAI = makeCompactAIButton()
        askAI.target = self
        askAI.action = #selector(askAITapped)
        effectView.addSubview(askAI)
        askAIButton = askAI

        // Tiny chevron-down "split" pill glued to the right of Ask AI. Opens
        // the Custom Prompt popover directly so the user can fire a one-shot
        // prompt that bypasses the prefix configured in Preferences without
        // disturbing that persisted setting.
        let askAIChevron = makeCompactAIChevronButton()
        askAIChevron.target = self
        askAIChevron.action = #selector(askAIChevronTapped(_:))
        effectView.addSubview(askAIChevron)
        askAIChevronButton = askAIChevron

        // Stop button — primary action, drawn as a filled red pill so it
        // visually anchors the bottom bar. The ⌥Space hint reads against the
        // rightmost visible action: in mic-only mode that's Stop (the hotkey
        // stops the recording), in mic+sys mode it's Hide (the hotkey just
        // hides the panel while recording continues in the background).
        let stop = makePrimaryStopButton()
        stop.target = self
        stop.action = #selector(stopTapped)
        stopButton = stop

        // Stop & Rewrite — finishes the recording then routes the transcript
        // through an LLM cleanup pass before paste. Mirrors the ⌥⇧Space hotkey
        // for users who'd rather click. Hidden outside .recording and disabled
        // while system audio is on (multi-speaker meeting transcripts aren't
        // the use case for verbatim grammar cleanup).
        let rewrite = makeRewriteButton()
        rewrite.target = self
        rewrite.action = #selector(rewriteTapped)
        rewrite.isHidden = true
        rewriteButton = rewrite

        let hide = makeSecondaryHideButton()
        hide.target = self
        hide.action = #selector(hideTapped)
        hideButton = hide

        let stopStack = NSStackView(views: [rewrite, stop, hide])
        stopStack.translatesAutoresizingMaskIntoConstraints = false
        stopStack.orientation = .horizontal
        stopStack.spacing = 6
        stopStack.alignment = .centerY
        bottomBar.addSubview(stopStack)

        // Status banner — pill-shaped container so warning/error messages
        // read clearly instead of disappearing as low-contrast footer text.
        let banner = NSView()
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 6
        banner.layer?.backgroundColor = NSColor.clear.cgColor
        banner.isHidden = true
        effectView.addSubview(banner)
        statusBanner = banner

        let bannerIcon = NSImageView()
        bannerIcon.translatesAutoresizingMaskIntoConstraints = false
        bannerIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        bannerIcon.contentTintColor = NSColor.systemYellow
        bannerIcon.imageScaling = .scaleProportionallyDown
        banner.addSubview(bannerIcon)
        statusBannerIcon = bannerIcon

        let status = NSTextField(labelWithString: "")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.textColor = .white
        status.alignment = .left
        status.lineBreakMode = .byTruncatingTail
        status.maximumNumberOfLines = 2
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        banner.addSubview(status)
        statusLabel = status

        // AI Assist drawer ----------------------------------------------------
        //
        // The drawer hangs off the bottom of the capture controls and stays
        // transparent so the parent HUD effect view shows through. Stack
        // (top → bottom inside the drawer):
        //   • resizeGrip — drag handle for resizing the body
        //   • divider    — 1pt separator from the capture region
        //   • header     — chevron + label; whole strip is click-to-toggle
        //   • body       — embed host for AIAssistWindowController's view
        let drawer = NSView()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.wantsLayer = true
        drawer.layer?.backgroundColor = NSColor.clear.cgColor
        drawer.isHidden = true
        effectView.addSubview(drawer)
        aiDrawerContainer = drawer

        let resizeGrip = DrawerResizeGripView()
        resizeGrip.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(resizeGrip)
        aiDrawerResizeGrip = resizeGrip

        let pan = NSPanGestureRecognizer(target: self, action: #selector(aiDrawerResizePan(_:)))
        resizeGrip.addGestureRecognizer(pan)

        let drawerDivider = NSBox()
        drawerDivider.boxType = .separator
        drawerDivider.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(drawerDivider)

        // Use a real NSButton — earlier attempts with a custom click view
        // kept losing clicks on a `.nonactivatingPanel` with
        // `isMovableByWindowBackground = true`. NSButton handles every one
        // of those gotchas correctly (accepts first mouse, doesn't trigger
        // window-drag, dispatches its action on click). The chevron / label
        // ride on top as decorative subviews; `DrawerToggleButton.hitTest`
        // forces the button itself to win so clicks land on the action,
        // not on the inner NSImageView / NSTextField.
        let drawerHeader = DrawerToggleButton()
        drawerHeader.translatesAutoresizingMaskIntoConstraints = false
        drawerHeader.isBordered = false
        drawerHeader.bezelStyle = .inline
        drawerHeader.title = ""
        drawerHeader.imagePosition = .noImage
        drawerHeader.target = self
        drawerHeader.action = #selector(aiDrawerToggleTapped)
        drawerHeader.focusRingType = .none
        drawer.addSubview(drawerHeader)
        aiDrawerHeader = drawerHeader

        // Chevron + label are plain NSImageView / NSTextField subviews —
        // `DrawerToggleButton.hitTest` returns the parent button so these
        // never intercept the click.
        let drawerChevron = NSImageView()
        drawerChevron.translatesAutoresizingMaskIntoConstraints = false
        drawerChevron.imageScaling = .scaleProportionallyDown
        drawerChevron.contentTintColor = .white.withAlphaComponent(0.85)
        drawerHeader.addSubview(drawerChevron)
        aiDrawerChevron = drawerChevron

        let drawerLabel = NSTextField(labelWithString: "")
        drawerLabel.translatesAutoresizingMaskIntoConstraints = false
        drawerLabel.font = .systemFont(ofSize: 10, weight: .medium)
        drawerLabel.textColor = .white.withAlphaComponent(0.85)
        drawerHeader.addSubview(drawerLabel)
        aiDrawerHeaderLabel = drawerLabel

        let drawerBody = NSView()
        drawerBody.translatesAutoresizingMaskIntoConstraints = false
        drawer.addSubview(drawerBody)
        aiDrawerEmbedHost = drawerBody

        let drawerHeight = drawer.heightAnchor.constraint(equalToConstant: 0)
        aiDrawerHeightConstraint = drawerHeight

        // Grip / divider / header heights declare intrinsic sizes at
        // less-than-required priority so AutoLayout can compress them to
        // zero when the drawer is fully collapsed (height = 0) without
        // logging conflicts.
        let resizeGripHeight = resizeGrip.heightAnchor
            .constraint(equalToConstant: Self.aiDrawerGripHeight)
        resizeGripHeight.priority = .init(999)
        aiDrawerResizeGripHeightConstraint = resizeGripHeight
        let drawerHeaderHeight = drawerHeader.heightAnchor
            .constraint(equalToConstant: Self.aiDrawerHeaderHeight)
        drawerHeaderHeight.priority = .init(999)
        let drawerDividerHeight = drawerDivider.heightAnchor.constraint(equalToConstant: 1)
        drawerDividerHeight.priority = .init(999)

        // Stored so the resize grip can grow the transcript area along with
        // the AI Assist body — see `aiDrawerResizePan(_:)`.
        let scrollHeightConstraint = scroll.heightAnchor
            .constraint(equalToConstant: transcriptScrollHeight)
        transcriptScrollHeightConstraint = scrollHeightConstraint

        NSLayoutConstraint.activate([

            // Scroll starts below the top action strip (Ask AI + 📎 + pop-out
            // + timer) so transcript text never collides with them. The strip
            // is centered on a 24pt pill button + 8pt vertical padding.
            scroll.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 38),
            scroll.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            scrollHeightConstraint,

            // Top action strip: anchored at top+8, centered on a 20pt button.
            // Chevron pill is anchored to the trailing edge; Ask AI sits to
            // its left with a 2pt seam so the two read as one split control.
            askAIChevron.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 8),
            askAIChevron.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -10),

            askAI.centerYAnchor.constraint(equalTo: askAIChevron.centerYAnchor),
            askAI.trailingAnchor.constraint(equalTo: askAIChevron.leadingAnchor, constant: -2),

            attach.centerYAnchor.constraint(equalTo: askAI.centerYAnchor),
            attach.trailingAnchor.constraint(equalTo: askAI.leadingAnchor, constant: -6),
            attach.widthAnchor.constraint(equalToConstant: 18),
            attach.heightAnchor.constraint(equalToConstant: 18),

            durLabel.centerYAnchor.constraint(equalTo: askAI.centerYAnchor),
            durLabel.trailingAnchor.constraint(equalTo: attach.leadingAnchor, constant: -10),

            popOut.centerYAnchor.constraint(equalTo: askAI.centerYAnchor),
            popOut.trailingAnchor.constraint(equalTo: durLabel.leadingAnchor, constant: -6),
            popOut.widthAnchor.constraint(equalToConstant: 16),
            popOut.heightAnchor.constraint(equalToConstant: 16),

            // Left half of the top strip: Save recording + folder glyph.
            saveCheckbox.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            saveCheckbox.centerYAnchor.constraint(equalTo: askAI.centerYAnchor),
            reveal.leadingAnchor.constraint(equalTo: saveCheckbox.trailingAnchor, constant: 2),
            reveal.centerYAnchor.constraint(equalTo: askAI.centerYAnchor),
            reveal.widthAnchor.constraint(equalToConstant: 16),
            reveal.heightAnchor.constraint(equalToConstant: 16),
            popOut.leadingAnchor.constraint(greaterThanOrEqualTo: reveal.trailingAnchor, constant: 8),

            waveform.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            waveform.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 12),
            waveform.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            waveform.heightAnchor.constraint(equalToConstant: 36),
            waveform.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -6),

            bottomBar.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 8),
            bottomBar.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -8),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),
            // bottomBar.bottom is no longer pinned to effectView.bottom — that
            // would force the capture controls to follow the bottom edge when
            // the AI Assist drawer expands the panel. The drawer container
            // below takes that role instead.

            micIcon.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 10),
            micIcon.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            micIcon.widthAnchor.constraint(equalToConstant: 14),
            micIcon.heightAnchor.constraint(equalToConstant: 14),

            popup.leadingAnchor.constraint(equalTo: micIcon.trailingAnchor, constant: 4),
            popup.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 100),

            sysLabel.leadingAnchor.constraint(equalTo: popup.trailingAnchor, constant: 8),
            sysLabel.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            sysWarning.leadingAnchor.constraint(equalTo: sysLabel.trailingAnchor, constant: 3),
            sysWarning.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            sysWarning.widthAnchor.constraint(equalToConstant: 11),
            sysWarning.heightAnchor.constraint(equalToConstant: 11),

            sysSwitch.leadingAnchor.constraint(equalTo: sysWarning.trailingAnchor, constant: 3),
            sysSwitch.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            hoverTarget.leadingAnchor.constraint(equalTo: sysLabel.leadingAnchor, constant: -4),
            hoverTarget.trailingAnchor.constraint(equalTo: sysSwitch.trailingAnchor, constant: 4),
            hoverTarget.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            hoverTarget.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),

            translateIconView.leadingAnchor.constraint(equalTo: sysSwitch.trailingAnchor, constant: 10),
            translateIconView.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            translateIconView.widthAnchor.constraint(equalToConstant: 12),
            translateIconView.heightAnchor.constraint(equalToConstant: 12),

            translatePop.leadingAnchor.constraint(equalTo: translateIconView.trailingAnchor, constant: 2),
            translatePop.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            translatePop.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
            translatePop.trailingAnchor.constraint(lessThanOrEqualTo: stopStack.leadingAnchor, constant: -10),

            stopStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -8),
            stopStack.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),

            // Banner overlays the waveform when shown (only happens briefly
            // during finalize/error states, when the waveform is idle anyway).
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: effectView.leadingAnchor, constant: 12),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -12),
            banner.centerXAnchor.constraint(equalTo: effectView.centerXAnchor),
            banner.centerYAnchor.constraint(equalTo: waveform.centerYAnchor),

            bannerIcon.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 8),
            bannerIcon.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            bannerIcon.widthAnchor.constraint(equalToConstant: 12),
            bannerIcon.heightAnchor.constraint(equalToConstant: 12),

            status.leadingAnchor.constraint(equalTo: bannerIcon.trailingAnchor, constant: 6),
            status.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            status.topAnchor.constraint(equalTo: banner.topAnchor, constant: 5),
            status.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -5),

            // AI Assist drawer ----------------------------------------------
            // Drawer hangs off the bottom of the capture region. Its top is
            // anchored just below the bottomBar; height is driven by a
            // toggleable constraint and the window frame grows / shrinks in
            // sync via positionAtBottomCenter(height:).
            drawer.topAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: 8),
            drawer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            // Keep the drawer's bottom edge above the system's bottom-edge
            // resize strip so the header is reliably clickable.
            drawer.bottomAnchor.constraint(
                equalTo: effectView.bottomAnchor,
                constant: -Self.aiDrawerBottomPadding
            ),
            drawerHeight,

            resizeGrip.topAnchor.constraint(equalTo: drawer.topAnchor),
            resizeGrip.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            resizeGrip.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            resizeGripHeight,

            drawerDivider.topAnchor.constraint(equalTo: resizeGrip.bottomAnchor),
            drawerDivider.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            drawerDivider.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            drawerDividerHeight,

            drawerHeader.topAnchor.constraint(equalTo: drawerDivider.bottomAnchor),
            drawerHeader.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            drawerHeader.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            drawerHeaderHeight,

            drawerChevron.leadingAnchor.constraint(equalTo: drawerHeader.leadingAnchor, constant: 12),
            drawerChevron.centerYAnchor.constraint(equalTo: drawerHeader.centerYAnchor),
            drawerChevron.widthAnchor.constraint(equalToConstant: 10),
            drawerChevron.heightAnchor.constraint(equalToConstant: 10),

            drawerLabel.leadingAnchor.constraint(equalTo: drawerChevron.trailingAnchor, constant: 6),
            drawerLabel.centerYAnchor.constraint(equalTo: drawerHeader.centerYAnchor),
            drawerLabel.trailingAnchor.constraint(lessThanOrEqualTo: drawerHeader.trailingAnchor, constant: -12),

            drawerBody.topAnchor.constraint(equalTo: drawerHeader.bottomAnchor),
            drawerBody.leadingAnchor.constraint(equalTo: drawer.leadingAnchor),
            drawerBody.trailingAnchor.constraint(equalTo: drawer.trailingAnchor),
            drawerBody.bottomAnchor.constraint(equalTo: drawer.bottomAnchor),
        ])

        refreshAIDrawerToggleLabel()
        refreshMediaRecordingUI()
        panel.contentView = effectView
    }

    /// Builds a pill button title with an optional hotkey hint baked into
    /// the right side. The hint reads as a dim, slightly smaller secondary
    /// label so it doesn't compete with the action verb.
    private func pillTitle(_ label: String, hint: String? = nil) -> NSAttributedString {
        let body = NSMutableAttributedString(
            string: label,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            ]
        )
        if let hint, !hint.isEmpty {
            body.append(NSAttributedString(
                string: "  \(hint)",
                attributes: [
                    .foregroundColor: NSColor.white.withAlphaComponent(0.55),
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                ]
            ))
        }
        return body
    }

    private func makePrimaryStopButton() -> NSButton {
        let btn = PillButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        // Accent (blue by default) instead of systemRed — Stop here finishes
        // the dictation and pastes the result; it's a "complete" not a
        // "destructive" action, and red was reading as cancel/abort.
        btn.fillColor = NSColor.controlAccentColor
        btn.font = .systemFont(ofSize: 10, weight: .semibold)
        btn.contentTintColor = .white
        btn.imagePosition = .noImage
        btn.cornerRadius = 8
        btn.horizontalPadding = 6
        btn.attributedTitle = pillTitle("Stop", hint: "⌥Space")
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        return btn
    }

    private func makeSecondaryHideButton() -> NSButton {
        let btn = PillButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.fillColor = NSColor.white.withAlphaComponent(0.12)
        btn.font = .systemFont(ofSize: 10, weight: .semibold)
        btn.contentTintColor = .white
        btn.imagePosition = .noImage
        btn.cornerRadius = 8
        btn.horizontalPadding = 6
        btn.attributedTitle = pillTitle("Hide")
        btn.toolTip = "Hide this panel (recording keeps running in the background)"
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        return btn
    }

    private func makeRewriteButton() -> NSButton {
        let btn = PillButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        // Purple is the macOS convention for AI-flavoured affordances —
        // distinct from Stop's accent blue so the two finishing actions
        // read as different intents at a glance.
        btn.fillColor = NSColor.systemPurple
        btn.font = .systemFont(ofSize: 10, weight: .semibold)
        btn.contentTintColor = .white
        btn.imagePosition = .imageLeading
        btn.imageHugsTitle = true
        btn.cornerRadius = 8
        btn.horizontalPadding = 6
        if let sparkle = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Rewrite"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            btn.image = sparkle.withSymbolConfiguration(config) ?? sparkle
        }
        btn.attributedTitle = pillTitle(" Rewrite", hint: "⌥⇧Space")
        btn.toolTip = "Stop the recording and ask the AI to fix grammar / transcription mistakes before paste (⌥⇧Space)"
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        return btn
    }

    private func makeCompactAIButton() -> NSButton {
        let btn = PillButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.fillColor = NSColor.controlAccentColor
        btn.font = .systemFont(ofSize: 11, weight: .semibold)
        btn.contentTintColor = .white
        btn.imagePosition = .imageLeading
        btn.imageHugsTitle = true
        btn.cornerRadius = 8
        btn.horizontalPadding = 6
        if let sparkle = NSImage(
            systemSymbolName: "sparkles",
            accessibilityDescription: "Ask AI"
        ) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            btn.image = sparkle.withSymbolConfiguration(config) ?? sparkle
        }
        btn.attributedTitle = NSAttributedString(
            string: " Ask AI",
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            ]
        )
        btn.toolTip = "Send the transcript to AI Assist"
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return btn
    }

    /// The split-button chevron glued to the right of "Ask AI". Same pill
    /// fill so the two read as one control, but only renders a chevron icon
    /// — clicking it opens the actions menu instead of firing a roundtrip.
    private func makeCompactAIChevronButton() -> NSButton {
        let btn = PillButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.fillColor = NSColor.controlAccentColor
        btn.contentTintColor = .white
        btn.imagePosition = .imageOnly
        btn.cornerRadius = 8
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        if let chev = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Ask AI options") {
            btn.image = chev.withSymbolConfiguration(config) ?? chev
        }
        btn.toolTip = "Ask AI with a custom prompt"
        btn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        btn.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return btn
    }

    // MARK: - Mic Devices

    private func refreshMicDevices() {
        guard let popup = micPopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "Default")

        let devices = VoiceTranscriptionRecorder.availableInputDevices()
        for device in devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
        }
    }

    @objc private func micDeviceChanged() {
        let uid = micPopup?.selectedItem?.representedObject as? String
        service.recorder.setInputDevice(uid: uid)

        // Mid-recording: hot-restart the mic capture so the new device
        // applies to the *current* session. Mirrors translation's
        // restartLiveClients flow on translateLanguageChanged.
        if service.state == .recording {
            service.restartMicCapture()
        }
    }

    // MARK: - Actions

    @objc private func stopTapped() {
        stopRecording()
    }

    @objc private func rewriteTapped() {
        // Caller chose Rewrite mid-recording — override whatever intent was
        // pending so the in-flight transcript flows through the LLM cleanup
        // pass before paste, regardless of how the recording was started.
        pendingFinalizeIntent = .rewriteAndPaste
        stopRecording()
    }

    /// True when the recorder is actively capturing system audio, OR (when
    /// idle/transcribing) when the panel's Sys toggle is on so the next
    /// recording would capture it. Used by the ⌥⇧Space hotkey gate so the
    /// shortcut becomes a silent no-op when sys audio is in play.
    var isSystemAudioCapturing: Bool {
        if service.isSystemAudioEnabled { return true }
        return systemAudioSwitch?.state == .on
    }

    @objc private func hideTapped() {
        hideKeepingRecording()
    }

    // MARK: - Ask AI

    @objc private func attachWindowTapped(_ sender: NSButton) {
        // The attached window is the video source of the file being written
        // — swapping it mid-file would splice two windows into one movie.
        if service.isMediaRecording {
            setBanner(Self.attachLockedMessage, severity: .info)
            return
        }
        let popover = windowPickerPopover ?? WindowPickerPopover()
        windowPickerPopover = popover
        popover.currentSelection = pendingAIWindow
        popover.onSelect = { [weak self] picked in
            guard let self else { return }
            self.pendingAIWindow = picked
            self.refreshAttachWindowButton()
        }
        popover.show(from: sender)
    }

    /// Update the 📎 button so it reflects whether a window is currently
    /// staged for attachment. Tints blue + adds the picked app's icon overlay
    /// so the user can see at a glance what they've attached.
    private func refreshAttachWindowButton() {
        guard let attach = attachWindowButton else { return }
        if let window = pendingAIWindow {
            attach.contentTintColor = NSColor.controlAccentColor
            attach.toolTip = service.isMediaRecording
                ? "Recording \(window.appName) to video — \(Self.attachLockedMessage)"
                : "Attached: \(window.title.isEmpty ? window.appName : window.title) — click to change"
        } else {
            attach.contentTintColor = .white.withAlphaComponent(0.8)
            attach.toolTip = "Attach a window screenshot to the AI request"
        }
    }

    /// Ask AI takes a snapshot of the current transcript and sends it without
    /// stopping the recording. The user keeps speaking; pressing Ask AI again
    /// later sends another snapshot. Stop still finalizes the recording in the
    /// normal way.
    @objc private func askAITapped() {
        guard Settings.shared.isAIEnabled else {
            setBanner("Set an OpenAI API key in Preferences → AI to use Ask AI.", severity: .warning)
            return
        }
        let text = service.transcript.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || pendingAIWindow != nil else {
            setBanner("Nothing to send yet — speak or attach a window, then press Ask AI.", severity: .info)
            return
        }
        clearCustomPromptDraft()
        handoffToAIAssist(prompt: text.isEmpty ? Self.screenshotOnlyPrompt : text)
    }

    /// Sends the snapshot prompt (+ optional window screenshot) to the AI
    /// Assist window and keeps the voice panel exactly as it is — the user
    /// is still recording, the transcript is still accumulating, the timer
    /// is still ticking. The AI-side staging (📎 selection) intentionally
    /// stays active so repeated Ask AI presses keep using the selected
    /// screenshot until the user changes it or the recording panel closes.
    ///
    /// `customPromptPrefix` is forwarded to `AIAssistWindowController` for
    /// the one call so the Custom Question dropdown can override the
    /// preference-configured prefix without persisting a change.
    private func handoffToAIAssist(prompt: String, customPromptPrefix: String? = nil) {
        aiAssistHandoffGeneration += 1
        let handoffGeneration = aiAssistHandoffGeneration
        let stagedWindow = pendingAIWindow

        // Snapshot the recording-window start now (on the main actor) so the
        // AI Assist call can time-filter clips captured during the session.
        // The recording stays live across Ask AI presses, so this remains
        // valid for the entire transcript window.
        let recordingStartedAt = service.recordingStartTime

        Task { [weak self, stagedWindow] in
            let imageData: Data?
            if let win = stagedWindow {
                imageData = await WindowScreenshotService().captureWindowAsJPEG(
                    windowID: win.id,
                    quality: 0.7,
                    scale: 1
                )
            } else {
                imageData = nil
            }
            let shouldContinue = await MainActor.run { [weak self] in
                self?.aiAssistHandoffGeneration == handoffGeneration
            }
            guard shouldContinue else { return }
            await MainActor.run {
                AIAssistWindowController.shared.askAI(
                    prompt: prompt,
                    imageData: imageData,
                    attachedWindowSummary: stagedWindow.map {
                        "\($0.appName) — \($0.title)"
                    },
                    customPromptPrefix: customPromptPrefix,
                    recordingStartedAt: recordingStartedAt
                )
            }
        }
    }

    // MARK: - Save recording (media file)

    static let attachLockedMessage = "Uncheck “Save recording” to change the attached window."

    @objc private func recordMediaToggled(_ sender: NSButton) {
        let wantsRecording = sender.state == .on
        switch VoiceMediaRecordingPolicy.action(
            checkboxOn: wantsRecording,
            sessionRecording: service.state == .recording,
            mediaRecording: service.isMediaRecording
        ) {
        case .startNow:
            startMediaRecordingFromUI()
        case .stopNow:
            service.stopMediaRecording(reason: .userRequested)
        case .arm:
            mediaRecordingArmed = true
        case .disarm:
            mediaRecordingArmed = false
        case .none:
            break
        }
        refreshMediaRecordingUI()
    }

    /// Starts the file recording for the live session using the currently
    /// attached window (if any) and the selected mic. Surfaces failures in
    /// the banner and reverts the checkbox.
    private func startMediaRecordingFromUI() {
        let uid = micPopup?.selectedItem?.representedObject as? String
        if let message = service.startMediaRecording(window: pendingAIWindow, micDeviceUID: uid) {
            let severity: BannerSeverity = message.lowercased().contains("permission") ? .warning : .error
            setBanner(message, severity: severity)
            return
        }
        refreshAttachWindowButton()
        if let window = pendingAIWindow {
            showTemporaryStatus("Recording \(window.appName) window + audio to file. Attached window is locked until you uncheck.", duration: 4)
        } else {
            showTemporaryStatus("Recording audio to file.", duration: 3)
        }
    }

    /// Reflects `service.isMediaRecording` / the armed flag in the checkbox
    /// and folder glyph. Single source of truth so every lifecycle path
    /// (stop, error, window lost, hide) ends up consistent.
    private func refreshMediaRecordingUI() {
        let active = service.isMediaRecording
        recordMediaCheckbox?.state = (active || mediaRecordingArmed) ? .on : .off
        if active, let url = service.mediaRecordingURL {
            recordMediaCheckbox?.toolTip = "Writing \(url.lastPathComponent) — uncheck to stop and finalise the file"
            revealRecordingButton?.toolTip = "Show \(url.lastPathComponent) in Finder"
        } else {
            recordMediaCheckbox?.toolTip = pendingAIWindow == nil
                ? "Save the audio of this session to a file (\(Settings.shared.voiceRecordingsFolderURL.lastPathComponent))"
                : "Save this session as a video of the attached window, with audio"
            revealRecordingButton?.toolTip = "Show the recordings folder in Finder"
        }
        refreshAttachWindowButton()
    }

    @objc private func revealRecordingTapped() {
        if service.isMediaRecording, let url = service.mediaRecordingURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let folder = Settings.shared.voiceRecordingsFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func handleMediaRecordingStopped(_ event: VoiceTranscriptionService.MediaStopEvent) {
        refreshMediaRecordingUI()
        switch event.reason {
        case .userRequested:
            if let saved = event.result {
                showTemporaryStatus("Saved \(saved.url.lastPathComponent)", duration: 4)
            } else {
                showTemporaryStatus("Recording was too short to save.", duration: 3)
            }

        case .sessionEnded:
            break

        case .failed(let message):
            setBanner("Media recording stopped: \(message)", severity: .error)

        case .sourceLost(let appName):
            let saved = event.result != nil
            // Panel banner (if visible) + menu-bar bubble so the user finds
            // out even when the panel is hidden behind the meeting.
            setBanner(
                MeetingPromptPolicy.mediaSourceLostMessage(appName: appName, saved: saved),
                severity: .warning
            )
            let bubble = MeetingPromptBubbleController.shared
            if bubble.onStopRecording == nil {
                // Meeting detection (which normally wires this) is macOS 14+
                // only; give the bubble's Stop & Save a target regardless.
                bubble.onStopRecording = {
                    VoiceRecordingPanelController.shared.show()
                    VoiceRecordingPanelController.shared.stopRecording()
                }
            }
            if bubble.anchorProvider == nil {
                bubble.anchorProvider = {
                    (NSApp.delegate as? AppDelegate)?.statusBarButton
                }
            }
            guard case .recording = service.state else { return }
            bubble.showMediaSourceLost(appName: appName, saved: saved)
        }
    }

    // MARK: - AI Assist drawer
    //
    // Three states map to three panel heights so the bottom edge of the panel
    // stays pinned to the bottom of the screen while the drawer toggles:
    //   • not yet embedded       → 0pt drawer  (panel = base)
    //   • embedded but minimized → 27pt header (panel = base + 27)
    //   • expanded               → header + body (panel = base + 27 + body)
    // Once embedded, the drawer header stays visible so the user always has a
    // way to re-expand after collapsing.

    /// Total height of the voice panel for the drawer's current state. Every
    /// frame-resize code path goes through this so layout and the window
    /// frame stay in lockstep. The resize grip is omitted from the chrome
    /// when the drawer is minimized — it's not visible there.
    private var currentPanelHeight: CGFloat {
        // `VoiceRecordingPanelWindow.panelHeight` (222) assumes the original
        // 96pt transcript scroll. Add the delta so a grown transcript area
        // pushes the panel taller. Always reserve the drawer's bottom
        // padding — the AutoLayout constraint pins `drawer.bottom` that
        // far above `effectView.bottom`, so the panel frame has to be tall
        // enough to satisfy it whether or not the drawer is populated.
        // Also account for the 4pt top + 4pt bottom inset between the
        // window contentView (transparent rectangle, for resize hit-testing)
        // and the visual effect view that hosts all the chrome.
        let transcriptDelta = transcriptScrollHeight - Self.transcriptBaseHeight
        let base = VoiceRecordingPanelWindow.panelHeight
            + transcriptDelta
            + Self.aiDrawerBottomPadding
        guard aiDrawerHasContent else { return base }
        let dividerHeader = 1 + Self.aiDrawerHeaderHeight
        return aiDrawerExpanded
            ? base + Self.aiDrawerGripHeight + dividerHeader + aiDrawerBodyHeight
            : base + dividerHeader
    }

    @objc private func aiDrawerToggleTapped() {
        if aiDrawerExpanded { collapseAIDrawer() } else { expandAIDrawer() }
    }

    private func expandAIDrawer() {
        aiDrawerHasContent = true
        if aiDrawerExpanded {
            applyDrawerLayout(animated: false)
            return
        }
        aiDrawerExpanded = true
        applyDrawerLayout(animated: true)
    }

    private func collapseAIDrawer() {
        guard aiDrawerExpanded else { return }
        aiDrawerExpanded = false
        applyDrawerLayout(animated: true)
    }

    private func applyDrawerLayout(animated: Bool) {
        let dividerHeader = 1 + Self.aiDrawerHeaderHeight
        let drawerHeight: CGFloat
        let bodyVisible: Bool
        let containerVisible: Bool
        if !aiDrawerHasContent {
            drawerHeight = 0
            bodyVisible = false
            containerVisible = false
        } else if aiDrawerExpanded {
            drawerHeight = Self.aiDrawerGripHeight + dividerHeader + aiDrawerBodyHeight
            bodyVisible = true
            containerVisible = true
        } else {
            drawerHeight = dividerHeader
            bodyVisible = false
            containerVisible = true
        }
        aiDrawerHeightConstraint?.constant = drawerHeight
        transcriptScrollHeightConstraint?.constant = transcriptScrollHeight
        aiDrawerEmbedHost?.isHidden = !bodyVisible
        // The grip is only useful while the body is visible — hide it (and
        // collapse its 6pt slot) when minimized so the resize cursor doesn't
        // show up over a strip that can't actually be dragged.
        aiDrawerResizeGrip?.isHidden = !bodyVisible
        aiDrawerResizeGripHeightConstraint?.constant = bodyVisible ? Self.aiDrawerGripHeight : 0
        aiDrawerContainer?.isHidden = !containerVisible
        // The window's resize-handle minSize has to follow the drawer state.
        // Without this, AppKit lets the user drag the top edge well below
        // what AutoLayout permits, and AutoLayout snaps the frame back —
        // producing the jumpy "rubber band" resize the user reported.
        updatePanelResizeLimits()
        resizePanelToCurrentHeight(animated: animated)
        refreshAIDrawerToggleLabel()
    }

    /// Pushes the current drawer state into the window's `minSize` /
    /// `maxSize` so the system resize handles stop where AutoLayout would
    /// stop anyway. Called from `applyDrawerLayout` (drawer toggled) and
    /// from `setup` (initial state).
    private func updatePanelResizeLimits() {
        guard let panel = window else { return }
        let visible = NSScreen.main?.visibleFrame

        // Match the math in `currentPanelHeight`, but pin the transcript
        // and body to their minimums so the floor reflects "smallest
        // window the user can drag to".
        var minHeight = VoiceRecordingPanelWindow.panelHeight
            - Self.transcriptBaseHeight
            + Self.transcriptMinHeight
            + Self.aiDrawerBottomPadding
        if aiDrawerHasContent {
            let dividerHeader = 1 + Self.aiDrawerHeaderHeight
            minHeight += dividerHeader
            if aiDrawerExpanded {
                minHeight += Self.aiDrawerGripHeight + Self.aiDrawerMinBodyHeight
            }
        }
        panel.minSize = NSSize(
            width: VoiceRecordingPanelWindow.minPanelWidth,
            height: minHeight
        )
        panel.maxSize = NSSize(
            width: max(VoiceRecordingPanelWindow.minPanelWidth,
                       (visible?.width ?? 2000) - 40),
            height: max(minHeight, (visible?.height ?? 2000) - 60)
        )
    }

    // MARK: - Drawer resize

    @objc private func aiDrawerResizePan(_ gesture: NSPanGestureRecognizer) {
        guard aiDrawerExpanded, let host = aiDrawerContainer else { return }
        switch gesture.state {
        case .began:
            aiDrawerResizeStartBodyHeight = aiDrawerBodyHeight
            aiDrawerResizeStartScrollHeight = transcriptScrollHeight
        case .changed:
            // Gesture translation is in the host view's coordinate space.
            // In non-flipped NSViews, +Y is upward; dragging up (positive
            // translation) grows the panel, which sits at the bottom of
            // the screen and expands upward.
            //
            // The drag is split 50/50 between the transcript scroll and the
            // AI drawer body so the whole window grows by the full drag
            // distance — the user gets more transcript area AND more AI
            // response area from a single gesture.
            let translation = gesture.translation(in: host)
            let half = translation.y / 2
            let bodyTarget = clamp(aiDrawerResizeStartBodyHeight + half,
                                   Self.aiDrawerMinBodyHeight,
                                   Self.aiDrawerMaxBodyHeight)
            let scrollTarget = clamp(aiDrawerResizeStartScrollHeight + half,
                                     Self.transcriptMinHeight,
                                     Self.transcriptMaxHeight)
            let bodyChanged = bodyTarget != aiDrawerBodyHeight
            let scrollChanged = scrollTarget != transcriptScrollHeight
            if bodyChanged || scrollChanged {
                aiDrawerBodyHeight = bodyTarget
                transcriptScrollHeight = scrollTarget
                applyDrawerLayout(animated: false)
            }
        case .ended, .cancelled, .failed:
            // Nothing to commit — heights are already applied.
            break
        default:
            break
        }
    }

    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        max(minValue, min(maxValue, value))
    }

    // MARK: - System window resize (drag from any edge / corner)

    /// Called when the user resizes the panel via the system resize handles
    /// (drag from any edge or corner). Just redistributes the new total
    /// height between the transcript scroll and the AI drawer body.
    ///
    /// NOTE: we do *not* re-anchor the bottom edge during resize. NSWindow's
    /// origin is bottom-left, so dragging the bottom edge moves `origin.y`
    /// every tick — forcing it back to a fixed screen anchor would make the
    /// bottom edge fight the cursor and produce a glitchy resize. The
    /// "anchor at screen bottom" is established by `positionAtBottomCenter`
    /// on every `show()`, and programmatic drawer growth preserves
    /// `origin.y` via `resizePanelToCurrentHeight`, so the panel still
    /// opens at the bottom each session and grows upward from wherever its
    /// current bottom edge sits.
    @objc private func panelWindowDidResize(_ note: Notification) {
        guard !isApplyingProgrammaticResize, window != nil else { return }
        syncFlexibleHeightsToFrame()
    }

    private func syncFlexibleHeightsToFrame() {
        guard let panel = window else { return }
        let actualHeight = panel.frame.height
        let delta = actualHeight - currentPanelHeight
        guard abs(delta) > 0.5 else { return }

        // When the AI drawer is expanded the user has presumably opened it
        // *because* they want to read the answer — give the whole resize
        // delta to the AI body so dragging the panel taller grows the AI
        // pane (and dragging shorter shrinks it). The transcript keeps its
        // user-chosen height. Only fall back to growing the transcript
        // when the drawer is collapsed.
        //
        // The drag-grip on top of the drawer still splits 50/50 (see
        // `aiDrawerResizePan`) — that's the gesture for "grow both halves
        // together". System resize handles map 1:1 to whichever pane is
        // active.
        if aiDrawerExpanded {
            let newBody = clamp(aiDrawerBodyHeight + delta,
                                Self.aiDrawerMinBodyHeight,
                                Self.aiDrawerMaxBodyHeight)
            aiDrawerBodyHeight = newBody
        } else {
            let newScroll = clamp(transcriptScrollHeight + delta,
                                  Self.transcriptMinHeight,
                                  Self.transcriptMaxHeight)
            transcriptScrollHeight = newScroll
        }

        // Apply the new constraints WITHOUT triggering a programmatic resize
        // — the window is already at the user-chosen height.
        transcriptScrollHeightConstraint?.constant = transcriptScrollHeight
        if aiDrawerHasContent {
            let dividerHeader = 1 + Self.aiDrawerHeaderHeight
            let drawerHeight: CGFloat = aiDrawerExpanded
                ? Self.aiDrawerGripHeight + dividerHeader + aiDrawerBodyHeight
                : dividerHeader
            aiDrawerHeightConstraint?.constant = drawerHeight
        }
    }

    private func resizePanelToCurrentHeight(animated: Bool) {
        guard let panel = window else { return }
        var frame = panel.frame
        let newHeight = currentPanelHeight
        guard frame.height != newHeight else { return }
        // Keep the bottom edge pinned (visibleFrame.minY + 6) so the drawer
        // grows / shrinks upward, matching the panel's bottom-of-screen anchor.
        frame.size.height = newHeight
        isApplyingProgrammaticResize = true
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                self?.isApplyingProgrammaticResize = false
            })
        } else {
            panel.setFrame(frame, display: true)
            isApplyingProgrammaticResize = false
        }
    }

    private func refreshAIDrawerToggleLabel() {
        let chevron = aiDrawerExpanded ? "chevron.down" : "chevron.up"
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        if let img = NSImage(systemSymbolName: chevron, accessibilityDescription: nil) {
            aiDrawerChevron?.image = img.withSymbolConfiguration(config) ?? img
        }
        aiDrawerHeaderLabel?.stringValue = aiDrawerExpanded
            ? "Hide AI Response"
            : "Show AI Response"
    }

    // MARK: - Custom Prompt dropdown

    @objc private func askAIChevronTapped(_ sender: NSButton) {
        let popover = customPromptPopover ?? makeCustomPromptPopover()
        customPromptPopover = popover
        // Reset between opens so each session starts blank.
        customPromptTextView?.string = ""
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        DispatchQueue.main.async { [weak self] in
            self?.customPromptTextView?.window?.makeFirstResponder(self?.customPromptTextView)
        }
    }

    private func makeCustomPromptPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        let viewController = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 140))
        container.wantsLayer = true

        let title = NSTextField(labelWithString: "Custom Prompt")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .white.withAlphaComponent(0.92)
        container.addSubview(title)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(white: 0.18, alpha: 1)

        let text = CustomPromptTextView()
        text.frame = NSRect(x: 0, y: 0, width: 304, height: 70)
        text.isEditable = true
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .white.withAlphaComponent(0.95)
        text.insertionPointColor = .white
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 70)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.allowsUndo = true
        text.onSubmit = { [weak self] in self?.submitCustomPrompt() }
        text.onCancel = { [weak self] in self?.customPromptPopover?.performClose(nil) }
        scroll.documentView = text
        container.addSubview(scroll)
        customPromptTextView = text

        let send = NSButton(title: "Send", target: self, action: #selector(submitCustomPromptTapped))
        send.translatesAutoresizingMaskIntoConstraints = false
        send.bezelStyle = .rounded
        send.controlSize = .small
        send.keyEquivalent = "\r"

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCustomPromptTapped))
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}" // Esc

        container.addSubview(send)
        container.addSubview(cancel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 320),
            container.heightAnchor.constraint(equalToConstant: 140),

            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),

            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: 70),

            send.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            send.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            cancel.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        viewController.view = container
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 320, height: 140)
        return popover
    }

    @objc private func submitCustomPromptTapped() { submitCustomPrompt() }
    @objc private func cancelCustomPromptTapped() { customPromptPopover?.performClose(nil) }

    private func clearCustomPromptDraft() {
        customPromptPopover?.performClose(nil)
        customPromptTextView?.string = ""
    }

    private func submitCustomPrompt() {
        guard Settings.shared.isAIEnabled else {
            customPromptPopover?.performClose(nil)
            setBanner("Set an OpenAI API key in Preferences → AI to use Ask AI.", severity: .warning)
            return
        }
        let question = (customPromptTextView?.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            setBanner("Type a question, then press Send.", severity: .info)
            return
        }
        let transcript = service.transcript.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || pendingAIWindow != nil else {
            customPromptPopover?.performClose(nil)
            setBanner("Nothing to send yet — speak or attach a window, then press Ask AI.", severity: .info)
            return
        }
        clearCustomPromptDraft()
        handoffToAIAssist(
            prompt: transcript.isEmpty ? Self.screenshotOnlyPrompt : transcript,
            customPromptPrefix: question
        )
    }

    /// Builds the popup menu: "Off" + each supported language. The current
    /// selection is restored from Settings every time the panel is shown so
    /// changes made elsewhere (or persisted across launches) are reflected.
    private func rebuildTranslateMenu(into popup: NSPopUpButton) {
        popup.removeAllItems()

        let off = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        off.representedObject = "" // empty code = translation disabled
        popup.menu?.addItem(off)
        popup.menu?.addItem(.separator())

        for entry in Settings.Defaults.translationLanguages {
            let item = NSMenuItem(
                title: "\u{2192} \(entry.name)",
                action: nil,
                keyEquivalent: ""
            )
            item.representedObject = entry.code
            popup.menu?.addItem(item)
        }

        syncTranslatePopupSelection()
    }

    private func syncTranslatePopupSelection() {
        guard let popup = translatePopup, let menu = popup.menu else { return }
        let enabled = Settings.shared.translationEnabled
        let target = Settings.shared.translationTargetLanguage
        let activeCode = enabled ? target : ""
        for item in menu.items {
            if let code = item.representedObject as? String, code == activeCode {
                popup.select(item)
                return
            }
        }
        // Fallback: persisted code unknown — fall back to Off so the UI
        // doesn't lie about its state.
        if let firstOff = menu.items.first {
            popup.select(firstOff)
        }
    }

    @objc private func translateLanguageChanged(_ sender: NSPopUpButton) {
        let code = (sender.selectedItem?.representedObject as? String) ?? ""
        if code.isEmpty {
            Settings.shared.translationEnabled = false
        } else {
            Settings.shared.translationEnabled = true
            Settings.shared.translationTargetLanguage = code
        }

        // Mid-recording: hot-restart the realtime clients so the new mode
        // applies to the *current* session. The audio recorder keeps running.
        if service.state == .recording {
            service.restartLiveClients()
        }
    }

    // MARK: - Transcript pop-out

    @objc private func toggleTranscriptPopover(_ sender: NSButton) {
        if let popover = transcriptPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        showTranscriptPopover(from: sender)
    }

    private func showTranscriptPopover(from anchor: NSView) {
        let popover = transcriptPopover ?? makeTranscriptPopover()
        transcriptPopover = popover
        refreshTranscriptPopover()
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func makeTranscriptPopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        let viewController = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
        container.wantsLayer = true

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyTranscriptFromPopover))
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .inline
        copyButton.font = .systemFont(ofSize: 11, weight: .medium)
        copyButton.controlSize = .small
        container.addSubview(copyButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let text = NSTextView()
        text.frame = NSRect(x: 0, y: 0, width: 380, height: 240)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = .white.withAlphaComponent(0.92)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 240)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        container.addSubview(scroll)
        transcriptPopoverTextView = text

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 380),
            container.heightAnchor.constraint(equalToConstant: 280),

            copyButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            scroll.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        viewController.view = container
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 380, height: 280)
        return popover
    }

    /// Re-renders the popover's text view to match the current live
    /// transcript. Called both on open and from `onTranscriptUpdate` while
    /// the popover is visible so the text grows in real time. Scroll
    /// position is preserved so users can read older text without being
    /// yanked to the bottom by streaming deltas.
    private func refreshTranscriptPopover() {
        guard let textView = transcriptPopoverTextView else { return }
        let live = service.transcript
        let text = transcriptPlainText(live)
        let scrollView = textView.enclosingScrollView
        let savedOrigin = scrollView?.contentView.bounds.origin
        textView.string = text
        if let origin = savedOrigin {
            textView.scroll(origin)
        }
    }

    private func transcriptPlainText(_ live: VoiceTranscriptionService.LiveTranscript) -> String {
        let combined = live.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty { return combined }
        // While text is still streaming as partials, `combined` may be empty —
        // surface the partials in the same shape the on-screen renderer uses
        // so the popup and the inline view stay in lockstep.
        let mp = live.micPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        let sp = live.systemPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if mp.isEmpty && sp.isEmpty { return "" }
        if sp.isEmpty { return mp }
        if mp.isEmpty { return sp }
        return "[Mic] \(mp)\n\n[Sys] \(sp)"
    }

    @objc private func copyTranscriptFromPopover() {
        let text = transcriptPlainText(service.transcript)
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func systemAudioToggled(_ sender: NSSwitch) {
        let shouldEnable = sender.state == .on
        guard service.state == .recording else {
            // Idle: still need to revert a pending rewrite intent if the
            // user started a rewrite recording, decided to add sys audio
            // before pressing Stop, but hasn't actually started capture
            // yet. Doesn't apply because rewrite recordings always start
            // mic-only — but keep the affordances in sync.
            updateHotkeyAffordances()
            return
        }

        if service.setSystemAudioEnabled(shouldEnable) != nil {
            // Most common cause is a missing Screen Recording permission. Don't
            // pop a banner — the tooltip on the switch already explains it,
            // and `setSystemAudioEnabled` opened System Settings for the user.
            sender.state = service.isSystemAudioEnabled ? .on : .off
            refreshSystemAudioTooltip()
        } else {
            refreshSystemAudioTooltip()
        }

        // Sys audio is now part of the capture. AI rewrite is a dictation
        // feature only, and meeting/system-audio recordings are save-only on
        // finalize so BrainCache doesn't paste a whole meeting into whatever
        // app was frontmost.
        if service.isSystemAudioEnabled, pendingFinalizeIntent == .rewriteAndPaste {
            pendingFinalizeIntent = .skipPaste
            setBanner("AI Rewrite turned off — system audio recordings are saved, not pasted.", severity: .info)
        }

        updateHotkeyAffordances()
    }

    /// In mic-only mode ⌥Space stops the recording, so the inline hint sits
    /// inside Stop and Hide is hidden. In mic+sys mode ⌥Space hides the
    /// panel (recording keeps running in the background), so the hint moves
    /// onto Hide and Stop drops its hint to avoid lying about the binding.
    private func updateHotkeyAffordances() {
        let systemAudioOn = systemAudioSwitch?.state == .on
        hideButton?.isHidden = !systemAudioOn
        stopButton?.attributedTitle = pillTitle("Stop", hint: systemAudioOn ? nil : "⌥Space")
        hideButton?.attributedTitle = pillTitle("Hide", hint: systemAudioOn ? "⌥Space" : nil)
        refreshRewriteButtonVisibility()
    }

    /// Single source of truth for the Rewrite pill's visibility. Hidden
    /// completely (not just disabled) when sys audio is in play — the
    /// feature simply doesn't apply, so showing a dead button would just
    /// add visual noise. Also hidden outside the .recording state since
    /// there's nothing to finish.
    private func refreshRewriteButtonVisibility() {
        let systemAudioOn = systemAudioSwitch?.state == .on
        let isRecording: Bool
        if case .recording = service.state { isRecording = true } else { isRecording = false }
        rewriteButton?.isHidden = !isRecording || systemAudioOn
    }

    // MARK: - Live transcript rendering

    private func renderTranscript(_ live: VoiceTranscriptionService.LiveTranscript) {
        guard let textView = transcriptTextView else { return }

        let dim = NSColor.white.withAlphaComponent(0.78)
        let bright = NSColor.white.withAlphaComponent(0.92)
        let labelColor = NSColor.systemBlue.withAlphaComponent(0.85)
        let sysLabelColor = NSColor.systemTeal.withAlphaComponent(0.85)

        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 11)
        let labelFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

        let entries = live.entries
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.timestamp < $1.timestamp }
        if !entries.isEmpty {
            // Only show source/timestamp prefixes when system audio is part of
            // the transcript. Mic-only gets a continuous, label-less render.
            let needsSourceLabels = entries.contains(where: { $0.source == .system })

            if needsSourceLabels {
                for (idx, entry) in entries.enumerated() {
                    if idx > 0 {
                        result.append(NSAttributedString(string: "\n",
                            attributes: [.font: font, .foregroundColor: bright]))
                    }

                    let sourceColor = entry.source == .mic ? labelColor : sysLabelColor
                    let prefix = "[\(VoiceTranscriptionService.LiveTranscript.formatTimestamp(entry.timestamp)) \(entry.source.rawValue)] "
                    result.append(NSAttributedString(string: prefix,
                        attributes: [.font: labelFont, .foregroundColor: sourceColor]))

                    result.append(NSAttributedString(
                        string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        attributes: [.font: font, .foregroundColor: entry.isFinal ? bright : dim]
                    ))
                }
            } else {
                for (idx, entry) in entries.enumerated() {
                    if idx > 0 {
                        result.append(NSAttributedString(string: " ",
                            attributes: [.font: font, .foregroundColor: bright]))
                    }
                    result.append(NSAttributedString(
                        string: entry.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        attributes: [.font: font, .foregroundColor: entry.isFinal ? bright : dim]
                    ))
                }
            }

            applyTranscript(result, to: textView)
            return
        }

        let hasMic = !live.mic.isEmpty || !live.micPartial.isEmpty
        let hasSys = !live.system.isEmpty || !live.systemPartial.isEmpty
        let bothActive = hasMic && hasSys

        if hasMic {
            if bothActive {
                result.append(NSAttributedString(string: "[Mic] ",
                    attributes: [.font: labelFont, .foregroundColor: labelColor]))
            }
            if !live.mic.isEmpty {
                result.append(NSAttributedString(string: live.mic,
                    attributes: [.font: font, .foregroundColor: bright]))
            }
            if !live.micPartial.isEmpty {
                if !live.mic.isEmpty {
                    result.append(NSAttributedString(string: " ",
                        attributes: [.font: font, .foregroundColor: bright]))
                }
                result.append(NSAttributedString(string: live.micPartial,
                    attributes: [.font: font, .foregroundColor: dim]))
            }
        }

        if hasSys {
            if hasMic {
                result.append(NSAttributedString(string: "\n\n",
                    attributes: [.font: font, .foregroundColor: bright]))
            }
            if bothActive {
                result.append(NSAttributedString(string: "[Sys] ",
                    attributes: [.font: labelFont, .foregroundColor: sysLabelColor]))
            }
            if !live.system.isEmpty {
                result.append(NSAttributedString(string: live.system,
                    attributes: [.font: font, .foregroundColor: bright]))
            }
            if !live.systemPartial.isEmpty {
                if !live.system.isEmpty {
                    result.append(NSAttributedString(string: " ",
                        attributes: [.font: font, .foregroundColor: bright]))
                }
                result.append(NSAttributedString(string: live.systemPartial,
                    attributes: [.font: font, .foregroundColor: dim]))
            }
        }

        applyTranscript(result, to: textView)
    }

    private func applyTranscript(_ result: NSAttributedString, to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let newLength = result.length

        // Fast path: when the existing rendered text is a prefix of the new
        // string (the common case during streaming — the transcript only
        // grows), append the new suffix instead of re-layouting the whole
        // textStorage. This keeps per-delta render cost O(delta) instead of
        // O(transcript length).
        if storage.length == lastRenderedLength,
           newLength >= lastRenderedLength,
           lastRenderedLength > 0,
           Self.attributedStringHasPrefix(result, prefixLength: lastRenderedLength, matching: storage) {
            if newLength > lastRenderedLength {
                let suffixRange = NSRange(location: lastRenderedLength, length: newLength - lastRenderedLength)
                let suffix = result.attributedSubstring(from: suffixRange)
                storage.append(suffix)
                lastRenderedLength = newLength
                textView.needsDisplay = true
                transcriptScroll?.contentView.needsDisplay = true
                textView.scrollToEndOfDocument(nil)
            }
            return
        }

        // Fallback: a finalization rewrote earlier content, the user cleared
        // the transcript, or the textStorage drifted from our cache. Replace
        // wholesale and re-layout.
        storage.setAttributedString(result)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
        lastRenderedLength = newLength
        textView.needsDisplay = true
        transcriptScroll?.contentView.needsDisplay = true
        textView.scrollToEndOfDocument(nil)
    }

    /// Returns true when the first `prefixLength` UTF-16 code units of
    /// `result.string` match `storage.string` over its full length. Cheaper
    /// than building a substring just to compare.
    private static func attributedStringHasPrefix(_ result: NSAttributedString,
                                                  prefixLength: Int,
                                                  matching storage: NSTextStorage) -> Bool {
        guard storage.length == prefixLength, prefixLength > 0 else { return prefixLength == 0 }
        let resultPrefix = result.string.utf16
        let storageStr = storage.string.utf16
        guard storageStr.count == prefixLength, resultPrefix.count >= prefixLength else { return false }
        var lhs = storageStr.startIndex
        var rhs = resultPrefix.startIndex
        for _ in 0..<prefixLength {
            if storageStr[lhs] != resultPrefix[rhs] { return false }
            lhs = storageStr.index(after: lhs)
            rhs = resultPrefix.index(after: rhs)
        }
        return true
    }

    private func clearTranscript() {
        transcriptTextView?.textStorage?.setAttributedString(NSAttributedString(string: ""))
        lastRenderedLength = 0
    }

    private enum BannerSeverity {
        case info, warning, error
    }

    private func setBanner(_ message: String, severity: BannerSeverity = .info) {
        guard let label = statusLabel, let banner = statusBanner else { return }
        label.stringValue = message
        if message.isEmpty {
            banner.isHidden = true
            return
        }
        banner.isHidden = false
        let bg: NSColor
        let icon: String
        let tint: NSColor
        switch severity {
        case .info:
            bg = NSColor.white.withAlphaComponent(0.10)
            icon = "info.circle.fill"
            tint = NSColor.white.withAlphaComponent(0.85)
        case .warning:
            bg = NSColor.systemYellow.withAlphaComponent(0.22)
            icon = "exclamationmark.triangle.fill"
            tint = NSColor.systemYellow
        case .error:
            bg = NSColor.systemRed.withAlphaComponent(0.22)
            icon = "exclamationmark.octagon.fill"
            tint = NSColor.systemRed
        }
        banner.layer?.backgroundColor = bg.cgColor
        statusBannerIcon?.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        statusBannerIcon?.contentTintColor = tint
    }

    // MARK: - State Handling

    private func handleStateChange(_ state: VoiceTranscriptionService.State) {
        NotificationCenter.default.post(name: .voiceRecordingStateDidChange, object: nil)
        switch state {
        case .idle:
            statusResetWorkItem?.cancel()
            statusResetWorkItem = nil
            setBanner("")
            stopDurationTimer()
            waveformView?.setMode(.idle)
            systemAudioSwitch?.isEnabled = true
            refreshRewriteButtonVisibility()
            refreshMediaRecordingUI()

        case .recording:
            if statusResetWorkItem == nil {
                setBanner("")
            }
            startDurationTimer()
            stopButton?.isEnabled = true
            waveformView?.setMode(.recording)
            systemAudioSwitch?.isEnabled = true
            updateHotkeyAffordances()
            refreshMediaRecordingUI()
            // Reset per-source tracking for the new session.
            clientStates.removeAll()

        case .transcribing:
            statusResetWorkItem?.cancel()
            statusResetWorkItem = nil
            setBanner("")
            stopDurationTimer()
            stopButton?.isEnabled = false
            waveformView?.setMode(.transcribing)
            systemAudioSwitch?.isEnabled = false
            refreshRewriteButtonVisibility()
            mediaRecordingArmed = false
            refreshMediaRecordingUI()
            flushPendingRender()

        case .completed:
            statusResetWorkItem?.cancel()
            statusResetWorkItem = nil
            setBanner("")
            waveformView?.setMode(.idle)
            systemAudioSwitch?.isEnabled = true
            refreshRewriteButtonVisibility()
            flushPendingRender()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.hide()
            }

        case .error(let message):
            statusResetWorkItem?.cancel()
            statusResetWorkItem = nil
            let severity: BannerSeverity = message.lowercased().contains("permission") ? .warning : .error
            setBanner(message, severity: severity)
            stopDurationTimer()
            stopButton?.isEnabled = true
            waveformView?.setMode(.idle)
            systemAudioSwitch?.isEnabled = true
            systemAudioSwitch?.state = .off
            updateHotkeyAffordances()
            mediaRecordingArmed = false
            refreshMediaRecordingUI()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard case .error = self?.service.state else { return }
                self?.service.cancel()
                self?.hide()
            }
        }
    }

    // MARK: - Per-source realtime state

    /// Tracks `.reconnecting` for each source and surfaces a non-blocking
    /// status banner ("Reconnecting microphone…") while at least one source
    /// is mid-reconnect. Cleared once every source is back to `.ready`. Only
    /// shown during `.recording` so the panel's regular error / completed
    /// banners aren't disturbed.
    private func handleClientStateChange(source: RealtimeTranscriptionClient.Source,
                                         state: RealtimeTranscriptionClient.State) {
        clientStates[source] = state
        guard case .recording = service.state else { return }

        let reconnecting = clientStates.filter { _, value in
            if case .reconnecting = value { return true }
            return false
        }.keys.sorted { $0.rawValue < $1.rawValue }

        if reconnecting.isEmpty {
            // Only clear the banner if we were the ones who set it — leave
            // user-facing error / info banners alone.
            if statusResetWorkItem == nil { setBanner("") }
            return
        }

        let label: String
        switch reconnecting.count {
        case 1:
            label = reconnecting[0] == .mic ? "microphone" : "system audio"
        default:
            label = "audio"
        }
        // Soft-info severity so the user sees that something is happening
        // without it looking like a hard failure. The reconnect path saves
        // the transcript on terminal failure, so this banner is purely an
        // FYI.
        setBanner("Reconnecting \(label)…", severity: .info)
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let duration = self.service.recordingDuration
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            self.durationLabel?.stringValue = String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func showTemporaryStatus(_ message: String, duration: TimeInterval = 3.0) {
        statusResetWorkItem?.cancel()
        setBanner(message, severity: .info)

        let work = DispatchWorkItem { [weak self] in
            guard self?.service.state == .recording else { return }
            self?.setBanner("")
            self?.statusResetWorkItem = nil
        }
        statusResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - System audio tooltip

    private func scheduleSystemAudioTooltip() {
        systemAudioTooltipShowWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.showSystemAudioTooltip()
        }
        systemAudioTooltipShowWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func showSystemAudioTooltip() {
        guard let anchor = systemAudioHoverTarget,
              let host = window?.contentView else { return }
        let granted = AccessibilityChecker.isScreenRecordingGranted
        let message = granted
            ? "Capture system audio"
            : "Screen Recording permission required.\nEnable BrainCache in System Settings."

        if systemAudioTooltip == nil {
            let bubble = TooltipBubble()
            bubble.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(bubble, positioned: .above, relativeTo: nil)
            systemAudioTooltip = bubble
        }
        guard let bubble = systemAudioTooltip else { return }
        bubble.message = message
        bubble.isHidden = false

        bubble.removeAllConstraints()
        let centerX = bubble.centerXAnchor.constraint(equalTo: anchor.centerXAnchor)
        centerX.priority = .defaultHigh
        let bottom = bubble.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -6)
        let leading = bubble.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 8)
        let trailing = bubble.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([centerX, bottom, leading, trailing])
        bubble.activeConstraints = [centerX, bottom, leading, trailing]
    }

    private func hideSystemAudioTooltip() {
        systemAudioTooltipShowWorkItem?.cancel()
        systemAudioTooltipShowWorkItem = nil
        systemAudioTooltip?.isHidden = true
    }
}

// MARK: - Hover-tracking helper

/// Transparent NSView that fires `onEnter` / `onExit` when the cursor crosses
/// its bounds. Click-through: returns nil from `hitTest` so underlying controls
/// receive mouse events normally.
final class HoverTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// Small dark-background tooltip bubble — used in place of system tooltips
/// because NSWindow tooltips don't fire reliably on `.nonactivatingPanel`.
final class TooltipBubble: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    var activeConstraints: [NSLayoutConstraint] = []

    var message: String = "" {
        didSet {
            label.stringValue = message
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.95).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = 0.5
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 240
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    func removeAllConstraints() {
        for c in activeConstraints {
            c.isActive = false
        }
        activeConstraints.removeAll()
    }
}

extension Notification.Name {
    static let voiceRecordingStateDidChange = Notification.Name("com.clipvault.voiceRecordingStateDidChange")
    static let voiceRecordingPanelVisibilityDidChange = Notification.Name("com.clipvault.voiceRecordingPanelVisibilityDidChange")
}

/// NSTextView used inside the Custom Question popover. Translates plain
/// Return into "submit" and Esc into "cancel" so the user can fire without
/// reaching for the buttons. Shift+Return / Option+Return inserts a newline
/// the normal way for multi-line questions.
final class CustomPromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / numpad Enter
        let isEsc = event.keyCode == 53
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasShift = modifiers.contains(.shift)
        let hasOption = modifiers.contains(.option)

        if isReturn && !hasShift && !hasOption {
            onSubmit?()
            return
        }
        if isEsc {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Borderless button with a rounded filled background — used for the primary
/// Stop action so it stands out against the dark bottom bar.
final class PillButton: NSButton {
    var fillColor: NSColor = .systemRed { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 6 { didSet { needsDisplay = true } }
    /// Extra horizontal padding added to the intrinsic size so the title has
    /// breathing room inside the pill — NSButton's default chrome insets are
    /// far too tight for our small font.
    var horizontalPadding: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding * 2
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let color = isHighlighted ? fillColor.blended(withFraction: 0.2, of: .black) ?? fillColor : fillColor
        color.setFill()
        path.fill()
        super.draw(dirtyRect)
    }
}

/// View that absorbs mouseDown events and reports them via `onClick`. Used
/// as the AI Assist drawer header so the entire strip (not just the small
/// chevron button) toggles the drawer when clicked.
///
/// `acceptsFirstMouse` returns true so the click registers even when the
/// nonactivating voice panel isn't already key — otherwise the first click
/// would be eaten just bringing the window forward.
///
/// `hitTest` returns `self` whenever the point falls inside the view's
/// bounds. The chevron / label subviews are decorative `NSImageView` /
/// `NSTextField` instances which (despite the prior comment claiming
/// otherwise) DO return themselves from `hitTest` and would otherwise
/// swallow clicks landing on top of them — leaving only the small bare
/// strip between them clickable. Forcing the parent to win means the
/// entire header strip is a reliable click target.
final class ClickThroughView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The voice panel has `isMovableByWindowBackground = true`. AppKit's
    /// default for a plain NSView is `mouseDownCanMoveWindow = true`, which
    /// means a click on this view would start dragging the whole window
    /// instead of dispatching `mouseDown` — silently breaking the drawer
    /// toggle. Built-in controls (NSButton, NSTextField, NSImageView)
    /// already return `false`, which is why nothing else in the panel had
    /// this problem.
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space; translate before
        // bounds-checking.
        guard let parent = superview else { return nil }
        let local = convert(point, from: parent)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Borderless NSButton used as the AI Assist drawer's "Show / Hide AI
/// Response" toggle. Subclassed so we can override `hitTest` to make the
/// entire button win against its decorative chevron / label subviews —
/// otherwise the inner NSImageView / NSTextField intercept the click and
/// the button's action never fires. NSButton itself is what makes this
/// click reliable on a `.nonactivatingPanel` with
/// `isMovableByWindowBackground = true`; plain NSView subclasses don't
/// survive the AppKit hit-test / window-drag interaction the same way.
final class DrawerToggleButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return nil }
        let local = convert(point, from: parent)
        return bounds.contains(local) ? self : nil
    }
}

/// 6pt-tall handle at the top of the AI Assist drawer. The actual drag is
/// driven by an external `NSPanGestureRecognizer`; this view just provides
/// the cursor change on hover and renders the visual affordance.
final class DrawerResizeGripView: NSView {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeUpDown.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let tickWidth: CGFloat = 28
        let tickHeight: CGFloat = 2
        let centerX = bounds.midX
        let centerY = bounds.midY
        let rect = NSRect(
            x: centerX - tickWidth / 2,
            y: centerY - tickHeight / 2,
            width: tickWidth,
            height: tickHeight
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1)
        NSColor.white.withAlphaComponent(0.35).setFill()
        path.fill()
    }
}
