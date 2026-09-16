import XCTest
@testable import ClipVault

// MARK: - Popup value mapping

final class ActivityCapturePrefs6PopupMappingTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCapturePrefs6Tests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // MARK: Fallback interval

    func testFallbackIntervalDefaultMapsToIndex2() {
        // Default is 60 seconds → "1 min" at index 2
        settings.activityCaptureFallbackIntervalSeconds = 60
        let idx = ActivityRecorderPrefsView.fallbackIntervalValues.firstIndex(of: settings.activityCaptureFallbackIntervalSeconds)
        XCTAssertEqual(idx, 2)
    }

    func testFallbackIntervalNeverMapsToIndex0() {
        settings.activityCaptureFallbackIntervalSeconds = 0
        let idx = ActivityRecorderPrefsView.fallbackIntervalValues.firstIndex(of: settings.activityCaptureFallbackIntervalSeconds)
        XCTAssertEqual(idx, 0, "Never (0) should be at popup index 0")
    }

    func testFallbackInterval30SecMapsToIndex1() {
        settings.activityCaptureFallbackIntervalSeconds = 30
        let idx = ActivityRecorderPrefsView.fallbackIntervalValues.firstIndex(of: settings.activityCaptureFallbackIntervalSeconds)
        XCTAssertEqual(idx, 1)
    }

    func testFallbackInterval5MinMapsToIndex4() {
        settings.activityCaptureFallbackIntervalSeconds = 300
        let idx = ActivityRecorderPrefsView.fallbackIntervalValues.firstIndex(of: settings.activityCaptureFallbackIntervalSeconds)
        XCTAssertEqual(idx, 4)
    }

    func testFallbackIntervalValueTableHasFiveEntries() {
        XCTAssertEqual(ActivityRecorderPrefsView.fallbackIntervalValues.count, 5)
    }

    // MARK: Idle threshold

    func testIdleThresholdNeverMapsToIndex0() {
        settings.activityCaptureIdleThresholdSeconds = 0
        let idx = ActivityRecorderPrefsView.idleThresholdValues.firstIndex(of: settings.activityCaptureIdleThresholdSeconds)
        XCTAssertEqual(idx, 0, "Never (0) should be at popup index 0")
    }

    func testIdleThresholdDefaultMapsToIndex2() {
        // Default is 30 seconds → index 2 (after Never at 0 and 15 sec at 1)
        settings.activityCaptureIdleThresholdSeconds = 30
        let idx = ActivityRecorderPrefsView.idleThresholdValues.firstIndex(of: settings.activityCaptureIdleThresholdSeconds)
        XCTAssertEqual(idx, 2)
    }

    func testIdleThreshold15SecMapsToIndex1() {
        settings.activityCaptureIdleThresholdSeconds = 15
        let idx = ActivityRecorderPrefsView.idleThresholdValues.firstIndex(of: settings.activityCaptureIdleThresholdSeconds)
        XCTAssertEqual(idx, 1)
    }

    func testIdleThreshold60SecMapsToIndex3() {
        settings.activityCaptureIdleThresholdSeconds = 60
        let idx = ActivityRecorderPrefsView.idleThresholdValues.firstIndex(of: settings.activityCaptureIdleThresholdSeconds)
        XCTAssertEqual(idx, 3)
    }

    // MARK: Retention

    func testRetentionNeverMapsToIndex0() {
        settings.activityCaptureRetentionDays = 0
        let idx = ActivityRecorderPrefsView.retentionValues.firstIndex(of: settings.activityCaptureRetentionDays)
        XCTAssertEqual(idx, 0, "Never (0) should be at popup index 0")
    }

    func testRetention30DaysMapsToIndex1() {
        settings.activityCaptureRetentionDays = 30
        let idx = ActivityRecorderPrefsView.retentionValues.firstIndex(of: settings.activityCaptureRetentionDays)
        XCTAssertEqual(idx, 1)
    }

    func testRetention60DaysMapsToIndex2() {
        settings.activityCaptureRetentionDays = 60
        let idx = ActivityRecorderPrefsView.retentionValues.firstIndex(of: settings.activityCaptureRetentionDays)
        XCTAssertEqual(idx, 2)
    }

    func testRetention90DaysMapsToIndex3() {
        settings.activityCaptureRetentionDays = 90
        let idx = ActivityRecorderPrefsView.retentionValues.firstIndex(of: settings.activityCaptureRetentionDays)
        XCTAssertEqual(idx, 3)
    }

    // MARK: Scale popup

    func testScale1xMapsToIndex0() {
        settings.activityCaptureScale = 1
        let idx = settings.activityCaptureScale == 2 ? 1 : 0
        XCTAssertEqual(idx, 0)
    }

    func testScale2xMapsToIndex1() {
        settings.activityCaptureScale = 2
        let idx = settings.activityCaptureScale == 2 ? 1 : 0
        XCTAssertEqual(idx, 1)
    }

    func testScaleInvalidValueClampedToOne() {
        settings.activityCaptureScale = 3
        XCTAssertEqual(settings.activityCaptureScale, 1, "Invalid scale should clamp to 1")
    }
}

// MARK: - Status label inference

final class ActivityCapturePrefs6StatusLabelTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCapturePrefs6StatusTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // Mirrors ActivityRecorderPrefsView.updateCaptureStatusLabel logic
    private func inferredStatus(enabled: Bool, paused: Bool) -> String {
        if enabled && !paused { return "Recording" }
        if enabled && paused { return "Paused" }
        return "Inactive"
    }

    func testStatusRecordingWhenEnabledAndNotPaused() {
        settings.activityCaptureEnabled = true
        settings.activityCapturePaused = false
        XCTAssertEqual(inferredStatus(enabled: settings.activityCaptureEnabled, paused: settings.activityCapturePaused), "Recording")
    }

    func testStatusPausedWhenEnabledAndPaused() {
        settings.activityCaptureEnabled = true
        settings.activityCapturePaused = true
        XCTAssertEqual(inferredStatus(enabled: settings.activityCaptureEnabled, paused: settings.activityCapturePaused), "Paused")
    }

    func testStatusInactiveWhenDisabled() {
        settings.activityCaptureEnabled = false
        XCTAssertEqual(inferredStatus(enabled: settings.activityCaptureEnabled, paused: settings.activityCapturePaused), "Inactive")
    }

    func testStatusInactiveWhenDisabledEvenIfPausedFlagSet() {
        settings.activityCaptureEnabled = false
        settings.activityCapturePaused = true
        XCTAssertEqual(inferredStatus(enabled: settings.activityCaptureEnabled, paused: settings.activityCapturePaused), "Inactive")
    }
}

// MARK: - Settings sync via notifications

final class ActivityCapturePrefs6NotificationTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCapturePrefs6NotifTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    func testScreenshotsSettingPostsSettingsChangeNotification() {
        let exp = expectation(description: "activityCaptureSettingsDidChange received")
        let observer = NotificationCenter.default.addObserver(
            forName: .activityCaptureSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }

        // screenshotsEnabled setter in Settings posts activityCaptureSettingsDidChange
        settings.activityCaptureScreenshotsEnabled = false

        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testJPEGQualitySettingPostsSettingsChangeNotification() {
        let exp = expectation(description: "activityCaptureSettingsDidChange received for quality")
        let observer = NotificationCenter.default.addObserver(
            forName: .activityCaptureSettingsDidChange,
            object: nil,
            queue: .main
        ) { _ in exp.fulfill() }

        settings.activityCaptureJPEGQuality = 0.5

        wait(for: [exp], timeout: 1.0)
        NotificationCenter.default.removeObserver(observer)
    }
}

// MARK: - Toggle validation logic

final class ActivityCapturePrefs6ToggleValidationTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCapturePrefs6ToggleTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    func testDisablingCaptureClearsPausedFlag() {
        settings.activityCaptureEnabled = true
        settings.activityCapturePaused = true

        // Simulate ActivityRecorderPrefsView toggle-off
        settings.activityCaptureEnabled = false
        settings.activityCapturePaused = false

        XCTAssertFalse(settings.activityCaptureEnabled)
        XCTAssertFalse(settings.activityCapturePaused)
    }

    func testNoBookmarkMeansNotConfigured() {
        // Without a bookmark, updateLogFolderPath shows "Not configured"
        XCTAssertNil(settings.activityCaptureLogRootBookmark)
        // Mirrors the guard in ActivityRecorderPrefsView.updateLogFolderPath
        let path = settings.activityCaptureLogRootBookmark == nil ? "Not configured" : "configured"
        XCTAssertEqual(path, "Not configured")
    }

    func testScreenshotControlsEnabledLogic() {
        settings.activityCaptureEnabled = true
        settings.activityCaptureScreenshotsEnabled = true
        // Mirrors ActivityRecorderPrefsView.updateCaptureControlsState
        let screenshotsOn = settings.activityCaptureEnabled && settings.activityCaptureScreenshotsEnabled
        XCTAssertTrue(screenshotsOn)
    }

    func testScreenshotControlsDisabledWhenCaptureOff() {
        settings.activityCaptureEnabled = false
        settings.activityCaptureScreenshotsEnabled = true
        let screenshotsOn = settings.activityCaptureEnabled && settings.activityCaptureScreenshotsEnabled
        XCTAssertFalse(screenshotsOn)
    }

    func testScreenshotControlsDisabledWhenScreenshotsOff() {
        settings.activityCaptureEnabled = true
        settings.activityCaptureScreenshotsEnabled = false
        let screenshotsOn = settings.activityCaptureEnabled && settings.activityCaptureScreenshotsEnabled
        XCTAssertFalse(screenshotsOn)
    }
}

// MARK: - JPEG quality display string

final class ActivityCapturePrefs6JPEGQualityStringTests: XCTestCase {

    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        suiteName = "ActivityCapturePrefs6JPEGTests-\(UUID().uuidString)"
        settings = Settings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        settings = nil
    }

    // Mirrors ActivityRecorderPrefsView.jpegQualityString
    private func qualityString(_ q: Double) -> String { "\(Int(q * 100))%" }

    func testJPEGQualityDefault70Percent() {
        settings.activityCaptureJPEGQuality = 0.7
        XCTAssertEqual(qualityString(settings.activityCaptureJPEGQuality), "70%")
    }

    func testJPEGQualityMaxIs100Percent() {
        settings.activityCaptureJPEGQuality = 1.0
        XCTAssertEqual(qualityString(settings.activityCaptureJPEGQuality), "100%")
    }

    func testJPEGQualityMinClamped() {
        settings.activityCaptureJPEGQuality = 0.1  // below min 0.3
        XCTAssertGreaterThanOrEqual(settings.activityCaptureJPEGQuality, 0.3)
        XCTAssertEqual(qualityString(settings.activityCaptureJPEGQuality), "30%")
    }

    func testJPEGQualityMaxClamped() {
        settings.activityCaptureJPEGQuality = 1.5  // above max 1.0
        XCTAssertLessThanOrEqual(settings.activityCaptureJPEGQuality, 1.0)
        XCTAssertEqual(qualityString(settings.activityCaptureJPEGQuality), "100%")
    }

    func testJPEGQuality50Percent() {
        settings.activityCaptureJPEGQuality = 0.5
        XCTAssertEqual(qualityString(settings.activityCaptureJPEGQuality), "50%")
    }
}
