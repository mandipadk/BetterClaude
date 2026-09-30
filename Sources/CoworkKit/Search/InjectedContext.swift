import Foundation

/// Text that arrives as the person's turn but was written by a tool: Claude Code's task
/// notifications and command echoes, Codex's session goals and agent history. It isn't
/// something anyone typed, so it isn't a prompt, a correction, or the last thing asked.
public enum InjectedContext {
    static let openings = [
        // Claude Code
        "<task-notification>", "<command-name>", "<command-message>", "<command-args>", "<local-command-stdout>",
        "<local-command-stderr>", "<local-command-caveat>", "<bash-input>", "<bash-stdout>", "<bash-stderr>",
        "<system-reminder>", "<user-prompt-submit-hook>", "<teammate-message", "[Request interrupted by user",
        "Caveat: The messages below were generated",
        // Codex
        "<environment_context>", "<user_instructions>", "# AGENTS.md instructions", "<permissions", "<turn_aborted>",
        "Session goal:", "The following is the Codex agent history", "<subagent_notification>",
        // Files attached around a message
        "<uploaded_files>",
    ]

    public static func contains(_ text: String) -> Bool {
        let head = text.drop { $0.isWhitespace }.prefix(64)
        return openings.contains { head.hasPrefix($0) }
    }
}
