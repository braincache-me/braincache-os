import XCTest
import GRDB
@testable import ClipVault

// MARK: - Mock pasteboard

final class MockWritePasteboard: PasteboardWriteProtocol {
    var clearCallCount = 0
    var writtenStrings: [NSPasteboard.PasteboardType: String] = [:]
    var writtenData: [NSPasteboard.PasteboardType: Data] = [:]
    var writtenPropertyLists: [NSPasteboard.PasteboardType: Any] = [:]

    @discardableResult func clearContents() -> Int {
        clearCallCount += 1
        writtenStrings.removeAll()
        writtenData.removeAll()
        writtenPropertyLists.removeAll()
        return clearCallCount
    }

    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenStrings[dataType] = string
        return true
    }

    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenData[dataType] = data
        return true
    }

    @discardableResult func setPropertyList(_ plist: Any, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        writtenPropertyLists[dataType] = plist
        return true
    }
}

// MARK: - PasteService tests

final class PasteServiceTests: XCTestCase {

    var mockPasteboard: MockWritePasteboard!
    var pasteService: PasteService!

    override func setUp() {
        super.setUp()
        mockPasteboard = MockWritePasteboard()
        pasteService = PasteService(pasteboard: mockPasteboard)
    }

    private func makeRecord(
        contentType: String = "text",
        textContent: String? = "hello",
        fileURL: String? = nil
    ) -> ClipRecord {
        ClipRecord(
            id: 1,
            contentType: contentType,
            textContent: textContent,
            dataHash: "abc",
            mediaFileName: nil,
            fileURL: fileURL,
            sourceApp: nil,
            byteSize: textContent?.utf8.count ?? 0,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true
        )
    }

    // MARK: - writeToClipboard

    func testWriteTextClipClearsAndWritesString() {
        let record = makeRecord(contentType: "text", textContent: "plain text")
        pasteService.writeToClipboard(record: record)

        XCTAssertEqual(mockPasteboard.clearCallCount, 1)
        XCTAssertEqual(mockPasteboard.writtenStrings[.string], "plain text")
    }

    func testWriteHTMLClipWritesBothHTMLAndString() {
        let record = makeRecord(contentType: "html", textContent: "<b>bold</b>")
        pasteService.writeToClipboard(record: record)

        XCTAssertEqual(mockPasteboard.writtenStrings[NSPasteboard.PasteboardType("public.html")], "<b>bold</b>")
        XCTAssertEqual(mockPasteboard.writtenStrings[.string], "bold")
    }

    func testWriteRTFClipWritesStringFallback() {
        let record = makeRecord(contentType: "rtf", textContent: "rtf text")
        pasteService.writeToClipboard(record: record)

        XCTAssertEqual(mockPasteboard.writtenStrings[.string], "rtf text")
    }

    func testWriteFileClipWritesPropertyList() {
        let record = makeRecord(
            contentType: "file",
            textContent: "/tmp/test.txt",
            fileURL: "file:///tmp/test.txt"
        )
        pasteService.writeToClipboard(record: record)

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        XCTAssertNotNil(mockPasteboard.writtenPropertyLists[filenamesType])
        let paths = mockPasteboard.writtenPropertyLists[filenamesType] as? [String]
        XCTAssertEqual(paths?.first, "/tmp/test.txt")
    }

    func testWriteFileClipUsesTextContentWhenNoURL() {
        let record = makeRecord(contentType: "file", textContent: "/some/path", fileURL: nil)
        pasteService.writeToClipboard(record: record)

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let paths = mockPasteboard.writtenPropertyLists[filenamesType] as? [String]
        XCTAssertEqual(paths, ["/some/path"])
    }

    func testWriteLargeFileClipLoadsFromMediaFileName() throws {
        // Large multi-file selection (>10 MB textContent) stores paths in a media file.
        // PasteService must load from mediaFileName when textContent is nil.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PasteServiceTests-\(UUID().uuidString)", isDirectory: true)
        let mediaManager = MediaFileManager(mediaDirectory: tmpDir)
        let service = PasteService(pasteboard: mockPasteboard, mediaFileManager: mediaManager)

        let paths = ["/tmp/file1.txt", "/tmp/file2.txt", "/tmp/file3.txt"]
        let joined = paths.joined(separator: "\n")
        let filename = try mediaManager.save(Data(joined.utf8), extension: "txt")

        let record = ClipRecord(
            id: 1, contentType: "file", textContent: nil,
            dataHash: "abc", mediaFileName: filename, fileURL: nil,
            sourceApp: nil, byteSize: joined.utf8.count,
            createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            isPinned: false, isIndexed: false
        )

        let result = service.writeToClipboard(record: record)
        XCTAssertTrue(result)
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let written = mockPasteboard.writtenPropertyLists[filenamesType] as? [String]
        XCTAssertEqual(written, paths)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testWriteImageClipWithNoMediaFileReturnsFalseWithoutClear() {
        // No mediaFileName and no textContent — cannot rehydrate, so pasteboard must not be cleared.
        let record = makeRecord(contentType: "image", textContent: nil)
        let result = pasteService.writeToClipboard(record: record)

        XCTAssertFalse(result)
        XCTAssertEqual(mockPasteboard.clearCallCount, 0, "Pasteboard must not be wiped when content cannot be rehydrated")
        XCTAssertTrue(mockPasteboard.writtenStrings.isEmpty)
    }

    func testClearIsAlwaysCalledBeforeWrite() {
        let record = makeRecord()
        pasteService.writeToClipboard(record: record)
        pasteService.writeToClipboard(record: record)

        XCTAssertEqual(mockPasteboard.clearCallCount, 2)
    }
}

// MARK: - Search ranking tests (ClipStore)

final class SearchRankingTests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)
    }

    private func insert(_ text: String, secondsAgo: Double = 0) throws -> Int64 {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            byteSize: text.utf8.count,
            createdAt: Date(timeIntervalSinceNow: -secondsAgo)
        )
        return try store.insert(entry: entry)
    }

    func testSearchReturnsMatchingItems() throws {
        try insert("swift programming language")
        try insert("python scripting")
        try insert("swift package manager")

        let results = try store.search(query: "swift", limit: 10)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.textContent?.contains("swift") == true })
    }

    func testSearchEmptyQueryReturnsMostRecentFirst() throws {
        try insert("oldest", secondsAgo: 3600)
        try insert("middle", secondsAgo: 1800)
        try insert("newest", secondsAgo: 0)

        let results = try store.search(query: "", limit: 10)
        XCTAssertEqual(results[0].textContent, "newest")
    }

    func testSearchPinnedItemsAppearBeforeUnpinned() throws {
        try insert("regular item")
        let id = try insert("pinned item")
        try store.pinClip(id: id)

        let results = try store.search(query: "", limit: 10)
        XCTAssertEqual(results[0].textContent, "pinned item")
        XCTAssertTrue(results[0].isPinned)
    }

    func testSearchNoMatchReturnsEmpty() throws {
        try insert("hello world")
        let results = try store.search(query: "zzznomatch", limit: 10)
        XCTAssertEqual(results.count, 0)
    }

    func testTouchLastUsedUpdatesTimestamp() throws {
        let id = try insert("touch test")

        let before = try store.fetchRecent(limit: 1).first?.lastUsedAt
        XCTAssertNil(before)

        try store.touchLastUsed(id: id)

        let after = try store.fetchRecent(limit: 1).first?.lastUsedAt
        XCTAssertNotNil(after)
    }
}
