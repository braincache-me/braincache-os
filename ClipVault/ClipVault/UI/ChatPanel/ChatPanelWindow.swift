import AppKit

/// Floating non-activating panel for the "Chat with Data" interface.
final class ChatPanelWindow: NSPanel {

    static let defaultWidth:  CGFloat = 780
    static let defaultHeight: CGFloat = 540
    static let minWidth:  CGFloat = 520
    static let minHeight: CGFloat = 380

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        let panelStyle: NSWindow.StyleMask = [
            .nonactivatingPanel,
            .fullSizeContentView,
            .titled,
            .resizable,
            .closable,
            .miniaturizable,
        ]
        super.init(
            contentRect: contentRect,
            styleMask: panelStyle,
            backing: backingStoreType,
            defer: flag
        )
        configure()
    }

    private func configure() {
        level = .floating
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward standard Edit-menu key equivalents to the first responder.
        // Required for a non-activating LSUIElement panel where there is no menu bar
        // to process Cmd+C/V/X/A/Z before they reach the window.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command {
            switch event.keyCode {
            case 8:  return NSApp.sendAction(#selector(NSText.copy(_:)),      to: nil, from: self)
            case 9:  return NSApp.sendAction(#selector(NSText.paste(_:)),     to: nil, from: self)
            case 7:  return NSApp.sendAction(#selector(NSText.cut(_:)),       to: nil, from: self)
            case 0:  return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case 6:
                let selector = event.modifierFlags.contains(.shift)
                    ? Selector(("redo:")) : Selector(("undo:"))
                return NSApp.sendAction(selector, to: nil, from: self)
            // Chat panel keyboard shortcuts
            case 45: // Cmd+N — new conversation
                return NSApp.sendAction(#selector(ChatPanelController.newConversationShortcut), to: nil, from: self)
            case 51: // Cmd+Delete — delete selected conversation
                return NSApp.sendAction(#selector(ChatPanelController.deleteConversationShortcut), to: nil, from: self)
            case 33: // Cmd+[ — previous conversation
                return NSApp.sendAction(#selector(ChatPanelController.navigatePreviousConversation), to: nil, from: self)
            case 30: // Cmd+] — next conversation
                return NSApp.sendAction(#selector(ChatPanelController.navigateNextConversation), to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Escape closes the panel.
        if Int(event.keyCode) == 53 {
            ChatPanelController.shared.hide()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Positioning

    func positionAtCenter() {
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let w = frame.width > 0 ? frame.width : Self.defaultWidth
        let h = frame.height > 0 ? frame.height : Self.defaultHeight
        let x = sf.midX - w / 2
        let y = sf.midY - h / 2
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }
}
