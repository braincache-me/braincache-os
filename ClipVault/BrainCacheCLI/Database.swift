import Foundation
import GRDB

/// Read-only handle to the BrainCache SQLite database.
///
/// The CLI never writes — we open the queue with read-only access flags so
/// concurrent runs (and concurrent CLI + app activity) can't accidentally
/// corrupt the WAL. Multiple read-only connections are safe under WAL mode.
struct BrainCacheDB {

    let dbQueue: DatabaseQueue
    let path: String

    static func open() throws -> BrainCacheDB {
        let url = try BrainCacheConfig.databaseURL()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else {
            throw CLIError.databaseMissing(path: url.path)
        }

        var config = Configuration()
        config.readonly = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA query_only = 1")
        }
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return BrainCacheDB(dbQueue: queue, path: url.path)
    }
}

/// A clipboard or audio-transcript row, as returned by the CLI.
///
/// This deliberately diverges from the app's `ClipRecord` to keep the CLI
/// independent: no shared sources, the row model is just what we read off
/// the SQLite table.
struct ClipRow: Codable {
    let id: Int64
    let contentType: String
    let textContent: String?
    let mediaFileName: String?
    let fileURL: String?
    let sourceApp: String?
    let byteSize: Int
    let createdAt: Double
    let isPinned: Bool
    let tags: [String]
    let imageDescription: String?

    static func fetch(_ db: Database, sql: String, arguments: StatementArguments) throws -> [ClipRow] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        return rows.map(ClipRow.init(row:))
    }

    init(row: Row) {
        id = row["id"]
        contentType = row["content_type"] ?? "text"
        textContent = row["text_content"]
        mediaFileName = row["media_file_name"]
        fileURL = row["file_url"]
        sourceApp = row["source_app"]
        byteSize = row["byte_size"] ?? 0
        createdAt = row["created_at"] ?? 0
        isPinned = (row["is_pinned"] as Int? ?? 0) != 0
        let tagsJSON: String? = row["tags"]
        if let json = tagsJSON, let data = json.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String].self, from: data) {
            tags = parsed
        } else {
            tags = []
        }
        imageDescription = row["image_description"]
    }

    var createdAtDate: Date {
        Date(timeIntervalSince1970: createdAt)
    }

    /// Returns the absolute path to the media file backing this clip, if any.
    var mediaFilePath: String? {
        guard let name = mediaFileName,
              let mediaDir = try? BrainCacheConfig.mediaDirectoryURL() else {
            return nil
        }
        return mediaDir.appendingPathComponent(name).path
    }

    /// True when this row came from the voice-transcription pipeline.
    var isAudioTranscript: Bool {
        sourceApp == "BrainCache Voice"
    }

    /// A short, single-line preview suitable for table rows.
    var preview: String {
        if let text = textContent, !text.isEmpty {
            return text.singleLinePreview(maxChars: 80)
        }
        if let desc = imageDescription, !desc.isEmpty {
            return "🖼 " + desc.singleLinePreview(maxChars: 76)
        }
        return "[\(contentType)] (\(byteSize) bytes)"
    }
}

extension String {
    /// Collapses whitespace and truncates to a single line of at most `maxChars`
    /// characters, adding an ellipsis when truncated.
    func singleLinePreview(maxChars: Int) -> String {
        let collapsed = self
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if trimmed.count <= maxChars { return trimmed }
        let prefix = trimmed.prefix(maxChars - 1)
        return String(prefix) + "…"
    }
}
