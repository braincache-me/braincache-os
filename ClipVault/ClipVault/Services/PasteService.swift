import AppKit
import CoreGraphics
import Foundation

/// Protocol for writing to a pasteboard — allows dependency injection in tests.
protocol PasteboardWriteProtocol {
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType dataType: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setPropertyList(_ plist: Any, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardWriteProtocol {}

/// Writes clip content back to the system pasteboard and fires a ⌘V keystroke
/// targeting the previously frontmost application.
final class PasteService {

    private let pasteboard: PasteboardWriteProtocol
    private let mediaFileManager: MediaFileManager

    init(pasteboard: PasteboardWriteProtocol = NSPasteboard.general,
         mediaFileManager: MediaFileManager = .shared) {
        self.pasteboard = pasteboard
        self.mediaFileManager = mediaFileManager
    }

    // MARK: - Public API

    /// Write clip content to the pasteboard and send ⌘V to the target application.
    /// Does nothing if no content could be written to the pasteboard.
    ///
    /// `mode` controls how rich clips (HTML/RTF) are written:
    ///  - `.rich` writes the original payload alongside a plain-text fallback so the
    ///    receiving app can pick the richest representation it supports.
    ///  - `.plain` writes only `.string`, guaranteeing the paste arrives as plain text.
    /// Mode is ignored for non-rich content types (text, image, PDF, file).
    func paste(record: ClipRecord, targetBundleID: String?, mode: PasteMode = .rich) {
        guard writeToClipboard(record: record, mode: mode) else { return }
        activateAndPaste(bundleID: targetBundleID)
    }

    // MARK: - Pasteboard write (testable)

    /// Write a ClipRecord's content to the pasteboard without sending keystrokes.
    /// Returns true if content was successfully written, false if nothing was written.
    @discardableResult
    func writeToClipboard(record: ClipRecord, mode: PasteMode = .rich) -> Bool {
        // Rehydrate all content before touching the pasteboard so a missing/corrupt
        // file or failed decode never leaves the user's clipboard wiped and empty.
        switch record.contentType {
        case ClipboardContentType.text.rawValue:
            let text: String?
            if let t = record.textContent {
                text = t
            } else if let filename = record.mediaFileName,
                      let data = try? mediaFileManager.load(filename: filename) {
                text = String(data: data, encoding: .utf8)
            } else {
                text = nil
            }
            guard let text else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)

        case ClipboardContentType.html.rawValue:
            // textContent stores plain text for search/AI; HTML lives in the media file.
            let htmlFromFile: String?
            if let filename = record.mediaFileName,
               let data = try? mediaFileManager.load(filename: filename) {
                htmlFromFile = String(data: data, encoding: .utf8)
            } else {
                htmlFromFile = nil
            }
            let html = htmlFromFile ?? record.textContent
            guard let html else { return false }
            // Derive the plain-text representation once so both modes can use it.
            let plain: String
            if htmlFromFile != nil, let pt = record.textContent {
                plain = pt
            } else {
                plain = html.strippingHTMLTags
            }
            pasteboard.clearContents()
            if mode == .plain {
                return pasteboard.setString(plain, forType: .string)
            }
            pasteboard.setString(html, forType: NSPasteboard.PasteboardType("public.html"))
            return pasteboard.setString(plain, forType: .string)

        case ClipboardContentType.rtf.rawValue:
            if mode == .plain {
                let text: String?
                if let t = record.textContent {
                    text = t
                } else if let filename = record.mediaFileName,
                          let data = try? mediaFileManager.load(filename: filename),
                          let attr = try? NSAttributedString(
                              data: data,
                              options: [.documentType: NSAttributedString.DocumentType.rtf],
                              documentAttributes: nil) {
                    text = attr.string
                } else {
                    text = nil
                }
                guard let text else { return false }
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
            if let filename = record.mediaFileName,
               let data = try? mediaFileManager.load(filename: filename) {
                pasteboard.clearContents()
                let wrote = pasteboard.setData(data, forType: .rtf)
                if let text = record.textContent {
                    pasteboard.setString(text, forType: .string)
                }
                return wrote
            } else if let text = record.textContent {
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
            return false

        case ClipboardContentType.image.rawValue:
            guard let filename = record.mediaFileName,
                  let data = try? mediaFileManager.load(filename: filename) else { return false }
            pasteboard.clearContents()
            let pasteboardType: NSPasteboard.PasteboardType = filename.hasSuffix(".png") ? .png : .tiff
            return pasteboard.setData(data, forType: pasteboardType)

        case ClipboardContentType.pdf.rawValue:
            if let filename = record.mediaFileName,
               let data = try? mediaFileManager.load(filename: filename) {
                pasteboard.clearContents()
                let wrote = pasteboard.setData(data, forType: .pdf)
                if let text = record.textContent {
                    pasteboard.setString(text, forType: .string)
                }
                return wrote
            } else if let text = record.textContent {
                pasteboard.clearContents()
                return pasteboard.setString(text, forType: .string)
            }
            return false

        case ClipboardContentType.file.rawValue:
            // textContent stores all paths joined by "\n" (set by PasteboardReader for multi-file).
            // Reconstruct the full array so multi-file Finder selections paste correctly.
            // For large entries (>10 MB) textContent is nil; load from the media file instead.
            let paths: [String]
            if let text = record.textContent {
                paths = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            } else if let filename = record.mediaFileName,
                      let data = try? mediaFileManager.load(filename: filename),
                      let text = String(data: data, encoding: .utf8) {
                paths = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            } else if let fileURLStr = record.fileURL, let url = URL(string: fileURLStr) {
                paths = [url.path]
            } else {
                return false
            }
            guard !paths.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.setPropertyList(paths, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        default:
            // unknown type — plain-text fallback
            guard let text = record.textContent else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }

    // MARK: - Activate and paste

    private func activateAndPaste(bundleID: String?) {
        guard AccessibilityChecker.isGranted else {
            NSLog("BrainCache: Accessibility permission not granted — cannot paste via CGEvent")
            DispatchQueue.main.async {
                AccessibilityChecker.requestAccess()
            }
            return
        }

        let targetPid: pid_t?
        if let id = bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate(options: [.activateIgnoringOtherApps])
            targetPid = app.processIdentifier
        } else {
            targetPid = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Self.postCmdV(targetPid: targetPid)
        }
    }

    // MARK: - CGEvent ⌘V

    static func postCmdV(targetPid: pid_t? = nil) {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Virtual key 0x09 = V on a standard US keyboard layout
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        if let pid = targetPid {
            keyDown.postToPid(pid)
            keyUp.postToPid(pid)
        } else {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
