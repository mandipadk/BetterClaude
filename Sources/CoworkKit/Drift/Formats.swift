import Foundation

extension FormatContract {

    static let number: Set<String> = ["int", "number"]
    static let text: Set<String> = ["string"]
    static let textOrNull: Set<String> = ["string", "null"]

    /// Claude Code's transcripts: the command line, the Code tab and Cowork all write these.
    public static let claudeCode = FormatContract(
        format: "claude-code",
        name: "Claude Code",
        kindOf: { record in
            guard let type = record["type"]?.stringValue, FormatShape.isNameValue(type) else { return nil }
            switch type {
            case "system":
                return "system/" + (record["subtype"]?.stringValue.flatMap { FormatShape.isNameValue($0) ? $0 : nil } ?? "*")
            case "attachment":
                return "attachment/" + (record["attachment"]?["type"]?.stringValue.flatMap { FormatShape.isNameValue($0) ? $0 : nil } ?? "*")
            default:
                return type
            }
        },
        versionOf: { $0["version"]?.stringValue.flatMap { FormatShape.isNameValue($0) ? $0 : nil } },
        valuePaths: ["userType", "entrypoint", "level", "message.role", "message.type", "message.model", "message.stop_reason"],
        opaque: ["toolUseResult", "mcpMeta", "message.content[tool_result].content", "message.content[tool_use].input.*",
                 "attachment.content", "attachment.hookSpecificOutput", "wireToolInputs", "wireIngestContext"],
        maps: ["snapshot.trackedFileBackups", "modelUsage"],
        onlyFields: ["message.content[tool_use].input": ["file_path", "notebook_path", "command"]],
        typedArrays: ["message.content"],
        maxDepth: 5,
        requirements: [
            // Reading and searching every conversation.
            Requirement(kinds: ["user", "assistant"], path: "message", types: ["object"], feature: "messages"),
            Requirement(kinds: ["user", "assistant"], path: "message.content", types: ["string", "array"], feature: "messages"),
            Requirement(kinds: ["user", "assistant"], path: "message.content[text].text", types: text, feature: "messages"),
            Requirement(kinds: ["user", "assistant"], path: "uuid", types: text, feature: "messages and forking"),
            Requirement(kinds: ["user", "assistant"], path: "parentUuid", types: textOrNull, feature: "continuing and forking"),
            Requirement(kinds: ["user", "assistant"], path: "sessionId", types: text, feature: "continuing and forking"),
            Requirement(kinds: ["user", "assistant"], path: "timestamp", types: text, feature: "dates"),
            Requirement(kinds: ["user", "assistant"], path: "cwd", types: text, feature: "projects"),
            Requirement(kinds: ["user", "assistant"], path: "isMeta", types: ["bool"], feature: "messages", optional: true),
            Requirement(kinds: ["user"], path: "isCompactSummary", types: ["bool"], feature: "compaction summaries", optional: true),
            Requirement(kinds: ["ai-title"], path: "aiTitle", types: text, feature: "titles"),
            Requirement(kinds: ["custom-title"], path: "customTitle", types: text, feature: "titles"),
            Requirement(kinds: ["system/away_summary"], path: "content", types: text, feature: "recaps"),
            Requirement(kinds: ["system/compact_boundary"], path: "compactMetadata", types: ["object"], feature: "compaction markers"),
            Requirement(kinds: ["system/compact_boundary"], path: "compactMetadata.preTokens", types: number, feature: "compaction markers", optional: true),
            // Usage and limits.
            Requirement(kinds: ["assistant"], path: "message.id", types: text, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.model", types: text, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage", types: ["object"], feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage.input_tokens", types: number, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage.output_tokens", types: number, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage.cache_read_input_tokens", types: number, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage.cache_creation_input_tokens", types: number, feature: "token usage"),
            Requirement(kinds: ["assistant"], path: "message.usage.cache_creation.ephemeral_1h_input_tokens", types: number,
                        feature: "token usage", optional: true),
            Requirement(kinds: ["cost-state"], path: "totalCostUSD", types: number, feature: "Claude Code's own cost"),
            Requirement(kinds: ["cost-state"], path: "totalLinesAdded", types: number, feature: "Claude Code's own cost"),
            // Tools, commands and files.
            Requirement(kinds: ["assistant"], path: "message.content[tool_use].name", types: text, feature: "tools and commands"),
            Requirement(kinds: ["assistant"], path: "message.content[tool_use].input", types: ["object"], feature: "tools and commands"),
            Requirement(kinds: ["assistant"], path: "message.content[tool_use].input.file_path", types: text, feature: "files Claude changed", optional: true),
            Requirement(kinds: ["assistant"], path: "message.content[tool_use].input.command", types: text, feature: "commands you could allow", optional: true),
            Requirement(kinds: ["file-history-snapshot"], path: "snapshot.trackedFileBackups", types: ["object"], feature: "file versions"),
            Requirement(kinds: ["file-history-snapshot"], path: "snapshot.trackedFileBackups.*.version", types: number, feature: "file versions"),
            Requirement(kinds: ["file-history-snapshot"], path: "snapshot.trackedFileBackups.*.backupFileName", types: textOrNull, feature: "file versions"),
            Requirement(kinds: ["file-history-snapshot"], path: "snapshot.trackedFileBackups.*.backupTime", types: text, feature: "file versions"),
            Requirement(kinds: ["file-history-delta"], path: "trackingPath", types: text, feature: "file versions"),
            Requirement(kinds: ["file-history-delta"], path: "backup.version", types: number, feature: "file versions"),
            Requirement(kinds: ["file-history-delta"], path: "backup.backupFileName", types: textOrNull, feature: "file versions"),
            Requirement(kinds: ["file-history-delta"], path: "backup.backupTime", types: text, feature: "file versions"),
            // What needs attention.
            Requirement(kinds: ["attachment/deferred_tools_delta"], path: "attachment.failedMcpServers", types: ["array"],
                        feature: "MCP servers that failed", optional: true),
            Requirement(kinds: ["attachment/deferred_tools_delta"], path: "attachment.failedMcpServers[].name", types: text,
                        feature: "MCP servers that failed"),
            Requirement(kinds: ["attachment/deferred_tools_delta"], path: "attachment.needsAuthMcpServers", types: ["array"],
                        feature: "MCP servers that need signing in", optional: true),
            Requirement(kinds: ["attachment/hook_non_blocking_error"], path: "attachment.hookEvent", types: text, feature: "hooks that failed"),
            Requirement(kinds: ["attachment/hook_non_blocking_error"], path: "attachment.exitCode", types: number, feature: "hooks that failed", optional: true),
        ],
        known: [
            // Read.
            "user", "assistant", "ai-title", "custom-title", "system/away_summary", "system/compact_boundary",
            "cost-state", "file-history-snapshot", "file-history-delta", "attachment/deferred_tools_delta",
            "attachment/hook_non_blocking_error",
            // Looked at, and not needed: Claude Code's own bookkeeping, reminders it gives itself,
            // and context it adds to a turn.
            "summary", "last-prompt", "mode", "permission-mode", "agent-name", "queue-operation", "atis-latch",
            "frame-link", "pr-link", "continued-in", "branched-from", "bridge-session", "history-suppression",
            "artifact-autoreact-ledger", "artifact-comment-monitor", "progress",
            "system/stop_hook_summary", "system/turn_duration", "system/local_command", "system/informational",
            "system/api_error", "system/model_refusal_fallback", "system/bridge_status",
            "attachment/total_tokens_reminder", "attachment/batching_reminder_sent", "attachment/bash_output_audience_note",
            "attachment/hook_success", "attachment/edited_text_file", "attachment/queued_command",
            "attachment/deferred_tools_record", "attachment/task_reminder", "attachment/silent_turn_reminder",
            "attachment/environment", "attachment/command_permissions", "attachment/skill_listing", "attachment/file",
            "attachment/prompt_snapshot", "attachment/todo_reminder", "attachment/mcp_instructions_delta",
            "attachment/date", "attachment/instructions", "attachment/agent_listing_delta", "attachment/date_change",
            "attachment/auto_mode", "attachment/compact_file_reference", "attachment/model", "attachment/session_context",
            "attachment/hook_additional_context", "attachment/task_status", "attachment/invoked_skills",
            "attachment/thinking_drop", "attachment/thinking_stripped", "attachment/credential_org",
            "attachment/remote_session_change", "attachment/ultra_effort_enter", "attachment/ultra_effort_exit",
            "attachment/plan_file_reference", "attachment/hook_system_message", "attachment/hook_cancelled",
            "attachment/companion_intro", "attachment/nested_memory", "attachment/plan_mode", "attachment/plan_mode_exit",
            "attachment/directory", "attachment/workflow_keyword_request", "attachment/read_truncation_notice",
            "attachment/dynamic_skill",
        ],
        modelPath: "message.model")

    /// Codex's session files, read for the timeline and search.
    public static let codex = FormatContract(
        format: "codex",
        name: "Codex",
        kindOf: { record in
            guard let type = record["type"]?.stringValue, FormatShape.isNameValue(type) else { return nil }
            guard let sub = record["payload"]?["type"]?.stringValue else { return type }
            return type + "/" + (FormatShape.isNameValue(sub) ? sub : "*")
        },
        versionOf: { record in
            guard record["type"]?.stringValue == "session_meta" else { return nil }
            return record["payload"]?["cli_version"]?.stringValue.flatMap { FormatShape.isNameValue($0) ? $0 : nil }
        },
        valuePaths: ["payload.role"],
        opaque: ["payload.arguments", "payload.input", "payload.output", "payload.base_instructions", "payload.instructions",
                 "payload.user_instructions", "payload.developer_instructions", "payload.summary", "payload.encrypted_content",
                 "payload.info", "payload.rate_limits"],
        maps: [],
        onlyFields: [:],
        typedArrays: ["payload.content"],
        maxDepth: 4,
        requirements: [
            Requirement(kinds: ["session_meta"], path: "payload.id", types: text, feature: "Codex conversations"),
            Requirement(kinds: ["session_meta"], path: "payload.cwd", types: text, feature: "Codex projects"),
            Requirement(kinds: ["session_meta"], path: "timestamp", types: text, feature: "dates"),
            Requirement(kinds: ["response_item/message"], path: "payload.role", types: text, feature: "Codex messages"),
            Requirement(kinds: ["response_item/message"], path: "payload.content", types: ["array"], feature: "Codex messages"),
            Requirement(kinds: ["response_item/message"], path: "payload.content[input_text].text", types: text, feature: "Codex messages"),
            Requirement(kinds: ["response_item/message"], path: "payload.content[output_text].text", types: text, feature: "Codex messages"),
            Requirement(kinds: ["response_item/function_call", "response_item/custom_tool_call"], path: "payload.name",
                        types: text, feature: "Codex tools"),
            Requirement(kinds: ["turn_context"], path: "payload.model", types: text, feature: "Codex models"),
        ],
        known: [
            // Read.
            "session_meta", "turn_context", "response_item/message", "response_item/function_call",
            "response_item/custom_tool_call",
            // Looked at, and not needed: tool output, reasoning, messages between Codex's own
            // agents (encrypted), and its bookkeeping.
            "compacted", "response_item/compaction", "response_item/agent_message", "inter_agent_communication_metadata",
            "response_item/custom_tool_call_output", "response_item/function_call_output", "response_item/reasoning",
            "response_item/image_generation_call", "response_item/tool_search_call", "response_item/tool_search_output",
            "response_item/web_search_call", "event_msg/item_completed", "event_msg/task_complete", "event_msg/task_started",
            "event_msg/thread_goal_updated", "event_msg/thread_settings_applied", "event_msg/token_count",
            "event_msg/turn_aborted", "token_usage_record", "world_state",
        ],
        modelPath: nil)
}
