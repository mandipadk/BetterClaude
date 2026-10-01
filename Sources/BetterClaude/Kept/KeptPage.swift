import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Keeps Claude Code conversations before Claude Code deletes them, and shows what's kept.
@MainActor
@Observable
final class KeptModel {
    private(set) var entries: [Vault.Entry] = []
    private(set) var footprint: Int64 = 0
    private(set) var period: TimeInterval = 30 * 86_400
    private(set) var isKeeping = false
    private(set) var loaded = false
    var errorMessage: String?

    func reload() {
        Task {
            let (entries, footprint, period) = await Task.detached(priority: .utility) {
                (Vault.entries(), Vault.footprint(), Vault.cleanupPeriod())
            }.value
            self.entries = entries.sorted { ($0.latest?.sourceModified ?? .distantPast) > ($1.latest?.sourceModified ?? .distantPast) }
            self.footprint = footprint
            self.period = period
            self.loaded = true
        }
    }

    /// Copies whatever changed since last time. Cheap when nothing did.
    func keep(_ conversations: [ConversationRef]) {
        guard !isKeeping else { return }
        isKeeping = true
        Task {
            _ = await Task.detached(priority: .utility) { Vault.keep(conversations) }.value
            isKeeping = false
            reload()
        }
    }

    func restore(_ entry: Vault.Entry, then done: @escaping () -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Vault.restore(entry) } }.value
            if case .failure(let error) = result {
                errorMessage = "Couldn't put it back: \(ContinueModel.explain(error))"
            }
            reload()
            done()
        }
    }

    var onlyHere: [Vault.Entry] { entries.filter { !$0.sourceExists } }

    func expiry(of entry: Vault.Entry) -> Date? {
        entry.sourceExists ? Vault.expiry(of: URL(fileURLWithPath: entry.sourcePath), period: period) : nil
    }

    /// A kept copy, as a conversation the reader can open.
    func conversation(for entry: Vault.Entry, fallbackInstall: String) -> ConversationRef? {
        guard let copy = Vault.latestCopy(of: entry), let latest = entry.latest else { return nil }
        let session = CCSessionRef(configDir: HostPaths.current.claudeCodeConfigDir,
                                   projectDir: copy.deletingLastPathComponent(),
                                   resolvedCwd: entry.projectPath ?? "", sessionId: entry.sessionId,
                                   transcriptURL: copy, title: entry.title, recordCount: 0,
                                   firstTimestamp: latest.sourceModified, lastTimestamp: latest.sourceModified,
                                   byteSize: latest.size)
        return ConversationRef(origin: .claudeCode(session), installID: entry.installID ?? fallbackInstall,
                               title: entry.title, lastActivity: latest.sourceModified,
                               projectPath: entry.projectPath, model: nil, bytes: latest.size,
                               isStarred: false, isArchived: false)
    }
}

struct KeptPage: View {
    @Environment(AppServices.self) private var services
    @AppStorage("keepAutomatically") private var keepAutomatically = true
    @State private var reading: ConversationRef?
    @State private var backup: BackupSheet.Mode?
    @AppStorage(BackupSheet.lastBackupKey) private var lastBackup: Double = 0
    @State private var puttingBack: KeptRowData?

    var body: some View {
        let kept = services.kept
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(kept).padding(.bottom, Theme.Space.xl)

                DetailSection(title: "Keeping") {
                    ExplainedToggle(
                        title: "Keep conversations automatically",
                        detail: "Each Claude Code conversation is copied here whenever it changes, while Better Claude is open, along with the versions of files Claude saved and its plans. Copies share space with the originals until Claude Code deletes those.",
                        isOn: $keepAutomatically)
                }

                DetailSection(title: "Backups",
                              subtitle: "Everything kept here, in one file encrypted with a password of your choosing. Keep it in iCloud Drive, or anywhere, and restore it on another Mac.") {
                    HStack(spacing: Theme.Space.s) {
                        Text(lastBackup > 0
                             ? "Last backed up \(Date(timeIntervalSince1970: lastBackup).formatted(.relative(presentation: .named)))."
                             : "Not backed up yet.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore…") { chooseBackup() }.buttonStyle(.bordered)
                        Button("Back Up…") { backup = .backUp }.buttonStyle(.borderedProminent)
                    }
                }

                let soon = expiringSoon
                if !soon.isEmpty {
                    DetailSection(title: "Deleted soon",
                                  subtitle: "Claude Code deletes these within a week. \(keepAutomatically ? "Copies are kept." : "Turn on keeping to save them.")") {
                        rows(soon.map { conversation in
                            KeptRowData(id: conversation.id, title: conversation.title,
                                        detail: expiryText(for: conversation), action: nil)
                        })
                    }
                }

                if !kept.onlyHere.isEmpty {
                    DetailSection(title: "Only here now",
                                  subtitle: "Claude Code has deleted these. Read them here, or put one back where Claude Code can resume it.") {
                        rows(kept.onlyHere.map { entry in
                            KeptRowData(id: entry.key, title: entry.title,
                                        detail: "Last used \(entry.latest?.sourceModified.listStamp.lowercasedIfWordLocal ?? "")",
                                        action: (entry, true))
                        })
                    }
                }

                let lost = goneForGood
                if !lost.isEmpty {
                    DetailSection(title: "Gone for good",
                                  subtitle: "Their messages were deleted before Better Claude could keep a copy. Only their titles remain.") {
                        rows(lost.map { conversation in
                            KeptRowData(id: conversation.id, title: conversation.title,
                                        detail: services.install(for: conversation)?.name ?? "", action: nil)
                        })
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            kept.reload()
            if services.debugBackupSheet { services.debugBackupSheet = false; backup = .backUp }
        }
        .sheet(item: $backup) { mode in
            BackupSheet(mode: mode) { backup = nil }
                .environment(services)
        }
        .sheet(item: $reading) { conversation in
            KeptReaderSheet(conversation: conversation) { reading = nil }
                .environment(services)
        }
        .confirmationDialog("Put “\(puttingBack?.title ?? "")” back?",
                            isPresented: Binding(get: { puttingBack != nil }, set: { if !$0 { puttingBack = nil } }),
                            titleVisibility: .visible, presenting: puttingBack) { row in
            Button("Put Back") {
                if let (entry, _) = row.action { services.kept.restore(entry) { services.refresh() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It goes back where Claude Code can resume it. You can undo this from History.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { kept.errorMessage != nil }, set: { if !$0 { kept.errorMessage = nil } })) {
            Button("OK") { kept.errorMessage = nil }
        } message: {
            Text(kept.errorMessage ?? "")
        }
    }

    private func header(_ kept: KeptModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kept").font(Theme.Font.display)
            Text("Claude Code deletes conversations \(days(kept.period)) days after they were last used. Better Claude keeps a copy, so you can still read them and put them back.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(kept.entries.count)")
                    .font(Theme.Font.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(kept.entries.count == 1 ? "conversation kept" : "conversations kept")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if kept.isKeeping {
                    ProgressView().controlSize(.small)
                    Text("Keeping…").font(Theme.Font.callout).foregroundStyle(.secondary)
                } else if kept.loaded {
                    Text("\(kept.footprint.fileSize) on disk")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.top, 8)
        }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Better Claude backup."
        panel.allowedContentTypes = [.init(filenameExtension: "aea") ?? .data]
        if let folder = Backup.iCloudFolder(paths: services.snapshot.paths) { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { backup = .restore(url) }
    }

    private var expiringSoon: [ConversationRef] {
        let period = services.kept.period
        let week = Date().addingTimeInterval(7 * 86_400)
        return services.snapshot.conversations.filter { conversation in
            guard let url = conversation.claudeCodeSession?.transcriptURL,
                  let expiry = Vault.expiry(of: url, period: period) else { return false }
            return expiry < week
        }
    }

    private var goneForGood: [ConversationRef] {
        let keptIDs = Set(services.kept.entries.map(\.sessionId))
        return services.snapshot.conversations.filter { $0.isTranscriptMissing && !keptIDs.contains($0.cliSessionId) }
    }

    private func expiryText(for conversation: ConversationRef) -> String {
        guard let url = conversation.claudeCodeSession?.transcriptURL,
              let expiry = Vault.expiry(of: url, period: services.kept.period) else { return "" }
        let days = Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0
        let when = days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days"
        let kept = services.kept.entries.contains { $0.sessionId == conversation.cliSessionId }
        return "Claude Code deletes it \(when)" + (kept ? ". A copy is kept." : ".")
    }

    private func days(_ period: TimeInterval) -> Int { Int((period / 86_400).rounded()) }

    struct KeptRowData: Identifiable {
        let id: String
        let title: String
        let detail: String
        let action: (Vault.Entry, Bool)?
    }

    private func rows(_ data: [KeptRowData]) -> some View {
        VStack(spacing: 2) {
            ForEach(data) { row in
                HStack(spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Theme.Font.body).lineLimit(1)
                        Text(row.detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: Theme.Space.m)
                    if let (entry, _) = row.action {
                        Button("Read") {
                            let fallback = services.installs.first { $0.kind == .claudeCode }?.id ?? ""
                            reading = services.kept.conversation(for: entry, fallbackInstall: fallback)
                        }
                        .buttonStyle(.bordered)
                        Button("Put Back…") { puttingBack = row }
                        .buttonStyle(.bordered)
                        .help("Put it back where Claude Code can resume it. You can undo this from History.")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, -8)
    }
}

/// A kept conversation, read in a sheet.
private struct KeptReaderSheet: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReaderView()
                .environment(\.readerActionsHidden, true)
            HStack {
                Label("A kept copy. Claude Code no longer has this conversation.", systemImage: "archivebox")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onClose).prominentAction().keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(width: 820, height: 660)
        .onAppear { services.reader.open(conversation, in: services.install(for: conversation)) }
        .onDisappear { services.selectedConversationID = nil; services.reader.close() }
    }
}

