import ArgumentParser
import Foundation
import GRDB

/// `braincache info` — surface every path / setting another tool needs to
/// interact with the BrainCache install, without it having to know the
/// internal layout. Run this first when you're scripting against the CLI.
struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Print the discovered BrainCache install paths and runtime stats."
    )

    @OptionGroup var global: GlobalOptions

    func run() throws {
        global.apply()

        let dbURL = (try? BrainCacheConfig.databaseURL())?.path
        let dbExists = dbURL.map { FileManager.default.fileExists(atPath: $0) } ?? false

        let mediaURL = (try? BrainCacheConfig.mediaDirectoryURL())?.path
        let mediaExists = mediaURL.map {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        } ?? false

        var clipsTotal: Int? = nil
        var clipboardTotal: Int? = nil
        var audioTotal: Int? = nil
        var embeddingsTotal: Int? = nil
        var embeddingDimensions: Int? = nil
        var oldestClipAt: String? = nil
        var newestClipAt: String? = nil

        if dbExists, let db = try? BrainCacheDB.open() {
            try? db.dbQueue.read { conn in
                clipsTotal = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM clips")
                clipboardTotal = try Int.fetchOne(conn, sql: """
                    SELECT COUNT(*) FROM clips WHERE source_app IS NULL OR source_app != ?
                """, arguments: ["BrainCache Voice"])
                audioTotal = try Int.fetchOne(conn, sql: """
                    SELECT COUNT(*) FROM clips WHERE source_app = ?
                """, arguments: ["BrainCache Voice"])
                embeddingsTotal = try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM clip_embeddings")
                embeddingDimensions = try Int.fetchOne(conn, sql: "SELECT dimensions FROM clip_embeddings LIMIT 1")
                if let oldestUnix = try Double.fetchOne(conn, sql: "SELECT MIN(created_at) FROM clips") {
                    oldestClipAt = cliIsoFormatter.string(from: Date(timeIntervalSince1970: oldestUnix))
                }
                if let newestUnix = try Double.fetchOne(conn, sql: "SELECT MAX(created_at) FROM clips") {
                    newestClipAt = cliIsoFormatter.string(from: Date(timeIntervalSince1970: newestUnix))
                }
            }
        }

        let activityRoot = BrainCacheConfig.activityRootURL()?.path
        var activityDays: [String] = []
        if let logs = BrainCacheConfig.activityLogsURL(),
           let files = try? FileManager.default.contentsOfDirectory(atPath: logs.path) {
            let dayRegex = try? NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")
            activityDays = files
                .filter { $0.hasSuffix(".jsonl") }
                .map { String($0.dropLast(".jsonl".count)) }
                .filter { stem in
                    guard let r = dayRegex else { return true }
                    let range = NSRange(stem.startIndex..., in: stem)
                    return r.firstMatch(in: stem, options: [], range: range) != nil
                }
                .sorted(by: >)
        }

        let payload = InfoPayload(
            cliVersion: "1.0.0",
            variant: BrainCacheConfig.useDevVariant ? "dev" : "prod",
            dataFolderName: BrainCacheConfig.dataFolderName,
            settingsSuite: BrainCacheConfig.settingsSuiteName,
            database: PathStat(path: dbURL, exists: dbExists),
            mediaDirectory: PathStat(path: mediaURL, exists: mediaExists),
            activityRoot: activityRoot,
            activityDaysAvailable: activityDays,
            stats: Stats(
                clips: clipsTotal,
                clipboardEntries: clipboardTotal,
                audioTranscripts: audioTotal,
                embeddings: embeddingsTotal,
                embeddingDimensions: embeddingDimensions,
                oldestClipAt: oldestClipAt,
                newestClipAt: newestClipAt
            ),
            ai: AIInfo(
                hasAPIKey: BrainCacheConfig.openAIAPIKey() != nil,
                apiKeySource: apiKeySource(),
                embeddingModel: BrainCacheConfig.embeddingModel
            )
        )

        Renderer(global.output).writeObject(payload)
    }

    private func apiKeySource() -> String {
        if ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.isEmpty == false {
            return "env"
        }
        if BrainCacheConfig.openAIAPIKey() != nil {
            return "keychain"
        }
        return "none"
    }
}

struct InfoPayload: Encodable {
    let cliVersion: String
    let variant: String
    let dataFolderName: String
    let settingsSuite: String
    let database: PathStat
    let mediaDirectory: PathStat
    let activityRoot: String?
    let activityDaysAvailable: [String]
    let stats: Stats
    let ai: AIInfo
}

struct PathStat: Encodable {
    let path: String?
    let exists: Bool
}

struct Stats: Encodable {
    let clips: Int?
    let clipboardEntries: Int?
    let audioTranscripts: Int?
    let embeddings: Int?
    let embeddingDimensions: Int?
    let oldestClipAt: String?
    let newestClipAt: String?
}

struct AIInfo: Encodable {
    let hasAPIKey: Bool
    let apiKeySource: String
    let embeddingModel: String
}
