import CoworkKit
import SwiftUI

struct OtherMacRequest: Identifiable {
    let backup: URL
    /// The Mac a newer backup is for, when it's one already opened.
    var name: String?
    var folder: URL?
    var id: String { backup.path }
}

/// Opening another Mac's backup: its password, and what to call that Mac.
struct OtherMacSheet: View {
    @Environment(AppServices.self) private var services
    let request: OtherMacRequest
    let onClose: () -> Void
    @State private var name = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: "laptopcomputer", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Another Mac's history").font(Theme.Font.title)
                    Text("The conversations that Mac kept join your timeline and search, marked as from it. They're read-only, and Claude's history tools don't see them.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                TextField("What to call that Mac", text: $name)
                    .textFieldStyle(.roundedBorder)
                SecureField("The backup's password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { open() }
                if let failure {
                    Text(failure).font(Theme.Font.callout).foregroundStyle(Theme.attention)
                }
            }
            HStack {
                Button("Cancel") { onClose() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Open") { open() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canOpen)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480)
        .onAppear { name = request.name ?? "My other Mac" }
    }

    private var canOpen: Bool {
        !working && !password.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func open() {
        // Return in the password field gets here without the button, so it checks the same.
        guard canOpen else { return }
        working = true
        failure = nil
        let backup = request.backup, password = password, name = name.trimmingCharacters(in: .whitespaces)
        let folder = request.folder
        let paths = services.snapshot.paths
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                Result { try OtherMacs.open(backup, password: password, name: name, replacing: folder, paths: paths) }
            }.value
            working = false
            switch result {
            case .success(let count):
                services.notice = count == 0 ? "That backup has no kept conversations to show."
                    : "Opened \(count) conversation\(count == 1 ? "" : "s") from \(name)."
                services.refresh()
                onClose()
            case .failure(let error):
                failure = (error as? Backup.Failure)?.description ?? String(describing: error)
            }
        }
    }
}
