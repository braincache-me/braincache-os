import AppKit
import ApplicationServices

/// Reads the window titles of a running browser via the Accessibility API.
/// BrainCache already holds Accessibility permission for paste, so this needs
/// no extra grant. Chromium browsers only expose the frontmost tab's title per
/// window, which is enough for the "does an open window look like a meeting?"
/// check the detector performs while that browser holds the microphone.
protocol BrowserWindowTitleReading {
    /// Titles of all windows of the app with `mainBundleID`, or nil when the
    /// app isn't running or Accessibility permission is missing.
    func windowTitles(mainBundleID: String) -> [String]?
}

final class BrowserWindowTitleReader: BrowserWindowTitleReading {

    func windowTitles(mainBundleID: String) -> [String]? {
        guard AccessibilityChecker.isGranted else { return nil }
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == mainBundleID }
        guard !apps.isEmpty else { return nil }

        var titles: [String] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Chromium builds its full AX tree lazily; this attribute wakes it
            // (same trick as FocusedTextReader's browser handling).
            AXUIElementSetAttributeValue(
                element, "AXManualAccessibility" as CFString, kCFBooleanTrue
            )
            var windowsValue: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                element, kAXWindowsAttribute as CFString, &windowsValue
            )
            guard status == .success, let windows = windowsValue as? [AXUIElement] else {
                continue
            }
            for window in windows {
                var titleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    window, kAXTitleAttribute as CFString, &titleValue
                ) == .success, let title = titleValue as? String {
                    titles.append(title)
                }
            }
        }
        return titles
    }
}
