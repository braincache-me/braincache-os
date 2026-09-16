import AppKit

/// A table row view for displaying a single `ActivityEvent` in the Activity History timeline.
///
/// Layout (left-to-right):
///   [event-type icon] [HH:MM:SS] [app name] [window title (truncated)] [control: Role "Name"] [screenshot badge]
final class ActivityEventRowView: NSTableCellView {

    static let identifier = NSUserInterfaceItemIdentifier("ActivityEventRow")

    // MARK: - Subviews

    private let eventIcon = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "")
    private let appLabel = NSTextField(labelWithString: "")
    private let windowLabel = NSTextField(labelWithString: "")
    private let controlLabel = NSTextField(labelWithString: "")
    private let screenshotBadge = NSTextField(labelWithString: "")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Configuration

    /// Populates the row from an `ActivityEvent`.
    func configure(with event: ActivityEvent) {
        timeLabel.stringValue = Self.timeFormatter.string(from: event.timestamp)
        appLabel.stringValue = event.appName
        windowLabel.stringValue = event.windowTitle
        controlLabel.stringValue = Self.controlDescription(event)
        screenshotBadge.isHidden = event.screenshotPath == nil
        eventIcon.image = Self.icon(for: event.eventType)
    }

    // MARK: - Private: build

    private func buildUI() {
        eventIcon.translatesAutoresizingMaskIntoConstraints = false
        eventIcon.imageScaling = .scaleProportionallyDown

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        appLabel.translatesAutoresizingMaskIntoConstraints = false
        appLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        appLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        windowLabel.translatesAutoresizingMaskIntoConstraints = false
        windowLabel.font = NSFont.systemFont(ofSize: 11)
        windowLabel.textColor = .secondaryLabelColor
        windowLabel.lineBreakMode = .byTruncatingTail
        windowLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        controlLabel.translatesAutoresizingMaskIntoConstraints = false
        controlLabel.font = NSFont.systemFont(ofSize: 11)
        controlLabel.textColor = .tertiaryLabelColor
        controlLabel.lineBreakMode = .byTruncatingTail

        screenshotBadge.translatesAutoresizingMaskIntoConstraints = false
        screenshotBadge.stringValue = "  screenshot  "
        screenshotBadge.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        screenshotBadge.textColor = .white
        screenshotBadge.backgroundColor = .systemBlue
        screenshotBadge.isBordered = false
        screenshotBadge.drawsBackground = true
        screenshotBadge.wantsLayer = true
        screenshotBadge.layer?.cornerRadius = 3
        screenshotBadge.setContentHuggingPriority(.required, for: .horizontal)
        screenshotBadge.isHidden = true

        addSubview(eventIcon)
        addSubview(timeLabel)
        addSubview(appLabel)
        addSubview(windowLabel)
        addSubview(controlLabel)
        addSubview(screenshotBadge)

        // Stack two rows: top (icon + time + app + screenshotBadge), bottom (windowTitle + control)
        NSLayoutConstraint.activate([
            eventIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            eventIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            eventIcon.widthAnchor.constraint(equalToConstant: 16),
            eventIcon.heightAnchor.constraint(equalToConstant: 16),

            timeLabel.leadingAnchor.constraint(equalTo: eventIcon.trailingAnchor, constant: 6),
            timeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            appLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 8),
            appLabel.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),

            screenshotBadge.leadingAnchor.constraint(equalTo: appLabel.trailingAnchor, constant: 6),
            screenshotBadge.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            screenshotBadge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            windowLabel.leadingAnchor.constraint(equalTo: timeLabel.leadingAnchor),
            windowLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 1),
            windowLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            windowLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),

            controlLabel.leadingAnchor.constraint(equalTo: windowLabel.trailingAnchor, constant: 8),
            controlLabel.centerYAnchor.constraint(equalTo: windowLabel.centerYAnchor),
            controlLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    // MARK: - Static helpers

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func controlDescription(_ event: ActivityEvent) -> String {
        guard let role = event.controlRole else { return "" }
        var parts = [role]
        if let name = event.controlName { parts.append("\"\(name)\"") }
        if let value = event.controlValue { parts.append("= \"\(value)\"") }
        return parts.joined(separator: " ")
    }

    static func icon(for type_: ActivityEventType) -> NSImage? {
        let systemName: String
        switch type_ {
        case .leftClick, .rightClick, .otherClick:
            systemName = "cursorarrow.click"
        case .keyShortcut:
            systemName = "command"
        case .textInput:
            systemName = "keyboard"
        case .appActivated:
            systemName = "app.badge"
        case .windowFocused, .windowTitleChanged:
            systemName = "macwindow"
        case .idleResumed:
            systemName = "clock.arrow.circlepath"
        case .periodicCapture:
            systemName = "timer"
        case .screenshotCaptured:
            systemName = "camera"
        case .meetingRecordingStarted:
            systemName = "mic.circle"
        case .meetingRecordingStopped:
            systemName = "mic.slash.circle"
        case .meetingTranscriptStarted:
            systemName = "text.bubble"
        case .meetingTranscriptStopped:
            systemName = "text.bubble.fill"
        case .sessionStarted, .sessionResumed:
            systemName = "record.circle"
        case .sessionStopped, .sessionPaused:
            systemName = "stop.circle"
        case .aiAssistResponse:
            systemName = "sparkles"
        }
        let img = NSImage(systemSymbolName: systemName, accessibilityDescription: type_.rawValue)
        img?.isTemplate = true
        return img
    }
}
