import Foundation
import GRDB

// MARK: - ConversationRecord

struct ConversationRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversations"

    var id: Int64?
    var title: String
    var createdAt: Double
    var updatedAt: Double
    /// One of `ConversationTopic.rawValue` — drives RAG retrieval scope.
    /// Defaults to `.clips` so older callers and rows pre-v7 stay on the original behavior.
    var topic: String = ConversationTopic.clips.rawValue

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case topic
    }

    enum Columns {
        static let id        = Column(CodingKeys.id)
        static let title     = Column(CodingKeys.title)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let topic     = Column(CodingKeys.topic)
    }

    init(
        id: Int64?,
        title: String,
        createdAt: Double,
        updatedAt: Double,
        topic: String = ConversationTopic.clips.rawValue
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.topic = topic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(Int64.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.createdAt = try c.decode(Double.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        self.topic = try c.decodeIfPresent(String.self, forKey: .topic)
            ?? ConversationTopic.clips.rawValue
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - ConversationTopic

/// Persistent topic identifier stored in `conversations.topic`. Maps 1:1 to `SearchHistoryMode`.
enum ConversationTopic: String {
    case clips = "clips"
    case audioTranscripts = "audio_transcripts"

    init(historyMode: SearchHistoryMode) {
        switch historyMode {
        case .clips: self = .clips
        case .audioTranscripts: self = .audioTranscripts
        }
    }

    var historyMode: SearchHistoryMode {
        switch self {
        case .clips: return .clips
        case .audioTranscripts: return .audioTranscripts
        }
    }
}

// MARK: - ChatMessageRecord

struct ChatMessageRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_messages"

    var id: Int64?
    var conversationId: Int64
    var role: String
    var content: String
    var citedClipIds: String?   // JSON-encoded [Int64]
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case citedClipIds   = "cited_clip_ids"
        case createdAt      = "created_at"
    }

    enum Columns {
        static let id             = Column(CodingKeys.id)
        static let conversationId = Column(CodingKeys.conversationId)
        static let role           = Column(CodingKeys.role)
        static let content        = Column(CodingKeys.content)
        static let citedClipIds   = Column(CodingKeys.citedClipIds)
        static let createdAt      = Column(CodingKeys.createdAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decodes citedClipIds JSON string into [Int64].
    func decodedCitedClipIds() -> [Int64] {
        guard let json = citedClipIds,
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([Int64].self, from: data) else {
            return []
        }
        return ids
    }
}

// MARK: - ConversationStore

final class ConversationStore {

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Conversations

    /// Creates a new conversation and returns the persisted record.
    func createConversation(
        title: String,
        topic: ConversationTopic = .clips
    ) throws -> ConversationRecord {
        var record = ConversationRecord(
            id: nil,
            title: title,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            topic: topic.rawValue
        )
        try dbQueue.write { db in
            try record.insert(db)
        }
        return record
    }

    /// Updates the topic of a conversation. Used when the user toggles Clips/Audio
    /// before any messages exist in the current chat.
    func updateTopic(conversationId: Int64, topic: ConversationTopic) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET topic = ? WHERE id = ?",
                arguments: [topic.rawValue, conversationId]
            )
        }
    }

    /// Returns all conversations ordered by updated_at descending.
    func fetchAll() throws -> [ConversationRecord] {
        try dbQueue.read { db in
            try ConversationRecord
                .order(ConversationRecord.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// Deletes a conversation and all its messages (cascade).
    func deleteConversation(id: Int64) throws {
        try dbQueue.write { db in
            _ = try ConversationRecord.deleteOne(db, key: id)
        }
    }

    /// Deletes all conversations (and all messages via cascade).
    func deleteAllConversations() throws {
        try dbQueue.write { db in
            _ = try ConversationRecord.deleteAll(db)
        }
    }

    /// Updates the title of a conversation.
    func updateTitle(conversationId: Int64, title: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ? WHERE id = ?",
                arguments: [title, conversationId]
            )
        }
    }

    /// Returns the total number of conversations.
    func conversationCount() throws -> Int {
        try dbQueue.read { db in
            try ConversationRecord.fetchCount(db)
        }
    }

    /// Deletes the oldest conversations (by `updated_at` ascending) so that at most
    /// `keepNewest` conversations remain. Does nothing if already within the limit.
    /// Cascade delete removes all associated messages automatically.
    func deleteOldestExceeding(keepNewest limit: Int) throws {
        try dbQueue.write { db in
            let count = try ConversationRecord.fetchCount(db)
            guard count > limit else { return }
            let excess = count - limit
            let oldest = try ConversationRecord
                .order(ConversationRecord.Columns.updatedAt.asc)
                .limit(excess)
                .fetchAll(db)
            for record in oldest {
                guard let id = record.id else { continue }
                _ = try ConversationRecord.deleteOne(db, key: id)
            }
        }
    }

    // MARK: - Messages

    /// Returns all messages for a conversation ordered by created_at ascending.
    func fetchMessages(conversationId: Int64) throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            try ChatMessageRecord
                .filter(ChatMessageRecord.Columns.conversationId == conversationId)
                .order(ChatMessageRecord.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// Appends a message to a conversation and bumps conversations.updated_at.
    @discardableResult
    func appendMessage(
        conversationId: Int64,
        role: String,
        content: String,
        citedClipIds: [Int64]? = nil
    ) throws -> ChatMessageRecord {
        let encodedIds: String?
        if let ids = citedClipIds, !ids.isEmpty {
            let data = try JSONEncoder().encode(ids)
            encodedIds = String(data: data, encoding: .utf8)
        } else {
            encodedIds = nil
        }

        var record = ChatMessageRecord(
            id: nil,
            conversationId: conversationId,
            role: role,
            content: content,
            citedClipIds: encodedIds,
            createdAt: Date().timeIntervalSince1970
        )
        try dbQueue.write { db in
            try record.insert(db)
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [record.createdAt, conversationId]
            )
        }
        return record
    }
}
