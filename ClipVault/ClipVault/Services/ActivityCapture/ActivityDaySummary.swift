import Foundation

/// A lightweight daily summary that the Activity History sidebar uses to display event counts
/// and storage usage without reparsing all JSONL on every open.
///
/// Summaries are stored as JSON at `<root>/summaries/YYYY-MM-DD.json`.
struct ActivityDaySummary: Codable, Equatable {

    // MARK: - Identity

    /// The calendar day this summary covers, e.g. `"2026-04-11"`.
    let dayString: String

    // MARK: - Event counts

    /// Total number of events recorded on this day.
    var eventCount: Int

    /// Number of screenshot events recorded on this day.
    var screenshotCount: Int

    // MARK: - Storage

    /// Size of the JSONL log file in bytes. Zero if the file does not exist.
    var logFileSizeBytes: Int64

    /// Total size of the screenshots folder for this day in bytes.
    var screenshotFolderSizeBytes: Int64

    /// When this summary was last updated (Unix timestamp).
    var savedAt: Date

    // MARK: - Computed

    /// Combined storage for this day (log + screenshots), in bytes.
    var totalSizeBytes: Int64 { logFileSizeBytes + screenshotFolderSizeBytes }

    // MARK: - Init

    init(
        dayString: String,
        eventCount: Int = 0,
        screenshotCount: Int = 0,
        logFileSizeBytes: Int64 = 0,
        screenshotFolderSizeBytes: Int64 = 0,
        savedAt: Date = Date()
    ) {
        self.dayString = dayString
        self.eventCount = eventCount
        self.screenshotCount = screenshotCount
        self.logFileSizeBytes = logFileSizeBytes
        self.screenshotFolderSizeBytes = screenshotFolderSizeBytes
        self.savedAt = savedAt
    }
}

// MARK: - Persistence helpers

extension ActivityDaySummary {

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return dec
    }()

    /// Loads a summary from a JSON file. Returns nil if the file does not exist or is malformed.
    static func load(from url: URL) -> ActivityDaySummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(ActivityDaySummary.self, from: data)
    }

    /// Saves this summary to a JSON file, creating intermediate directories as needed.
    func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ActivityDaySummary.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Rebuilds the summary by scanning the actual log and screenshot files on disk.
    ///
    /// - Parameters:
    ///   - date: The day to summarize.
    ///   - logsDirectory: The `logs/` directory.
    ///   - screenshotsDirectory: The `screenshots/` directory.
    ///   - rootDirectory: The root directory (used to locate `summaries/`).
    /// - Returns: An updated summary reflecting the current disk state.
    static func rebuild(
        for date: Date,
        logsDirectory: URL,
        screenshotsDirectory: URL
    ) -> ActivityDaySummary {
        let day = ActivityLogPaths.dayString(for: date)
        let logURL = ActivityLogPaths.logFileURL(for: date, in: logsDirectory)
        let screenshotDir = ActivityLogPaths.screenshotDirectoryURL(for: date, in: screenshotsDirectory)

        // Count events by counting newlines in the log file
        var eventCount = 0
        var logSize: Int64 = 0
        if let logData = try? Data(contentsOf: logURL) {
            logSize = Int64(logData.count)
            // Each non-empty line is one event
            eventCount = logData.split(separator: UInt8(ascii: "\n"),
                                       omittingEmptySubsequences: true).count
        }

        // Count screenshots and total folder size
        var screenshotCount = 0
        var screenshotFolderSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: screenshotDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "jpg" {
                    screenshotCount += 1
                }
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    screenshotFolderSize += Int64(size)
                }
            }
        }

        return ActivityDaySummary(
            dayString: day,
            eventCount: eventCount,
            screenshotCount: screenshotCount,
            logFileSizeBytes: logSize,
            screenshotFolderSizeBytes: screenshotFolderSize,
            savedAt: Date()
        )
    }
}
