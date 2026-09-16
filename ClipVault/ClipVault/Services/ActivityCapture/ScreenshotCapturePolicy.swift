import Foundation

/// The event that triggered a screenshot request.
enum ScreenshotTrigger: String {
    case appSwitch = "app_switch"
    case windowFocused = "window_focused"
    case titleChanged = "title_changed"
    case idleResumed = "idle_resumed"
    case periodicCapture = "periodic_capture"
}

/// Stateful policy that decides whether a screenshot should be captured.
///
/// Rules enforced:
/// - Minimum interval: no two captures within `minimumIntervalSeconds`.
/// - Same-window suppression: `windowFocused` / `titleChanged` triggers are
///   suppressed when the window key (identifier or title) has not changed since
///   the last capture.
/// - `titleChanged` throttle: even when the title *does* change, two
///   title-change screenshots cannot be taken within `titleChangedIntervalSeconds`.
///   This stops rapidly mutating titles (Chrome tab navigation, animated titles)
///   from generating dozens of near-identical screenshots.
/// - Periodic fallback override: `periodicCapture` triggers honour
///   `fallbackIntervalSeconds`; passing `0` disables periodic capture entirely.
/// - `appSwitch` and `idleResumed` always capture (subject to minimum interval).
struct ScreenshotCapturePolicy {

    // MARK: - Mutable tracking state

    private(set) var lastCaptureDate: Date?

    /// Effective window key at the time of last capture: `windowIdentifier ?? windowTitle`.
    private(set) var lastCaptureKey: String?

    /// Date of the most recent `periodicCapture`-triggered screenshot.
    private(set) var lastFallbackDate: Date?

    /// Date of the most recent `titleChanged`-triggered screenshot. Used to
    /// throttle high-frequency title churn independent of the minimum interval.
    private(set) var lastTitleChangedDate: Date?

    // MARK: - Decision

    /// Returns `true` if a screenshot should be taken given the current trigger and window state.
    ///
    /// - Parameters:
    ///   - trigger: The reason the screenshot was requested.
    ///   - windowIdentifier: Opaque window identifier from AX/coordinator (may be nil).
    ///   - windowTitle: Current window title (used as fallback identifier).
    ///   - minimumIntervalSeconds: Minimum gap between any two captures. Default 2 s.
    ///   - fallbackIntervalSeconds: Gap required for `periodicCapture`. `0` = never. Default 60 s.
    ///   - titleChangedIntervalSeconds: Minimum gap between two `titleChanged`
    ///     captures, on top of `minimumIntervalSeconds`. Default 10 s.
    ///   - now: Current time (injectable for deterministic tests).
    func shouldCapture(
        trigger: ScreenshotTrigger,
        windowIdentifier: String?,
        windowTitle: String,
        minimumIntervalSeconds: Double = 2.0,
        fallbackIntervalSeconds: Int = 60,
        titleChangedIntervalSeconds: Double = 10.0,
        now: Date = Date()
    ) -> Bool {
        // Always enforce minimum interval between any two captures.
        if let last = lastCaptureDate, now.timeIntervalSince(last) < minimumIntervalSeconds {
            return false
        }

        switch trigger {
        case .appSwitch, .idleResumed:
            // Always capture on app-switch and idle-resume.
            return true

        case .windowFocused, .titleChanged:
            // Suppress if this is the same window/title as the last capture.
            let key = windowIdentifier ?? windowTitle
            if let lastKey = lastCaptureKey, lastKey == key {
                return false
            }
            // Throttle title-change bursts (Chrome tab nav, animated titles).
            if trigger == .titleChanged,
               titleChangedIntervalSeconds > 0,
               let lastTitle = lastTitleChangedDate,
               now.timeIntervalSince(lastTitle) < titleChangedIntervalSeconds {
                return false
            }
            return true

        case .periodicCapture:
            guard fallbackIntervalSeconds > 0 else { return false }
            if let last = lastFallbackDate {
                return now.timeIntervalSince(last) >= Double(fallbackIntervalSeconds)
            }
            return true
        }
    }

    // MARK: - State update

    /// Records that a screenshot was taken so future `shouldCapture` calls can
    /// apply dedupe rules correctly.
    ///
    /// - Parameters:
    ///   - windowIdentifier: Opaque window identifier (may be nil).
    ///   - windowTitle: Current window title (used when `windowIdentifier` is nil).
    ///   - trigger: The trigger that caused the capture (used to update fallback timestamp).
    ///   - date: Capture timestamp (injectable for tests).
    mutating func recordCapture(
        windowIdentifier: String?,
        windowTitle: String,
        trigger: ScreenshotTrigger,
        at date: Date = Date()
    ) {
        lastCaptureDate = date
        lastCaptureKey = windowIdentifier ?? windowTitle
        if trigger == .periodicCapture {
            lastFallbackDate = date
        }
        if trigger == .titleChanged {
            lastTitleChangedDate = date
        }
    }
}
