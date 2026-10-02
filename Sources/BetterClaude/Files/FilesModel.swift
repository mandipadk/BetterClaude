import CoworkKit
import Foundation
import Observation

/// Files Claude changed, and the history of the one being looked at.
@MainActor
@Observable
final class FilesModel {
    private(set) var files: [TouchedFile] = []
    var filter = "" {
        didSet { if filter != oldValue { reload() } }
    }
    var selectedPath: String? {
        didSet { if selectedPath != oldValue { loadSelected() } }
    }
    private(set) var history: FileHistory?
    private(set) var commits: [CommitLink] = []
    /// The saved version being compared with the file as it is now.
    var selectedVersionID: String? {
        didSet { if selectedVersionID != oldValue { loadDiff() } }
    }
    private(set) var diff: LineDiff?
    private(set) var diffNote: String?
    var errorMessage: String?
    var lastRestore: ImportReceipt?

    private weak var services: AppServices?
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    func attach(_ services: AppServices) {
        self.services = services
    }

    func reload() {
        guard let index = services?.index.index else { return }
        let filter = filter.trimmingCharacters(in: .whitespaces)
        listTask?.cancel()
        listTask = Task {
            let found = (try? await FileProvenance.recentFiles(index: index, matching: filter)) ?? []
            guard !Task.isCancelled else { return }
            files = found
            if selectedPath == nil { selectedPath = found.first?.path }
        }
    }

    private func loadSelected() {
        history = nil
        commits = []
        diff = nil
        selectedVersionID = nil
        guard let path = selectedPath, let index = services?.index.index else { return }
        let paths = services?.snapshot.paths ?? .current
        detailTask?.cancel()
        detailTask = Task {
            let found = try? await FileProvenance.history(of: path, index: index, paths: paths)
            guard !Task.isCancelled, selectedPath == path else { return }
            history = found
            selectedVersionID = found?.versions.last?.id
            let linked = (try? await CommitLinker.commits(touching: path, index: index)) ?? []
            guard !Task.isCancelled, selectedPath == path else { return }
            commits = linked
        }
    }

    var selectedVersion: FileHistory.SavedVersion? {
        history?.versions.first { $0.id == selectedVersionID }
    }

    private func loadDiff() {
        diff = nil
        diffNote = nil
        guard let version = selectedVersion, let path = selectedPath else { return }
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (LineDiff?, String?) in
                let now = try? String(contentsOfFile: path, encoding: .utf8)
                if version.didNotExist {
                    guard let now else { return (nil, "The file didn't exist then, and doesn't now.") }
                    return (LineDiff(old: "", new: now), nil)
                }
                guard let copy = version.copy else {
                    return (nil, "Claude Code deleted this version's copy before Better Claude could keep it.")
                }
                guard let then = try? String(contentsOf: copy, encoding: .utf8) else {
                    return (nil, "This version isn't text, so there's nothing to compare line by line.")
                }
                guard let now else { return (LineDiff(old: then, new: ""), "The file has since been deleted.") }
                return (LineDiff(old: then, new: now), nil)
            }.value
            guard selectedVersionID == version.id else { return }
            diff = result.0
            diffNote = result.1
        }
    }

    func restore(_ version: FileHistory.SavedVersion) {
        guard let path = selectedPath else { return }
        let paths = services?.snapshot.paths ?? .current
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try FileProvenance.restore(version, to: path, paths: paths) }
            }.value
            switch result {
            case .success(let receipt):
                lastRestore = receipt
                loadDiff()
            case .failure(let error):
                errorMessage = String(describing: error)
            }
        }
    }

    func undoLastRestore() {
        guard let receipt = lastRestore else { return }
        lastRestore = nil
        Task {
            let result = await Task.detached { Result { try Undo.revertAndRecord(receipt) } }.value
            switch result {
            case .success(let outcome):
                if let kept = outcome.leftInPlace.first {
                    errorMessage = "The file wasn't put back: \(kept.reason)."
                }
            case .failure(let error):
                errorMessage = "Couldn't undo it: \(ContinueModel.explain(error))"
            }
            loadDiff()
        }
    }
}
