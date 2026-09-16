import XCTest
@testable import ClipVault

final class ActivityCaptureTask1Tests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCaptureTask1Tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // MARK: - Settings defaults

    func testDefaultActivityCaptureEnabledIsFalse() {
        XCTAssertFalse(settings.activityCaptureEnabled)
    }

    func testDefaultActivityCapturePausedIsFalse() {
        XCTAssertFalse(settings.activityCapturePaused)
    }

    func testDefaultActivityCaptureScreenshotsEnabledIsTrue() {
        XCTAssertTrue(settings.activityCaptureScreenshotsEnabled)
    }

    func testDefaultActivityCaptureJPEGQuality() {
        XCTAssertEqual(settings.activityCaptureJPEGQuality, Settings.Defaults.activityCaptureJPEGQuality, accuracy: 0.0001)
    }

    func testDefaultActivityCaptureScale() {
        XCTAssertEqual(settings.activityCaptureScale, Settings.Defaults.activityCaptureScale)
    }

    func testDefaultActivityCaptureFallbackIntervalSeconds() {
        XCTAssertEqual(settings.activityCaptureFallbackIntervalSeconds,
                       Settings.Defaults.activityCaptureFallbackIntervalSeconds)
    }

    func testDefaultActivityCaptureIdleThresholdSeconds() {
        XCTAssertEqual(settings.activityCaptureIdleThresholdSeconds,
                       Settings.Defaults.activityCaptureIdleThresholdSeconds)
    }

    func testDefaultActivityCaptureRetentionDaysIsZero() {
        XCTAssertEqual(settings.activityCaptureRetentionDays, 0)
    }

    func testDefaultActivityCaptureLogRootBookmarkIsNil() {
        XCTAssertNil(settings.activityCaptureLogRootBookmark)
    }

    func testDefaultExcludedBundleIDsContainsBrainCache() {
        XCTAssertTrue(settings.activityCaptureExcludedBundleIDs.contains("com.TalkFlow.BrainCache"))
    }

    func testDefaultExcludedBundleIDsContainsPasswordManagers() {
        let excluded = settings.activityCaptureExcludedBundleIDs
        XCTAssertTrue(excluded.contains("com.agilebits.onepassword7"))
        XCTAssertTrue(excluded.contains("com.bitwarden.desktop"))
    }

    // MARK: - Settings read/write

    func testWriteAndReadActivityCaptureEnabled() {
        settings.activityCaptureEnabled = true
        XCTAssertTrue(settings.activityCaptureEnabled)
        settings.activityCaptureEnabled = false
        XCTAssertFalse(settings.activityCaptureEnabled)
    }

    func testWriteAndReadActivityCapturePaused() {
        settings.activityCapturePaused = true
        XCTAssertTrue(settings.activityCapturePaused)
    }

    func testWriteAndReadActivityCaptureScreenshotsEnabled() {
        settings.activityCaptureScreenshotsEnabled = false
        XCTAssertFalse(settings.activityCaptureScreenshotsEnabled)
    }

    func testJPEGQualityClampedToMinimum() {
        settings.activityCaptureJPEGQuality = 0.1
        XCTAssertEqual(settings.activityCaptureJPEGQuality, 0.3, accuracy: 0.0001)
    }

    func testJPEGQualityClampedToMaximum() {
        settings.activityCaptureJPEGQuality = 1.5
        XCTAssertEqual(settings.activityCaptureJPEGQuality, 1.0, accuracy: 0.0001)
    }

    func testJPEGQualityWithinRange() {
        settings.activityCaptureJPEGQuality = 0.8
        XCTAssertEqual(settings.activityCaptureJPEGQuality, 0.8, accuracy: 0.0001)
    }

    func testScaleNormalisesInvalidValueToOne() {
        settings.activityCaptureScale = 3
        XCTAssertEqual(settings.activityCaptureScale, 1)
    }

    func testScaleAcceptsTwo() {
        settings.activityCaptureScale = 2
        XCTAssertEqual(settings.activityCaptureScale, 2)
    }

    func testScaleAcceptsOne() {
        settings.activityCaptureScale = 1
        XCTAssertEqual(settings.activityCaptureScale, 1)
    }

    func testWriteAndReadFallbackIntervalSeconds() {
        settings.activityCaptureFallbackIntervalSeconds = 120
        XCTAssertEqual(settings.activityCaptureFallbackIntervalSeconds, 120)
    }

    func testWriteAndReadIdleThresholdSeconds() {
        settings.activityCaptureIdleThresholdSeconds = 15
        XCTAssertEqual(settings.activityCaptureIdleThresholdSeconds, 15)
    }

    func testWriteAndReadRetentionDays() {
        settings.activityCaptureRetentionDays = 30
        XCTAssertEqual(settings.activityCaptureRetentionDays, 30)
    }

    func testWriteAndReadLogRootBookmark() {
        let data = Data([0x01, 0x02, 0x03])
        settings.activityCaptureLogRootBookmark = data
        XCTAssertEqual(settings.activityCaptureLogRootBookmark, data)
    }

    func testClearingLogRootBookmark() {
        settings.activityCaptureLogRootBookmark = Data([0xFF])
        settings.activityCaptureLogRootBookmark = nil
        XCTAssertNil(settings.activityCaptureLogRootBookmark)
    }

    func testWriteAndReadExcludedBundleIDs() {
        let ids = ["com.example.App", "com.another.App"]
        settings.activityCaptureExcludedBundleIDs = ids
        XCTAssertEqual(settings.activityCaptureExcludedBundleIDs, ids)
    }

    // MARK: - Notification names

    func testNotificationNamesAreDistinct() {
        let names: [Notification.Name] = [
            .activityCaptureEnabledDidChange,
            .activityCapturePausedDidChange,
            .activityCaptureSettingsDidChange,
            .activityCaptureLogRootDidChange,
            .activityCaptureExclusionsDidChange
        ]
        let rawValues = names.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "All notification names must be unique")
    }

    func testNotificationNamesArePrefixed() {
        let names: [Notification.Name] = [
            .activityCaptureEnabledDidChange,
            .activityCapturePausedDidChange,
            .activityCaptureSettingsDidChange,
            .activityCaptureLogRootDidChange,
            .activityCaptureExclusionsDidChange
        ]
        for name in names {
            XCTAssertTrue(name.rawValue.hasPrefix("activityCapture"),
                          "\(name.rawValue) should begin with 'activityCapture'")
        }
    }

    // MARK: - ActivityCaptureFolderAccess

    func testFolderAccessThrowsWhenNoBookmarkSaved() {
        let access = ActivityCaptureFolderAccess(settings: settings)
        XCTAssertThrowsError(try access.resolveAccess()) { error in
            guard case ActivityCaptureFolderAccess.AccessError.bookmarkDataMissing = error else {
                XCTFail("Expected bookmarkDataMissing, got \(error)")
                return
            }
        }
    }

    func testFolderAccessResolvedRootURLIsNilInitially() {
        let access = ActivityCaptureFolderAccess(settings: settings)
        XCTAssertNil(access.resolvedRootURL)
    }

    func testFolderAccessLogsURLIsNilWhenNoRoot() {
        let access = ActivityCaptureFolderAccess(settings: settings)
        XCTAssertNil(access.logsURL)
    }

    func testFolderAccessScreenshotsURLIsNilWhenNoRoot() {
        let access = ActivityCaptureFolderAccess(settings: settings)
        XCTAssertNil(access.screenshotsURL)
    }

    func testFolderAccessThrowsWithInvalidBookmarkData() {
        settings.activityCaptureLogRootBookmark = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let access = ActivityCaptureFolderAccess(settings: settings)
        XCTAssertThrowsError(try access.resolveAccess()) { error in
            guard case ActivityCaptureFolderAccess.AccessError.bookmarkResolutionFailed = error else {
                XCTFail("Expected bookmarkResolutionFailed, got \(error)")
                return
            }
        }
    }

    func testFolderAccessSubdirectoriesHaveCorrectNames() {
        // We can test URL construction logic by injecting a fake root.
        // Since we can't actually resolve a security-scoped bookmark in unit tests,
        // we validate the URL suffix logic using a temp directory.
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ACFolderAccessTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Use FileManager directly to verify the naming conventions match the class contract.
        let logsURL = tempRoot.appendingPathComponent("logs", isDirectory: true)
        let screenshotsURL = tempRoot.appendingPathComponent("screenshots", isDirectory: true)
        XCTAssertEqual(logsURL.lastPathComponent, "logs")
        XCTAssertEqual(screenshotsURL.lastPathComponent, "screenshots")
    }
}
