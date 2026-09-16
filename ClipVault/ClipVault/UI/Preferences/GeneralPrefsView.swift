import AppKit
import ServiceManagement

final class GeneralPrefsView: NSView {

    // MARK: - Scroll infrastructure

    private let scrollView = NSScrollView()
    private let contentView = FlippedPrefsContentView()

    // MARK: - Controls

    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch BrainCache at login", target: nil, action: nil)
    private let meetingDetectionCheckbox = NSButton(checkboxWithTitle: "Offer to record when a meeting is detected", target: nil, action: nil)
    private let meetingDetectionDesc = NSTextField(wrappingLabelWithString: "")
    private let showOnboardingButton = NSButton(title: "Show Onboarding", target: nil, action: nil)
    private let pasteModePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

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
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled(_:))

        meetingDetectionCheckbox.target = self
        meetingDetectionCheckbox.action = #selector(meetingDetectionToggled(_:))
        meetingDetectionDesc.font = .systemFont(ofSize: 11)
        meetingDetectionDesc.textColor = .secondaryLabelColor
        meetingDetectionDesc.maximumNumberOfLines = 0
        if MeetingDetector.isSupported {
            meetingDetectionDesc.stringValue =
                "When Zoom, Teams, a browser call, or another meeting app starts using your microphone, BrainCache shows a small bubble under the menu bar icon offering to record and transcribe the meeting."
        } else {
            meetingDetectionCheckbox.isEnabled = false
            meetingDetectionDesc.stringValue = "Meeting detection requires macOS 14 or later."
        }

        showOnboardingButton.target = self
        showOnboardingButton.action = #selector(showOnboarding)

        pasteModePopup.removeAllItems()
        pasteModePopup.addItem(withTitle: "Plain text")
        pasteModePopup.lastItem?.representedObject = PasteMode.plain
        pasteModePopup.addItem(withTitle: "With formatting")
        pasteModePopup.lastItem?.representedObject = PasteMode.rich
        pasteModePopup.target = self
        pasteModePopup.action = #selector(pasteModeChanged(_:))
    }

    private func layoutContent() {
        let m: CGFloat = 20

        let generalLabel = makeSectionHeader("General")
        let pasteSep = makeSeparator()
        let pasteHeader = makeSectionHeader("Paste Behavior")
        let pasteLabel = NSTextField(labelWithString: "Default paste mode:")
        pasteLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        let pasteDesc = NSTextField(wrappingLabelWithString:
            "Pick the format used when you press Return to paste a clip. Hold Shift while pressing Return (or shift+double-click) to paste the opposite mode for a single paste.")
        pasteDesc.font = .systemFont(ofSize: 11)
        pasteDesc.textColor = .secondaryLabelColor
        pasteDesc.maximumNumberOfLines = 0

        let sep = makeSeparator()
        let onboardingHeader = makeSectionHeader("Getting Started")
        let onboardingDesc = NSTextField(wrappingLabelWithString:
            "Re-open the welcome slides any time for a quick refresher on permissions, the shortcut, and optional AI setup.")
        onboardingDesc.font = .systemFont(ofSize: 11)
        onboardingDesc.textColor = .secondaryLabelColor
        onboardingDesc.maximumNumberOfLines = 0

        let allViews: [NSView] = [
            generalLabel, launchAtLoginCheckbox,
            meetingDetectionCheckbox, meetingDetectionDesc,
            pasteSep, pasteHeader, pasteLabel, pasteModePopup, pasteDesc,
            sep, onboardingHeader, onboardingDesc, showOnboardingButton,
        ]
        allViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            generalLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: m),
            generalLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: generalLabel.bottomAnchor, constant: 8),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            meetingDetectionCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 8),
            meetingDetectionCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            meetingDetectionDesc.topAnchor.constraint(equalTo: meetingDetectionCheckbox.bottomAnchor, constant: 4),
            meetingDetectionDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m + 18),
            meetingDetectionDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            pasteSep.topAnchor.constraint(equalTo: meetingDetectionDesc.bottomAnchor, constant: 16),
            pasteSep.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            pasteSep.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            pasteHeader.topAnchor.constraint(equalTo: pasteSep.bottomAnchor, constant: 8),
            pasteHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            pasteLabel.centerYAnchor.constraint(equalTo: pasteModePopup.centerYAnchor),
            pasteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            pasteModePopup.topAnchor.constraint(equalTo: pasteHeader.bottomAnchor, constant: 8),
            pasteModePopup.leadingAnchor.constraint(equalTo: pasteLabel.trailingAnchor, constant: 8),

            pasteDesc.topAnchor.constraint(equalTo: pasteModePopup.bottomAnchor, constant: 6),
            pasteDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            pasteDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            sep.topAnchor.constraint(equalTo: pasteDesc.bottomAnchor, constant: 16),
            sep.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            sep.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            onboardingHeader.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            onboardingHeader.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            onboardingDesc.topAnchor.constraint(equalTo: onboardingHeader.bottomAnchor, constant: 6),
            onboardingDesc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            onboardingDesc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            showOnboardingButton.topAnchor.constraint(equalTo: onboardingDesc.bottomAnchor, constant: 8),
            showOnboardingButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            contentView.bottomAnchor.constraint(equalTo: showOnboardingButton.bottomAnchor, constant: m),
        ])
    }

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Load

    private func loadValues() {
        var launchAtLogin = Settings.shared.launchAtLogin
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        launchAtLoginCheckbox.state = launchAtLogin ? .on : .off

        meetingDetectionCheckbox.state =
            (MeetingDetector.isSupported && Settings.shared.meetingDetectionEnabled) ? .on : .off

        let currentMode = Settings.shared.defaultPasteMode
        let index = pasteModePopup.itemArray.firstIndex { item in
            (item.representedObject as? PasteMode) == currentMode
        } ?? 0
        pasteModePopup.selectItem(at: index)
    }

    // MARK: - Actions

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enable = sender.state == .on
        if #available(macOS 13.0, *) {
            do {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                Settings.shared.launchAtLogin = enable
            } catch {
                NSLog("GeneralPrefsView: SMAppService error: %@", error.localizedDescription)
                sender.state = enable ? .off : .on
            }
        } else {
            sender.state = enable ? .off : .on
        }
    }

    @objc private func meetingDetectionToggled(_ sender: NSButton) {
        Settings.shared.meetingDetectionEnabled = sender.state == .on
        MeetingDetector.shared.settingsDidChange()
    }

    @objc private func showOnboarding() {
        OnboardingWindowController.shared.show()
    }

    @objc private func pasteModeChanged(_ sender: NSPopUpButton) {
        guard let mode = sender.selectedItem?.representedObject as? PasteMode else { return }
        Settings.shared.defaultPasteMode = mode
    }
}
