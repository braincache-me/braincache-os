import XCTest
import GRDB
@testable import ClipVault

final class ClipVaultBackupManagerTests: XCTestCase {

    private var tempRoot: URL!
    private var liveDataURL: URL!
    private var pendingRestoreURL: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipVaultBackupManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        liveDataURL = tempRoot.appendingPathComponent("LiveData", isDirectory: true)
        pendingRestoreURL = tempRoot.appendingPathComponent("Pending.\(ClipVaultBackupManager.backupExtension)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testExportCurrentDataCopiesDatabaseAndMedia() throws {
        try createDataDirectory(at: liveDataURL, clipText: "live clip", mediaFileName: "live.txt")
        let manager = makeManager()
        let destinationURL = tempRoot.appendingPathComponent("Exported.\(ClipVaultBackupManager.backupExtension)", isDirectory: true)

        try manager.exportCurrentData(to: destinationURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("clipvault.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("media/live.txt").path))
        XCTAssertEqual(try fetchFirstClipText(from: destinationURL), "live clip")
    }

    func testStageRestoreCopiesBackupPackageToPendingLocation() throws {
        let sourceBackupURL = tempRoot.appendingPathComponent("Source.\(ClipVaultBackupManager.backupExtension)", isDirectory: true)
        try createDataDirectory(at: sourceBackupURL, clipText: "backup clip", mediaFileName: "backup.txt")
        let manager = makeManager()

        try manager.stageRestore(from: sourceBackupURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingRestoreURL.appendingPathComponent("clipvault.db").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingRestoreURL.appendingPathComponent("media/backup.txt").path))
        XCTAssertEqual(try fetchFirstClipText(from: pendingRestoreURL), "backup clip")
    }

    func testApplyPendingRestoreReplacesLiveData() throws {
        try createDataDirectory(at: liveDataURL, clipText: "old clip", mediaFileName: "old.txt")

        let sourceBackupURL = tempRoot.appendingPathComponent("Replacement.\(ClipVaultBackupManager.backupExtension)", isDirectory: true)
        try createDataDirectory(at: sourceBackupURL, clipText: "new clip", mediaFileName: "new.txt")

        let manager = makeManager()
        try manager.stageRestore(from: sourceBackupURL)

        let didApply = try manager.applyPendingRestoreIfNeeded()

        XCTAssertTrue(didApply)
        XCTAssertEqual(try fetchFirstClipText(from: liveDataURL), "new clip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDataURL.appendingPathComponent("media/new.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDataURL.appendingPathComponent("media/old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingRestoreURL.path))
    }

    private func makeManager() -> ClipVaultBackupManager {
        ClipVaultBackupManager(
            dataDirectoryURL: liveDataURL,
            pendingRestoreURL: pendingRestoreURL
        )
    }

    private func createDataDirectory(at url: URL, clipText: String, mediaFileName: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let dbURL = url.appendingPathComponent("clipvault.db")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE clips (
                    id INTEGER PRIMARY KEY,
                    text_content TEXT
                )
            """)
            try db.execute(
                sql: "INSERT INTO clips (text_content) VALUES (?)",
                arguments: [clipText]
            )
        }

        let mediaURL = url.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        try Data("media".utf8).write(to: mediaURL.appendingPathComponent(mediaFileName))
    }

    private func fetchFirstClipText(from dataDirectoryURL: URL) throws -> String? {
        let dbURL = dataDirectoryURL.appendingPathComponent("clipvault.db")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        return try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT text_content FROM clips LIMIT 1")
        }
    }
}
