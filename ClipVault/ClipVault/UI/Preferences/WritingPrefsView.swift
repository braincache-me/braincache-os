import AppKit

/// Preferences → Writing. Configures the Writing Assistant,
/// including its editable prompt and model selection.
final class WritingPrefsView: NSView {

    // MARK: - Scroll infrastructure

    private let scrollView = NSScrollView()
    private let contentView = FlippedPrefsContentView()
    private let stack = NSStackView()

    // MARK: - Controls

    private let rewritePromptScrollView = NSScrollView()
    private let rewritePromptTextView = NSTextView()
    private let rewriteModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rewriteMaxOutputTokensField = NSTextField()

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

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            contentView.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
        ])

        configureControls()
        layoutContent()
    }

    private func configureControls() {
        configurePromptEditor(rewritePromptScrollView, textView: rewritePromptTextView)

        rewriteModelPopup.target = self
        rewriteModelPopup.action = #selector(rewriteModelChanged(_:))

        rewriteMaxOutputTokensField.alignment = .right
        rewriteMaxOutputTokensField.formatter = numberFormatter()
        rewriteMaxOutputTokensField.target = self
        rewriteMaxOutputTokensField.action = #selector(rewriteMaxOutputTokensChanged)
        rewriteMaxOutputTokensField.delegate = self
    }

    private func configurePromptEditor(_ scroll: NSScrollView, textView: NSTextView) {
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        scroll.documentView = textView
    }

    private func layoutContent() {
        addToStack(sectionHeader("Writing Assistant"))
        addToStack(wrappingLabel(
            "BrainCache can open a small AI companion directly beside the text cursor "
            + "in any editable field."),
            fullWidth: true)

        addSeparator()

        addToStack(sectionHeader("Behavior"))
        addToStack(wrappingLabel(
            "Double-tap right Command in any text field, or use the configured AI shortcut, "
            + "then type what you want. The assistant can rewrite a selection, answer into an empty "
            + "field, or generate text to replace, append, or copy."),
            fullWidth: true)
        addToStack(fieldLabel("Assistant instructions:"))
        addToStack(rewritePromptScrollView, fullWidth: true, height: 110)
        addToStack(resetButton(action: #selector(resetRewritePrompt)))
        addToStack(modelRow(label: "Model:", popup: rewriteModelPopup))
        addToStack(numberRow(label: "Max output tokens:", field: rewriteMaxOutputTokensField))
    }

    // MARK: - Stack helpers

    private func addToStack(_ view: NSView, fullWidth: Bool = false, height: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        if fullWidth {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let height {
            view.heightAnchor.constraint(equalToConstant: height).isActive = true
        }
    }

    private func addSeparator() {
        let box = NSBox()
        box.boxType = .separator
        if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(16, after: last)
        }
        addToStack(box, fullWidth: true)
        stack.setCustomSpacing(14, after: box)
    }

    private func sectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func resetButton(action: Selector) -> NSButton {
        let button = NSButton(title: "Reset to default", target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func modelRow(label text: String, popup: NSPopUpButton) -> NSView {
        let row = NSStackView(views: [fieldLabel(text), popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func numberRow(label text: String, field: NSTextField) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let row = NSStackView(views: [fieldLabel(text), field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func numberFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 256
        formatter.maximum = 32_000
        formatter.allowsFloats = false
        return formatter
    }

    // MARK: - Load

    private func loadValues() {
        let s = Settings.shared
        rewritePromptTextView.string = s.writingRewritePrompt
        populate(rewriteModelPopup, selected: s.writingRewriteModel)
        rewriteMaxOutputTokensField.integerValue = s.writingRewriteMaxOutputTokens
    }

    private func populate(_ popup: NSPopUpButton, selected: String) {
        popup.removeAllItems()
        var models = Settings.shared.cachedModelList
        if models.isEmpty { models = [selected] }
        if !models.contains(selected) { models.insert(selected, at: 0) }
        popup.addItems(withTitles: models)
        popup.selectItem(withTitle: selected)
    }

    // MARK: - Actions

    @objc private func rewriteModelChanged(_ sender: NSPopUpButton) {
        if let title = sender.selectedItem?.title {
            Settings.shared.writingRewriteModel = title
        }
    }

    @objc private func resetRewritePrompt() {
        Settings.shared.writingRewritePrompt = ""
        rewritePromptTextView.string = Settings.shared.writingRewritePrompt
    }

    @objc private func rewriteMaxOutputTokensChanged() {
        Settings.shared.writingRewriteMaxOutputTokens = integerValue(
            from: rewriteMaxOutputTokensField,
            fallback: Settings.shared.writingRewriteMaxOutputTokens
        )
        rewriteMaxOutputTokensField.integerValue = Settings.shared.writingRewriteMaxOutputTokens
    }

    private func integerValue(from field: NSTextField, fallback: Int) -> Int {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? fallback
    }

}

// MARK: - NSTextViewDelegate

extension WritingPrefsView: NSTextViewDelegate, NSTextFieldDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView === rewritePromptTextView {
            Settings.shared.writingRewritePrompt = textView.string
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === rewriteMaxOutputTokensField {
            rewriteMaxOutputTokensChanged()
        }
    }
}
