import Foundation

/// Text that arrives as the person's turn but was written by a tool: Claude Code's task
/// notifications and command echoes, Codex's session goals and agent history. It isn't
/// something anyone typed, so it isn't a prompt, a correction, or the last thing asked.
///
/// A turn is read block by block: a turn whose first block is a command echo can still
/// carry a typed second block, and a block can open with attached files before the prompt.
public enum InjectedContext {

    /// One piece of the person's turn, as a reader shows it.
    public enum Part: Sendable, Equatable {
        /// Something the person typed.
        case typed(String)
        /// A slash command they ran, with the slash, and whatever followed it.
        case command(name: String, arguments: String)
        /// A shell command they ran with `!`.
        case shell(String)
        /// They stopped the reply.
        case interrupted
        /// A background task or sub-agent reported back, with its own one-line summary.
        case notification(String?)
    }

    /// Elements a tool wrapped around its own output: nothing in them was typed.
    static let hiddenElements: Set<String> = [
        // Claude Code
        "system-reminder", "local-command-stdout", "local-command-stderr", "local-command-caveat",
        "bash-stdout", "bash-stderr", "user-prompt-submit-hook", "teammate-message", "command-message",
        // Codex
        "environment_context", "user_instructions", "permissions", "recommended_plugins", "skill",
        "codex_internal_context", "image",
        // Files attached around a message
        "uploaded_files",
    ]

    static let notificationElements: Set<String> = ["task-notification", "subagent_notification"]

    /// Wrappers around text the person did put there, such as a long paste.
    static let unwrappedElements: Set<String> = ["pasted_content"]

    static var knownElements: Set<String> {
        hiddenElements.union(notificationElements).union(unwrappedElements)
            .union(["command-name", "command-args", "bash-input", "turn_aborted"])
    }

    /// Openings that make a whole turn the tool's: everything after them belongs to it.
    static let wholeTurnOpenings = [
        "Caveat: The messages below were generated", "Session goal:", "The following is the Codex agent history",
    ]

    /// Openings that make one block the tool's.
    static let blockOpenings = ["# AGENTS.md instructions"]

    static let interruption = "[Request interrupted by user"

    /// Whether `text` holds nothing the person typed.
    public static func contains(_ text: String) -> Bool {
        typedText(parts(ofBlocks: [text])) == nil
    }

    /// The person's turn, from its text blocks in order.
    public static func parts(ofBlocks blocks: [String]) -> [Part] {
        for block in blocks {
            let head = block.drop { $0.isWhitespace }
            if wholeTurnOpenings.contains(where: { head.hasPrefix($0) }) { return [] }
        }
        var parts: [Part] = []
        for block in blocks {
            for part in self.parts(ofBlock: block) {
                if case .typed(let text) = part, case .typed(let earlier)? = parts.last {
                    parts[parts.count - 1] = .typed(earlier + "\n" + text)
                } else {
                    parts.append(part)
                }
            }
        }
        return parts
    }

    /// What the person typed, or nil when nothing was.
    public static func typedText(_ parts: [Part]) -> String? {
        let typed = parts.compactMap { part -> String? in
            if case .typed(let text) = part { return text }
            return nil
        }
        return typed.isEmpty ? nil : typed.joined(separator: "\n")
    }

    static func parts(ofBlock block: String) -> [Part] {
        var rest = Substring(block)
        if blockOpenings.contains(where: { rest.drop { $0.isWhitespace }.hasPrefix($0) }) { return [] }
        var parts: [Part] = []
        var commandName: String?
        var commandArguments = ""

        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.hasPrefix(interruption) {
                parts.append(.interrupted)
                rest = rest.firstIndex(of: "]").map { rest[rest.index(after: $0)...] } ?? ""
                continue
            }
            // A closing tag left on its own, as Codex writes around an attached image.
            if rest.hasPrefix("</"), let end = rest.firstIndex(of: ">"),
               knownElements.contains(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end])) {
                rest = rest[rest.index(after: end)...]
                continue
            }
            guard let (name, contentStart) = openingTag(rest), knownElements.contains(name) else { break }
            let inner: Substring
            if let close = rest.range(of: "</\(name)>", range: contentStart..<rest.endIndex) {
                inner = rest[contentStart..<close.lowerBound]
                rest = rest[close.upperBound...]
            } else {
                inner = rest[contentStart...]
                rest = ""
            }
            let content = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "command-name": commandName = content
            case "command-args": commandArguments = content
            case "bash-input": parts.append(.shell(content))
            case "turn_aborted": parts.append(.interrupted)
            case _ where notificationElements.contains(name):
                parts.append(.notification(element("summary", in: content)))
            case _ where unwrappedElements.contains(name):
                if !content.isEmpty { parts.append(.typed(content)) }
            default:
                break
            }
        }
        if let commandName {
            let name = commandName.hasPrefix("/") ? commandName : "/" + commandName
            parts.append(.command(name: name, arguments: commandArguments))
        }
        let typed = removingElement("system-reminder", from: String(rest))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(.typed(typed)) }
        return parts
    }

    /// `<name …>` at the start of `text`: the name and where its content starts.
    static func openingTag(_ text: Substring) -> (String, Substring.Index)? {
        guard text.first == "<" else { return nil }
        let nameStart = text.index(after: text.startIndex)
        let name = text[nameStart...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard let first = name.first, first.isLetter, name.endIndex < text.endIndex else { return nil }
        let after = text[name.endIndex]
        guard after == ">" || after.isWhitespace, let close = text[name.endIndex...].firstIndex(of: ">") else { return nil }
        return (String(name), text.index(after: close))
    }

    static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func removingElement(_ name: String, from text: String) -> String {
        var text = text
        while let open = text.range(of: "<\(name)>") {
            guard let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else {
                text.removeSubrange(open.lowerBound...)
                break
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return text
    }
}
