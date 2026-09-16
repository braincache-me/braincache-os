import Foundation

final class MediaFileManager {

    static let shared = MediaFileManager()

    private let mediaDir: URL

    init() {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let raw = appSupport
            .appendingPathComponent(BuildVariant.dataFolderName, isDirectory: true)
            .appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        // Resolve symlinks in the base directory itself so prefix checks below are reliable.
        mediaDir = raw.resolvingSymlinksInPath()
    }

    /// Initialise with a custom directory (useful for tests).
    init(mediaDirectory: URL) {
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        mediaDir = mediaDirectory.resolvingSymlinksInPath()
    }

    /// Save data and return the generated filename (UUID-based).
    func save(_ data: Data, extension ext: String = "bin") throws -> String {
        let filename = UUID().uuidString + "." + ext
        let fileURL = mediaDir.appendingPathComponent(filename)
        try data.write(to: fileURL, options: .atomic)
        return filename
    }

    /// Load data for a previously saved filename.
    func load(filename: String) throws -> Data {
        let fileURL = mediaDir.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(mediaDir.path + "/") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: fileURL)
    }

    /// Delete a stored media file.
    func delete(filename: String) throws {
        let fileURL = mediaDir.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(mediaDir.path + "/") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Returns true if the file exists in the media directory.
    func exists(filename: String) -> Bool {
        let fileURL = mediaDir.appendingPathComponent(filename).resolvingSymlinksInPath()
        guard fileURL.path.hasPrefix(mediaDir.path + "/") else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
