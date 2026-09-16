import AppKit
import ApplicationServices
import AVFoundation

enum AccessibilityChecker {

    // MARK: - Accessibility (required for CGEvent paste)

    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the one-time system prompt AND opens the Accessibility pane in
    /// System Settings. macOS only shows the TCC prompt once per app installation;
    /// opening Settings ensures the user always lands in the right place.
    @discardableResult
    static func requestAccess() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)
        if !result {
            openAccessibilitySettings()
        }
        return result
    }

    static func requestIfNeeded() {
        guard !isGranted else { return }
        requestAccess()
    }

    /// Returns the System Settings URL for the Accessibility privacy pane.
    /// macOS 13 (Ventura) reorganised System Preferences into System Settings and changed
    /// the deep-link scheme. Using the wrong URL on either version silently does nothing,
    /// so we branch on the OS version.
    static func accessibilitySettingsURL(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL? {
        let urlString: String
        if osVersion.majorVersion >= 13 {
            // macOS 13 Ventura and later — System Settings
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        } else {
            // macOS 12 Monterey and earlier — System Preferences
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        return URL(string: urlString)
    }

    @discardableResult
    static func openAccessibilitySettings() -> Bool {
        if let url = accessibilitySettingsURL() {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - Screen Recording (optional, needed on some macOS versions for clipboard reads)

    static var isScreenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func screenRecordingSettingsURL(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL? {
        let urlString: String
        if osVersion.majorVersion >= 13 {
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
        return URL(string: urlString)
    }

    @discardableResult
    static func openScreenRecordingSettings() -> Bool {
        // On macOS 12 and earlier, CGRequestScreenCaptureAccess() must be called at least once
        // to register the app in the Screen Recording list — otherwise the entry never appears.
        if !isScreenRecordingGranted {
            CGRequestScreenCaptureAccess()
        }
        if let url = screenRecordingSettingsURL() {
            return NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - Microphone (required for voice transcription)

    static var isMicrophoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneAuthorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Triggers the system TCC prompt the first time, and opens Privacy →
    /// Microphone afterwards if the user previously denied. macOS only shows
    /// the prompt while the status is `.notDetermined`; on `.denied` /
    /// `.restricted` we have to send the user to System Settings manually.
    static func requestMicrophoneAccess(completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        case .denied, .restricted:
            _ = openMicrophoneSettings()
            completion(false)
        @unknown default:
            _ = openMicrophoneSettings()
            completion(false)
        }
    }

    static func microphoneSettingsURL(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> URL? {
        let urlString: String
        if osVersion.majorVersion >= 13 {
            urlString = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        return URL(string: urlString)
    }

    @discardableResult
    static func openMicrophoneSettings() -> Bool {
        if let url = microphoneSettingsURL() {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
