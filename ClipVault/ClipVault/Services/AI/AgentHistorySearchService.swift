import Foundation

/// One hit from a local AI-agent history search.
struct AgentHistoryMatch: Equatable {
    let file: String
    let timestamp: String?
    let role: String?
    let snippet: String
}

/// Searches the local session logs written by AI coding agents:
/// Claude Code (`~/.claude`) and Codex (`~/.codex`). Both store JSONL
/// transcripts — one JSON object per line — under per-project / per-session
/// folders. The service greps those lines for a query and returns readable
/// snippets, newest files first, so Ask AI can answer questions like
/// "How did you do that?" about past agent sessions.
///
/// Roots are injectable so tests can point at fixture folders; the app is
/// not sandboxed, so the real dot-folders in the user's home are readable
/// directly.
final class AgentHistorySearchService {

    enum Source {
        case claudeCode
        case codex
    }

    /// Newest-first cap on how many JSONL files are scanned per search —
    /// long-lived agent installs can hold thousands of session files.
    static let maxFilesScanned = 60
    /// Skip pathologically large transcripts instead of loading them.
    static let maxFileBytes = 50 * 1024 * 1024
    /// A single session shouldn't crowd out every other result.
    static let maxMatchesPerFile = 5
    /// Characters of context kept around the query hit.
    static let snippetLength = 300

    private let claudeRoot: URL
    private let codexRoot: URL
    private let fileManager: FileManager

    init(claudeRoot: URL? = nil, codexRoot: URL? = nil, fileManager: FileManager = .default) {
        let home = fileManager.homeDirectoryForCurrentUser
        self.claudeRoot = claudeRoot ?? home.appendingPathComponent(".claude")
        self.codexRoot = codexRoot ?? home.appendingPathComponent(".codex")
        self.fileManager = fileManager
    }

    // MARK: - Search

    func search(source: Source, query: String, limit: Int) -> [AgentHistoryMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let cappedLimit = max(1, min(limit, 25))

        let root = (source == .claudeCode) ? claudeRoot : codexRoot
        var matches: [AgentHistoryMatch] = []
        for file in candidateFiles(root: root) {
            guard matches.count < cappedLimit else { break }
            matches.append(contentsOf: scan(
                file: file,
                root: root,
                query: trimmed,
                remaining: cappedLimit - matches.count
            ))
        }
        return matches
    }

    /// JSONL files under the root, newest-first by modification date.
    /// Covers `projects/<slug>/*.jsonl` (Claude Code), `sessions/**/*.jsonl`
    /// (Codex), and the top-level `history.jsonl` both agents keep.
    private func candidateFiles(root: URL) -> [URL] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let size = values?.fileSize, size > Self.maxFileBytes { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files
            .sorted { $0.modified > $1.modified }
            .prefix(Self.maxFilesScanned)
            .map { $0.url }
    }

    private func scan(file: URL, root: URL, query: String, remaining: Int) -> [AgentHistoryMatch] {
        guard remaining > 0,
              let content = try? String(contentsOf: file, encoding: .utf8) else { return [] }

        let relativePath = file.path.hasPrefix(root.path)
            ? String(file.path.dropFirst(root.path.count + 1))
            : file.lastPathComponent

        var matches: [AgentHistoryMatch] = []
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard matches.count < min(remaining, Self.maxMatchesPerFile) else { break }
            guard line.localizedCaseInsensitiveContains(query) else { continue }

            let parsed = Self.parseLine(String(line))
            let searchable = parsed.text.isEmpty ? String(line) : parsed.text
            guard searchable.localizedCaseInsensitiveContains(query) else { continue }

            matches.append(AgentHistoryMatch(
                file: relativePath,
                timestamp: parsed.timestamp,
                role: parsed.role,
                snippet: Self.snippet(around: query, in: searchable)
            ))
        }
        return matches
    }

    // MARK: - JSONL line parsing

    /// Pulls human-readable text, the speaker role, and a timestamp out of
    /// one transcript line. The two agents (and their versions) differ in
    /// envelope shape, so this walks the JSON generically: strings under
    /// `text` / `content` / `summary` keys become the searchable text, and
    /// the first `role` / `timestamp` values found are kept.
    static func parseLine(_ line: String) -> (text: String, role: String?, timestamp: String?) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return (line, nil, nil)
        }

        var texts: [String] = []
        var role: String?
        var timestamp: String?

        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, inner) in dict {
                    switch key {
                    case "role":
                        if role == nil { role = inner as? String }
                    case "timestamp", "ts", "created_at":
                        if timestamp == nil {
                            timestamp = inner as? String
                        }
                    case "text", "content", "summary":
                        if let s = inner as? String {
                            texts.append(s)
                        } else {
                            walk(inner)
                        }
                    default:
                        if inner is [String: Any] || inner is [Any] {
                            walk(inner)
                        }
                    }
                }
            } else if let array = value as? [Any] {
                for inner in array { walk(inner) }
            }
        }
        walk(json)

        return (texts.joined(separator: " "), role, timestamp)
    }

    /// Extracts ~`snippetLength` characters of context centered on the first
    /// case-insensitive occurrence of `query`.
    static func snippet(around query: String, in text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = collapsed.range(of: query, options: [.caseInsensitive]) else {
            return String(collapsed.prefix(snippetLength))
        }

        let half = snippetLength / 2
        let start = collapsed.index(
            range.lowerBound, offsetBy: -half, limitedBy: collapsed.startIndex
        ) ?? collapsed.startIndex
        let end = collapsed.index(
            range.upperBound, offsetBy: half, limitedBy: collapsed.endIndex
        ) ?? collapsed.endIndex

        var result = String(collapsed[start..<end])
        if start > collapsed.startIndex { result = "…" + result }
        if end < collapsed.endIndex { result += "…" }
        return result
    }

    // MARK: - Tool output formatting

    /// Renders matches as the plain-text tool result handed back to the model.
    static func formatResults(_ matches: [AgentHistoryMatch], query: String, sourceLabel: String) -> String {
        guard !matches.isEmpty else {
            return "No matches for \"\(query)\" in \(sourceLabel). The history may not mention it, or the logs may not exist on this Mac."
        }
        var lines = ["Found \(matches.count) match(es) for \"\(query)\" in \(sourceLabel), newest sessions first:"]
        for (idx, match) in matches.enumerated() {
            var header = "[\(idx + 1)] \(match.file)"
            if let ts = match.timestamp { header += " — \(ts)" }
            if let role = match.role { header += " — \(role)" }
            lines.append(header)
            lines.append("    \(match.snippet)")
        }
        return lines.joined(separator: "\n")
    }
}
