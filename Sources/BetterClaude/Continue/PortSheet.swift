import AppKit
import CoworkKit
import SwiftUI

/// Moving a Cowork project into Claude Code: what will happen, then doing it, then taking it
/// back if wanted. The engine does the work; this decides the folder and the Code tab.
@MainActor
@Observable
final class PortModel: Identifiable {
    enum Step: Equatable { case choose, working, done, failed }

    let id = UUID()
    let project: CoworkProject
    var folder: String?
    /// The Desktop app whose Code tab lists the conversations, or `nil` for none.
    var codeTabInstallID: String?

    private(set) var step: Step = .choose
    private(set) var plan: CoworkPort.Plan?
    private(set) var isPlanning = false
    private(set) var briefs = 0
    private(set) var failure: String?
    private(set) var receipt: ImportReceipt?
    private(set) var undone = false
    private var staging: URL?
    private var planning: Task<Void, Never>?

    init(project: CoworkProject, codeTabInstallID: String?) {
        self.project = project
        self.folder = project.space.folders.first { FileManager.default.fileExists(atPath: $0) }
        self.codeTabInstallID = codeTabInstallID
    }

    func replan(services: AppServices) {
        planning?.cancel()
        plan = nil
        failure = nil
        guard let folder else { failure = "Choose the folder Claude Code should work in."; return }
        isPlanning = true
        let project = project
        let index = services.index.index
        let codeTabRoot = codeTabInstallID.flatMap { services.install($0)?.codeTabRoot }
        cleanUp()
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BetterClaude-port-\(UUID().uuidString)", isDirectory: true)
        self.staging = staging
        planning = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(CoworkPort.Plan, Int), Error> in
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let conversations = await CoworkPort.conversations(project.sessions, index: index)
                    let plan = try CoworkPort.plan(name: project.name, space: project.space, conversations: conversations,
                                                   folder: URL(fileURLWithPath: folder), codeTabRoot: codeTabRoot,
                                                   staging: staging)
                    return .success((plan, conversations.filter { $0.brief != nil }.count))
                } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled else { return }
            isPlanning = false
            switch result {
            case .success(let (plan, briefs)):
                self.plan = plan
                self.briefs = briefs
                if !plan.isExecutable {
                    failure = plan.importPlan.preconditions.filter { !$0.passed }.map(\.title).joined(separator: ". ") + "."
                }
            case .failure(let error):
                failure = ContinueModel.explain(error)
            }
        }
    }

    func apply() {
        guard let plan, plan.isExecutable else { return }
        step = .working
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try CoworkPort.apply(plan) }
            }.value
            cleanUp()
            switch result {
            case .success(let receipt):
                self.receipt = receipt
                step = .done
            case .failure(let error):
                failure = ContinueModel.explain(error)
                if case TransferError.partiallyApplied(let id, _, _) = error {
                    receipt = try? Undo.receipts().first { $0.id == id }
                }
                step = .failed
            }
        }
    }

    func undo() {
        guard let receipt else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Undo.revertAndRecord(receipt) }
            }.value
            switch result {
            case .success: undone = true
            case .failure(let error): failure = "Couldn't undo it: \(ContinueModel.explain(error))"
            }
        }
    }

    func cleanUp() {
        if let staging { try? FileManager.default.removeItem(at: staging) }
        staging = nil
    }
}

struct PortSheet: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: PortModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.step {
                    case .choose, .working: choose
                    case .done: done
                    case .failed: failed
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: 560, height: 600)
        .background(Theme.Surface.window)
        .task { model.replan(services: services) }
        .onDisappear { model.cleanUp() }
    }

    // MARK: Choose

    @ViewBuilder
    private var choose: some View {
        Text("Move “\(model.project.name)” to Claude Code")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Theme.Surface.primary)
        Text("Cowork tasks on this Mac are going away. This brings \(conversationCount) into Claude Code, where you can keep going. The tasks stay as they are, and Undo takes it all back.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.Surface.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)

        SectionLabel(title: "Where", top: 20)
        Card(inset: 44) {
            Row(title: model.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No folder yet",
                detail: model.folder.map { services.snapshot.paths.abbreviating($0) } ?? "The project's folder isn't on this Mac") {
                RowSymbol(name: "folder")
            } trailing: {
                Button("Change…") { chooseFolder() }.buttonStyle(.quiet)
            }
            Row(title: "Show in the Code tab", detail: "Lists each conversation in that app's Code tab too") {
                RowSymbol(name: "sidebar.left")
            } trailing: {
                Picker("Show in the Code tab", selection: $model.codeTabInstallID) {
                    Text("Nowhere").tag(String?.none)
                    ForEach(codeTabInstalls) { install in
                        Text(install.name).tag(Optional(install.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.codeTabInstallID) { model.replan(services: services) }
            }
        }

        SectionLabel(title: "What happens")
        Card(inset: 44) {
            Row(title: "\(conversationCount.prefix(1).uppercased() + conversationCount.dropFirst()) you can resume",
                detail: "Full history, working in \(folderName). claude --resume lists them") {
                RowSymbol(name: "text.bubble")
            } trailing: { EmptyView() }
            Row(title: "Their files", detail: "In \(Importer.sidecarRootName), a folder for each conversation") {
                RowSymbol(name: "doc.on.doc")
            } trailing: { EmptyView() }
            Row(title: "CLAUDE.md",
                detail: model.plan.map { $0.claudeMD == nil ? "Already there, so it's left as it is" : "What the project is and what came before" }
                    ?? "What the project is and what came before") {
                RowSymbol(name: "doc.text")
            } trailing: { EmptyView() }
            Row(title: "A brief for a new project",
                detail: model.isPlanning ? "Reading the conversations…"
                    : "\(model.briefs) of \(model.project.sessions.count) summarised, to attach to a new project's first message") {
                RowSymbol(name: "text.alignleft")
            } trailing: { EmptyView() }
        }

        if let failure = model.failure {
            Text(failure)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // MARK: Done

    @ViewBuilder
    private var done: some View {
        Text(model.undone ? "Taken back" : "It's in Claude Code")
            .font(.system(size: 16, weight: .bold))
        Text(model.undone
             ? "Everything the move wrote is gone. The Cowork tasks were never changed."
             : "\(conversationCount.prefix(1).uppercased() + conversationCount.dropFirst()) in \(folderName), ready to resume. Attach From Cowork/Brief for a new project.md to a new project's first message to start it informed.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.Surface.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
        if !model.undone, let folder = model.folder {
            HStack(spacing: 8) {
                Button("Open in Terminal") { services.resumePicker(in: folder) }.buttonStyle(.primary)
                Button("Show the Brief") {
                    if let brief = model.plan?.brief { NSWorkspace.shared.activateFileViewerSelecting([brief]) }
                }
                .buttonStyle(.secondary)
                Button("Undo") { model.undo() }.buttonStyle(.quiet)
            }
            .padding(.top, 18)
        }
    }

    @ViewBuilder
    private var failed: some View {
        Text("It didn't finish").font(.system(size: 16, weight: .bold))
        Text(model.failure ?? "Something went wrong.")
            .font(.system(size: 13))
            .foregroundStyle(Theme.Surface.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
        if model.receipt != nil, !model.undone {
            Button("Undo What It Wrote") { model.undo() }.buttonStyle(.secondary).padding(.top, 14)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch model.step {
            case .choose, .working:
                Button("Cancel", action: onClose).buttonStyle(.secondary).keyboardShortcut(.cancelAction)
                Button {
                    model.apply()
                } label: {
                    if model.step == .working || model.isPlanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move")
                    }
                }
                .buttonStyle(.primary)
                .frame(minWidth: 90)
                .disabled(!(model.plan?.isExecutable ?? false) || model.step == .working)
                .keyboardShortcut(.defaultAction)
            case .done, .failed:
                Button("Done", action: onClose).buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    // MARK: Helpers

    private var conversationCount: String {
        let count = model.project.sessions.count
        return count == 1 ? "its conversation" : "its \(count) conversations"
    }

    private var folderName: String {
        model.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the folder"
    }

    private var codeTabInstalls: [Install] {
        services.installs.filter { $0.isDesktop && $0.codeTabRoot != nil }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Claude Code should work in."
        if let folder = model.folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.folder = url.path
        model.replan(services: services)
    }
}
