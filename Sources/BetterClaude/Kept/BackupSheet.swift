import AppKit
import CoworkKit
import SwiftUI

/// Backing up everything Better Claude keeps to one encrypted file, or restoring from one.
struct BackupSheet: View {
    enum Mode: Identifiable {
        case backUp
        case restore(URL)
        var id: String {
            switch self {
            case .backUp: return "backup"
            case .restore(let url): return url.path
            }
        }
    }

    @Environment(AppServices.self) private var services
    let mode: Mode
    let onClose: () -> Void

    @State private var password = ""
    @State private var confirmation = ""
    @State private var destination: URL?
    @State private var working = false
    @State private var result: String?
    @State private var failure: String?

    /// Seconds since 1970, as a Double, so `@AppStorage` can read it.
    static let lastBackupKey = "lastBackupDate"

    /// Versions before 0.28 saved a `Date` here, which `@AppStorage` can't read as a number,
    /// so the Kept page always said "Not backed up yet". Rewrites it as a number once.
    static func migrateLastBackup(_ defaults: UserDefaults = .standard) {
        if let date = defaults.object(forKey: lastBackupKey) as? Date {
            defaults.set(date.timeIntervalSince1970, forKey: lastBackupKey)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(spacing: Theme.Space.m) {
                GlyphTile(systemImage: isBackUp ? "lock.doc" : "arrow.down.doc", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBackUp ? "Back up" : "Restore from a backup").font(Theme.Font.title)
                    Text(isBackUp
                         ? "Kept conversations, saved file versions and plans, imported claude.ai conversations, and who may read what, in one encrypted file."
                         : "Adds what the backup holds and this Mac doesn't. Nothing here is replaced.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let result {
                Text(result).font(Theme.Font.body)
                HStack { Spacer(); Button("Done") { onClose() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if isBackUp {
                        SecureField("Password again", text: $confirmation)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text(hint)
                        .font(Theme.Font.callout)
                        .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.failure))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isBackUp {
                    HStack {
                        FactRow(label: "Saves to", value: destinationLabel, labelWidth: 70)
                        Button("Change…") { chooseDestination() }.buttonStyle(.bordered)
                    }
                }
                HStack {
                    Button("Cancel") { onClose() }.buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button(isBackUp ? "Back Up" : "Restore") { run() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canRun || working)
                }
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 520)
        .onAppear {
            if destination == nil, let folder = Backup.iCloudFolder(paths: services.snapshot.paths) {
                destination = folder.appendingPathComponent(Backup.suggestedName())
            }
        }
    }

    private var isBackUp: Bool {
        if case .backUp = mode { return true }
        return false
    }

    private var canRun: Bool {
        guard password.count >= Backup.minimumPasswordLength else { return false }
        return isBackUp ? (password == confirmation && destination != nil) : true
    }

    private var hint: String {
        if let failure { return failure }
        if isBackUp {
            if password.count < Backup.minimumPasswordLength {
                return "At least \(Backup.minimumPasswordLength) characters; a few words together works well. It isn't stored anywhere, and without it the backup can't be opened, so keep it somewhere safe."
            }
            return confirmation.isEmpty || password == confirmation ? "It isn't stored anywhere; keep it somewhere safe." : "The two passwords don't match."
        }
        return "The password the backup was made with."
    }

    private var destinationLabel: String {
        guard let destination else { return "Choose where" }
        if let folder = Backup.iCloudFolder(paths: services.snapshot.paths),
           destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            return "iCloud Drive, Better Claude Backups"
        }
        return services.snapshot.paths.abbreviating(destination.path)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Backup.suggestedName()
        panel.allowedContentTypes = [.init(filenameExtension: "aea") ?? .data]
        if let current = destination?.deletingLastPathComponent() { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    private func run() {
        failure = nil
        working = true
        let paths = services.snapshot.paths
        let password = password
        let mode = mode
        let destination = destination
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<Backup.Report, Error> in
                Result {
                    switch mode {
                    case .backUp: return try Backup.create(at: destination!, password: password, paths: paths)
                    case .restore(let url): return try Backup.restore(from: url, password: password, paths: paths)
                    }
                }
            }.value
            working = false
            switch outcome {
            case .success(let report):
                let size = report.bytes.fileSize
                if isBackUp {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastBackupKey)
                    result = "Backed up \(report.files) files, \(size) before compression, to \(destinationLabel)."
                } else {
                    result = report.files == 0
                        ? "Everything in that backup is already on this Mac."
                        : "Restored \(report.files) files, \(size), that this Mac didn't have."
                    services.kept.reload()
                    services.refresh()
                }
            case .failure(let error):
                failure = String(describing: error)
            }
        }
    }
}
