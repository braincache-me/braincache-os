import XCTest
import GRDB
@testable import ClipVault

// MARK: - ConversationListView Tests

final class ConversationListViewTests: XCTestCase {

    // MARK: - relativeDate

    func testRelativeDateJustNow() {
        let ts = Date().timeIntervalSince1970 - 30
        XCTAssertEqual(ConversationListView.relativeDate(from: ts), "Just now")
    }

    func testRelativeDateMinutesAgo() {
        let ts = Date().timeIntervalSince1970 - 5 * 60
        XCTAssertEqual(ConversationListView.relativeDate(from: ts), "5 min ago")
    }

    func testRelativeDateOneMinuteAgo() {
        let ts = Date().timeIntervalSince1970 - 90   // 1.5 min
        XCTAssertEqual(ConversationListView.relativeDate(from: ts), "1 min ago")
    }

    func testRelativeDateHoursAgo() {
        let ts = Date().timeIntervalSince1970 - 3 * 3600
        XCTAssertEqual(ConversationListView.relativeDate(from: ts), "3 hr ago")
    }

    func testRelativeDateYesterday() {
        let ts = Date().timeIntervalSince1970 - 25 * 3600
        XCTAssertEqual(ConversationListView.relativeDate(from: ts), "Yesterday")
    }

    func testRelativeDateOlderUsesShortDate() {
        let ts = Date().timeIntervalSince1970 - 10 * 86400
        let result = ConversationListView.relativeDate(from: ts)
        // Should not be any of the relative labels
        XCTAssertFalse(result == "Just now")
        XCTAssertFalse(result.hasSuffix("min ago"))
        XCTAssertFalse(result.hasSuffix("hr ago"))
        XCTAssertFalse(result == "Yesterday")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Data source

    func testNumberOfRowsMatchesConversations() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        let convs: [ConversationRecord] = [
            ConversationRecord(id: 1, title: "A", createdAt: now, updatedAt: now),
            ConversationRecord(id: 2, title: "B", createdAt: now, updatedAt: now),
            ConversationRecord(id: 3, title: "C", createdAt: now, updatedAt: now),
        ]
        view.reload(conversations: convs, selectedId: nil)
        XCTAssertEqual(view.conversations.count, 3)
    }

    func testReloadWithEmptyConversations() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        view.reload(conversations: [], selectedId: nil)
        XCTAssertEqual(view.conversations.count, 0)
        XCTAssertNil(view.selectedConversationId)
    }

    // MARK: - Selection

    func testReloadSetsSelectedConversationId() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        let convs: [ConversationRecord] = [
            ConversationRecord(id: 1, title: "A", createdAt: now, updatedAt: now),
            ConversationRecord(id: 2, title: "B", createdAt: now, updatedAt: now),
        ]
        view.reload(conversations: convs, selectedId: 2)
        XCTAssertEqual(view.selectedConversationId, 2)
    }

    func testReloadWithNilSelectedIdClearsSelection() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        let convs: [ConversationRecord] = [
            ConversationRecord(id: 1, title: "A", createdAt: now, updatedAt: now),
        ]
        view.reload(conversations: convs, selectedId: 1)
        view.reload(conversations: convs, selectedId: nil)
        XCTAssertNil(view.selectedConversationId)
    }

    func testReloadWithNonExistentSelectedIdSetsNil() {
        let view = ConversationListView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let now = Date().timeIntervalSince1970
        let convs: [ConversationRecord] = [
            ConversationRecord(id: 1, title: "A", createdAt: now, updatedAt: now),
        ]
        view.reload(conversations: convs, selectedId: 99)   // id 99 does not exist
        XCTAssertNil(view.selectedConversationId)
    }
}

// MARK: - AutoTitle Tests

final class AutoTitleTests: XCTestCase {

    func testAutoTitleShortMessage() {
        let title = ChatPanelController.autoTitle(from: "Hello world")
        XCTAssertEqual(title, "Hello world")
    }

    func testAutoTitleTruncatesAt60Chars() {
        let msg = String(repeating: "A", count: 100)
        let title = ChatPanelController.autoTitle(from: msg)
        XCTAssertEqual(title.count, 60)
    }

    func testAutoTitleExactly60CharsUnchanged() {
        let msg = String(repeating: "B", count: 60)
        let title = ChatPanelController.autoTitle(from: msg)
        XCTAssertEqual(title, msg)
    }

    func testAutoTitleEmptyMessage() {
        let title = ChatPanelController.autoTitle(from: "")
        XCTAssertEqual(title, "")
    }

    func testAutoTitlePreservesUnicode() {
        // Emoji characters should not be split mid-codepoint
        let emoji = String(repeating: "🔥", count: 30)   // 30 emoji, each is 1 Character
        let title = ChatPanelController.autoTitle(from: emoji)
        XCTAssertEqual(title.count, 30)   // 30 chars total < 60
    }
}

// MARK: - ChatPanelController Conversation Lifecycle Tests

final class ChatPanelControllerLifecycleTests: XCTestCase {

    private var store: ConversationStore!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ConversationStore(dbQueue: dbQueue)
    }

    func testCreateConversationPersistsToStore() throws {
        let conv = try store.createConversation(title: "Test")
        XCTAssertNotNil(conv.id)
        XCTAssertEqual(try store.conversationCount(), 1)
    }

    func testLoadMessagesForConversation() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "Hello")
        try store.appendMessage(conversationId: convId, role: "assistant", content: "World")
        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(msgs.count, 2)
    }

    func testSwitchConversationLoadsCorrectMessages() throws {
        let conv1 = try store.createConversation(title: "Conv 1")
        let conv2 = try store.createConversation(title: "Conv 2")
        let id1 = try XCTUnwrap(conv1.id)
        let id2 = try XCTUnwrap(conv2.id)
        try store.appendMessage(conversationId: id1, role: "user", content: "Msg in 1")
        try store.appendMessage(conversationId: id2, role: "user", content: "Msg in 2")

        let msgs1 = try store.fetchMessages(conversationId: id1)
        let msgs2 = try store.fetchMessages(conversationId: id2)

        XCTAssertEqual(msgs1.first?.content, "Msg in 1")
        XCTAssertEqual(msgs2.first?.content, "Msg in 2")
    }

    func testDeleteConversationRemovesFromList() throws {
        let conv = try store.createConversation(title: "To Delete")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "msg")
        try store.deleteConversation(id: convId)
        XCTAssertTrue(try store.fetchAll().isEmpty)
    }

    func testDeleteConversationAlsoCascadesMessages() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "hello")
        try store.deleteConversation(id: convId)
        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertTrue(msgs.isEmpty)
    }

    func testAutoTitleShortMessageApplied() throws {
        let conv = try store.createConversation(title: "New Chat")
        let convId = try XCTUnwrap(conv.id)
        let firstMsg = "What is the weather like today?"
        let title = ChatPanelController.autoTitle(from: firstMsg)
        try store.updateTitle(conversationId: convId, title: title)
        let updated = try XCTUnwrap(try store.fetchAll().first)
        XCTAssertEqual(updated.title, firstMsg)
    }

    func testAutoTitleLongMessageTruncated() throws {
        let conv = try store.createConversation(title: "New Chat")
        let convId = try XCTUnwrap(conv.id)
        let longMsg = String(repeating: "Hello world ", count: 10)   // > 60 chars
        let title = ChatPanelController.autoTitle(from: longMsg)
        try store.updateTitle(conversationId: convId, title: title)
        let updated = try XCTUnwrap(try store.fetchAll().first)
        XCTAssertEqual(updated.title.count, 60)
    }

    func testFetchAllAfterDeleteReturnsRemainingConversation() throws {
        let c1 = try store.createConversation(title: "Keep")
        let c2 = try store.createConversation(title: "Delete")
        let id2 = try XCTUnwrap(c2.id)
        try store.deleteConversation(id: id2)
        let remaining = try store.fetchAll()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, c1.id)
    }

    func testNewConversationDefaultTitle() throws {
        let conv = try store.createConversation(title: "New Chat")
        XCTAssertEqual(conv.title, "New Chat")
    }

    func testConversationListOrderedMostRecentFirst() throws {
        let c1 = try store.createConversation(title: "Old")
        let c2 = try store.createConversation(title: "Recent")
        let id2 = try XCTUnwrap(c2.id)
        Thread.sleep(forTimeInterval: 0.02)
        try store.appendMessage(conversationId: id2, role: "user", content: "bump")
        let all = try store.fetchAll()
        XCTAssertEqual(all.first?.id, c2.id)
        XCTAssertEqual(all.last?.id, c1.id)
    }
}

// MARK: - ChatMessage model round-trip

final class ChatMessagePersistenceTests: XCTestCase {

    private var store: ConversationStore!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        store = ConversationStore(dbQueue: manager.dbQueue)
    }

    func testMessageRoundTrip() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        let record = try store.appendMessage(conversationId: convId,
                                             role: "user",
                                             content: "Hello DB!")
        let fetched = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, record.id)
        XCTAssertEqual(fetched[0].content, "Hello DB!")
        XCTAssertEqual(fetched[0].role, "user")
    }

    func testAssistantMessageWithCitedIds() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        let record = try store.appendMessage(conversationId: convId,
                                             role: "assistant",
                                             content: "See clips #1 and #2.",
                                             citedClipIds: [1, 2])
        let fetched = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(fetched[0].decodedCitedClipIds(), [1, 2])
        XCTAssertNotNil(record.citedClipIds)
    }

    func testChatMessageStructMapsFromRecord() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "Hello")
        try store.appendMessage(conversationId: convId, role: "assistant", content: "World")

        let records = try store.fetchMessages(conversationId: convId)
        let chatMessages = records.map { record in
            ChatMessage(
                role: record.role == "user" ? .user : .assistant,
                text: record.content,
                citedIDs: record.decodedCitedClipIds(),
                timestamp: Date(timeIntervalSince1970: record.createdAt),
                id: record.id,
                conversationId: convId
            )
        }
        XCTAssertEqual(chatMessages.count, 2)
        XCTAssertEqual(chatMessages[0].role, .user)
        XCTAssertEqual(chatMessages[0].text, "Hello")
        XCTAssertEqual(chatMessages[1].role, .assistant)
        XCTAssertEqual(chatMessages[1].text, "World")
        XCTAssertEqual(chatMessages[0].conversationId, convId)
    }
}
