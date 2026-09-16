import AppKit
import Foundation
import GRDB

final class ImportExportCoordinator {

    static let shared = ImportExportCoordinator()

    private init() {}

    func importFromPaste(clipStore: ClipStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.message = "Select the Paste app database (db.sqlite)"

        let defaultPath = PasteAppImporter.defaultDatabasePath
        if FileManager.default.fileExists(atPath: defaultPath) {
            panel.directoryURL = URL(fileURLWithPath: defaultPath).deletingLastPathComponent()
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVault-paste-import-\(UUID().uuidString)", isDirectory: true)
        let tempDB = tempDir.appendingPathComponent("db.sqlite")

        do {
            try copySQLiteDatabaseForRead(at: url, to: tempDir, renamedTo: tempDB.lastPathComponent)
        } catch {
            showAlert(
                title: "Import Failed",
                message: "Could not copy database: \(error.localizedDescription)",
                style: .critical
            )
            return
        }

        let (alert, progressIndicator) = makeProgressAlert(
            title: "Importing from Paste…",
            message: "Preparing…",
            indeterminate: false
        )

        var cancelled = false

        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let importer = PasteAppImporter(clipStore: clipStore)
            do {
                let result = try importer.importDatabase(at: tempDB.path) { completed, total in
                    guard !cancelled else { return }
                    DispatchQueue.main.async {
                        progressIndicator.doubleValue = Double(completed) / Double(max(total, 1))
                        alert.informativeText = "Processing \(completed) of \(total)…"
                    }
                }

                DispatchQueue.main.async {
                    self.dismissProgressAlert(alert)

                    var lines: [String] = []
                    lines.append("\(result.imported) clips imported")
                    if result.skipped > 0 { lines.append("\(result.skipped) duplicates skipped") }
                    if result.cloudOnly > 0 { lines.append("\(result.cloudOnly) iCloud-only items skipped") }
                    if result.failed > 0 { lines.append("\(result.failed) items failed") }

                    self.showAlert(
                        title: "Import Complete",
                        message: lines.joined(separator: "\n"),
                        style: .informational
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.dismissProgressAlert(alert)
                    self.showAlert(
                        title: "Import Failed",
                        message: error.localizedDescription,
                        style: .critical
                    )
                }
            }
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            cancelled = true
        }
    }

    func exportClipVaultBackup() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ClipVaultBackupManager.defaultBackupName()
        panel.message = "Export a full BrainCache backup package"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let backupManager: ClipVaultBackupManager
        do {
            backupManager = try ClipVaultBackupManager.live()
        } catch {
            showAlert(
                title: "Export Failed",
                message: error.localizedDescription,
                style: .critical
            )
            return
        }

        let finalURL = ClipVaultBackupManager.normalizedBackupURL(destinationURL)
        let (alert, _) = makeProgressAlert(
            title: "Exporting BrainCache Backup…",
            message: "Copying the database and media files…",
            indeterminate: true
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try backupManager.exportCurrentData(to: finalURL, dbQueue: DatabaseManager.shared.dbQueue)
                DispatchQueue.main.async {
                    self.dismissProgressAlert(alert)
                    self.showAlert(
                        title: "Export Complete",
                        message: "Backup saved to:\n\(finalURL.path)",
                        style: .informational
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.dismissProgressAlert(alert)
                    self.showAlert(
                        title: "Export Failed",
                        message: error.localizedDescription,
                        style: .critical
                    )
                }
            }
        }

        _ = alert.runModal()
    }

    func importClipVaultBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a BrainCache backup package"

        guard panel.runModal() == .OK, let backupURL = panel.url else { return }

        let backupManager: ClipVaultBackupManager
        do {
            backupManager = try ClipVaultBackupManager.live()
            try backupManager.stageRestore(from: backupURL)
        } catch {
            showAlert(
                title: "Import Failed",
                message: error.localizedDescription,
                style: .critical
            )
            return
        }

        promptToQuitAfterStagedImport(backupManager: backupManager, sourceDescription: "backup")
    }

    func importExistingDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a BrainCache/ClipVault data folder or clipvault.db file"

        let appSupportURL = try? DatabaseManager.applicationSupportRootURL()
        panel.directoryURL = appSupportURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let backupManager: ClipVaultBackupManager
        do {
            backupManager = try ClipVaultBackupManager.live()
        } catch {
            showAlert(
                title: "Import Failed",
                message: error.localizedDescription,
                style: .critical
            )
            return
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVault-existing-db-import-\(UUID().uuidString)", isDirectory: true)
        let importPackageURL = tempRoot
            .appendingPathComponent("Imported Database.\(ClipVaultBackupManager.backupExtension)", isDirectory: true)

        do {
            try createImportPackage(from: selectedURL, at: importPackageURL)
            try backupManager.stageRestore(from: importPackageURL)
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            showAlert(
                title: "Import Failed",
                message: error.localizedDescription,
                style: .critical
            )
            return
        }

        try? FileManager.default.removeItem(at: tempRoot)
        promptToQuitAfterStagedImport(backupManager: backupManager, sourceDescription: "database")
    }

    func repairSearchIndex() {
        do {
            let result = try AIIndexingPipeline.shared.repairIndexingIssues()
            let message: String
            if result.requeuedClipCount > 0 {
                message = "Search index rebuilt. \(result.requeuedClipCount) clips were marked for AI repair."
            } else {
                message = "Search index rebuilt successfully."
            }

            showAlert(
                title: "Search Index Repaired",
                message: message,
                style: .informational
            )
        } catch {
            showAlert(
                title: "Repair Failed",
                message: error.localizedDescription,
                style: .critical
            )
        }
    }

    private func copySQLiteDatabaseForRead(at sourceURL: URL, to destinationDir: URL, renamedTo filename: String) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        let destinationURL = destinationDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try copySidecarIfPresent(for: sourceURL, into: destinationDir)
    }

    private func copySidecarIfPresent(for databaseURL: URL, into destinationDir: URL) throws {
        let sidecars = [
            databaseURL.deletingLastPathComponent().appendingPathComponent(databaseURL.lastPathComponent + "-wal"),
            databaseURL.deletingLastPathComponent().appendingPathComponent(databaseURL.lastPathComponent + "-shm"),
        ]

        for sidecarURL in sidecars where FileManager.default.fileExists(atPath: sidecarURL.path) {
            let didAccess = sidecarURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sidecarURL.stopAccessingSecurityScopedResource()
                }
            }
            let destinationURL = destinationDir.appendingPathComponent(sidecarURL.lastPathComponent)
            try? FileManager.default.copyItem(at: sidecarURL, to: destinationURL)
        }
    }

    private func createImportPackage(from selectedURL: URL, at packageURL: URL) throws {
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory) else {
            throw ExistingDatabaseImportError.invalidSelection("The selected item no longer exists.")
        }

        if isDirectory.boolValue {
            try createImportPackage(fromDataDirectory: selectedURL, at: packageURL)
        } else {
            try createImportPackage(fromDatabaseFile: selectedURL, at: packageURL)
        }
    }

    private func createImportPackage(fromDataDirectory directoryURL: URL, at packageURL: URL) throws {
        let didAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                directoryURL.stopAccessingSecurityScopedResource()
            }
        }

        let databaseURL = directoryURL.appendingPathComponent("clipvault.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ExistingDatabaseImportError.invalidSelection(
                "Selected folder does not contain clipvault.db."
            )
        }

        try copySQLiteDatabaseForRead(at: databaseURL, to: packageURL, renamedTo: "clipvault.db")
        try copyMediaDirectoryIfPresent(from: directoryURL, to: packageURL)
    }

    private func createImportPackage(fromDatabaseFile databaseURL: URL, at packageURL: URL) throws {
        try copySQLiteDatabaseForRead(at: databaseURL, to: packageURL, renamedTo: "clipvault.db")
        try copyMediaDirectoryIfPresent(from: databaseURL.deletingLastPathComponent(), to: packageURL)
    }

    private func copyMediaDirectoryIfPresent(from parentDirectoryURL: URL, to packageURL: URL) throws {
        let mediaURL = parentDirectoryURL.appendingPathComponent("media", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mediaURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }

        let destinationURL = packageURL.appendingPathComponent("media", isDirectory: true)
        let didAccess = mediaURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                mediaURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.copyItem(at: mediaURL, to: destinationURL)
    }

    private func promptToQuitAfterStagedImport(
        backupManager: ClipVaultBackupManager,
        sourceDescription: String
    ) {
        let alert = NSAlert()
        alert.messageText = "Import Ready"
        alert.informativeText = """
        The \(sourceDescription) has been staged successfully.

        Quit BrainCache now to finish importing it on the next launch.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Quit BrainCache")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        } else {
            try? backupManager.clearPendingRestore()
        }
    }

    private func makeProgressAlert(
        title: String,
        message: String,
        indeterminate: Bool
    ) -> (NSAlert, NSProgressIndicator) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        let button = alert.addButton(withTitle: "Working…")
        button.isEnabled = false

        let progressIndicator = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        progressIndicator.isIndeterminate = indeterminate
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = indeterminate ? 1 : 0
        progressIndicator.startAnimation(nil)
        alert.accessoryView = progressIndicator

        return (alert, progressIndicator)
    }

    private func dismissProgressAlert(_ alert: NSAlert) {
        alert.window.orderOut(nil)
        NSApp.stopModal()
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private enum ExistingDatabaseImportError: LocalizedError {
    case invalidSelection(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelection(let message):
            return message
        }
    }
}

final class ClipVaultBackupManager {

    static let backupExtension = "clipvaultbackup"

    let dataDirectoryURL: URL
    let pendingRestoreURL: URL

    private let fileManager: FileManager

    init(
        dataDirectoryURL: URL,
        pendingRestoreURL: URL,
        fileManager: FileManager = .default
    ) {
        self.dataDirectoryURL = dataDirectoryURL
        self.pendingRestoreURL = pendingRestoreURL
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) throws -> ClipVaultBackupManager {
        let dataDirectoryURL = try DatabaseManager.dataDirectoryURL(fileManager: fileManager)
        let pendingRestoreURL = dataDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("ClipVault Pending Restore.\(backupExtension)", isDirectory: true)

        return ClipVaultBackupManager(
            dataDirectoryURL: dataDirectoryURL,
            pendingRestoreURL: pendingRestoreURL,
            fileManager: fileManager
        )
    }

    static func normalizedBackupURL(_ url: URL) -> URL {
        guard url.pathExtension != backupExtension else { return url }
        return url.appendingPathExtension(backupExtension)
    }

    static func defaultBackupName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return "BrainCache Backup \(formatter.string(from: date)).\(backupExtension)"
    }

    func exportCurrentData(to destinationURL: URL, dbQueue: DatabaseQueue? = nil) throws {
        guard fileManager.fileExists(atPath: dataDirectoryURL.path) else {
            throw BackupError.dataDirectoryMissing
        }

        let finalURL = Self.normalizedBackupURL(destinationURL)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw BackupError.destinationAlreadyExists(finalURL.lastPathComponent)
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ClipVault-backup-export-\(UUID().uuidString)", isDirectory: true)
        let stagingBackupURL = stagingRoot.appendingPathComponent(finalURL.lastPathComponent, isDirectory: true)

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let copyOperation = {
            try self.fileManager.copyItem(at: self.dataDirectoryURL, to: stagingBackupURL)
        }

        do {
            if let dbQueue {
                try dbQueue.write { _ in
                    try copyOperation()
                }
            } else {
                try copyOperation()
            }

            try fileManager.moveItem(at: stagingBackupURL, to: finalURL)
        } catch {
            try? fileManager.removeItem(at: stagingBackupURL)
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }

        try? fileManager.removeItem(at: stagingRoot)
    }

    func stageRestore(from backupURL: URL) throws {
        try validateBackupDirectory(at: backupURL)
        try clearPendingRestore()
        try fileManager.createDirectory(at: pendingRestoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: backupURL, to: pendingRestoreURL)
    }

    @discardableResult
    func applyPendingRestoreIfNeeded() throws -> Bool {
        guard fileManager.fileExists(atPath: pendingRestoreURL.path) else { return false }

        try validateBackupDirectory(at: pendingRestoreURL)
        try fileManager.createDirectory(at: dataDirectoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let rollbackURL = dataDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("ClipVault-pre-restore-\(UUID().uuidString)", isDirectory: true)

        let liveDataExists = fileManager.fileExists(atPath: dataDirectoryURL.path)
        if liveDataExists {
            try fileManager.moveItem(at: dataDirectoryURL, to: rollbackURL)
        }

        do {
            try fileManager.moveItem(at: pendingRestoreURL, to: dataDirectoryURL)
            if liveDataExists {
                try? fileManager.removeItem(at: rollbackURL)
            }
            return true
        } catch {
            if fileManager.fileExists(atPath: dataDirectoryURL.path) {
                try? fileManager.removeItem(at: dataDirectoryURL)
            }
            if liveDataExists, fileManager.fileExists(atPath: rollbackURL.path) {
                try? fileManager.moveItem(at: rollbackURL, to: dataDirectoryURL)
            }
            throw error
        }
    }

    func clearPendingRestore() throws {
        if fileManager.fileExists(atPath: pendingRestoreURL.path) {
            try fileManager.removeItem(at: pendingRestoreURL)
        }
    }

    private func validateBackupDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackupError.invalidBackup("Please choose a BrainCache backup package.")
        }

        let databaseURL = url.appendingPathComponent("clipvault.db")
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw BackupError.invalidBackup("Backup package is missing clipvault.db.")
        }

        try validateDatabase(at: databaseURL)
    }

    private func validateDatabase(at url: URL) throws {
        let database = try DatabaseQueue(path: url.path)
        let hasClipsTable = try database.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1
                        FROM sqlite_master
                        WHERE type = 'table' AND name = 'clips'
                    )
                """
            ) ?? false
        }

        guard hasClipsTable else {
            throw BackupError.invalidBackup("Selected backup does not look like a BrainCache database.")
        }
    }

    enum BackupError: LocalizedError {
        case dataDirectoryMissing
        case destinationAlreadyExists(String)
        case invalidBackup(String)

        var errorDescription: String? {
            switch self {
            case .dataDirectoryMissing:
                return "BrainCache data was not found, so there is nothing to export yet."
            case .destinationAlreadyExists(let name):
                return "\(name) already exists. Choose a different backup name."
            case .invalidBackup(let message):
                return message
            }
        }
    }
}
