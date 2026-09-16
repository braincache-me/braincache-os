import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

protocol PasteboardProtocol {
    var changeCount: Int { get }
    func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType?
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?
    func propertyList(forType dataType: NSPasteboard.PasteboardType) -> Any?
}

extension NSPasteboard: PasteboardProtocol {}

final class PasteboardReader {

    // Concealed/transient type — skip these to avoid password managers leaking secrets
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    // Items larger than this threshold are stored but not indexed in FTS
    static let maxIndexedByteSize = 10 * 1024 * 1024 // 10 MB
    static let maxPDFPagesForTextExtraction = 50
    static let maxPDFExtractedTextChars = 200_000
    static let pdfTypes: [NSPasteboard.PasteboardType] = [
        .pdf,
        NSPasteboard.PasteboardType("com.adobe.pdf"),
        NSPasteboard.PasteboardType("public.pdf")
    ]
    static let fileURLTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("public.file-url"),
        NSPasteboard.PasteboardType("NSURLPboardType")
    ]

    /// Returns `true` when the HTML is just browser chrome (meta/span/div wrappers)
    /// around the same text already available as plain text on the pasteboard.
    static func isWrappedPlainText(html: String, plainText: String) -> Bool {
        var stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        stripped = stripped
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        stripped = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlain = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPlain.isEmpty else { return false }
        return stripped == trimmedPlain
    }

    func read(from pasteboard: PasteboardProtocol, sourceApp: String? = nil) -> ClipboardEntry? {
        // Skip concealed items (e.g., password manager secrets)
        if pasteboard.availableType(from: [Self.concealedType]) != nil {
            return nil
        }

        // HTML — store plain text in textContent for search/display/AI;
        // raw HTML goes to rawData (saved as media file for paste-back fidelity).
        let htmlType = NSPasteboard.PasteboardType("public.html")
        if let html = pasteboard.string(forType: htmlType), !html.isEmpty {
            let plainText = pasteboard.string(forType: .string)
            let htmlData = Data(html.utf8)
            let indexed = htmlData.count <= Self.maxIndexedByteSize

            if let plainText = plainText, !plainText.isEmpty {
                if Self.isWrappedPlainText(html: html, plainText: plainText) {
                    let textData = Data(plainText.utf8)
                    let textIndexed = textData.count <= Self.maxIndexedByteSize
                    return ClipboardEntry(
                        contentType: .text,
                        textContent: textIndexed ? plainText : nil,
                        dataHash: Hashing.sha256(data: textData),
                        rawData: textData,
                        sourceApp: sourceApp,
                        byteSize: textData.count,
                        isIndexed: textIndexed
                    )
                }

                return ClipboardEntry(
                    contentType: .html,
                    textContent: indexed ? plainText : nil,
                    dataHash: Hashing.sha256(data: htmlData),
                    rawData: htmlData,
                    sourceApp: sourceApp,
                    byteSize: htmlData.count,
                    isIndexed: indexed
                )
            }

            return ClipboardEntry(
                contentType: .html,
                textContent: indexed ? html : nil,
                dataHash: Hashing.sha256(data: htmlData),
                rawData: htmlData,
                sourceApp: sourceApp,
                byteSize: htmlData.count,
                isIndexed: indexed
            )
        }

        // RTF
        if let rtfData = pasteboard.data(forType: .rtf), !rtfData.isEmpty {
            let indexed = rtfData.count <= Self.maxIndexedByteSize
            let text = indexed ? NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string : nil
            return ClipboardEntry(
                contentType: .rtf,
                textContent: text,
                dataHash: Hashing.sha256(data: rtfData),
                rawData: rtfData,
                sourceApp: sourceApp,
                byteSize: rtfData.count,
                isIndexed: indexed
            )
        }

        // PDF — store the full PDF payload and locally extract selectable text for search/AI.
        // Extraction is capped so a long document cannot stall clipboard polling indefinitely.
        if let pdfData = firstData(from: pasteboard, forTypes: Self.pdfTypes), !pdfData.isEmpty {
            return makePDFEntry(data: pdfData, fileURL: nil, sourceApp: sourceApp)
        }

        // Plain text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let data = Data(text.utf8)
            let indexed = data.count <= Self.maxIndexedByteSize
            return ClipboardEntry(
                contentType: .text,
                textContent: indexed ? text : nil,
                dataHash: Hashing.sha256(data: data),
                rawData: data,
                sourceApp: sourceApp,
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        // PNG image
        if let imageData = pasteboard.data(forType: .png), !imageData.isEmpty {
            let indexed = imageData.count <= Self.maxIndexedByteSize
            return ClipboardEntry(
                contentType: .image,
                dataHash: Hashing.sha256(data: imageData),
                rawData: imageData,
                sourceApp: sourceApp,
                byteSize: imageData.count,
                isIndexed: indexed
            )
        }

        // TIFF image
        if let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty {
            let indexed = tiffData.count <= Self.maxIndexedByteSize
            return ClipboardEntry(
                contentType: .image,
                dataHash: Hashing.sha256(data: tiffData),
                rawData: tiffData,
                sourceApp: sourceApp,
                byteSize: tiffData.count,
                isIndexed: indexed
            )
        }

        // File URLs
        for fileURLType in Self.fileURLTypes {
            if let fileURLString = pasteboard.string(forType: fileURLType),
               let url = URL(string: fileURLString) {
                return readFileURL(url, sourceApp: sourceApp)
            }

            if let fileURLData = pasteboard.data(forType: fileURLType),
               let fileURLString = String(data: fileURLData, encoding: .utf8),
               let url = URL(string: fileURLString) {
                return readFileURL(url, sourceApp: sourceApp)
            }
        }

        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pasteboard.propertyList(forType: filenamesType) as? [String],
           let first = filenames.first {
            if filenames.count == 1 {
                let url = URL(fileURLWithPath: first)
                if let entry = readFileURL(url, sourceApp: sourceApp) {
                    return entry
                }
            }

            let url = URL(fileURLWithPath: first)
            // Hash all filenames so two multi-file selections that share only the first
            // path are not incorrectly deduplicated.
            let joined = filenames.joined(separator: "\n")
            let data = Data(joined.utf8)
            let indexed = data.count <= Self.maxIndexedByteSize
            return ClipboardEntry(
                contentType: .file,
                textContent: indexed ? joined : nil,
                dataHash: Hashing.sha256(data: data),
                rawData: data,
                fileURL: url,
                sourceApp: sourceApp,
                byteSize: data.count,
                isIndexed: indexed
            )
        }

        return nil
    }

    private func firstData(
        from pasteboard: PasteboardProtocol,
        forTypes types: [NSPasteboard.PasteboardType]
    ) -> Data? {
        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return data
            }
        }
        return nil
    }

    private func readFileURL(_ url: URL, sourceApp: String?) -> ClipboardEntry? {
        guard url.isFileURL else { return nil }
        if url.pathExtension.lowercased() == "pdf",
           let data = try? Data(contentsOf: url), !data.isEmpty {
            return makePDFEntry(data: data, fileURL: url, sourceApp: sourceApp)
        }

        let path = url.path
        let data = Data(path.utf8)
        let indexed = data.count <= Self.maxIndexedByteSize
        return ClipboardEntry(
            contentType: .file,
            textContent: indexed ? path : nil,
            dataHash: Hashing.sha256(data: data),
            rawData: data,
            fileURL: url,
            sourceApp: sourceApp,
            byteSize: data.count,
            isIndexed: indexed
        )
    }

    private func makePDFEntry(data: Data, fileURL: URL?, sourceApp: String?) -> ClipboardEntry {
        let extractedText = extractPDFText(from: data)
        let textData = extractedText.map { Data($0.utf8) }
        let indexed = textData.map { !$0.isEmpty && $0.count <= Self.maxIndexedByteSize } ?? false

        return ClipboardEntry(
            contentType: .pdf,
            textContent: indexed ? extractedText : nil,
            dataHash: Hashing.sha256(data: data),
            rawData: data,
            fileURL: fileURL,
            sourceApp: sourceApp,
            byteSize: data.count,
            isIndexed: indexed
        )
    }

    func extractPDFText(from data: Data) -> String? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }

        var parts: [String] = []
        var remainingChars = Self.maxPDFExtractedTextChars
        let pageLimit = min(document.pageCount, Self.maxPDFPagesForTextExtraction)

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
}
