import Foundation

/// Putting a Claude Code conversation in a Claude Desktop's Code tab, where it carries on.
///
/// A Code tab runs Claude Code and reads its transcripts from a Claude Code folder, usually the
/// same `~/.claude` the command line uses. Then nothing is copied: the conversation gets a Code
/// tab record pointing at its transcript, and resuming it there continues the same file. A Claude
/// set up with a Claude Code folder of its own gets the transcript copied into that folder first.
public enum CodeTabMove {

    public struct Plan: Sendable {
        public let title: String
        public let cliSessionId: String
        public let cwd: String
        public let transcript: URL
        /// Where the Code tab record goes, and the record to start it from.
        public let directory: URL?
        public let template: URL?
        /// Set when the destination reads transcripts from another Claude Code folder.
        public let copyTo: URL?
        public let lastActivity: Date?
        public let problems: [String]

        public var isExecutable: Bool { problems.isEmpty }
    }

    /// - Parameters:
    ///   - sourceRecord: the conversation's own Code tab record, when it came from one; the new
    ///     record starts from it so it keeps the conversation's model and settings.
    ///   - codeTabRoot: the destination's `claude-code-sessions` folder.
    ///   - destinationConfigDir: the Claude Code folder the destination's Code tab reads.
    public static func plan(title: String, cliSessionId: String, cwd: String, transcript: URL,
                            lastActivity: Date?, sourceRecord: URL?, codeTabRoot: URL,
                            destinationConfigDir: URL, sourceConfigDir: URL) -> Plan {
        var problems: [String] = []
        let existing = CodeTabSessions.sessions(in: codeTabRoot)
        if existing.contains(where: { $0.cliSessionId == cliSessionId }) {
            problems.append("It's already in that Claude's Code tab.")
        }
        let destination = CoworkPort.codeTabTemplate(in: codeTabRoot)
        if destination == nil {
            problems.append("That Claude's Code tab hasn't been used yet. Start any conversation in its Code tab once, then try again.")
        }
        if cwd.isEmpty || !FileManager.default.fileExists(atPath: cwd) {
            problems.append("The folder it worked in isn't on this Mac.")
        }
        var copyTo: URL?
        if WriteFence.realPath(destinationConfigDir) != WriteFence.realPath(sourceConfigDir) {
            let target = destinationConfigDir.appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(PathEncoder.encode(PathEncoder.resolvedPath(cwd)), isDirectory: true)
                .appendingPathComponent(transcript.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                problems.append("That Claude's Claude Code folder already has this conversation.")
            }
            copyTo = target
        }
        return Plan(title: title, cliSessionId: cliSessionId, cwd: cwd, transcript: transcript,
                    directory: destination?.directory, template: sourceRecord ?? destination?.template,
                    copyTo: copyTo, lastActivity: lastActivity, problems: problems)
    }

    public static func apply(_ plan: Plan, destinationName: String) throws -> ImportReceipt {
        guard plan.isExecutable, let directory = plan.directory, let template = plan.template else {
            throw TransferError.preconditionsFailed(plan.problems)
        }
        var receipt = ImportReceipt(direction: .codeTab, destination: "\(destinationName) · Code tab")
        receipt.title = plan.title
        receipt.itemCount = 1
        try Undo.save(receipt)
        do {
            if let copyTo = plan.copyTo {
                let folder = copyTo.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: folder.path) {
                    try receipt.createDirectories(at: folder)
                }
                try FileManager.default.copyItem(at: plan.transcript, to: copyTo)
                try receipt.recordCreatedFile(at: copyTo)
            }
            let record = try CoworkPort.writeCodeTabRecord(copying: template, into: directory,
                                                           cliSessionId: plan.cliSessionId, title: plan.title,
                                                           cwd: plan.cwd, lastActivity: plan.lastActivity)
            try receipt.recordCreatedFile(at: record)
            receipt.completed = true
            try Undo.save(receipt)
        } catch {
            try? Undo.save(receipt)
            throw TransferError.partiallyApplied(receiptID: receipt.id, written: receipt.created.count,
                                                 underlying: String(describing: error))
        }
        return receipt
    }
}
