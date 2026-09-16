import XCTest
@testable import ClipVault

/// Tests for Task 9: Export, drag-and-drop, delete-day, and storage reporting.
///
/// Covers:
/// - Export formatting for full day and selected rows
/// - ActivityExportCoordinator.formattedString for all three formats
/// - ActivityExportCoordinator.performWrite for flat and screenshot-bundled exports
/// - ActivityHistoryStore.deleteDay behavior (removes from days, clears loadedEvents)
/// - ActivityHistoryStore.storageBreakdown calculation
/// - ActivityHistorySidebarView.updateFooter breakdown (via formatBytes static helper)
final class ActivityCaptureTask9Tests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        appName: String = "Safari",
        bundleID: String = "com.apple.Safari",
        windowTitle: String = "Test Window",
        eventType: ActivityEventType = .leftClick,
        screenshotPath: String? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_744_376_400),
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            eventType: eventType,
            controlRole: "AXButton",
            controlName: "Submit",
            controlValue: nil,
            clickX: 100,
            clickY: 200,
            screenshotPath: screenshotPath
        )
    }

    private func writeEvents(_ events: [ActivityEvent], to logsDir: URL, dayString: String) throws {
        let logURL = logsDir.appendingPathComponent("\(dayString).jsonl")
        let lines = try events.map { try $0.jsonlLine() }.joined(separator: "\n") + "\n"
        try lines.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Task9-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - ActivityExportCoordinator: formattedString

    func testFormatterJSONL() {
        let coordinator = ActivityExportCoordinator()
        let events = [makeEvent(appName: "Xcode"), makeEvent(appName: "Safari")]
        let output = coordinator.formattedString(events: events, format: .jsonl)
        XCTAssertEqual(output.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
        XCTAssertTrue(output.contains("Xcode"))
        XCTAssertTrue(output.contains("Safari"))
    }

    func testFormatterCSV() {
        let coordinator = ActivityExportCoordinator()
        let events = [makeEvent(appName: "Finder")]
        let output = coordinator.formattedString(events: events, format: .csv)
        // CSV has a header row + 1 data row
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("appName"))
        XCTAssertTrue(lines[1].contains("Finder"))
    }

    func testFormatterPlainText() {
        let coordinator = ActivityExportCoordinator()
        let events = [makeEvent(appName: "Terminal", windowTitle: "bash")]
        let output = coordinator.formattedString(events: events, format: .plainText)
        XCTAssertTrue(output.contains("Terminal"))
        XCTAssertTrue(output.contains("bash"))
    }

    func testFormatterJSONLEmptyEvents() {
        let coordinator = ActivityExportCoordinator()
        let output = coordinator.formattedString(events: [], format: .jsonl)
        XCTAssertTrue(output.isEmpty)
    }

    // MARK: - ActivityExportCoordinator: performWrite (flat)

    func testPerformWriteJSONLToFile() throws {
        let coordinator = ActivityExportCoordinator()
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("out.jsonl")
        let events = [makeEvent(), makeEvent()]
        coordinator.performWrite(events: events, to: url, format: .jsonl, screenshotsURL: nil)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2)
    }

    func testPerformWriteCSVToFile() throws {
        let coordinator = ActivityExportCoordinator()
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("out.csv")
        coordinator.performWrite(events: [makeEvent()], to: url, format: .csv, screenshotsURL: nil)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("timestamp,"))
    }

    func testPerformWritePlainTextToFile() throws {
        let coordinator = ActivityExportCoordinator()
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("out.txt")
        coordinator.performWrite(events: [makeEvent(appName: "Slack")], to: url, format: .plainText, screenshotsURL: nil)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Slack"))
    }

    // MARK: - ActivityExportCoordinator: screenshot bundling

    func testPerformWriteJSONLBundlesScreenshots() throws {
        let coordinator = ActivityExportCoordinator()
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a fake screenshot file in a screenshots root.
        let screenshotsRoot = tempDir.appendingPathComponent("screenshots", isDirectory: true)
        let dayScreenshotsDir = screenshotsRoot.appendingPathComponent("2026-04-11", isDirectory: true)
        try FileManager.default.createDirectory(at: dayScreenshotsDir, withIntermediateDirectories: true)
        let screenshotFile = dayScreenshotsDir.appendingPathComponent("shot.jpg")
        try Data([0xFF, 0xD8]).write(to: screenshotFile)  // fake JPEG header

        let event = makeEvent(screenshotPath: "2026-04-11/shot.jpg")

        let exportDir = tempDir.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let exportURL = exportDir.appendingPathComponent("activity-2026-04-11.jsonl")

        coordinator.performWrite(events: [event], to: exportURL, format: .jsonl, screenshotsURL: screenshotsRoot)

        // Export should create a folder next to the chosen filename.
        let bundleFolderURL = exportURL.deletingPathExtension()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleFolderURL.path))

        // The data file should exist inside the bundle folder.
        let dataFile = bundleFolderURL.appendingPathComponent("activity-2026-04-11.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataFile.path))

        // Screenshot should be copied preserving the day subdirectory to avoid filename collisions
        // across multi-day exports (e.g. screenshots/2026-04-11/shot.jpg).
        let copiedShot = bundleFolderURL.appendingPathComponent("screenshots/2026-04-11/shot.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedShot.path))

        // The data file should contain rewritten path with day prefix preserved.
        let content = try String(contentsOf: dataFile, encoding: .utf8)
        XCTAssertTrue(content.contains("\"screenshots/2026-04-11/shot.jpg\""))
    }

    func testPerformWriteJSONLWithNoScreenshotsIsFlat() throws {
        let coordinator = ActivityExportCoordinator()
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("activity-2026-04-11.jsonl")
        coordinator.performWrite(events: [makeEvent()], to: url, format: .jsonl, screenshotsURL: nil)

        // Without screenshots, the file is written directly — no bundle folder created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let bundle = url.deletingPathExtension()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
    }

    // MARK: - Partial selection export

    func testExportSelectedRowsSubset() {
        let coordinator = ActivityExportCoordinator()
        // Use app names that are unambiguous substrings — they must not appear in shared
        // fields like controlRole ("AXButton") or controlName ("Submit").
        let all = [
            makeEvent(appName: "FirstApp"),
            makeEvent(appName: "SecondApp"),
            makeEvent(appName: "ThirdApp")
        ]
        let selected = [all[0], all[2]]
        let output = coordinator.formattedString(events: selected, format: .plainText)
        XCTAssertTrue(output.contains("FirstApp"))
        XCTAssertFalse(output.contains("SecondApp"))
        XCTAssertTrue(output.contains("ThirdApp"))
    }

    // MARK: - ActivityHistoryStore: deleteDay

    func testDeleteDayRemovesDayFromStore() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try writeEvents([makeEvent()], to: logsDir, dayString: "2026-04-11")
        try writeEvents([makeEvent()], to: logsDir, dayString: "2026-04-10")

        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        // Load the day list.
        let refreshExp = expectation(description: "refreshed")
        store.onDataChanged = { refreshExp.fulfill() }
        store.refreshDayList()
        wait(for: [refreshExp], timeout: 5)
        XCTAssertEqual(store.days.count, 2)

        // Delete one day.
        let deleteExp = expectation(description: "deleted")
        var callCount = 0
        store.onDataChanged = {
            callCount += 1
            if callCount == 1 { deleteExp.fulfill() }
        }
        store.deleteDay("2026-04-11")
        wait(for: [deleteExp], timeout: 5)

        XCTAssertEqual(store.days.count, 1)
        XCTAssertEqual(store.days[0].dayString, "2026-04-10")
    }

    func testDeleteDayClearsLoadedEventsIfSameDay() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try writeEvents([makeEvent(), makeEvent()], to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        // Load events for the day.
        let loadExp = expectation(description: "loaded")
        store.onDataChanged = { loadExp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [loadExp], timeout: 5)
        XCTAssertEqual(store.loadedEvents.count, 2)
        XCTAssertEqual(store.loadedDayString, "2026-04-11")

        // Delete that same day.
        let deleteExp = expectation(description: "deleted")
        var count = 0
        store.onDataChanged = {
            count += 1
            if count == 1 { deleteExp.fulfill() }
        }
        store.deleteDay("2026-04-11")
        wait(for: [deleteExp], timeout: 5)

        XCTAssertTrue(store.loadedEvents.isEmpty)
        XCTAssertNil(store.loadedDayString)
    }

    func testDeleteDayDoesNotClearLoadedEventsForDifferentDay() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try writeEvents([makeEvent()], to: logsDir, dayString: "2026-04-11")
        try writeEvents([makeEvent()], to: logsDir, dayString: "2026-04-10")

        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        // Load events for 2026-04-11.
        let loadExp = expectation(description: "loaded")
        store.onDataChanged = { loadExp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [loadExp], timeout: 5)
        XCTAssertEqual(store.loadedEvents.count, 1)

        // Delete a different day.
        let deleteExp = expectation(description: "deleted")
        var count = 0
        store.onDataChanged = {
            count += 1
            if count == 1 { deleteExp.fulfill() }
        }
        store.deleteDay("2026-04-10")
        wait(for: [deleteExp], timeout: 5)

        // loadedEvents should still contain the 2026-04-11 events.
        XCTAssertEqual(store.loadedEvents.count, 1)
        XCTAssertEqual(store.loadedDayString, "2026-04-11")
    }

    func testDeleteDayMovesLogFileToTrash() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("2026-04-11.jsonl")
        try writeEvents([makeEvent()], to: logsDir, dayString: "2026-04-11")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))

        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "deleted")
        store.deleteDay("2026-04-11") { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertFalse(FileManager.default.fileExists(atPath: logFile.path))
    }

    func testDeleteDayCallsCompletionWithNilOnSuccess() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // No files to delete — completion should still be called with nil.
        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "completed")
        store.deleteDay("2026-04-11") { error in
            XCTAssertNil(error)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - ActivityHistoryStore: storageBreakdown

    func testStorageBreakdownIsZeroWithNoSummaries() {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)
        let breakdown = store.storageBreakdown
        XCTAssertEqual(breakdown.logsBytes, 0)
        XCTAssertEqual(breakdown.screenshotsBytes, 0)
    }

    func testStorageBreakdownSumsCorrectly() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        // Write two days with known content.
        let content = "line1\nline2\n"
        try content.write(to: logsDir.appendingPathComponent("2026-04-11.jsonl"), atomically: true, encoding: .utf8)
        try content.write(to: logsDir.appendingPathComponent("2026-04-10.jsonl"), atomically: true, encoding: .utf8)

        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "refreshed")
        store.onDataChanged = { exp.fulfill() }
        store.refreshDayList()
        wait(for: [exp], timeout: 5)

        let breakdown = store.storageBreakdown
        // Each log file has the same content; total log bytes should be 2 * content bytes.
        let expectedLogBytes = Int64(content.data(using: .utf8)!.count * 2)
        XCTAssertEqual(breakdown.logsBytes, expectedLogBytes)
        XCTAssertEqual(breakdown.screenshotsBytes, 0)
    }

    func testScreenshotRootURLMatchesFolderAccess() {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let access = FakeActivityCaptureFolderAccessTask9(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)
        let expected = tempDir.appendingPathComponent("screenshots", isDirectory: true)
        XCTAssertEqual(store.screenshotRootURL, expected)
    }

    func testScreenshotRootURLIsNilWhenNoAccess() {
        let access = FakeActivityCaptureFolderAccessTask9(rootURL: nil)
        let store = ActivityHistoryStore(folderAccess: access)
        XCTAssertNil(store.screenshotRootURL)
    }

    // MARK: - ActivityHistorySidebarView: footer format (storage breakdown)

    func testFormatBytesForSmallValue() {
        XCTAssertEqual(ActivityHistorySidebarView.formatBytes(0), "0 B")
    }

    func testFormatBytesForKilobytes() {
        let result = ActivityHistorySidebarView.formatBytes(1536)
        XCTAssertTrue(result.contains("KB"))
    }

    func testFormatBytesForMegabytes() {
        let result = ActivityHistorySidebarView.formatBytes(3 * 1024 * 1024)
        XCTAssertTrue(result.contains("MB"))
    }

    // MARK: - ActivityExportCoordinator: format extensions

    func testFormatFileExtensions() {
        XCTAssertEqual(ActivityExportCoordinator.Format.jsonl.fileExtension, "jsonl")
        XCTAssertEqual(ActivityExportCoordinator.Format.csv.fileExtension, "csv")
        XCTAssertEqual(ActivityExportCoordinator.Format.plainText.fileExtension, "txt")
    }

    func testFormatRawValueMapping() {
        XCTAssertEqual(ActivityExportCoordinator.Format(rawValue: 0), .jsonl)
        XCTAssertEqual(ActivityExportCoordinator.Format(rawValue: 1), .csv)
        XCTAssertEqual(ActivityExportCoordinator.Format(rawValue: 2), .plainText)
        XCTAssertNil(ActivityExportCoordinator.Format(rawValue: 99))
    }
}

// MARK: - Fake folder provider

private struct FakeActivityCaptureFolderAccessTask9: ActivityHistoryFolderProvider {
    let rootURL: URL?
    var resolvedRootURL: URL? { rootURL }
    var logsURL: URL? { rootURL.map { $0.appendingPathComponent("logs", isDirectory: true) } }
    var screenshotsURL: URL? { rootURL.map { $0.appendingPathComponent("screenshots", isDirectory: true) } }
}
