import AppKit
import CoworkKit
import Observation

/// Where a conversation can be continued.
enum ContinueDestination: Hashable, Identifiable {
    /// A Claude Desktop install (or copy), in one of its accounts.
    case account(installID: String, AccountRef)
    /// A Claude Code project folder.
    case project(path: String)

    var id: String {
        switch self {
        case .account(_, let account): return "account:" + account.id
        case .project(let path): return "project:" + path
        }
    }
}

/// Carrying one conversation into another install or a Claude Code project.
///
/// Export and import are the engine's own code paths, the same ones the command line uses, so
/// a safety check added there applies here too. Everything slow runs off the main actor.
@MainActor
@Observable
final class ContinueModel: Identifiable {
    enum Step: Equatable {
        case choose
        case review
        case working
        case done
        case failed
    }

    let conversation: ConversationRef
    let source: Install?

    var step: Step = .choose
    var destination: ContinueDestination?
    var includeUploads = false
    var includeOutputs = false
    var profile: RedactionProfile = .sameUser
    var quitIfOpen = true

    private(set) var isPlanning = false
    private(set) var plan: ImportPlan?
    private(set) var progress: String?
    private(set) var receipt: ImportReceipt?
    private(set) var failure: String?
    /// Set when the import stopped partway; this receipt undoes what it wrote.
    private(set) var partialReceiptID: String?
    private(set) var undone = false

    private var stagingDirectory: URL?

    init(conversation: ConversationRef, source: Install?) {
        self.conversation = conversation
        self.source = source
    }

    var isCowork: Bool { conversation.coworkSession != nil }

    // MARK: Plan

    func review(in snapshot: CatalogSnapshot) {
        guard let destination else { return }
        isPlanning = true
        failure = nil
        let conversation = conversation
        let options = exportOptions
        let profile = profile
        let quit = quitIfOpen
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.buildPlan(conversation: conversation, destination: destination,
                                            options: options, profile: profile, quit: quit) }
            }.value
            isPlanning = false
            switch result {
            case .success(let (plan, staging)):
                cleanUp()
                self.plan = plan
                stagingDirectory = staging
                step = .review
            case .failure(let error):
                failure = Self.explain(error)
            }
        }
    }

    private var exportOptions: ExportOptions {
        var options = ExportOptions(redactionProfile: profile)
        options.includeUploads = includeUploads
        options.includeOutputs = includeOutputs
        return options
    }

    nonisolated static func buildPlan(conversation: ConversationRef, destination: ContinueDestination,
                                      options: ExportOptions, profile: RedactionProfile,
                                      quit: Bool) throws -> (ImportPlan, URL) {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BetterClaude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = staging.appendingPathComponent("transfer.coworkbundle")

        let exportPlan: ExportPlan
        if let session = conversation.coworkSession {
            exportPlan = try Exporter.plan([session], options: options)
        } else if let session = conversation.claudeCodeSession {
            exportPlan = try Exporter.plan([session], options: options)
        } else {
            throw TransferError.sourceTranscriptMissing(sessionId: conversation.cliSessionId)
        }
        _ = try Exporter.write(exportPlan, to: bundle, profile: profile)

        let endpoint: Endpoint
        switch destination {
        case .account(_, let account):
            endpoint = .cowork(account)
        case .project(let path):
            endpoint = .claudeCode(projectDir: projectDirectory(for: path),
                                   configDir: HostPaths.current.claudeCodeConfigDir)
        }
        var importOptions = ImportOptions()
        importOptions.quitRunningVariant = quit
        return (try Importer.plan(bundle: bundle, to: endpoint, options: importOptions), staging)
    }

    /// The folder under `~/.claude/projects` that Claude Code reads for `path`: the existing
    /// one when there is one, otherwise the one it would create.
    nonisolated static func projectDirectory(for path: String) -> URL {
        let projects = HostPaths.current.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)
        if let existing = (try? PathEncoder.candidateDirectories(for: path, in: projects))?.first {
            return existing
        }
        return projects.appendingPathComponent(PathEncoder.encode(resolving: path), isDirectory: true)
    }

    // MARK: Apply

    func apply() {
        guard let plan else { return }
        step = .working
        progress = "Copying the conversation…"
        let options = ImportOptions(quitRunningVariant: quitIfOpen)
        let report: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in self?.progress = ContinueModel.friendly(message) }
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Importer.apply(plan, options: options, progress: report) }
            }.value
            cleanUp()
            switch result {
            case .success(let receipt):
                self.receipt = receipt
                step = .done
            case .failure(let error):
                if case TransferError.partiallyApplied(let id, _, _) = error { partialReceiptID = id }
                failure = Self.explain(error)
                step = .failed
            }
        }
    }

    /// Takes back what this transfer wrote.
    func undo() {
        let id = receipt?.id ?? partialReceiptID
        guard let id else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> RevertResult in
                    guard let receipt = try Undo.receipts().first(where: { $0.id == id }) else {
                        throw UndoError.receiptNotFound(id: id)
                    }
                    return try Undo.revertAndRecord(receipt)
                }
            }.value
            switch result {
            case .success: undone = true
            case .failure(let error): failure = "Couldn't undo it: \(Self.explain(error))"
            }
        }
    }

    func cleanUp() {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }

    // MARK: Words

    /// Engine messages are written for the command line; a sheet wants plainer ones.
    nonisolated static func friendly(_ message: String) -> String {
        if message.hasPrefix("Quitting Claude") { return "Quitting Claude so it can't overwrite the copy…" }
        return message
    }

    nonisolated static func explain(_ error: Error) -> String {
        switch error {
        case TransferError.partiallyApplied(_, let written, _):
            return "It stopped partway, after writing \(written == 1 ? "one file" : "\(written) files"). Undo removes everything it wrote."
        case TransferError.variantRunning:
            return "That Claude is open. Let Better Claude quit it, or quit it yourself, then try again."
        case TransferError.secretsFound:
            return "The conversation contains something that looks like a password or API key, so it wasn't copied. Remove it in Claude, or continue with “Remove everything optional”."
        case TransferError.insufficientSpace(let needed, let available):
            return "There isn't enough space: it needs \(needed.fileSize) and \(available.fileSize) is free."
        case TransferError.noDonorSession:
            return "That account hasn't been used in this Claude yet. Open it and start any conversation once, then try again."
        default:
            let text = String(describing: error)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }
}
