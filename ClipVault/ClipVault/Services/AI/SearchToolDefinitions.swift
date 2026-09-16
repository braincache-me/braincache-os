import Foundation

/// Defines the OpenAI function-calling tool schemas for the agentic RAG pipeline.
///
/// Each tool maps to a `ClipStore` or `VectorSearchEngine` method. The LLM can invoke
/// these tools across multiple iterations to refine its retrieval strategy before
/// composing a final answer. Tool definitions conform to the OpenAI `tools` API format.
///
/// Tool and parameter description strings live in `Prompts.json` under `searchTools.*`.
/// The structural schema (types, `required` arrays, enum values) stays in Swift because
/// it must match the API contract and the dispatch code in `AgenticRAGEngine`.
struct SearchToolDefinitions {

    /// All tool definitions — pass directly as the `tools` parameter in a chat completion.
    static var allTools: [[String: Any]] {
        [searchByKeyword, searchBySemantic, filterByApp,
         filterByDateRange, filterByTags, filterByContentType]
    }

    /// Canonical tool name set — used to validate incoming tool_call dispatch.
    static let toolNames: Set<String> = [
        "search_by_keyword",
        "search_by_semantic",
        "filter_by_app",
        "filter_by_date_range",
        "filter_by_tags",
        "filter_by_content_type"
    ]

    // MARK: - Individual Tool Schemas

    static var searchByKeyword: [String: Any] {
        let prompts = Prompts.shared.searchTools.searchByKeyword
        return [
            "type": "function",
            "function": [
                "name": "search_by_keyword",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": prompts.parameters["query"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static var searchBySemantic: [String: Any] {
        let prompts = Prompts.shared.searchTools.searchBySemantic
        return [
            "type": "function",
            "function": [
                "name": "search_by_semantic",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": prompts.parameters["query"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static var filterByApp: [String: Any] {
        let prompts = Prompts.shared.searchTools.filterByApp
        return [
            "type": "function",
            "function": [
                "name": "filter_by_app",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app_name": [
                            "type": "string",
                            "description": prompts.parameters["app_name"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["app_name"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static var filterByDateRange: [String: Any] {
        let prompts = Prompts.shared.searchTools.filterByDateRange
        return [
            "type": "function",
            "function": [
                "name": "filter_by_date_range",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "start_date": [
                            "type": "string",
                            "description": prompts.parameters["start_date"] ?? ""
                        ] as [String: Any],
                        "end_date": [
                            "type": "string",
                            "description": prompts.parameters["end_date"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["start_date", "end_date"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static var filterByTags: [String: Any] {
        let prompts = Prompts.shared.searchTools.filterByTags
        return [
            "type": "function",
            "function": [
                "name": "filter_by_tags",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"] as [String: Any],
                            "description": prompts.parameters["tags"] ?? ""
                        ] as [String: Any],
                        "match_all": [
                            "type": "boolean",
                            "description": prompts.parameters["match_all"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["tags"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    static var filterByContentType: [String: Any] {
        let prompts = Prompts.shared.searchTools.filterByContentType
        return [
            "type": "function",
            "function": [
                "name": "filter_by_content_type",
                "description": prompts.description,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "content_type": [
                            "type": "string",
                            "enum": ["text", "image", "html", "rtf", "file"],
                            "description": prompts.parameters["content_type"] ?? ""
                        ] as [String: Any],
                        "limit": [
                            "type": "integer",
                            "description": prompts.parameters["limit"] ?? ""
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["content_type"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }
}
