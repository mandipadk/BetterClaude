import CoworkKit
import SwiftUI

/// Two installs to compare.
struct InstallComparison: Identifiable {
    let left: Install
    let right: Install
    var id: String { left.id + "|" + right.id }
}

/// What one install has that the other doesn't: skills, servers, plugins and the rest.
struct CompareSheet: View {
    @Environment(AppServices.self) private var services
    let pair: InstallComparison

    @State private var comparison: ConfigComparison?
    @State private var onlyDifferences = true
    @State private var copying: (name: String, from: Install, to: Install)?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let comparison {
                content(comparison)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                HStack(spacing: 8) {
                    Toggle("Only differences", isOn: $onlyDifferences)
                        .labelsHidden()
                        .toggleStyle(AccentSwitchStyle())
                    Text("Only differences").font(Theme.Font.body)
                }
                Spacer()
                Button("Done") { services.comparing = nil }
                    .prominentAction()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        }
        .frame(width: 760, height: 620)
        .tint(Theme.accent)
        .task { await load() }
        .confirmationDialog("Copy this server?", isPresented: Binding(get: { copying != nil }, set: { if !$0 { copying = nil } }),
                            presenting: copying) { item in
            Button("Copy into \(item.to.name)") { copy(item.name, from: item.from, to: item.to) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.name) is copied into \(item.to.name) as \(item.from.name) has it, including any keys in its settings.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.l) {
            end(pair.left)
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            end(pair.right)
            Spacer()
            if let summary = comparison?.summary {
                HStack(spacing: 22) {
                    Fact(label: "Only in \(pair.left.name)") { Text("\(summary.onlyLeft)") }
                    Fact(label: "Only in \(pair.right.name)") { Text("\(summary.onlyRight)") }
                    Fact(label: "Different") { Text("\(summary.different)") }
                    Fact(label: "Same") { Text("\(summary.same)") }
                }
            }
        }
        .padding(20)
    }

    private func end(_ install: Install) -> some View {
        HStack(spacing: 8) {
            InstallIcon(install: install, size: 36)
            Text(install.name).font(Theme.Font.headline).lineLimit(1)
        }
    }

    private func content(_ comparison: ConfigComparison) -> some View {
        let rows = comparison.rows.filter { !onlyDifferences || $0.status != .same }
        let kinds = Set(rows.map(\.kind)).sorted { $0.order < $1.order }
        return Group {
            if rows.isEmpty {
                EmptyState(systemImage: "equal.circle", title: "They match",
                           message: "\(pair.left.name) and \(pair.right.name) are set up with the same things.")
            } else {
                VStack(spacing: 0) {
                    // Which column is which, kept in view while the list scrolls.
                    HStack(spacing: 10) {
                        Spacer()
                        columnHead(pair.left)
                        columnHead(pair.right)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(kinds, id: \.self) { kind in
                                Text(kind.title)
                                    .font(Theme.Font.headline)
                                    .padding(.top, 14)
                                    .padding(.bottom, 4)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(rows.filter { $0.kind == kind }) { row in
                                    CompareRow(row: row, leftName: pair.left.name, rightName: pair.right.name,
                                               copyTarget: copyTarget(for: row)) {
                                        if let target = copyTarget(for: row) {
                                            copying = (row.name, target.id == pair.left.id ? pair.right : pair.left, target)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Where a server only one side has could be copied: the other side, if it's a Desktop install.
    private func copyTarget(for row: ConfigComparison.Row) -> Install? {
        guard row.kind == .mcpServer, row.name != RecallConnection.serverName else { return nil }
        switch row.status {
        case .onlyLeft: return Fleet.canReceiveServers(pair.right) ? pair.right : nil
        case .onlyRight: return Fleet.canReceiveServers(pair.left) ? pair.left : nil
        default: return nil
        }
    }

    private func copy(_ name: String, from: Install, to: Install) {
        do {
            try Fleet.copyServer(named: name, from: from, to: to, paths: services.snapshot.paths)
            message = "Copied \(name) into \(to.name). It's available the next time \(to.name) opens, and History can undo it."
            Task { await load() }
        } catch {
            message = String(describing: error)
        }
    }

    private func columnHead(_ install: Install) -> some View {
        HStack(spacing: 5) {
            InstallIcon(install: install, size: 16)
            Text(install.name).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 90)
    }

    private func load() async {
        let left = pair.left, right = pair.right
        comparison = await Task.detached(priority: .userInitiated) {
            let leftItems = ConfigInventory.items(for: left)
            let rightItems = ConfigInventory.items(for: right)
            let leftScope = leftItems.first?.scope ?? .desktopVariant(left.name, left.dataRoot)
            let rightScope = rightItems.first?.scope ?? .desktopVariant(right.name, right.dataRoot)
            return ConfigDiff.compare(leftScope, leftItems, rightScope, rightItems)
        }.value
    }
}

private struct CompareRow: View {
    let row: ConfigComparison.Row
    let leftName: String
    let rightName: String
    var copyTarget: Install?
    var onCopy: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Text(row.name).font(Theme.Font.body).lineLimit(1)
            if row.status == .different {
                Text("Differs")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let copyTarget {
                Button("Copy to \(copyTarget.name)", action: onCopy)
                    .buttonStyle(.plain)
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.accent)
            }
            mark(row.left != nil)
                .frame(width: 90)
            mark(row.right != nil)
                .frame(width: 90)
        }
        .frame(height: 26)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func mark(_ present: Bool) -> some View {
        Image(systemName: present ? "checkmark" : "minus")
            .font(.system(size: 12, weight: present ? .bold : .regular))
            .foregroundStyle(present ? Color.primary : Color.secondary.opacity(0.5))
    }

    private var spoken: String {
        switch row.status {
        case .onlyLeft: return "\(row.name), only in \(leftName)"
        case .onlyRight: return "\(row.name), only in \(rightName)"
        case .same: return "\(row.name), in both"
        case .different: return "\(row.name), in both but different"
        }
    }
}
