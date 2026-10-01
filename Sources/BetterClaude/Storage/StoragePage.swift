import AppKit
import CoworkKit
import Observation
import SwiftUI

@MainActor
@Observable
final class StorageModel {
    private(set) var categories: [Storage.Category] = []
    private(set) var removals: [Storage.Removal] = []
    private(set) var isMeasuring = false
    private(set) var measuredGeneration: Int?
    var errorMessage: String?

    func measure(_ snapshot: CatalogSnapshot, generation: Int) {
        guard !isMeasuring, measuredGeneration != generation else { return }
        isMeasuring = true
        let pending = snapshot.installs.flatMap { install in
            Storage.categories(for: install, coworkConversations: snapshot.conversations
                .filter { $0.installID == install.id && $0.coworkSession != nil }.count)
        }
        if categories.isEmpty { categories = pending }
        Task {
            let measured = await withTaskGroup(of: Storage.Category.self) { group in
                for category in pending {
                    group.addTask(priority: .utility) { Storage.measure(category) }
                }
                var result: [Storage.Category] = []
                for await category in group { result.append(category) }
                return result
            }
            let order = Dictionary(uniqueKeysWithValues: pending.enumerated().map { ($1.id, $0) })
            categories = measured.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            removals = await Task.detached { Storage.removals() }.value
            isMeasuring = false
            measuredGeneration = generation
        }
    }

    func remove(_ category: Storage.Category, install: Install, isRunning: @escaping @Sendable () -> Bool,
                then done: @escaping () -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Storage.moveToTrash(category, install: install, isRunning: isRunning) }
            }.value
            if case .failure(let error) = result {
                errorMessage = "\(error)".prefix(1).uppercased() + "\(error)".dropFirst()
            }
            measuredGeneration = nil
            done()
        }
    }

    func putBack(_ removal: Storage.Removal, then done: @escaping () -> Void) {
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try Storage.putBack(removal) } }.value
            if case .failure(let error) = result { errorMessage = "Couldn't put it back: \(error)" }
            measuredGeneration = nil
            done()
        }
    }

    var total: Int64 { categories.reduce(0) { $0 + $1.bytes } }
    var freeable: Int64 { categories.filter { $0.safety != .yours }.reduce(0) { $0 + $1.bytes } }
    var regenerable: Int64 { categories.filter { $0.safety == .regenerable }.reduce(0) { $0 + $1.bytes } }
}

struct StoragePage: View {
    @Environment(AppServices.self) private var services
    @State private var confirming: Storage.Category?

    var body: some View {
        let storage = services.storage
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(storage).padding(.bottom, Theme.Space.xl)

                ForEach(services.installs) { install in
                    let categories = storage.categories.filter { $0.installID == install.id && $0.bytes > 0 }
                    if !categories.isEmpty {
                        installSection(install, categories: categories)
                    }
                }

                let recent = storage.removals.filter { !$0.putBack }.prefix(5)
                if !recent.isEmpty {
                    DetailSection(title: "Moved to the Trash",
                                  subtitle: "Put any of these back while they're still in the Trash.") {
                        VStack(spacing: 2) {
                            ForEach(Array(recent)) { removal in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(removal.title) from \(removal.installName)").font(Theme.Font.body)
                                        Text("\(removal.bytes.fileSize), \(removal.date.listStamp)")
                                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Put Back") { storage.putBack(removal) { services.refresh() } }
                                        .buttonStyle(.bordered)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: services.generation) {
            if services.hasLoaded { storage.measure(services.snapshot, generation: services.generation) }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { category in
            Button("Move to Trash") {
                guard let install = services.install(category.installID) else { return }
                let running = services.isRunning(install)
                storage.remove(category, install: install, isRunning: { running }) { services.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { category in
            Text(category.safety == .regenerable
                 ? "\(category.explanation) It goes to the Trash, so you can put it back until you empty it."
                 : "It goes to the Trash, so you can put it back until you empty it.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { storage.errorMessage != nil }, set: { if !$0 { storage.errorMessage = nil } })) {
            Button("OK") { storage.errorMessage = nil }
        } message: {
            Text(storage.errorMessage ?? "")
        }
    }

    private var confirmTitle: String {
        guard let category = confirming else { return "" }
        let install = services.install(category.installID)?.name ?? "Claude"
        return "Move \(category.title.lowercased()) from \(install) to the Trash?"
    }

    private func header(_ storage: StorageModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Storage").font(Theme.Font.display)
            Text("What Claude keeps on this Mac, and what can safely go. Nothing here is ever deleted outright: it goes to the Trash.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(storage.total.fileSize)
                    .font(Theme.Font.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("used by Claude").font(Theme.Font.callout).foregroundStyle(.secondary)
                Spacer()
                if storage.isMeasuring { ProgressView().controlSize(.small) }
            }
            .padding(.top, 8)
            UsageBar(yours: storage.total - storage.freeable, regenerable: storage.regenerable,
                     reclaimable: storage.freeable - storage.regenerable)
            HStack(alignment: .top, spacing: 22) {
                keyed(Theme.accentFill, "Can be freed", storage.freeable - storage.regenerable)
                keyed(Color(nsColor: .secondaryLabelColor), "Downloaded again if needed", storage.regenerable)
                keyed(Color(nsColor: .tertiaryLabelColor), "Your conversations and tools", storage.total - storage.freeable)
            }
            .padding(.top, 4)
        }
        .animation(Theme.Motion.fade, value: storage.total)
    }

    /// A fact keyed to its part of the bar by a short stroke of the same color.
    private func keyed(_ color: Color, _ label: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(color).frame(width: 18, height: 4)
            Fact(label: label) { Text(bytes > 0 ? bytes.fileSize : "Nothing") }
        }
    }

    private func installSection(_ install: Install, categories: [Storage.Category]) -> some View {
        let running = services.isRunning(install)
        return DetailSection(title: install.name,
                             subtitle: running && categories.contains { $0.safety != .yours }
                                 ? "\(install.name) is open. Quit it to free space here." : nil) {
            VStack(spacing: 2) {
                ForEach(categories) { category in
                    HStack(alignment: .center, spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title).font(Theme.Font.body)
                            Text(category.explanation)
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Space.m)
                        Text(category.bytes.fileSize + (category.isApproximate ? "+" : ""))
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if category.safety != .yours {
                            Button("Move to Trash") { confirming = category }
                                .buttonStyle(.bordered)
                                .disabled(running)
                        } else {
                            Color.clear.frame(width: 118, height: 1)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

/// A capsule bar split by how safe each part is to remove.
struct UsageBar: View {
    let yours: Int64
    let regenerable: Int64
    let reclaimable: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(yours + regenerable + reclaimable), 1)
            HStack(spacing: 2) {
                segment(Double(reclaimable) / total * geometry.size.width, Theme.accentFill)
                segment(Double(regenerable) / total * geometry.size.width, Color(nsColor: .secondaryLabelColor))
                segment(Double(yours) / total * geometry.size.width, Color(nsColor: .tertiaryLabelColor))
            }
        }
        .frame(height: 8)
        .frame(maxWidth: 520)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private func segment(_ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: width > 0 ? max(width, 3) : 0)
    }
}
