import AppKit

protocol WritingAssistantWindowCommandHandling: AnyObject {
    var hasGeneratedResult: Bool { get }
    func submitAssistantPrompt()
    func commitAssistantResult(mode: WritingAssistantCommitMode)
    func hideAssistantPanel()
}

final class WritingAssistantPanelController: NSObject {

    private static let panelWidth: CGFloat = 560
    private static let panelHeight: CGFloat = 112

    private let service: TextRewriteService

    private var window: WritingAssistantPanelWindow?
    private var snapshot: FocusedTextSnapshot?
    private var anchor: CGRect?
    private var generatedResult: WritingAssistantGeneratedResult?
    private var generationID: UUID?

    private let promptField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(wrappingLabelWithString: "")
    private let loaderView = WritingAssistantLoaderView()
    private let closeButton = NSButton()
    private let buttonRow = NSStackView()

    init(service: TextRewriteService) {
        self.service = service
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(snapshot: FocusedTextSnapshot, anchor: CGRect?) {
        self.snapshot = snapshot
        self.anchor = anchor
        self.generatedResult = nil
        self.generationID = nil

        let window = ensureWindow()
        resetUI()
        resize()
        position(window, near: anchor)

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        focusPromptField()
    }

    func hide() {
        generationID = nil
        generatedResult = nil
        window?.orderOut(nil)
    }

    private func resetUI() {
        promptField.stringValue = ""
        promptField.placeholderString = "Ask, refine, rewrite, calculate"
        promptField.isEnabled = true
        statusLabel.stringValue = ""
        statusLabel.isHidden = true
        resultLabel.stringValue = ""
        resultLabel.isHidden = true
        buttonRow.isHidden = true
        loaderView.stopAnimating()
        loaderView.isHidden = true
    }

    private func setLoading(_ loading: Bool) {
        promptField.isEnabled = !loading
        if loading {
            loaderView.isHidden = false
            loaderView.startAnimating()
            statusLabel.stringValue = "Working..."
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        } else {
            loaderView.stopAnimating()
            loaderView.isHidden = true
        }
    }

    private func showResult(_ result: WritingAssistantGeneratedResult) {
        generatedResult = result
        resultLabel.stringValue = result.text
        resultLabel.isHidden = false
        buttonRow.isHidden = false
        statusLabel.stringValue = "Esc close"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = false
    }

    private func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemOrange
        statusLabel.isHidden = false
        promptField.isEnabled = true
        focusPromptField()
    }

    private func ensureWindow() -> WritingAssistantPanelWindow {
        if let window { return window }

        let window = WritingAssistantPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.commandHandler = self
        window.contentView = makeContentView()
        window.initialFirstResponder = promptField
        self.window = window
        return window
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor

        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 12
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor

        root.addSubview(materialView)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true

        materialView.addSubview(content)

        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        promptField.translatesAutoresizingMaskIntoConstraints = false
        promptField.isBezeled = false
        promptField.drawsBackground = false
        promptField.focusRingType = .none
        promptField.font = .systemFont(ofSize: 15, weight: .medium)
        promptField.textColor = .labelColor
        promptField.delegate = self

        loaderView.translatesAutoresizingMaskIntoConstraints = false
        loaderView.isHidden = true

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close"
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)

        let promptRow = NSStackView(views: [promptField, loaderView, closeButton])
        promptRow.orientation = .horizontal
        promptRow.alignment = .centerY
        promptRow.spacing = 8
        promptRow.translatesAutoresizingMaskIntoConstraints = false
        promptField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true

        resultLabel.font = .systemFont(ofSize: 12)
        resultLabel.textColor = .labelColor
        resultLabel.maximumNumberOfLines = 2
        resultLabel.lineBreakMode = .byTruncatingTail
        resultLabel.isHidden = true

        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.alignment = .centerY
        buttonRow.isHidden = true
        buttonRow.addArrangedSubview(actionButton("Replace  ⌘↩", action: #selector(replaceClicked)))
        buttonRow.addArrangedSubview(actionButton("Append  ⌘↓", action: #selector(appendClicked)))
        buttonRow.addArrangedSubview(actionButton("Copy  ⌘C", action: #selector(copyClicked)))

        stack.addArrangedSubview(promptRow)
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(resultLabel)
        stack.addArrangedSubview(buttonRow)
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: root.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            content.topAnchor.constraint(equalTo: materialView.topAnchor),
            content.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            loaderView.widthAnchor.constraint(equalToConstant: 24),
            loaderView.heightAnchor.constraint(equalToConstant: 24),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            promptRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            resultLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])

        return root
    }

    private func actionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    @objc private func replaceClicked() {
        commitAssistantResult(mode: .replace)
    }

    @objc private func appendClicked() {
        commitAssistantResult(mode: .append)
    }

    @objc private func copyClicked() {
        commitAssistantResult(mode: .copy)
    }

    @objc private func closeClicked() {
        hide()
    }

    private func resize() {
        guard let window else { return }
        window.setContentSize(NSSize(width: Self.panelWidth, height: Self.panelHeight))
        if let anchor {
            position(window, near: anchor)
        }
    }

    private func position(_ window: NSWindow, near anchor: CGRect?) {
        let fallback = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let anchorRect = anchor ?? CGRect(origin: NSEvent.mouseLocation, size: .zero)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorRect) } ?? fallback
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchorRect.minX
        var y = anchorRect.minY - Self.panelHeight - 8

        x = min(max(x, visible.minX + 8), visible.maxX - Self.panelWidth - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - Self.panelHeight - 8)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func focusPromptField() {
        guard let window else { return }
        window.makeFirstResponder(promptField)
        promptField.becomeFirstResponder()
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(self.promptField)
            self.promptField.currentEditor()?.selectedRange = NSRange(
                location: (self.promptField.stringValue as NSString).length,
                length: 0
            )
        }
    }
}

extension WritingAssistantPanelController: WritingAssistantWindowCommandHandling {
    var hasGeneratedResult: Bool { generatedResult != nil }

    func submitAssistantPrompt() {
        guard generatedResult == nil else { return }
        guard let snapshot else { return }

        let instruction = promptField.stringValue
        let id = UUID()
        generationID = id
        setLoading(true)

        service.generateAssistantResponse(
            instruction: instruction,
            snapshot: snapshot,
            anchor: anchor
        ) { [weak self] result in
            guard let self, self.generationID == id else { return }
            self.generationID = nil
            self.setLoading(false)

            switch result {
            case .success(let generated):
                self.showResult(generated)
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }

    func commitAssistantResult(mode: WritingAssistantCommitMode) {
        guard let generatedResult else { return }
        hide()
        service.commit(generatedResult, mode: mode, anchor: anchor)
    }

    func hideAssistantPanel() {
        hide()
    }
}

extension WritingAssistantPanelController: NSTextFieldDelegate {
    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submitAssistantPrompt()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            hideAssistantPanel()
            return true
        }
        return false
    }
}

final class WritingAssistantPanelWindow: NSPanel {

    weak var commandHandler: WritingAssistantWindowCommandHandling?

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backingStoreType,
            defer: flag
        )
        configure()
    }

    private func configure() {
        level = .popUpMenu
        isFloatingPanel = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        commandHandler?.hideAssistantPanel()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.keyCode {
            case 36, 76:
                if commandHandler?.hasGeneratedResult == true {
                    commandHandler?.commitAssistantResult(mode: .replace)
                } else {
                    commandHandler?.submitAssistantPrompt()
                }
                return true
            case 125:
                commandHandler?.commitAssistantResult(mode: .append)
                return true
            case 8 where commandHandler?.hasGeneratedResult == true:
                commandHandler?.commitAssistantResult(mode: .copy)
                return true
            case 8:  return NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: self)
            case 9:  return NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: self)
            case 7:  return NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: self)
            case 0:  return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case 6:
                let selector = event.modifierFlags.contains(.shift)
                    ? Selector(("redo:")) : Selector(("undo:"))
                return NSApp.sendAction(selector, to: nil, from: self)
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            commandHandler?.hideAssistantPanel()
        case 36, 76:
            if event.modifierFlags.contains(.command) {
                if commandHandler?.hasGeneratedResult == true {
                    commandHandler?.commitAssistantResult(mode: .replace)
                } else {
                    commandHandler?.submitAssistantPrompt()
                }
            } else {
                commandHandler?.submitAssistantPrompt()
            }
        case 125 where event.modifierFlags.contains(.command):
            commandHandler?.commitAssistantResult(mode: .append)
        default:
            super.keyDown(with: event)
        }
    }
}
