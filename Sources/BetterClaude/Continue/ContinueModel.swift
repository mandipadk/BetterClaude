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
    /// Everything being carried: one conversation, or every conversation in a project.
    let conversations: [ConversationRef]
    /// Set when a whole Cowork project is being copied.
    let project: CoworkProject?
    let source: Install?

    var step: Step = .choose
    var destination: ContinueDestination?
    var includeUploads = false
    var includeOutputs = false
    var profile: RedactionProfile = .sameUser
    /// Off until the person turns it on: quitting an app is theirs to agree to.
    var quitIfOpen = false

    private(set) var isPlanning = false
    private(set) var plan: ImportPlan?
    private(set) var progress: String?
    private(set) var receipt: ImportReceipt?
    private(set) var failure: String?
    /// Set when the import stopped partway; this receipt undoes what it wrote.
    private(set) var partialReceiptID: String?
    private(set) var undone = false
    private(set) var isUndoing = false
    /// What Undo left in place, in words, when it couldn't take everything back.
    private(set) var undoNote: String?
    private(set) var undoFailure: String?

    private var stagingDirectory: URL?

    init(conversation: ConversationRef, source: Install?) {
        self.conversation = conversation
        self.conversations = [conversation]
        self.project = nil
        self.source = source
    }

    init(project: CoworkProject, conversations: [ConversationRef], source: Install?) {
        self.conversation = conversations[0]
        self.conversations = conversations
        self.project = project
        self.source = source
        // A project is being moved as a whole, so the files in it come too.
        self.includeUploads = true
        self.includeOutputs = true
    }

    var isCowork: Bool { conversation.coworkSession != nil }

    /// What the sheet calls the thing being carried.
    var subject: String { project?.name ?? conversation.title }

    /// "the conversation", or "its 3 conversations".
    var countPhrase: String {
        conversations.count == 1 ? "the conversation" : "its \(conversations.count) conversations"
    }

    // MARK: Plan

    func review(in snapshot: CatalogSnapshot) {
        guard let destination else { return }
        isPlanning = true
        failure = nil
        let conversations = conversations
        let options = exportOptions
        let profile = profile
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.buildPlan(conversations: conversations, destination: destination,
                                            options: options, profile: profile) }
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

    nonisolated static func buildPlan(conversations: [ConversationRef], destination: ContinueDestination,
                                      options: ExportOptions, profile: RedactionProfile) throws -> (ImportPlan, URL) {
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BetterClaude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = staging.appendingPathComponent("transfer.coworkbundle")

        let exportPlan: ExportPlan
        let cowork = conversations.compactMap(\.coworkSession)
        let code = conversations.compactMap(\.claudeCodeSession)
        if !cowork.isEmpty {
            exportPlan = try Exporter.plan(cowork, options: options)
        } else if !code.isEmpty {
            exportPlan = try Exporter.plan(code, options: options)
        } else {
            throw TransferError.sourceTranscriptMissing(sessionId: conversations.first?.cliSessionId ?? "")
        }
        _ = try Exporter.write(exportPlan, to: bundle, profile: profile)

        let endpoint: Endpoint
        switch destination {
        case .account(_, let account):
            endpoint = .cowork(account)
        case .project(let path):
            endpoint = .claudeCode(projectDir: URL(fileURLWithPath: path),
                                   configDir: HostPaths.current.claudeCodeConfigDir)
        }
        // Planned as if quitting were allowed, so an open Claude shows as the toggle in Review
        // rather than a dead end. Whether it is allowed is the toggle's, checked again on apply.
        var importOptions = ImportOptions()
        importOptions.quitRunningVariant = true
        return (try Importer.plan(bundle: bundle, to: endpoint, options: importOptions), staging)
    }

    // MARK: Apply

    func apply() {
        guard let plan else { return }
        step = .working
        progress = conversations.count == 1 ? "Copying the conversation…" : "Copying \(conversations.count) conversations…"
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
        guard let id, !isUndoing, !undone else { return }
        isUndoing = true
        undoFailure = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () throws -> RevertResult in
                    guard let receipt = try Undo.receipts().first(where: { $0.id == id }) else {
                        throw UndoError.receiptNotFound(id: id)
                    }
                    return try Undo.revertAndRecord(receipt)
                }
            }.value
            isUndoing = false
            switch result {
            case .success(let outcome):
                undone = true
                undoNote = Self.leftBehind(outcome)
            case .failure(let error): undoFailure = "Couldn't undo it: \(Self.explain(error))"
            }
        }
    }

    /// What an undo kept, in a sentence, or `nil` when it took everything back.
    nonisolated static func leftBehind(_ result: RevertResult) -> String? {
        let count = result.leftInPlace.count
        guard count > 0 else { return nil }
        return count == 1
            ? "One file changed since, so it was kept. Undo it again from Activity once you're done with it."
            : "\(count) files changed since, so they were kept. Undo it again from Activity once you're done with them."
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
