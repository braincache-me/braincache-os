import XCTest
import GRDB
@testable import ClipVault

/// Unit tests for SearchPanelController, ClipRowView helpers, and debounce logic.
final class SearchPanelControllerTests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!
    var controller: SearchPanelController!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)

        controller = SearchPanelController()
        controller.clipStore = store
    }

    // MARK: - Helpers

    private func insert(
        _ text: String,
        createdAt: Date = Date(),
        sourceApp: String? = nil
    ) throws -> Int64 {
        let entry = ClipboardEntry(
            contentType: .text,
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            sourceApp: sourceApp,
            byteSize: text.utf8.count,
            createdAt: createdAt
        )
        return try store.insert(entry: entry)
    }

    // MARK: - reloadWithQuery (no window needed)

    func testReloadEmptyQueryReturnsRecent() throws {
        try insert("alpha")
        try insert("beta")
        try insert("gamma")

        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.count, 3)
    }

    func testReloadEmptyQueryDefaultsToClipboardClipsOnly() throws {
        try insert("regular clipboard")
        try insert("meeting transcript", sourceApp: ClipRecord.audioTranscriptSourceApp)

        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.map(\.textContent), ["regular clipboard"])
    }

    func testAudioTranscriptModeReturnsVoiceTranscripts() throws {
        try insert("regular clipboard")
        try insert("standup transcript", sourceApp: ClipRecord.audioTranscriptSourceApp)

        controller.setHistoryMode(.audioTranscripts, reload: false)
        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.map(\.textContent), ["standup transcript"])
        XCTAssertTrue(controller.results.allSatisfy { $0.isAudioTranscript })
    }

    func testAudioTranscriptModeSearchFiltersWithinTranscripts() throws {
        try insert("regular standup notes")
        try insert("standup transcript", sourceApp: ClipRecord.audioTranscriptSourceApp)
        try insert("sales call transcript", sourceApp: ClipRecord.audioTranscriptSourceApp)

        controller.setHistoryMode(.audioTranscripts, reload: false)
        controller.reloadWithQuery("standup")

        XCTAssertEqual(controller.results.map(\.textContent), ["standup transcript"])
    }

    func testDefaultActionPreviewsAudioTranscripts() throws {
        try insert("regular clipboard")
        try insert("standup transcript", sourceApp: ClipRecord.audioTranscriptSourceApp)

        controller.reloadWithQuery("")
        XCTAssertEqual(controller.defaultAction(for: controller.results[0]), .paste)

        controller.setHistoryMode(.audioTranscripts, reload: false)
        controller.reloadWithQuery("")
        XCTAssertEqual(controller.defaultAction(for: controller.results[0]), .preview)
    }

    func testReloadWithQueryFiltersResults() throws {
        try insert("swift language")
        try insert("python scripting")
        try insert("swift package manager")

        controller.reloadWithQuery("swift")

        XCTAssertEqual(controller.results.count, 2)
        XCTAssertTrue(controller.results.allSatisfy { $0.textContent?.contains("swift") == true })
    }

    func testReloadNoMatchReturnsEmpty() throws {
        try insert("hello world")

        controller.reloadWithQuery("zzznomatch")

        XCTAssertEqual(controller.results.count, 0)
    }

    func testReloadEmptyStoreReturnsEmpty() throws {
        controller.reloadWithQuery("")
        XCTAssertEqual(controller.results.count, 0)
    }

    func testReloadAskCommandDoesNotRunKeywordSearch() throws {
        try insert("swift question-like text")

        controller.reloadWithQuery("/ask what does this clip mean?")

        XCTAssertEqual(controller.results.count, 0)
        XCTAssertEqual(controller.displayedCount, 0)
    }

    // MARK: - Debounce

    func testDebounceSchedulesSearch() throws {
        try insert("debounce test")

        let expectation = self.expectation(description: "Debounced search completes")

        // Rapidly schedule multiple searches — only the last should fire
        controller.scheduleSearch(query: "zzz")
        controller.scheduleSearch(query: "zzz")
        controller.scheduleSearch(query: "debounce")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(self.controller.results.count, 1)
            XCTAssertEqual(self.controller.results[0].textContent, "debounce test")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    func testDebounceCancel() throws {
        try insert("cancel test")

        let expectation = self.expectation(description: "Cancelled debounce does not fire old query")

        controller.scheduleSearch(query: "zzznomatch")
        // Cancel by scheduling a new one immediately
        controller.scheduleSearch(query: "cancel")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            XCTAssertEqual(self.controller.results.count, 1)
            XCTAssertEqual(self.controller.results[0].textContent, "cancel test")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5)
    }

    // MARK: - Keyboard routing

    func testMoveSelectionWithoutWindow() throws {
        try insert("row 1")
        try insert("row 2")
        try insert("row 3")

        controller.reloadWithQuery("")
        // moveSelectionLeft/Right are no-ops when collectionView is nil (no window),
        // but must not crash
        controller.moveSelectionRight()
        controller.moveSelectionLeft()
        // No assertion — just verifying no crash
    }

    func testSelectedClipNilWhenNoTableView() throws {
        try insert("something")
        controller.reloadWithQuery("")
        // Without a real window/tableView, selectedClip is nil
        XCTAssertNil(controller.selectedClip)
    }

    // MARK: - Context menu actions

    func testPinActionPinsClip() throws {
        let id = try insert("to pin")
        controller.reloadWithQuery("")

        // Verify unpinned initially
        var record = try store.fetchRecent(limit: 1).first
        XCTAssertFalse(record?.isPinned ?? true)

        // Simulate the togglePin action via the store directly (mirroring what the action does)
        try store.pinClip(id: id)
        controller.reloadWithQuery("")

        record = controller.results.first
        XCTAssertTrue(record?.isPinned ?? false, "Clip should be pinned after pin action")
    }

    func testUnpinActionUnpinsClip() throws {
        let id = try insert("to unpin")
        try store.pinClip(id: id)
        controller.reloadWithQuery("")

        XCTAssertTrue(controller.results.first?.isPinned ?? false)

        try store.unpinClip(id: id)
        controller.reloadWithQuery("")

        XCTAssertFalse(controller.results.first?.isPinned ?? true, "Clip should be unpinned after unpin action")
    }

    func testDeleteActionRemovesClip() throws {
        let id = try insert("to delete")
        controller.reloadWithQuery("")
        XCTAssertEqual(controller.results.count, 1)

        try store.deleteById(id)
        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.count, 0, "Clip should be removed after delete action")
    }

    func testPinnedClipAppearsFirstInResults() throws {
        try insert("unpinned")
        let id = try insert("pinned later")
        try store.pinClip(id: id)

        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.first?.textContent, "pinned later", "Pinned clip must appear first")
    }
}

// MARK: - FTS5 search tests

final class FTS5SearchTests: XCTestCase {

    var dbQueue: DatabaseQueue!
    var store: ClipStore!
    var controller: SearchPanelController!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ClipStore(dbQueue: dbQueue)

        controller = SearchPanelController()
        controller.clipStore = store
    }

    override func tearDown() {
        controller = nil
        store = nil
        dbQueue = nil
        super.tearDown()
    }

    private func insert(_ text: String, tags: [String]? = nil) throws -> Int64 {
        let tagsJSON: String? = tags.flatMap { tagArray in
            (try? JSONEncoder().encode(tagArray)).flatMap { String(data: $0, encoding: .utf8) }
        }
        var record = ClipRecord(
            id: nil,
            contentType: "text",
            textContent: text,
            dataHash: Hashing.sha256(data: text.data(using: .utf8)!),
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: nil,
            byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: tagsJSON,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )
        return try store.insertRecord(&record)
    }

    func testFTS5SearchFindsMatch() throws {
        try insert("swift programming")
        try insert("python scripting")

        controller.reloadWithQuery("swift")

        XCTAssertEqual(controller.results.count, 1)
        XCTAssertEqual(controller.results.first?.textContent, "swift programming")
    }

    func testEmptyQueryReturnsRecent() throws {
        try insert("clip one")
        try insert("clip two")

        controller.reloadWithQuery("")

        XCTAssertEqual(controller.results.count, 2)
    }
}

// MARK: - Tag badge rendering data

final class TagBadgeRenderingTests: XCTestCase {

    // decodeTags returns nil for nil / invalid JSON.
    func testDecodeTagsNilForInvalidJSON() {
        XCTAssertNil(ClipCardView.decodeTags(from: "not-json"))
        XCTAssertNil(ClipCardView.decodeTags(from: "{}"))
    }

    // decodeTags parses a valid JSON array.
    func testDecodeTagsValidJSON() {
        let json = #"["code","swift","work"]"#
        let tags = ClipCardView.decodeTags(from: json)
        XCTAssertEqual(tags, ["code", "swift", "work"])
    }

    // decodeTags returns empty array for empty JSON array.
    func testDecodeTagsEmptyArray() {
        let tags = ClipCardView.decodeTags(from: "[]")
        XCTAssertEqual(tags, [])
    }

    // ClipRowView.rowHeight returns base height when no tags.
    func testRowHeightNoTags() {
        var record = ClipRecord(
            id: 1, contentType: "text", textContent: "hello",
            dataHash: "abc", mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 5,
            createdAt: 0, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: nil, imageDescription: nil,
            aiProcessed: 0, aiProcessedAt: nil
        )
        XCTAssertEqual(ClipRowView.rowHeight(for: record), ClipRowView.rowHeight)

        record.tags = "[]"
        XCTAssertEqual(ClipRowView.rowHeight(for: record), ClipRowView.rowHeight,
                       "Empty tag array should return base row height")
    }

    // ClipRowView.rowHeight returns expanded height when tags present.
    func testRowHeightWithTags() {
        let record = ClipRecord(
            id: 1, contentType: "text", textContent: "hello",
            dataHash: "abc", mediaFileName: nil, fileURL: nil,
            sourceApp: nil, byteSize: 5,
            createdAt: 0, lastUsedAt: nil,
            isPinned: false, isIndexed: true,
            tags: #"["code","swift"]"#,
            imageDescription: nil,
            aiProcessed: 0, aiProcessedAt: nil
        )
        XCTAssertEqual(ClipRowView.rowHeight(for: record), ClipRowView.rowHeightWithTags)
    }
}

// MARK: - ClipRowView date formatting

final class ClipRowViewTests: XCTestCase {

    func testFormatDateJustNow() {
        let date = Date(timeIntervalSinceNow: -5)
        XCTAssertEqual(ClipRowView.formatDate(date), "just now")
    }

    func testFormatDateOver60Seconds() {
        let date = Date(timeIntervalSinceNow: -120)
        let result = ClipRowView.formatDate(date)
        // Should contain some relative description, not "just now"
        XCTAssertNotEqual(result, "just now")
        XCTAssertFalse(result.isEmpty)
    }
}

// MARK: - SearchPanelWindow positioning

final class SearchPanelWindowTests: XCTestCase {

    func testWindowPositionIsBottomFullWidth() {
        let panel = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: 800,
                                height: SearchPanelWindow.panelHeight),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.positionAtBottomCenter()

        guard let screen = NSScreen.main else {
            return
        }
        let fullFrame = screen.frame
        let panelFrame = panel.frame

        XCTAssertEqual(panelFrame.width, fullFrame.width, accuracy: 1)
        XCTAssertEqual(panelFrame.origin.x, fullFrame.minX, accuracy: 1)
        XCTAssertEqual(panelFrame.origin.y, fullFrame.minY, accuracy: 1)
    }

    func testWindowCanBecomeKey() {
        let panel = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testWindowLevel() {
        let panel = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        XCTAssertEqual(panel.level, .statusBar)
    }
}
