import CoworkKit
import SwiftUI

struct ForkRequest: Identifiable {
    let messageID: String
    var id: String { messageID }
}

/// Starts a new conversation from part of the open one. The original is not changed.
struct ForkSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let request: ForkRequest

    @State private var title = ""
    @State private var working = false

    /// Where the fork will be listed: the same app's Code tab for a Code tab session.
    private var whereItGoes: String {
        if let conversation = services.reader.conversation, case .codeTab = conversation.origin {
            let app = services.install(for: conversation)?.name ?? "Claude"
            return "The original isn't changed. The fork is listed beside it in \(app)'s Code tab, and you can undo it from History. If \(app) is open, it may need reopening to show it."
        }
        return "The original isn't changed. Claude Code lists the fork beside it, and you can undo it from History."
    }

    var body: some View {
        let reader = services.reader
        let kept = reader.messagesKept(upTo: request.messageID)
        let total = reader.readable?.messageCount ?? kept
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fork from here").font(Theme.Font.title)
                    Text(kept == total
                         ? "A new conversation with all \(total) messages."
                         : kept == 1 ? "A new conversation with just the first message."
                         : "A new conversation with the first \(kept) of \(total) messages.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(Theme.Font.callout).foregroundStyle(.secondary)
                TextField("Name", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            Text(whereItGoes)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { services.forking = nil }
                    .quietAction()
                    .keyboardShortcut(.cancelAction)
                Button {
                    working = true
                    Task { await services.fork(request, title: title) }
                } label: {
                    if working { ProgressView().controlSize(.small).tint(.white) } else { Text("Fork") }
                }
                .prominentAction()
                .frame(minWidth: 96)
                .disabled(working)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            title = "\(reader.conversation?.title ?? "Conversation") (fork)"
        }
    }
}
