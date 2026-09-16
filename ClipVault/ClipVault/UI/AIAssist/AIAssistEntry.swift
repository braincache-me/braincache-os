import AppKit
import Foundation

/// One Q&A round in the AI Assist window.
///
/// Each press of "Ask AI" creates a new entry. `response` accumulates as tokens
/// stream in. The window's `‹ N/M ›` nav lets the user revisit older entries
/// once they've completed; in-flight entries are always the latest one.
final class AIAssistEntry {

    enum State {
        case streaming
        case done
        case error(String)
    }

    let id = UUID()
    let createdAt = Date()
    let prompt: String
    let attachedWindowSummary: String?
    let attachedThumbnail: NSImage?

    var response: String = ""
    /// Reasoning-summary ("thinking") text streamed via the Responses API,
    /// plus one-line notes for tool calls made along the way. Rendered as a
    /// collapsible block above the answer.
    var thinking: String = ""
    /// Transient status shown in place of "Streaming…" while the model is
    /// thinking, web-searching, or running a local tool. Nil once answer
    /// tokens start arriving.
    var statusDetail: String?
    var state: State = .streaming

    init(
        prompt: String,
        attachedWindowSummary: String? = nil,
        attachedThumbnail: NSImage? = nil
    ) {
        self.prompt = prompt
        self.attachedWindowSummary = attachedWindowSummary
        self.attachedThumbnail = attachedThumbnail
    }
}
