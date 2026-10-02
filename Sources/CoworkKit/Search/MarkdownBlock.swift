import Foundation

/// The Markdown Claude writes, as blocks: enough of the language to read a conversation
/// comfortably — headings, lists, quotes, tables and code — with inline styling left to
/// whoever draws each block.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// Bulleted and numbered items, nested by `level`.
    case list([ListItem])
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    public struct ListItem: Equatable, Sendable {
        public enum Marker: Equatable, Sendable {
            case bullet
            case number(Int)
        }
        /// 0 for an item at the left edge, 1 for one nested under it, and so on.
        public let level: Int
        public let marker: Marker
        public let text: String

        public init(level: Int, marker: Marker, text: String) {
            self.level = level
            self.marker = marker
            self.text = text
        }
    }

    public static func parse(_ source: String) -> [MarkdownBlock] {
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
                // A fence inside a list item is indented with it; the code isn't.
                let indent = indentation(line)
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(dropIndentation(next, upTo: indent))
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

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
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

            if Self.listMarker(trimmed) != nil {
                flushParagraph()
                blocks.append(.list(Self.listItems(&lines)))
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
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: min(hashes, 4), text: String(line.dropFirst(hashes + 1)))
    }

    /// Consecutive list lines, each nested by how far it is indented relative to the ones
    /// before it. An indented line that isn't an item continues the item above it.
    private static func listItems(_ lines: inout ArraySlice<String>) -> [ListItem] {
        var items: [ListItem] = []
        var indents: [Int] = []
        /// The number the next item at each level takes, while that level keeps counting.
        var counters: [Int: Int] = [:]
        while let line = lines.first {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("```") else { break }
            let indent = indentation(line)
            guard let (marker, text) = listMarker(trimmed) else {
                guard indent > 0, let last = items.popLast() else { break }
                items.append(ListItem(level: last.level, marker: last.marker, text: last.text + "\n" + trimmed))
                lines.removeFirst()
                continue
            }
            while let top = indents.last, indent < top { indents.removeLast() }
            if indents.last.map({ indent > $0 + 1 }) ?? true { indents.append(indent) }
            let level = indents.count - 1
            counters = counters.filter { $0.key <= level }
            let resolved: ListItem.Marker
            switch marker {
            case .bullet:
                counters[level] = nil
                resolved = .bullet
            case .number(let written):
                let number = counters[level] ?? written
                counters[level] = number + 1
                resolved = .number(number)
            }
            items.append(ListItem(level: level, marker: resolved, text: text))
            lines.removeFirst()
        }
        return items
    }

    private static func listMarker(_ line: String) -> (ListItem.Marker, String)? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return (.bullet, String(line.dropFirst(marker.count)))
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (.number(number), String(rest.dropFirst(2)))
    }

    /// Leading spaces, with a tab as four.
    private static func indentation(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func dropIndentation(_ line: String, upTo limit: Int) -> String {
        var dropped = 0
        var index = line.startIndex
        while index < line.endIndex, dropped < limit, line[index] == " " || line[index] == "\t" {
            dropped += line[index] == "\t" ? 4 : 1
            index = line.index(after: index)
        }
        return String(line[index...])
    }

    /// A table row's cells. A pipe inside a code span, or written `\|`, belongs to the cell.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var characters = line.trimmingCharacters(in: .whitespaces)[...]
        if characters.first == "|" { characters.removeFirst() }
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            let next = characters.index(after: index)
            if character == "\\", next < characters.endIndex, characters[next] == "|" {
                current.append("|")
                index = characters.index(after: next)
                continue
            }
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = next
        }
        // The closing pipe ends the last cell rather than starting an empty one.
        if !current.trimmingCharacters(in: .whitespaces).isEmpty || cells.isEmpty { cells.append(current) }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
