import AppKit

/// Tracks the frontmost application so PasteService can restore focus after pasting.
final class AppDetector {

    static let shared = AppDetector()

    /// Bundle identifier of the app that was frontmost before the search panel appeared.
    /// Updated by calling captureCurrentApp() just before the panel shows.
    private(set) var lastFrontmostApp: String?

    // Thread-safety: handleAppActivation fires on the main thread; poll() reads these
    // properties from ClipboardMonitor's background queue. Protect with a lock.
    private let stateLock = NSLock()

    /// A single app-activation event in the switch history.
    /// outgoingBundleID is the app that was frontmost before the switch;
    /// incomingBundleID is the app that became frontmost;
    /// changeCountAtSwitch is the pasteboard changeCount at the moment of the switch.
    struct AppSwitchEvent {
        let outgoingBundleID: String?
        let incomingBundleID: String?
        let changeCountAtSwitch: Int
    }

    private var _switchHistory: [AppSwitchEvent] = []
    private let maxSwitchHistoryDepth = 10

    /// Returns a snapshot of the recent app-switch history, ordered oldest-first.
    /// ClipboardMonitor uses this to trace which app produced the current clipboard content.
    func switchHistorySnapshot() -> [AppSwitchEvent] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _switchHistory
    }

    /// Our own tracked "current" app — maintained from notification userInfo so we don't
    /// read NSWorkspace.frontmostApplication inside the notification handler (which would
    /// already reflect the newly-activated app and make the previous slot unusable).
    /// Only accessed from handleAppActivation (main thread), so no lock needed.
    private var currentTrackedBundleID: String?

    private var activationObserver: NSObjectProtocol?

    init() {
        // Seed tracked state with whatever is frontmost at startup.
        currentTrackedBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil,
            using: { [weak self] _ in self?.handleAppSwitch() }
        )
        // Use the dedicated per-app activation notification available on macOS 10.6+
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        if let o = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func handleAppActivation(_ notification: Notification) {
        // The notification userInfo tells us which app just became active.
        let newApp = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
        // Use our own tracked state (not a live NSWorkspace query) so we capture the true
        // previously-frontmost app rather than the just-activated one.
        if currentTrackedBundleID != newApp {
            // Snapshot the pasteboard changeCount now. If the clipboard changed before this
            // switch, changeCount already reflects that copy; if it changes after, it will
            // exceed this snapshot — letting ClipboardMonitor distinguish the two cases.
            let cc = NSPasteboard.general.changeCount
            if newApp == Bundle.main.bundleIdentifier {
                // ClipVault itself is becoming active. Record the transition with nil as the
                // incoming ID so the outgoing app (possibly excluded) is captured in history
                // for excluded-app filtering, but don't update currentTrackedBundleID — the
                // next real-app switch must still see the last non-ClipVault app as outgoing.
                let event = AppSwitchEvent(
                    outgoingBundleID: currentTrackedBundleID,
                    incomingBundleID: nil,
                    changeCountAtSwitch: cc
                )
                stateLock.lock()
                _switchHistory.append(event)
                if _switchHistory.count > maxSwitchHistoryDepth {
                    _switchHistory.removeFirst()
                }
                stateLock.unlock()
            } else {
                let event = AppSwitchEvent(
                    outgoingBundleID: currentTrackedBundleID,
                    incomingBundleID: newApp,
                    changeCountAtSwitch: cc
                )
                stateLock.lock()
                _switchHistory.append(event)
                if _switchHistory.count > maxSwitchHistoryDepth {
                    _switchHistory.removeFirst()
                }
                stateLock.unlock()
                currentTrackedBundleID = newApp
            }
        }
    }

    private func handleAppSwitch() {}

    /// Snapshot the current frontmost application.
    /// Call this immediately before showing the search panel so PasteService knows where to send ⌘V.
    func captureCurrentApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            // ClipVault is already frontmost (e.g., Preferences is open). Clear any stale
            // paste target so we don't accidentally paste into an unrelated earlier app.
            lastFrontmostApp = nil
            return
        }
        lastFrontmostApp = frontmost?.bundleIdentifier
    }

    /// Bundle identifier of the current frontmost application, excluding ClipVault itself.
    var currentFrontmostBundleID: String? {
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app?.bundleIdentifier
    }
}
