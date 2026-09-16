import XCTest
@testable import ClipVault

final class AccessibilityOnboardingAlertTests: XCTestCase {

    // MARK: - Default alert properties

    func testDefaultMessageText() {
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertEqual(alert.messageText, "Accessibility Permission Required")
    }

    func testDefaultInformativeTextMentionsSystemSettings() {
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertTrue(
            alert.informativeText.contains("System Settings"),
            "Informative text should direct users to System Settings"
        )
    }

    func testDefaultInformativeTextMentionsPrivacyAccessibility() {
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertTrue(
            alert.informativeText.contains("Privacy") && alert.informativeText.contains("Accessibility"),
            "Informative text should mention Privacy & Security > Accessibility path"
        )
    }

    func testPrimaryButtonTitleIsOpenSystemSettings() {
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertEqual(alert.primaryButtonTitle, "Open System Settings")
    }

    func testSecondaryButtonTitleIsLater() {
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertEqual(alert.secondaryButtonTitle, "Later")
    }

    // MARK: - Action routing

    func testPrimaryActionIsCalledWhenInjected() {
        var called = false
        let alert = AccessibilityOnboardingAlert.make(openSettings: { called = true })
        // Invoke the primary action directly to simulate the user clicking the primary button.
        alert.primaryAction()
        XCTAssertTrue(called, "primaryAction should invoke the openSettings closure")
    }

    func testDefaultPrimaryActionDoesNotCrash() {
        // Verify that the default closure (which calls AccessibilityChecker.openAccessibilitySettings())
        // does not crash when invoked outside of a running app context.
        // NSWorkspace.shared.open(_:) may fail silently
        // in the test environment — that's acceptable.
        let alert = AccessibilityOnboardingAlert.make()
        XCTAssertNoThrow(alert.primaryAction())
    }

    func testCustomOpenSettingsIsForwardedCorrectly() {
        var callCount = 0
        let alert = AccessibilityOnboardingAlert.make(openSettings: { callCount += 1 })
        alert.primaryAction()
        alert.primaryAction()
        XCTAssertEqual(callCount, 2)
    }
}
