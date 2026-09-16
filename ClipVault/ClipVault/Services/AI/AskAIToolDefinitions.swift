import Foundation

/// Tool schemas for Ask AI's Responses API requests, assembled from the
/// per-tool Preferences flags.
///
/// Note the schema shape differs from `SearchToolDefinitions` (Chat
/// Completions): the Responses API takes flat function entries —
/// `{"type": "function", "name": ..., "parameters": ...}` without the nested
/// `"function"` wrapper — and hosted tools like `{"type": "web_search"}`.
/// Description strings live in `Prompts.json` under `askAI.*`.
struct AskAIToolDefinitions {

    static let claudeCodeHistoryToolName = "search_claude_code_history"
    static let codexHistoryToolName = "search_codex_history"
    static let askClaudeCodeToolName = "ask_claude_code"
    static let askCodexToolName = "ask_codex"

    /// OpenAI's hosted web search — executed server-side, no local dispatch.
    static var webSearchTool: [String: Any] {
        ["type": "web_search"]
    }

    static var claudeCodeHistoryTool: [String: Any] {
        historyTool(
            name: claudeCodeHistoryToolName,
            entry: Prompts.shared.askAI.tools.claudeCodeHistory
        )
    }

    static var codexHistoryTool: [String: Any] {
        historyTool(
            name: codexHistoryToolName,
            entry: Prompts.shared.askAI.tools.codexHistory
        )
    }

    static var askClaudeCodeTool: [String: Any] {
        askAgentTool(
            name: askClaudeCodeToolName,
            entry: Prompts.shared.askAI.tools.askClaudeCode
        )
    }

    static var askCodexTool: [String: Any] {
        askAgentTool(
            name: askCodexToolName,
            entry: Prompts.shared.askAI.tools.askCodex
        )
    }

    /// Schema for the CLI-bridge tools: put a question straight to the local
    /// coding agent (`claude -p --continue` / `codex exec resume --last`).
    private static func askAgentTool(
        name: String,
        entry: Prompts.SearchTools.ToolEntry
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": entry.description,
            "parameters": [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "description": entry.parameters["question"] ?? ""
                    ] as [String: Any],
                    "project_path": [
                        "type": "string",
                        "description": entry.parameters["project_path"] ?? ""
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["question"]
            ] as [String: Any]
        ]
    }

    private static func historyTool(
        name: String,
        entry: Prompts.SearchTools.ToolEntry
    ) -> [String: Any] {
        [
            "type": "function",
            "name": name,
            "description": entry.description,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": entry.parameters["query"] ?? ""
                    ] as [String: Any],
                    "limit": [
                        "type": "integer",
                        "description": entry.parameters["limit"] ?? ""
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["query"]
            ] as [String: Any]
        ]
    }

    /// The `tools` array for an Ask AI request given the Preferences flags.
    static func tools(
        webSearch: Bool,
        claudeCodeHistory: Bool,
        codexHistory: Bool
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if webSearch { result.append(webSearchTool) }
        if claudeCodeHistory {
            result.append(claudeCodeHistoryTool)
            result.append(askClaudeCodeTool)
        }
        if codexHistory {
            result.append(codexHistoryTool)
            result.append(askCodexTool)
        }
        return result
    }

    /// Guidance appended to the Ask AI system prompt so the model knows when
    /// each enabled tool is worth calling.
    static func systemPromptAddendum(
        webSearch: Bool,
        claudeCodeHistory: Bool,
        codexHistory: Bool
    ) -> String {
        var parts: [String] = []
        if webSearch {
            parts.append(Prompts.shared.askAI.webSearchGuidance)
        }
        if claudeCodeHistory || codexHistory {
            parts.append(Prompts.shared.askAI.agentHistoryGuidance)
        }
        guard !parts.isEmpty else { return "" }
        return "\n\n" + parts.joined(separator: "\n\n")
    }
}

/// Dispatches Ask AI function calls to their local implementations and
/// formats the plain-text result the model receives.
struct AskAIToolExecutor {

    /// Human-readable one-liner describing a call, shown in the thinking
    /// trace so users can see what the assistant looked up.
    static func activitySummary(name: String, argumentsJSON: String) -> String {
        switch name {
        case AskAIToolDefinitions.claudeCodeHistoryToolName:
            return "Searched Claude Code history for \"\(queryArgument(from: argumentsJSON) ?? "…")\""
        case AskAIToolDefinitions.codexHistoryToolName:
            return "Searched Codex history for \"\(queryArgument(from: argumentsJSON) ?? "…")\""
        case AskAIToolDefinitions.askClaudeCodeToolName:
            return "Asked Claude Code: \"\(questionArgument(from: argumentsJSON) ?? "…")\""
        case AskAIToolDefinitions.askCodexToolName:
            return "Asked Codex: \"\(questionArgument(from: argumentsJSON) ?? "…")\""
        default:
            return "Called \(name)"
        }
    }

    /// Status-label line shown while the call runs.
    static func statusDetail(name: String) -> String {
        switch name {
        case AskAIToolDefinitions.askClaudeCodeToolName:
            return "Asking Claude Code…"
        case AskAIToolDefinitions.askCodexToolName:
            return "Asking Codex…"
        default:
            return "Searching agent history…"
        }
    }

    static func execute(
        name: String,
        argumentsJSON: String,
        historyService: AgentHistorySearchService,
        cliBridge: AgentCLIBridge = AgentCLIBridge()
    ) -> String {
        switch name {
        case AskAIToolDefinitions.claudeCodeHistoryToolName:
            guard let query = queryArgument(from: argumentsJSON), !query.isEmpty else {
                return "Error: missing required \"query\" argument."
            }
            let matches = historyService.search(
                source: .claudeCode, query: query, limit: limitArgument(from: argumentsJSON) ?? 10
            )
            return AgentHistorySearchService.formatResults(
                matches, query: query, sourceLabel: "Claude Code CLI history (~/.claude)"
            )
        case AskAIToolDefinitions.codexHistoryToolName:
            guard let query = queryArgument(from: argumentsJSON), !query.isEmpty else {
                return "Error: missing required \"query\" argument."
            }
            let matches = historyService.search(
                source: .codex, query: query, limit: limitArgument(from: argumentsJSON) ?? 10
            )
            return AgentHistorySearchService.formatResults(
                matches, query: query, sourceLabel: "Codex CLI history (~/.codex)"
            )
        case AskAIToolDefinitions.askClaudeCodeToolName:
            guard let question = questionArgument(from: argumentsJSON), !question.isEmpty else {
                return "Error: missing required \"question\" argument."
            }
            return cliBridge.ask(
                agent: .claude, question: question,
                projectPath: projectPathArgument(from: argumentsJSON)
            )
        case AskAIToolDefinitions.askCodexToolName:
            guard let question = questionArgument(from: argumentsJSON), !question.isEmpty else {
                return "Error: missing required \"question\" argument."
            }
            return cliBridge.ask(
                agent: .codex, question: question,
                projectPath: projectPathArgument(from: argumentsJSON)
            )
        default:
            return "Error: unknown tool \"\(name)\"."
        }
    }

    private static func arguments(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func queryArgument(from json: String) -> String? {
        (arguments(from: json)?["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limitArgument(from json: String) -> Int? {
        arguments(from: json)?["limit"] as? Int
    }

    private static func questionArgument(from json: String) -> String? {
        (arguments(from: json)?["question"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func projectPathArgument(from json: String) -> String? {
        (arguments(from: json)?["project_path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
