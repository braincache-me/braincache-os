import AppKit
import Foundation

/// Manages access to the activity log root folder.
///
/// The app is not sandboxed, so direct path access works. We still persist a bookmark
/// for compatibility, but always fall back to the stored path string if the bookmark fails.
final class ActivityCaptureFolderAccess {

    enum AccessError: LocalizedError {
        case bookmarkDataMissing
        case bookmarkResolutionFailed(Error)
        case bookmarkStale
        case directoryCreationFailed(Error)
        case userCancelled

        var errorDescription: String? {
            switch self {
            case .bookmarkDataMissing:
                return "No log folder has been selected. Please enable Activity Capture in Preferences."
            case .bookmarkResolutionFailed(let err):
                return "Could not access the activity log folder: \(err.localizedDescription)"
            case .bookmarkStale:
                return "The activity log folder could not be found. Please choose a new folder."
            case .directoryCreationFailed(let err):
                return "Could not create the log folder structure: \(err.localizedDescription)"
            case .userCancelled:
                return "Folder selection was cancelled."
            }
        }
    }

    /// The resolved root URL. Nil until `resolveAccess()` succeeds.
    private(set) var resolvedRootURL: URL?

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
    }

    // MARK: - Public API

    /// The `logs/` subdirectory URL inside the resolved root.
    var logsURL: URL? {
        resolvedRootURL.map { $0.appendingPathComponent("logs", isDirectory: true) }
    }

    /// The `screenshots/` subdirectory URL inside the resolved root.
    var screenshotsURL: URL? {
        resolvedRootURL.map { $0.appendingPathComponent("screenshots", isDirectory: true) }
    }

    /// The `recordings/` subdirectory URL inside the resolved root.
    var recordingsURL: URL? {
        resolvedRootURL.map { $0.appendingPathComponent("recordings", isDirectory: true) }
    }

    /// The `transcripts/` subdirectory URL inside the resolved root.
    var transcriptsURL: URL? {
        resolvedRootURL.map { $0.appendingPathComponent("transcripts", isDirectory: true) }
    }

    /// Attempt to resolve the persisted folder location.
    /// Tries bookmark first, then falls back to stored path string.
    @discardableResult
    func resolveAccess() throws -> URL {
        var bookmarkError: Error?

        // Try bookmark resolution first.
        if let bookmarkData = settings.activityCaptureLogRootBookmark {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData,
                                  options: [],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &isStale)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw AccessError.bookmarkStale
                }
                if isStale {
                    if let refreshed = try? url.bookmarkData(options: []) {
                        settings.activityCaptureLogRootBookmark = refreshed
                    }
                }
                resolvedRootURL = url
                settings.activityCaptureLogRootPath = url.path
                try createDirectoryStructureIfNeeded(root: url)
                return url
            } catch {
                bookmarkError = error
            }
        }

        // Fallback: use stored path string directly (app is not sandboxed).
        if let path = settings.activityCaptureLogRootPath {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                resolvedRootURL = url
                try createDirectoryStructureIfNeeded(root: url)
                return url
            }
        }

        if let bookmarkError {
            if let accessError = bookmarkError as? AccessError {
                throw accessError
            }
            throw AccessError.bookmarkResolutionFailed(bookmarkError)
        }

        throw AccessError.bookmarkDataMissing
    }

    /// Clear the resolved URL.
    func stopAccess() {
        resolvedRootURL = nil
    }

    /// Present an `NSOpenPanel` to let the user choose the log root folder.
    @discardableResult
    func promptUserToChooseFolder(relativeTo window: NSWindow? = nil) throws -> URL {
        let panel = NSOpenPanel()
        panel.title = "Choose Activity Log Folder"
        panel.message = "BrainCache will save activity logs inside this folder."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        let response: NSApplication.ModalResponse
        if let window {
            _ = window
            response = panel.runModal()
        } else {
            response = panel.runModal()
        }

        guard response == .OK, let chosen = panel.url else {
            throw AccessError.userCancelled
        }

        // Save both bookmark and plain path for maximum reliability.
        let bookmarkData = try chosen.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        settings.activityCaptureLogRootBookmark = bookmarkData
        settings.activityCaptureLogRootPath = chosen.path
        NotificationCenter.default.post(name: .activityCaptureLogRootDidChange, object: nil)

        stopAccess()
        resolvedRootURL = chosen

        try createDirectoryStructureIfNeeded(root: chosen)
        return chosen
    }

    // MARK: - Private helpers

    private func createDirectoryStructureIfNeeded(root: URL) throws {
        let fm = FileManager.default
        let subfolders = [
            root.appendingPathComponent("logs", isDirectory: true),
            root.appendingPathComponent("screenshots", isDirectory: true),
            root.appendingPathComponent("recordings", isDirectory: true),
            root.appendingPathComponent("transcripts", isDirectory: true)
        ]
        for folder in subfolders {
            if !fm.fileExists(atPath: folder.path) {
                do {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    throw AccessError.directoryCreationFailed(error)
                }
            }
        }
    }
}
