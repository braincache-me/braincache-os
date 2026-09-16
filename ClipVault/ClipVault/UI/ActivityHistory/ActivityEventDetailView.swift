import AppKit

final class ActivityEventDetailView: NSView {

    // MARK: - Subviews

    private let emptyLabel = NSTextField(labelWithString: "Select an event to view details")
    private let outerScrollView = NSScrollView()
    private let rawJSONScrollView = NSScrollView()
    private let rawJSONTextView = NSTextView()
    private let screenshotImageView = NSImageView()
    private let copyJSONButton = NSButton(title: "Copy Raw JSON", target: nil, action: nil)
    private let contentStack = NSStackView()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Configuration

    func configure(event: ActivityEvent?, rawJSON: String, screenshotURL: URL?) {
        let hasEvent = event != nil

        emptyLabel.isHidden = hasEvent
        outerScrollView.isHidden = !hasEvent

        guard hasEvent else { return }

        rawJSONTextView.string = rawJSON

        if let url = screenshotURL,
           let image = NSImage(contentsOf: url) {
            screenshotImageView.image = image
            screenshotImageView.isHidden = false
        } else {
            screenshotImageView.image = nil
            screenshotImageView.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func copyJSON() {
        let text = rawJSONTextView.string
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let orig = copyJSONButton.title
        copyJSONButton.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyJSONButton.title = orig
        }
    }

    // MARK: - Private: build

    private func buildUI() {
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // JSON text view
        rawJSONTextView.isEditable = false
        rawJSONTextView.isRichText = false
        rawJSONTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        rawJSONTextView.autoresizingMask = [.width]
        rawJSONTextView.textContainer?.widthTracksTextView = true
        rawJSONTextView.backgroundColor = NSColor.textBackgroundColor

        rawJSONScrollView.documentView = rawJSONTextView
        rawJSONScrollView.hasVerticalScroller = true
        rawJSONScrollView.hasHorizontalScroller = false
        rawJSONScrollView.autohidesScrollers = true
        rawJSONScrollView.borderType = .lineBorder
        rawJSONScrollView.translatesAutoresizingMaskIntoConstraints = false

        // Screenshot image view
        screenshotImageView.imageScaling = .scaleProportionallyDown
        screenshotImageView.imageAlignment = .alignCenter
        screenshotImageView.wantsLayer = true
        screenshotImageView.layer?.cornerRadius = 4
        screenshotImageView.layer?.masksToBounds = true
        screenshotImageView.translatesAutoresizingMaskIntoConstraints = false

        // Copy button
        copyJSONButton.bezelStyle = .rounded
        copyJSONButton.target = self
        copyJSONButton.action = #selector(copyJSON)

        // Labels
        let jsonLabel = NSTextField(labelWithString: "Raw JSON")
        jsonLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        jsonLabel.textColor = .secondaryLabelColor

        let screenshotLabel = NSTextField(labelWithString: "Screenshot")
        screenshotLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        screenshotLabel.textColor = .secondaryLabelColor

        // Content stack
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        contentStack.addArrangedSubview(jsonLabel)
        contentStack.addArrangedSubview(rawJSONScrollView)
        contentStack.addArrangedSubview(copyJSONButton)
        contentStack.addArrangedSubview(screenshotLabel)
        contentStack.addArrangedSubview(screenshotImageView)

        // Wrap in outer scroll view so it works at any panel height
        outerScrollView.documentView = contentStack
        outerScrollView.hasVerticalScroller = true
        outerScrollView.hasHorizontalScroller = false
        outerScrollView.autohidesScrollers = true
        outerScrollView.borderType = .noBorder
        outerScrollView.drawsBackground = false
        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.isHidden = true

        addSubview(outerScrollView)

        NSLayoutConstraint.activate([
            outerScrollView.topAnchor.constraint(equalTo: topAnchor),
            outerScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: outerScrollView.contentView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: outerScrollView.contentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: outerScrollView.contentView.trailingAnchor),

            rawJSONScrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -24),
            rawJSONScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            rawJSONScrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 200),

            screenshotImageView.widthAnchor.constraint(lessThanOrEqualTo: contentStack.widthAnchor, constant: -24),
            screenshotImageView.heightAnchor.constraint(lessThanOrEqualToConstant: 300)
        ])
    }
}
