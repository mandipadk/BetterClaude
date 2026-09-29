import CoworkKit
import SwiftUI

/// On an install's page: whether this Claude can search your past conversations, and whose.
struct RecallSection: View {
    @Environment(AppServices.self) private var services
    let install: Install

    var body: some View {
        let recall = services.recall
        let snapshot = services.snapshot
        let own = snapshot.account(of: install)
        let others = snapshot.knownAccounts.filter { $0.id != own?.id }
        DetailSection(title: "Your history, for Claude",
                      subtitle: "Lets this Claude look up your past conversations when you mention earlier work, and quote what was said. It reads Better Claude's index on this Mac; nothing leaves it.") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.s) {
                    ExplainedToggle(title: "Let \(install.name) search your history",
                                    detail: detail(connected: recall.isConnected(install)),
                                    isOn: Binding(get: { recall.isConnected(install) },
                                                  set: { recall.setConnected($0, install: install, snapshot: snapshot) }))
                    if recall.busy.contains(install.id) { ProgressView().controlSize(.small) }
                }
                if recall.isConnected(install), let own {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        FactRow(label: "It can read", value: own.displayName, labelWidth: 110)
                        ForEach(others) { other in
                            ExplainedToggle(
                                title: "Also \(other.displayName)",
                                detail: other.id == ClaudeAccount.codex.id
                                    ? "Your Codex sessions on this Mac."
                                    : "Another account's conversations. Opening this doesn't let that account's Claude read this one's.",
                                isOn: Binding(get: { recall.isOpen(from: own.id, to: other.id) },
                                              set: { recall.setDoor(from: own.id, to: other.id, open: $0) }))
                        }
                    }
                }
            }
        }
        .alert("Couldn't change it",
               isPresented: Binding(get: { recall.errorMessage != nil }, set: { if !$0 { recall.errorMessage = nil } })) {
            Button("OK") { recall.errorMessage = nil }
        } message: {
            Text(recall.errorMessage ?? "")
        }
    }

    private func detail(connected: Bool) -> String {
        switch install.kind {
        case .claudeCode:
            return "Adds Better Claude to Claude Code's tools for every project. Turning it off takes it out again."
        default:
            return connected && services.isRunning(install)
                ? "Quit and reopen \(install.name) to start using it."
                : "Adds Better Claude to \(install.name)'s tools, from the next time it opens. Turning it off takes it out again."
        }
    }
}
