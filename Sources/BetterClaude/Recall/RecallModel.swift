import CoworkKit
import Foundation
import Observation

/// Which Claudes can search your history, and whose history each may read.
@MainActor
@Observable
final class RecallModel {
    /// Install ids whose Claude has the history server.
    private(set) var connected: Set<String> = []
    private(set) var busy: Set<String> = []
    private(set) var access = RecallAccess()
    var errorMessage: String?

    private let paths: HostPaths

    init(paths: HostPaths) {
        self.paths = paths
        access = RecallAccess.load(paths: paths)
    }

    /// The server inside this app bundle.
    var serverURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bc-recall")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func refresh(_ snapshot: CatalogSnapshot) {
        let paths = paths
        let installs = snapshot.installs
        Task {
            let found = await Task.detached(priority: .utility) {
                Set(installs.filter { install in
                    RecallConnection.target(for: install, paths: paths).map { RecallConnection.isConnected($0, paths: paths) } ?? false
                }.map(\.id))
            }.value
            connected = found
            recordAccounts(snapshot)
            repairMoved(snapshot)
        }
    }

    /// Keeps the map of Desktop data folders to accounts current, which the server uses to
    /// tell which Claude started it.
    private func recordAccounts(_ snapshot: CatalogSnapshot) {
        var map: [String: String] = [:]
        for install in snapshot.installs where install.isDesktop {
            if let account = snapshot.account(of: install) {
                map[install.dataRoot.standardizedFileURL.path] = account.id
            }
        }
        guard map != (access.installAccounts ?? [:]) else { return }
        access.installAccounts = map
        try? access.save(paths: paths)
    }

    /// If Better Claude moved since a Claude was connected, point that Claude at where it is now.
    private func repairMoved(_ snapshot: CatalogSnapshot) {
        guard let server = serverURL, !paths.isFixture else { return }
        for install in snapshot.installs where connected.contains(install.id) {
            guard let target = RecallConnection.target(for: install, paths: paths),
                  let registered = RecallConnection.registration(target, paths: paths),
                  registered.command != server.path,
                  let account = snapshot.account(of: install)?.id else { continue }
            if FileManager.default.isExecutableFile(atPath: registered.command) { continue }
            try? RecallConnection.connect(target, server: server, account: account, paths: paths)
        }
    }

    func isConnected(_ install: Install) -> Bool { connected.contains(install.id) }

    func setConnected(_ on: Bool, install: Install, snapshot: CatalogSnapshot) {
        guard let target = RecallConnection.target(for: install, paths: paths) else { return }
        guard let server = serverURL else {
            errorMessage = "This copy of Better Claude doesn't include its history server. Install Better Claude from its disk image and try again."
            return
        }
        guard let account = snapshot.account(of: install)?.id else {
            errorMessage = "\(install.name) isn't signed in, so Better Claude can't tell whose history it may read."
            return
        }
        if case .claudeCode = target, paths.isFixture {
            errorMessage = "Claude Code isn't changed while Better Claude is reading a sample Mac."
            return
        }
        busy.insert(install.id)
        let paths = paths
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    if on {
                        try RecallConnection.connect(target, server: server, account: account, paths: paths)
                    } else {
                        try RecallConnection.disconnect(target, paths: paths)
                    }
                }
            }.value
            busy.remove(install.id)
            switch result {
            case .success:
                if on { connected.insert(install.id) } else { connected.remove(install.id) }
            case .failure(let error):
                errorMessage = String(describing: error)
            }
        }
    }

    func isOpen(from consumer: String, to other: String) -> Bool {
        access.isOpen(from: consumer, to: other)
    }

    func setDoor(from consumer: String, to other: String, open: Bool) {
        access.setDoor(from: consumer, to: other, open: open)
        do {
            try access.save(paths: paths)
        } catch {
            errorMessage = "Couldn't save who can read what: \(error.localizedDescription)"
            access = RecallAccess.load(paths: paths)
        }
    }
}
