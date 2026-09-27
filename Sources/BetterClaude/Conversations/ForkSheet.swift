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

    var body: some View {
        let reader = services.reader
        let kept = reader.messagesKept(upTo: request.messageID)
        let total = reader.readable?.messageCount ?? kept
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent.opacity(0.12), in: .rect(cornerRadius: Theme.Radius.tile))
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
            Text("The original isn't changed. Claude Code lists the fork beside it, and you can undo it from History.")
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
        .tint(Theme.accent)
        .onAppear {
            title = "\(reader.conversation?.title ?? "Conversation") (fork)"
        }
    }
}
