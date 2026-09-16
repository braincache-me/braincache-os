import Foundation
import GRDB

/// Row model for the clips table.
struct ClipRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let audioTranscriptSourceApp = "BrainCache Voice"

    var id: Int64?
    var contentType: String
    var textContent: String?
    var dataHash: String
    var mediaFileName: String?
    var fileURL: String?
    var sourceApp: String?
    var byteSize: Int
    var createdAt: Double
    var lastUsedAt: Double?
    var isPinned: Bool
    var isIndexed: Bool
    // AI metadata — added in migration v4
    var tags: String? = nil
    var imageDescription: String? = nil
    var aiProcessed: Int = 0
    var aiProcessedAt: Double? = nil

    static let databaseTableName = "clips"

    enum Columns {
        static let id = Column("id")
        static let contentType = Column("content_type")
        static let textContent = Column("text_content")
        static let dataHash = Column("data_hash")
        static let mediaFileName = Column("media_file_name")
        static let fileURL = Column("file_url")
        static let sourceApp = Column("source_app")
        static let byteSize = Column("byte_size")
        static let createdAt = Column("created_at")
        static let lastUsedAt = Column("last_used_at")
        static let isPinned = Column("is_pinned")
        static let isIndexed = Column("is_indexed")
        static let tags = Column("tags")
        static let imageDescription = Column("image_description")
        static let aiProcessed = Column("ai_processed")
        static let aiProcessedAt = Column("ai_processed_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case contentType = "content_type"
        case textContent = "text_content"
        case dataHash = "data_hash"
        case mediaFileName = "media_file_name"
        case fileURL = "file_url"
        case sourceApp = "source_app"
        case byteSize = "byte_size"
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
        case isPinned = "is_pinned"
        case isIndexed = "is_indexed"
        case tags
        case imageDescription = "image_description"
        case aiProcessed = "ai_processed"
        case aiProcessedAt = "ai_processed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decodes the JSON-encoded tags string into a Swift array.
    var parsedTags: [String] {
        guard let json = tags,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    var isAudioTranscript: Bool {
        sourceApp == Self.audioTranscriptSourceApp
    }
}

final class ClipStore {

    private let dbQueue: DatabaseQueue
    private let mediaFileManager: MediaFileManager
    private static let aiRepairWhereClause = """
        ai_processed != 1
        OR (
            ai_processed = 1
            AND NOT EXISTS (SELECT 1 FROM clip_embeddings WHERE clip_id = clips.id)
        )
        OR (
            ai_processed = 1
            AND content_type = 'image'
            AND media_file_name IS NOT NULL
            AND (image_description IS NULL OR trim(image_description) = '')
        )
    """
    private static let automaticAIRepairWhereClause = """
        ai_processed = 0
        OR (
            ai_processed = 1
            AND NOT EXISTS (SELECT 1 FROM clip_embeddings WHERE clip_id = clips.id)
        )
        OR (
            ai_processed = 1
            AND content_type = 'image'
            AND media_file_name IS NOT NULL
            AND (image_description IS NULL OR trim(image_description) = '')
        )
        OR (
            ai_processed = 2
            AND (ai_processed_at IS NULL OR ai_processed_at <= ?)
        )
    """

    init(dbQueue: DatabaseQueue, mediaFileManager: MediaFileManager = .shared) {
        self.dbQueue = dbQueue
        self.mediaFileManager = mediaFileManager
    }

    // MARK: - Insert

    @discardableResult
    func insert(entry: ClipboardEntry) throws -> Int64 {
        var savedMediaFileName: String? = nil
        // Save raw payload to disk for binary types (image/RTF/HTML) and also for large
        // plain-text or file-URL clips whose textContent was dropped because they exceed the
        // index size threshold — without this the record would be display-only and impossible
        // to paste back.
        if (entry.contentType == .image || entry.contentType == .rtf || entry.contentType == .html
            || entry.contentType == .pdf
            || (entry.contentType == .text && entry.textContent == nil)
            || (entry.contentType == .file && entry.textContent == nil)),
           let rawData = entry.rawData {
            let ext = mediaExtension(for: entry)
            savedMediaFileName = try mediaFileManager.save(rawData, extension: ext)
        }
        var record = ClipRecord(
            id: nil,
            contentType: entry.contentType.rawValue,
            textContent: entry.textContent,
            dataHash: entry.dataHash,
            mediaFileName: savedMediaFileName,
            fileURL: entry.fileURL?.absoluteString,
            sourceApp: entry.sourceApp,
            byteSize: entry.byteSize,
            createdAt: entry.createdAt.timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: entry.isIndexed
        )
        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
        } catch {
            if let filename = savedMediaFileName {
                try? mediaFileManager.delete(filename: filename)
            }
            throw error
        }
        guard let id = record.id else {
            throw DatabaseError(message: "Insert succeeded but rowID was not set")
        }
        return id
    }

    private func mediaExtension(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case .text: return "txt"
        case .file: return "txt"
        case .rtf: return "rtf"
        case .html: return "html"
        case .pdf: return "pdf"
        case .image:
            guard let data = entry.rawData, data.count >= 4 else { return "bin" }
            // PNG magic: 89 50 4E 47
            if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
                return "png"
            }
            return "tiff"
        }
    }

    // MARK: - Fetch

    func fetchRecent(limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord
                .order(
                    ClipRecord.Columns.isPinned.desc,
                    ClipRecord.Columns.createdAt.desc
                )
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetchRecentClipboardClips(limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE source_app IS NULL OR source_app != ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [ClipRecord.audioTranscriptSourceApp, limit, offset]
            )
        }
    }

    func fetchRecentAudioTranscripts(limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE source_app = ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ? OFFSET ?
                """,
                arguments: [ClipRecord.audioTranscriptSourceApp, limit, offset]
            )
        }
    }

    // MARK: - Search

    func search(query: String, limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        guard !query.isEmpty else {
            return try fetchRecent(limit: limit, offset: offset)
        }
        guard let ftsQuery = makeFTSQuery(for: query) else {
            return try fetchRecent(limit: limit, offset: offset)
        }

        return try dbQueue.read { db in
            let sql = """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
                ORDER BY
                    clips.is_pinned DESC,
                    rank * exp(-0.001 * (unixepoch() - clips.created_at)) ASC
                LIMIT ? OFFSET ?
            """
            return try ClipRecord.fetchAll(db, sql: sql, arguments: [ftsQuery, limit, offset])
        }
    }

    func searchClipboardHistory(query: String, limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        guard !query.isEmpty else {
            return try fetchRecentClipboardClips(limit: limit, offset: offset)
        }
        guard let ftsQuery = makeFTSQuery(for: query) else {
            return try fetchRecentClipboardClips(limit: limit, offset: offset)
        }

        return try dbQueue.read { db in
            let sql = """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
                  AND (clips.source_app IS NULL OR clips.source_app != ?)
                ORDER BY
                    clips.is_pinned DESC,
                    rank * exp(-0.001 * (unixepoch() - clips.created_at)) ASC
                LIMIT ? OFFSET ?
            """
            return try ClipRecord.fetchAll(
                db,
                sql: sql,
                arguments: [ftsQuery, ClipRecord.audioTranscriptSourceApp, limit, offset]
            )
        }
    }

    func searchAudioTranscripts(query: String, limit: Int = 50, offset: Int = 0) throws -> [ClipRecord] {
        guard !query.isEmpty else {
            return try fetchRecentAudioTranscripts(limit: limit, offset: offset)
        }
        guard let ftsQuery = makeFTSQuery(for: query) else {
            return try fetchRecentAudioTranscripts(limit: limit, offset: offset)
        }

        return try dbQueue.read { db in
            let sql = """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
                  AND clips.source_app = ?
                ORDER BY
                    clips.is_pinned DESC,
                    rank * exp(-0.001 * (unixepoch() - clips.created_at)) ASC
                LIMIT ? OFFSET ?
            """
            return try ClipRecord.fetchAll(
                db,
                sql: sql,
                arguments: [ftsQuery, ClipRecord.audioTranscriptSourceApp, limit, offset]
            )
        }
    }

    private func makeFTSQuery(for query: String) -> String? {
        let tokens = query.split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { i, tok -> String in
            let escaped = tok.replacingOccurrences(of: "\"", with: "\"\"")
            if i == tokens.count - 1 {
                return "\"\(escaped)\"*"
            }
            return "\"\(escaped)\""
        }.joined(separator: " ")
    }

    // MARK: - Delete / Purge

    func deleteById(_ id: Int64) throws {
        var filename: String? = nil
        try dbQueue.write { db in
            filename = try String.fetchOne(db, sql: "SELECT media_file_name FROM clips WHERE id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM clips WHERE id = ?", arguments: [id])
        }
        if let filename {
            try? mediaFileManager.delete(filename: filename)
        }
    }

    func deleteAll() throws {
        var filenames: [String] = []
        try dbQueue.write { db in
            filenames = try String.fetchAll(db, sql: "SELECT media_file_name FROM clips WHERE media_file_name IS NOT NULL")
            try db.execute(sql: "DELETE FROM clips")
        }
        for filename in filenames {
            try? mediaFileManager.delete(filename: filename)
        }
    }

    func purgeOlderThan(days: Int) throws {
        let cutoff = Date().timeIntervalSince1970 - Double(days) * 86400
        var filenames: [String] = []
        try dbQueue.write { db in
            filenames = try String.fetchAll(
                db,
                sql: "SELECT media_file_name FROM clips WHERE created_at < ? AND is_pinned = 0 AND media_file_name IS NOT NULL",
                arguments: [cutoff]
            )
            try db.execute(
                sql: "DELETE FROM clips WHERE created_at < ? AND is_pinned = 0",
                arguments: [cutoff]
            )
        }
        for filename in filenames {
            try? mediaFileManager.delete(filename: filename)
        }
    }

    func purgeExceedingCount(max: Int) throws {
        var filenames: [String] = []
        try dbQueue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clips WHERE is_pinned = 0") ?? 0
            guard count > max else { return }
            let excess = count - max
            // Fetch the oldest non-pinned rows in a single query to ensure filenames and
            // IDs come from exactly the same set of rows. Using two separate ORDER BY/LIMIT
            // queries with different WHERE clauses (one filtering on media_file_name IS NOT NULL)
            // could select different rows, causing orphaned files or missed deletions.
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, media_file_name FROM clips
                WHERE is_pinned = 0
                ORDER BY created_at ASC, id ASC
                LIMIT ?
            """, arguments: [excess])
            let ids = rows.compactMap { $0["id"] as Int64? }
            filenames = rows.compactMap { $0["media_file_name"] as String? }
            guard !ids.isEmpty else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(
                sql: "DELETE FROM clips WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
        for filename in filenames {
            try? mediaFileManager.delete(filename: filename)
        }
    }

    // MARK: - Bulk Helpers

    /// Insert a pre-built record directly (used by importers).
    @discardableResult
    func insertRecord(_ record: inout ClipRecord) throws -> Int64 {
        try dbQueue.write { db in
            try record.insert(db)
        }
        guard let id = record.id else {
            throw DatabaseError(message: "Insert succeeded but rowID was not set")
        }
        return id
    }

    /// Check whether a given data_hash already exists (O(log n) via index).
    func containsHash(_ hash: String) throws -> Bool {
        try dbQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM clips WHERE data_hash = ?)",
                arguments: [hash]
            ) ?? false
        }
    }

    // MARK: - Pin

    func pinClip(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET is_pinned = 1 WHERE id = ?", arguments: [id])
        }
    }

    func unpinClip(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clips SET is_pinned = 0 WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - AI Processing

    /// Returns clips that have not yet been processed by the AI pipeline (ai_processed = 0).
    func fetchUnprocessed(limit: Int = 50) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord
                .filter(ClipRecord.Columns.aiProcessed == 0)
                .order(ClipRecord.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Marks a clip as successfully AI-processed, storing its tags and image description.
    func markProcessed(id: Int64, tags: String?, imageDescription: String?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE clips SET
                        ai_processed = 1,
                        ai_processed_at = ?,
                        tags = ?,
                        image_description = ?
                    WHERE id = ?
                """,
                arguments: [Date().timeIntervalSince1970, tags, imageDescription, id]
            )
        }
    }

    /// Marks a clip as failed AI processing (ai_processed = 2). The pipeline will not retry
    /// it automatically; the user can trigger a re-index to reset all failed clips.
    func markFailed(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clips SET ai_processed = 2, ai_processed_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }

    /// Fetches clips by a list of IDs, preserving the order of the input array.
    func fetchByIds(_ ids: [Int64]) throws -> [ClipRecord] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let records = try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: "SELECT * FROM clips WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
        let byId = Dictionary(uniqueKeysWithValues: records.compactMap { r in r.id.map { ($0, r) } })
        return ids.compactMap { byId[$0] }
    }

    /// Fetches a single clip by its primary key, or nil if not found.
    func fetchById(_ id: Int64) throws -> ClipRecord? {
        try dbQueue.read { db in
            try ClipRecord.fetchOne(db, sql: "SELECT * FROM clips WHERE id = ?", arguments: [id])
        }
    }

    /// Resets all clips (including previously failed ones) to unprocessed so the pipeline re-indexes them.
    func resetAllToUnprocessed() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clips SET ai_processed = 0, ai_processed_at = NULL"
            )
        }
    }

    /// Returns the number of clips that are missing AI artifacts or were left unprocessed.
    func countClipsNeedingAIRepair() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE \(Self.aiRepairWhereClause)"
            ) ?? 0
        }
    }

    /// Resets only clips with missing AI artifacts so the pipeline can repair them.
    @discardableResult
    func resetClipsNeedingAIRepair() throws -> Int {
        try dbQueue.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE \(Self.aiRepairWhereClause)"
            ) ?? 0

            guard count > 0 else { return 0 }

            try db.execute(
                sql: """
                    UPDATE clips
                    SET ai_processed = 0, ai_processed_at = NULL
                    WHERE \(Self.aiRepairWhereClause)
                """
            )
            return count
        }
    }

    /// Resets clips that should be retried automatically. Recent failures are left alone
    /// until `failedRetryDelay` has elapsed so transient outages recover without hammering
    /// the API every safety-net tick.
    @discardableResult
    func resetClipsNeedingAutomaticAIRepair(failedRetryDelay: TimeInterval) throws -> Int {
        let cutoff = Date().timeIntervalSince1970 - failedRetryDelay
        return try dbQueue.write { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clips WHERE \(Self.automaticAIRepairWhereClause)",
                arguments: [cutoff]
            ) ?? 0

            guard count > 0 else { return 0 }

            try db.execute(
                sql: """
                    UPDATE clips
                    SET ai_processed = 0, ai_processed_at = NULL
                    WHERE \(Self.automaticAIRepairWhereClause)
                """,
                arguments: [cutoff]
            )
            return count
        }
    }

    /// Rebuilds the FTS table and triggers from the current clips table contents.
    func rebuildSearchIndex() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS clips_au")
            try db.execute(sql: "DROP TABLE IF EXISTS clips_fts")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE clips_fts USING fts5(
                    text_content,
                    image_description,
                    content='clips',
                    content_rowid='id'
                )
            """)

            try db.execute(sql: """
                INSERT INTO clips_fts(rowid, text_content, image_description)
                SELECT id, text_content, image_description
                FROM clips
                WHERE is_indexed = 1
                  AND (text_content IS NOT NULL OR image_description IS NOT NULL)
            """)

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
    }

    // MARK: - Filtered Fetch (Agentic RAG)

    /// Fetches clips whose `source_app` contains `appName` (case-insensitive LIKE match).
    func fetchByApp(appName: String, limit: Int = 20) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE source_app LIKE ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ?
                """,
                arguments: ["%\(appName)%", limit]
            )
        }
    }

    /// Fetches clips whose `created_at` falls within `[start, end]` (Unix timestamps).
    func fetchByDateRange(start: Double, end: Double, limit: Int = 20) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE created_at BETWEEN ? AND ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ?
                """,
                arguments: [start, end, limit]
            )
        }
    }

    /// Fetches clips whose JSON-encoded `tags` column contains the specified tags.
    ///
    /// Uses a LIKE-based approach (`tags LIKE '%"tagname"%'`) so no SQLite JSON extension
    /// is required. `matchAll = true` requires ALL tags to be present; `false` requires ANY.
    func fetchByTags(tags: [String], matchAll: Bool = false, limit: Int = 20) throws -> [ClipRecord] {
        guard !tags.isEmpty else { return [] }

        // Build one LIKE condition per tag: tags LIKE '%"tagname"%'
        let conditions = tags.map { _ in "tags LIKE ?" }
        let joiner = matchAll ? " AND " : " OR "
        let whereClause = conditions.joined(separator: joiner)
        let args: [DatabaseValueConvertible] = tags.map { "%\"\($0)\"%" as DatabaseValueConvertible }
            + [limit as DatabaseValueConvertible]

        return try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE \(whereClause)
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// Fetches clips whose `content_type` exactly matches `contentType`.
    func fetchByContentType(contentType: String, limit: Int = 20) throws -> [ClipRecord] {
        try dbQueue.read { db in
            try ClipRecord.fetchAll(
                db,
                sql: """
                    SELECT * FROM clips
                    WHERE content_type = ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ?
                """,
                arguments: [contentType, limit]
            )
        }
    }

    // MARK: - Update text content (live transcript drafts)

    /// Rewrites the text of an existing clip in place. Used by the voice
    /// transcription draft flush so an in-progress transcript is persisted
    /// every few seconds into the *same* clip instead of piling up copies.
    /// The FTS `clips_au` trigger keeps the search index in sync.
    ///
    /// - Parameter resetAIProcessing: `true` for the final save of a session
    ///   so the AI pipeline re-classifies / re-embeds the finished text.
    ///   Draft flushes pass `false` so a partial transcript isn't re-indexed
    ///   on every flush.
    func updateTextContent(id: Int64, text: String, resetAIProcessing: Bool) throws {
        let hash = Hashing.sha256(data: Data(text.utf8))
        try dbQueue.write { db in
            if resetAIProcessing {
                try db.execute(
                    sql: """
                        UPDATE clips
                        SET text_content = ?, data_hash = ?, byte_size = ?,
                            ai_processed = 0, ai_processed_at = NULL, tags = NULL
                        WHERE id = ?
                        """,
                    arguments: [text, hash, text.utf8.count, id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE clips SET text_content = ?, data_hash = ?, byte_size = ? WHERE id = ?",
                    arguments: [text, hash, text.utf8.count, id]
                )
            }
        }
    }

    // MARK: - Update last_used_at

    func touchLastUsed(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clips SET last_used_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }
}
