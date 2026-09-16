import AppKit
import Foundation

/// Coordinates export of activity events to file using `NSSavePanel`.
///
/// Supports:
/// - Full-day export and partial (selected rows) export — the caller resolves which events to pass.
/// - Three output formats: JSONL, CSV, plain text.
/// - Screenshot folder bundling: when exporting JSONL with screenshot references,
///   creates a folder containing the data file and a `screenshots/` subfolder with
///   paths rewritten to be relative within the export layout.
final class ActivityExportCoordinator {

    // MARK: - Export format

    enum Format: Int {
        case jsonl = 0
        case csv = 1
        case plainText = 2

        var fileExtension: String {
            switch self {
            case .jsonl:     return "jsonl"
            case .csv:       return "csv"
            case .plainText: return "txt"
            }
        }
    }

    // MARK: - Public API

    /// Presents an `NSSavePanel` and writes the export when the user confirms.
    ///
    /// - Parameters:
    ///   - events: Pre-resolved events to export (full day or selection — caller decides).
    ///   - dayString: Used for the default save filename (e.g. `"2026-04-11"`).
    ///   - screenshotsURL: Root screenshots directory; when present and the format is JSONL,
    ///                     screenshot files are bundled alongside the exported data file.
    ///   - parentWindow: When non-nil the panel is presented as a sheet; otherwise modal.
    func run(
        events: [ActivityEvent],
        dayString: String,
        screenshotsURL: URL?,
        parentWindow: NSWindow?
    ) {
        guard !events.isEmpty else { return }

        let savePanel = NSSavePanel()
        savePanel.title = "Export Activity Events"
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "activity-\(dayString).jsonl"

        let (accessoryView, formatPopup) = makeAccessoryView(dayString: dayString, savePanel: savePanel)
        savePanel.accessoryView = accessoryView

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = savePanel.url else { return }
            let format = Format(rawValue: formatPopup.indexOfSelectedItem) ?? .jsonl
            self?.performWrite(events: events, to: url, format: format, screenshotsURL: screenshotsURL)
        }

        if let w = parentWindow {
            savePanel.beginSheetModal(for: w, completionHandler: handle)
        } else {
            savePanel.begin(completionHandler: handle)
        }
    }

    // MARK: - Write (exposed for testing)

    /// Writes events to `url` in the given format, with optional screenshot bundling.
    ///
    /// For JSONL exports that contain screenshot paths, if `screenshotsURL` is provided, the
    /// method creates an export folder containing the data file and a `screenshots/` subfolder.
    func performWrite(
        events: [ActivityEvent],
        to url: URL,
        format: Format,
        screenshotsURL: URL?
    ) {
        let hasScreenshots = events.contains { $0.screenshotPath != nil }
        if format == .jsonl, hasScreenshots, let screenshotsURL {
            bundleWithScreenshots(events: events, to: url, screenshotsURL: screenshotsURL)
        } else {
            let content = formattedString(events: events, format: format)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentError(error)
            }
        }
    }

    /// Returns the formatted string for the given events and format (exposed for testing).
    func formattedString(events: [ActivityEvent], format: Format) -> String {
        switch format {
        case .jsonl:     return ActivityExportFormatter.jsonlString(for: events)
        case .csv:       return ActivityExportFormatter.csvString(for: events)
        case .plainText: return ActivityExportFormatter.plainTextString(for: events)
        }
    }

    // MARK: - Screenshot bundling

    private func bundleWithScreenshots(events: [ActivityEvent], to url: URL, screenshotsURL: URL) {
        // Create an export folder next to the chosen file.
        // E.g. if url = ~/Desktop/activity-2026-04-11.jsonl
        //      folderURL = ~/Desktop/activity-2026-04-11/
        let folderURL = url.deletingPathExtension()
        let dataFileURL = folderURL.appendingPathComponent(url.lastPathComponent)
        let exportScreenshotsURL = folderURL.appendingPathComponent("screenshots", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: exportScreenshotsURL, withIntermediateDirectories: true)
        } catch {
            presentError(error)
            return
        }

        // Copy screenshot files and rewrite their paths to be relative within the export folder.
        // Preserve the relative path (including day subdirectory) to avoid filename collisions
        // across multi-day exports (e.g. two days could have screenshots with identical filenames).
        let screenshotsBase = screenshotsURL.standardized.path + "/"
        let rewritten: [ActivityEvent] = events.map { event in
            guard let relPath = event.screenshotPath else { return event }
            let sourceURL = screenshotsURL.appendingPathComponent(relPath).standardized
            guard sourceURL.path.hasPrefix(screenshotsBase) else { return event }
            let destURL = exportScreenshotsURL.appendingPathComponent(relPath)
            // Ensure the day subdirectory exists inside the export screenshots folder.
            try? FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            return ActivityEvent(
                id: event.id,
                timestamp: event.timestamp,
                appName: event.appName,
                bundleID: event.bundleID,
                windowTitle: event.windowTitle,
                eventType: event.eventType,
                controlRole: event.controlRole,
                controlName: event.controlName,
                controlValue: event.controlValue,
                clickX: event.clickX,
                clickY: event.clickY,
                screenshotPath: "screenshots/\(relPath)",
                windowIdentifier: event.windowIdentifier,
                triggerMetadata: event.triggerMetadata
            )
        }

        let content = ActivityExportFormatter.jsonlString(for: rewritten)
        do {
            try content.write(to: dataFileURL, atomically: true, encoding: .utf8)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Accessory view

    private func makeAccessoryView(dayString: String, savePanel: NSSavePanel) -> (NSView, NSPopUpButton) {
        let label = NSTextField(labelWithString: "Format:")
        label.translatesAutoresizingMaskIntoConstraints = false

        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["JSONL", "CSV", "Plain Text"])
        popup.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 32))
        container.addSubview(label)
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])

        let extensions = ["jsonl", "csv", "txt"]
        let obs = NotificationCenter.default.addObserver(
            forName: NSMenu.didSendActionNotification,
            object: popup.menu,
            queue: .main
        ) { _ in
            let ext = extensions[popup.indexOfSelectedItem]
            savePanel.nameFieldStringValue = "activity-\(dayString).\(ext)"
        }
        // Retain the observer for the lifetime of the popup button.
        objc_setAssociatedObject(popup, &Self.obsKey, obs, .OBJC_ASSOCIATION_RETAIN)

        return (container, popup)
    }

    private static var obsKey: UInt8 = 0

    // MARK: - Error presentation

    private func presentError(_ error: Error) {
        DispatchQueue.main.async {
            NSAlert(error: error).runModal()
        }
    }
}
