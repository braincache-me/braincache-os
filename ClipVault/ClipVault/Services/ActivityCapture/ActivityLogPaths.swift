import Foundation

/// Helper for constructing file URLs within the activity log directory structure.
///
/// Directory layout:
/// ```
/// <root>/
///   logs/
///     YYYY-MM-DD.jsonl
///   screenshots/
///     YYYY-MM-DD/
///       YYYY-MM-DDThh-mm-ss-mmm_<AppName>_<trigger>.jpg
///   summaries/
///     YYYY-MM-DD.json
/// ```
enum ActivityLogPaths {

    // MARK: - Date formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    // MARK: - Day string helpers

    /// Returns the calendar-day string for a given date, e.g. `"2026-04-11"`.
    static func dayString(for date: Date = Date()) -> String {
        dayFormatter.string(from: date)
    }

    /// Parses a day string back to a Date (midnight local time). Returns nil if the string is malformed.
    static func date(fromDayString dayString: String) -> Date? {
        dayFormatter.date(from: dayString)
    }

    // MARK: - Log file URLs

    /// Returns the JSONL log file URL for a given date.
    /// - Parameters:
    ///   - date: The calendar day.
    ///   - logsDirectory: The `logs/` directory URL (from `ActivityCaptureFolderAccess.logsURL`).
    static func logFileURL(for date: Date = Date(), in logsDirectory: URL) -> URL {
        logsDirectory.appendingPathComponent(dayString(for: date) + ".jsonl")
    }

    // MARK: - Screenshot URLs

    /// Returns the per-day screenshot directory URL.
    static func screenshotDirectoryURL(for date: Date = Date(), in screenshotsDirectory: URL) -> URL {
        screenshotsDirectory.appendingPathComponent(dayString(for: date), isDirectory: true)
    }

    /// Returns the full URL for a screenshot file given its timestamp, app name, and trigger.
    static func screenshotFileURL(
        timestamp: Date,
        appName: String,
        trigger: String,
        in screenshotsDirectory: URL
    ) -> URL {
        let dayDir = screenshotDirectoryURL(for: timestamp, in: screenshotsDirectory)
        let filename = screenshotFilename(timestamp: timestamp, appName: appName, trigger: trigger)
        return dayDir.appendingPathComponent(filename)
    }

    /// The relative screenshot path stored inside an `ActivityEvent.screenshotPath`.
    /// E.g. `"2026-04-11/2026-04-11T14-23-45-123_Safari_app_activated.jpg"`.
    static func relativeScreenshotPath(timestamp: Date, appName: String, trigger: String) -> String {
        let day = dayString(for: timestamp)
        let filename = screenshotFilename(timestamp: timestamp, appName: appName, trigger: trigger)
        return "\(day)/\(filename)"
    }

    // MARK: - Summary URLs

    /// Returns the summary JSON file URL for a given date.
    static func summaryFileURL(for date: Date = Date(), in rootDirectory: URL) -> URL {
        let summariesDir = rootDirectory.appendingPathComponent("summaries", isDirectory: true)
        return summariesDir.appendingPathComponent(dayString(for: date) + ".json")
    }

    // MARK: - Private helpers

    private static func screenshotFilename(timestamp: Date, appName: String, trigger: String) -> String {
        let ts = timestampFormatter.string(from: timestamp)
        // Sanitise app name to be filesystem-safe
        let safeApp = appName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
            .prefix(40)  // cap length
        let safeTrigger = trigger
            .replacingOccurrences(of: " ", with: "_")
            .prefix(30)
        return "\(ts)_\(safeApp)_\(safeTrigger).jpg"
    }
}
