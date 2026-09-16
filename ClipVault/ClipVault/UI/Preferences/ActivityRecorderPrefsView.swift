import AppKit

final class ActivityRecorderPrefsView: NSView {

    // MARK: - Scroll infrastructure

    private let scrollView = NSScrollView()
    private let contentView = FlippedPrefsContentView()

    // MARK: - Intro + master toggle

    private let introLabel = NSTextField(wrappingLabelWithString:
        "Passively logs UI interactions to dated files in a folder you choose. All data stays local on this Mac.")
    private let captureSwitch = NSSwitch()
    private let captureTitleLabel = NSTextField(labelWithString: "Enable Activity Capture")
    private let captureStatusLabel = NSTextField(labelWithString: "Inactive")

    // MARK: - AX permission warning

    private let warningBox = NSView()
    private let warningIcon = NSImageView()
    private let warningLabel = NSTextField(wrappingLabelWithString:
        "Accessibility permission is required to read UI element names and roles.")
    private let openSystemSettingsButton = NSButton(title: "Open System Settings\u{2026}", target: nil, action: nil)

    // MARK: - Top stack (intro + toggle + optional warning)

    private let topStack = NSStackView()
    private let captureRow = NSView()

    // MARK: - Screenshots

    private let screenshotsHeaderLabel = NSTextField(labelWithString: "Screenshots")
    private let screenshotsSwitch = NSSwitch()
    private let jpegQualityLabel = NSTextField(labelWithString: "JPEG Quality")
    private let jpegQualitySlider = NSSlider()
    private let jpegQualityValueLabel = NSTextField(labelWithString: "70%")
    private let scaleLabel = NSTextField(labelWithString: "Scale")
    private let scalePopup = NSPopUpButton()
    private let fallbackLabel = NSTextField(labelWithString: "Periodic Fallback")
    private let fallbackIntervalPopup = NSPopUpButton()
    private let idleLabel = NSTextField(labelWithString: "Idle Threshold")
    private let idleThresholdPopup = NSPopUpButton()

    // MARK: - Meeting audio / transcript

    private let meetingHeaderLabel = NSTextField(labelWithString: "Meeting Recording")
    private let meetingModeLabel = NSTextField(labelWithString: "When mic activates")
    private let meetingModeSegmented = NSSegmentedControl(
        labels: ["Off", "Audio", "Transcript"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let meetingHintLabel = NSTextField(wrappingLabelWithString:
        "Off: ignore meeting mic activity.  Audio: save mic + system to an .m4a.  " +
        "Transcript: stream mic + system to OpenAI and save the text.  " +
        "Recording starts when another app opens the mic and stops once it's released " +
        "for the delay below.")
    private let meetingSilenceLabel = NSTextField(labelWithString: "Stop after mic released")
    private let meetingSilenceStepper = NSStepper()
    private let meetingSilenceValueLabel = NSTextField(labelWithString: "45 sec")

    // MARK: - Storage

    private let storageHeaderLabel = NSTextField(labelWithString: "Storage")
    private let retentionLabel = NSTextField(labelWithString: "Auto-cleanup")
    private let retentionPopup = NSPopUpButton()
    private let logFolderLabel = NSTextField(labelWithString: "Log Folder")
    private let logFolderPathLabel = NSTextField(labelWithString: "Not configured")
    private let changeFolderButton = NSButton(title: "Change\u{2026}", target: nil, action: nil)
    private let openLogsFolderButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)

    // MARK: - Privacy

    private let privacyHeaderLabel = NSTextField(labelWithString: "Privacy")
    private let privacyDescLabel = NSTextField(wrappingLabelWithString:
        "Block specific apps from ever being recorded. Useful for password managers, banking apps, or anything sensitive.")
    private let manageExclusionsButton = NSButton(title: "Manage Exclusions\u{2026}", target: nil, action: nil)

    // MARK: - State

    private var notificationObservers: [NSObjectProtocol] = []

    // popup value tables (index ↔ Settings value)
    static let fallbackIntervalValues = [0, 30, 60, 120, 300]
    static let idleThresholdValues = [0, 15, 30, 60]
    static let retentionValues = [0, 30, 60, 90]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        loadValues()
        subscribeToNotifications()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Build UI

    private func buildUI() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        configureControls()
        layoutContent()
    }

    private func configureControls() {
        // Intro
        introLabel.font = .systemFont(ofSize: 12)
        introLabel.textColor = .secondaryLabelColor
        introLabel.maximumNumberOfLines = 0

        // Master toggle
        captureTitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        captureSwitch.target = self
        captureSwitch.action = #selector(captureEnabledToggled(_:))

        captureStatusLabel.font = .systemFont(ofSize: 11)
        captureStatusLabel.textColor = .secondaryLabelColor

        // Permission warning (layer-backed rounded panel)
        warningBox.wantsLayer = true
        warningBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        warningBox.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        warningBox.layer?.borderWidth = 1
        warningBox.layer?.cornerRadius = 8

        warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        warningIcon.contentTintColor = .systemOrange
        warningIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .labelColor
        warningLabel.maximumNumberOfLines = 0

        openSystemSettingsButton.target = self
        openSystemSettingsButton.action = #selector(openSystemSettingsTapped)
        openSystemSettingsButton.bezelStyle = .rounded
        openSystemSettingsButton.controlSize = .small

        // Section headers
        for header in [screenshotsHeaderLabel, meetingHeaderLabel, storageHeaderLabel, privacyHeaderLabel] {
            header.font = .systemFont(ofSize: 13, weight: .semibold)
        }

        // Field labels — share consistent style
        for label in [jpegQualityLabel, scaleLabel, fallbackLabel, idleLabel,
                      meetingModeLabel, meetingSilenceLabel,
                      retentionLabel, logFolderLabel] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .labelColor
            label.alignment = .right
        }

        // Meeting recording
        meetingModeSegmented.target = self
        meetingModeSegmented.action = #selector(meetingModeChanged(_:))
        meetingHintLabel.font = .systemFont(ofSize: 11)
        meetingHintLabel.textColor = .secondaryLabelColor
        meetingHintLabel.maximumNumberOfLines = 0

        meetingSilenceStepper.minValue = 5
        meetingSilenceStepper.maxValue = 300
        meetingSilenceStepper.increment = 5
        meetingSilenceStepper.valueWraps = false
        meetingSilenceStepper.target = self
        meetingSilenceStepper.action = #selector(meetingSilenceChanged(_:))
        meetingSilenceValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        meetingSilenceValueLabel.textColor = .secondaryLabelColor
        meetingSilenceValueLabel.alignment = .left

        // Screenshots
        screenshotsSwitch.target = self
        screenshotsSwitch.action = #selector(screenshotsToggled(_:))

        jpegQualitySlider.minValue = 0.3
        jpegQualitySlider.maxValue = 1.0
        jpegQualitySlider.target = self
        jpegQualitySlider.action = #selector(jpegQualityChanged(_:))

        jpegQualityValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        jpegQualityValueLabel.textColor = .secondaryLabelColor
        jpegQualityValueLabel.alignment = .left

        scalePopup.addItems(withTitles: ["1\u{00D7}", "2\u{00D7}"])
        scalePopup.target = self
        scalePopup.action = #selector(scaleChanged(_:))

        fallbackIntervalPopup.addItems(withTitles: ["Never", "30 sec", "1 min", "2 min", "5 min"])
        fallbackIntervalPopup.target = self
        fallbackIntervalPopup.action = #selector(fallbackIntervalChanged(_:))

        idleThresholdPopup.addItems(withTitles: ["Never", "15 sec", "30 sec", "60 sec"])
        idleThresholdPopup.target = self
        idleThresholdPopup.action = #selector(idleThresholdChanged(_:))

        // Storage
        retentionPopup.addItems(withTitles: ["Never", "30 days", "60 days", "90 days"])
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged(_:))

        logFolderPathLabel.font = .systemFont(ofSize: 12)
        logFolderPathLabel.textColor = .secondaryLabelColor
        logFolderPathLabel.lineBreakMode = .byTruncatingMiddle
        logFolderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        changeFolderButton.target = self
        changeFolderButton.action = #selector(changeFolderTapped)
        changeFolderButton.controlSize = .small
        changeFolderButton.bezelStyle = .rounded

        openLogsFolderButton.target = self
        openLogsFolderButton.action = #selector(openLogsFolderTapped)
        openLogsFolderButton.controlSize = .small
        openLogsFolderButton.bezelStyle = .rounded

        // Privacy
        privacyDescLabel.font = .systemFont(ofSize: 12)
        privacyDescLabel.textColor = .secondaryLabelColor
        privacyDescLabel.maximumNumberOfLines = 0

        manageExclusionsButton.target = self
        manageExclusionsButton.action = #selector(manageExclusionsTapped)
        manageExclusionsButton.bezelStyle = .rounded
    }

    private func layoutContent() {
        let margin: CGFloat = 24
        let labelColumnWidth: CGFloat = 140
        let groupSpacing: CGFloat = 24

        // Master-toggle row: title + status on left, switch on right
        captureRow.translatesAutoresizingMaskIntoConstraints = false
        [captureTitleLabel, captureStatusLabel, captureSwitch].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            captureRow.addSubview($0)
        }
        NSLayoutConstraint.activate([
            captureTitleLabel.leadingAnchor.constraint(equalTo: captureRow.leadingAnchor),
            captureTitleLabel.centerYAnchor.constraint(equalTo: captureRow.centerYAnchor),

            captureStatusLabel.leadingAnchor.constraint(equalTo: captureTitleLabel.trailingAnchor, constant: 8),
            captureStatusLabel.centerYAnchor.constraint(equalTo: captureRow.centerYAnchor),

            captureSwitch.trailingAnchor.constraint(equalTo: captureRow.trailingAnchor),
            captureSwitch.centerYAnchor.constraint(equalTo: captureRow.centerYAnchor),
            captureRow.heightAnchor.constraint(greaterThanOrEqualTo: captureSwitch.heightAnchor),
        ])

        // Warning box: icon + label + button
        [warningIcon, warningLabel, openSystemSettingsButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            warningBox.addSubview($0)
        }
        NSLayoutConstraint.activate([
            warningIcon.topAnchor.constraint(equalTo: warningBox.topAnchor, constant: 10),
            warningIcon.leadingAnchor.constraint(equalTo: warningBox.leadingAnchor, constant: 12),
            warningIcon.widthAnchor.constraint(equalToConstant: 18),
            warningIcon.heightAnchor.constraint(equalToConstant: 18),

            warningLabel.topAnchor.constraint(equalTo: warningBox.topAnchor, constant: 10),
            warningLabel.leadingAnchor.constraint(equalTo: warningIcon.trailingAnchor, constant: 8),
            warningLabel.trailingAnchor.constraint(equalTo: warningBox.trailingAnchor, constant: -12),

            openSystemSettingsButton.topAnchor.constraint(equalTo: warningLabel.bottomAnchor, constant: 8),
            openSystemSettingsButton.leadingAnchor.constraint(equalTo: warningLabel.leadingAnchor),
            openSystemSettingsButton.bottomAnchor.constraint(equalTo: warningBox.bottomAnchor, constant: -10),
        ])

        // Top stack lets the warning row collapse when hidden so the gap to
        // the next section closes automatically.
        topStack.orientation = .vertical
        topStack.alignment = .leading
        topStack.distribution = .fill
        topStack.spacing = 14
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.addArrangedSubview(introLabel)
        topStack.addArrangedSubview(captureRow)
        topStack.addArrangedSubview(warningBox)
        contentView.addSubview(topStack)

        // Force inner rows to fill the stack width
        NSLayoutConstraint.activate([
            captureRow.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            warningBox.widthAnchor.constraint(equalTo: topStack.widthAnchor),
            introLabel.widthAnchor.constraint(equalTo: topStack.widthAnchor),
        ])

        // All other views
        let allViews: [NSView] = [
            screenshotsHeaderLabel, screenshotsSwitch,
            jpegQualityLabel, jpegQualitySlider, jpegQualityValueLabel,
            scaleLabel, scalePopup,
            fallbackLabel, fallbackIntervalPopup,
            idleLabel, idleThresholdPopup,
            meetingHeaderLabel,
            meetingModeLabel, meetingModeSegmented,
            meetingHintLabel,
            meetingSilenceLabel, meetingSilenceStepper, meetingSilenceValueLabel,
            storageHeaderLabel,
            retentionLabel, retentionPopup,
            logFolderLabel, logFolderPathLabel, changeFolderButton, openLogsFolderButton,
            privacyHeaderLabel, privacyDescLabel, manageExclusionsButton,
        ]
        allViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        // Field-column origin (where controls start)
        let fieldX = margin + labelColumnWidth + 12

        NSLayoutConstraint.activate([
            // MARK: Top stack
            topStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            topStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            topStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // MARK: Screenshots section header (toggle on the right)
            screenshotsHeaderLabel.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: groupSpacing),
            screenshotsHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            screenshotsSwitch.centerYAnchor.constraint(equalTo: screenshotsHeaderLabel.centerYAnchor),
            screenshotsSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // JPEG Quality
            jpegQualityLabel.topAnchor.constraint(equalTo: screenshotsHeaderLabel.bottomAnchor, constant: 14),
            jpegQualityLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            jpegQualityLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            jpegQualitySlider.centerYAnchor.constraint(equalTo: jpegQualityLabel.centerYAnchor),
            jpegQualitySlider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),
            jpegQualitySlider.widthAnchor.constraint(equalToConstant: 160),

            jpegQualityValueLabel.centerYAnchor.constraint(equalTo: jpegQualityLabel.centerYAnchor),
            jpegQualityValueLabel.leadingAnchor.constraint(equalTo: jpegQualitySlider.trailingAnchor, constant: 8),

            // Scale
            scaleLabel.topAnchor.constraint(equalTo: jpegQualityLabel.bottomAnchor, constant: 12),
            scaleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            scaleLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            scalePopup.centerYAnchor.constraint(equalTo: scaleLabel.centerYAnchor),
            scalePopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            // Fallback
            fallbackLabel.topAnchor.constraint(equalTo: scaleLabel.bottomAnchor, constant: 12),
            fallbackLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            fallbackLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            fallbackIntervalPopup.centerYAnchor.constraint(equalTo: fallbackLabel.centerYAnchor),
            fallbackIntervalPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            // Idle
            idleLabel.topAnchor.constraint(equalTo: fallbackLabel.bottomAnchor, constant: 12),
            idleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            idleLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            idleThresholdPopup.centerYAnchor.constraint(equalTo: idleLabel.centerYAnchor),
            idleThresholdPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            // MARK: Meeting Recording section
            meetingHeaderLabel.topAnchor.constraint(equalTo: idleLabel.bottomAnchor, constant: groupSpacing),
            meetingHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            meetingModeLabel.topAnchor.constraint(equalTo: meetingHeaderLabel.bottomAnchor, constant: 14),
            meetingModeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            meetingModeLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            meetingModeSegmented.centerYAnchor.constraint(equalTo: meetingModeLabel.centerYAnchor),
            meetingModeSegmented.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            meetingHintLabel.topAnchor.constraint(equalTo: meetingModeSegmented.bottomAnchor, constant: 6),
            meetingHintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),
            meetingHintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            meetingSilenceLabel.topAnchor.constraint(equalTo: meetingHintLabel.bottomAnchor, constant: 12),
            meetingSilenceLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            meetingSilenceLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            meetingSilenceStepper.centerYAnchor.constraint(equalTo: meetingSilenceLabel.centerYAnchor),
            meetingSilenceStepper.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            meetingSilenceValueLabel.centerYAnchor.constraint(equalTo: meetingSilenceLabel.centerYAnchor),
            meetingSilenceValueLabel.leadingAnchor.constraint(equalTo: meetingSilenceStepper.trailingAnchor, constant: 8),

            // MARK: Storage section
            storageHeaderLabel.topAnchor.constraint(equalTo: meetingSilenceLabel.bottomAnchor, constant: groupSpacing),
            storageHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            retentionLabel.topAnchor.constraint(equalTo: storageHeaderLabel.bottomAnchor, constant: 14),
            retentionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            retentionLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            retentionPopup.centerYAnchor.constraint(equalTo: retentionLabel.centerYAnchor),
            retentionPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),

            // Log folder row: path on label/value line; Change… button on the right
            logFolderLabel.topAnchor.constraint(equalTo: retentionLabel.bottomAnchor, constant: 14),
            logFolderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            logFolderLabel.widthAnchor.constraint(equalToConstant: labelColumnWidth),

            logFolderPathLabel.centerYAnchor.constraint(equalTo: logFolderLabel.centerYAnchor),
            logFolderPathLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: fieldX),
            logFolderPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: changeFolderButton.leadingAnchor, constant: -12),

            changeFolderButton.centerYAnchor.constraint(equalTo: logFolderLabel.centerYAnchor),
            changeFolderButton.trailingAnchor.constraint(equalTo: openLogsFolderButton.leadingAnchor, constant: -8),

            openLogsFolderButton.centerYAnchor.constraint(equalTo: logFolderLabel.centerYAnchor),
            openLogsFolderButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            // MARK: Privacy section
            privacyHeaderLabel.topAnchor.constraint(equalTo: logFolderLabel.bottomAnchor, constant: groupSpacing),
            privacyHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),

            privacyDescLabel.topAnchor.constraint(equalTo: privacyHeaderLabel.bottomAnchor, constant: 6),
            privacyDescLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            privacyDescLabel.trailingAnchor.constraint(lessThanOrEqualTo: manageExclusionsButton.leadingAnchor, constant: -12),

            manageExclusionsButton.centerYAnchor.constraint(equalTo: privacyDescLabel.centerYAnchor),
            manageExclusionsButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            contentView.bottomAnchor.constraint(equalTo: privacyDescLabel.bottomAnchor, constant: margin),
        ])
    }

    // MARK: - Load / Save

    private func loadValues() {
        let s = Settings.shared

        captureSwitch.state = s.activityCaptureEnabled ? .on : .off
        screenshotsSwitch.state = s.activityCaptureScreenshotsEnabled ? .on : .off

        jpegQualitySlider.doubleValue = s.activityCaptureJPEGQuality
        jpegQualityValueLabel.stringValue = jpegQualityString(s.activityCaptureJPEGQuality)

        scalePopup.selectItem(at: s.activityCaptureScale == 2 ? 1 : 0)

        let fbIdx = Self.fallbackIntervalValues.firstIndex(of: s.activityCaptureFallbackIntervalSeconds) ?? 2
        fallbackIntervalPopup.selectItem(at: fbIdx)

        let idleIdx = Self.idleThresholdValues.firstIndex(of: s.activityCaptureIdleThresholdSeconds) ?? 2
        idleThresholdPopup.selectItem(at: idleIdx)

        let retIdx = Self.retentionValues.firstIndex(of: s.activityCaptureRetentionDays) ?? 0
        retentionPopup.selectItem(at: retIdx)

        loadMeetingModeSelection()
        meetingSilenceStepper.integerValue = s.activityCaptureMicReleaseDelay
        meetingSilenceValueLabel.stringValue = "\(s.activityCaptureMicReleaseDelay) sec"

        updateLogFolderPath()
        updatePermissionWarning()
        updateCaptureStatusLabel()
        updateCaptureControlsState()
    }

    private func loadMeetingModeSelection() {
        switch Settings.shared.activityCaptureAudioMode {
        case .off: meetingModeSegmented.selectedSegment = 0
        case .audio: meetingModeSegmented.selectedSegment = 1
        case .transcript: meetingModeSegmented.selectedSegment = 2
        }
    }

    private func subscribeToNotifications() {
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(
            forName: .activityCaptureEnabledDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleCaptureEnabledChange()
        })

        notificationObservers.append(center.addObserver(
            forName: .activityCapturePausedDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCaptureStatusLabel()
        })

        notificationObservers.append(center.addObserver(
            forName: .activityCaptureLogRootDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateLogFolderPath()
            self?.updateCaptureControlsState()
        })
    }

    // MARK: - State refresh helpers

    private func handleCaptureEnabledChange() {
        captureSwitch.state = Settings.shared.activityCaptureEnabled ? .on : .off
        updateCaptureStatusLabel()
        updatePermissionWarning()
        updateCaptureControlsState()
    }

    func refreshPermissionStatus() {
        updatePermissionWarning()
        updateCaptureControlsState()
    }

    private func updateCaptureStatusLabel() {
        let enabled = Settings.shared.activityCaptureEnabled
        let paused = Settings.shared.activityCapturePaused
        if enabled && !paused {
            captureStatusLabel.stringValue = "• Recording"
            captureStatusLabel.textColor = .systemGreen
        } else if enabled && paused {
            captureStatusLabel.stringValue = "• Paused"
            captureStatusLabel.textColor = .systemOrange
        } else {
            captureStatusLabel.stringValue = "• Inactive"
            captureStatusLabel.textColor = .secondaryLabelColor
        }
    }

    private func updatePermissionWarning() {
        let axGranted = AccessibilityChecker.isGranted
        warningBox.isHidden = axGranted
    }

    private func updateCaptureControlsState() {
        let captureOn = Settings.shared.activityCaptureEnabled
        let screenshotsOn = captureOn && Settings.shared.activityCaptureScreenshotsEnabled

        screenshotsSwitch.isEnabled = captureOn
        jpegQualitySlider.isEnabled = screenshotsOn
        jpegQualityValueLabel.textColor = screenshotsOn ? .secondaryLabelColor : .tertiaryLabelColor
        scalePopup.isEnabled = screenshotsOn
        fallbackIntervalPopup.isEnabled = screenshotsOn
        idleThresholdPopup.isEnabled = screenshotsOn

        retentionPopup.isEnabled = captureOn
        openLogsFolderButton.isEnabled = Settings.shared.activityCaptureLogRootBookmark != nil
        manageExclusionsButton.isEnabled = captureOn

        meetingModeSegmented.isEnabled = captureOn
        let meetingOn = captureOn && Settings.shared.activityCaptureAudioMode != .off
        meetingSilenceStepper.isEnabled = meetingOn
        meetingSilenceValueLabel.textColor = meetingOn ? .secondaryLabelColor : .tertiaryLabelColor
    }

    private func updateLogFolderPath() {
        guard let bookmarkData = Settings.shared.activityCaptureLogRootBookmark else {
            logFolderPathLabel.stringValue = "Not configured"
            return
        }
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var path = url.path + "/logs"
            if path.hasPrefix(home) {
                path = "~" + path.dropFirst(home.count)
            }
            logFolderPathLabel.stringValue = path
        } else {
            logFolderPathLabel.stringValue = "Not configured"
        }
    }

    private func jpegQualityString(_ quality: Double) -> String {
        "\(Int(quality * 100))%"
    }

    // MARK: - Actions

    @objc private func captureEnabledToggled(_ sender: NSSwitch) {
        if sender.state == .on {
            guard AccessibilityChecker.isGranted else {
                sender.state = .off
                AccessibilityChecker.requestAccess()
                updatePermissionWarning()
                return
            }
            if Settings.shared.activityCaptureLogRootBookmark == nil {
                let tempAccess = ActivityCaptureFolderAccess()
                do {
                    try tempAccess.promptUserToChooseFolder(relativeTo: window)
                } catch ActivityCaptureFolderAccess.AccessError.userCancelled {
                    sender.state = .off
                    return
                } catch {
                    sender.state = .off
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Could Not Open Folder"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
            }
            Settings.shared.activityCaptureEnabled = true
            NotificationCenter.default.post(name: .activityCaptureEnabledDidChange, object: nil)
        } else {
            Settings.shared.activityCaptureEnabled = false
            Settings.shared.activityCapturePaused = false
            NotificationCenter.default.post(name: .activityCaptureEnabledDidChange, object: nil)
        }
        updateCaptureStatusLabel()
        updateCaptureControlsState()
        updateLogFolderPath()
    }

    @objc private func openSystemSettingsTapped() {
        AccessibilityChecker.openAccessibilitySettings()
    }

    @objc private func screenshotsToggled(_ sender: NSSwitch) {
        Settings.shared.activityCaptureScreenshotsEnabled = sender.state == .on
        updateCaptureControlsState()
    }

    @objc private func jpegQualityChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        Settings.shared.activityCaptureJPEGQuality = value
        jpegQualityValueLabel.stringValue = jpegQualityString(value)
    }

    @objc private func scaleChanged(_ sender: NSPopUpButton) {
        Settings.shared.activityCaptureScale = sender.indexOfSelectedItem == 1 ? 2 : 1
    }

    @objc private func fallbackIntervalChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Self.fallbackIntervalValues.count else { return }
        Settings.shared.activityCaptureFallbackIntervalSeconds = Self.fallbackIntervalValues[idx]
    }

    @objc private func idleThresholdChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Self.idleThresholdValues.count else { return }
        Settings.shared.activityCaptureIdleThresholdSeconds = Self.idleThresholdValues[idx]
    }

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Self.retentionValues.count else { return }
        Settings.shared.activityCaptureRetentionDays = Self.retentionValues[idx]
    }

    @objc private func meetingSilenceChanged(_ sender: NSStepper) {
        let value = sender.integerValue
        Settings.shared.activityCaptureMicReleaseDelay = value
        meetingSilenceValueLabel.stringValue = "\(Settings.shared.activityCaptureMicReleaseDelay) sec"
    }

    @objc private func meetingModeChanged(_ sender: NSSegmentedControl) {
        let chosen: ActivityCaptureAudioMode
        switch sender.selectedSegment {
        case 1: chosen = .audio
        case 2: chosen = .transcript
        default: chosen = .off
        }
        applyMeetingMode(chosen)
    }

    /// Applies the chosen mode after running its permission preflight.
    /// On failure, prompts the user and reverts the segmented control.
    private func applyMeetingMode(_ requested: ActivityCaptureAudioMode) {
        guard requested != .off else {
            Settings.shared.activityCaptureAudioMode = .off
            loadMeetingModeSelection()
            updateCaptureControlsState()
            return
        }

        // 1) Mic permission (both modes).
        if !AccessibilityChecker.isMicrophoneGranted {
            AccessibilityChecker.requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.applyMeetingMode(requested)
                } else {
                    self.revertMeetingMode(reason:
                        "Microphone access is required to record meetings. " +
                        "Enable BrainCache in System Settings → Privacy & Security → Microphone.")
                }
            }
            return
        }

        // 2) Transcript mode also needs screen recording (system audio) and an API key.
        if requested == .transcript {
            if !AccessibilityChecker.isScreenRecordingGranted {
                _ = AccessibilityChecker.openScreenRecordingSettings()
                revertMeetingMode(reason:
                    "Screen Recording permission is required to capture system audio " +
                    "for the transcript. Enable BrainCache in System Settings, then quit " +
                    "and reopen the app.")
                return
            }
            guard Settings.shared.isAIEnabled else {
                revertMeetingMode(reason:
                    "Add your OpenAI API key in Preferences → AI to enable transcript recording.")
                return
            }
        }

        Settings.shared.activityCaptureAudioMode = requested
        loadMeetingModeSelection()
        updateCaptureControlsState()
    }

    private func revertMeetingMode(reason: String) {
        loadMeetingModeSelection()
        updateCaptureControlsState()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Cannot Enable Meeting Recording"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func changeFolderTapped() {
        let tempAccess = ActivityCaptureFolderAccess()
        do {
            try tempAccess.promptUserToChooseFolder(relativeTo: window)
            NotificationCenter.default.post(name: .activityCaptureLogRootDidChange, object: nil)
            updateLogFolderPath()
            updateCaptureControlsState()
        } catch ActivityCaptureFolderAccess.AccessError.userCancelled {
            // nothing to do
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could Not Change Folder"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func openLogsFolderTapped() {
        guard let bookmarkData = Settings.shared.activityCaptureLogRootBookmark else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        let logsURL = url.appendingPathComponent("logs", isDirectory: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logsURL.path)
    }

    @objc private func manageExclusionsTapped() {
        ExclusionListSheet.run(relativeTo: window) { [weak self] updated in
            guard let updated = updated else { return }
            Settings.shared.activityCaptureExcludedBundleIDs = updated
        }
    }
}
