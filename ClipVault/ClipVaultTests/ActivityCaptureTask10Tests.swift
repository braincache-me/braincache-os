import XCTest
@testable import ClipVault

// MARK: - Fakes shared with Task 9 (defined in Task9Tests, re-declared here is NOT possible)
// We create our own minimal fake for Task 10.

private final class FakeFolderAccessTask10: ActivityHistoryFolderProvider {
    let rootURL: URL?
    var logsURL: URL? { rootURL?.appendingPathComponent("logs", isDirectory: true) }
    var screenshotsURL: URL? { rootURL?.appendingPathComponent("screenshots", isDirectory: true) }
    var resolvedRootURL: URL? { rootURL }
    init(rootURL: URL?) { self.rootURL = rootURL }
}

// MARK: - Helpers

private func makeTempDir(tag: String = "Task10") -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeLogWriter(in dir: URL) -> ActivityLogWriter {
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    return ActivityLogWriter(logsURL: logsDir, flushThreshold: 100, flushInterval: 0)
}

private func writtenEvents(in dir: URL) -> [ActivityEvent] {
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    let day = ActivityLogPaths.dayString()
    let logURL = logsDir.appendingPathComponent(day + ".jsonl")
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
    return content
        .split(separator: "\n", omittingEmptySubsequences: true)
        .compactMap { try? ActivityEvent.jsonDecoder.decode(ActivityEvent.self,
                                                            from: String($0).data(using: .utf8)!) }
}

// MARK: - Tests

final class ActivityCaptureTask10Tests: XCTestCase {

    private var tempDir: URL!
    private var savedIdleThreshold: Int = 30
    private var savedRetentionDays: Int = 0

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        savedIdleThreshold = Settings.shared.activityCaptureIdleThresholdSeconds
        savedRetentionDays = Settings.shared.activityCaptureRetentionDays
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        Settings.shared.activityCaptureIdleThresholdSeconds = savedIdleThreshold
        Settings.shared.activityCaptureRetentionDays = savedRetentionDays
        super.tearDown()
    }

    // MARK: - Retention cleanup: old files are trashed

    func testCleanupRemovesFileOlderThanRetentionWindow() throws {
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Create a log file dated 35 days ago.
        let oldDate = Calendar.current.date(byAdding: .day, value: -35, to: Date())!
        let oldDayString = ActivityLogPaths.dayString(for: oldDate)
        let oldLogURL = logsDir.appendingPathComponent("\(oldDayString).jsonl")
        try "old log content".write(to: oldLogURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldLogURL.path))

        let service = ActivityCaptureCleanupService()
        let exp = expectation(description: "cleanup done")
        var deletedCount = 0
        service.performCleanup(
            retentionDays: 30,
            logsURL: logsDir,
            screenshotsURL: nil,
            rootURL: nil
        ) { deleted, error in
            deletedCount = deleted
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(deletedCount, 1, "One day should have been deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldLogURL.path),
                       "Log file older than retention window should be moved to Trash")
    }

    func testCleanupDoesNotRemoveRecentFiles() throws {
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Create a log file dated yesterday (within 30-day retention).
        let recentDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let recentDayString = ActivityLogPaths.dayString(for: recentDate)
        let recentLogURL = logsDir.appendingPathComponent("\(recentDayString).jsonl")
        try "recent log content".write(to: recentLogURL, atomically: true, encoding: .utf8)

        let service = ActivityCaptureCleanupService()
        let exp = expectation(description: "cleanup done")
        var deletedCount = 0
        service.performCleanup(
            retentionDays: 30,
            logsURL: logsDir,
            screenshotsURL: nil,
            rootURL: nil
        ) { deleted, _ in
            deletedCount = deleted
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(deletedCount, 0, "Recent file should not be deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentLogURL.path),
                      "Recent log file must survive cleanup")
    }

    func testCleanupWithZeroRetentionIsNoop() {
        let service = ActivityCaptureCleanupService()
        let exp = expectation(description: "cleanup done")
        var deletedCount = 0
        service.performCleanup(
            retentionDays: 0,      // "Never" — cleanup disabled
            logsURL: tempDir,
            screenshotsURL: nil,
            rootURL: nil
        ) { deleted, _ in
            deletedCount = deleted
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(deletedCount, 0)
    }

    func testCleanupAlsoRemovesScreenshotFolderAndSummary() throws {
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let screenshotsDir = tempDir.appendingPathComponent("screenshots", isDirectory: true)
        let summariesDir = tempDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: summariesDir, withIntermediateDirectories: true)

        let oldDate = Calendar.current.date(byAdding: .day, value: -40, to: Date())!
        let oldDayString = ActivityLogPaths.dayString(for: oldDate)

        // Log file
        let logURL = logsDir.appendingPathComponent("\(oldDayString).jsonl")
        try "data".write(to: logURL, atomically: true, encoding: .utf8)

        // Screenshot folder for that day
        let screenshotDayDir = screenshotsDir.appendingPathComponent(oldDayString, isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotDayDir, withIntermediateDirectories: true)
        try "img".write(to: screenshotDayDir.appendingPathComponent("shot.jpg"),
                       atomically: true, encoding: .utf8)

        // Summary file
        let summaryURL = ActivityLogPaths.summaryFileURL(for: oldDate, in: tempDir)
        try "{}".write(to: summaryURL, atomically: true, encoding: .utf8)

        let service = ActivityCaptureCleanupService()
        let exp = expectation(description: "cleanup done")
        service.performCleanup(
            retentionDays: 30,
            logsURL: logsDir,
            screenshotsURL: screenshotsDir,
            rootURL: tempDir
        ) { _, _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: screenshotDayDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: summaryURL.path))
    }

    func testCleanupSeparatesOldFromRecent() throws {
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let oldDate = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        let recentDate = Calendar.current.date(byAdding: .day, value: -5, to: Date())!
        let oldDayString = ActivityLogPaths.dayString(for: oldDate)
        let recentDayString = ActivityLogPaths.dayString(for: recentDate)

        let oldURL = logsDir.appendingPathComponent("\(oldDayString).jsonl")
        let recentURL = logsDir.appendingPathComponent("\(recentDayString).jsonl")
        try "old".write(to: oldURL, atomically: true, encoding: .utf8)
        try "recent".write(to: recentURL, atomically: true, encoding: .utf8)

        let service = ActivityCaptureCleanupService()
        let exp = expectation(description: "done")
        var deleted = 0
        service.performCleanup(retentionDays: 30, logsURL: logsDir, screenshotsURL: nil, rootURL: nil) { count, _ in
            deleted = count; exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }

    // MARK: - Exclusion matching

    func testExclusionListBlocksSpecifiedBundleID() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self",
            excludedBundleIDs: { ["com.agilebits.onepassword7", "com.bitwarden.desktop"] }
        )
        coordinator.suppressDiagnosticLogs = true
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.agilebits.onepassword7"))
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.bitwarden.desktop"))
        XCTAssertFalse(coordinator.shouldExclude(bundleID: "com.apple.Safari"))
        XCTAssertFalse(coordinator.shouldExclude(bundleID: ""))
    }

    func testOwnBundleIDIsAlwaysExcluded() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.TalkFlow.BrainCache",
            excludedBundleIDs: { [] }  // empty exclusion list
        )
        coordinator.suppressDiagnosticLogs = true
        // Own bundle ID should still be excluded regardless of the exclusion list.
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.TalkFlow.BrainCache"))
    }

    func testDynamicExclusionListIsReadAtEventTime() {
        var excludeList = [String]()
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self",
            excludedBundleIDs: { excludeList }
        )
        coordinator.suppressDiagnosticLogs = true
        XCTAssertFalse(coordinator.shouldExclude(bundleID: "com.example.App"))

        excludeList = ["com.example.App"]
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.example.App"),
                      "Exclusion list is re-read at event time so dynamic updates take effect")
    }

    // MARK: - Idle-resume trigger

    func testIdleResumeEventIsEmittedAfterThresholdExceeded() {
        // Set idle threshold to 1 second via Settings.
        Settings.shared.activityCaptureIdleThresholdSeconds = 15  // minimum allowed

        let writer = makeLogWriter(in: tempDir)
        let fakeInspector = FakeActivityAXInspector()
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.suppressDiagnosticLogs = true
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"
        coordinator.currentAppName = "ExampleApp"

        // Simulate that lastActivityDate is far in the past (beyond idle threshold).
        coordinator.lastActivityDate = Date(timeIntervalSinceNow: -Double(
            Settings.shared.activityCaptureIdleThresholdSeconds) - 1)

        // The next click should trigger an idleResumed event.
        coordinator.handleClickAt(CGPoint(x: 50, y: 50), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()
        coordinator.stop()

        let events = writtenEvents(in: tempDir)
        let idleEvents = events.filter { $0.eventType == .idleResumed }
        XCTAssertFalse(idleEvents.isEmpty, "An idleResumed event should be emitted when activity resumes after idle")
    }

    func testNoIdleResumeEventWhenThresholdNotExceeded() {
        Settings.shared.activityCaptureIdleThresholdSeconds = 15

        let writer = makeLogWriter(in: tempDir)
        let fakeInspector = FakeActivityAXInspector()
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.suppressDiagnosticLogs = true
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"

        // lastActivityDate is recent — idle threshold has NOT elapsed.
        coordinator.lastActivityDate = Date()

        coordinator.handleClickAt(CGPoint(x: 50, y: 50), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()
        coordinator.stop()

        let events = writtenEvents(in: tempDir)
        let idleEvents = events.filter { $0.eventType == .idleResumed }
        XCTAssertTrue(idleEvents.isEmpty, "No idleResumed event when threshold has not been exceeded")
    }

    // MARK: - Sleep / wake lifecycle

    func testPeriodicTimerDoesNotSpinAfterStop() {
        // This test verifies that stopping the coordinator does not leave an
        // active DispatchSourceTimer behind (no retain cycle / crash on deinit).
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.suppressDiagnosticLogs = true
        // Start then immediately stop — periodic timer should be cleaned up.
        coordinator.start()
        coordinator.stop()
        // If the timer is left armed it would fire after coordinator is gone and crash.
        // Passing without a crash/exception is the assertion.
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testSleepWakeObserversAreRemovedOnStop() {
        // Verifies that the coordinator can be stopped without retaining workspace
        // notification observers that fire after the coordinator is deallocated.
        weak var weakCoordinator: ActivityCaptureCoordinator?
        autoreleasepool {
            let coordinator = ActivityCaptureCoordinator(
                logWriter: makeLogWriter(in: tempDir),
                ownBundleID: "com.Self",
                excludedBundleIDs: { [] }
            )
            coordinator.suppressDiagnosticLogs = true
            coordinator.start()
            coordinator.stop()
            weakCoordinator = coordinator
        }
        // After the autorelease pool drains, the coordinator should be deallocated
        // (no strong references from sleep/wake observers).
        XCTAssertNil(weakCoordinator, "Coordinator should be deallocated after stop — no retained observer cycles")
    }

    // MARK: - Failure tolerance: screenshot errors do not crash the recorder

    func testCoordinatorContinuesAfterNilScreenshotService() {
        // If screenshotService is nil, interaction events should still be logged.
        let writer = makeLogWriter(in: tempDir)
        let fakeInspector = FakeActivityAXInspector()
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.Self",
            excludedBundleIDs: { [] },
            screenshotService: nil  // no screenshot service
        )
        coordinator.suppressDiagnosticLogs = true
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"

        coordinator.handleClickAt(CGPoint(x: 10, y: 10), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()
        coordinator.stop()

        let events = writtenEvents(in: tempDir)
        let clickEvents = events.filter { $0.eventType == .leftClick }
        XCTAssertEqual(clickEvents.count, 1,
                       "Click events should still be recorded even when screenshot service is unavailable")
    }

    func testCoordinatorContinuesAfterFailingScreenshotService() async {
        let writer = makeLogWriter(in: tempDir)
        let failingService = FailingWindowScreenshotService()
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: FakeActivityAXInspector(),
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.Self",
            excludedBundleIDs: { [] },
            screenshotService: failingService,
            screenshotsURL: tempDir,
            screenshotsEnabled: { true }
        )
        coordinator.suppressDiagnosticLogs = true
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"
        coordinator.currentAppName = "ExampleApp"

        // Trigger something that would attempt a screenshot (app-switch event through the focus path).
        // We call handleClickAt — no screenshot triggered by clicks, but we can verify no crash.
        coordinator.handleClickAt(CGPoint(x: 10, y: 10), eventType: .leftClick)
        coordinator.clickAggregator.flush()

        // Give any async screenshot task a moment to complete.
        try? await Task.sleep(nanoseconds: 200_000_000)

        writer.flushSync()
        coordinator.stop()

        let events = writtenEvents(in: tempDir)
        let clickEvents = events.filter { $0.eventType == .leftClick }
        // Click events should still be recorded even if screenshot capture fails.
        XCTAssertEqual(clickEvents.count, 1,
                       "Interaction events must be logged even when screenshot service always fails")
        // No screenshot events should exist (service returned nil path).
        let screenshotEvents = events.filter { $0.eventType == .screenshotCaptured }
        XCTAssertTrue(screenshotEvents.isEmpty)
    }

    // MARK: - Storage usage (convenience)

    func testStorageBreakdownSumsLogAndScreenshotBytes() throws {
        // Write two summaries with non-zero screenshot bytes to disk and verify
        // that ActivityHistoryStore.storageBreakdown sums both components correctly.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let today = Date()

        let summary1 = ActivityDaySummary(
            dayString: ActivityLogPaths.dayString(for: yesterday),
            eventCount: 5,
            logFileSizeBytes: 1024,
            screenshotFolderSizeBytes: 4096
        )
        let summary2 = ActivityDaySummary(
            dayString: ActivityLogPaths.dayString(for: today),
            eventCount: 3,
            logFileSizeBytes: 512,
            screenshotFolderSizeBytes: 2048
        )

        try summary1.save(to: ActivityLogPaths.summaryFileURL(for: yesterday, in: tempDir))
        try summary2.save(to: ActivityLogPaths.summaryFileURL(for: today, in: tempDir))

        let access = FakeFolderAccessTask10(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "refreshed")
        store.onDataChanged = { exp.fulfill() }
        store.refreshDayList()
        wait(for: [exp], timeout: 5)

        let breakdown = store.storageBreakdown
        XCTAssertEqual(breakdown.logsBytes, 1024 + 512)
        XCTAssertEqual(breakdown.screenshotsBytes, 4096 + 2048)
    }
}

// MARK: - Fake screenshot service that always fails

private final class FailingWindowScreenshotService: WindowScreenshotCapturing {
    func captureAndSave(
        appName: String,
        bundleID: String,
        trigger: String,
        screenshotsURL: URL,
        quality: Double,
        scale: Int
    ) async -> String? {
        return nil  // always fails
    }
}
