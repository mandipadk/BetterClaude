import SwiftUI

/// The Markdown Claude writes, as blocks: enough of the language to read a conversation
/// comfortably — headings, lists, quotes, tables and code — and inline styling inside each.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]
        var paragraph: [String] = []

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                lines.removeFirst()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                    lines.removeFirst()
                }
                if !lines.isEmpty { lines.removeFirst() }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    text: code.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                lines.removeFirst()
                continue
            }

            if let heading = Self.heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                lines.removeFirst()
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                blocks.append(.rule)
                lines.removeFirst()
                continue
            }

            if trimmed.hasPrefix("|"), lines.count > 1,
               let separator = lines.dropFirst().first?.trimmingCharacters(in: .whitespaces),
               separator.hasPrefix("|"), separator.contains("-") {
                flushParagraph()
                let header = Self.cells(trimmed)
                lines.removeFirst(2)
                var rows: [[String]] = []
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|") {
                    rows.append(Self.cells(next))
                    lines.removeFirst()
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if Self.bulletText(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), let item = Self.bulletText(next) {
                    items.append(item)
                    lines.removeFirst()
                }
                blocks.append(.bullets(items))
                continue
            }

            if let (start, _) = Self.numbered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), let (_, item) = Self.numbered(next) {
                    items.append(item)
                    lines.removeFirst()
                }
                blocks.append(.numbered(start: start, items: items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
                    quoted.append(String(next.dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines.removeFirst()
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            lines.removeFirst()
        }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...4).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(line.dropFirst(hashes + 1)))
    }

    private static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (number, String(rest.dropFirst(2)))
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// Renders Markdown blocks in the reading type.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownBlock.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 18 : level == 2 ? 16 : 14, weight: .semibold))
                .padding(.top, 4)
        case .paragraph(let text):
            inline(text).font(Theme.Font.reading).lineSpacing(3)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item).lineSpacing(3)
                    }
                }
            }
            .font(Theme.Font.reading)
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + index).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 18, alignment: .trailing)
                        inline(item).lineSpacing(3)
                    }
                }
            }
            .font(Theme.Font.reading)
        case .quote(let text):
            inline(text)
                .font(Theme.Font.reading)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.hairline).frame(width: 3)
                }
        case .code(let language, let text):
            CodeWell(language: language, text: text)
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }
}

/// Code in a contained well — the one place monospaced type appears.
struct CodeWell: View {
    let language: String?
    let text: String
    @State private var copied = false

    static func languageName(_ tag: String?) -> String {
        guard let tag = tag?.lowercased(), !tag.isEmpty else { return "Code" }
        let names = ["ts": "TypeScript", "typescript": "TypeScript", "tsx": "TypeScript",
                     "js": "JavaScript", "javascript": "JavaScript", "jsx": "JavaScript",
                     "py": "Python", "python": "Python", "swift": "Swift", "rb": "Ruby",
                     "ruby": "Ruby", "go": "Go", "rs": "Rust", "rust": "Rust",
                     "sh": "Shell", "bash": "Shell", "zsh": "Shell", "shell": "Shell",
                     "json": "JSON", "yaml": "YAML", "yml": "YAML", "html": "HTML",
                     "css": "CSS", "sql": "SQL", "md": "Markdown", "markdown": "Markdown",
                     "kotlin": "Kotlin", "java": "Java", "c": "C", "cpp": "C++", "diff": "Diff"]
        return names[tag] ?? tag.capitalized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Self.languageName(language))
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.plain)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.Font.code)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                    in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
    }
}

struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(Theme.Font.callout.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                .font(Theme.Font.body)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
