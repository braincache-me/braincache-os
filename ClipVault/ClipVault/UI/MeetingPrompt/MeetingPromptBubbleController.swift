import AppKit

/// The small bubble that drops down from the BrainCache menu bar icon when a
/// meeting is detected: "Are you in a meeting? Record and transcribe it?"
/// with a primary Record button and a Not-now button that snoozes detection.
/// Non-activating so it never steals focus from the call.
final class MeetingPromptBubbleController {

    static let shared = MeetingPromptBubbleController()

    /// What the bubble is currently asking.
    enum Mode {
        /// A meeting was detected: offer to record it.
        case meetingDetected
        /// The meeting ended but the recording is still running with the
        /// panel hidden: offer to stop.
        case stopSuggestion
        /// The window attached to a "Save recording" session was closed:
        /// the video file was finalised, transcription continues — offer
        /// to stop.
        case mediaSourceLost
    }

    /// Returns the status item button the bubble anchors to.
    var anchorProvider: (() -> NSStatusBarButton?)?
    /// "Record" pressed (meeting-detected mode).
    var onRecord: (() -> Void)?
    /// "Not now" pressed (meeting-detected mode).
    var onDismiss: (() -> Void)?
    /// "Stop & Save" pressed (stop-suggestion mode).
    var onStopRecording: (() -> Void)?

    private var panel: NSPanel?
    private var messageLabel: NSTextField?
    private var primaryButton: NSButton?
    private var secondaryButton: NSButton?
    private var autoDismissWorkItem: DispatchWorkItem?
    private(set) var mode: Mode = .meetingDetected

    private static let bubbleWidth: CGFloat = 264

    // MARK: - Show / hide

    func show(platformName: String?) {
        if panel == nil { buildPanel() }
        guard let messageLabel else { return }

        mode = .meetingDetected
        if let platformName {
            messageLabel.stringValue =
                "Looks like a \(platformName) meeting. Record and transcribe it?"
        } else {
            messageLabel.stringValue =
                "Are you in a meeting? Record and transcribe it?"
        }
        primaryButton?.title = "Record"
        secondaryButton?.title = "Not now"
        present()
    }

    /// The meeting ended but BrainCache is still recording in the background
    /// (panel hidden): drop the bubble again, this time offering to stop.
    func showStopSuggestion() {
        if panel == nil { buildPanel() }
        guard let messageLabel else { return }

        mode = .stopSuggestion
        messageLabel.stringValue =
            "Looks like the meeting ended. Stop and save the recording?"
        primaryButton?.title = "Stop & Save"
        secondaryButton?.title = "Keep going"
        present()
    }

    /// The window being recorded to a video file disappeared. The file is
    /// already finalised; the transcript is still live. Same buttons as the
    /// stop suggestion so the user can wrap the whole session up in one click.
    func showMediaSourceLost(appName: String, saved: Bool) {
        if panel == nil { buildPanel() }
        guard let messageLabel else { return }

        mode = .mediaSourceLost
        messageLabel.stringValue = MeetingPromptPolicy.mediaSourceLostMessage(
            appName: appName, saved: saved
        )
        primaryButton?.title = "Stop & Save"
        secondaryButton?.title = "Keep going"
        present()
    }

    private func present() {
        guard let panel else { return }
        panel.layoutIfNeeded()
        if let container = panel.contentView {
            let size = container.fittingSize
            if size != .zero { panel.setContentSize(size) }
        }

        position(panel)
        // No fade-in: window-alpha animators are unreliable for freshly
        // ordered-in non-activating panels (the animation can silently never
        // fire, leaving the panel at alpha 0). Visibility beats polish here.
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        scheduleAutoDismiss()
    }

    func hide() {
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func scheduleAutoDismiss() {
        autoDismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        autoDismissWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + MeetingPromptPolicy.bubbleAutoDismissSeconds, execute: item
        )
    }

    /// Center the bubble under the status item; fall back to the top-right
    /// corner of the main screen when the button is unavailable or not
    /// actually visible (crowded menu bar on a small screen, or the item
    /// parked under a MacBook notch) — anchoring to a hidden button would put
    /// the bubble off-screen where the user never sees the offer.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let button = anchorProvider?(),
           let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let buttonFrame = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            var auxLeft: NSRect?
            var auxRight: NSRect?
            if #available(macOS 12.0, *) {
                auxLeft = screen.auxiliaryTopLeftArea
                auxRight = screen.auxiliaryTopRightArea
            }
            if Self.anchorIsVisible(
                buttonFrame: buttonFrame,
                screenFrame: screen.frame,
                auxiliaryTopLeftArea: auxLeft,
                auxiliaryTopRightArea: auxRight,
                windowOcclusionVisible: buttonWindow.occlusionState.contains(.visible)
            ) {
                var x = buttonFrame.midX - size.width / 2
                let y = buttonFrame.minY - size.height - 6
                let limit = screen.visibleFrame
                x = min(max(x, limit.minX + 8), limit.maxX - size.width - 8)
                panel.setFrameOrigin(NSPoint(x: x, y: y))
                return
            }
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.maxX - size.width - 16,
                y: frame.maxY - size.height - 8
            ))
        }
    }

    /// Whether the status-item button is genuinely on screen. Pure so it is
    /// unit-testable. A status item squeezed out of a full menu bar keeps its
    /// window, but macOS either marks it non-visible (occlusion) or parks it
    /// in the notch gap between the two auxiliary top areas.
    static func anchorIsVisible(
        buttonFrame: NSRect,
        screenFrame: NSRect,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?,
        windowOcclusionVisible: Bool
    ) -> Bool {
        guard windowOcclusionVisible else { return false }
        guard buttonFrame.width > 0, screenFrame.intersects(buttonFrame) else { return false }
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea,
           buttonFrame.midY >= left.minY {
            // Notched screen and the button sits at menu bar height: it must
            // fall inside one of the two visible menu bar strips.
            let inLeft = buttonFrame.midX >= left.minX && buttonFrame.midX <= left.maxX
            let inRight = buttonFrame.midX >= right.minX && buttonFrame.midX <= right.maxX
            return inLeft || inRight
        }
        return true
    }

    // MARK: - Panel construction

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.bubbleWidth, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        let message = NSTextField(wrappingLabelWithString: "")
        message.font = .systemFont(ofSize: 12.5)
        message.textColor = .labelColor
        message.alignment = .left
        message.translatesAutoresizingMaskIntoConstraints = false
        message.setContentCompressionResistancePriority(.required, for: .vertical)

        let recordButton = NSButton(
            title: "Record", target: self, action: #selector(recordPressed)
        )
        recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "\r"
        recordButton.controlSize = .regular
        recordButton.translatesAutoresizingMaskIntoConstraints = false

        let dismissButton = NSButton(
            title: "Not now", target: self, action: #selector(dismissPressed)
        )
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .regular
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(message)
        effectView.addSubview(recordButton)
        effectView.addSubview(dismissButton)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            message.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 12),
            message.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 14),
            message.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -14),

            recordButton.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 10),
            recordButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            recordButton.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -10),

            dismissButton.centerYAnchor.constraint(equalTo: recordButton.centerYAnchor),
            dismissButton.trailingAnchor.constraint(equalTo: recordButton.leadingAnchor, constant: -8),

            container.widthAnchor.constraint(equalToConstant: Self.bubbleWidth),
        ])

        panel.contentView = container
        panel.setContentSize(
            container.fittingSize == .zero
                ? NSSize(width: Self.bubbleWidth, height: 96)
                : container.fittingSize
        )

        self.panel = panel
        self.messageLabel = message
        self.primaryButton = recordButton
        self.secondaryButton = dismissButton
    }

    // MARK: - Actions

    @objc private func recordPressed() {
        hide()
        switch mode {
        case .meetingDetected: onRecord?()
        case .stopSuggestion, .mediaSourceLost: onStopRecording?()
        }
    }

    @objc private func dismissPressed() {
        hide()
        switch mode {
        case .meetingDetected: onDismiss?()
        case .stopSuggestion, .mediaSourceLost: break
        }
    }
}
