import XCTest
@testable import ClipVault

// MARK: - Fake AX inspector for testing

final class FakeActivityAXInspector: ActivityAXInspecting {
    var stubbedResult: ActivityAXResult = .empty
    var stubbedIsSecureFieldFocused: Bool = false
    var stubbedCurrentURL: String?

    func inspect(at point: CGPoint) -> ActivityAXResult {
        return stubbedResult
    }

    func isSecureFieldFocused() -> Bool {
        return stubbedIsSecureFieldFocused
    }

    func currentURL(forPID pid: pid_t) -> String? {
        return stubbedCurrentURL
    }
}

// MARK: - Helpers

private func makeLogWriter(in dir: URL) -> ActivityLogWriter {
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    let writer = ActivityLogWriter(logsURL: logsDir, flushThreshold: 100, flushInterval: 0)
    return writer
}

private func writtenEvents(in dir: URL) throws -> [ActivityEvent] {
    let logsDir = dir.appendingPathComponent("logs", isDirectory: true)
    let day = ActivityLogPaths.dayString()
    let logURL = logsDir.appendingPathComponent(day + ".jsonl")
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
    return try content
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { try ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: String($0).data(using: .utf8)!) }
}

// MARK: - Tests

final class ActivityCaptureTask3Tests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Task3-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - ActivityAXResult: attribute fallback order

    func testBestControlNamePrefersDerivedName() {
        var result = ActivityAXResult(isSecureField: false)
        result.derivedControlName = "Resolved Name"
        result.title = "Button Title"
        result.elementDescription = "Button Desc"
        result.roleDescription = "Button Role"
        XCTAssertEqual(result.bestControlName, "Resolved Name")
    }

    func testBestControlNameFallsBackToTitleAfterDerivedNameMissing() {
        var result = ActivityAXResult(isSecureField: false)
        result.title = "Button Title"
        result.elementDescription = "Button Desc"
        result.roleDescription = "Button Role"
        XCTAssertEqual(result.bestControlName, "Button Title")
    }

    func testBestControlNameFallsBackToTitleUIElementText() {
        var result = ActivityAXResult(isSecureField: false)
        result.title = nil
        result.titleUIElementText = "Email"
        result.elementDescription = "Button Desc"
        result.roleDescription = "Button Role"
        XCTAssertEqual(result.bestControlName, "Email")
    }

    func testBestControlNameFallsBackToDescription() {
        var result = ActivityAXResult(isSecureField: false)
        result.title = nil
        result.titleUIElementText = nil
        result.elementDescription = "Button Desc"
        result.roleDescription = "Button Role"
        XCTAssertEqual(result.bestControlName, "Button Desc")
    }

    func testBestControlNameFallsBackToPlaceholder() {
        var result = ActivityAXResult(isSecureField: false)
        result.title = nil
        result.titleUIElementText = nil
        result.elementDescription = nil
        result.placeholderValue = "Search"
        result.roleDescription = "text field"
        XCTAssertEqual(result.bestControlName, "Search")
    }

    func testBestControlNameUsesButtonValueWhenNoOtherNameExists() {
        var result = ActivityAXResult(isSecureField: false)
        result.role = "AXButton"
        result.title = nil
        result.titleUIElementText = nil
        result.elementDescription = nil
        result.placeholderValue = nil
        result.help = nil
        result.value = "Continue"
        result.roleDescription = "button"
        XCTAssertEqual(result.bestControlName, "Continue")
    }

    func testBestControlNameFallsBackToRoleDescription() {
        var result = ActivityAXResult(isSecureField: false)
        result.role = "AXButton"
        result.title = nil
        result.titleUIElementText = nil
        result.elementDescription = nil
        result.roleDescription = "Button"
        XCTAssertEqual(result.bestControlName, "Button")
    }

    func testBestControlNameDoesNotUseGenericContainerRoleDescription() {
        var result = ActivityAXResult(isSecureField: false)
        result.role = "AXGroup"
        result.roleDescription = "group"
        XCTAssertNil(result.bestControlName)
    }

    func testBestControlNameNilWhenAllMissing() {
        let result = ActivityAXResult(isSecureField: false)
        XCTAssertNil(result.bestControlName)
    }

    // MARK: - Secure field redaction

    func testSecureFieldClearsControlValue() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXSecureTextField",
            roleDescription: "secure text field",
            title: "Password",
            elementDescription: nil,
            value: "s3cr3t",
            isSecureField: true,
            windowTitle: "Login"
        )

        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        // Override current app context to a non-excluded app
        coordinator.currentBundleID = "com.example.App"
        coordinator.handleClickAt(CGPoint(x: 100, y: 200), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        // sessionStarted + leftClick = 2 events
        let clickEvents = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clickEvents.count, 1)
        XCTAssertNil(clickEvents.first?.controlValue, "Password field value must not be recorded")
        XCTAssertEqual(clickEvents.first?.controlRole, "AXSecureTextField")
        XCTAssertEqual(clickEvents.first?.controlName, "Password")
        coordinator.stop()
    }

    func testClickEventCarriesURLFromAXResult() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXLink",
            roleDescription: "link",
            title: "Sign in",
            elementDescription: nil,
            value: nil,
            isSecureField: false,
            windowTitle: "LinkedIn"
        )
        fakeInspector.stubbedResult.url = "https://www.linkedin.com/jobs/view/123"

        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.google.Chrome"
        coordinator.handleClickAt(CGPoint(x: 100, y: 200), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let clickEvents = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clickEvents.count, 1)
        XCTAssertEqual(clickEvents.first?.url, "https://www.linkedin.com/jobs/view/123")
        XCTAssertEqual(coordinator.currentURL, "https://www.linkedin.com/jobs/view/123")
        coordinator.stop()
    }

    func testClickWithoutURLLeavesFieldNil() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXButton",
            roleDescription: "button",
            title: "OK",
            elementDescription: nil,
            value: nil,
            isSecureField: false,
            windowTitle: "Finder"
        )

        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.apple.finder"
        coordinator.handleClickAt(CGPoint(x: 10, y: 10), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let clickEvents = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clickEvents.count, 1)
        XCTAssertNil(clickEvents.first?.url)
        coordinator.stop()
    }

    func testNonSecureFieldRecordsValue() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXTextField",
            roleDescription: "text field",
            title: "Username",
            elementDescription: nil,
            value: "alice",
            isSecureField: false,
            windowTitle: "Login"
        )

        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.Self",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"
        coordinator.handleClickAt(CGPoint(x: 50, y: 50), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let clickEvents = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clickEvents.count, 1)
        XCTAssertEqual(clickEvents.first?.controlValue, "alice")
        coordinator.stop()
    }

    // MARK: - Bundle ID exclusion

    func testOwnBundleIDIsExcluded() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self.App",
            excludedBundleIDs: { [] }
        )
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.Self.App"))
    }

    func testListedBundleIDIsExcluded() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self.App",
            excludedBundleIDs: { ["com.1password.1password", "com.agilebits.onepassword"] }
        )
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.1password.1password"))
        XCTAssertTrue(coordinator.shouldExclude(bundleID: "com.agilebits.onepassword"))
    }

    func testUnlistedBundleIDIsNotExcluded() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self.App",
            excludedBundleIDs: { ["com.excluded.App"] }
        )
        XCTAssertFalse(coordinator.shouldExclude(bundleID: "com.apple.Safari"))
    }

    func testEmptyBundleIDIsNotExcluded() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.Self.App",
            excludedBundleIDs: { [] }
        )
        XCTAssertFalse(coordinator.shouldExclude(bundleID: ""))
    }

    func testExcludedAppClickIsNotLogged() {
        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: FakeActivityAXInspector(),
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.Self.App",
            excludedBundleIDs: { ["com.excluded.App"] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.excluded.App"
        coordinator.handleClickAt(CGPoint(x: 1, y: 1), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let clickEvents = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clickEvents.count, 0, "Events from excluded apps must not be recorded")
        coordinator.stop()
    }

    // MARK: - Monitor lifecycle state machine

    func testInitialStateIsIdle() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testStartTransitionsToRecording() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.stop()
    }

    func testPauseTransitionsToPaused() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.pause()
        XCTAssertEqual(coordinator.state, .paused)
        coordinator.stop()
    }

    func testResumeTransitionsBackToRecording() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.pause()
        coordinator.resume()
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.stop()
    }

    func testStopTransitionsToIdle() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testDoubleStartIsIgnored() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.start()  // second start is a no-op
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.stop()
    }

    func testPauseFromIdleIsIgnored() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.pause()
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testResumeFromRecordingIsIgnored() {
        let coordinator = ActivityCaptureCoordinator(
            logWriter: makeLogWriter(in: tempDir),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.resume()  // not paused, should be ignored
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.stop()
    }

    func testPausedCoordinatorDoesNotLogClicks() {
        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: FakeActivityAXInspector(),
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.pause()
        coordinator.currentBundleID = "com.example.Other"
        coordinator.handleClickAt(CGPoint(x: 1, y: 1), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let clicks = events?.filter { $0.eventType == .leftClick } ?? []
        XCTAssertEqual(clicks.count, 0, "Paused coordinator must not record clicks")
        coordinator.stop()
    }

    func testSessionEventsAreEmitted() {
        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: FakeActivityAXInspector(),
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.pause()
        coordinator.resume()
        coordinator.stop()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let types = events?.map { $0.eventType } ?? []
        XCTAssertTrue(types.contains(.sessionStarted))
        XCTAssertTrue(types.contains(.sessionPaused))
        XCTAssertTrue(types.contains(.sessionResumed))
        XCTAssertTrue(types.contains(.sessionStopped))
    }

    // MARK: - Key shortcut summary

    func testKeyShortcutSummaryWithCommandKey() {
        // We can test the logic by creating a real NSEvent for testing.
        // Since constructing NSEvents for modifier+key is tricky in unit tests,
        // we verify the logic indirectly via a synthetic NSEvent.
        // For the modifier flag logic test we can verify the function's guard clause.
        // NSEvent.keyEvent doesn't require a display — we can create one.
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!
        let summary = ActivityCaptureCoordinator.keyShortcutSummary(for: event)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("⌘"))
        XCTAssertTrue(summary!.contains("C"))
    }

    func testKeyShortcutSummaryNilForPlainText() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        let summary = ActivityCaptureCoordinator.keyShortcutSummary(for: event)
        XCTAssertNil(summary, "Plain text keystrokes must not produce a shortcut summary")
    }

    func testKeyShortcutSummaryWithControlAndOption() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        )!
        let summary = ActivityCaptureCoordinator.keyShortcutSummary(for: event)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("⌃"))
        XCTAssertTrue(summary!.contains("⌥"))
    }

    func testKeyShortcutSummaryShiftAloneIsIgnored() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "A",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        let summary = ActivityCaptureCoordinator.keyShortcutSummary(for: event)
        XCTAssertNil(summary, "Shift alone (capitalization) must not produce a shortcut summary")
    }

    // MARK: - Focus-change event generation

    func testFocusObserverDeliversAppActivatedEvent() {
        let observer = ActivityFocusObserver()
        var received: ActivityFocusObserver.FocusEvent?
        observer.onFocusChange = { event in received = event }

        // Simulate an app-activation notification
        let app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier != nil }
        guard let app else {
            XCTSkip("No running application available for test")
            return
        }
        let notification = Notification(
            name: NSWorkspace.didActivateApplicationNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: app]
        )
        // Post directly to the observer's handler via NotificationCenter
        // by calling start() first and then posting on the workspace notification center.
        observer.start()
        NSWorkspace.shared.notificationCenter.post(notification)

        // The handler is queued on .main but called synchronously since we're on main.
        if Thread.isMainThread {
            // Run one iteration of the run loop to let the notification be delivered.
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        XCTAssertNotNil(received)
        if case .appActivated(let name, let bid, _) = received?.kind {
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(bid.isEmpty)
        } else {
            XCTFail("Expected appActivated focus event")
        }
        observer.stop()
    }

    // MARK: - Event type mapping

    func testEventTypeMapping() {
        // Verify the raw values align with what the coordinator emits.
        XCTAssertEqual(ActivityEventType.leftClick.rawValue, "left_click")
        XCTAssertEqual(ActivityEventType.rightClick.rawValue, "right_click")
        XCTAssertEqual(ActivityEventType.otherClick.rawValue, "other_click")
        XCTAssertEqual(ActivityEventType.keyShortcut.rawValue, "key_shortcut")
        XCTAssertEqual(ActivityEventType.appActivated.rawValue, "app_activated")
        XCTAssertEqual(ActivityEventType.windowFocused.rawValue, "window_focused")
        XCTAssertEqual(ActivityEventType.windowTitleChanged.rawValue, "window_title_changed")
    }

    func testClickEventUsesWindowTitleFromAXWhenAvailable() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXButton",
            roleDescription: nil,
            title: "OK",
            elementDescription: nil,
            value: nil,
            isSecureField: false,
            windowTitle: "AX Window Title"
        )
        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"
        coordinator.currentWindowTitle = "Tracked Title"  // should be overridden by AX
        coordinator.handleClickAt(CGPoint(x: 10, y: 10), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let click = events?.first { $0.eventType == .leftClick }
        XCTAssertEqual(click?.windowTitle, "AX Window Title")
        coordinator.stop()
    }

    func testClickEventFallsBackToTrackedWindowTitle() {
        let fakeInspector = FakeActivityAXInspector()
        fakeInspector.stubbedResult = ActivityAXResult(
            role: "AXButton",
            roleDescription: nil,
            title: nil,
            elementDescription: nil,
            value: nil,
            isSecureField: false,
            windowTitle: nil  // no AX window title
        )
        let writer = makeLogWriter(in: tempDir)
        let coordinator = ActivityCaptureCoordinator(
            logWriter: writer,
            axInspector: fakeInspector,
            focusObserver: ActivityFocusObserver(),
            ownBundleID: "com.test.App",
            excludedBundleIDs: { [] }
        )
        coordinator.start()
        coordinator.currentBundleID = "com.example.App"
        coordinator.currentWindowTitle = "Tracked Title"
        coordinator.handleClickAt(CGPoint(x: 10, y: 10), eventType: .leftClick)
        coordinator.clickAggregator.flush()
        writer.flushSync()

        let events = try? writtenEvents(in: tempDir)
        let click = events?.first { $0.eventType == .leftClick }
        XCTAssertEqual(click?.windowTitle, "Tracked Title")
        coordinator.stop()
    }
}
