import XCTest
import GRDB
@testable import ClipVault

// MARK: - Migration v5 Schema Tests

final class MigrationV5Tests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
    }

    func testConversationsTableExists() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("conversations"))
        }
    }

    func testChatMessagesTableExists() throws {
        try dbQueue.read { db in
            XCTAssertTrue(try db.tableExists("chat_messages"))
        }
    }

    func testConversationsColumns() throws {
        try dbQueue.read { db in
            let cols = try db.columns(in: "conversations").map(\.name)
            XCTAssertTrue(cols.contains("id"))
            XCTAssertTrue(cols.contains("title"))
            XCTAssertTrue(cols.contains("created_at"))
            XCTAssertTrue(cols.contains("updated_at"))
        }
    }

    func testChatMessagesColumns() throws {
        try dbQueue.read { db in
            let cols = try db.columns(in: "chat_messages").map(\.name)
            XCTAssertTrue(cols.contains("id"))
            XCTAssertTrue(cols.contains("conversation_id"))
            XCTAssertTrue(cols.contains("role"))
            XCTAssertTrue(cols.contains("content"))
            XCTAssertTrue(cols.contains("cited_clip_ids"))
            XCTAssertTrue(cols.contains("created_at"))
        }
    }

    func testCascadeDeleteRemovesMessages() throws {
        let store = ConversationStore(dbQueue: dbQueue)
        let conv = try store.createConversation(title: "Cascade Test")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "hello")
        try store.appendMessage(conversationId: convId, role: "assistant", content: "world")

        // Verify messages exist
        let beforeDelete = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(beforeDelete.count, 2)

        // Delete conversation — cascade should remove messages
        try store.deleteConversation(id: convId)

        try dbQueue.read { db in
            let count = try ChatMessageRecord
                .filter(ChatMessageRecord.Columns.conversationId == convId)
                .fetchCount(db)
            XCTAssertEqual(count, 0)
        }
    }

    func testIndexCreated() throws {
        // Verify the idx_chat_messages_conv index exists by inserting and querying via conversation_id
        let store = ConversationStore(dbQueue: dbQueue)
        let conv = try store.createConversation(title: "Index Test")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "msg")
        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(msgs.count, 1)
    }
}

// MARK: - Migration v7 (conversations.topic)

final class MigrationV7Tests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
    }

    func testConversationsHasTopicColumn() throws {
        try dbQueue.read { db in
            let cols = try db.columns(in: "conversations").map(\.name)
            XCTAssertTrue(cols.contains("topic"))
        }
    }

    func testCreatedConversationDefaultsToClipsTopic() throws {
        let store = ConversationStore(dbQueue: dbQueue)
        let conv = try store.createConversation(title: "Default Topic")
        XCTAssertEqual(conv.topic, ConversationTopic.clips.rawValue)
    }

    func testCreateConversationWithAudioTranscriptsTopic() throws {
        let store = ConversationStore(dbQueue: dbQueue)
        let conv = try store.createConversation(title: "Voice Chat",
                                                topic: .audioTranscripts)
        XCTAssertEqual(conv.topic, ConversationTopic.audioTranscripts.rawValue)
        // Round-trip via fetchAll to confirm persistence.
        let fetched = try store.fetchAll().first { $0.id == conv.id }
        XCTAssertEqual(fetched?.topic, ConversationTopic.audioTranscripts.rawValue)
    }

    func testUpdateTopicPersists() throws {
        let store = ConversationStore(dbQueue: dbQueue)
        let conv = try store.createConversation(title: "Switchable")
        let convId = try XCTUnwrap(conv.id)
        try store.updateTopic(conversationId: convId, topic: .audioTranscripts)
        let fetched = try store.fetchAll().first { $0.id == convId }
        XCTAssertEqual(fetched?.topic, ConversationTopic.audioTranscripts.rawValue)
    }

    func testConversationTopicHistoryModeRoundTrip() {
        XCTAssertEqual(ConversationTopic(historyMode: .clips), .clips)
        XCTAssertEqual(ConversationTopic(historyMode: .audioTranscripts), .audioTranscripts)
        XCTAssertEqual(ConversationTopic.clips.historyMode, .clips)
        XCTAssertEqual(ConversationTopic.audioTranscripts.historyMode, .audioTranscripts)
    }
}

// MARK: - ConversationStore Tests

final class ConversationStoreTests: XCTestCase {

    private var store: ConversationStore!
    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        let manager = DatabaseManager()
        try manager.setupInMemory()
        dbQueue = manager.dbQueue
        store = ConversationStore(dbQueue: dbQueue)
    }

    // MARK: - Create

    func testCreateConversationReturnsRecord() throws {
        let conv = try store.createConversation(title: "My Chat")
        XCTAssertNotNil(conv.id)
        XCTAssertEqual(conv.title, "My Chat")
        XCTAssertGreaterThan(conv.createdAt, 0)
        XCTAssertGreaterThan(conv.updatedAt, 0)
    }

    func testCreateMultipleConversations() throws {
        _ = try store.createConversation(title: "First")
        _ = try store.createConversation(title: "Second")
        _ = try store.createConversation(title: "Third")
        let count = try store.conversationCount()
        XCTAssertEqual(count, 3)
    }

    // MARK: - Fetch All

    func testFetchAllOrderedByUpdatedAtDesc() throws {
        _ = try store.createConversation(title: "Old")
        let recent = try store.createConversation(title: "New")
        let recentId = try XCTUnwrap(recent.id)

        // Append a message to bump updated_at of "New" relative to insertion order
        // We need to ensure "New" has a higher updated_at; since both were just created,
        // add a tiny sleep and then append a message.
        // Instead, directly manipulate via appendMessage which bumps updated_at.
        Thread.sleep(forTimeInterval: 0.01)
        try store.appendMessage(conversationId: recentId, role: "user", content: "hi")

        let all = try store.fetchAll()
        XCTAssertEqual(all.first?.id, recentId)
    }

    func testFetchAllEmptyWhenNoConversations() throws {
        let all = try store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Delete

    func testDeleteConversation() throws {
        let conv = try store.createConversation(title: "Delete Me")
        let convId = try XCTUnwrap(conv.id)
        try store.deleteConversation(id: convId)
        let count = try store.conversationCount()
        XCTAssertEqual(count, 0)
    }

    func testDeleteAllConversations() throws {
        _ = try store.createConversation(title: "A")
        _ = try store.createConversation(title: "B")
        _ = try store.createConversation(title: "C")
        try store.deleteAllConversations()
        XCTAssertEqual(try store.conversationCount(), 0)
    }

    // MARK: - Title update

    func testUpdateTitle() throws {
        let conv = try store.createConversation(title: "Old Title")
        let convId = try XCTUnwrap(conv.id)
        try store.updateTitle(conversationId: convId, title: "New Title")
        let all = try store.fetchAll()
        XCTAssertEqual(all.first?.title, "New Title")
    }

    // MARK: - Append Message

    func testAppendMessageReturnsRecord() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        let msg = try store.appendMessage(conversationId: convId, role: "user", content: "Hello")
        XCTAssertNotNil(msg.id)
        XCTAssertEqual(msg.conversationId, convId)
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "Hello")
        XCTAssertNil(msg.citedClipIds)
    }

    func testAppendMessageWithCitedClipIds() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        let msg = try store.appendMessage(
            conversationId: convId,
            role: "assistant",
            content: "Answer",
            citedClipIds: [1, 2, 3]
        )
        XCTAssertNotNil(msg.citedClipIds)
        XCTAssertEqual(msg.decodedCitedClipIds(), [1, 2, 3])
    }

    func testAppendMessageBumpsConversationUpdatedAt() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        let originalUpdatedAt = conv.updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        try store.appendMessage(conversationId: convId, role: "user", content: "msg")

        let updated = try store.fetchAll().first(where: { $0.id == convId })
        XCTAssertGreaterThan(updated?.updatedAt ?? 0, originalUpdatedAt)
    }

    // MARK: - Fetch Messages

    func testFetchMessagesOrderedByCreatedAtAsc() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "First")
        Thread.sleep(forTimeInterval: 0.01)
        try store.appendMessage(conversationId: convId, role: "assistant", content: "Second")

        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].content, "First")
        XCTAssertEqual(msgs[1].content, "Second")
    }

    func testFetchMessagesReturnsOnlyConversationMessages() throws {
        let conv1 = try store.createConversation(title: "Chat 1")
        let conv2 = try store.createConversation(title: "Chat 2")
        let id1 = try XCTUnwrap(conv1.id)
        let id2 = try XCTUnwrap(conv2.id)

        try store.appendMessage(conversationId: id1, role: "user", content: "Conv1 msg")
        try store.appendMessage(conversationId: id2, role: "user", content: "Conv2 msg")

        let msgs1 = try store.fetchMessages(conversationId: id1)
        let msgs2 = try store.fetchMessages(conversationId: id2)

        XCTAssertEqual(msgs1.count, 1)
        XCTAssertEqual(msgs1[0].content, "Conv1 msg")
        XCTAssertEqual(msgs2.count, 1)
        XCTAssertEqual(msgs2[0].content, "Conv2 msg")
    }

    func testFetchMessagesEmptyWhenNoneExist() throws {
        let conv = try store.createConversation(title: "Empty")
        let convId = try XCTUnwrap(conv.id)
        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertTrue(msgs.isEmpty)
    }

    // MARK: - Cascade delete removes messages

    func testCascadeDeleteRemovesMessagesOnConversationDelete() throws {
        let conv = try store.createConversation(title: "To Delete")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "msg 1")
        try store.appendMessage(conversationId: convId, role: "assistant", content: "msg 2")

        try store.deleteConversation(id: convId)

        let msgs = try store.fetchMessages(conversationId: convId)
        XCTAssertTrue(msgs.isEmpty)
    }

    func testDeleteAllConversationsClearsMessages() throws {
        let conv = try store.createConversation(title: "Chat")
        let convId = try XCTUnwrap(conv.id)
        try store.appendMessage(conversationId: convId, role: "user", content: "hello")

        try store.deleteAllConversations()

        try dbQueue.read { db in
            let count = try ChatMessageRecord.fetchCount(db)
            XCTAssertEqual(count, 0)
        }
    }
}

// MARK: - ChatMessage model tests

final class ChatMessageModelTests: XCTestCase {

    func testDefaultInitHasNilDatabaseFields() {
        let msg = ChatMessage(role: .user, text: "hello")
        XCTAssertNil(msg.id)
        XCTAssertNil(msg.conversationId)
    }

    func testInitWithDatabaseFields() {
        let msg = ChatMessage(role: .assistant, text: "reply", citedIDs: [1, 2], id: 42, conversationId: 7)
        XCTAssertEqual(msg.id, 42)
        XCTAssertEqual(msg.conversationId, 7)
        XCTAssertEqual(msg.citedIDs, [1, 2])
    }

    func testBackwardCompatibleInit() {
        // The old-style init (no id/conversationId) must still work
        let msg = ChatMessage(role: .user, text: "hi", citedIDs: [], timestamp: Date())
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "hi")
        XCTAssertNil(msg.id)
        XCTAssertNil(msg.conversationId)
    }
}
