import CryptoKit
import Foundation

/// What kind of thing an artifact is. One axis, six values: enough to filter by, few enough
/// that a person can hold the whole list in their head.
public enum ArtifactKind: String, Sendable, CaseIterable {
    case code          // fenced block in a message
    case document      // file in outputs/ that is text-ish
    case data          // csv/json/etc in outputs/
    case image
    case upload        // something the user put in
    case other

    /// Display name. Lives here rather than in the view so the filter bar and any future
    /// export agree on one spelling.
    public var label: String {
        switch self {
        case .code: return "Code"
        case .document: return "Documents"
        case .data: return "Data"
        case .image: return "Images"
        case .upload: return "Uploads"
        case .other: return "Other"
        }
    }
}

/// One thing Claude made or was given, with a path back to the conversation that produced it.
///
/// An artifact is either inline (a fenced block that only exists inside a transcript) or a
/// file on disk, never both — `inlineContent` and `fileURL` are the two spellings of "where
/// the bytes are".
public struct Artifact: Sendable, Identifiable, Hashable {
    public let id: String              // content hash + origin, stable across re-harvests
    public let kind: ArtifactKind
    public let title: String           // filename, or an inferred label for a code block
    public let language: String?       // fence language, or inferred from extension
    public let bytes: Int
    public let lineCount: Int?
    public let contentHash: String     // sha256 — the dedup key
    /// Present for code blocks harvested from a transcript; nil for files on disk.
    public let inlineContent: String?
    /// Present for files; nil for inline blocks.
    public let fileURL: URL?
    public let conversationTitle: String
    public let conversationID: String
    public let container: String       // variant name or project name
    public let createdAt: Date?

    public init(id: String, kind: ArtifactKind, title: String, language: String?, bytes: Int,
                lineCount: Int?, contentHash: String, inlineContent: String?, fileURL: URL?,
                conversationTitle: String, conversationID: String, container: String,
                createdAt: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.language = language
        self.bytes = bytes
        self.lineCount = lineCount
        self.contentHash = contentHash
        self.inlineContent = inlineContent
        self.fileURL = fileURL
        self.conversationTitle = conversationTitle
        self.conversationID = conversationID
        self.container = container
        self.createdAt = createdAt
    }
}

public struct HarvestSummary: Sendable {
    public let artifacts: [Artifact]
    public let totalBytes: Int64
    public let duplicatesCollapsed: Int
    public let conversationsScanned: Int
    public let skipped: [String]       // reasons, e.g. "node_modules", "binary"

    public init(artifacts: [Artifact], totalBytes: Int64, duplicatesCollapsed: Int,
                conversationsScanned: Int, skipped: [String]) {
        self.artifacts = artifacts
        self.totalBytes = totalBytes
        self.duplicatesCollapsed = duplicatesCollapsed
        self.conversationsScanned = conversationsScanned
        self.skipped = skipped
    }

    public func count(of kind: ArtifactKind) -> Int {
        artifacts.reduce(0) { $1.kind == kind ? $0 + 1 : $0 }
    }
}

/// One conversation to harvest from: its transcript, its workspace, or both.
///
/// Deliberately not a `SessionRef` or a `CCSessionRef`: the harvest needs four strings and up
/// to two URLs, and taking those directly keeps it usable for a Cowork session, a Claude Code
/// transcript, and a synthetic fixture without a branch per case.
public struct HarvestSource: Sendable {
    public let conversationTitle: String
    public let conversationID: String
    public let container: String
    public let transcriptURL: URL?
    public let workspaceURL: URL?

    public init(conversationTitle: String, conversationID: String, container: String,
                transcriptURL: URL?, workspaceURL: URL?) {
        self.conversationTitle = conversationTitle
        self.conversationID = conversationID
        self.container = container
        self.transcriptURL = transcriptURL
        self.workspaceURL = workspaceURL
    }
}

/// Everything Claude ever made, gathered from every conversation on the machine.
///
/// Nothing here writes: the harvest reads transcripts and session workspaces and returns
/// values. Files are streamed rather than loaded — one session workspace on this machine
/// holds a 66 MB model file, and hashing it must not cost 66 MB of resident memory.
public enum ArtifactHarvest {

    // MARK: - Code blocks

    /// Code blocks inside one transcript.
    public static func codeBlocks(in transcript: Transcript, conversationTitle: String,
                                  conversationID: String, container: String) -> [Artifact] {
        var out: [Artifact] = []
        var ordinal = 0
        for message in ConversationText.messages(in: transcript) {
            for block in fencedBlocks(in: message.text) {
                ordinal += 1
                guard isSubstantial(block.content) else { continue }
                // Stored as a file would be, newline-terminated. Without this a block and the
                // file Claude wrote it to hash differently over a single trailing byte, and
                // "here is the script" / "I saved the script" would never collapse.
                let content = block.content + "\n"
                let digest = sha256(Data(content.utf8))
                let language = block.language.flatMap { $0.isEmpty ? nil : $0 }
                out.append(Artifact(
                    id: "\(digest)@\(conversationID)#\(ordinal)",
                    kind: .code,
                    title: inferredTitle(forCode: block.content, language: language),
                    language: language.map(canonicalLanguage),
                    bytes: content.utf8.count,
                    lineCount: lineCount(of: content),
                    contentHash: digest,
                    inlineContent: content,
                    fileURL: nil,
                    conversationTitle: conversationTitle,
                    conversationID: conversationID,
                    container: container,
                    createdAt: message.timestamp))
            }
        }
        return out
    }

    // MARK: - Files

    /// Files on disk belonging to one session workspace.
    public static func files(inWorkspace workspace: URL, conversationTitle: String,
                             conversationID: String, container: String) -> [Artifact] {
        harvestFiles(inWorkspace: workspace, conversationTitle: conversationTitle,
                     conversationID: conversationID, container: container).artifacts
    }

    /// The subdirectories of a session workspace that hold anything a person put there or got
    /// back. Everything else in a workspace — `.claude/`, `audit.jsonl` — is machine state.
    public static let workspaceSubdirectories = ["uploads", "outputs"]

    /// Directory names never descended into.
    ///
    /// `node_modules` is the whole reason this list exists: on this machine it accounts for
    /// roughly 86% of every file under `outputs/` and contains nothing the user wrote or asked
    /// for. Walking it would make the harvest slower than the app it lives in.
    public static let excludedDirectoryNames: Set<String> = ["node_modules", ".git"]

    static func harvestFiles(inWorkspace workspace: URL, conversationTitle: String,
                             conversationID: String, container: String)
        -> (artifacts: [Artifact], skips: [String: Int]) {
        var artifacts: [Artifact] = []
        var skips: [String: Int] = [:]

        for name in workspaceSubdirectories {
            let root = workspace.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(root) else { continue }
            for fileURL in walk(root, skips: &skips) {
                guard let artifact = makeArtifact(
                    file: fileURL, origin: name, conversationTitle: conversationTitle,
                    conversationID: conversationID, container: container, skips: &skips)
                else { continue }
                artifacts.append(artifact)
            }
        }
        return (artifacts, skips)
    }

    /// Depth-first walk that never throws out and never follows a symlink.
    ///
    /// A dangling link, a directory whose permissions changed, or a file deleted between the
    /// listing and the read removes one entry and leaves the rest of the walk intact.
    /// Symlinks are skipped rather than resolved: a workspace that links to its own parent
    /// would otherwise walk forever.
    static func walk(_ root: URL, skips: inout [String: Int]) -> [URL] {
        var files: [URL] = []
        var stack = [root]
        while let directory = stack.popLast() {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [])) ?? []
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    if excludedDirectoryNames.contains(name) {
                        skips[name, default: 0] += countFiles(under: entry)
                        continue
                    }
                    // A dot-directory is tooling state — `.venv`, `.next`, `.cache`.
                    if name.hasPrefix(".") {
                        skips["dot-directory", default: 0] += countFiles(under: entry)
                        continue
                    }
                    stack.append(entry)
                    continue
                }

                if name == ".DS_Store" || name.hasPrefix(".") {
                    skips["dot-file", default: 0] += 1
                    continue
                }
                files.append(entry)
            }
        }
        return files
    }

    /// File count under an excluded directory, so the summary can say what it declined to read.
    ///
    /// This lists directories but opens no files, which is what makes reporting the exclusion
    /// affordable in the first place.
    static func countFiles(under directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var count = 0
        for case let entry as URL in enumerator {
            if (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }

    static func makeArtifact(file url: URL, origin: String, conversationTitle: String,
                             conversationID: String, container: String,
                             skips: inout [String: Int]) -> Artifact? {
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let bytes = values?.fileSize ?? 0
        let created = values?.creationDate ?? values?.contentModificationDate

        let ext = url.pathExtension.lowercased()
        let isImage = imageExtensions.contains(ext)

        // Sniff before hashing. A binary that will be skipped must not be read end to end.
        let binary = isImage ? true : looksBinary(url)
        guard let kind = classify(origin: origin, ext: ext, isBinary: binary) else {
            skips["binary", default: 0] += 1
            return nil
        }

        // Line counts only mean something for text, and counting them is free while hashing.
        guard let probe = digest(of: url, countingLines: !binary) else {
            skips["unreadable", default: 0] += 1
            return nil
        }

        return Artifact(
            id: "\(probe.digest)@\(conversationID)#\(url.lastPathComponent)",
            kind: kind,
            title: url.lastPathComponent,
            language: languageForExtension[ext],
            bytes: bytes,
            lineCount: probe.lines,
            contentHash: probe.digest,
            inlineContent: nil,
            fileURL: url,
            conversationTitle: conversationTitle,
            conversationID: conversationID,
            container: container,
            createdAt: created)
    }

    /// `nil` means "skip this file".
    ///
    /// Directory wins for uploads: what makes an upload worth finding is that the user put it
    /// there, not what format it happens to be in.
    static func classify(origin: String, ext: String, isBinary: Bool) -> ArtifactKind? {
        if origin == "uploads" { return .upload }
        if imageExtensions.contains(ext) { return .image }
        if dataExtensions.contains(ext) { return .data }
        if binaryDocumentExtensions.contains(ext) { return .document }
        if isBinary { return nil }
        return .document
    }

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "ico",
    ]
    static let dataExtensions: Set<String> = [
        "csv", "tsv", "json", "jsonl", "ndjson", "xml", "yaml", "yml", "toml", "parquet",
        "sqlite", "db", "plist", "arrow",
    ]
    /// Formats that are binary on disk but are documents to a person.
    static let binaryDocumentExtensions: Set<String> = [
        "pdf", "docx", "doc", "xlsx", "xls", "pptx", "ppt", "odt", "ods", "epub", "pages",
        "numbers", "key", "rtf",
    ]

    static let languageForExtension: [String: String] = [
        "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript",
        "cjs": "javascript", "ts": "typescript", "tsx": "tsx", "jsx": "jsx", "rb": "ruby",
        "go": "go", "rs": "rust", "java": "java", "kt": "kotlin", "c": "c", "h": "c",
        "cpp": "c++", "cc": "c++", "hpp": "c++", "m": "objective-c", "mm": "objective-c++",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell", "ps1": "powershell",
        "sql": "sql", "html": "html", "css": "css", "scss": "scss", "md": "markdown",
        "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml",
        "csv": "csv", "tsv": "tsv", "txt": "text", "lua": "lua", "php": "php", "pl": "perl",
        "r": "r", "scala": "scala", "ex": "elixir", "exs": "elixir", "hs": "haskell",
        "dart": "dart", "vue": "vue", "svelte": "svelte", "tf": "terraform",
        "dockerfile": "dockerfile", "makefile": "make", "gradle": "gradle", "ipynb": "notebook",
    ]

    // MARK: - Deduplication

    /// Collapse by contentHash, keeping the earliest origin and counting the rest.
    ///
    /// This is the point of the whole feature. The same snippet is pasted, refined and pasted
    /// again across a dozen conversations; without collapsing, the library is a list of the
    /// same twenty things repeated.
    public static func deduplicate(_ artifacts: [Artifact]) -> (kept: [Artifact], collapsed: Int) {
        var earliest: [String: Artifact] = [:]
        var order: [String] = []
        for artifact in artifacts {
            guard let existing = earliest[artifact.contentHash] else {
                earliest[artifact.contentHash] = artifact
                order.append(artifact.contentHash)
                continue
            }
            if isEarlier(artifact, than: existing) { earliest[artifact.contentHash] = artifact }
        }
        let kept = order.compactMap { earliest[$0] }
        return (kept, artifacts.count - kept.count)
    }

    /// An artifact with no date cannot be earlier than one that has a date: an undated file is
    /// unknown, not ancient, and treating it as ancient would let it evict the provenance of a
    /// block that has a real timestamp. `id` breaks exact ties so the result is deterministic.
    static func isEarlier(_ lhs: Artifact, than rhs: Artifact) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (l?, r?): return l == r ? lhs.id < rhs.id : l < r
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return lhs.id < rhs.id
        }
    }

    // MARK: - Search

    /// Terms are AND-ed across the title, language, provenance and — for inline blocks — the
    /// code itself, matching the behaviour of the conversation search box.
    public static func search(_ artifacts: [Artifact], query: String) -> [Artifact] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return artifacts }
        return artifacts.filter { artifact in
            let haystack = haystack(for: artifact)
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    static func haystack(for artifact: Artifact) -> String {
        var parts = [artifact.title, artifact.kind.rawValue, artifact.conversationTitle,
                     artifact.container]
        if let language = artifact.language { parts.append(language) }
        if let content = artifact.inlineContent { parts.append(content) }
        if let url = artifact.fileURL { parts.append(url.lastPathComponent) }
        return parts.joined(separator: "\n").lowercased()
    }

    // MARK: - Whole-machine harvest

    /// Harvest every source, deduplicate, and report what was skipped.
    ///
    /// Serial. Correct, and fine for a handful of sources; for a whole machine use
    /// ``harvest(sources:maximumConcurrency:)``, which is the same work spread over cores.
    public static func harvest(sources: [HarvestSource]) -> HarvestSummary {
        assemble(sources.map(harvestOne), scanned: sources.count)
    }

    /// The whole-machine harvest.
    ///
    /// Sources are independent, and the cost is dominated by parsing JSON, so this scales
    /// almost linearly with cores. Concurrency is *bounded* rather than unlimited: a
    /// transcript's parsed form is several times the size of the file and individual
    /// transcripts run to tens of megabytes, so starting all of them at once trades a memory
    /// spike for throughput nobody asked for.
    public static func harvest(sources: [HarvestSource],
                               maximumConcurrency: Int) async -> HarvestSummary {
        let width = max(1, maximumConcurrency)
        var results: [Partial] = []
        results.reserveCapacity(sources.count)

        await withTaskGroup(of: Partial.self) { group in
            var next = 0
            while next < min(width, sources.count) {
                let source = sources[next]
                group.addTask { harvestOne(source) }
                next += 1
            }
            while let finished = await group.next() {
                results.append(finished)
                if next < sources.count {
                    let source = sources[next]
                    group.addTask { harvestOne(source) }
                    next += 1
                }
            }
        }
        return assemble(results, scanned: sources.count)
    }

    /// One source's contribution, before deduplication.
    struct Partial: Sendable {
        var artifacts: [Artifact] = []
        var skips: [String: Int] = [:]
    }

    static func harvestOne(_ source: HarvestSource) -> Partial {
        var partial = Partial()
        if let transcriptURL = source.transcriptURL {
            if let transcript = fencedRecords(at: transcriptURL) {
                partial.artifacts += codeBlocks(
                    in: transcript, conversationTitle: source.conversationTitle,
                    conversationID: source.conversationID, container: source.container)
            } else {
                partial.skips["unreadable transcript", default: 0] += 1
            }
        }
        if let workspace = source.workspaceURL, isDirectory(workspace) {
            let found = harvestFiles(inWorkspace: workspace,
                                     conversationTitle: source.conversationTitle,
                                     conversationID: source.conversationID,
                                     container: source.container)
            partial.artifacts += found.artifacts
            for (reason, count) in found.skips { partial.skips[reason, default: 0] += count }
        }
        return partial
    }

    /// The records of a transcript that could possibly hold a fenced block.
    ///
    /// Parsing is what a whole-machine harvest costs: this corpus is 550 MB of JSONL and most
    /// of it is tool results, diffs and inline media that no code block can hide in. A record
    /// with no ``` anywhere in its raw bytes cannot produce one either — JSON has no escape
    /// for a backtick, so a fence in a message is three literal backticks on the line — and
    /// skipping those records unparsed is the difference between minutes and seconds.
    ///
    /// Records that survive the filter keep their own uuid and timestamp, so provenance is
    /// unaffected; only records that would have contributed nothing are missing.
    static func fencedRecords(at url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let fence = Data("```".utf8)
        let newline = Data([0x0A])

        var records: [JSONValue] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data.range(of: newline, options: [], in: start..<data.endIndex)?.lowerBound
                ?? data.endIndex
            if start < end, data.range(of: fence, options: [], in: start..<end) != nil,
               let record = try? JSONValue.parse(Data(data[start..<end])) {
                records.append(record)
            }
            guard end < data.endIndex else { break }
            start = data.index(after: end)
        }
        return Transcript(records: records)
    }

    static func assemble(_ partials: [Partial], scanned: Int) -> HarvestSummary {
        var all: [Artifact] = []
        var skips: [String: Int] = [:]
        for partial in partials {
            all += partial.artifacts
            for (reason, count) in partial.skips { skips[reason, default: 0] += count }
        }
        let (kept, collapsed) = deduplicate(all)
        // Newest first. Sorted down to the id so a concurrent harvest and a serial one over
        // the same corpus produce the same list in the same order.
        return HarvestSummary(
            artifacts: kept.sorted { lhs, rhs in
                let left = lhs.createdAt ?? .distantPast
                let right = rhs.createdAt ?? .distantPast
                if left != right { return left > right }
                if lhs.title != rhs.title { return lhs.title < rhs.title }
                return lhs.id < rhs.id
            },
            totalBytes: kept.reduce(Int64(0)) { $0 + Int64($1.bytes) },
            duplicatesCollapsed: collapsed,
            conversationsScanned: scanned,
            skipped: skips.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" })
    }

    // MARK: - Fence parsing

    struct FencedBlock {
        let language: String?
        let content: String
    }

    /// Split a message on ``` fences.
    ///
    /// An unterminated opening fence — a message truncated by a token limit, which happens —
    /// closes at the end of the message rather than swallowing the parser.
    static func fencedBlocks(in text: String) -> [FencedBlock] {
        guard text.contains("```") else { return [] }
        var blocks: [FencedBlock] = []
        var language: String?
        var body: [Substring] = []
        var inside = false

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.hasPrefix("```") {
                if inside {
                    blocks.append(FencedBlock(language: language,
                                              content: body.joined(separator: "\n")))
                    body = []
                    language = nil
                    inside = false
                } else {
                    inside = true
                    language = fenceLanguage(trimmed.dropFirst(3))
                }
                continue
            }
            if inside { body.append(line) }
        }
        if inside, !body.isEmpty {
            blocks.append(FencedBlock(language: language, content: body.joined(separator: "\n")))
        }
        return blocks
    }

    /// The tag on an opening fence, when it is one. Info strings like ```swift title="x"``
    /// keep only the first token, and anything that is not an identifier is discarded rather
    /// than shown as a language.
    static func fenceLanguage(_ rest: Substring) -> String? {
        let token = rest.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard let token, !token.isEmpty, token.count <= 20 else { return nil }
        let allowed = token.allSatisfy { $0.isLetter || $0.isNumber || "+-#._".contains($0) }
        return allowed ? token.lowercased() : nil
    }

    static let languageAliases: [String: String] = [
        "sh": "shell", "bash": "shell", "zsh": "shell", "shell-session": "shell",
        "js": "javascript", "ts": "typescript", "py": "python", "rb": "ruby", "yml": "yaml",
        "objc": "objective-c", "cpp": "c++", "rs": "rust", "kt": "kotlin", "md": "markdown",
    ]

    static func canonicalLanguage(_ raw: String) -> String {
        languageAliases[raw] ?? raw
    }

    /// A one-line `ls` is noise, not an artifact.
    static let minimumLines = 2
    static let minimumBytes = 40

    static func isSubstantial(_ content: String) -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return lineCount(of: content) >= minimumLines && content.utf8.count >= minimumBytes
    }

    static func lineCount(of content: String) -> Int {
        guard !content.isEmpty else { return 0 }
        var lines = 1
        for character in content where character == "\n" { lines += 1 }
        if content.hasSuffix("\n") { lines -= 1 }
        return max(lines, 1)
    }

    // MARK: - Title inference

    /// A label a person can recognise a block by, in descending order of how much it says:
    /// a leading comment, a declaration name, then the language and the first identifier.
    ///
    /// "Untitled" is the last resort and is never reached while any line has a word in it,
    /// because a library of thirty rows all reading "Untitled" is not a library.
    public static func inferredTitle(forCode content: String, language: String?) -> String {
        let head = String(content.prefix(4000))
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let first = lines.first, let comment = commentText(first) { return truncated(comment) }
        if let declaration = declarationLabel(head) { return truncated(declaration) }
        if let identifier = firstIdentifier(head) {
            guard let language, !language.isEmpty else { return truncated(identifier) }
            return truncated("\(canonicalLanguage(language)) \(identifier)")
        }
        if let first = lines.first { return truncated(first) }
        guard let language, !language.isEmpty else { return "Code block" }
        return "\(canonicalLanguage(language)) block"
    }

    static let commentMarkers = ["///", "//", "#!", "#", "--", "/*", "*", "<!--", ";;", ";", "%"]

    /// The prose in a leading comment, or `nil` when the line is not one.
    static func commentText(_ line: String) -> String? {
        for marker in commentMarkers where line.hasPrefix(marker) {
            var text = String(line.dropFirst(marker.count))
            for tail in ["-->", "*/"] where text.hasSuffix(tail) {
                text = String(text.dropLast(tail.count))
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t*-=#/"))
            // A rule of dashes or a banner of stars is decoration, not a name.
            guard text.contains(where: \.isLetter) else { return nil }
            return text
        }
        return nil
    }

    static func declarationLabel(_ head: String) -> String? {
        let declaration = /\b(func|class|struct|enum|protocol|extension|interface|def|fn|function|trait|impl|record|module|namespace|type)\s+([A-Za-z_][A-Za-z0-9_]*)/
        if let match = head.firstMatch(of: declaration) {
            return "\(match.output.1) \(match.output.2)"
        }
        let binding = /\b(const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=/
        if let match = head.firstMatch(of: binding) {
            return "\(match.output.1) \(match.output.2)"
        }
        // `name() { … }` — a shell function, which none of the keyword forms above catch.
        if let match = head.firstMatch(of: /(?m)^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{/) {
            return String(match.output.1)
        }
        return nil
    }

    /// Words that identify a language rather than a thing the code is about.
    static let uninformativeIdentifiers: Set<String> = [
        "the", "and", "for", "import", "from", "return", "print", "echo", "select", "insert",
        "update", "delete", "where", "with", "using", "package", "public", "private", "static",
        "final", "const", "let", "var", "new", "this", "self", "true", "false", "null", "none",
        "if", "else", "while", "try", "catch", "async", "await", "export", "default",
        // Type names say what a thing is made of, not what it is for.
        "int", "void", "char", "bool", "float", "double", "long", "short", "unsigned", "str",
        "string", "list", "dict", "set", "map", "array", "object",
    ]

    static func firstIdentifier(_ head: String) -> String? {
        var current = ""
        for character in head {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            if let found = acceptableIdentifier(current) { return found }
            current = ""
        }
        return acceptableIdentifier(current)
    }

    static func acceptableIdentifier(_ candidate: String) -> String? {
        guard candidate.count >= 3, candidate.first?.isNumber != true,
              candidate.contains(where: \.isLetter),
              !uninformativeIdentifiers.contains(candidate.lowercased())
        else { return nil }
        return candidate
    }

    static func truncated(_ text: String, limit: Int = 72) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - Reading files

    struct FileProbe {
        let digest: String
        let lines: Int?
    }

    /// How much of a file is inspected for a NUL byte.
    public static let binarySniffBytes = 8 * 1024

    /// A file with a NUL byte near its start is binary. This is the same heuristic `git` uses,
    /// and it is right far more often than extension-matching alone.
    static func looksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: binarySniffBytes), !head.isEmpty else {
            return false
        }
        return head.contains(0x00)
    }

    /// Stream the file to a SHA-256, counting lines on the way past.
    ///
    /// Streaming in 1 MiB chunks is not an optimisation: `outputs/` on this machine holds
    /// single files of tens of megabytes, and `Data(contentsOf:)` across the whole harvest
    /// would be measured in gigabytes of peak memory.
    static func digest(of url: URL, countingLines: Bool) -> FileProbe? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        var newlines = 0
        var lastByte: UInt8?
        var sawAnything = false

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sawAnything = true
            hasher.update(data: chunk)
            if countingLines {
                chunk.withUnsafeBytes { raw in
                    for byte in raw where byte == UInt8(ascii: "\n") { newlines += 1 }
                }
            }
            lastByte = chunk.last
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard countingLines else { return FileProbe(digest: digest, lines: nil) }
        guard sawAnything else { return FileProbe(digest: digest, lines: 0) }
        // A file not ending in a newline still has a final line.
        let lines = lastByte == UInt8(ascii: "\n") ? newlines : newlines + 1
        return FileProbe(digest: digest, lines: lines)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
