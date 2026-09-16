import XCTest
@testable import ClipVault

final class ActivityCaptureTask2Tests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
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
        screenshotPath: String? = nil,
        windowIdentifier: String? = "win-1",
        triggerMetadata: String? = nil
    ) -> ActivityEvent {
        ActivityEvent(
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
            screenshotPath: screenshotPath,
            windowIdentifier: windowIdentifier,
            triggerMetadata: triggerMetadata
        )
    }

    // MARK: - ActivityEventType

    func testEventTypeRawValues() {
        XCTAssertEqual(ActivityEventType.leftClick.rawValue, "left_click")
        XCTAssertEqual(ActivityEventType.rightClick.rawValue, "right_click")
        XCTAssertEqual(ActivityEventType.keyShortcut.rawValue, "key_shortcut")
        XCTAssertEqual(ActivityEventType.appActivated.rawValue, "app_activated")
        XCTAssertEqual(ActivityEventType.windowFocused.rawValue, "window_focused")
        XCTAssertEqual(ActivityEventType.windowTitleChanged.rawValue, "window_title_changed")
        XCTAssertEqual(ActivityEventType.idleResumed.rawValue, "idle_resumed")
        XCTAssertEqual(ActivityEventType.periodicCapture.rawValue, "periodic_capture")
        XCTAssertEqual(ActivityEventType.screenshotCaptured.rawValue, "screenshot_captured")
        XCTAssertEqual(ActivityEventType.sessionStarted.rawValue, "session_started")
        XCTAssertEqual(ActivityEventType.sessionStopped.rawValue, "session_stopped")
        XCTAssertEqual(ActivityEventType.sessionPaused.rawValue, "session_paused")
        XCTAssertEqual(ActivityEventType.sessionResumed.rawValue, "session_resumed")
    }

    func testEventTypeCodable() throws {
        for type_ in ActivityEventType.allCases {
            let encoded = try JSONEncoder().encode(type_)
            let decoded = try JSONDecoder().decode(ActivityEventType.self, from: encoded)
            XCTAssertEqual(decoded, type_)
        }
    }

    // MARK: - ActivityEvent schema

    func testEventEquality() {
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1_000_000)
        let e1 = ActivityEvent(id: id, timestamp: ts, appName: "App", bundleID: "com.example", windowTitle: "Win", eventType: .leftClick)
        let e2 = ActivityEvent(id: id, timestamp: ts, appName: "App", bundleID: "com.example", windowTitle: "Win", eventType: .leftClick)
        XCTAssertEqual(e1, e2)
    }

    func testEventOptionalFieldsDefaultToNil() {
        let event = ActivityEvent(appName: "App", bundleID: "com.x", windowTitle: "W", eventType: .sessionStarted)
        XCTAssertNil(event.controlRole)
        XCTAssertNil(event.controlName)
        XCTAssertNil(event.controlValue)
        XCTAssertNil(event.clickX)
        XCTAssertNil(event.clickY)
        XCTAssertNil(event.screenshotPath)
        XCTAssertNil(event.windowIdentifier)
        XCTAssertNil(event.triggerMetadata)
    }

    // MARK: - JSONL serialization

    func testJsonlLineProducesValidJSON() throws {
        let event = makeEvent()
        let line = try event.jsonlLine()
        XCTAssertFalse(line.isEmpty)
        // Must be parseable as a JSON object
        let data = line.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj)
    }

    func testJsonlLineContainsISO8601Timestamp() throws {
        let ts = Date(timeIntervalSince1970: 1_700_000_000)
        let event = makeEvent(timestamp: ts)
        let line = try event.jsonlLine()
        // ISO 8601 pattern with millisecond precision
        XCTAssertTrue(line.contains("2023-"), "Expected ISO 8601 year in line: \(line)")
        XCTAssertTrue(line.contains("T"), "Expected ISO 8601 T separator: \(line)")
        XCTAssertTrue(line.contains("."), "Expected millisecond fraction in timestamp: \(line)")
    }

    func testJsonlLineContainsAllFields() throws {
        let event = makeEvent(
            appName: "Safari",
            bundleID: "com.apple.Safari",
            windowTitle: "Apple",
            eventType: .leftClick,
            controlRole: "AXButton",
            controlName: "Go",
            controlValue: nil,
            clickX: 42.5,
            clickY: 99.0,
            screenshotPath: "2026-04-11/shot.jpg"
        )
        let line = try event.jsonlLine()
        XCTAssertTrue(line.contains("\"Safari\""))
        XCTAssertTrue(line.contains("\"com.apple.Safari\""))
        XCTAssertTrue(line.contains("\"Apple\""))
        XCTAssertTrue(line.contains("\"left_click\""))
        XCTAssertTrue(line.contains("\"AXButton\""))
        XCTAssertTrue(line.contains("\"Go\""))
        XCTAssertTrue(line.contains("42.5"))
        XCTAssertTrue(line.contains("99"))
        XCTAssertTrue(line.contains("\"2026-04-11/shot.jpg\""))
    }

    func testJsonlRoundTrip() throws {
        let original = makeEvent(timestamp: Date(timeIntervalSince1970: 1_000_000))
        let line = try original.jsonlLine()
        let data = line.data(using: .utf8)!
        let decoded = try ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.appName, original.appName)
        XCTAssertEqual(decoded.bundleID, original.bundleID)
        XCTAssertEqual(decoded.windowTitle, original.windowTitle)
        XCTAssertEqual(decoded.eventType, original.eventType)
        XCTAssertEqual(decoded.controlRole, original.controlRole)
        XCTAssertEqual(decoded.controlName, original.controlName)
        XCTAssertEqual(decoded.controlValue, original.controlValue)
        XCTAssertEqual(decoded.clickX, original.clickX)
        XCTAssertEqual(decoded.clickY, original.clickY)
        // Timestamps should round-trip to millisecond precision
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       original.timestamp.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - ActivityLogPaths

    func testDayStringFormat() {
        // Use a fixed date: 2026-04-11 at noon UTC
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 11
        comps.hour = 12; comps.minute = 0; comps.second = 0
        comps.timeZone = TimeZone.current
        let date = cal.date(from: comps)!
        let day = ActivityLogPaths.dayString(for: date)
        XCTAssertEqual(day, "2026-04-11")
    }

    func testDayStringRoundTrip() {
        let day = "2026-04-11"
        let parsed = ActivityLogPaths.date(fromDayString: day)
        XCTAssertNotNil(parsed)
        let back = ActivityLogPaths.dayString(for: parsed!)
        XCTAssertEqual(back, day)
    }

    func testLogFileURLHasCorrectExtension() {
        let logsDir = URL(fileURLWithPath: "/tmp/logs")
        let date = Date(timeIntervalSince1970: 1_744_329_600) // 2026-04-11 (UTC)
        let url = ActivityLogPaths.logFileURL(for: date, in: logsDir)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".jsonl"))
        XCTAssertTrue(url.path.hasPrefix("/tmp/logs"))
    }

    func testScreenshotDirectoryURLContainsDayString() {
        let screenshotsDir = URL(fileURLWithPath: "/tmp/screenshots")
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 11
        comps.timeZone = TimeZone.current
        let date = cal.date(from: comps)!
        let url = ActivityLogPaths.screenshotDirectoryURL(for: date, in: screenshotsDir)
        XCTAssertTrue(url.lastPathComponent == "2026-04-11")
    }

    func testRelativeScreenshotPathContainsComponents() {
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 4; comps.day = 11
        comps.hour = 14; comps.minute = 23; comps.second = 45
        comps.timeZone = TimeZone.current
        let date = cal.date(from: comps)!
        let relative = ActivityLogPaths.relativeScreenshotPath(
            timestamp: date,
            appName: "My App",
            trigger: "app_activated"
        )
        XCTAssertTrue(relative.hasPrefix("2026-04-11/"))
        XCTAssertTrue(relative.hasSuffix(".jpg"))
        XCTAssertTrue(relative.contains("My_App"))
        XCTAssertTrue(relative.contains("app_activated"))
    }

    func testRelativeScreenshotPathSanitizesSpecialCharacters() {
        let date = Date()
        let relative = ActivityLogPaths.relativeScreenshotPath(
            timestamp: date,
            appName: "App/With:Slashes",
            trigger: "idle resume"
        )
        XCTAssertFalse(relative.contains("/App"))
        XCTAssertFalse(relative.contains(":"))
        XCTAssertFalse(relative.contains(" "))
    }

    // MARK: - ActivityLogWriter

    func testWriterAppendsEventsToJSONLFile() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WriterTest-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 25, flushInterval: 0)
        let ts = Date()
        let events = (0..<3).map { i -> ActivityEvent in
            makeEvent(appName: "App\(i)", eventType: .leftClick)
        }
        events.forEach { writer.append($0) }
        writer.flushSync()

        let day = ActivityLogPaths.dayString(for: ts)
        let logURL = logsDir.appendingPathComponent(day + ".jsonl")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
    }

    func testWriterFlushesAtThreshold() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WriterThreshold-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 3, flushInterval: 0)
        let events = (0..<3).map { _ in makeEvent() }
        events.forEach { writer.append($0) }

        // Allow async flush to happen
        Thread.sleep(forTimeInterval: 0.1)
        writer.flushSync()

        let day = ActivityLogPaths.dayString()
        let logURL = logsDir.appendingPathComponent(day + ".jsonl")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
    }

    func testWriterAppendsAcrossMultipleCalls() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WriterAppend-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 25, flushInterval: 0)
        writer.append(makeEvent(appName: "First"))
        writer.flushSync()
        writer.append(makeEvent(appName: "Second"))
        writer.flushSync()

        let day = ActivityLogPaths.dayString()
        let logURL = logsDir.appendingPathComponent(day + ".jsonl")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(content.contains("\"First\""))
        XCTAssertTrue(content.contains("\"Second\""))
    }

    func testWriterEachLineIsValidJSON() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WriterJSON-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 25, flushInterval: 0)
        (0..<5).forEach { _ in writer.append(makeEvent()) }
        writer.flushSync()

        let day = ActivityLogPaths.dayString()
        let logURL = logsDir.appendingPathComponent(day + ".jsonl")
        let content = try String(contentsOf: logURL, encoding: .utf8)
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = String(line).data(using: .utf8)!
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    func testWriterStopPreventsAdditionalWrites() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WriterStop-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 25, flushInterval: 0)
        writer.append(makeEvent(appName: "Before"))
        writer.flushSync()
        writer.stop()
        Thread.sleep(forTimeInterval: 0.1)
        writer.append(makeEvent(appName: "After"))
        writer.flushSync()

        let day = ActivityLogPaths.dayString()
        let logURL = logsDir.appendingPathComponent(day + ".jsonl")
        if let content = try? String(contentsOf: logURL, encoding: .utf8) {
            XCTAssertTrue(content.contains("\"Before\""))
            XCTAssertFalse(content.contains("\"After\""))
        }
    }

    // MARK: - ActivityDaySummary

    func testDaySummaryDefaultValues() {
        let summary = ActivityDaySummary(dayString: "2026-04-11")
        XCTAssertEqual(summary.eventCount, 0)
        XCTAssertEqual(summary.screenshotCount, 0)
        XCTAssertEqual(summary.logFileSizeBytes, 0)
        XCTAssertEqual(summary.screenshotFolderSizeBytes, 0)
        XCTAssertEqual(summary.totalSizeBytes, 0)
    }

    func testDaySummaryTotalSizeBytes() {
        var summary = ActivityDaySummary(dayString: "2026-04-11")
        summary.logFileSizeBytes = 1024
        summary.screenshotFolderSizeBytes = 2048
        XCTAssertEqual(summary.totalSizeBytes, 3072)
    }

    func testDaySummarySaveAndLoad() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SummaryTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let original = ActivityDaySummary(
            dayString: "2026-04-11",
            eventCount: 42,
            screenshotCount: 5,
            logFileSizeBytes: 1000,
            screenshotFolderSizeBytes: 5000,
            savedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let url = tempDir.appendingPathComponent("summaries/2026-04-11.json")
        try original.save(to: url)

        let loaded = ActivityDaySummary.load(from: url)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.dayString, "2026-04-11")
        XCTAssertEqual(loaded?.eventCount, 42)
        XCTAssertEqual(loaded?.screenshotCount, 5)
        XCTAssertEqual(loaded?.logFileSizeBytes, 1000)
        XCTAssertEqual(loaded?.screenshotFolderSizeBytes, 5000)
    }

    func testDaySummaryLoadReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/path/summary.json")
        XCTAssertNil(ActivityDaySummary.load(from: url))
    }

    func testDaySummaryRebuild() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SummaryRebuild-\(UUID().uuidString)", isDirectory: true)
        let logsDir = tempDir.appendingPathComponent("logs", isDirectory: true)
        let screenshotsDir = tempDir.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write 3 JSONL lines
        let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 25, flushInterval: 0)
        (0..<3).forEach { _ in writer.append(makeEvent()) }
        writer.flushSync()

        let summary = ActivityDaySummary.rebuild(for: Date(), logsDirectory: logsDir, screenshotsDirectory: screenshotsDir)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertGreaterThan(summary.logFileSizeBytes, 0)
        XCTAssertEqual(summary.screenshotCount, 0)
    }

    // MARK: - ActivityExportFormatter - JSONL

    func testExportJSONLProducesOneLinePerEvent() {
        let events = (0..<4).map { _ in makeEvent() }
        let output = ActivityExportFormatter.jsonlString(for: events)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 4)
    }

    func testExportJSONLIsEmpty() {
        let output = ActivityExportFormatter.jsonlString(for: [])
        XCTAssertTrue(output.isEmpty)
    }

    func testExportJSONLEachLineIsValidJSON() throws {
        let events = (0..<3).map { _ in makeEvent() }
        let output = ActivityExportFormatter.jsonlString(for: events)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let data = String(line).data(using: .utf8)!
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    // MARK: - ActivityExportFormatter - CSV

    func testExportCSVHasHeader() {
        let output = ActivityExportFormatter.csvString(for: [])
        XCTAssertTrue(output.hasPrefix("timestamp,"))
        XCTAssertTrue(output.contains("appName"))
        XCTAssertTrue(output.contains("bundleID"))
        XCTAssertTrue(output.contains("eventType"))
    }

    func testExportCSVHasCorrectRowCount() {
        let events = (0..<5).map { _ in makeEvent() }
        let output = ActivityExportFormatter.csvString(for: events)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        // header + 5 data rows
        XCTAssertEqual(lines.count, 6)
    }

    func testExportCSVQuotesFieldsWithCommas() {
        let event = makeEvent(windowTitle: "Title, With Comma")
        let output = ActivityExportFormatter.csvString(for: [event])
        XCTAssertTrue(output.contains("\"Title, With Comma\""))
    }

    func testExportCSVQuotesFieldsWithInternalQuotes() {
        let event = makeEvent(windowTitle: "Title \"Quoted\"")
        let output = ActivityExportFormatter.csvString(for: [event])
        XCTAssertTrue(output.contains("\"Title \"\"Quoted\"\"\""))
    }

    func testExportCSVNilFieldsAreEmpty() {
        let event = ActivityEvent(appName: "App", bundleID: "com.x", windowTitle: "W", eventType: .sessionStarted)
        let output = ActivityExportFormatter.csvString(for: [event])
        // controlRole, controlName, controlValue should all be empty columns
        let dataLine = output.split(separator: "\n").dropFirst().first.map(String.init) ?? ""
        let columns = dataLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertGreaterThan(columns.count, 5)
    }

    // MARK: - ActivityExportFormatter - Plain text

    func testExportPlainTextContainsTimestamp() {
        let event = makeEvent(timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("["))
        XCTAssertTrue(output.contains(":"))
    }

    func testExportPlainTextContainsAppName() {
        let event = makeEvent(appName: "Firefox")
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("Firefox"))
    }

    func testExportPlainTextContainsEventType() {
        let event = makeEvent(eventType: .appActivated)
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("app_activated"))
    }

    func testExportPlainTextContainsControlInfo() {
        let event = makeEvent(controlRole: "AXButton", controlName: "OK")
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("AXButton"))
        XCTAssertTrue(output.contains("\"OK\""))
    }

    func testExportPlainTextContainsCoordinates() {
        let event = makeEvent(clickX: 300, clickY: 400)
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("300"))
        XCTAssertTrue(output.contains("400"))
    }

    func testExportPlainTextContainsScreenshotPath() {
        let event = makeEvent(screenshotPath: "2026-04-11/snap.jpg")
        let output = ActivityExportFormatter.plainTextString(for: [event])
        XCTAssertTrue(output.contains("2026-04-11/snap.jpg"))
    }

    func testExportPlainTextEmptyForNoEvents() {
        XCTAssertEqual(ActivityExportFormatter.plainTextString(for: []), "")
    }

    func testExportPlainTextOneLinePerEvent() {
        let events = (0..<7).map { _ in makeEvent() }
        let output = ActivityExportFormatter.plainTextString(for: events)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 7)
    }
}
