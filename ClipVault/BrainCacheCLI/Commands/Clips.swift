import ArgumentParser
import Foundation
import GRDB

struct Clips: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clips",
        abstract: "Read clipboard history (excludes voice transcripts — see `braincache audio`).",
        subcommands: [List.self, Search.self, Show.self]
    )

    // MARK: - clips list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the most recent clipboard entries, newest first."
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: [.short, .long], help: "Number of clips to return.")
        var last: Int = 20

        @Option(name: .long, help: "Skip the first N rows (paging).")
        var offset: Int = 0

        @Flag(name: .long, help: "Include voice transcripts as well as clipboard entries.")
        var includeAudio: Bool = false

        @Flag(name: .long, help: "Return only pinned clips.")
        var pinnedOnly: Bool = false

        @Flag(name: .long, help: "Include full text/image-description content in JSON output (table mode is always preview-only).")
        var full: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            let rows: [ClipRow] = try db.dbQueue.read { conn in
                var sql = "SELECT * FROM clips WHERE 1=1"
                var args: [DatabaseValueConvertible] = []
                if !includeAudio {
                    sql += " AND (source_app IS NULL OR source_app != ?)"
                    args.append("BrainCache Voice")
                }
                if pinnedOnly {
                    sql += " AND is_pinned = 1"
                }
                sql += " ORDER BY is_pinned DESC, created_at DESC LIMIT ? OFFSET ?"
                args.append(last)
                args.append(offset)
                return try ClipRow.fetch(conn, sql: sql, arguments: StatementArguments(args))
            }
            Clips.render(rows: rows, mode: global.output, full: full)
        }
    }

    // MARK: - clips search

    struct Search: ParsableCommand {
        enum Mode: String, ExpressibleByArgument, CaseIterable {
            case grep, fts, vector, hybrid
        }

        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Search clipboard history by FTS5 phrase, regex grep, or vector similarity."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Search query. Treated as an FTS5 phrase, a regex, or a semantic query depending on --mode.")
        var query: String

        @Option(name: [.customShort("m"), .long], help: "grep | fts | vector | hybrid (default: fts)")
        var mode: Mode = .fts

        @Option(name: [.short, .long], help: "Maximum results to return.")
        var limit: Int = 20

        @Flag(name: .long, help: "Match case-sensitively (grep mode only).")
        var caseSensitive: Bool = false

        @Flag(name: .long, help: "Treat the query as a literal string instead of a regex (grep mode only).")
        var fixedStrings: Bool = false

        @Flag(name: .long, help: "Include voice transcripts.")
        var includeAudio: Bool = false

        @Flag(name: .long, help: "Include full text/image-description content in JSON output.")
        var full: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            let rows: [ClipRow]
            switch mode {
            case .fts:
                rows = try Clips.ftsSearch(db: db, query: query, includeAudio: includeAudio, limit: limit)
            case .grep:
                rows = try Clips.grepSearch(db: db, pattern: query, caseSensitive: caseSensitive,
                                            fixedStrings: fixedStrings, includeAudio: includeAudio, limit: limit)
            case .vector:
                rows = try Clips.vectorSearch(db: db, query: query, includeAudio: includeAudio, limit: limit)
            case .hybrid:
                rows = try Clips.hybridSearch(db: db, query: query, includeAudio: includeAudio, limit: limit)
            }
            Clips.render(rows: rows, mode: global.output, full: full)
        }
    }

    // MARK: - clips show

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print the full content of one clip by ID."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Clip ID (as printed by `clips list`).")
        var id: Int64

        @Flag(name: .long, help: "Print only the textual body to stdout (no metadata), suitable for piping.")
        var raw: Bool = false

        func run() throws {
            global.apply()
            let db = try BrainCacheDB.open()
            let row = try db.dbQueue.read { conn -> ClipRow? in
                try ClipRow.fetch(conn, sql: "SELECT * FROM clips WHERE id = ? LIMIT 1",
                                  arguments: [id]).first
            }
            guard let row else { throw CLIError.unknownClip(id) }

            if raw {
                if let text = row.textContent {
                    print(text)
                } else if let desc = row.imageDescription {
                    print(desc)
                } else if let path = row.mediaFilePath {
                    print(path)
                }
                return
            }
            Renderer(global.output).writeObject(ClipDetail(row: row))
        }
    }

    // MARK: - Search helpers

    fileprivate static func ftsSearch(db: BrainCacheDB, query: String,
                                      includeAudio: Bool, limit: Int) throws -> [ClipRow] {
        let ftsQuery = makeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }
        return try db.dbQueue.read { conn in
            var sql = """
                SELECT clips.*
                FROM clips
                JOIN clips_fts ON clips.id = clips_fts.rowid
                WHERE clips_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [ftsQuery]
            if !includeAudio {
                sql += " AND (clips.source_app IS NULL OR clips.source_app != ?)"
                args.append("BrainCache Voice")
            }
            sql += """

                ORDER BY clips.is_pinned DESC,
                         rank * exp(-0.001 * (unixepoch() - clips.created_at)) ASC
                LIMIT ?
            """
            args.append(limit)
            return try ClipRow.fetch(conn, sql: sql, arguments: StatementArguments(args))
        }
    }

    fileprivate static func grepSearch(db: BrainCacheDB, pattern: String,
                                       caseSensitive: Bool, fixedStrings: Bool,
                                       includeAudio: Bool, limit: Int) throws -> [ClipRow] {
        let regex: NSRegularExpression
        let effectivePattern = fixedStrings
            ? NSRegularExpression.escapedPattern(for: pattern)
            : pattern
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: effectivePattern, options: options)
        } catch {
            throw CLIError.invalidRegex(pattern, underlying: error.localizedDescription)
        }

        // Pull a generous candidate set ordered newest-first. We then filter
        // in Swift. This mirrors how a `grep` over an in-memory haystack works
        // and keeps the SQL simple.
        let candidates: [ClipRow] = try db.dbQueue.read { conn in
            var sql = """
                SELECT * FROM clips
                WHERE (text_content IS NOT NULL OR image_description IS NOT NULL)
            """
            var args: [DatabaseValueConvertible] = []
            if !includeAudio {
                sql += " AND (source_app IS NULL OR source_app != ?)"
                args.append("BrainCache Voice")
            }
            sql += " ORDER BY is_pinned DESC, created_at DESC LIMIT ?"
            // Hard cap so a very broad regex doesn't drag the whole DB into memory.
            args.append(max(limit * 50, 1000))
            return try ClipRow.fetch(conn, sql: sql, arguments: StatementArguments(args))
        }

        var matches: [ClipRow] = []
        for row in candidates {
            let haystacks = [row.textContent, row.imageDescription].compactMap { $0 }
            let hit = haystacks.contains { hay in
                let range = NSRange(hay.startIndex..., in: hay)
                return regex.firstMatch(in: hay, options: [], range: range) != nil
            }
            if hit {
                matches.append(row)
                if matches.count >= limit { break }
            }
        }
        return matches
    }

    fileprivate static func vectorSearch(db: BrainCacheDB, query: String,
                                         includeAudio: Bool, limit: Int) throws -> [ClipRow] {
        let model = BrainCacheConfig.embeddingModel
        // Pull existing embedding rows to discover the stored dimension count.
        let storedDimensions = try db.dbQueue.read { conn -> Int? in
            try Int.fetchOne(conn, sql: "SELECT dimensions FROM clip_embeddings LIMIT 1")
        }
        let dims = storedDimensions ?? 256
        let queryVec = try EmbeddingClient.embed(query: query, model: model, dimensions: dims)

        struct Candidate {
            let clipId: Int64
            let distance: Float
        }
        let allCandidates: [Candidate] = try db.dbQueue.read { conn in
            let rows = try Row.fetchAll(conn, sql: "SELECT clip_id, embedding FROM clip_embeddings")
            return rows.compactMap { row -> Candidate? in
                guard let clipId = row["clip_id"] as Int64?,
                      let blob = row["embedding"] as? Data else { return nil }
                let stored = VectorMath.dataToFloats(blob)
                guard stored.count == queryVec.count else { return nil }
                return Candidate(clipId: clipId, distance: VectorMath.cosineDistance(queryVec, stored))
            }
        }
        let topIds = allCandidates
            .sorted { $0.distance < $1.distance }
            .prefix(limit)
            .map { $0.clipId }
        if topIds.isEmpty { return [] }

        // Fetch full rows for the winning IDs, preserving the similarity order.
        let placeholders = Array(repeating: "?", count: topIds.count).joined(separator: ",")
        var args: [DatabaseValueConvertible] = topIds.map { $0 as DatabaseValueConvertible }
        var sql = "SELECT * FROM clips WHERE id IN (\(placeholders))"
        if !includeAudio {
            sql += " AND (source_app IS NULL OR source_app != ?)"
            args.append("BrainCache Voice")
        }
        let fetched = try db.dbQueue.read { conn in
            try ClipRow.fetch(conn, sql: sql, arguments: StatementArguments(args))
        }
        let byId = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0) })
        return topIds.compactMap { byId[$0] }
    }

    fileprivate static func hybridSearch(db: BrainCacheDB, query: String,
                                         includeAudio: Bool, limit: Int) throws -> [ClipRow] {
        // Reciprocal Rank Fusion (k = 60) — same constant the app uses.
        let k: Double = 60
        let fts = try ftsSearch(db: db, query: query, includeAudio: includeAudio, limit: limit * 2)
        let vec = (try? vectorSearch(db: db, query: query, includeAudio: includeAudio, limit: limit * 2)) ?? []

        var scores: [Int64: Double] = [:]
        var rowById: [Int64: ClipRow] = [:]
        for (rank, row) in fts.enumerated() {
            scores[row.id, default: 0] += 1.0 / (k + Double(rank + 1))
            rowById[row.id] = row
        }
        for (rank, row) in vec.enumerated() {
            scores[row.id, default: 0] += 1.0 / (k + Double(rank + 1))
            rowById[row.id] = row
        }
        return scores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .compactMap { rowById[$0.key] }
    }

    /// Mirrors `ClipStore.makeFTSQuery` — quote each token, suffix the last
    /// with `*` for prefix matching.
    private static func makeFTSQuery(_ raw: String) -> String {
        let tokens = raw.split(separator: " ")
        guard !tokens.isEmpty else { return "" }
        return tokens.enumerated().map { i, tok -> String in
            let escaped = tok.replacingOccurrences(of: "\"", with: "\"\"")
            return i == tokens.count - 1 ? "\"\(escaped)\"*" : "\"\(escaped)\""
        }.joined(separator: " ")
    }

    // MARK: - Rendering

    fileprivate static func render(rows: [ClipRow], mode: OutputMode, full: Bool) {
        let renderer = Renderer(mode)
        switch renderer.mode {
        case .json:
            for row in rows {
                renderer.writeOne(ClipJSON(row: row, full: full))
            }
        case .table:
            let cols: [TableColumn<ClipRow>] = [
                TableColumn(title: "ID",      value: { String($0.id) }),
                TableColumn(title: "PIN",     value: { $0.isPinned ? "★" : " " }),
                TableColumn(title: "WHEN",    value: { cliIsoFormatter.string(from: $0.createdAtDate) }),
                TableColumn(title: "APP",     value: { $0.sourceApp ?? "—" }),
                TableColumn(title: "TYPE",    value: { $0.contentType }),
                TableColumn(title: "PREVIEW", value: { $0.preview }),
            ]
            renderer.write(rows, columns: cols)
        }
    }
}

// MARK: - JSON DTOs

/// Compact row used by `clips list` / `clips search` output.
struct ClipJSON: Encodable {
    let id: Int64
    let createdAt: String
    let contentType: String
    let sourceApp: String?
    let byteSize: Int
    let isPinned: Bool
    let tags: [String]
    let mediaFile: String?
    let preview: String
    let text: String?
    let imageDescription: String?

    init(row: ClipRow, full: Bool) {
        id = row.id
        createdAt = cliIsoFormatter.string(from: row.createdAtDate)
        contentType = row.contentType
        sourceApp = row.sourceApp
        byteSize = row.byteSize
        isPinned = row.isPinned
        tags = row.tags
        mediaFile = row.mediaFilePath
        preview = row.preview
        text = full ? row.textContent : nil
        imageDescription = full ? row.imageDescription : nil
    }
}

/// Verbose detail used by `clips show`.
struct ClipDetail: Encodable {
    let id: Int64
    let createdAt: String
    let contentType: String
    let sourceApp: String?
    let byteSize: Int
    let isPinned: Bool
    let tags: [String]
    let text: String?
    let imageDescription: String?
    let mediaFile: String?
    let fileURL: String?

    init(row: ClipRow) {
        id = row.id
        createdAt = cliIsoFormatter.string(from: row.createdAtDate)
        contentType = row.contentType
        sourceApp = row.sourceApp
        byteSize = row.byteSize
        isPinned = row.isPinned
        tags = row.tags
        text = row.textContent
        imageDescription = row.imageDescription
        mediaFile = row.mediaFilePath
        fileURL = row.fileURL
    }
}
