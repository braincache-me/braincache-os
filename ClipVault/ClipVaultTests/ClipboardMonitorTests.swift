import AppKit
import XCTest
@testable import ClipVault

// MARK: - Mock Pasteboard

final class MockPasteboard: PasteboardProtocol {
    var changeCount: Int = 0
    var strings: [NSPasteboard.PasteboardType: String] = [:]
    var dataMap: [NSPasteboard.PasteboardType: Data] = [:]
    var propertyLists: [NSPasteboard.PasteboardType: Any] = [:]
    var availableTypes: Set<NSPasteboard.PasteboardType> = []

    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? {
        types.first { availableTypes.contains($0) }
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        strings[dataType]
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        dataMap[dataType]
    }

    func propertyList(forType dataType: NSPasteboard.PasteboardType) -> Any? {
        propertyLists[dataType]
    }
}

// MARK: - Hashing Tests

final class HashingTests: XCTestCase {

    func testSHA256String() {
        // SHA256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        let result = Hashing.sha256(string: "abc")
        XCTAssertEqual(result, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(result.count, 64)
    }

    func testSHA256KnownValue() {
        // SHA256 of empty string
        let result = Hashing.sha256(string: "")
        XCTAssertEqual(result, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSHA256Data() {
        let data = Data([0x00, 0x01, 0x02])
        let result = Hashing.sha256(data: data)
        XCTAssertEqual(result.count, 64)
    }

    func testSHA256Deterministic() {
        let a = Hashing.sha256(string: "hello")
        let b = Hashing.sha256(string: "hello")
        XCTAssertEqual(a, b)
    }

    func testSHA256Different() {
        let a = Hashing.sha256(string: "hello")
        let b = Hashing.sha256(string: "world")
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - PasteboardReader Tests

final class PasteboardReaderTests: XCTestCase {

    private var pasteboard: MockPasteboard!
    private var reader: PasteboardReader!

    override func setUp() {
        super.setUp()
        pasteboard = MockPasteboard()
        reader = PasteboardReader()
    }

    func testReadsPlainText() {
        pasteboard.strings[.string] = "Hello, world"
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.contentType, .text)
        XCTAssertEqual(entry?.textContent, "Hello, world")
    }

    func testSkipsConcealedType() {
        pasteboard.availableTypes = [PasteboardReader.concealedType]
        pasteboard.strings[.string] = "secret"
        let entry = reader.read(from: pasteboard)
        XCTAssertNil(entry)
    }

    func testReadsHTMLBeforePlainText() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<table><tr><td>A</td><td>B</td></tr></table>"
        pasteboard.strings[.string] = "A\tB"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .html)
    }

    func testBrowserWrappedHTMLTreatedAsText() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<meta charset='utf-8'><span style=\"color: rgb(0,0,0);\">hello world</span>"
        pasteboard.strings[.string] = "hello world"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .text)
        XCTAssertEqual(entry?.textContent, "hello world")
    }

    func testSimpleBoldHTMLMatchingPlainTextTreatedAsText() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<b>bold</b>"
        pasteboard.strings[.string] = "bold"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .text)
        XCTAssertEqual(entry?.textContent, "bold")
    }

    func testHTMLOnlyWithoutPlainTextStaysHTML() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<b>bold</b>"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .html)
    }

    func testHTMLWithEntitiesMatchingPlainTextTreatedAsText() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<span>foo &amp; bar</span>"
        pasteboard.strings[.string] = "foo & bar"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .text)
        XCTAssertEqual(entry?.textContent, "foo & bar")
    }

    func testRichHTMLDifferingFromPlainTextStaysHTML() {
        let htmlType = NSPasteboard.PasteboardType("public.html")
        pasteboard.strings[htmlType] = "<a href=\"https://example.com\">link</a> and more"
        pasteboard.strings[.string] = "link (https://example.com) and more"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .html)
    }

    func testReadsRTFBeforePlainText() {
        // Create minimal RTF data
        let rtfString = "{\\rtf1 Hello}"
        let rtfData = Data(rtfString.utf8)
        pasteboard.dataMap[.rtf] = rtfData
        pasteboard.strings[.string] = "Hello"
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .rtf)
    }

    func testReadsPDFBeforePlainTextAndExtractsText() {
        let pdfData = makePDFData(text: "Quarterly planning notes")
        pasteboard.dataMap[.pdf] = pdfData
        pasteboard.strings[.string] = "Quarterly planning notes"

        let entry = reader.read(from: pasteboard)

        XCTAssertEqual(entry?.contentType, .pdf)
        XCTAssertEqual(entry?.rawData, pdfData)
        XCTAssertEqual(entry?.textContent, "Quarterly planning notes")
        XCTAssertTrue(entry?.isIndexed == true)
    }

    func testReadsPNGImage() {
        let fakeImage = Data([0x89, 0x50, 0x4E, 0x47]) // PNG header bytes
        pasteboard.dataMap[.png] = fakeImage
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .image)
    }

    func testReadsTIFFImage() {
        let fakeTiff = Data([0x4D, 0x4D, 0x00, 0x2A]) // TIFF header
        pasteboard.dataMap[.tiff] = fakeTiff
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .image)
    }

    func testReadsFileURLs() {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.propertyLists[filenamesType] = ["/Users/test/file.txt"]
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.contentType, .file)
        XCTAssertEqual(entry?.fileURL?.path, "/Users/test/file.txt")
    }

    func testReadsSinglePDFFileURLAsPDFClip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipvault-pdf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("notes.pdf")
        let pdfData = makePDFData(text: "PDF from Finder")
        try pdfData.write(to: pdfURL)

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.propertyLists[filenamesType] = [pdfURL.path]

        let entry = reader.read(from: pasteboard)

        XCTAssertEqual(entry?.contentType, .pdf)
        XCTAssertEqual(entry?.fileURL, pdfURL)
        XCTAssertEqual(entry?.textContent, "PDF from Finder")
    }

    func testReturnsNilForEmptyPasteboard() {
        let entry = reader.read(from: pasteboard)
        XCTAssertNil(entry)
    }

    func testHashIsDeterministic() {
        pasteboard.strings[.string] = "same content"
        let entry1 = reader.read(from: pasteboard)
        let entry2 = reader.read(from: pasteboard)
        XCTAssertEqual(entry1?.dataHash, entry2?.dataHash)
    }

    func testByteSizeIsSet() {
        let text = "Hello"
        pasteboard.strings[.string] = text
        let entry = reader.read(from: pasteboard)
        XCTAssertEqual(entry?.byteSize, Data(text.utf8).count)
    }

    func testSourceAppIsPreserved() {
        pasteboard.strings[.string] = "test"
        let entry = reader.read(from: pasteboard, sourceApp: "com.apple.Safari")
        XCTAssertEqual(entry?.sourceApp, "com.apple.Safari")
    }

    private func makePDFData(text: String) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: NSPoint(x: 72, y: 700),
            withAttributes: [.font: NSFont.systemFont(ofSize: 18)]
        )
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

// MARK: - ClipboardMonitor Exclusion Unit Tests

final class ClipboardMonitorExclusionUnitTests: XCTestCase {

    private func makeSettings(excluded: [String]) -> Settings {
        let suiteName = "test.exclusion.unit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = excluded
        return settings
    }

    func testIsExcludedReturnsTrueForExcludedBundleID() {
        let settings = makeSettings(excluded: ["com.excluded.app"])
        let monitor = ClipboardMonitor(settings: settings)
        XCTAssertTrue(monitor.isExcluded(bundleID: "com.excluded.app"))
    }

    func testIsExcludedReturnsFalseForAllowedBundleID() {
        let settings = makeSettings(excluded: ["com.excluded.app"])
        let monitor = ClipboardMonitor(settings: settings)
        XCTAssertFalse(monitor.isExcluded(bundleID: "com.allowed.app"))
    }

    func testIsExcludedReturnsFalseForNilBundleID() {
        let settings = makeSettings(excluded: ["com.excluded.app"])
        let monitor = ClipboardMonitor(settings: settings)
        XCTAssertFalse(monitor.isExcluded(bundleID: nil))
    }

    func testIsExcludedReturnsFalseWhenListIsEmpty() {
        let settings = makeSettings(excluded: [])
        let monitor = ClipboardMonitor(settings: settings)
        XCTAssertFalse(monitor.isExcluded(bundleID: "com.any.app"))
    }
}

// MARK: - ClipboardMonitor Lifecycle Tests

final class ClipboardMonitorTests: XCTestCase {

    private var pasteboard: MockPasteboard!
    private var monitor: ClipboardMonitor!

    override func setUp() {
        super.setUp()
        pasteboard = MockPasteboard()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
    }

    override func tearDown() {
        monitor.stop()
        super.tearDown()
    }

    func testInitiallyNotRunning() {
        XCTAssertFalse(monitor.isRunning)
    }

    func testStartSetsRunning() {
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
    }

    func testStopClearsRunning() {
        monitor.start()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testDoubleStartIsIdempotent() {
        monitor.start()
        monitor.start()
        XCTAssertTrue(monitor.isRunning)
    }

    func testDoubleStopIsIdempotent() {
        monitor.start()
        monitor.stop()
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }

    func testDelegateCalledOnNewContent() {
        class TestDelegate: ClipboardMonitorDelegate {
            var captured: [ClipboardEntry] = []
            func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
                captured.append(entry)
            }
        }

        let delegate = TestDelegate()
        monitor.delegate = delegate
        monitor.start()
        // Simulate a new clipboard change after monitoring has started
        pasteboard.strings[.string] = "New clip"
        pasteboard.changeCount = 1

        let expectation = XCTestExpectation(description: "delegate called")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !delegate.captured.isEmpty {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 2.0)
        XCTAssertFalse(delegate.captured.isEmpty)
        XCTAssertEqual(delegate.captured.first?.textContent, "New clip")
    }

    func testExcludedAppDoesNotFireDelegate() {
        let suiteName = "test.exclusion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) {
                captureCount += 1
            }
        }

        let delegate = TestDelegate()
        let excludedMonitor = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        excludedMonitor.sourceAppProvider = { "com.excluded.app" }
        excludedMonitor.switchHistoryProvider = { [] }
        excludedMonitor.delegate = delegate

        excludedMonitor.start()
        pasteboard.strings[.string] = "Excluded content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "exclusion wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        excludedMonitor.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 0, "Excluded app content must not fire delegate")
    }

    func testAllowedAppFiresDelegate() {
        let suiteName = "test.exclusion.allowed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) {
                captureCount += 1
            }
        }

        let delegate = TestDelegate()
        let allowedMonitor = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        allowedMonitor.sourceAppProvider = { "com.allowed.app" }
        allowedMonitor.switchHistoryProvider = { [] }
        allowedMonitor.delegate = delegate

        allowedMonitor.start()
        pasteboard.strings[.string] = "Allowed content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "allowed wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        allowedMonitor.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 1, "Allowed app content must fire delegate")
    }

    // MARK: Previous-app race suppression tests

    func testRecentExcludedPreviousAppSuppressesClip() {
        // Simulates: user copies in excluded app (changeCount becomes 1), then switches to
        // allowed app within the poll window. changeCountAtSwitch == 1 == currentCount,
        // so the copy was present before the switch and must be suppressed.
        let suiteName = "test.prevexcluded.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        m.sourceAppProvider = { "com.allowed.app" }
        // changeCount at switch time equals the current changeCount: copy happened before switch
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app", incomingBundleID: "com.allowed.app", changeCountAtSwitch: 1)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Leaked content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 0, "Clip from recently-excluded previous app must be suppressed")
    }

    func testCopyInAllowedAppAfterSwitchIsNotSuppressed() {
        // Simulates: user switches from excluded app X to allowed app Y, then copies in Y.
        // changeCountAtSwitch == 0, current changeCount == 1 (copy happened after switch).
        // The clip must NOT be suppressed even though previous app was excluded and switch
        // was very recent.
        let suiteName = "test.prevexcluded.allowedcopy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        m.sourceAppProvider = { "com.allowed.app" }
        // changeCount at switch time was 0; current changeCount is 1 — copy happened after switch
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app", incomingBundleID: "com.allowed.app", changeCountAtSwitch: 0)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Legitimate content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "allowed copy after switch wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 1, "Copy in allowed app after switch must not be suppressed")
    }

    func testStaleExcludedPreviousAppDoesNotSuppressClip() {
        // Simulates: user was in excluded app, switched to allowed app, then copied in the
        // allowed app. changeCount at switch time (0) is lower than current changeCount (1),
        // proving the copy happened after the switch and must NOT be suppressed.
        let suiteName = "test.prevexcluded.stale.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        m.sourceAppProvider = { "com.allowed.app" }
        // changeCount at switch time was 0; current changeCount is 1 — copy happened after switch
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app", incomingBundleID: "com.allowed.app", changeCountAtSwitch: 0)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Legitimate content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "stale suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 1, "Clip from allowed app after switch must not be suppressed")
    }

    func testExcludedThenAllowedThenAllowedLeaksExcludedContent() {
        // Multi-switch scenario: excluded → allowed1 → allowed2.
        // The excluded app copied (changeCount=1) then the user switched twice before the poll.
        // After two switches the single-slot approach loses the excluded app from the trail.
        // The history-based algorithm must still suppress the excluded app's content.
        let suiteName = "test.multiswitch.leak.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        m.sourceAppProvider = { "com.allowed2.app" }
        // excluded copied at cc=1; switch to allowed1 at cc=1; switch to allowed2 at cc=1
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app",  incomingBundleID: "com.allowed1.app", changeCountAtSwitch: 1),
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.allowed1.app",  incomingBundleID: "com.allowed2.app", changeCountAtSwitch: 1)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Excluded leaked content"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "multi-switch leak suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 0, "Excluded app content must be suppressed even after two subsequent switches")
    }

    func testAllowedThenExcludedThenAllowedDoesNotSuppressAllowedContent() {
        // Multi-switch scenario: allowed1 → excluded → allowed2.
        // The allowed1 app copied (changeCount=1), then the user briefly visited excluded
        // and returned to an allowed app. The previously single-slot approach would see
        // previousApp=excluded and incorrectly suppress the legitimate clip.
        // The history-based algorithm must NOT suppress this clip.
        let suiteName = "test.multiswitch.falsesuppress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        m.sourceAppProvider = { "com.allowed2.app" }
        // allowed1 copied at cc=1; switch to excluded at cc=1 (no new copy); switch to allowed2 at cc=1
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.allowed1.app",  incomingBundleID: "com.excluded.app",  changeCountAtSwitch: 1),
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app",  incomingBundleID: "com.allowed2.app",  changeCountAtSwitch: 1)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Legitimate content from allowed1"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "multi-switch false-suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 1, "Allowed app content must not be suppressed when excluded app was only briefly visited afterward")
    }

    func testExcludedAppCopiedThenClipVaultActivatedSuppressesClip() {
        // Scenario (finding 1): user copies in excluded app, then activates ClipVault.
        // handleAppActivation records the transition with incomingBundleID=nil so the
        // outgoing excluded app is still in history. resolvedSource must fall back to it.
        let suiteName = "test.clipvault.activation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let settings = Settings(defaults: defaults)
        settings.excludedBundleIDs = ["com.excluded.app"]

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }

        let delegate = TestDelegate()
        let m = ClipboardMonitor(pasteboard: pasteboard, settings: settings)
        // ClipVault is now frontmost; liveApp returns nil for ClipVault itself.
        m.sourceAppProvider = { nil }
        // History has one event: excluded app was active and then ClipVault activated.
        // incomingBundleID is nil (ClipVault sentinel), outgoing is the excluded app.
        // changeCountAtSwitch == currentCount because the copy happened before the switch.
        m.switchHistoryProvider = { [
            AppDetector.AppSwitchEvent(outgoingBundleID: "com.excluded.app", incomingBundleID: nil, changeCountAtSwitch: 1)
        ] }
        m.delegate = delegate

        m.start()
        pasteboard.strings[.string] = "Secret from excluded app"
        pasteboard.changeCount = 1

        let exp = XCTestExpectation(description: "clipvault activation suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        m.stop()

        defaults.removePersistentDomain(forName: suiteName)
        XCTAssertEqual(delegate.captureCount, 0, "Excluded app content must be suppressed when ClipVault activation recorded as nil-incoming event")
    }

    func testDeduplicationSkipsIdenticalContent() {
        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ monitor: ClipboardMonitor, didCapture entry: ClipboardEntry) {
                captureCount += 1
            }
        }

        let delegate = TestDelegate()
        monitor.delegate = delegate

        monitor.start()
        // Set content and trigger first change after monitoring has started
        pasteboard.strings[.string] = "Same content"
        pasteboard.changeCount = 1

        // Wait for first capture
        let exp1 = XCTestExpectation(description: "first capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 2.0)

        let countAfterFirst = delegate.captureCount

        // Trigger change count bump but same content
        pasteboard.changeCount = 2
        let exp2 = XCTestExpectation(description: "dedup wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 2.0)

        XCTAssertEqual(delegate.captureCount, countAfterFirst, "Duplicate content should not fire delegate again")
    }

    func testFirstLaunchSkipsPreexistingClipboard() {
        // Clipboard already has content before start() is called (copied before ClipVault launched).
        // The monitor must not capture it — we cannot reliably identify its source app.
        pasteboard.strings[.string] = "Pre-existing content"
        pasteboard.changeCount = 5

        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }
        let delegate = TestDelegate()
        monitor.delegate = delegate
        monitor.start()  // seeds lastChangeCount = 5; first poll sees no change

        let exp = XCTestExpectation(description: "first launch wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(delegate.captureCount, 0, "Pre-existing clipboard content must not be captured on first launch")
    }

    func testSuppressNextCapturePreventsDuplicate() {
        // Simulates pasting an older history item back: the monitor must not re-insert it.
        class TestDelegate: ClipboardMonitorDelegate {
            var captureCount = 0
            func clipboardMonitor(_ m: ClipboardMonitor, didCapture entry: ClipboardEntry) { captureCount += 1 }
        }
        let delegate = TestDelegate()
        monitor.delegate = delegate
        monitor.start()

        // First capture a legitimate entry
        pasteboard.strings[.string] = "Current clipboard"
        pasteboard.changeCount = 1

        let exp1 = XCTestExpectation(description: "first capture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp1.fulfill() }
        wait(for: [exp1], timeout: 2.0)
        XCTAssertEqual(delegate.captureCount, 1)

        // Simulate pasting an older clip: suppress its hash before writing to pasteboard
        let olderContent = "Older clip content"
        let olderHash = Hashing.sha256(data: Data(olderContent.utf8))
        monitor.suppressNextCapture(hash: olderHash)
        pasteboard.strings[.string] = olderContent
        pasteboard.changeCount = 2

        let exp2 = XCTestExpectation(description: "suppression wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)

        XCTAssertEqual(delegate.captureCount, 1, "Suppressed hash must prevent re-insertion of pasted history item")
    }
}
