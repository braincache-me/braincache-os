import Foundation

/// Formats a collection of `ActivityEvent` values into JSONL, CSV, or plain-text output.
///
/// All formatters operate on in-memory arrays rather than raw strings and produce
/// `String` values suitable for writing to a file or copying to the clipboard.
enum ActivityExportFormatter {

    // MARK: - JSONL

    /// Returns a JSONL string — one JSON object per line, no trailing blank line.
    static func jsonlString(for events: [ActivityEvent]) -> String {
        events.compactMap { try? $0.jsonlLine() }.joined(separator: "\n")
    }

    // MARK: - CSV

    /// CSV column order and header.
    private static let csvColumns: [String] = [
        "timestamp", "appName", "bundleID", "windowTitle", "eventType",
        "controlRole", "controlName", "controlValue",
        "clickX", "clickY", "screenshotPath", "windowIdentifier", "triggerMetadata"
    ]

    /// Returns a CSV string with a header row and one data row per event.
    static func csvString(for events: [ActivityEvent]) -> String {
        var lines: [String] = [csvColumns.joined(separator: ",")]
        for event in events {
            let row: [String] = [
                csvField(ActivityEvent.iso8601Formatter.string(from: event.timestamp)),
                csvField(event.appName),
                csvField(event.bundleID),
                csvField(event.windowTitle),
                csvField(event.eventType.rawValue),
                csvField(event.controlRole),
                csvField(event.controlName),
                csvField(event.controlValue),
                event.clickX.map { String(format: "%.1f", $0) } ?? "",
                event.clickY.map { String(format: "%.1f", $0) } ?? "",
                csvField(event.screenshotPath),
                csvField(event.windowIdentifier),
                csvField(event.triggerMetadata)
            ]
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Plain text

    /// Returns a human-readable plain-text summary, one event per line.
    static func plainTextString(for events: [ActivityEvent]) -> String {
        var lines: [String] = []
        for event in events {
            let ts = localTimestamp(event.timestamp)
            var parts: [String] = [
                "[\(ts)]",
                "[\(event.eventType.rawValue)]",
                event.appName
            ]
            if !event.windowTitle.isEmpty {
                parts.append("— \"\(event.windowTitle)\"")
            }
            if let role = event.controlRole {
                var controlParts = [role]
                if let name = event.controlName { controlParts.append("\"\(name)\"") }
                if let value = event.controlValue { controlParts.append("= \"\(value)\"") }
                parts.append("[\(controlParts.joined(separator: " "))]")
            }
            if let x = event.clickX, let y = event.clickY {
                parts.append("@(\(Int(x)),\(Int(y)))")
            }
            if let path = event.screenshotPath {
                parts.append("[screenshot: \(path)]")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private helpers

    /// Wraps a string in CSV quotes, escaping any internal quote characters.
    private static func csvField(_ value: String?) -> String {
        guard let value else { return "" }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    private static let localTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static func localTimestamp(_ date: Date) -> String {
        localTimeFormatter.string(from: date)
    }
}
