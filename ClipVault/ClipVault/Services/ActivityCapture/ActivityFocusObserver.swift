import AppKit
import ApplicationServices

/// Observes frontmost-application and window-focus changes.
///
/// Subscribes to `NSWorkspace.didActivateApplicationNotification` for app switches,
/// and attaches an `AXObserver` to the frontmost process for focused-window /
/// window-title-changed events.
///
/// All callbacks arrive on the main thread.
final class ActivityFocusObserver {

    // MARK: - Event type delivered by this observer

    enum FocusEventKind {
        case appActivated(appName: String, bundleID: String, windowTitle: String)
        case windowFocused(appName: String, bundleID: String, windowTitle: String)
        case windowTitleChanged(appName: String, bundleID: String, windowTitle: String)
    }

    struct FocusEvent {
        let kind: FocusEventKind
        let timestamp: Date
    }

    // MARK: - Public handler

    /// Called on the main thread whenever the focus context changes.
    var onFocusChange: ((FocusEvent) -> Void)?

    // MARK: - Private state

    private var appActivationToken: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0

    private var lastAppName: String = ""
    private var lastBundleID: String = ""
    private var lastWindowTitle: String = ""

    // MARK: - Lifecycle

    deinit {
        stop()
    }

    func start() {
        guard appActivationToken == nil else { return }
        appActivationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
    }

    func stop() {
        if let token = appActivationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appActivationToken = nil
        }
        tearDownAXObserver()
    }

    // MARK: - AX callback (C function pointer)

    private static let axCallback: AXObserverCallback = { (_, element, notification, userInfo) in
        guard let userInfo else { return }
        let self_ = Unmanaged<ActivityFocusObserver>.fromOpaque(userInfo).takeUnretainedValue()
        self_.handleAXCallback(notification: notification as String)
    }

    // MARK: - Private helpers

    private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
        else { return }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""

        setupAXObserver(for: app.processIdentifier, appName: appName, bundleID: bundleID)

        let windowTitle = frontmostWindowTitle(for: app.processIdentifier) ?? ""
        lastAppName = appName
        lastBundleID = bundleID
        lastWindowTitle = windowTitle

        deliver(FocusEvent(
            kind: .appActivated(appName: appName, bundleID: bundleID, windowTitle: windowTitle),
            timestamp: Date()
        ))
    }

    private func handleAXCallback(notification: String) {
        let windowTitle = frontmostWindowTitle(for: observedPID) ?? ""
        let appName = lastAppName
        let bundleID = lastBundleID

        let normalized = Self.normalizeTitle(windowTitle)
        let lastNormalized = Self.normalizeTitle(lastWindowTitle)

        switch notification {
        case kAXFocusedWindowChangedNotification as String:
            guard normalized != lastNormalized else { return }
            lastWindowTitle = windowTitle
            deliver(FocusEvent(
                kind: .windowFocused(appName: appName, bundleID: bundleID, windowTitle: windowTitle),
                timestamp: Date()
            ))

        case kAXTitleChangedNotification as String:
            guard normalized != lastNormalized else { return }
            lastWindowTitle = windowTitle
            deliver(FocusEvent(
                kind: .windowTitleChanged(appName: appName, bundleID: bundleID, windowTitle: windowTitle),
                timestamp: Date()
            ))

        default:
            break
        }
    }

    /// Removes volatile substrings that browsers and chat apps inject into window
    /// titles (audio indicators, memory warnings, unread-count prefixes) so that
    /// dedup compares the meaningful part of the title.
    static func normalizeTitle(_ title: String) -> String {
        guard !title.isEmpty else { return title }
        var s = title

        // Chrome's "(N) " unread/badge prefix.
        if let r = s.range(of: #"^\(\d+\)\s+"#, options: .regularExpression) {
            s.removeSubrange(r)
        }

        // Chrome: " - Audio playing"
        s = s.replacingOccurrences(of: " - Audio playing", with: "")
        // Chrome: " - High memory usage - 802 MB" (any number, with or without comma/space)
        s = s.replacingOccurrences(
            of: #" - High memory usage(\s*-\s*[\d,]+\s*MB)?"#,
            with: "",
            options: .regularExpression
        )

        // Collapse the resulting double-space / trailing dash artifacts.
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    private func deliver(_ event: FocusEvent) {
        onFocusChange?(event)
    }

    private func frontmostWindowTitle(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let win = windowRef,
              CFGetTypeID(win) == AXUIElementGetTypeID()
        else { return nil }
        let axWin = unsafeBitCast(win, to: AXUIElement.self)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.isEmpty
        else { return nil }
        return title
    }

    private func setupAXObserver(for pid: pid_t, appName: String, bundleID: String) {
        tearDownAXObserver()
        guard pid > 0 else { return }
        observedPID = pid

        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &obs) == .success, let observer = obs else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // Register for focused-window change and title change on the application element.
        // Title changes on individual windows would require observing each window element;
        // listening on the application element is sufficient for the common case.
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, appElement, kAXTitleChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
    }

    private func tearDownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = nil
        }
        observedPID = 0
    }
}
