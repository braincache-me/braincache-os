import AppKit

/// Floating non-activating panel used as the clipboard search overlay.
final class SearchPanelWindow: NSPanel {

    static let panelHeight: CGFloat = 310
    static let horizontalInset: CGFloat = 0
    private static let showDuration: TimeInterval = 0.44
    private static let hideDuration: TimeInterval = 0.36

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
        level = .statusBar
        isMovable = false
        isMovableByWindowBackground = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Disable AppKit's auto-constrain so the panel can sit at the absolute
        // bottom of the screen, overlapping the dock area.
        frameRect
    }

    // MARK: - Key handling

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Forward standard Edit-menu key equivalents to the search field.
        // Required for a non-activating LSUIElement panel where there is no menu bar.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.keyCode {
            case 8, 9, 7, 0, 6:
                // Let AppKit route to first responder first, then fall back for LSUIElement.
                if super.performKeyEquivalent(with: event) {
                    return true
                }
            default:
                break
            }
            switch event.keyCode {
            case 8:  // Cmd+C — copy; route to whatever is first responder
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case 9:  // Cmd+V — paste into search field
                ensureSearchFieldIsFirstResponder()
                return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case 7:  // Cmd+X — cut
                return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case 0:  // Cmd+A — select all text in search field
                ensureSearchFieldIsFirstResponder()
                return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
            case 6:  // Cmd+Z / Cmd+Shift+Z — undo/redo
                let selector = event.modifierFlags.contains(.shift)
                    ? Selector(("redo:")) : Selector(("undo:"))
                return NSApp.sendAction(selector, to: nil, from: self)
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Ensures the search field is the first responder so Edit actions reach it.
    private func ensureSearchFieldIsFirstResponder() {
        guard let field = SearchPanelController.shared.searchField,
              firstResponder !== field.currentEditor() else { return }
        makeFirstResponder(field)
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+key events are handled by performKeyEquivalent — do not redirect them
        // to the search field via keyDown, as that bypasses the text system's paste/copy handling.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            super.keyDown(with: event)
            return
        }
        let controller = SearchPanelController.shared
        switch Int(event.keyCode) {
        case 53:        // Escape
            controller.hide()
        case 36, 76:    // Return, Numpad Enter
            controller.confirmSelection()
        case 126, 123:  // Up, Left
            controller.moveSelectionLeft()
        case 125, 124:  // Down, Right
            controller.moveSelectionRight()
        default:
            if let field = controller.searchField,
               firstResponder === field.currentEditor() || firstResponder === field {
                super.keyDown(with: event)
            } else {
                controller.redirectToSearchField(event: event, in: self)
            }
        }
    }

    // MARK: - Positioning

    /// Move the panel to the absolute bottom of the main screen, spanning full width and overlaying the dock.
    func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let fullFrame = screen.frame
        let w = fullFrame.width
        let h = Self.panelHeight
        let x = fullFrame.minX
        let y = fullFrame.minY
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }

    // MARK: - Animation

    func showWithAnimation() {
        positionAtBottomCenter()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        displayIfNeeded()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
        }
    }

    func hideWithAnimation(completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.hideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
            completion()
        })
    }
}
