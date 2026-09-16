import AppKit
import ApplicationServices
import CoreGraphics

/// Owns the Writing Assistant's text-field shortcuts.
///
/// The legacy rewrite hotkey and the double-tap right Command gesture both
/// open the companion panel for the currently focused text field.
final class WritingAssistantCoordinator {

    private let textReader = FocusedTextReader()
    private let assistantHotkeyMonitor = WritingAssistantHotkeyMonitor()
    private lazy var assistantPanel = WritingAssistantPanelController(service: rewriteService)

    /// Exposed so `AppDelegate` can wire the clipboard monitor.
    let rewriteService = TextRewriteService()

    init() {
        // Chrome / Chromium-based browsers build their AX tree lazily and only
        // after `AXManualAccessibility` (and friends) is set on the app
        // element. Doing it on demand at hotkey-press time is too late — the
        // first query returns nothing because the tree hasn't been built. So
        // we prime it as soon as a browser becomes frontmost, giving Chrome
        // time to build its tree before the user invokes the rewrite.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            primeIfBrowser(app)
        }
        assistantHotkeyMonitor.doubleTapHandler = { [weak self] in
            DispatchQueue.main.async {
                _ = self?.openAssistant()
            }
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication else { return }
        primeIfBrowser(app)
    }

    func startWritingAssistantHotkeyMonitor() {
        assistantHotkeyMonitor.start()
    }

    func stopWritingAssistantHotkeyMonitor() {
        assistantHotkeyMonitor.stop()
    }

    private func primeIfBrowser(_ app: NSRunningApplication) {
        guard FocusedTextReader.browserBundleIDs.contains(app.bundleIdentifier ?? ""),
              app.processIdentifier > 0 else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Both attributes are needed across Chromium versions.
        AXUIElementSetAttributeValue(
            appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - Writing Assistant

    /// Backward-compatible entry point used by the old "AI rewrite" menu item
    /// and hotkey. It now opens the companion panel instead of immediately
    /// rewriting text.
    func handleRewriteHotkey() -> Bool {
        return openAssistant()
    }

    /// Inspects the focused element and opens the companion panel 8 px below the
    /// caret or selection. Must be called on the main thread.
    @discardableResult
    func openAssistant() -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        guard let snapshot = textReader.readFocusedText() else {
            return false
        }
        guard snapshot.canAttemptRewrite else {
            return false
        }
        assistantPanel.show(snapshot: snapshot, anchor: assistantAnchorRect(for: snapshot))
        return true
    }

    private func assistantAnchorRect(for snapshot: FocusedTextSnapshot) -> CGRect? {
        if let element = snapshot.element {
            let axRect: CGRect?
            if snapshot.hasSelection {
                axRect = textReader.selectionRect(
                    for: element,
                    location: snapshot.selectionLocation,
                    length: snapshot.selectionLength
                )
            } else {
                axRect = textReader.caretRect(
                    for: element,
                    caretLocation: snapshot.selectionLocation,
                    textLength: snapshot.valueLength
                )
            }
            if let axRect {
                return AXGeometry.cocoaRect(fromAXRect: axRect)
            }
            if let elementFrame = textReader.elementFrame(element) {
                return AXGeometry.cocoaRect(fromAXRect: elementFrame)
            }
        }
        if let element = snapshot.element,
           let window = textReader.windowFrame(of: element) {
            return AXGeometry.cocoaRect(fromAXRect: window)
        }
        return nil
    }
}
