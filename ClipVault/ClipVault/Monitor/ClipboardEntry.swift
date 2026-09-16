import Foundation

enum ClipboardContentType: String, Codable {
    case text
    case image
    case rtf
    case html
    case pdf
    case file
}

struct ClipboardEntry {
    var id: Int64?
    let contentType: ClipboardContentType
    let textContent: String?
    let dataHash: String
    let rawData: Data?
    let fileURL: URL?
    let sourceApp: String?
    let byteSize: Int
    let createdAt: Date
    /// False for items >10 MB — stored but excluded from FTS indexing.
    let isIndexed: Bool

    init(
        id: Int64? = nil,
        contentType: ClipboardContentType,
        textContent: String? = nil,
        dataHash: String,
        rawData: Data? = nil,
        fileURL: URL? = nil,
        sourceApp: String? = nil,
        byteSize: Int,
        createdAt: Date = Date(),
        isIndexed: Bool = true
    ) {
        self.id = id
        self.contentType = contentType
        self.textContent = textContent
        self.dataHash = dataHash
        self.rawData = rawData
        self.fileURL = fileURL
        self.sourceApp = sourceApp
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.isIndexed = isIndexed
    }
}
