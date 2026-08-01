import CoworkKit
import Foundation
import Observation

/// Where a transfer is headed, as chosen in the UI.
enum Destination: Hashable, Identifiable {
    case coworkAccount(AccountRef)
    case claudeCodeProject(URL)

    var id: String {
        switch self {
        case .coworkAccount(let a): return "cowork:\(a.id)"
        case .claudeCodeProject(let u): return "code:\(u.path)"
        }
    }

    var label: String {
        switch self {
        case .coworkAccount(let a): return "\(a.store.variantDirName) · \(a.displayIdentity)"
        case .claudeCodeProject(let u): return u.lastPathComponent
        }
    }

    var detail: String {
        switch self {
        case .coworkAccount(let a): return "\(a.sessionCount) existing session(s)"
        case .claudeCodeProject(let u): return u.path
        }
    }
}

enum TransferStage: Equatable {
    case configuring
    case planning
    case ready
    case running
    case finished(receiptID: String, summary: String)
    case failed(String)
}

@MainActor
@Observable
final class TransferModel {
    var stage: TransferStage = .configuring
    var destination: Destination?
    var includeUploads = false
    var includeOutputs = false
    var profile: RedactionProfile = .sameUser
    var quitRunningVariant = false

    var plan: ImportPlan?
    var manifest: Manifest?
    var progressLines: [String] = []

    let sessions: [SessionRow]
    private var bundleURL: URL?

    init(sessions: [SessionRow]) {
        self.sessions = sessions
    }

    var canPlan: Bool { destination != nil && !sessions.isEmpty }

    /// Builds the bundle and computes the import plan without writing to the destination.
    ///
    /// Export and import are the same code path the command line uses; the UI never has its
    /// own transfer logic, so a check added in one place applies to both.
    func buildPlan() async {
        guard let destination else { return }
        stage = .planning
        progressLines = []
        do {
            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("BetterClaude-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let bundle = staging.appendingPathComponent("transfer.coworkbundle")

            var options = ExportOptions(redactionProfile: profile)
            options.includeUploads = includeUploads
            options.includeOutputs = includeOutputs

            let coworkSessions = sessions.compactMap(\.cowork)
            let codeSessions = sessions.compactMap(\.claudeCode)
            let exportPlan = coworkSessions.isEmpty
                ? try Exporter.plan(codeSessions, options: options)
                : try Exporter.plan(coworkSessions, options: options)
            progressLines.append(contentsOf: exportPlan.warnings)

            let manifest = try Exporter.write(exportPlan, to: bundle, profile: profile)
            self.manifest = manifest
            bundleURL = bundle

            let endpoint: Endpoint
            switch destination {
            case .coworkAccount(let account):
                endpoint = .cowork(account)
            case .claudeCodeProject(let projectDir):
                endpoint = .claudeCode(projectDir: projectDir,
                                       configDir: Discovery.defaultClaudeCodeConfigDir())
            }

            var importOptions = ImportOptions()
            importOptions.quitRunningVariant = quitRunningVariant
            plan = try Importer.plan(bundle: bundle, to: endpoint, options: importOptions)
            stage = .ready
        } catch {
            stage = .failed("\(error)")
        }
    }

    func apply() async {
        guard let plan else { return }
        stage = .running
        do {
            var options = ImportOptions()
            options.quitRunningVariant = quitRunningVariant
            let receipt = try Importer.apply(plan, options: options) { message in
                Task { @MainActor in self.progressLines.append(message) }
            }
            let next: String
            switch plan.endpoint {
            case .cowork:
                next = "Open Claude to see the conversation in its session list."
            case .claudeCode(let projectDir, _):
                next = "Run `claude --resume` from \(projectDir.path)."
            }
            stage = .finished(receiptID: receipt.id, summary: next)
            cleanUpBundle()
        } catch {
            stage = .failed("\(error)")
            cleanUpBundle()
        }
    }

    func cleanUpBundle() {
        guard let bundleURL else { return }
        try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent())
        self.bundleURL = nil
    }
}
