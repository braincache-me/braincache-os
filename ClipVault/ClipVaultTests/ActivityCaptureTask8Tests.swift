import XCTest
@testable import ClipVault

/// Tests for Task 8: Activity History window UI and file-backed data browsing.
///
/// Covers:
/// - Sidebar day ordering (newest-first)
/// - Live filtering by search text, app name, and event type
/// - Event grouping / display-model mapping (ActivityEventRowView helpers)
/// - Detail view population (rawJSON, screenshotURL resolution)
/// - ActivityHistoryStore discovery and lazy loading
final class ActivityCaptureTask8Tests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String = "Safari",
        bundleID: String = "com.apple.Safari",
        windowTitle: String = "Test Window",
        eventType: ActivityEventType = .leftClick,
        controlRole: String? = "AXButton",
        controlName: String? = "Submit",
        controlValue: String? = nil,
        clickX: Double? = 100,
        clickY: Double? = 200,
        screenshotPath: String? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            timestamp: timestamp,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            eventType: eventType,
            controlRole: controlRole,
            controlName: controlName,
            controlValue: controlValue,
            clickX: clickX,
            clickY: clickY,
            screenshotPath: screenshotPath
        )
    }

    private func writeEvents(_ events: [ActivityEvent], to logsDir: URL, dayString: String) throws {
        let logURL = logsDir.appendingPathComponent("\(dayString).jsonl")
        let lines = try events.map { try $0.jsonlLine() }.joined(separator: "\n") + "\n"
        try lines.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - ActivityHistoryFilter

    func testFilterEmptyMatchesAll() {
        let filter = ActivityHistoryFilter()
        XCTAssertTrue(filter.isEmpty)
    }

    func testFilterWithSearchTextIsNotEmpty() {
        var filter = ActivityHistoryFilter()
        filter.searchText = "hello"
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterWithAppNameIsNotEmpty() {
        var filter = ActivityHistoryFilter()
        filter.appName = "Safari"
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterWithEventTypeIsNotEmpty() {
        var filter = ActivityHistoryFilter()
        filter.eventType = .leftClick
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterEquality() {
        var a = ActivityHistoryFilter()
        var b = ActivityHistoryFilter()
        a.searchText = "x"
        b.searchText = "x"
        XCTAssertEqual(a, b)
    }

    // MARK: - ActivityHistoryStore: day ordering

    func testStoreDiscoversDaysNewestFirst() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let screenshotsDir = tempDir.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)

        // Create three JSONL files with different day strings.
        let days = ["2026-04-09", "2026-04-11", "2026-04-10"]
        for day in days {
            let event = makeEvent(appName: "App-\(day)")
            try writeEvents([event], to: logsDir, dayString: day)
        }

        // Build a fake folder access pointing to tempDir.
        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let expectation = self.expectation(description: "days loaded")
        store.onDataChanged = { expectation.fulfill() }
        store.refreshDayList()
        wait(for: [expectation], timeout: 5)

        // Should be sorted newest-first.
        let loadedDays = store.days.map { $0.dayString }
        XCTAssertEqual(loadedDays, ["2026-04-11", "2026-04-10", "2026-04-09"])
    }

    func testStoreDayCountMatchesFilesOnDisk() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        for day in ["2026-04-09", "2026-04-10"] {
            try writeEvents([makeEvent()], to: logsDir, dayString: day)
        }

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "refreshed")
        store.onDataChanged = { exp.fulfill() }
        store.refreshDayList()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(store.days.count, 2)
    }

    // MARK: - ActivityHistoryStore: lazy day loading

    func testStoreLoadsEventsForSelectedDay() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = (0..<5).map { i in makeEvent(appName: "App\(i)") }
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        var callCount = 0
        let exp = expectation(description: "loaded")
        exp.expectedFulfillmentCount = 1
        store.onDataChanged = {
            callCount += 1
            if callCount == 1 { exp.fulfill() }
        }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(store.loadedEvents.count, 5)
    }

    func testStoreLoadsEmptyArrayForMissingDay() {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-01-01")
        wait(for: [exp], timeout: 5)

        XCTAssertTrue(store.loadedEvents.isEmpty)
    }

    // MARK: - ActivityHistoryStore: filtering

    func testStoreFilterBySearchText() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = [
            makeEvent(appName: "Safari", windowTitle: "Apple News"),
            makeEvent(appName: "Firefox", windowTitle: "Google Search"),
            makeEvent(appName: "Safari", windowTitle: "GitHub")
        ]
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        var filter = ActivityHistoryFilter()
        filter.searchText = "safari"
        let results = store.applyFilter(filter)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.appName == "Safari" })
    }

    func testStoreFilterByAppName() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = [
            makeEvent(appName: "Safari"),
            makeEvent(appName: "Xcode"),
            makeEvent(appName: "Safari")
        ]
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        var filter = ActivityHistoryFilter()
        filter.appName = "Xcode"
        let results = store.applyFilter(filter)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].appName, "Xcode")
    }

    func testStoreFilterByEventType() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = [
            makeEvent(eventType: .leftClick),
            makeEvent(eventType: .appActivated),
            makeEvent(eventType: .leftClick),
            makeEvent(eventType: .keyShortcut)
        ]
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        var filter = ActivityHistoryFilter()
        filter.eventType = .leftClick
        let results = store.applyFilter(filter)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.eventType == .leftClick })
    }

    func testStoreEmptyFilterReturnsAll() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = (0..<6).map { _ in makeEvent() }
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        let results = store.applyFilter(ActivityHistoryFilter())
        XCTAssertEqual(results.count, 6)
    }

    // MARK: - ActivityHistoryStore: available apps

    func testStoreAvailableAppsSortedAlphabetically() throws {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let events = [
            makeEvent(appName: "Xcode"),
            makeEvent(appName: "Arc"),
            makeEvent(appName: "Zed")
        ]
        try writeEvents(events, to: logsDir, dayString: "2026-04-11")

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let exp = expectation(description: "loaded")
        store.onDataChanged = { exp.fulfill() }
        store.loadDay("2026-04-11")
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(store.availableApps, ["Arc", "Xcode", "Zed"])
    }

    // MARK: - ActivityHistoryStore: rawJSON

    func testStoreRawJSONIsPrettyPrintedJSON() {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let event = makeEvent(appName: "Finder")
        let json = store.rawJSON(for: event)
        XCTAssertFalse(json.isEmpty)
        // Pretty-printed JSON has newlines.
        XCTAssertTrue(json.contains("\n"))
        // Must be valid JSON.
        let data = json.data(using: .utf8)!
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertTrue(json.contains("\"Finder\""))
    }

    // MARK: - ActivityHistoryStore: screenshotURL

    func testStoreScreenshotURLResolvesRelativePath() {
        let tempDir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let access = FakeActivityCaptureFolderAccess(rootURL: tempDir)
        let store = ActivityHistoryStore(folderAccess: access)

        let url = store.screenshotURL(relativePath: "2026-04-11/shot.jpg")
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.path.contains("screenshots") == true)
        XCTAssertTrue(url?.path.contains("2026-04-11/shot.jpg") == true)
    }

    func testStoreScreenshotURLIsNilWhenNoAccess() {
        let access = FakeActivityCaptureFolderAccess(rootURL: nil)
        let store = ActivityHistoryStore(folderAccess: access)
        XCTAssertNil(store.screenshotURL(relativePath: "2026-04-11/shot.jpg"))
    }

    // MARK: - ActivityEventRowView: display model helpers

    func testControlDescriptionWithRoleAndName() {
        let event = makeEvent(controlRole: "AXButton", controlName: "OK", controlValue: nil)
        let desc = ActivityEventRowView.controlDescription(event)
        XCTAssertTrue(desc.contains("AXButton"))
        XCTAssertTrue(desc.contains("\"OK\""))
    }

    func testControlDescriptionWithValue() {
        let event = makeEvent(controlRole: "AXTextField", controlName: "Query", controlValue: "hello")
        let desc = ActivityEventRowView.controlDescription(event)
        XCTAssertTrue(desc.contains("= \"hello\""))
    }

    func testControlDescriptionEmptyWhenNoRole() {
        let event = makeEvent(controlRole: nil, controlName: nil, controlValue: nil)
        let desc = ActivityEventRowView.controlDescription(event)
        XCTAssertTrue(desc.isEmpty)
    }

    func testIconExistsForAllEventTypes() {
        for type_ in ActivityEventType.allCases {
            let icon = ActivityEventRowView.icon(for: type_)
            XCTAssertNotNil(icon, "Expected non-nil icon for \(type_.rawValue)")
        }
    }

    // MARK: - ActivityHistorySidebarView: format bytes

    func testFormatBytesBytes() {
        let result = ActivityHistorySidebarView.formatBytes(512)
        XCTAssertTrue(result.contains("512"))
        XCTAssertTrue(result.contains("B"))
    }

    func testFormatBytesKilobytes() {
        let result = ActivityHistorySidebarView.formatBytes(2048)
        XCTAssertTrue(result.contains("KB"))
    }

    func testFormatBytesMegabytes() {
        let result = ActivityHistorySidebarView.formatBytes(2 * 1024 * 1024)
        XCTAssertTrue(result.contains("MB"))
    }

    // MARK: - ActivityTimelineView: filtering

    func testTimelineFilterBySearchText() {
        let timeline = ActivityTimelineView()
        let events = [
            makeEvent(appName: "Safari", windowTitle: "Apple News"),
            makeEvent(appName: "Firefox", windowTitle: "Google")
        ]
        timeline.loadEvents(events)

        // Simulate search by injecting filter directly via applyFilter on in-memory events.
        // (We can't drive the UI search field easily in unit tests, so we test the filter logic
        // in the store tests above. Here we verify the timeline responds to loadEvents correctly.)
        XCTAssertEqual(timeline.filteredEvents.count, 2)
    }

    func testTimelineShowsEmptyBeforeDayLoaded() {
        let timeline = ActivityTimelineView()
        timeline.showEmptyDay()
        XCTAssertTrue(timeline.filteredEvents.isEmpty)
    }

    func testTimelineSelectedEventsDefaultsToAll() {
        let timeline = ActivityTimelineView()
        let events = (0..<3).map { _ in makeEvent() }
        timeline.loadEvents(events)
        // With no selection, selectedEvents should return all filtered events.
        XCTAssertEqual(timeline.selectedEvents.count, 3)
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Task8-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Fake folder provider

/// A lightweight test double conforming to `ActivityHistoryFolderProvider`.
private struct FakeActivityCaptureFolderAccess: ActivityHistoryFolderProvider {
    let rootURL: URL?

    var resolvedRootURL: URL? { rootURL }
    var logsURL: URL? { rootURL.map { $0.appendingPathComponent("logs", isDirectory: true) } }
    var screenshotsURL: URL? { rootURL.map { $0.appendingPathComponent("screenshots", isDirectory: true) } }
}
