import Foundation
import os

/// Translates Ask AI's Responses-API request shape into Chat Completions.
///
/// Token Factory (and most other OpenAI-compatible gateways) expose only
/// `POST /chat/completions`, so `OpenAIClient.streamResponse` falls back to a
/// streaming chat-completions request on non-OpenAI providers. This type owns
/// the pure translation pieces so they can be unit-tested without a network.
///
/// Three shape differences matter:
/// - Tools: Responses uses a *flat* function schema
///   (`{"type":"function","name":…,"parameters":…}`); Chat Completions nests it
///   under a `"function"` key. Hosted tools such as `{"type":"web_search"}`
///   have no chat-completions equivalent and are skipped (and logged).
/// - Input: Responses content blocks are `input_text` / `input_image`;
///   Chat Completions uses `text` / `image_url`.
/// - Continuation: Responses replays server-stored context via
///   `previous_response_id`; chat completions has no server state, so the
///   assistant message carrying `tool_calls` plus one `role:"tool"` message
///   per call must be appended by the client. `ResponsesChatSessionStore`
///   keeps that history keyed by a synthetic response id.
enum ResponsesChatCompletionsBridge {

    private static let logger = Logger(subsystem: "com.braincache.ai", category: "provider-bridge")

    /// Converts Responses-API tool definitions to the chat-completions shape.
    ///
    /// Returns the converted tools plus the hosted-tool types that had to be
    /// dropped, so the caller can log them once per request.
    static func chatTools(from responsesTools: [[String: Any]]) -> (tools: [[String: Any]], skippedHostedTools: [String]) {
        var converted: [[String: Any]] = []
        var skipped: [String] = []

        for tool in responsesTools {
            let type = (tool["type"] as? String) ?? ""
            guard type == "function" else {
                skipped.append(type.isEmpty ? "unknown" : type)
                continue
            }
            // Already nested (defensive: a caller may hand us a chat-shaped tool).
            if let nested = tool["function"] as? [String: Any] {
                converted.append(["type": "function", "function": nested])
                continue
            }
            guard let name = tool["name"] as? String else {
                skipped.append("function(unnamed)")
                continue
            }
            var function: [String: Any] = ["name": name]
            if let description = tool["description"] as? String {
                function["description"] = description
            }
            if let parameters = tool["parameters"] as? [String: Any] {
                function["parameters"] = parameters
            }
            converted.append(["type": "function", "function": function])
        }

        return (converted, skipped)
    }

    /// Logs the hosted tools that could not be forwarded, once per request.
    static func logSkippedHostedTools(_ skipped: [String]) {
        guard !skipped.isEmpty else { return }
        let list = skipped.joined(separator: ", ")
        logger.log("skipping hosted tool(s) unsupported by this provider: \(list, privacy: .public)")
    }

    /// Converts Responses `input_text` / `input_image` blocks into the
    /// chat-completions `text` / `image_url` content parts.
    static func chatContentParts(from blocks: [[String: Any]]) -> [[String: Any]] {
        blocks.compactMap { block in
            switch block["type"] as? String {
            case "input_text", "text":
                guard let text = block["text"] as? String else { return nil }
                return ["type": "text", "text": text]
            case "input_image", "image_url":
                let detail = (block["detail"] as? String) ?? "auto"
                if let url = block["image_url"] as? String {
                    return ["type": "image_url", "image_url": ["url": url, "detail": detail]]
                }
                if let nested = block["image_url"] as? [String: Any] {
                    return ["type": "image_url", "image_url": nested]
                }
                return nil
            default:
                return nil
            }
        }
    }

    /// Builds the opening chat-completions message array for an Ask AI turn.
    static func chatMessages(
        instructions: String,
        userContentBlocks: [[String: Any]]
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(["role": "user", "content": chatContentParts(from: userContentBlocks)])
        return messages
    }

    /// Builds the assistant message that records the tool calls the model made.
    static func assistantToolCallMessage(
        calls: [(callId: String, name: String, arguments: String)]
    ) -> [String: Any] {
        [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": calls.map { call in
                [
                    "id": call.callId,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ] as [String: Any]
            },
        ]
    }

    /// One `role:"tool"` message per executed call. Every call must get one,
    /// or the provider rejects the next round.
    static func toolResultMessages(
        outputs: [(callId: String, output: String)]
    ) -> [[String: Any]] {
        outputs.map { ["role": "tool", "tool_call_id": $0.callId, "content": $0.output] }
    }
}

/// Keeps the chat-completions message history of an Ask AI turn alive between
/// tool rounds, keyed by a synthetic response id handed back to the caller in
/// place of the Responses API's `previous_response_id`.
///
/// Bounded to the most recent turns so a long-running app can't accumulate
/// conversation state indefinitely.
final class ResponsesChatSessionStore {

    static let shared = ResponsesChatSessionStore()

    private let lock = NSLock()
    private var sessions: [String: [[String: Any]]] = [:]
    private var insertionOrder: [String] = []
    private let maxSessions: Int

    init(maxSessions: Int = 16) {
        self.maxSessions = maxSessions
    }

    /// Stores `messages` under a fresh synthetic id and returns that id.
    func store(_ messages: [[String: Any]]) -> String {
        let id = "chatcmpl-session-\(UUID().uuidString)"
        lock.lock()
        defer { lock.unlock() }
        sessions[id] = messages
        insertionOrder.append(id)
        while insertionOrder.count > maxSessions {
            let evicted = insertionOrder.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
        return id
    }

    /// Returns the stored history for `id`, or nil when it has been evicted.
    func messages(for id: String) -> [[String: Any]]? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id]
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
        insertionOrder.removeAll()
    }
}
