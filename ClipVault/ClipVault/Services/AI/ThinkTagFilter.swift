import Foundation

/// Removes `<think>…</think>` reasoning blocks from model output.
///
/// Nemotron reasoning models (and several other open-weight families) emit
/// their chain of thought inline in the completion. OpenAI models never do, so
/// the filter is only applied on non-OpenAI providers.
///
/// The filter is streaming-safe: a tag split across two SSE deltas (`"<thi"` +
/// `"nk>"`) is still recognised, because any trailing text that could still
/// grow into a tag is held back until the next chunk (or `flush()`).
struct ThinkTagFilter {

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var isInsideThinkBlock = false

    init() {}

    /// Feeds one chunk and returns the text that is safe to emit now.
    mutating func feed(_ chunk: String) -> String {
        buffer += chunk
        var emitted = ""

        while true {
            if isInsideThinkBlock {
                guard let range = buffer.range(of: Self.closeTag) else {
                    // Still inside: drop everything except a tail that could
                    // still grow into the closing tag.
                    buffer = String(buffer.suffix(Self.longestPartialSuffix(of: buffer, matching: Self.closeTag)))
                    break
                }
                buffer = String(buffer[range.upperBound...])
                isInsideThinkBlock = false
                continue
            }

            guard let range = buffer.range(of: Self.openTag) else {
                let holdBack = Self.longestPartialSuffix(of: buffer, matching: Self.openTag)
                let safeCount = buffer.count - holdBack
                if safeCount > 0 {
                    let splitIndex = buffer.index(buffer.startIndex, offsetBy: safeCount)
                    emitted += buffer[..<splitIndex]
                    buffer = String(buffer[splitIndex...])
                }
                break
            }
            emitted += buffer[..<range.lowerBound]
            buffer = String(buffer[range.upperBound...])
            isInsideThinkBlock = true
        }

        return emitted
    }

    /// Returns whatever is still held back once the stream ends. Text kept
    /// inside an unterminated think block is discarded.
    mutating func flush() -> String {
        defer {
            buffer = ""
            isInsideThinkBlock = false
        }
        return isInsideThinkBlock ? "" : buffer
    }

    /// One-shot convenience for non-streamed completions.
    static func strip(_ text: String) -> String {
        var filter = ThinkTagFilter()
        return filter.feed(text) + filter.flush()
    }

    /// Length (in characters) of the longest suffix of `text` that is a proper
    /// prefix of `tag` — the part we cannot yet classify as content or markup.
    private static func longestPartialSuffix(of text: String, matching tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            if text.hasSuffix(String(tag.prefix(length))) { return length }
        }
        return 0
    }
}
