import CoworkKit
import SwiftUI

/// Upkeep, on one calm page: everything Claude keeps on this Mac and how Better Claude looks
/// after it. Each row says its state in words; only something that needs you is orange, and
/// then only its words.
struct ThisMacPage: View {
    @Environment(AppServices.self) private var services
    @AppStorage(BackupSheet.lastBackupKey) private var lastBackup: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "This Mac", subtitle: "Everything Claude keeps here, and how Better Claude looks after it.")

                GroupLabel(title: "Conversations")
                RowGroup(inset: 44) {
                    link("Kept", symbol: "archivebox", value: keptValue, to: .kept)
                    link("History", symbol: "clock.arrow.circlepath", value: "Everything Better Claude changed, with Undo", to: .history)
                }

                GroupLabel(title: "Safety")
                RowGroup(inset: 44) {
                    GroupRow(title: "Backups", detail: "Encrypted, in one file you choose where to keep") {
                        symbol("lock")
                    } trailing: {
                        Text(lastBackup > 0
                             ? Date(timeIntervalSince1970: lastBackup).formatted(.relative(presentation: .named)).capitalizedFirst
                             : "Not backed up yet")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                        Button("Back Up…") {
                            services.destination = .kept
                            services.pendingBackupSheet = true
                        }
                        .buttonStyle(.bordered)
                    }
                    Button { services.destination = .secrets } label: {
                        GroupRow(title: "Secrets", detail: "Keys and tokens pasted into conversations") {
                            symbol("key")
                        } trailing: {
                            secretsValue
                            RowChevron()
                        }
                    }
                    .buttonStyle(.plain)
                    GroupRow(title: "Other Macs", detail: "Read another Mac's backup here, without changing anything") {
                        symbol("laptopcomputer")
                    } trailing: {
                        Button("Open a Backup…") { services.openOtherMac() }.buttonStyle(.bordered)
                    }
                }

                GroupLabel(title: "Space and memory")
                RowGroup(inset: 44) {
                    link("Storage", symbol: "internaldrive", value: "What Claude keeps here, and what can go", to: .storage)
                    link("Memory", symbol: "brain", value: "CLAUDE.md and memory, for every project", to: .memory)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func link(_ title: String, symbol name: String, value: String, to destination: SidebarDestination) -> some View {
        Button { services.destination = destination } label: {
            GroupRow(title: title) {
                symbol(name)
            } trailing: {
                Text(value).font(Theme.Font.callout).foregroundStyle(.secondary).lineLimit(1)
                RowChevron()
            }
        }
        .buttonStyle(.plain)
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 18)
    }

    private var keptValue: String {
        let kept = services.kept.entries.count
        let onlyHere = services.kept.onlyHere.count
        guard kept > 0 else { return "Nothing kept yet" }
        return onlyHere > 0 ? "\(kept) conversations, \(onlyHere) only here" : "\(kept) conversations"
    }

    @ViewBuilder
    private var secretsValue: some View {
        let open = services.secrets.open.count
        if services.secrets.swept == nil && services.secrets.findings.isEmpty {
            Text("Not looked yet").font(Theme.Font.callout).foregroundStyle(.secondary)
        } else if open > 0 {
            Text(open == 1 ? "1 to rotate" : "\(open) to rotate")
                .font(Theme.Font.callout.weight(.semibold))
                .foregroundStyle(Theme.attention)
        } else {
            Text("Nothing to rotate").font(Theme.Font.callout).foregroundStyle(.secondary)
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
