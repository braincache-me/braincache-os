import AppKit

/// Floating, resizable, nonactivating panel that shows the latest AI Assist
/// answer (and lets the user navigate back through past ones).
///
/// Nonactivating so the source app keeps focus — the user can record again
/// without first dismissing this window. `LSUIElement = true` means we still
/// need `NSApp.activate` to bring it to the front when it first appears.
final class AIAssistWindow: NSPanel {

    static let minSize = NSSize(width: 520, height: 400)
    static let defaultSize = NSSize(width: 600, height: 480)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: AIAssistWindow.defaultSize),
            styleMask: [
                .titled,
                .closable,
                .resizable,
                .nonactivatingPanel,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        title = "AI Assist"
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        level = .floating
        minSize = AIAssistWindow.minSize

        // Match VoiceRecordingPanelWindow's HUD look: clear/non-opaque chrome
        // with a transparent titlebar so the wrapping NSVisualEffectView
        // (installed by AIAssistWindowController) can show through with
        // rounded corners. Standard window buttons are hidden for a clean
        // floating surface; Cmd+W still closes via the `.closable` style.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        appearance = NSAppearance(named: .darkAqua)
        sharingType = BuildVariant.allowsScreenCapture ? .readOnly : .none

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        center()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
