import AppKit

// MARK: - ChatMessage

/// A single message in the chat conversation.
struct ChatMessage {
    enum Role { case user, assistant }

    let role:           Role
    let text:           String
    let usesPlainTextRenderer: Bool
    let citedIDs:       [Int64]
    let timestamp:      Date
    /// Database primary key — nil for unsaved (in-memory only) messages.
    var id:             Int64?
    /// Database foreign key to the owning conversation — nil for in-memory messages.
    var conversationId: Int64?

    /// Human-readable descriptions of each tool call made during an agentic query.
    /// Empty for classic RAG queries and user messages.
    var searchSteps: [String]

    init(
        role: Role,
        text: String,
        usesPlainTextRenderer: Bool = false,
        citedIDs: [Int64] = [],
        timestamp: Date = Date(),
        id: Int64? = nil,
        conversationId: Int64? = nil,
        searchSteps: [String] = []
    ) {
        self.role           = role
        self.text           = text
        self.usesPlainTextRenderer = usesPlainTextRenderer
        self.citedIDs       = citedIDs
        self.timestamp      = timestamp
        self.id             = id
        self.conversationId = conversationId
        self.searchSteps    = searchSteps
    }
}

// MARK: - ChatBubbleView

/// A single chat message bubble: rounded rect background, word-wrapped text with
/// markdown rendering, timestamp, copy button, and (for assistant messages) clip badges
/// and collapsible search steps.
final class ChatBubbleView: NSView {

    // MARK: - Subviews

    private let textLabel  = NSTextField(wrappingLabelWithString: "")
    private let timeLabel  = NSTextField(labelWithString: "")
    private let badgesRow  = NSStackView()
    private let bubble     = NSView()
    private let copyBtn    = NSButton()
    private var markdownView: MarkdownWebView?

    /// Collapsible search-steps disclosure button (assistant messages only, when steps exist).
    private(set) var stepsDisclosureBtn: NSButton?
    private(set) var stepsContentStack: NSStackView?

    private var actionTargets: [ActionTarget] = []

    // MARK: - Layout constants

    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding:   CGFloat =  8
    private static let cornerRadius:      CGFloat = 10
    private static let maxBubbleWidth:    CGFloat = 480

    // MARK: - Init

    init(message: ChatMessage,
         onClipTapped: ((Int64, NSView) -> Void)? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout(message: message, onClipTapped: onClipTapped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(message:)") }

    // MARK: - Build

    private func buildLayout(message: ChatMessage,
                             onClipTapped: ((Int64, NSView) -> Void)?) {
        let isUser = message.role == .user
        // Rich rendering (tables / code / mermaid) for assistant markdown
        // messages — user and plain-text replies stay as `NSTextField` since
        // they don't carry any markdown.
        let usesRichMarkdown = !isUser && !message.usesPlainTextRenderer

        // Bubble background
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = Self.cornerRadius
        bubble.layer?.backgroundColor = isUser
            ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.6).cgColor
        addSubview(bubble)

        // Content view inside the bubble — either the rich markdown web
        // view (assistant) or the wrapping text field (user / plain text).
        let contentView: NSView
        if usesRichMarkdown {
            let md = MarkdownWebView(compact: true)
            md.translatesAutoresizingMaskIntoConstraints = false
            md.setMarkdown(message.text)
            markdownView = md
            bubble.addSubview(md)
            contentView = md
        } else {
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            textLabel.isEditable = false
            textLabel.isSelectable = true
            textLabel.isBordered = false
            textLabel.drawsBackground = false
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.maximumNumberOfLines = 0
            textLabel.preferredMaxLayoutWidth = Self.maxBubbleWidth - 2 * Self.horizontalPadding
            textLabel.cell?.wraps = true
            textLabel.cell?.usesSingleLineMode = false

            let textColor: NSColor = isUser ? .white : .labelColor
            if isUser {
                textLabel.attributedStringValue = NSAttributedString(
                    string: message.text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13),
                        .foregroundColor: textColor,
                    ])
            } else {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.lineBreakMode = .byCharWrapping
                paragraphStyle.lineSpacing = 2
                textLabel.lineBreakMode = .byCharWrapping
                textLabel.attributedStringValue = NSAttributedString(
                    string: message.text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: paragraphStyle,
                    ])
            }
            textLabel.setContentCompressionResistancePriority(.required, for: .vertical)
            bubble.addSubview(textLabel)
            contentView = textLabel
        }

        // Timestamp label
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        timeLabel.stringValue = fmt.string(from: message.timestamp)
        timeLabel.font = .systemFont(ofSize: 10)
        timeLabel.textColor = .tertiaryLabelColor
        addSubview(timeLabel)

        // Copy button — placed next to the timestamp, outside the bubble
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.bezelStyle = .inline
        copyBtn.isBordered = false
        copyBtn.image = NSImage(systemSymbolName: "doc.on.doc",
                                accessibilityDescription: "Copy message")
        copyBtn.imageScaling = .scaleProportionallyDown
        copyBtn.contentTintColor = .tertiaryLabelColor
        copyBtn.toolTip = "Copy"
        let copyTarget = ActionTarget { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
            self.copyBtn.contentTintColor = .systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.copyBtn.contentTintColor = .tertiaryLabelColor
            }
        }
        actionTargets.append(copyTarget)
        copyBtn.target = copyTarget
        copyBtn.action = #selector(ActionTarget.run)
        addSubview(copyBtn)

        // Badges row (only for assistant messages with citations)
        badgesRow.translatesAutoresizingMaskIntoConstraints = false
        badgesRow.orientation = .horizontal
        badgesRow.spacing = 4
        badgesRow.isHidden = message.citedIDs.isEmpty

        for clipID in message.citedIDs {
            let badge = makeBadge(clipID: clipID, onClipTapped: onClipTapped)
            badgesRow.addArrangedSubview(badge)
        }
        bubble.addSubview(badgesRow)

        let p = Self.horizontalPadding
        let v = Self.verticalPadding
        let maxW = Self.maxBubbleWidth

        if isUser {
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p),
                bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxW),

                textLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: v),
                textLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p),
                textLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p),
                textLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -v),

                badgesRow.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 4),
                badgesRow.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),

                timeLabel.topAnchor.constraint(equalTo: badgesRow.bottomAnchor, constant: 2),
                timeLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
                timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

                copyBtn.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
                copyBtn.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -4),
                copyBtn.widthAnchor.constraint(equalToConstant: 14),
                copyBtn.heightAnchor.constraint(equalToConstant: 14),
            ])
        } else {
            let hasSteps = !message.searchSteps.isEmpty
            let stepsStack = hasSteps ? buildStepsSection(steps: message.searchSteps) : nil
            if let stepsStack { bubble.addSubview(stepsStack) }

            let contentBottom: NSLayoutAnchor<NSLayoutYAxisAnchor>
            let contentBottomConst: CGFloat
            if !badgesRow.isHidden {
                contentBottom = badgesRow.topAnchor
                contentBottomConst = -4
            } else if let stepsStack {
                contentBottom = stepsStack.topAnchor
                contentBottomConst = -4
            } else {
                contentBottom = bubble.bottomAnchor
                contentBottomConst = -v
            }

            let badgesRowBottom: NSLayoutAnchor<NSLayoutYAxisAnchor>
            let badgesRowBottomConst: CGFloat
            if let stepsStack {
                badgesRowBottom = stepsStack.topAnchor
                badgesRowBottomConst = -4
            } else {
                badgesRowBottom = bubble.bottomAnchor
                badgesRowBottomConst = -v
            }

            // The markdown web view has no intrinsic horizontal size; pin
            // bubble width explicitly so it doesn't collapse to zero. The
            // text-field path keeps its intrinsic-size-driven `<=` cap.
            let bubbleWidthConstraint: NSLayoutConstraint = usesRichMarkdown
                ? bubble.widthAnchor.constraint(equalToConstant: maxW)
                : bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxW)

            var constraints: [NSLayoutConstraint] = [
                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p),
                bubbleWidthConstraint,

                contentView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: v),
                contentView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p),
                contentView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p),
                contentView.bottomAnchor.constraint(equalTo: contentBottom, constant: contentBottomConst),

                badgesRow.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p),
                badgesRow.bottomAnchor.constraint(equalTo: badgesRowBottom, constant: badgesRowBottomConst),

                timeLabel.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 2),
                timeLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                timeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),

                copyBtn.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
                copyBtn.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 4),
                copyBtn.widthAnchor.constraint(equalToConstant: 14),
                copyBtn.heightAnchor.constraint(equalToConstant: 14),
            ]

            if let stepsStack {
                constraints += [
                    stepsStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: p),
                    stepsStack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -p),
                    stepsStack.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -v),
                ]
            }
            NSLayoutConstraint.activate(constraints)
        }
    }

    // MARK: - Steps Section

    private func buildStepsSection(steps: [String]) -> NSStackView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.spacing = 2
        container.alignment = .leading

        let disclosureBtn = NSButton(title: "▸ Search steps (\(steps.count))", target: nil, action: nil)
        disclosureBtn.translatesAutoresizingMaskIntoConstraints = false
        disclosureBtn.bezelStyle = .inline
        disclosureBtn.isBordered = false
        disclosureBtn.font = .systemFont(ofSize: 11)
        disclosureBtn.contentTintColor = .tertiaryLabelColor

        let contentStack = NSStackView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.spacing = 2
        contentStack.alignment = .leading
        contentStack.isHidden = true

        for step in steps {
            let lbl = NSTextField(labelWithString: "  \(step)")
            lbl.font = .systemFont(ofSize: 10)
            lbl.textColor = .secondaryLabelColor
            lbl.maximumNumberOfLines = 2
            contentStack.addArrangedSubview(lbl)
        }

        container.addArrangedSubview(disclosureBtn)
        container.addArrangedSubview(contentStack)

        let target = ActionTarget {
            let expanded = !contentStack.isHidden
            contentStack.isHidden = expanded
            disclosureBtn.title = expanded
                ? "▸ Search steps (\(steps.count))"
                : "▾ Search steps (\(steps.count))"
        }
        actionTargets.append(target)
        disclosureBtn.target = target
        disclosureBtn.action = #selector(ActionTarget.run)

        stepsDisclosureBtn = disclosureBtn
        stepsContentStack = contentStack

        return container
    }

    // MARK: - Badge

    private func makeBadge(clipID: Int64, onClipTapped: ((Int64, NSView) -> Void)?) -> NSButton {
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.title = "#\(clipID)"
        btn.bezelStyle = .inline
        btn.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        btn.contentTintColor = .controlAccentColor
        btn.isBordered = true
        if let handler = onClipTapped {
            let target = ActionTarget(action: { handler(clipID, btn) })
            actionTargets.append(target)
            btn.target = target
            btn.action = #selector(ActionTarget.run)
        }
        return btn
    }
}

// MARK: - ActionTarget helper

/// Lightweight target object for NSButton closures (AppKit has no built-in closure API).
final class ActionTarget: NSObject {
    private let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
