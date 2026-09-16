import XCTest
@testable import ClipVault

final class AccessibilityCheckerTests: XCTestCase {

    // MARK: - accessibilitySettingsURL

    func testURLForMacOS13ReturnsNewSettingsScheme() {
        let version = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
    }

    func testURLForMacOS14ReturnsNewSettingsScheme() {
        let version = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
    }

    func testURLForMacOS15ReturnsNewSettingsScheme() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        )
    }

    func testURLForMacOS12ReturnsLegacyPreferencesScheme() {
        let version = OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testURLForMacOS11ReturnsLegacyPreferencesScheme() {
        let version = OperatingSystemVersion(majorVersion: 11, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    func testURLDefaultParameterReturnsValidURL() {
        // Calling without an explicit version uses the current OS — just verify it returns a non-nil URL.
        let url = AccessibilityChecker.accessibilitySettingsURL()
        XCTAssertNotNil(url)
    }

    func testURLSchemeIsXAppleSystemPreferences() {
        for major in [11, 12, 13, 14, 15] {
            let version = OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0)
            let url = AccessibilityChecker.accessibilitySettingsURL(osVersion: version)
            XCTAssertEqual(url?.scheme, "x-apple.systempreferences", "major \(major)")
        }
    }

    // MARK: - screenRecordingSettingsURL

    func testScreenRecordingURLForMacOS13ReturnsNewSettingsScheme() {
        let version = OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.screenRecordingSettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
    }

    func testScreenRecordingURLForMacOS15ReturnsNewSettingsScheme() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.screenRecordingSettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        )
    }

    func testScreenRecordingURLForMacOS12ReturnsLegacyPreferencesScheme() {
        let version = OperatingSystemVersion(majorVersion: 12, minorVersion: 0, patchVersion: 0)
        let url = AccessibilityChecker.screenRecordingSettingsURL(osVersion: version)
        XCTAssertNotNil(url)
        XCTAssertEqual(
            url?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testScreenRecordingURLDefaultParameterReturnsValidURL() {
        let url = AccessibilityChecker.screenRecordingSettingsURL()
        XCTAssertNotNil(url)
    }
}
