import AppKit

/// Encapsulates the guided alert shown to existing users (no onboarding) when
/// Accessibility permission has not been granted. Separating the alert data from
/// the presentation makes it unit-testable without spinning up a UI.
struct AccessibilityOnboardingAlert {
    let messageText: String
    let informativeText: String
    let primaryButtonTitle: String
    let secondaryButtonTitle: String
    let primaryAction: () -> Void

    /// Returns the default alert configuration that opens System Settings when confirmed.
    /// The default closure opens System Settings directly and does NOT call
    /// `AXIsProcessTrustedWithOptions(prompt: true)` — that API pops a second OS-level
    /// consent dialog on top of this custom alert, producing duplicate prompts at launch.
    /// `AXIsProcessTrusted()` (called earlier by `isGranted`) is enough to register the
    /// app in the Accessibility list so the user can toggle it on in Settings.
    static func make(
        openSettings: @escaping () -> Void = { AccessibilityChecker.openAccessibilitySettings() }
    ) -> AccessibilityOnboardingAlert {
        AccessibilityOnboardingAlert(
            messageText: "Accessibility Permission Required",
            informativeText: "BrainCache needs Accessibility permission to paste clips back to other apps. Click \"Open System Settings\" to enable it under Privacy & Security \u{2192} Accessibility.",
            primaryButtonTitle: "Open System Settings",
            secondaryButtonTitle: "Later",
            primaryAction: openSettings
        )
    }

    /// Presents the alert modally and invokes `primaryAction` if the user clicks the primary button.
    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: primaryButtonTitle)
        alert.addButton(withTitle: secondaryButtonTitle)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            primaryAction()
        }
        return response
    }
}
