import CoworkKit
import SwiftUI

/// Parsed blocks by source text, so a message is parsed once rather than on every pass of
/// the view that shows it, such as each hover.
@MainActor
enum MarkdownBlockCache {
    private static var blocks: [String: [MarkdownBlock]] = [:]

    static func blocks(for source: String) -> [MarkdownBlock] {
        if let cached = blocks[source] { return cached }
        let parsed = MarkdownBlock.parse(source)
        if blocks.count > 2_000 { blocks.removeAll(keepingCapacity: true) }
        blocks[source] = parsed
        return parsed
    }
}

/// Renders Markdown blocks in the reading type.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ source: String) {
        blocks = MarkdownBlockCache.blocks(for: source)
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
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch item.marker {
                        case .bullet:
                            Text(item.level == 0 ? "•" : "◦").foregroundStyle(.secondary)
                        case .number(let number):
                            Text("\(number).")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 18, alignment: .trailing)
                        }
                        inline(item.text).lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
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

    @State private var hovering = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(4)
                .foregroundStyle(Theme.Surface.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Surface.fill, in: .rect(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if hovering || copied {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.secondary)
                .padding(6)
                .help("Copy this \(Self.languageName(language)) code")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy Code") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
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
