import Foundation

/// A conversation as one self-contained web page, to send to someone: no scripts, nothing
/// loaded from elsewhere, keys and tokens hidden, and the home folder shortened to `~`.
public enum ConversationPage {

    public static func render(_ conversation: ReadableConversation, title: String, model: String?,
                              home: String, assistantName: String = "Claude", exported: Date = Date()) -> String {
        func clean(_ text: String) -> String {
            let redacted = SecretSweep.redact(text)
            return home.count > 1 ? redacted.replacingOccurrences(of: home, with: "~") : redacted
        }
        var body = ""
        for entry in conversation.entries {
            switch entry {
            case .message(let message):
                let who = message.role == .user ? "You" : message.role == .assistant ? escape(assistantName) : "Note"
                let stamp = message.timestamp.map { " <time>\(escape($0.formatted(date: .abbreviated, time: .shortened)))</time>" } ?? ""
                let attached = message.attachments.map { "<p class=\"attachment\">\(escape(clean($0)))</p>" }.joined()
                body += "<section class=\"message \(message.role == .user ? "you" : "claude")\">"
                body += "<h2>\(who)\(stamp)</h2>\(markdown(clean(message.text)))\(attached)</section>\n"
            case .tools(_, let names):
                let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                body += "<p class=\"tools\">Used \(names.count) tool\(names.count == 1 ? "" : "s"): \(escape(unique.joined(separator: ", ")))</p>\n"
            case .compaction(let compaction):
                body += "<details class=\"compaction\"><summary>Earlier messages were summarized here</summary>"
                if let summary = compaction.summary { body += markdown(clean(summary)) }
                body += "</details>\n"
            case .recap(_, let text, _):
                body += "<p class=\"recap\"><strong>\(escape(assistantName))'s recap.</strong> \(inline(escape(clean(text))))</p>\n"
            case .notice(let notice):
                body += "<p class=\"tools\">\(escape(clean(notice.text)))</p>\n"
            }
        }
        var facts: [String] = []
        if let model { facts.append("<div><dt>Model</dt><dd>\(escape(model))</dd></div>") }
        if let first = conversation.firstTimestamp {
            facts.append("<div><dt>Started</dt><dd>\(escape(first.formatted(date: .long, time: .shortened)))</dd></div>")
        }
        facts.append("<div><dt>Messages</dt><dd>\(conversation.messageCount)</dd></div>")
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escape(clean(title)))</title>
        <style>
        :root{--ground:#f6f7f6;--surface:#fff;--ink:#141816;--muted:#58615c;--rule:#dfe4e0;--fill:#ebefec;--accent:#0b7d59;color-scheme:light}
        @media (prefers-color-scheme:dark){:root{--ground:#111412;--surface:#191d1b;--ink:#e7ece9;--muted:#9ca59f;--rule:#29302c;--fill:#212724;--accent:#2eb27e;color-scheme:dark}}
        *{box-sizing:border-box}body{margin:0;background:var(--ground);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Helvetica Neue",system-ui,sans-serif;padding:48px 16px 80px}
        main{max-width:760px;margin:0 auto}h1{font-size:32px;line-height:1.15;letter-spacing:-.02em;margin:0 0 16px}
        dl{display:flex;flex-wrap:wrap;gap:8px 28px;margin:0 0 36px;padding:0 0 20px;border-bottom:1px solid var(--rule)}dl div{min-width:0}
        dt{font-size:12px;color:var(--muted)}dd{margin:0;font-size:14px;font-variant-numeric:tabular-nums}
        .message{margin:0 0 28px}.message h2{font-size:14px;font-weight:600;margin:0 0 6px}.message h2 time{font-weight:400;color:var(--muted);margin-left:6px}
        .you>:not(h2){background:var(--fill);border-radius:10px;padding:10px 14px;margin:0 0 8px}
        p{margin:0 0 12px}h3,h4{margin:18px 0 8px;font-size:16px}ul,ol{margin:0 0 12px;padding-left:22px}
        pre{background:var(--surface);border:1px solid var(--rule);border-radius:10px;padding:12px 14px;overflow-x:auto;font:13px/1.5 ui-monospace,"SF Mono",Menlo,monospace}
        code{font:.9em ui-monospace,"SF Mono",Menlo,monospace;background:var(--fill);padding:.05em .3em;border-radius:4px}pre code{background:none;padding:0}
        a{color:var(--accent)}.tools,.recap{color:var(--muted);font-size:14px}
        .compaction{border:1px dashed var(--rule);border-radius:10px;padding:10px 14px;margin:0 0 28px;color:var(--muted)}summary{cursor:pointer}
        footer{margin-top:48px;padding-top:16px;border-top:1px solid var(--rule);color:var(--muted);font-size:13px}
        </style></head><body><main>
        <h1>\(escape(clean(title)))</h1>
        <dl>\(facts.joined())</dl>
        \(body)<footer>Exported from Better Claude on \(escape(exported.formatted(date: .long, time: .omitted))). Keys and tokens are hidden, and home folder paths are shortened to ~.</footer>
        </main></body></html>
        """
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Enough Markdown for conversations: fenced code, headings, lists, tables as text,
    /// paragraphs, and inline code, bold and links.
    static func markdown(_ text: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var list: (ordered: Bool, items: [String])?
        var code: [String]?
        func flushParagraph() {
            if !paragraph.isEmpty { html += "<p>\(paragraph.map { inline(escape($0)) }.joined(separator: "<br>"))</p>" }
            paragraph = []
        }
        func flushList() {
            if let current = list {
                let tag = current.ordered ? "ol" : "ul"
                html += "<\(tag)>" + current.items.map { "<li>\(inline(escape($0)))</li>" }.joined() + "</\(tag)>"
            }
            list = nil
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    html += "<pre><code>\(escape(code!.joined(separator: "\n")))</code></pre>"
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("```") { flushParagraph(); flushList(); code = []; continue }
            if trimmed.isEmpty { flushParagraph(); flushList(); continue }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"),
               trimmed[hashes] == " ", trimmed.distance(from: trimmed.startIndex, to: hashes) <= 6 {
                flushParagraph(); flushList()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes) <= 2 ? "h3" : "h4"
                html += "<\(level)>\(inline(escape(String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces))))</\(level)>"
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                if list?.ordered == true { flushList() }
                list = (false, (list?.items ?? []) + [String(trimmed.dropFirst(2))])
                continue
            }
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber), !trimmed[..<dot].isEmpty,
               trimmed[trimmed.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                if list?.ordered == false { flushList() }
                list = (true, (list?.items ?? []) + [String(trimmed[trimmed.index(dot, offsetBy: 2)...])])
                continue
            }
            flushList()
            paragraph.append(line)
        }
        if let code { html += "<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>" }
        flushParagraph()
        flushList()
        return html
    }

    /// Inline code, bold, and web links, on already-escaped text.
    static func inline(_ escaped: String) -> String {
        var text = escaped
        text = text.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\((https?://[^\s)&]+)\)"#, with: "<a href=\"$2\">$1</a>",
                                         options: .regularExpression)
        return text
    }
}
