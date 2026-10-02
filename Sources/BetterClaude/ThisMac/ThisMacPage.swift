import CoworkKit
import SwiftUI

/// Upkeep, on one calm page: everything Claude keeps on this Mac and how Better Claude looks
/// after it. Each row says its state in words; only something that needs you is orange, and
/// then only its words.
struct ThisMacPage: View {
    @Environment(AppServices.self) private var services
    @AppStorage(BackupSheet.lastBackupKey) private var lastBackup: Double = 0
    @State private var lastChange: ImportReceipt?
    @State private var checkingCounts = false

    var body: some View {
        page.sheet(isPresented: $checkingCounts) { AccuracySheet().environment(services) }
            #if DEBUG
            .onAppear {
                if UserDefaults.standard.bool(forKey: "debugOpenAccuracy") {
                    UserDefaults.standard.removeObject(forKey: "debugOpenAccuracy")
                    checkingCounts = true
                }
            }
            #endif
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "This Mac", subtitle: "Everything Claude keeps here, and how Better Claude looks after it.")

                GroupLabel(title: "Conversations")
                RowGroup(inset: 44) {
                    link("Kept", symbol: "archivebox", value: keptValue, to: .kept)
                    link("Activity", symbol: "clock.arrow.circlepath",
                         value: lastChange.map { "\($0.title ?? "A change"), \($0.timestamp.listStamp.lowercasedIfWordLocal)" }
                            ?? "Everything Better Claude changed, with Undo", to: .history)
                    Button { checkingCounts = true } label: {
                        GroupRow(title: "How it's counted", detail: "Every count checked against what's on this Mac") {
                            symbol("checklist")
                        } trailing: {
                            RowChevron()
                        }
                    }
                    .buttonStyle(.plain)
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
                        .buttonStyle(.secondary)
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
                        Button("Open a Backup…") { services.openOtherMac() }.buttonStyle(.secondary)
                    }
                }

                GroupLabel(title: "Space")
                RowGroup(inset: 44) {
                    Button { services.destination = .storage } label: {
                        HStack(spacing: Theme.Space.m) {
                            symbol("internaldrive")
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Storage").font(Theme.Font.bodyMedium)
                                if let share = reclaimableShare {
                                    ThinMeter(value: share).frame(maxWidth: 290)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            storageValue
                            RowChevron()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: services.generation) {
            if services.secrets.swept == nil, !services.secrets.sweeping { services.secrets.sweep(services.snapshot) }
            if services.storage.categories.isEmpty, !services.storage.isMeasuring {
                services.storage.measure(services.snapshot, generation: services.generation)
            }
            lastChange = await Task.detached { (try? Undo.receipts())?.filter(\.completed).max { $0.timestamp < $1.timestamp } }.value
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

    @ViewBuilder
    /// How much of what Claude keeps here could go, which is what the meter shows.
    private var reclaimableShare: Double? {
        let categories = services.storage.categories
        let total = categories.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return nil }
        return Double(categories.filter { $0.safety == .reclaimable }.reduce(Int64(0)) { $0 + $1.bytes }) / Double(total)
    }

    @ViewBuilder
    private var storageValue: some View {
        let categories = services.storage.categories
        let total = categories.reduce(Int64(0)) { $0 + $1.bytes }
        let free = categories.filter { $0.safety == .reclaimable }.reduce(Int64(0)) { $0 + $1.bytes }
        if total > 0 {
            Text("\(total.fileSize), \(free.fileSize) can go").font(Theme.Font.callout).foregroundStyle(.secondary)
        } else {
            Text("What Claude keeps here, and what can go").font(Theme.Font.callout).foregroundStyle(.secondary)
        }
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
