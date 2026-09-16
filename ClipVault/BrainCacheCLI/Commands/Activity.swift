import ArgumentParser
import Foundation

/// `braincache activity …` — query the UI activity recorder's JSONL logs.
///
/// Activity data lives outside the SQLite DB: one JSONL file per local
/// calendar day under `<chosen-root>/logs/YYYY-MM-DD.jsonl`. We parse one
/// line at a time so multi-megabyte days don't blow up memory, and we
/// resolve screenshot / audio paths to absolute on-disk locations for
/// the caller.
struct Activity: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "activity",
        abstract: "Read recorded UI activity (clicks, focus changes, screenshots).",
        subcommands: [Day.self, Range.self, Search.self, Show.self]
    )

    // MARK: - activity day

    struct Day: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "day",
            abstract: "Return every event recorded on a given local-calendar day."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Date in YYYY-MM-DD format. Defaults to today.")
        var date: String?

        @Option(name: .long, help: "Filter to events whose appName matches this substring (case-insensitive).")
        var app: String?

        @Option(name: .long, help: "Filter to events whose eventType is one of the listed types (comma-separated).")
        var types: String?

        @Flag(name: .long, help: "Include only events that have a screenshot path.")
        var withScreenshot: Bool = false

        @Option(name: [.short, .long], help: "Maximum events to return. 0 = no cap.")
        var limit: Int = 0

        func run() throws {
            global.apply()
            let day = try resolveDay(date)
            let events = try Activity.loadEvents(day: day,
                                                 appFilter: app,
                                                 typeFilter: parseTypes(types),
                                                 withScreenshotOnly: withScreenshot,
                                                 limit: limit)
            Activity.render(events: events, mode: global.output)
        }
    }

    // MARK: - activity range

    struct Range: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "range",
            abstract: "Return every event between two timestamps."
        )

        @OptionGroup var global: GlobalOptions

        @Option(name: .long, help: "Start timestamp (ISO-8601 or YYYY-MM-DD).")
        var start: String

        @Option(name: .long, help: "End timestamp (ISO-8601 or YYYY-MM-DD). Defaults to now.")
        var end: String?

        @Option(name: .long, help: "Filter to events whose appName matches this substring.")
        var app: String?

        @Option(name: .long, help: "Filter event types (comma-separated).")
        var types: String?

        @Option(name: [.short, .long], help: "Maximum events to return. 0 = no cap.")
        var limit: Int = 0

        func run() throws {
            global.apply()
            let startDate = try parseTimestamp(start)
            let endDate = try (end.map(parseTimestamp) ?? Date())
            guard startDate <= endDate else {
                throw CLIError.dateParseFailed("--start must be on or before --end")
            }
            let events = try Activity.loadEventsInRange(start: startDate, end: endDate,
                                                       appFilter: app,
                                                       typeFilter: parseTypes(types),
                                                       limit: limit)
            Activity.render(events: events, mode: global.output)
        }
    }

    // MARK: - activity search

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "search",
            abstract: "Grep across the JSONL logs."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Pattern. Regex by default; use --fixed-strings for literal.")
        var pattern: String

        @Option(name: .long, help: "Restrict search to this single day (YYYY-MM-DD).")
        var day: String?

        @Option(name: .long, help: "Restrict to events within the last N days.")
        var lastDays: Int?

        @Flag(name: .long, help: "Case-sensitive match.")
        var caseSensitive: Bool = false

        @Flag(name: .long, help: "Treat the pattern as a literal string.")
        var fixedStrings: Bool = false

        @Flag(name: .long, help: "Search only inside textual fields (controlName, controlValue, windowTitle, nearbyText, url). Default also includes appName and bundleID.")
        var textOnly: Bool = false

        @Option(name: [.short, .long], help: "Maximum results.")
        var limit: Int = 100

        func run() throws {
            global.apply()
            let patternString = fixedStrings
                ? NSRegularExpression.escapedPattern(for: pattern)
                : pattern
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: patternString, options: options)
            } catch {
                throw CLIError.invalidRegex(pattern, underlying: error.localizedDescription)
            }

            let days: [Date]
            if let day = day {
                days = [try resolveDay(day)]
            } else if let n = lastDays, n > 0 {
                days = (0..<n).map {
                    Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date()
                }
            } else {
                days = try Activity.listAvailableDays()
            }

            var matches: [ActivityEventJSON] = []
            outer: for day in days {
                let events = (try? Activity.loadEvents(day: day, appFilter: nil,
                                                       typeFilter: nil,
                                                       withScreenshotOnly: false,
                                                       limit: 0)) ?? []
                for event in events {
                    if Activity.matches(event: event, regex: regex, textOnly: textOnly) {
                        matches.append(event)
                        if matches.count >= limit { break outer }
                    }
                }
            }
            Activity.render(events: matches, mode: global.output)
        }
    }

    // MARK: - activity show

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Print one full event JSON by its UUID."
        )

        @OptionGroup var global: GlobalOptions

        @Argument(help: "Event UUID (as printed by `activity day` / `activity search`).")
        var id: String

        @Option(name: .long, help: "Search only this day (YYYY-MM-DD). Faster when you know the date.")
        var day: String?

        func run() throws {
            global.apply()
            let days = try (day.map { [try resolveDay($0)] } ?? Activity.listAvailableDays())
            for d in days {
                let events = (try? Activity.loadEvents(day: d, appFilter: nil,
                                                       typeFilter: nil,
                                                       withScreenshotOnly: false,
                                                       limit: 0)) ?? []
                if let match = events.first(where: { $0.id == id }) {
                    Renderer(global.output).writeObject(match)
                    return
                }
            }
            throw CLIError.dateParseFailed("event \(id) not found in any available day")
        }
    }

    // MARK: - Loading

    /// One event in the JSONL log. Matches `ActivityEvent` in the app but is
    /// fully optional-tolerant so future schema additions don't break decode.
    struct ActivityEventJSON: Codable, Equatable {
        let id: String
        let timestamp: String
        let appName: String?
        let bundleID: String?
        let windowTitle: String?
        let eventType: String?
        let controlRole: String?
        let controlName: String?
        let controlValue: String?
        let clickX: Double?
        let clickY: Double?
        let nearbyText: String?
        let url: String?
        let screenshotPath: String?
        let audioPath: String?
        let windowIdentifier: String?
        let triggerMetadata: String?
        let aiPrompt: String?
        let aiResponse: String?
        let aiAttachedWindow: String?

        /// Resolved on-disk path for `screenshotPath`. Computed at render time.
        var screenshotAbsolutePath: String? {
            guard let rel = screenshotPath,
                  let root = BrainCacheConfig.activityScreenshotsURL() else { return nil }
            return root.appendingPathComponent(rel).path
        }

        /// Resolved on-disk path for `audioPath`.
        var audioAbsolutePath: String? {
            guard let rel = audioPath,
                  let root = BrainCacheConfig.activityRootURL() else { return nil }
            return root.appendingPathComponent("recordings", isDirectory: false)
                       .appendingPathComponent(rel).path
        }
    }

    private static let jsonDecoder: JSONDecoder = {
        let dec = JSONDecoder()
        // The app encodes ISO-8601 with fractional seconds; we keep timestamps
        // as raw strings to avoid losing precision on round-trip.
        return dec
    }()

    fileprivate static func loadEvents(day: Date,
                                       appFilter: String?,
                                       typeFilter: Set<String>?,
                                       withScreenshotOnly: Bool,
                                       limit: Int) throws -> [ActivityEventJSON] {
        guard let logsURL = BrainCacheConfig.activityLogsURL() else {
            throw CLIError.activityRootNotConfigured
        }
        let dayString = dayFormatter.string(from: day)
        let fileURL = logsURL.appendingPathComponent(dayString + ".jsonl")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        var events: [ActivityEventJSON] = []
        let stream = try LineByLineFileReader(url: fileURL)
        defer { stream.close() }
        while let line = try stream.next() {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let event = try? jsonDecoder.decode(ActivityEventJSON.self, from: data) else {
                continue
            }
            if let app = appFilter, !app.isEmpty {
                let appName = event.appName ?? ""
                if appName.range(of: app, options: .caseInsensitive) == nil { continue }
            }
            if let types = typeFilter, !types.isEmpty {
                if !types.contains(event.eventType ?? "") { continue }
            }
            if withScreenshotOnly && (event.screenshotPath == nil) { continue }
            events.append(event)
            if limit > 0 && events.count >= limit { break }
        }
        return events
    }

    fileprivate static func loadEventsInRange(start: Date, end: Date,
                                              appFilter: String?,
                                              typeFilter: Set<String>?,
                                              limit: Int) throws -> [ActivityEventJSON] {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        var days: [Date] = []
        var cursor = startDay
        while cursor <= endDay {
            days.append(cursor)
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        let startISO = Activity.isoFormatter.string(from: start)
        let endISO = Activity.isoFormatter.string(from: end)

        var out: [ActivityEventJSON] = []
        for day in days {
            let events = try loadEvents(day: day,
                                        appFilter: appFilter,
                                        typeFilter: typeFilter,
                                        withScreenshotOnly: false,
                                        limit: 0)
            for event in events {
                // String compare on ISO-8601 is correct because the format is
                // monotonic. Saves us a parse-per-line round-trip.
                if event.timestamp < startISO { continue }
                if event.timestamp > endISO { continue }
                out.append(event)
                if limit > 0 && out.count >= limit { return out }
            }
        }
        return out
    }

    fileprivate static func listAvailableDays() throws -> [Date] {
        guard let logsURL = BrainCacheConfig.activityLogsURL() else {
            throw CLIError.activityRootNotConfigured
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: logsURL.path)) ?? []
        return files
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> Date? in
                let day = String(name.dropLast(".jsonl".count))
                // dayFormatter is strict (yyyy-MM-dd, en_US_POSIX), so it
                // rejects debug files like "click_ocr_debug.jsonl" outright.
                return dayFormatter.date(from: day)
            }
            .sorted(by: >)  // newest first
    }

    fileprivate static func matches(event: ActivityEventJSON,
                                    regex: NSRegularExpression,
                                    textOnly: Bool) -> Bool {
        var fields: [String] = []
        if !textOnly {
            if let v = event.appName { fields.append(v) }
            if let v = event.bundleID { fields.append(v) }
        }
        for v in [event.controlName, event.controlValue, event.windowTitle,
                  event.nearbyText, event.url, event.aiPrompt, event.aiResponse] {
            if let v = v { fields.append(v) }
        }
        for field in fields {
            let range = NSRange(field.startIndex..., in: field)
            if regex.firstMatch(in: field, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Rendering

    fileprivate static func render(events: [ActivityEventJSON], mode: OutputMode) {
        let renderer = Renderer(mode)
        switch renderer.mode {
        case .json:
            for event in events {
                renderer.writeOne(ActivityEventOutput(event: event))
            }
        case .table:
            let cols: [TableColumn<ActivityEventJSON>] = [
                TableColumn(title: "TIMESTAMP", value: { $0.timestamp }),
                TableColumn(title: "APP",       value: { $0.appName ?? "—" }),
                TableColumn(title: "EVENT",     value: { $0.eventType ?? "—" }),
                TableColumn(title: "TITLE",     value: { ($0.windowTitle ?? "").singleLinePreview(maxChars: 50) }),
                TableColumn(title: "DETAIL",    value: { detailFor(event: $0) }),
                TableColumn(title: "SHOT",      value: { $0.screenshotPath != nil ? "yes" : "" }),
            ]
            renderer.write(events, columns: cols)
        }
    }

    private static func detailFor(event: ActivityEventJSON) -> String {
        if let name = event.controlName, !name.isEmpty {
            if let value = event.controlValue, !value.isEmpty {
                return "\(name) = \(value)".singleLinePreview(maxChars: 60)
            }
            return name.singleLinePreview(maxChars: 60)
        }
        if let value = event.controlValue, !value.isEmpty {
            return value.singleLinePreview(maxChars: 60)
        }
        if let url = event.url, !url.isEmpty {
            return url.singleLinePreview(maxChars: 60)
        }
        if let prompt = event.aiPrompt, !prompt.isEmpty {
            return prompt.singleLinePreview(maxChars: 60)
        }
        if let trigger = event.triggerMetadata, !trigger.isEmpty {
            return trigger.singleLinePreview(maxChars: 60)
        }
        return ""
    }

    // MARK: - Date helpers

    fileprivate static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    fileprivate static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Helpers usable inside Activity subcommands

fileprivate func resolveDay(_ raw: String?) throws -> Date {
    guard let raw = raw, !raw.isEmpty else { return Date() }
    if let d = Activity.dayFormatter.date(from: raw) { return d }
    if let d = Activity.isoFormatter.date(from: raw) { return d }
    throw CLIError.dateParseFailed(raw)
}

fileprivate func parseTimestamp(_ raw: String) throws -> Date {
    if let d = Activity.isoFormatter.date(from: raw) { return d }
    if let d = Activity.dayFormatter.date(from: raw) { return d }
    throw CLIError.dateParseFailed(raw)
}

fileprivate func parseTypes(_ raw: String?) -> Set<String>? {
    guard let raw = raw, !raw.isEmpty else { return nil }
    return Set(raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
}

/// Output DTO with resolved absolute paths included so callers don't have to
/// re-compute them from the activity root.
struct ActivityEventOutput: Encodable {
    let id: String
    let timestamp: String
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let eventType: String?
    let controlRole: String?
    let controlName: String?
    let controlValue: String?
    let clickX: Double?
    let clickY: Double?
    let nearbyText: String?
    let url: String?
    let screenshotPath: String?
    let screenshotAbsolutePath: String?
    let audioPath: String?
    let audioAbsolutePath: String?
    let aiPrompt: String?
    let aiResponse: String?

    init(event: Activity.ActivityEventJSON) {
        id = event.id
        timestamp = event.timestamp
        appName = event.appName
        bundleID = event.bundleID
        windowTitle = event.windowTitle
        eventType = event.eventType
        controlRole = event.controlRole
        controlName = event.controlName
        controlValue = event.controlValue
        clickX = event.clickX
        clickY = event.clickY
        nearbyText = event.nearbyText
        url = event.url
        screenshotPath = event.screenshotPath
        screenshotAbsolutePath = event.screenshotAbsolutePath
        audioPath = event.audioPath
        audioAbsolutePath = event.audioAbsolutePath
        aiPrompt = event.aiPrompt
        aiResponse = event.aiResponse
    }
}

// MARK: - Streaming line reader

/// Iterates UTF-8 lines from a file without slurping the entire contents.
/// Buffered reads keep ~64 KiB in memory at a time, so multi-megabyte daily
/// JSONL logs stay flat in RSS.
final class LineByLineFileReader {
    private let handle: FileHandle
    private var leftover = Data()
    private let bufferSize = 64 * 1024

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    func close() {
        try? handle.close()
    }

    func next() throws -> String? {
        while true {
            if let nlIndex = leftover.firstIndex(of: 0x0A) {
                let lineData = leftover.subdata(in: 0..<nlIndex)
                leftover.removeSubrange(0...nlIndex)
                return String(data: lineData, encoding: .utf8) ?? ""
            }
            let chunk = try handle.read(upToCount: bufferSize) ?? Data()
            if chunk.isEmpty {
                if leftover.isEmpty { return nil }
                let line = leftover
                leftover = Data()
                return String(data: line, encoding: .utf8) ?? ""
            }
            leftover.append(chunk)
        }
    }
}
