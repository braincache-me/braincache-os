import Foundation

/// Classifies a clipboard entry into a set of semantic tags using the OpenAI chat API.
///
/// Tags are validated against a known taxonomy and limited to a maximum of 8 per clip.
/// Common patterns (URLs, emails, file paths) are tagged heuristically without an API call.
final class ContentClassifier {

    // MARK: - Known Tag Taxonomy

    static let knownTags: Set<String> = [
        // Content type
        "code", "code:swift", "code:python", "code:javascript", "code:sql", "code:shell",
        "prose", "document", "pdf", "structured-data", "json", "xml", "csv",
        "url", "email-address", "phone-number", "file-path",
        // Topic / domain
        "finance", "legal", "medical", "tech", "design", "marketing", "personal", "work", "academic",
        // Significance
        "key-information", "credential", "api-key", "password", "address", "contact-info",
        "reference-number", "date-time",
        // Content quality
        "actionable", "reference-material", "article-excerpt", "conversation-snippet",
        "log-output", "error-message", "stack-trace",
        // Relevance
        "important", "trivial", "gibberish", "auto-generated", "boilerplate", "duplicate-ish",
        // Media
        "screenshot", "photo", "diagram", "chart", "ui-mockup", "icon", "meme", "document-scan"
    ]

    static let maxTags = 8
    static let maxTextLength = 2_000

    private let client: OpenAIClient

    init(client: OpenAIClient = .shared) {
        self.client = client
    }

    // MARK: - Public API

    /// Classifies the given clip record and returns an array of validated taxonomy tags.
    ///
    /// - Returns an array of known tags, max 8. Returns `["trivial"]` for empty content.
    ///   Returns `[]` for image-only clips with no description (Task 4 must run first).
    func classify(clip: ClipRecord) async throws -> [String] {
        let text: String?
        if let t = clip.textContent, !t.isEmpty {
            let isHTML = clip.contentType == ClipboardContentType.html.rawValue
            text = isHTML ? t.strippingHTMLTags : t
        } else if let d = clip.imageDescription, !d.isEmpty {
            text = d
        } else {
            text = nil
        }

        // Image-only with no description yet: defer to after Task 4 runs
        guard let rawText = text else {
            return []
        }

        // Heuristic pre-tagging: obvious patterns that don't need an LLM call
        let heuristicTags = heuristicTags(for: rawText, contentType: clip.contentType)
        if !heuristicTags.isEmpty {
            return Array(heuristicTags.prefix(Self.maxTags))
        }

        // Empty / whitespace-only
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ["trivial"]
        }

        let effectiveType = clip.contentType == ClipboardContentType.html.rawValue ? "text" : clip.contentType
        return try await classifyViaLLM(text: rawText, contentType: effectiveType)
    }

    // MARK: - Heuristic Pre-tagging

    /// Returns tags for patterns that can be detected without an LLM call.
    /// Returns an empty array when the content needs LLM classification.
    func heuristicTags(for text: String, contentType: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty { return ["trivial"] }

        var tags: [String] = []

        // URL: single-token text that starts with a common scheme
        if looksLikeURL(trimmed) {
            tags.append("url")
            return tags
        }

        // Email address
        if looksLikeEmail(trimmed) {
            tags.append("email-address")
            return tags
        }

        // File path: absolute POSIX or Windows path
        if looksLikeFilePath(trimmed) {
            tags.append("file-path")
            return tags
        }

        // JSON
        if looksLikeJSON(trimmed) {
            tags.append("json")
            tags.append("structured-data")
            return tags
        }

        // XML
        if looksLikeXML(trimmed) {
            tags.append("xml")
            tags.append("structured-data")
            return tags
        }

        return []
    }

    // MARK: - LLM Classification

    private func classifyViaLLM(text: String, contentType: String) async throws -> [String] {
        let truncated = truncate(text, to: Self.maxTextLength)
        let isShort = truncated.count < 10

        let systemPrompt = buildSystemPrompt()
        let userPrompt = buildUserPrompt(text: truncated, contentType: contentType, isShort: isShort)

        let messages = [
            OpenAIClient.ChatMessage(role: "system", content: systemPrompt),
            OpenAIClient.ChatMessage(role: "user", content: userPrompt)
        ]

        let response = try await client.chatCompletion(
            model: Settings.shared.classificationModel,
            messages: messages,
            maxTokens: 200,
            responseFormat: .json,
            usageCategory: .indexing
        )

        guard let content = response.choices.first?.message.content else {
            throw OpenAIError.noChoices
        }

        return try parseTags(from: content)
    }

    // MARK: - Prompt Construction

    func buildSystemPrompt() -> String {
        let taxonomy = Self.knownTags.sorted().joined(separator: ", ")
        return Prompts.shared.classification.systemTemplate.renderingTemplate([
            "taxonomy": taxonomy,
            "maxTags": String(Self.maxTags),
        ])
    }

    func buildUserPrompt(text: String, contentType: String, isShort: Bool) -> String {
        let template = isShort
            ? Prompts.shared.classification.userPromptShort
            : Prompts.shared.classification.userPromptLong
        return template.renderingTemplate([
            "contentType": contentType,
            "text": text,
        ])
    }

    // MARK: - Response Parsing

    /// Parses the LLM JSON response into a validated tag array.
    func parseTags(from jsonString: String) throws -> [String] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawTags = json["tags"] as? [Any] else {
            return ["trivial"]
        }

        let stringTags = rawTags.compactMap { $0 as? String }
        let validated = stringTags.filter { Self.knownTags.contains($0) }
        return Array(validated.prefix(Self.maxTags))
    }

    // MARK: - Helpers

    func truncate(_ text: String, to maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end]) + "…[truncated]"
    }

    private func looksLikeURL(_ text: String) -> Bool {
        guard !text.contains(" "), !text.contains("\n") else { return false }
        let schemes = ["http://", "https://", "ftp://", "ftps://"]
        return schemes.contains(where: { text.lowercased().hasPrefix($0) })
    }

    private func looksLikeEmail(_ text: String) -> Bool {
        guard !text.contains(" "), !text.contains("\n") else { return false }
        let parts = text.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let local = parts[0]
        let domain = parts[1]
        return !local.isEmpty && domain.contains(".") && domain.count > 3
    }

    private func looksLikeFilePath(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        // POSIX absolute path
        if text.hasPrefix("/") && text.count > 1 { return true }
        // macOS home dir
        if text.hasPrefix("~/") { return true }
        // Windows path
        if text.count >= 3 {
            let chars = Array(text)
            if chars[0].isLetter && chars[1] == ":" && (chars[2] == "\\" || chars[2] == "/") {
                return true
            }
        }
        return false
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("{") && t.hasSuffix("}")) ||
               (t.hasPrefix("[") && t.hasSuffix("]"))
    }

    private func looksLikeXML(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // XML declaration: <?xml ...
        if t.hasPrefix("<?xml") { return true }
        // Element-based XML: starts with < followed by a letter and contains a closing tag
        guard t.hasPrefix("<"), t.count > 2 else { return false }
        let idx = t.index(after: t.startIndex)
        return t[idx].isLetter && t.contains("</")
    }
}
