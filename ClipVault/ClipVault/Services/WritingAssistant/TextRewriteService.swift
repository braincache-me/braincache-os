import AppKit
import Foundation

/// Rewrites the text in the focused field through the LLM, then replaces it in
/// place via a clipboard paste — one clean ⌘Z undo step in the target app.
final class TextRewriteService {

    private let keystrokes: KeystrokeSynthesizer
    private let openAI: OpenAIClient

    /// Set by the coordinator so the rewrite paste is not re-captured as a new
    /// clipboard entry.
    weak var clipboardMonitor: ClipboardMonitor?

    /// Guards against a second rewrite firing while one is still in flight.
    private(set) var isRewriting = false

    init(keystrokes: KeystrokeSynthesizer = KeystrokeSynthesizer(),
         openAI: OpenAIClient = .shared) {
        self.keystrokes = keystrokes
        self.openAI = openAI
    }

    /// Rewrites `snapshot.textToRewrite` and replaces it in the focused field.
    /// Rewrites only the selection when one exists, otherwise the whole field.
    /// `anchor` is the caret rect in AppKit screen coords, used to place the HUD.
    /// Must be called on the main thread.
    func rewrite(snapshot: FocusedTextSnapshot, anchor: CGRect?) {
        guard !isRewriting else { return }
        guard snapshot.canAttemptRewrite else { return }
        guard Settings.shared.isAIEnabled else {
            WritingAssistantHUD.shared.showError(
                "Add an OpenAI API key in Preferences → AI to use rewrite.", near: anchor)
            return
        }

        let pid: pid_t? = snapshot.pid > 0 ? snapshot.pid : nil

        isRewriting = true
        postRewriteStateChanged(true)
        WritingAssistantHUD.shared.showProgress("Rewriting…", near: anchor)

        Task { [weak self] in
            guard let self else { return }
            let capturedContent = await self.captureFocusedContentIfAvailable(
                snapshot: snapshot,
                pid: pid
            )
            let sourceText = capturedContent?.plainText ?? snapshot.textToRewrite
            guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    self.isRewriting = false
                    self.postRewriteStateChanged(false)
                    WritingAssistantHUD.shared.showSuccess("No text to rewrite.", near: anchor)
                }
                return
            }
            let model = Settings.shared.writingRewriteModel
            let messages: [OpenAIClient.ChatMessage] = [
                .init(role: "system", content: Settings.shared.writingRewritePrompt),
                .init(role: "user", content: Self.rewriteUserPrompt(sourceText: sourceText, snapshot: snapshot)),
            ]
            // Output length tracks input length, bounded by the user's preference.
            let maxTokens = max(256, min(Settings.shared.writingRewriteMaxOutputTokens, sourceText.count / 3 + 96))
            do {
                let response = try await self.openAI.chatCompletion(
                    model: model,
                    messages: messages,
                    maxTokens: maxTokens,
                    usageCategory: .chat
                )
                let cleaned = response.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    self.isRewriting = false
                    self.postRewriteStateChanged(false)
                    guard !cleaned.isEmpty, cleaned != sourceText else {
                        WritingAssistantHUD.shared.showSuccess(
                            "No changes suggested.", near: anchor)
                        return
                    }
                    self.applyRewrite(
                        cleaned,
                        replacingWholeField: !snapshot.hasSelection,
                        richContent: capturedContent?.richPayload,
                        pid: pid,
                        anchor: anchor
                    )
                }
            } catch {
                await MainActor.run {
                    self.isRewriting = false
                    self.postRewriteStateChanged(false)
                    WritingAssistantHUD.shared.showError(
                        "Rewrite failed: \(error.localizedDescription)", near: anchor)
                }
            }
        }
    }

    /// Runs a user instruction against the focused field and returns the
    /// generated text without committing it yet. The caller decides whether to
    /// replace, append, or copy.
    func generateAssistantResponse(
        instruction: String,
        snapshot: FocusedTextSnapshot,
        anchor: CGRect?,
        completion: @escaping (Result<WritingAssistantGeneratedResult, Error>) -> Void
    ) {
        guard !isRewriting else { return }
        guard snapshot.canAttemptRewrite else {
            completion(.failure(WritingAssistantServiceError.noEditableText))
            return
        }
        guard Settings.shared.isAIEnabled else {
            completion(.failure(WritingAssistantServiceError.apiKeyMissing))
            return
        }

        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            completion(.failure(WritingAssistantServiceError.emptyInstruction))
            return
        }

        let pid: pid_t? = snapshot.pid > 0 ? snapshot.pid : nil
        let sourceText = snapshot.textToRewrite

        isRewriting = true
        postRewriteStateChanged(true)

        Task { [weak self] in
            guard let self else { return }
            let model = Settings.shared.writingRewriteModel
            let messages: [OpenAIClient.ChatMessage] = [
                .init(role: "system", content: Settings.shared.writingRewritePrompt),
                .init(role: "user", content: Self.assistantUserPrompt(
                    instruction: trimmedInstruction,
                    sourceText: sourceText,
                    snapshot: snapshot
                )),
            ]
            let maxTokens = max(
                256,
                min(
                    Settings.shared.writingRewriteMaxOutputTokens,
                    max(sourceText.count, trimmedInstruction.count) / 3 + 160
                )
            )
            do {
                let response = try await self.openAI.chatCompletion(
                    model: model,
                    messages: messages,
                    maxTokens: maxTokens,
                    usageCategory: .chat
                )
                let cleaned = response.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    self.isRewriting = false
                    self.postRewriteStateChanged(false)
                    guard !cleaned.isEmpty else {
                        completion(.failure(WritingAssistantServiceError.emptyResponse))
                        return
                    }
                    completion(.success(WritingAssistantGeneratedResult(
                        text: cleaned,
                        replacingWholeField: !snapshot.hasSelection,
                        hadSelection: snapshot.hasSelection,
                        pid: pid
                    )))
                }
            } catch {
                await MainActor.run {
                    self.isRewriting = false
                    self.postRewriteStateChanged(false)
                    completion(.failure(error))
                }
            }
        }
    }

    /// Commits generated assistant text through the requested action.
    func commit(
        _ result: WritingAssistantGeneratedResult,
        mode: WritingAssistantCommitMode,
        anchor: CGRect?
    ) {
        switch mode {
        case .copy:
            let replacement = RichTextRewriteReplacement.plain(result.text)
            clipboardMonitor?.suppressNextCapture(hash: replacement.suppressionHash)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.text, forType: .string)

        case .replace:
            applyRewrite(
                result.text,
                replacingWholeField: result.replacingWholeField,
                richContent: nil,
                pid: result.pid,
                anchor: anchor
            )

        case .append:
            applyAppend(result.text, collapseSelectionFirst: result.hadSelection, pid: result.pid)
        }
    }

    // MARK: - Apply

    private func applyRewrite(
        _ text: String,
        replacingWholeField: Bool,
        richContent: RichTextRewritePayload?,
        pid: pid_t?,
        anchor: CGRect?
    ) {
        let replacement = richContent?.replacement(for: text) ?? .plain(text)
        clipboardMonitor?.suppressNextCapture(hash: replacement.suppressionHash)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch replacement.format {
        case .html(let html):
            pasteboard.setString(html, forType: RichTextRewritePayload.htmlType)
        case .rtf(let data):
            pasteboard.setData(data, forType: .rtf)
        case .plain:
            break
        }
        pasteboard.setString(replacement.plainText, forType: .string)

        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        // Let activation settle, then replace: ⌘A selects the whole field when
        // there was no selection; the paste over a selection is a single
        // undoable edit so ⌘Z restores the original in one step.
        let keystrokes = self.keystrokes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if replacingWholeField {
                keystrokes.selectAll(pid: pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    keystrokes.paste(pid: pid)
                }
            } else {
                keystrokes.paste(pid: pid)
            }
        }

        WritingAssistantHUD.shared.showSuccess("Rewritten — press ⌘Z to undo", near: anchor)
    }

    private func applyAppend(_ text: String, collapseSelectionFirst: Bool, pid: pid_t?) {
        let replacement = RichTextRewriteReplacement.plain(text)
        clipboardMonitor?.suppressNextCapture(hash: replacement.suppressionHash)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }

        let keystrokes = self.keystrokes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if collapseSelectionFirst {
                keystrokes.moveRight(pid: pid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    keystrokes.paste(pid: pid)
                }
            } else {
                keystrokes.paste(pid: pid)
            }
        }
    }

    private func postRewriteStateChanged(_ isRewriting: Bool) {
        NotificationCenter.default.post(
            name: .writingAssistantRewriteStateDidChange,
            object: self,
            userInfo: ["isRewriting": isRewriting]
        )
    }

    @MainActor
    private func captureFocusedContentIfAvailable(
        snapshot: FocusedTextSnapshot,
        pid: pid_t?
    ) async -> CapturedRewriteContent? {
        guard snapshot.hasSelection || snapshot.canAttemptRewrite else { return nil }

        let pasteboard = NSPasteboard.general
        let previousClipboard = PasteboardSnapshot.capture(from: pasteboard)
        if !snapshot.hasSelection {
            keystrokes.selectAll(pid: pid)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        keystrokes.copy(pid: pid)
        try? await Task.sleep(nanoseconds: 120_000_000)

        if let hash = RichTextRewritePayload.currentPasteboardHash(from: pasteboard) {
            clipboardMonitor?.suppressNextCapture(hash: hash)
        }
        let plainText = pasteboard.string(forType: .string)
        let richPayload = RichTextRewritePayload.read(
            from: pasteboard,
            expectedPlainText: snapshot.textToRewrite
        )
        let captured = CapturedRewriteContent(
            plainText: richPayload?.plainText ?? plainText ?? "",
            richPayload: richPayload
        )
        previousClipboard.restore(to: pasteboard)
        return captured.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : captured
    }

    static func rewriteUserPrompt(sourceText: String, snapshot: FocusedTextSnapshot) -> String {
        let appName = nonEmpty(snapshot.appName) ?? "Unknown app"
        let windowTitle = nonEmpty(snapshot.windowTitle) ?? "Unknown window"
        return """
        Rewrite the text below. Use the app name and window title only as context for tone, audience, and intent. Preserve the existing paragraph breaks, line breaks, lists, signatures, and sign-offs unless changing them is necessary for the rewrite. Return only the rewritten text, with no commentary.

        App name: \(appName)
        Window title: \(windowTitle)

        BEGIN TEXT
        \(sourceText)
        END TEXT
        """
    }

    static func assistantUserPrompt(
        instruction: String,
        sourceText: String,
        snapshot: FocusedTextSnapshot
    ) -> String {
        let appName = nonEmpty(snapshot.appName) ?? "Unknown app"
        let windowTitle = nonEmpty(snapshot.windowTitle) ?? "Unknown window"
        let role = nonEmpty(snapshot.role) ?? "Unknown role"
        let sourceKind: String
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sourceKind = "empty focused field"
        } else if snapshot.hasSelection {
            sourceKind = "selected text"
        } else {
            sourceKind = "focused field text"
        }

        return """
        The user invoked the BrainCache writing assistant inside a focused text input. Treat USER INSTRUCTION as the user's request, and use CURRENT FOCUSED INPUT as context. Return only the text that should be inserted, replaced, appended, or copied. Do not add commentary unless the user explicitly asks for it.

        If the focused app is a terminal or shell and the user asks for a command, return only the shell command to type, with no explanation or markdown.

        App name: \(appName)
        Window title: \(windowTitle)
        Focused role: \(role)
        Source kind: \(sourceKind)

        USER INSTRUCTION
        \(instruction)

        CURRENT FOCUSED INPUT
        \(sourceText)
        END CURRENT FOCUSED INPUT
        """
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum WritingAssistantCommitMode {
    case replace
    case append
    case copy
}

struct WritingAssistantGeneratedResult {
    let text: String
    let replacingWholeField: Bool
    let hadSelection: Bool
    let pid: pid_t?
}

enum WritingAssistantServiceError: LocalizedError {
    case apiKeyMissing
    case emptyInstruction
    case emptyResponse
    case noEditableText

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Add an OpenAI API key in Preferences > AI to use the writing assistant."
        case .emptyInstruction:
            return "Type what you want the assistant to do."
        case .emptyResponse:
            return "The assistant returned an empty response."
        case .noEditableText:
            return "Focus an editable text field first."
        }
    }
}

extension Notification.Name {
    static let writingAssistantRewriteStateDidChange =
        Notification.Name("com.clipvault.writingAssistantRewriteStateDidChange")
}

struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var captured: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    captured[type] = data
                }
            }
            return captured
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restoredItems = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

struct CapturedRewriteContent {
    let plainText: String
    let richPayload: RichTextRewritePayload?
}

struct RichTextRewritePayload {
    enum SourceFormat {
        case html
        case rtf

        var logName: String {
            switch self {
            case .html: return "html"
            case .rtf: return "rtf"
            }
        }
    }

    static let htmlType = NSPasteboard.PasteboardType("public.html")

    let format: SourceFormat
    let attributedString: NSAttributedString
    let plainText: String

    static func read(from pasteboard: NSPasteboard, expectedPlainText: String) -> RichTextRewritePayload? {
        let pasteboardPlain = pasteboard.string(forType: .string)

        if let html = pasteboard.string(forType: htmlType),
           let payload = fromHTML(html, pasteboardPlain: pasteboardPlain, expectedPlainText: expectedPlainText) {
            return payload
        }

        if let rtf = pasteboard.data(forType: .rtf),
           let payload = fromRTF(rtf, pasteboardPlain: pasteboardPlain, expectedPlainText: expectedPlainText) {
            return payload
        }

        return nil
    }

    static func currentPasteboardHash(from pasteboard: NSPasteboard) -> String? {
        if let html = pasteboard.string(forType: htmlType), !html.isEmpty {
            return Hashing.sha256(data: Data(html.utf8))
        }
        if let rtf = pasteboard.data(forType: .rtf), !rtf.isEmpty {
            return Hashing.sha256(data: rtf)
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Hashing.sha256(data: Data(text.utf8))
        }
        return nil
    }

    func replacement(for rewrittenText: String) -> RichTextRewriteReplacement? {
        let replacement = Self.replacementAttributedString(
            preservingStylesFrom: attributedString,
            rewrittenText: rewrittenText
        )
        let range = NSRange(location: 0, length: replacement.length)

        switch format {
        case .html:
            guard let data = try? replacement.data(
                from: range,
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ]
            ),
                  let html = String(data: data, encoding: .utf8)
            else { return nil }
            return RichTextRewriteReplacement(plainText: rewrittenText, format: .html(html))

        case .rtf:
            guard let data = try? replacement.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) else { return nil }
            return RichTextRewriteReplacement(plainText: rewrittenText, format: .rtf(data))
        }
    }

    private static func fromHTML(
        _ html: String,
        pasteboardPlain: String?,
        expectedPlainText: String
    ) -> RichTextRewritePayload? {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              )
        else { return nil }
        let plainText = bestPlainText(attributed: attributed, pasteboardPlain: pasteboardPlain)
        guard plainTextMatches(plainText, expectedPlainText: expectedPlainText) else { return nil }
        return RichTextRewritePayload(format: .html, attributedString: attributed, plainText: plainText)
    }

    private static func fromRTF(
        _ data: Data,
        pasteboardPlain: String?,
        expectedPlainText: String
    ) -> RichTextRewritePayload? {
        guard let attributed = NSAttributedString(rtf: data, documentAttributes: nil) else { return nil }
        let plainText = bestPlainText(attributed: attributed, pasteboardPlain: pasteboardPlain)
        guard plainTextMatches(plainText, expectedPlainText: expectedPlainText) else { return nil }
        return RichTextRewritePayload(format: .rtf, attributedString: attributed, plainText: plainText)
    }

    private static func bestPlainText(attributed: NSAttributedString, pasteboardPlain: String?) -> String {
        if let pasteboardPlain, !pasteboardPlain.isEmpty {
            return pasteboardPlain
        }
        return attributed.string
    }

    private static func plainTextMatches(_ captured: String, expectedPlainText: String) -> Bool {
        let captured = canonicalText(captured)
        let expected = canonicalText(expectedPlainText)
        guard !captured.isEmpty else { return false }
        guard !expected.isEmpty else { return true }
        if captured == expected || captured.contains(expected) || expected.contains(captured) {
            return true
        }
        let capturedCollapsed = whitespaceCollapsedText(captured)
        let expectedCollapsed = whitespaceCollapsedText(expected)
        return capturedCollapsed == expectedCollapsed
            || capturedCollapsed.contains(expectedCollapsed)
            || expectedCollapsed.contains(capturedCollapsed)
    }

    private static func canonicalText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whitespaceCollapsedText(_ text: String) -> String {
        canonicalText(text)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacementAttributedString(
        preservingStylesFrom original: NSAttributedString,
        rewrittenText: String
    ) -> NSAttributedString {
        let oldLength = original.length
        let newLength = (rewrittenText as NSString).length
        guard oldLength > 0, newLength > 0 else {
            return NSAttributedString(string: rewrittenText)
        }

        let baseAttributes = sanitizedAttributes(original.attributes(at: 0, effectiveRange: nil))
        let result = NSMutableAttributedString(string: rewrittenText, attributes: baseAttributes)
        original.enumerateAttributes(
            in: NSRange(location: 0, length: oldLength),
            options: []
        ) { attributes, range, _ in
            let newRange = proportionalRange(from: range, oldLength: oldLength, newLength: newLength)
            guard newRange.length > 0 else { return }
            result.addAttributes(sanitizedAttributes(attributes), range: newRange)
        }
        return result
    }

    private static func proportionalRange(
        from oldRange: NSRange,
        oldLength: Int,
        newLength: Int
    ) -> NSRange {
        let startRatio = Double(oldRange.location) / Double(oldLength)
        let endRatio = Double(oldRange.location + oldRange.length) / Double(oldLength)
        let start = min(newLength, max(0, Int((startRatio * Double(newLength)).rounded(.down))))
        var end = min(newLength, max(start, Int((endRatio * Double(newLength)).rounded(.up))))
        if end == start, start < newLength {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func sanitizedAttributes(
        _ attributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var sanitized = attributes
        sanitized.removeValue(forKey: .attachment)
        return sanitized
    }
}

struct RichTextRewriteReplacement {
    enum Format {
        case plain
        case html(String)
        case rtf(Data)
    }

    let plainText: String
    let format: Format

    static func plain(_ text: String) -> RichTextRewriteReplacement {
        RichTextRewriteReplacement(plainText: text, format: .plain)
    }

    var suppressionHash: String {
        switch format {
        case .html(let html):
            return Hashing.sha256(data: Data(html.utf8))
        case .rtf(let data):
            return Hashing.sha256(data: data)
        case .plain:
            return Hashing.sha256(data: Data(plainText.utf8))
        }
    }
}
