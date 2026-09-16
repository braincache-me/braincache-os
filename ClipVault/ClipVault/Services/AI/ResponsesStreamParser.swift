import Foundation

/// Token usage reported by a `response.completed` event.
struct ResponsesUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
}

/// One semantic event decoded from an OpenAI Responses API SSE stream.
///
/// The Responses API (unlike Chat Completions) streams typed events — each
/// `data:` line carries a JSON object with a `type` field. Ask AI consumes
/// the subset below; everything else (`response.in_progress`,
/// `response.output_item.added` for message items, part boundaries, …) is
/// intentionally ignored by the parser and skipped by the stream.
enum ResponsesStreamEvent: Equatable {
    /// `response.reasoning_summary_text.delta` — a chunk of the model's
    /// thinking-trace summary (requires `reasoning.summary` in the request).
    case reasoningDelta(String)
    /// `response.output_text.delta` — a chunk of the visible answer.
    case textDelta(String)
    /// A `web_search_call` output item appeared — the model is running the
    /// built-in web search tool server-side.
    case webSearchStarted
    /// `response.output_item.done` for a `function_call` item — the model
    /// wants a local tool executed. Arguments arrive as a JSON string.
    case functionCall(callId: String, name: String, arguments: String)
    /// `response.completed` — carries the response id (needed to continue
    /// the conversation via `previous_response_id`) and final token usage.
    case completed(responseId: String, usage: ResponsesUsage?)
    /// `response.failed` or an `error` event.
    case failed(message: String)
}

/// Stateless mapping from a decoded SSE JSON payload to a stream event.
/// Kept separate from `OpenAIClient` so it can be unit-tested without
/// network plumbing.
struct ResponsesStreamParser {

    static func event(from json: [String: Any]) -> ResponsesStreamEvent? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "response.reasoning_summary_text.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return nil }
            return .reasoningDelta(delta)

        case "response.output_text.delta":
            guard let delta = json["delta"] as? String, !delta.isEmpty else { return nil }
            return .textDelta(delta)

        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any],
                  (item["type"] as? String) == "web_search_call" else { return nil }
            return .webSearchStarted

        case "response.output_item.done":
            guard let item = json["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call",
                  let callId = item["call_id"] as? String,
                  let name = item["name"] as? String else { return nil }
            return .functionCall(
                callId: callId,
                name: name,
                arguments: (item["arguments"] as? String) ?? "{}"
            )

        case "response.completed":
            guard let response = json["response"] as? [String: Any],
                  let id = response["id"] as? String else { return nil }
            var usage: ResponsesUsage?
            if let u = response["usage"] as? [String: Any] {
                let cached = ((u["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
                usage = ResponsesUsage(
                    inputTokens: (u["input_tokens"] as? Int) ?? 0,
                    outputTokens: (u["output_tokens"] as? Int) ?? 0,
                    cachedInputTokens: cached
                )
            }
            return .completed(responseId: id, usage: usage)

        case "response.failed":
            let message = (((json["response"] as? [String: Any])?["error"] as? [String: Any])?["message"] as? String)
                ?? "response failed"
            return .failed(message: message)

        case "error":
            return .failed(message: (json["message"] as? String) ?? "stream error")

        default:
            return nil
        }
    }
}
