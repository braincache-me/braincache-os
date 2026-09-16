import AppKit
import Foundation

// MARK: - Folder access protocol (testable)

protocol ActivityHistoryFolderProvider {
    var resolvedRootURL: URL? { get }
    var logsURL: URL? { get }
    var screenshotsURL: URL? { get }
}

extension ActivityCaptureFolderAccess: ActivityHistoryFolderProvider {}

// MARK: - Store

final class ActivityHistoryStore {

    // MARK: - Published state

    private(set) var days: [ActivityDaySummary] = []
    private(set) var loadedEvents: [ActivityEvent] = []
    private(set) var loadedDayString: String? = nil
    private(set) var filter = ActivityHistoryFilter()

    /// Non-nil when the last operation failed — the UI can display this.
    private(set) var lastError: String? = nil

    // MARK: - Dependencies

    private let folderAccess: ActivityHistoryFolderProvider

    // MARK: - Change callbacks

    var onDataChanged: (() -> Void)?

    // MARK: - Private state

    private let ioQueue = DispatchQueue(label: "com.TalkFlow.BrainCache.ActivityHistoryStore", qos: .userInitiated)

    // MARK: - Init

    init(folderAccess: ActivityHistoryFolderProvider) {
        self.folderAccess = folderAccess
    }

    // MARK: - Day discovery

    func refreshDayList() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let (summaries, error) = self.loadAllSummaries()
            DispatchQueue.main.async {
                self.days = summaries
                self.lastError = error
                self.onDataChanged?()
            }
        }
    }

    private func loadAllSummaries() -> ([ActivityDaySummary], String?) {
        guard let rootURL = resolveRootURL() else {
            NSLog("ActivityHistoryStore: resolveRootURL returned nil")
            return ([], "Activity log folder not accessible. Please select a folder in Preferences.")
        }

        NSLog("ActivityHistoryStore: rootURL = %@", rootURL.path)
        let logsDir = rootURL.appendingPathComponent("logs", isDirectory: true)
        NSLog("ActivityHistoryStore: logsDir exists = %d, path = %@",
              FileManager.default.fileExists(atPath: logsDir.path), logsDir.path)
        let screenshotsDir = rootURL.appendingPathComponent("screenshots", isDirectory: true)
        let summariesDir = rootURL.appendingPathComponent("summaries", isDirectory: true)

        var knownDays = Set<String>()
        var result: [ActivityDaySummary] = []

        // First pass: load persisted summary files.
        if FileManager.default.fileExists(atPath: summariesDir.path),
           let enumerator = FileManager.default.enumerator(
               at: summariesDir,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
           ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "json" else { continue }
                let dayString = url.deletingPathExtension().lastPathComponent
                guard !dayString.isEmpty, ActivityLogPaths.date(fromDayString: dayString) != nil else { continue }
                if let summary = ActivityDaySummary.load(from: url) {
                    result.append(summary)
                    knownDays.insert(dayString)
                }
            }
        }

        // Second pass: discover log files that have no summary yet.
        if FileManager.default.fileExists(atPath: logsDir.path),
           let enumerator = FileManager.default.enumerator(
               at: logsDir,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
           ) {
            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let dayString = url.deletingPathExtension().lastPathComponent
                guard !knownDays.contains(dayString),
                      let date = ActivityLogPaths.date(fromDayString: dayString) else { continue }
                let summary = ActivityDaySummary.rebuild(
                    for: date,
                    logsDirectory: logsDir,
                    screenshotsDirectory: screenshotsDir
                )
                result.append(summary)
                let summaryURL = ActivityLogPaths.summaryFileURL(for: date, in: rootURL)
                try? summary.save(to: summaryURL)
            }
        }

        if result.isEmpty && !FileManager.default.fileExists(atPath: logsDir.path) {
            return ([], "Logs directory not found at: \(logsDir.path)")
        }

        result.sort { $0.dayString > $1.dayString }
        return (result, nil)
    }

    // MARK: - Day loading

    func loadDay(_ dayString: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let (events, error) = self.parseJSONL(for: dayString)
            DispatchQueue.main.async {
                self.loadedDayString = dayString
                self.loadedEvents = events
                self.lastError = error
                self.onDataChanged?()
            }
        }
    }

    // MARK: - Delete day

    func deleteDay(_ dayString: String, completion: ((Error?) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let rootURL = self.resolveRootURL() else {
                DispatchQueue.main.async { completion?(nil) }
                return
            }
            var firstError: Error? = nil
            let logsDir = rootURL.appendingPathComponent("logs", isDirectory: true)
            let screenshotsDir = rootURL.appendingPathComponent("screenshots", isDirectory: true)

            let logFile = logsDir.appendingPathComponent("\(dayString).jsonl")
            if FileManager.default.fileExists(atPath: logFile.path) {
                do {
                    try FileManager.default.trashItem(at: logFile, resultingItemURL: nil)
                } catch {
                    firstError = error
                }
            }

            let dayFolder = screenshotsDir.appendingPathComponent(dayString, isDirectory: true)
            if FileManager.default.fileExists(atPath: dayFolder.path) {
                do {
                    try FileManager.default.trashItem(at: dayFolder, resultingItemURL: nil)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }

            if let date = ActivityLogPaths.date(fromDayString: dayString) {
                let summaryURL = ActivityLogPaths.summaryFileURL(for: date, in: rootURL)
                try? FileManager.default.trashItem(at: summaryURL, resultingItemURL: nil)
            }

            DispatchQueue.main.async {
                self.days.removeAll { $0.dayString == dayString }
                if self.loadedDayString == dayString {
                    self.loadedDayString = nil
                    self.loadedEvents = []
                }
                self.onDataChanged?()
                completion?(firstError)
            }
        }
    }

    // MARK: - JSONL parsing

    private func parseJSONL(for dayString: String) -> ([ActivityEvent], String?) {
        guard let rootURL = resolveRootURL() else {
            return ([], "Activity log folder not accessible.")
        }

        let logsDir = rootURL.appendingPathComponent("logs", isDirectory: true)
        let logURL = logsDir.appendingPathComponent(dayString + ".jsonl")

        guard FileManager.default.fileExists(atPath: logURL.path) else {
            return ([], "Log file not found: \(logURL.lastPathComponent)")
        }

        let content: String
        do {
            content = try String(contentsOf: logURL, encoding: .utf8)
        } catch {
            return ([], "Cannot read \(logURL.lastPathComponent): \(error.localizedDescription)")
        }

        guard !content.isEmpty else {
            return ([], nil)
        }

        var events: [ActivityEvent] = []
        var parseErrors = 0
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)

        for line in lines {
            let lineStr = String(line)
            guard let data = lineStr.data(using: .utf8) else {
                parseErrors += 1
                continue
            }
            do {
                let event = try ActivityEvent.jsonDecoder.decode(ActivityEvent.self, from: data)
                events.append(event)
            } catch {
                parseErrors += 1
                if parseErrors <= 3 {
                    NSLog("ActivityHistoryStore: parse error in %@: %@", dayString, error.localizedDescription)
                }
            }
        }

        let errorMsg: String?
        if parseErrors > 0 && events.isEmpty {
            errorMsg = "All \(lines.count) events failed to parse in \(dayString).jsonl"
        } else if parseErrors > 0 {
            errorMsg = "\(parseErrors) of \(lines.count) events failed to parse"
        } else {
            errorMsg = nil
        }

        return (events, errorMsg)
    }

    // MARK: - Root URL resolution

    private func resolveRootURL() -> URL? {
        if let url = folderAccess.resolvedRootURL {
            NSLog("ActivityHistoryStore: resolvedRootURL already set = %@", url.path)
            return url
        }
        NSLog("ActivityHistoryStore: resolvedRootURL is nil, attempting re-resolve")
        if let fa = folderAccess as? ActivityCaptureFolderAccess {
            do {
                let url = try fa.resolveAccess()
                NSLog("ActivityHistoryStore: re-resolve succeeded = %@", url.path)
                return url
            } catch {
                NSLog("ActivityHistoryStore: re-resolve failed: %@", error.localizedDescription)
            }
        }
        return nil
    }

    // MARK: - Filtering

    @discardableResult
    func applyFilter(_ filter: ActivityHistoryFilter) -> [ActivityEvent] {
        self.filter = filter
        return filteredEvents()
    }

    func filteredEvents() -> [ActivityEvent] {
        loadedEvents.filter { event in
            filterMatches(event, filter: filter)
        }
    }

    private func filterMatches(_ event: ActivityEvent, filter: ActivityHistoryFilter) -> Bool {
        if let app = filter.appName, !app.isEmpty {
            guard event.appName.localizedCaseInsensitiveContains(app) else { return false }
        }
        if let type_ = filter.eventType {
            guard event.eventType == type_ else { return false }
        }
        if !filter.searchText.isEmpty {
            let text = filter.searchText.lowercased()
            let haystack = [
                event.appName,
                event.windowTitle,
                event.controlName ?? "",
                event.controlRole ?? "",
                event.controlValue ?? "",
                event.triggerMetadata ?? ""
            ].joined(separator: " ").lowercased()
            guard haystack.contains(text) else { return false }
        }
        return true
    }

    // MARK: - Storage helpers

    var screenshotRootURL: URL? { folderAccess.screenshotsURL }

    var storageBreakdown: (logsBytes: Int64, screenshotsBytes: Int64) {
        let logs = days.reduce(Int64(0)) { $0 + $1.logFileSizeBytes }
        let screenshots = days.reduce(Int64(0)) { $0 + $1.screenshotFolderSizeBytes }
        return (logs, screenshots)
    }

    // MARK: - Display model helpers

    var availableApps: [String] {
        let names = Set(loadedEvents.map { $0.appName })
        return names.sorted()
    }

    func rawJSON(for event: ActivityEvent) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601MillisecondPrecision
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(event),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    func screenshotURL(relativePath: String) -> URL? {
        guard let screenshotsURL = folderAccess.screenshotsURL else { return nil }
        let resolved = screenshotsURL.appendingPathComponent(relativePath).standardized
        guard resolved.path.hasPrefix(screenshotsURL.standardized.path + "/") else { return nil }
        return resolved
    }
}

// MARK: - Filter model

struct ActivityHistoryFilter: Equatable {
    var searchText: String = ""
    var appName: String? = nil
    var eventType: ActivityEventType? = nil

    var isEmpty: Bool {
        searchText.isEmpty && appName == nil && eventType == nil
    }
}

// MARK: - JSONEncoder date strategy helper

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601MillisecondPrecision: JSONEncoder.DateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(ActivityEvent.iso8601Formatter.string(from: date))
    }
}
