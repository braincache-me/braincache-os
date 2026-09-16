import AppKit

/// Document view for preference scroll views. NSScrollView's clip view follows
/// its document view's `isFlipped` value — without this override, top-anchored
/// content lands at the visual bottom because macOS's default coordinate origin
/// is bottom-left.
final class FlippedPrefsContentView: NSView {
    override var isFlipped: Bool { true }
}
