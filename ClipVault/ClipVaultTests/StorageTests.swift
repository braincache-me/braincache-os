import XCTest
import GRDB
@testable import ClipVault

final class ClipStoreTests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)
    }

    // MARK: - Helpers

    private func makeEntry(
        text: String = "hello",
        hash: String? = nil,
        createdAt: Date = Date(),
        sourceApp: String? = nil
    ) -> ClipboardEntry {
        ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: hash ?? Hashing.sha256(data: text.data(using: .utf8)!),
            sourceApp: sourceApp,
            byteSize: text.utf8.count,
            createdAt: createdAt
        )
    }

    // MARK: - Insert & fetchRecent

    func testInsertAndFetchRecent() throws {
        let e1 = makeEntry(text: "first")
        let e2 = makeEntry(text: "second")
        try store.insert(entry: e1)
        try store.insert(entry: e2)

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 2)
        // Most recent first
        XCTAssertEqual(results[0].textContent, "second")
        XCTAssertEqual(results[1].textContent, "first")
    }

    func testFetchRecentRespectsLimit() throws {
        for i in 0..<10 {
            try store.insert(entry: makeEntry(text: "item \(i)"))
        }
        let results = try store.fetchRecent(limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Search

    func testSearchFindsMatchingText() throws {
        try store.insert(entry: makeEntry(text: "swift programming language"))
        try store.insert(entry: makeEntry(text: "python scripting"))

        let results = try store.search(query: "swift", limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].textContent, "swift programming language")
    }

    func testSearchEmptyQueryReturnsFetchRecent() throws {
        for i in 0..<5 {
            try store.insert(entry: makeEntry(text: "item \(i)"))
        }
        let results = try store.search(query: "", limit: 10)
        XCTAssertEqual(results.count, 5)
    }

    func testSearchNoMatchReturnsEmpty() throws {
        try store.insert(entry: makeEntry(text: "hello world"))
        let results = try store.search(query: "zzznomatch", limit: 10)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Delete

    func testDeleteById() throws {
        let id = try store.insert(entry: makeEntry(text: "to delete"))
        var results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 1)

        try store.deleteById(id)
        results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 0)
    }

    func testDeleteAll() throws {
        try store.insert(entry: makeEntry(text: "a"))
        try store.insert(entry: makeEntry(text: "b"))
        try store.deleteAll()
        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Purge

    func testPurgeOlderThan() throws {
        let old = makeEntry(text: "old", createdAt: Date(timeIntervalSinceNow: -100 * 86400))
        let fresh = makeEntry(text: "fresh", createdAt: Date())
        try store.insert(entry: old)
        try store.insert(entry: fresh)

        try store.purgeOlderThan(days: 30)

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].textContent, "fresh")
    }

    func testPurgeOlderThanSparesPinnedClips() throws {
        let old = makeEntry(text: "old", createdAt: Date(timeIntervalSinceNow: -100 * 86400))
        let id = try store.insert(entry: old)
        try store.pinClip(id: id)

        try store.purgeOlderThan(days: 30)

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results.count, 1, "Pinned clips must not be purged")
    }

    func testPurgeExceedingCount() throws {
        for i in 0..<10 {
            try store.insert(entry: makeEntry(text: "item \(i)"))
        }
        try store.purgeExceedingCount(max: 5)
        let results = try store.fetchRecent(limit: 20)
        XCTAssertEqual(results.count, 5)
    }

    func testPurgeExceedingCountSparesPinnedClips() throws {
        // Insert 3 pinned + 3 unpinned
        for i in 0..<3 {
            let id = try store.insert(entry: makeEntry(text: "pinned \(i)"))
            try store.pinClip(id: id)
        }
        for i in 0..<3 {
            try store.insert(entry: makeEntry(text: "unpinned \(i)"))
        }
        // max=2 means 2 unpinned survive; pinned are untouched
        try store.purgeExceedingCount(max: 2)
        let results = try store.fetchRecent(limit: 20)
        // 3 pinned + 2 unpinned = 5
        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(results.filter { $0.isPinned }.count == 3)
    }

    // MARK: - Pin / Unpin

    func testPinAndUnpin() throws {
        let id = try store.insert(entry: makeEntry(text: "pinnable"))
        try store.pinClip(id: id)
        var results = try store.fetchRecent(limit: 10)
        XCTAssertTrue(results[0].isPinned)

        try store.unpinClip(id: id)
        results = try store.fetchRecent(limit: 10)
        XCTAssertFalse(results[0].isPinned)
    }

    func testPinnedClipsAppearFirst() throws {
        try store.insert(entry: makeEntry(text: "unpinned"))
        let id = try store.insert(entry: makeEntry(text: "pinned"))
        try store.pinClip(id: id)

        let results = try store.fetchRecent(limit: 10)
        XCTAssertEqual(results[0].textContent, "pinned", "Pinned clips must appear first")
    }
}

// MARK: - MediaFileManager Tests

final class MediaFileManagerTests: XCTestCase {

    var tempDir: URL!
    var manager: MediaFileManager!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        manager = MediaFileManager(mediaDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSaveAndLoad() throws {
        let data = "hello media".data(using: .utf8)!
        let filename = try manager.save(data, extension: "txt")
        let loaded = try manager.load(filename: filename)
        XCTAssertEqual(loaded, data)
    }

    func testExistsAfterSave() throws {
        let data = Data([1, 2, 3])
        let filename = try manager.save(data)
        XCTAssertTrue(manager.exists(filename: filename))
    }

    func testDeleteRemovesFile() throws {
        let data = Data([4, 5, 6])
        let filename = try manager.save(data)
        try manager.delete(filename: filename)
        XCTAssertFalse(manager.exists(filename: filename))
    }

    func testLoadMissingFileThrows() {
        XCTAssertThrowsError(try manager.load(filename: "nonexistent.bin"))
    }

    func testSaveUniqueFilenames() throws {
        let data = Data([0])
        let f1 = try manager.save(data)
        let f2 = try manager.save(data)
        XCTAssertNotEqual(f1, f2, "Each save should produce a unique filename")
    }
}
