import AppKit

final class VoiceRecordingPanelWindow: NSPanel {

    static let panelHeight: CGFloat = 222
    static let panelWidth: CGFloat = 480
    /// Smallest width the user can shrink the panel to via the system
    /// resize handles. Below this the bottom-bar controls would overlap.
    static let minPanelWidth: CGFloat = 420
    private static let showDuration: TimeInterval = 0.36
    private static let hideDuration: TimeInterval = 0.28

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
            // `.resizable` enables drag handles on every edge and corner so
            // the user can grow / shrink the panel directly. The controller
            // re-anchors the bottom edge in `windowDidResize` so the panel
            // keeps its near-bottom-of-screen home base.
            .resizable,
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
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        appearance = NSAppearance(named: .darkAqua)
        sharingType = BuildVariant.allowsScreenCapture ? .readOnly : .none

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Bound resize within a sensible range on both axes. The controller
        // observes `NSWindow.didResizeNotification` to keep the bottom edge
        // anchored to the screen and to distribute the new height between
        // the transcript area and the AI drawer body.
        let visible = NSScreen.main?.visibleFrame
        minSize = NSSize(width: Self.minPanelWidth, height: Self.panelHeight)
        maxSize = NSSize(
            width: max(Self.minPanelWidth, (visible?.width ?? 2000) - 40),
            height: max(Self.panelHeight, (visible?.height ?? 2000) - 60)
        )
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Positioning

    /// Pins the panel to the bottom-center of the screen. `height` lets the
    /// controller request a taller frame (when the AI Assist drawer is
    /// expanded) without leaking drawer-state details into the window.
    /// Preserves the current width so a user-resized panel doesn't snap
    /// back to the default 480pt each time it reopens.
    func positionAtBottomCenter(height: CGFloat = panelHeight) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let width = frame.width > 0 ? frame.width : Self.panelWidth
        let x = visibleFrame.midX - width / 2
        let y = visibleFrame.minY + 6
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
    }

    // MARK: - Animation

    func showWithAnimation(height: CGFloat = panelHeight) {
        positionAtBottomCenter(height: height)
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
