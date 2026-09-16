import AppKit
import ApplicationServices
import AVFoundation

private enum PermissionStatus {
    case granted
    case notGranted
    case needsReview
}

final class PermissionsPrefsView: NSView {

    private static var didInitiateScreenRecordingFlowThisLaunch = false
    private static var didInitiateAccessibilityFlowThisLaunch = false
    private static var didInitiateMicrophoneFlowThisLaunch = false

    private var permissionRows: [PermissionRow] = []
    private var refreshTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.clipvault.permissions-timer", qos: .utility)
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "")
    private let relaunchButton = NSButton(title: "Quit & Reopen BrainCache", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        refreshAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        stopMonitoring()
    }

    // MARK: - Monitoring

    func startMonitoring() {
        stopMonitoring()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.refreshAll() }
        }
        timer.resume()
        refreshTimer = timer
    }

    func stopMonitoring() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Build UI

    private func buildUI() {
        let headerLabel = NSTextField(labelWithString: "BrainCache needs these permissions to work properly.")
        headerLabel.font = .systemFont(ofSize: 13)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        let accessibilityRow = PermissionRow(
            title: "Accessibility",
            explanation: "Required to paste clips into other apps via simulated keystrokes, and to inspect UI element names and roles when Activity Capture is enabled.",
            statusProvider: {
                PermissionsPrefsView.accessibilityStatus()
            },
            openAction: { [weak self] in
                PermissionsPrefsView.didInitiateAccessibilityFlowThisLaunch = true
                _ = AccessibilityChecker.openAccessibilitySettings()
                self?.refreshAll()
            }
        )

        let microphoneRow = PermissionRow(
            title: "Microphone",
            explanation: "Required for voice transcription (⌥Space). The first click shows the macOS permission dialog; on subsequent denials it opens System Settings → Privacy & Security → Microphone so you can re-enable BrainCache manually.",
            statusProvider: {
                PermissionsPrefsView.microphoneStatus()
            },
            openAction: { [weak self] in
                let status = AccessibilityChecker.microphoneAuthorizationStatus
                switch status {
                case .authorized:
                    _ = AccessibilityChecker.openMicrophoneSettings()
                case .notDetermined:
                    AccessibilityChecker.requestMicrophoneAccess { _ in
                        DispatchQueue.main.async { self?.refreshAll() }
                    }
                default:
                    PermissionsPrefsView.didInitiateMicrophoneFlowThisLaunch = true
                    _ = AccessibilityChecker.openMicrophoneSettings()
                }
                self?.refreshAll()
            }
        )

        let screenRecordingRow = PermissionRow(
            title: "Screen Recording (optional)",
            explanation: "Required for Activity Capture screenshots and for capturing System audio alongside the mic during voice transcription. Click to open Settings, then add BrainCache with the + button. A relaunch is required afterward.",
            statusProvider: {
                PermissionsPrefsView.screenRecordingStatus()
            },
            openAction: { [weak self] in
                if !AccessibilityChecker.isScreenRecordingGranted {
                    PermissionsPrefsView.didInitiateScreenRecordingFlowThisLaunch = true
                    _ = AccessibilityChecker.openScreenRecordingSettings()
                } else {
                    _ = AccessibilityChecker.openScreenRecordingSettings()
                }
                self?.refreshAll()
            }
        )

        permissionRows = [accessibilityRow, microphoneRow, screenRecordingRow]

        var constraints: [NSLayoutConstraint] = [
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            separator.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
        ]

        var previousAnchor = separator.bottomAnchor
        for row in permissionRows {
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            constraints.append(contentsOf: [
                row.topAnchor.constraint(equalTo: previousAnchor, constant: 16),
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            ])
            previousAnchor = row.bottomAnchor
        }

        let refreshButton = NSButton(title: "Refresh All", target: self, action: #selector(refreshTapped))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(refreshButton)

        guidanceLabel.font = .systemFont(ofSize: 11)
        guidanceLabel.textColor = .secondaryLabelColor
        guidanceLabel.maximumNumberOfLines = 0
        guidanceLabel.isHidden = true
        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(guidanceLabel)

        relaunchButton.target = self
        relaunchButton.action = #selector(relaunchTapped)
        relaunchButton.bezelStyle = .rounded
        relaunchButton.isHidden = true
        relaunchButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(relaunchButton)

        constraints.append(contentsOf: [
            refreshButton.topAnchor.constraint(equalTo: previousAnchor, constant: 24),
            refreshButton.centerXAnchor.constraint(equalTo: centerXAnchor),

            guidanceLabel.topAnchor.constraint(equalTo: refreshButton.bottomAnchor, constant: 12),
            guidanceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            guidanceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),

            relaunchButton.topAnchor.constraint(equalTo: guidanceLabel.bottomAnchor, constant: 10),
            relaunchButton.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Refresh

    @objc private func refreshTapped() {
        refreshAll()
    }

    @objc private func relaunchTapped() {
        // `NSWorkspace.openApplication` on the currently-running bundle just activates
        // the existing instance — it doesn't spawn a new one — so calling terminate
        // afterwards leaves nothing running. Instead, detach a shell helper that waits
        // for our PID to exit, then launches a fresh instance via `open`.
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(bundlePath)\""

        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Reopen BrainCache"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        NSApp.terminate(nil)
    }

    func refreshAll() {
        for row in permissionRows {
            row.refresh()
        }
        updateGuidance()
    }

    private func updateGuidance() {
        let needsReview = Self.screenRecordingStatus() == .needsReview
            || Self.accessibilityStatus() == .needsReview
            || Self.microphoneStatus() == .needsReview
        guidanceLabel.isHidden = !needsReview
        relaunchButton.isHidden = !needsReview

        if needsReview {
            guidanceLabel.stringValue = "macOS caches permission decisions per-process: after you toggle BrainCache in System Settings, the new status only shows up once you fully quit and reopen the app. \"Refresh All\" cannot pick up the change on its own."
        }
    }

    private static func accessibilityStatus() -> PermissionStatus {
        if AccessibilityChecker.isGranted {
            didInitiateAccessibilityFlowThisLaunch = false
            return .granted
        }
        return didInitiateAccessibilityFlowThisLaunch ? .needsReview : .notGranted
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AccessibilityChecker.microphoneAuthorizationStatus {
        case .authorized:
            didInitiateMicrophoneFlowThisLaunch = false
            return .granted
        case .notDetermined:
            return didInitiateMicrophoneFlowThisLaunch ? .needsReview : .notGranted
        case .denied, .restricted:
            return didInitiateMicrophoneFlowThisLaunch ? .needsReview : .notGranted
        @unknown default:
            return .notGranted
        }
    }

    // MARK: - Screen Recording check

    static func checkScreenRecordingPermission() -> Bool {
        AccessibilityChecker.isScreenRecordingGranted
    }

    private static func screenRecordingStatus() -> PermissionStatus {
        if AccessibilityChecker.isScreenRecordingGranted {
            didInitiateScreenRecordingFlowThisLaunch = false
            return .granted
        }
        return didInitiateScreenRecordingFlowThisLaunch ? .needsReview : .notGranted
    }

    @discardableResult
    static func openScreenRecordingSettings() -> Bool {
        AccessibilityChecker.openScreenRecordingSettings()
    }
}

// MARK: - PermissionRow

private final class PermissionRow: NSView {

    private let statusIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    private let statusProvider: () -> PermissionStatus
    private let openAction: () -> Void

    init(title: String, explanation: String, statusProvider: @escaping () -> PermissionStatus, openAction: @escaping () -> Void) {
        self.statusProvider = statusProvider
        self.openAction = openAction
        super.init(frame: .zero)

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 13)

        explanationLabel.stringValue = explanation
        explanationLabel.font = .systemFont(ofSize: 11)
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.maximumNumberOfLines = 2
        explanationLabel.preferredMaxLayoutWidth = 340

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(openSettings)

        statusIcon.imageScaling = .scaleProportionallyDown

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)

        let views: [NSView] = [statusIcon, titleLabel, explanationLabel, actionButton, statusLabel]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            statusIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusIcon.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            statusIcon.widthAnchor.constraint(equalToConstant: 20),
            statusIcon.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: statusIcon.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            explanationLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            explanationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            explanationLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            actionButton.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 6),
            actionButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            bottomAnchor.constraint(equalTo: actionButton.bottomAnchor, constant: 4),
        ])

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    @objc private func openSettings() {
        openAction()
    }

    func refresh() {
        switch statusProvider() {
        case .granted:
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            statusIcon.contentTintColor = .systemGreen
            statusLabel.stringValue = "Granted"
            statusLabel.textColor = .systemGreen
            actionButton.title = "Open Settings"
        case .notGranted:
            statusIcon.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Not Granted")
            statusIcon.contentTintColor = .systemRed
            statusLabel.stringValue = "Not Granted"
            statusLabel.textColor = .systemRed
            actionButton.title = "Grant Permission…"
        case .needsReview:
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Needs Review")
            statusIcon.contentTintColor = .systemOrange
            statusLabel.stringValue = "Check Settings"
            statusLabel.textColor = .systemOrange
            actionButton.title = "Open Settings"
        }
    }
}
