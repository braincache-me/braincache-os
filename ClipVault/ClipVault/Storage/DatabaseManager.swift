import Foundation
import GRDB

final class DatabaseManager {

    static let shared = DatabaseManager()

    static func applicationSupportRootURL(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func dataDirectoryURL(fileManager: FileManager = .default) throws -> URL {
        try applicationSupportRootURL(fileManager: fileManager)
            .appendingPathComponent(BuildVariant.dataFolderName, isDirectory: true)
    }

    static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try dataDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("clipvault.db")
    }

    private(set) var dbQueue: DatabaseQueue!

    init() {}

    func setup() throws {
        let dir = try Self.dataDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = try Self.databaseURL()
        // WAL mode must be set outside any transaction via prepareDatabase;
        // PRAGMA journal_mode inside a migration transaction is silently ignored by SQLite.
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA cache_size = -2000")
            try db.execute(sql: "PRAGMA mmap_size = 0")
        }
        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrate()
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA optimize")
        }
    }

    /// For in-memory databases used in tests.
    func setupInMemory() throws {
        dbQueue = try DatabaseQueue()
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "clips") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content_type", .text).notNull()
                t.column("text_content", .text)
                t.column("data_hash", .text).notNull().indexed()
                t.column("media_file_name", .text)
                t.column("file_url", .text)
                t.column("source_app", .text)
                t.column("byte_size", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("last_used_at", .double)
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
                t.column("is_indexed", .boolean).notNull().defaults(to: true)
            }

            // FTS5 virtual table for full-text search
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    text_content,
                    content='clips',
                    content_rowid='id'
                )
            """)

            // Triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, text_content)
                    SELECT new.id, new.text_content
                    WHERE new.is_indexed = 1 AND new.text_content IS NOT NULL;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content)
                    VALUES('delete', old.id, old.text_content);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content)
                    VALUES('delete', old.id, old.text_content);
                    INSERT INTO clips_fts(rowid, text_content)
                    SELECT new.id, new.text_content
                    WHERE new.is_indexed = 1 AND new.text_content IS NOT NULL;
                END
            """)
        }

        // Fix FTS delete/update triggers: guard against non-indexed rows that were never
        // inserted into FTS. Deleting a rowid that doesn't exist in FTS5 leaves a phantom
        // negative-count entry that corrupts search results over time.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_au")

            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content)
                    SELECT 'delete', old.id, old.text_content
                    WHERE old.is_indexed = 1 AND old.text_content IS NOT NULL;
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content)
                    SELECT 'delete', old.id, old.text_content
                    WHERE old.is_indexed = 1 AND old.text_content IS NOT NULL;
                    INSERT INTO clips_fts(rowid, text_content)
                    SELECT new.id, new.text_content
                    WHERE new.is_indexed = 1 AND new.text_content IS NOT NULL;
                END
            """)
        }

        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE INDEX idx_clips_pinned_created
                ON clips(is_pinned DESC, created_at DESC)
            """)
            try db.execute(sql: """
                CREATE INDEX idx_clips_created_pinned
                ON clips(created_at, is_pinned)
            """)
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('optimize')")
            try db.execute(sql: "ANALYZE")
        }

        migrator.registerMigration("v4") { db in
            // Add AI metadata columns to clips
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN tags TEXT")
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN image_description TEXT")
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN ai_processed INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE clips ADD COLUMN ai_processed_at DOUBLE")

            // Create vector embedding storage table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS clip_embeddings (
                    clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
                    embedding BLOB NOT NULL,
                    model TEXT NOT NULL DEFAULT 'text-embedding-3-small',
                    dimensions INTEGER NOT NULL DEFAULT 256
                )
            """)

            // Rebuild FTS5 virtual table to index both text_content and image_description.
            // Drop old triggers (they reference the old single-column FTS schema).
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_au")

            // Drop and recreate clips_fts with both indexed columns.
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    text_content,
                    image_description,
                    content='clips',
                    content_rowid='id'
                )
            """)

            // Repopulate the FTS index from existing clips data.
            // image_description is NULL for all existing clips (just added by ALTER TABLE above).
            try db.execute(sql: """
                INSERT INTO clips_fts(rowid, text_content, image_description)
                SELECT id, text_content, image_description
                FROM clips
                WHERE is_indexed = 1
                  AND (text_content IS NOT NULL OR image_description IS NOT NULL)
            """)

            // Recreate triggers to sync both FTS columns on insert/delete/update.
            try db.execute(sql: """
                CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                    INSERT INTO clips_fts(rowid, text_content, image_description)
                    SELECT new.id, new.text_content, new.image_description
                    WHERE new.is_indexed = 1
                      AND (new.text_content IS NOT NULL OR new.image_description IS NOT NULL);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content, image_description)
                    SELECT 'delete', old.id, old.text_content, old.image_description
                    WHERE old.is_indexed = 1
                      AND (old.text_content IS NOT NULL OR old.image_description IS NOT NULL);
                END
            """)

            try db.execute(sql: """
                CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                    INSERT INTO clips_fts(clips_fts, rowid, text_content, image_description)
                    SELECT 'delete', old.id, old.text_content, old.image_description
                    WHERE old.is_indexed = 1
                      AND (old.text_content IS NOT NULL OR old.image_description IS NOT NULL);
                    INSERT INTO clips_fts(rowid, text_content, image_description)
                    SELECT new.id, new.text_content, new.image_description
                    WHERE new.is_indexed = 1
                      AND (new.text_content IS NOT NULL OR new.image_description IS NOT NULL);
                END
            """)

            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('optimize')")
        }

        migrator.registerMigration("v5") { db in
            // Conversations table
            try db.create(table: "conversations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Chat messages table
            try db.create(table: "chat_messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversation_id", .integer).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("cited_clip_ids", .text)
                t.column("created_at", .double).notNull()
            }

            try db.execute(sql: """
                CREATE INDEX idx_chat_messages_conv
                ON chat_messages(conversation_id, created_at)
            """)
        }

        // Strip HTML tags from textContent of existing html clips so search/display/AI
        // see plain text. The original HTML is preserved in the media file for paste-back.
        // Also resets AI processing so clips get re-classified with clean text.
        migrator.registerMigration("v6") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, text_content FROM clips
                WHERE content_type = 'html' AND text_content IS NOT NULL
            """)
            for row in rows {
                let id: Int64 = row["id"]
                let html: String = row["text_content"]
                let plain = html
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&#160;", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try db.execute(
                    sql: "UPDATE clips SET text_content = ?, ai_processed = 0, tags = NULL WHERE id = ?",
                    arguments: [plain, id]
                )
            }
            try db.execute(sql: "INSERT INTO clips_fts(clips_fts) VALUES('rebuild')")
        }

        // Per-conversation topic — drives whether the menubar chat answers from clipboard
        // clips or audio transcripts. Defaults to 'clips' for all existing conversations.
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                ALTER TABLE conversations
                ADD COLUMN topic TEXT NOT NULL DEFAULT 'clips'
            """)
        }

        try migrator.migrate(dbQueue)
    }
}
