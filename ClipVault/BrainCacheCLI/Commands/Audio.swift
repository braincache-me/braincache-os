import ArgumentParser
import Foundation
import GRDB

/// `braincache audio …` — voice transcription sessions.
///
/// Audio transcripts are stored in the same `clips` table as clipboard rows,
/// distinguished by `source_app = "BrainCache Voice"`. Each row is one
/// recorded session and its `text_content` is the concatenated mic + system
/// transcript. The CLI exposes them under their own subcommand so callers
/// don't have to know that storage detail.
struct Audio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audio",
        abstract: "Read voice transcription sessions.",
        subcommands: [List.self, Search.self, Show.self]
    )

    private static let sourceAppMarker = "BrainCache Voice"

    // MARK: - audio list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List recent voice transcription sessions, newest first."
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: [.short, .long], help: "Number of sessions to return.")
        var last: Int = 20

        @Option(name: .long, help: "Skip the first N rows.")
        var offset: Int = 0

        @Flag(name: .long, help: "Include the full transcript in JSON output.")
        var full: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            let rows = try db.dbQueue.read { conn in
                try ClipRow.fetch(conn, sql: """
                    SELECT * FROM clips
                    WHERE source_app = ?
                    ORDER BY is_pinned DESC, created_at DESC
                    LIMIT ? OFFSET ?
                """, arguments: [Audio.sourceAppMarker, last, offset])
            }
            Audio.render(rows: rows, mode: global.output, full: full)
        }
    }

    // MARK: - audio search

    struct Search: ParsableCommand {
        enum Mode: String, ExpressibleByArgument, CaseIterable {
            case grep, fts, vector, hybrid
        }

        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search inside voice transcripts."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Search query.")
        var query: String

        @Option(name: [.customShort("m"), .long], help: "grep | fts | vector | hybrid (default: fts).")
        var mode: Mode = .fts

        @Option(name: [.short, .long], help: "Maximum results.")
        var limit: Int = 20

        @Flag(name: .long, help: "Match case-sensitively (grep mode only).")
        var caseSensitive: Bool = false

        @Flag(name: .long, help: "Treat the query as a literal string (grep mode only).")
        var fixedStrings: Bool = false

        @Flag(name: .long, help: "Include the full transcript in JSON output.")
        var full: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            // Reuse the clips-side helpers but restrict to audio rows only.
            // `includeAudio` is irrelevant here; we filter to source_app =
            // "BrainCache Voice" in a post-fetch step so we share one
            // codepath across all four modes without duplicating SQL.
            let raw: [ClipRow]
            switch mode {
            case .fts:
                raw = try audioFTS(db: db, query: query, limit: limit)
            case .grep:
                raw = try audioGrep(db: db, query: query, caseSensitive: caseSensitive,
                                    fixedStrings: fixedStrings, limit: limit)
            case .vector:
                raw = try audioVector(db: db, query: query, limit: limit)
            case .hybrid:
                raw = try audioHybrid(db: db, query: query, limit: limit)
            }
            Audio.render(rows: raw, mode: global.output, full: full)
        }
    }

    // MARK: - audio show

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the full transcript of one session by ID."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Audio session ID (as printed by `audio list`).")
        var id: Int64

        @Flag(name: .long, help: "Print only the transcript body (no metadata).")
        var raw: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            let row = try db.dbQueue.read { conn in
                try ClipRow.fetch(conn, sql: """
                    SELECT * FROM clips WHERE id = ? AND source_app = ? LIMIT 1
                """, arguments: [id, Audio.sourceAppMarker]).first
            }
            guard let row else { throw CLIError.unknownClip(id) }

            if raw {
                if let text = row.textContent { print(text) }
                return
            }
            Renderer(global.output).writeObject(AudioDetail(row: row))
        }
    }

    // MARK: - Search backends (audio-only variants of the clips helpers)

    private static func audioFTS(db: BrainCacheDB, query: String, limit: Int) throws -> [ClipRow] {
        let ftsQuery = makeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }
        return try db.dbQueue.read { conn in
            try ClipRow.fetch(conn, sql: """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
                  AND clips.source_app = ?
                ORDER BY clips.is_pinned DESC,
                         rank * exp(-0.001 * (unixepoch() - clips.created_at)) ASC
                LIMIT ?
            """, arguments: [ftsQuery, sourceAppMarker, limit])
        }
    }

    private static func audioGrep(db: BrainCacheDB, query: String,
                                  caseSensitive: Bool, fixedStrings: Bool,
                                  limit: Int) throws -> [ClipRow] {
        let pattern = fixedStrings ? NSRegularExpression.escapedPattern(for: query) : query
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw CLIError.invalidRegex(query, underlying: error.localizedDescription)
        }
        let candidates = try db.dbQueue.read { conn in
            try ClipRow.fetch(conn, sql: """
                SELECT * FROM clips
                WHERE source_app = ?
                  AND text_content IS NOT NULL
                ORDER BY is_pinned DESC, created_at DESC
                LIMIT ?
            """, arguments: [sourceAppMarker, max(limit * 50, 1000)])
        }
        var out: [ClipRow] = []
        for row in candidates {
            guard let hay = row.textContent else { continue }
            let range = NSRange(hay.startIndex..., in: hay)
            if regex.firstMatch(in: hay, options: [], range: range) != nil {
                out.append(row)
                if out.count >= limit { break }
            }
        }
        return out
    }

    private static func audioVector(db: BrainCacheDB, query: String, limit: Int) throws -> [ClipRow] {
        let model = BrainCacheConfig.embeddingModel
        let storedDimensions = try db.dbQueue.read { conn -> Int? in
            try Int.fetchOne(conn, sql: "SELECT dimensions FROM clip_embeddings LIMIT 1")
        }
        let dims = storedDimensions ?? 256
        let queryVec = try EmbeddingClient.embed(query: query, model: model, dimensions: dims)

        // Inner join restricts to clips whose source_app marks them as audio,
        // so we never spend CPU on clipboard embeddings.
        struct Candidate { let clipId: Int64; let distance: Float }
        let candidates: [Candidate] = try db.dbQueue.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT clip_embeddings.clip_id, clip_embeddings.embedding
                FROM clip_embeddings
                JOIN clips ON clips.id = clip_embeddings.clip_id
                WHERE clips.source_app = ?
            """, arguments: [sourceAppMarker])
            return rows.compactMap { row -> Candidate? in
                guard let cid = row["clip_id"] as Int64?,
                      let blob = row["embedding"] as? Data else { return nil }
                let v = VectorMath.dataToFloats(blob)
                guard v.count == queryVec.count else { return nil }
                return Candidate(clipId: cid, distance: VectorMath.cosineDistance(queryVec, v))
            }
        }
        let topIds = candidates.sorted { $0.distance < $1.distance }.prefix(limit).map { $0.clipId }
        if topIds.isEmpty { return [] }

        let placeholders = Array(repeating: "?", count: topIds.count).joined(separator: ",")
        let args: [DatabaseValueConvertible] = topIds.map { $0 as DatabaseValueConvertible }
        let fetched = try db.dbQueue.read { conn in
            try ClipRow.fetch(conn, sql: "SELECT * FROM clips WHERE id IN (\(placeholders))",
                              arguments: StatementArguments(args))
        }
        let byId = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return topIds.compactMap { byId[$0] }
    }

    private static func audioHybrid(db: BrainCacheDB, query: String, limit: Int) throws -> [ClipRow] {
        let k = 60.0
        let fts = try audioFTS(db: db, query: query, limit: limit * 2)
        let vec = (try? audioVector(db: db, query: query, limit: limit * 2)) ?? []
        var scores: [Int64: Double] = [:]
        var rows: [Int64: ClipRow] = [:]
        for (rank, r) in fts.enumerated() {
            scores[r.id, default: 0] += 1.0 / (k + Double(rank + 1))
            rows[r.id] = r
        }
        for (rank, r) in vec.enumerated() {
            scores[r.id, default: 0] += 1.0 / (k + Double(rank + 1))
            rows[r.id] = r
        }
        return scores.sorted { $0.value > $1.value }.prefix(limit).compactMap { rows[$0.key] }
    }

    private static func makeFTSQuery(_ raw: String) -> String {
        let tokens = raw.split(separator: " ")
        guard !tokens.isEmpty else { return "" }
        return tokens.enumerated().map { i, t -> String in
            let escaped = t.replacingOccurrences(of: "\"", with: "\"\"")
            return i == tokens.count - 1 ? "\"\(escaped)\"*" : "\"\(escaped)\""
        }.joined(separator: " ")
    }

    // MARK: - Rendering

    private static func render(rows: [ClipRow], mode: OutputMode, full: Bool) {
        let renderer = Renderer(mode)
        switch renderer.mode {
        case .json:
            for row in rows {
                renderer.writeOne(AudioRowJSON(row: row, full: full))
            }
        case .table:
            let cols: [TableColumn<ClipRow>] = [
                TableColumn(title: "ID",       value: { String($0.id) }),
                TableColumn(title: "WHEN",     value: { cliIsoFormatter.string(from: $0.createdAtDate) }),
                TableColumn(title: "SIZE",     value: { String($0.byteSize) }),
                TableColumn(title: "TAGS",     value: { $0.tags.joined(separator: ",") }),
                TableColumn(title: "PREVIEW",  value: { $0.preview }),
            ]
            renderer.write(rows, columns: cols)
        }
    }
}

struct AudioRowJSON: Encodable {
    let id: Int64
    let createdAt: String
    let byteSize: Int
    let tags: [String]
    let preview: String
    let transcript: String?

    init(row: ClipRow, full: Bool) {
        id = row.id
        createdAt = cliIsoFormatter.string(from: row.createdAtDate)
        byteSize = row.byteSize
        tags = row.tags
        preview = row.preview
        transcript = full ? row.textContent : nil
    }
}

struct AudioDetail: Encodable {
    let id: Int64
    let createdAt: String
    let byteSize: Int
    let tags: [String]
    let transcript: String?
    let isPinned: Bool

    init(row: ClipRow) {
        id = row.id
        createdAt = cliIsoFormatter.string(from: row.createdAtDate)
        byteSize = row.byteSize
        tags = row.tags
        transcript = row.textContent
        isPinned = row.isPinned
    }
}
