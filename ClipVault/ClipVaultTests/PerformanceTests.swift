import XCTest
import GRDB
@testable import ClipVault

// MARK: - Large Paste Tests

final class LargePasteTests: XCTestCase {

    private var pasteboard: MockPasteboard!
    private var reader: PasteboardReader!

    override func setUp() {
        super.setUp()
        pasteboard = MockPasteboard()
        reader = PasteboardReader()
    }

    func testSmallTextIsIndexed() {
        pasteboard.strings[.string] = "short text"
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.isIndexed)
        XCTAssertNotNil(entry!.textContent)
    }

    func testLargeTextIsNotIndexed() {
        // Create a string that encodes to >10MB
        let bigText = String(repeating: "A", count: PasteboardReader.maxIndexedByteSize + 1)
        pasteboard.strings[.string] = bigText
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.isIndexed, "Entry >10MB must have isIndexed=false")
        XCTAssertNil(entry!.textContent, "Large text content must not be stored as textContent")
    }

    func testLargeImageIsNotIndexed() {
        // PNG data slightly over 10MB
        let bigImage = Data(repeating: 0x00, count: PasteboardReader.maxIndexedByteSize + 1)
        pasteboard.dataMap[.png] = bigImage
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.isIndexed, "Image >10MB must have isIndexed=false")
    }

    func testExactlyAtThresholdIsIndexed() {
        let data = Data(repeating: 0x41, count: PasteboardReader.maxIndexedByteSize)
        pasteboard.dataMap[.png] = data
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry!.isIndexed, "Item exactly at threshold must be indexed")
    }

    func testLargeRTFIsNotIndexed() {
        let bigRTF = Data(repeating: 0x7B, count: PasteboardReader.maxIndexedByteSize + 1)
        pasteboard.dataMap[.rtf] = bigRTF
        let entry = reader.read(from: pasteboard)
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.isIndexed)
        XCTAssertNil(entry!.textContent)
    }

    func testClipStoreInsertUsesIsIndexed() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ClipStore(dbQueue: manager.dbQueue)

        // Insert a non-indexed entry (simulating large paste)
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: nil,
            dataHash: "largehash",
            byteSize: PasteboardReader.maxIndexedByteSize + 1,
            isIndexed: false
        )
        let id = try store.insert(entry: entry)

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].isIndexed, "Large entry must be stored with isIndexed=false")
        XCTAssertEqual(results[0].id, id)
    }

    func testLargeEntryNotFoundBySearch() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        let store = ClipStore(dbQueue: manager.dbQueue)

        // Insert a large (non-indexed) entry
        let largeEntry = ClipboardEntry(
            contentType: .text,
            textContent: nil,
            dataHash: "bighash",
            byteSize: PasteboardReader.maxIndexedByteSize + 1,
            isIndexed: false
        )
        try store.insert(entry: largeEntry)

        // FTS search should not find it
        let results = try store.search(query: "anything", limit: 10)
        XCTAssertEqual(results.count, 0, "Non-indexed entries must not appear in FTS search")
    }
}

// MARK: - Sleep/Wake Tests

final class ClipboardMonitorSleepWakeTests: XCTestCase {

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

    func testSuspendAndResumeDoNotCrash() {
        monitor.start()
        // Suspend while running
        monitor.suspendTimer()
        // Resume after suspend
        monitor.resumeTimer()
        // Should still be in running state
        XCTAssertTrue(monitor.isRunning)
    }

    func testSuspendBeforeStartIsNoop() {
        // Suspending before start must not crash
        monitor.suspendTimer()
        XCTAssertFalse(monitor.isRunning)
    }

    func testResumeBeforeSuspendIsNoop() {
        monitor.start()
        // Resume without a prior suspend must not crash
        monitor.resumeTimer()
        XCTAssertTrue(monitor.isRunning)
    }

    func testSuspendThenStopDoesNotCrash() {
        monitor.start()
        monitor.suspendTimer()
        // Stop must resume the timer internally before cancelling to avoid an imbalance crash
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
    }
}

// MARK: - PurgeScheduler Tests

final class PurgeSchedulerTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var store: ClipStore!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)

        suiteName = "test.purge.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeEntry(text: String, daysOld: Int = 0) -> ClipboardEntry {
        ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: Hashing.sha256(string: text + UUID().uuidString),
            byteSize: text.utf8.count,
            createdAt: Date(timeIntervalSinceNow: -Double(daysOld) * 86400)
        )
    }

    func testRunPurgeDeletesOldEntries() throws {
        settings.autoPurgeAgeDays = 30
        settings.maxHistoryCount = 1000

        try store.insert(entry: makeEntry(text: "old", daysOld: 60))
        try store.insert(entry: makeEntry(text: "fresh"))

        let scheduler = PurgeScheduler(store: store, settings: settings)
        scheduler.runPurge()

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].textContent, "fresh")
    }

    func testRunPurgeTrimsExcessEntries() throws {
        settings.autoPurgeAgeDays = 365
        settings.maxHistoryCount = 3

        for i in 0..<6 {
            try store.insert(entry: makeEntry(text: "item \(i)"))
        }

        let scheduler = PurgeScheduler(store: store, settings: settings)
        scheduler.runPurge()

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 3)
    }

    func testStopCancelsTimer() {
        let scheduler = PurgeScheduler(store: store, settings: settings)
        scheduler.start()
        scheduler.stop()
        // After stop, no crash if stop called again
        scheduler.stop()
    }

    func testRunPurgeRespectsPinnedEntries() throws {
        settings.autoPurgeAgeDays = 30
        settings.maxHistoryCount = 1

        let pinnedID = try store.insert(entry: makeEntry(text: "pinned", daysOld: 60))
        try store.pinClip(id: pinnedID)
        try store.insert(entry: makeEntry(text: "fresh"))

        let scheduler = PurgeScheduler(store: store, settings: settings)
        scheduler.runPurge()

        let results = try store.fetchRecent(limit: 10)
        // pinned survives age purge; max=1 unpinned so "fresh" survives count purge
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.contains { $0.isPinned })
    }
}
