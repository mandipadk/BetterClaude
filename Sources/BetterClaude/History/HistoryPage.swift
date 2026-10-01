import CoworkKit
import Observation
import SwiftUI

/// Everything Better Claude has written, each with a way to take it back.
@MainActor
@Observable
final class HistoryModel {
    private(set) var receipts: [ImportReceipt] = []
    private(set) var loaded = false
    /// What the last undo of each receipt left behind, by receipt id.
    private(set) var leftBehind: [String: Int] = [:]
    var errorMessage: String?

    func load() {
        Task {
            let found = await Task.detached(priority: .userInitiated) { (try? Undo.receipts()) ?? [] }.value
            receipts = found
            loaded = true
        }
    }

    func undo(_ receipt: ImportReceipt, then done: @escaping () -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Undo.revertAndRecord(receipt) }
            }.value
            switch result {
            case .success(let outcome):
                leftBehind[receipt.id] = outcome.skipped.filter { $0.reason != "already absent" }.count
            case .failure(let error):
                errorMessage = "Couldn't undo it: \(ContinueModel.explain(error))"
            }
            load()
            done()
        }
    }
}

struct HistoryPage: View {
    @Environment(AppServices.self) private var services
    @State private var model = HistoryModel()
    @State private var confirming: ImportReceipt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Activity").font(Theme.Font.display)
                    Text("Everything Better Claude has changed on this Mac, and a way to take each back.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, Theme.Space.xl)

                if model.loaded && model.receipts.isEmpty {
                    DetailSection(title: "Nothing yet") {
                        Text("When you continue a conversation somewhere else or fork one, it's listed here.")
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                    }
                }

                let interrupted = model.receipts.filter { !$0.completed && $0.revertedAt == nil }
                if !interrupted.isEmpty {
                    DetailSection(title: "Didn't finish",
                                  subtitle: "These stopped partway, usually because Better Claude or the Mac quit. Undo removes what they wrote.") {
                        rows(interrupted)
                    }
                }

                let finished = model.receipts.filter { $0.completed || $0.revertedAt != nil }
                if !finished.isEmpty {
                    DetailSection(title: "Changes") {
                        rows(finished)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil },
                                                               set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { receipt in
            Button("Undo", role: .destructive) {
                model.undo(receipt) { services.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { receipt in
            Text("Removes what it added to \(HistoryRow.place(of: receipt)). Anything changed since is left alone.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var confirmTitle: String {
        "Undo “\(confirming?.title ?? "this change")”?"
    }

    private func rows(_ receipts: [ImportReceipt]) -> some View {
        VStack(spacing: 2) {
            ForEach(receipts, id: \.id) { receipt in
                HistoryRow(receipt: receipt, leftBehind: model.leftBehind[receipt.id]) {
                    confirming = receipt
                }
            }
        }
        .padding(.horizontal, -8)
    }
}

struct HistoryRow: View {
    let receipt: ImportReceipt
    let leftBehind: Int?
    let onUndo: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(receipt.title ?? "A conversation")
                    .font(Theme.Font.body)
                    .lineLimit(1)
                Text(description)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            if receipt.revertedAt != nil {
                Text(leftBehind.map { $0 > 0 ? "Undone, \($0) changed files kept" : "Undone" } ?? "Undone")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button("Undo…", action: onUndo)
                    .buttonStyle(.secondary)
                    .opacity(hovering ? 1 : 0.8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Theme.subtleFill : .clear, in: .rect(cornerRadius: Theme.Radius.control))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch receipt.direction {
        case .branch: return "arrow.triangle.branch"
        case .fileRestore: return "clock.arrow.circlepath"
        case .skill: return "wand.and.stars"
        case .fleet: return "square.on.square"
        case .memoryEdit: return "text.badge.plus"
        default: return "arrow.right.circle"
        }
    }

    private var description: String {
        let when = receipt.timestamp.listStamp.lowercasedIfWord
        switch receipt.direction {
        case .branch: return "Forked in \(Self.place(of: receipt)), \(when)"
        case .fileRestore: return "An earlier version put back, \(when)"
        case .skill: return "Added to Claude Code's skills, \(when)"
        case .fleet: return "Copied into \(receipt.destination), \(when)"
        case .restore: return "Put back where Claude Code finds it, \(when)"
        case .memoryEdit: return "Added to \(URL(fileURLWithPath: receipt.destination).lastPathComponent), \(when)"
        default: return "Copied into \(Self.place(of: receipt)), \(when)"
        }
    }

    /// Where a receipt's change landed, in words: the install's name, or Claude Code.
    static func place(of receipt: ImportReceipt) -> String {
        let first = receipt.destination.components(separatedBy: " · ").first ?? receipt.destination
        return first.isEmpty ? "Claude" : first
    }
}

private extension String {
    /// "Yesterday" reads as "yesterday" mid-sentence; dates and times are left alone.
    var lowercasedIfWord: String {
        guard let first = first, first.isLetter, !contains(where: \.isNumber) else { return self }
        return lowercased()
    }
}
