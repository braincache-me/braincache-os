import Compression
import Foundation
import GRDB
import PDFKit

/// Imports clipboard history from the Paste app (com.wiheads.paste) into ClipVault.
///
/// Paste stores its data in a Core Data SQLite database at:
///   ~/Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/db.sqlite
///
/// The pasteboard payload is stored in `ZITEMDATAENTITY.ZRAWPASTEBOARDITEMS` as either:
///   - Version 1 (byte 0x01): raw-deflate-compressed JSON array of pasteboard items
///   - Version 2 (byte 0x02): iCloud asset UUID reference (no local data — skipped)
///
/// Each pasteboard item in the JSON has `types` (UTI strings) and `dataByType` (base64 values).
final class PasteAppImporter {

    static let databaseFileName = "db.sqlite"

    struct ImportResult {
        var imported: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
        var cloudOnly: Int = 0
    }

    static let defaultDatabasePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Containers/com.wiheads.paste/Data/Library/Application Support/Paste/\(databaseFileName)"
    }()

    private let clipStore: ClipStore
    private let mediaFileManager: MediaFileManager

    init(clipStore: ClipStore, mediaFileManager: MediaFileManager = .shared) {
        self.clipStore = clipStore
        self.mediaFileManager = mediaFileManager
    }

    /// Import all items from the Paste database at `path`.
    /// `progress` is called on the main queue with (completed, total).
    func importDatabase(
        at path: String,
        progress: @escaping (Int, Int) -> Void
    ) throws -> ImportResult {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportError.databaseNotFound(path)
        }

        let sourceDB = try DatabaseQueue(path: path)

        let pinboardListPKs = try fetchPinboardListPKs(from: sourceDB)
        let appNames = try fetchAppNames(from: sourceDB)

        let totalCount = try sourceDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZITEMENTITY") ?? 0
        }

        var result = ImportResult()
        var processed = 0

        let batchSize = 200
        var offset = 0

        while offset < totalCount {
            let rows = try sourceDB.read { db -> [Row] in
                try Row.fetchAll(db, sql: """
                    SELECT
                        i.Z_PK,
                        i.ZRAWTYPE,
                        i.ZCREATEDAT,
                        i.ZSOURCEAPPLICATION,
                        i.ZLIST,
                        i.ZCHECKSUM,
                        d.ZRAWPASTEBOARDITEMS
                    FROM ZITEMENTITY i
                    LEFT JOIN ZITEMDATAENTITY d ON d.ZITEM = i.Z_PK
                    ORDER BY i.Z_PK ASC
                    LIMIT ? OFFSET ?
                """, arguments: [batchSize, offset])
            }

            if rows.isEmpty { break }
            offset += rows.count

            for row in rows {
                processed += 1
                if processed % 100 == 0 || processed == totalCount {
                    let current = processed
                    let total = totalCount
                    DispatchQueue.main.async { progress(current, total) }
                }

                guard let blobData: Data = row["ZRAWPASTEBOARDITEMS"] else {
                    result.failed += 1
                    continue
                }

                guard blobData.count > 1, blobData[0] == 0x01 else {
                    result.cloudOnly += 1
                    continue
                }

                let coreDataTimestamp: Double = row["ZCREATEDAT"] ?? 0
                let createdAt = Date(timeIntervalSinceReferenceDate: coreDataTimestamp)

                let sourceAppPK: Int64? = row["ZSOURCEAPPLICATION"]
                let sourceApp = sourceAppPK.flatMap { appNames[$0] }

                let listPK: Int64? = row["ZLIST"]
                let isPinned = listPK.map { pinboardListPKs.contains($0) } ?? false

                do {
                    guard let entry = try decodePasteboardBlob(blobData) else {
                        result.failed += 1
                        continue
                    }

                    if try clipStore.containsHash(entry.dataHash) {
                        result.skipped += 1
                        continue
                    }

                    try insertImportedClip(
                        entry: entry,
                        createdAt: createdAt,
                        sourceApp: sourceApp,
                        isPinned: isPinned
                    )
                    result.imported += 1
                } catch {
                    result.failed += 1
                }
            }
        }

        return result
    }

    // MARK: - Paste DB Queries

    private func fetchPinboardListPKs(from db: DatabaseQueue) throws -> Set<Int64> {
        try db.read { db in
            let pks = try Int64.fetchAll(
                db,
                sql: "SELECT Z_PK FROM ZLISTENTITY WHERE ZRAWTYPE = 2"
            )
            return Set(pks)
        }
    }

    private func fetchAppNames(from db: DatabaseQueue) throws -> [Int64: String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT Z_PK, ZNAME FROM ZAPPLICATIONENTITY")
            var dict: [Int64: String] = [:]
            for row in rows {
                if let pk: Int64 = row["Z_PK"], let name: String = row["ZNAME"] {
                    dict[pk] = name
                }
            }
            return dict
        }
    }

    // MARK: - Blob Decoding

    /// Decompress and parse the Paste pasteboard blob, returning the best-match content.
    private func decodePasteboardBlob(_ blob: Data) throws -> DecodedPasteItem? {
        let compressed = blob.dropFirst()
        guard let jsonData = rawInflate(compressed) else {
            return nil
        }

        guard let items = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
              let first = items.first,
              let dataByType = first["dataByType"] as? [String: String] else {
            return nil
        }

        return extractBestContent(from: dataByType)
    }

    private func rawInflate(_ data: Data) -> Data? {
        // COMPRESSION_ZLIB handles raw deflate (no zlib/gzip wrapper)
        let capacity = data.count * 8
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { srcPtr -> Int in
            guard let src = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, capacity,
                src, data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    // MARK: - Content Extraction

    private struct DecodedPasteItem {
        let contentType: ClipboardContentType
        let textContent: String?
        let rawData: Data?
        let fileURL: URL?
        let dataHash: String
        let byteSize: Int
        let isIndexed: Bool
    }

    /// Pick the richest pasteboard representation, matching PasteboardReader's priority.
    private func extractBestContent(from dataByType: [String: String]) -> DecodedPasteItem? {
        let maxIndexedByteSize = PasteboardReader.maxIndexedByteSize

        // HTML
        if let b64 = dataByType["public.html"],
           let data = Data(base64Encoded: b64), !data.isEmpty,
           let html = String(data: data, encoding: .utf8), !html.isEmpty {
            let indexed = data.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .html,
                textContent: indexed ? html : nil,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // RTF
        if let b64 = dataByType["public.rtf"],
           let data = Data(base64Encoded: b64), !data.isEmpty {
            let indexed = data.count <= maxIndexedByteSize
            let text = indexed ? NSAttributedString(rtf: data, documentAttributes: nil)?.string : nil
            return DecodedPasteItem(
                contentType: .rtf,
                textContent: text,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // PDF
        if let b64 = dataByType["com.adobe.pdf"] ?? dataByType["public.pdf"],
           let data = Data(base64Encoded: b64), !data.isEmpty {
            let extractedText = Self.extractPDFText(from: data)
            let textData = extractedText.map { Data($0.utf8) }
            let indexed = textData.map { !$0.isEmpty && $0.count <= maxIndexedByteSize } ?? false
            return DecodedPasteItem(
                contentType: .pdf,
                textContent: indexed ? extractedText : nil,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // Plain text
        if let b64 = dataByType["public.utf8-plain-text"] ?? dataByType["public.text"],
           let data = Data(base64Encoded: b64), !data.isEmpty,
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            let indexed = data.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .text,
                textContent: indexed ? text : nil,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // PNG image
        if let b64 = dataByType["public.png"],
           let data = Data(base64Encoded: b64), !data.isEmpty {
            let indexed = data.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .image,
                textContent: nil,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // TIFF image
        if let b64 = dataByType["public.tiff"],
           let data = Data(base64Encoded: b64), !data.isEmpty {
            let indexed = data.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .image,
                textContent: nil,
                rawData: data,
                fileURL: nil,
                dataHash: Hashing.sha256(data: data),
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // File URL
        if let b64 = dataByType["public.file-url"],
           let data = Data(base64Encoded: b64), !data.isEmpty,
           let urlString = String(data: data, encoding: .utf8),
           let url = URL(string: urlString) {
            let path = url.path
            let pathData = Data(path.utf8)
            let indexed = pathData.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .file,
                textContent: indexed ? path : nil,
                rawData: pathData,
                fileURL: url,
                dataHash: Hashing.sha256(data: pathData),
                byteSize: pathData.count,
                isIndexed: indexed
            )
        }

        // Dynamic file URL types (dyn.ah62d4rv4gu80g55...)
        for (type, b64) in dataByType where type.hasPrefix("dyn.") {
            guard let data = Data(base64Encoded: b64), !data.isEmpty,
                  let urlString = String(data: data, encoding: .utf8),
                  urlString.hasPrefix("file://"),
                  let url = URL(string: urlString) else { continue }
            let path = url.path
            let pathData = Data(path.utf8)
            let indexed = pathData.count <= maxIndexedByteSize
            return DecodedPasteItem(
                contentType: .file,
                textContent: indexed ? path : nil,
                rawData: pathData,
                fileURL: url,
                dataHash: Hashing.sha256(data: pathData),
                byteSize: pathData.count,
                isIndexed: indexed
            )
        }

        return nil
    }

    // MARK: - Insert

    private func insertImportedClip(
        entry: DecodedPasteItem,
        createdAt: Date,
        sourceApp: String?,
        isPinned: Bool
    ) throws {
        var savedMediaFileName: String? = nil

        if let rawData = entry.rawData,
           (entry.contentType == .image || entry.contentType == .rtf || entry.contentType == .html
            || entry.contentType == .pdf
            || (entry.contentType == .text && entry.textContent == nil)
            || (entry.contentType == .file && entry.textContent == nil)) {
            let ext = mediaExtension(for: entry)
            savedMediaFileName = try mediaFileManager.save(rawData, extension: ext)
        }

        var record = ClipRecord(
            id: nil,
            contentType: entry.contentType.rawValue,
            textContent: entry.textContent,
            dataHash: entry.dataHash,
            mediaFileName: savedMediaFileName,
            fileURL: entry.fileURL?.absoluteString,
            sourceApp: sourceApp,
            byteSize: entry.byteSize,
            createdAt: createdAt.timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: isPinned,
            isIndexed: entry.isIndexed
        )

        do {
            try clipStore.insertRecord(&record)
        } catch {
            if let filename = savedMediaFileName {
                try? mediaFileManager.delete(filename: filename)
            }
            throw error
        }
    }

    private func mediaExtension(for entry: DecodedPasteItem) -> String {
        switch entry.contentType {
        case .text, .file: return "txt"
        case .rtf: return "rtf"
        case .html: return "html"
        case .pdf: return "pdf"
        case .image:
            guard let data = entry.rawData, data.count >= 4 else { return "bin" }
            if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 {
                return "png"
            }
            return "tiff"
        }
    }

    private static func extractPDFText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        var parts: [String] = []
        var remainingChars = PasteboardReader.maxPDFExtractedTextChars
        let pageLimit = min(document.pageCount, PasteboardReader.maxPDFPagesForTextExtraction)

        for pageIndex in 0..<pageLimit {
            guard remainingChars > 0,
                  let page = document.page(at: pageIndex),
                  let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageText.isEmpty else { continue }

            if pageText.count <= remainingChars {
                parts.append(pageText)
                remainingChars -= pageText.count
            } else {
                let end = pageText.index(pageText.startIndex, offsetBy: remainingChars)
                parts.append(String(pageText[..<end]))
                remainingChars = 0
            }
        }

        let text = parts.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case databaseNotFound(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let path):
                return "Paste database not found at \(path)"
            }
        }
    }
}
