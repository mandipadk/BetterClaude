import Foundation

/// What Claude Code's automatic memory for a project doesn't actually give Claude. Only the
/// first 200 lines, or 25KB, of `MEMORY.md` are read at the start of a session, and a note is
/// only found through a link from it.
public struct MemoryHealth: Sendable, Equatable {
    public static let lineLimit = 200
    public static let byteLimit = 25 * 1_024

    public let index: URL
    /// Lines of `MEMORY.md` past the cut, which never load.
    public let linesPastCut: Int
    /// Notes in the folder that `MEMORY.md` doesn't link to.
    public let unlinked: [URL]
    /// Links in `MEMORY.md` to notes that aren't there.
    public let missing: [String]

    public var isHealthy: Bool { linesPastCut == 0 && unlinked.isEmpty && missing.isEmpty }

    /// The health of a memory folder, or nil when it has no `MEMORY.md`.
    public static func check(folder: URL) -> MemoryHealth? {
        let index = folder.appendingPathComponent("MEMORY.md")
        guard let data = try? Data(contentsOf: index), let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // The cut is whichever comes first, 200 lines or 25KB.
        var kept = 0, bytes = 0
        for line in lines {
            bytes += line.utf8.count + 1
            guard kept < lineLimit, bytes <= byteLimit else { break }
            kept += 1
        }
        let links = Set(linkTargets(in: text))
        let notes = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".md") && $0 != "MEMORY.md" }.sorted()
        return MemoryHealth(index: index, linesPastCut: lines.count - kept,
                            unlinked: notes.filter { !links.contains($0) }.map { folder.appendingPathComponent($0) },
                            missing: links.filter { !notes.contains($0) }.sorted())
    }

    static func linkTargets(in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: #"\]\(([^)#\s]+\.md)\)"#)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// A note's description, from its front matter, for its line in the index.
    static func summary(of note: URL) -> String {
        let text = (try? String(contentsOf: note, encoding: .utf8)) ?? ""
        if let line = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("description:") }) {
            return line.dropFirst("description:".count).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        }
        return ""
    }

    /// Adds a line for each note to `MEMORY.md`, near the top so it's inside the cut, with a
    /// receipt: Undo in History puts the index back as it was.
    @discardableResult
    public func link(_ notes: [URL], paths: HostPaths = .current) throws -> ImportReceipt {
        var receipt = ImportReceipt(direction: .memoryEdit, destination: index.path)
        receipt.title = "Linked \(notes.count) note\(notes.count == 1 ? "" : "s") from MEMORY.md"
        receipt.itemCount = notes.count
        try receipt.backUp(index, paths: paths)
        try Undo.save(receipt)
        var lines = try String(contentsOf: index, encoding: .utf8).components(separatedBy: "\n")
        let entries = notes.map { note -> String in
            let name = note.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            let summary = Self.summary(of: note)
            return "- [\(name.prefix(1).uppercased() + name.dropFirst())](\(note.lastPathComponent))" + (summary.isEmpty ? "" : " — \(summary)")
        }
        // After the last existing link, or at the top.
        let at = (lines.lastIndex { $0.contains("](") && $0.contains(".md)") }).map { $0 + 1 } ?? 0
        lines.insert(contentsOf: entries, at: min(at, lines.count))
        try AtomicWrite.write(Data(lines.joined(separator: "\n").utf8), to: index)
        try receipt.recordModified(at: index)
        receipt.completed = true
        try Undo.save(receipt)
        return receipt
    }
}
