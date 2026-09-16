import Foundation

/// Removes recorder data files (logs, screenshots, summaries) older than the
/// configured retention window by moving them to the Trash.
///
/// All file I/O is performed on a background utility queue. The completion
/// block is always called on the main queue.
///
/// Usage:
/// ```swift
/// let service = ActivityCaptureCleanupService()
/// service.performCleanup(
///     retentionDays: 30,
///     logsURL: folderAccess.logsURL,
///     screenshotsURL: folderAccess.screenshotsURL,
///     rootURL: folderAccess.resolvedRootURL
/// ) { deleted, error in
///     // deleted: number of day-files moved to Trash
///     // error: first error encountered, or nil
/// }
/// ```
final class ActivityCaptureCleanupService {

    // MARK: - Dependencies (injectable for testing)

    /// Provides "now". Default: `Date()`.
    var currentDate: () -> Date = { Date() }

    /// File system operations. Default: `FileManager.default`.
    let fileManager: FileManager

    private let ioQueue = DispatchQueue(
        label: "com.TalkFlow.BrainCache.ActivityCaptureCleanup",
        qos: .utility
    )

    // MARK: - Init

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Cleanup

    /// Deletes recorder data strictly older than `retentionDays` calendar days.
    ///
    /// - Parameters:
    ///   - retentionDays: Number of days to retain. `0` means never delete.
    ///   - logsURL: The `logs/` directory URL.
    ///   - screenshotsURL: The `screenshots/` directory URL.
    ///   - rootURL: The root URL (used to locate `summaries/`). Optional.
    ///   - completion: Called on the main queue with the count of days deleted
    ///     and the first error encountered (if any).
    func performCleanup(
        retentionDays: Int,
        logsURL: URL?,
        screenshotsURL: URL?,
        rootURL: URL?,
        completion: ((Int, Error?) -> Void)? = nil
    ) {
        guard retentionDays > 0, let logsURL = logsURL else {
            DispatchQueue.main.async { completion?(0, nil) }
            return
        }

        ioQueue.async { [weak self] in
            guard let self else { return }
            let (deleted, error) = self.runCleanup(
                retentionDays: retentionDays,
                logsURL: logsURL,
                screenshotsURL: screenshotsURL,
                rootURL: rootURL
            )
            DispatchQueue.main.async { completion?(deleted, error) }
        }
    }

    // MARK: - Private

    private func runCleanup(
        retentionDays: Int,
        logsURL: URL,
        screenshotsURL: URL?,
        rootURL: URL?
    ) -> (deleted: Int, firstError: Error?) {
        let cutoff = calendar.date(
            byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: currentDate())
        )!

        var jsonlURLs: [URL]
        do {
            jsonlURLs = try fileManager.contentsOfDirectory(
                at: logsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ).filter { $0.pathExtension == "jsonl" }
        } catch {
            NSLog("ActivityCaptureCleanupService: cannot list logs directory: %@", error.localizedDescription)
            return (0, error)
        }

        var deleted = 0
        var firstError: Error? = nil

        for logURL in jsonlURLs {
            let dayString = logURL.deletingPathExtension().lastPathComponent
            guard let date = ActivityLogPaths.date(fromDayString: dayString),
                  date < cutoff else { continue }

            // Trash JSONL log file.
            do {
                try fileManager.trashItem(at: logURL, resultingItemURL: nil)
            } catch {
                NSLog("ActivityCaptureCleanupService: failed to trash %@: %@",
                      logURL.lastPathComponent, error.localizedDescription)
                if firstError == nil { firstError = error }
                continue
            }

            // Trash per-day screenshot folder (best-effort).
            if let screenshotsURL = screenshotsURL {
                let dayFolder = screenshotsURL.appendingPathComponent(dayString, isDirectory: true)
                if fileManager.fileExists(atPath: dayFolder.path) {
                    do {
                        try fileManager.trashItem(at: dayFolder, resultingItemURL: nil)
                    } catch {
                        NSLog("ActivityCaptureCleanupService: failed to trash screenshots for %@: %@",
                              dayString, error.localizedDescription)
                        if firstError == nil { firstError = error }
                    }
                }
            }

            // Trash summary file (best-effort).
            if let rootURL = rootURL,
               let date = ActivityLogPaths.date(fromDayString: dayString) {
                let summaryURL = ActivityLogPaths.summaryFileURL(for: date, in: rootURL)
                if fileManager.fileExists(atPath: summaryURL.path) {
                    try? fileManager.trashItem(at: summaryURL, resultingItemURL: nil)
                }
            }

            deleted += 1
        }

        return (deleted, firstError)
    }

    private let calendar: Calendar = {
        var cal = Calendar.current
        cal.timeZone = .current
        return cal
    }()
}

// MARK: - Convenience: run from AppDelegate using live settings

extension ActivityCaptureCleanupService {

    /// Runs cleanup using the current retention setting and the given folder access.
    func performCleanupIfNeeded(folderAccess: ActivityHistoryFolderProvider) {
        let days = Settings.shared.activityCaptureRetentionDays
        guard days > 0 else { return }
        performCleanup(
            retentionDays: days,
            logsURL: folderAccess.logsURL,
            screenshotsURL: folderAccess.screenshotsURL,
            rootURL: folderAccess.resolvedRootURL
        ) { deleted, error in
            if deleted > 0 {
                NSLog("ActivityCaptureCleanupService: purged %d day(s) of recorder data", deleted)
            }
            if let error = error {
                NSLog("ActivityCaptureCleanupService: cleanup encountered error: %@",
                      error.localizedDescription)
            }
        }
    }
}
