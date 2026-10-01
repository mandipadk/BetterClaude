import AppKit
import CoworkKit
import SwiftUI

/// What an install is set up with — skills, MCP servers, plugins and the rest — as counted
/// groups that open into their items.
struct SetupSection: View {
    @Environment(AppServices.self) private var services
    let install: Install

    var body: some View {
        let items = services.setup[install.id]
        DetailSection(title: "Set up with", subtitle: subtitle(items)) {
            if let items {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(kinds(in: items), id: \.self) { kind in
                        KindGroup(kind: kind, items: items.filter { $0.kind == kind }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                    }
                }
                .padding(.horizontal, -8)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading its setup…").font(Theme.Font.callout).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: install.id) { services.loadSetup(for: install) }
    }

    private func kinds(in items: [ConfigItem]) -> [ConfigKind] {
        Set(items.map(\.kind)).sorted { $0.order < $1.order }
    }

    private func subtitle(_ items: [ConfigItem]?) -> String? {
        guard let items else { return nil }
        if items.isEmpty {
            return install.kind == .science
                ? "Claude Science manages its own tools."
                : "No skills, servers or plugins yet."
        }
        return "Everything Claude can use here. Open a group to see each item; click one to find it in Finder."
    }
}

private struct KindGroup: View {
    let kind: ConfigKind
    let items: [ConfigItem]
    @State private var expanded = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                    Image(systemName: Self.symbol(kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(kind.title).font(Theme.Font.body)
                    Spacer()
                    Text("\(items.count)")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(.rect)
            }
            .buttonStyle(HoverRowStyle())
            .accessibilityLabel("\(kind.title), \(items.count)")
            .accessibilityHint(expanded ? "Collapse" : "Expand")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(showAll ? items : Array(items.prefix(12))) { item in
                        ItemRow(item: item)
                    }
                    if items.count > 12 {
                        Button(showAll ? "Show Fewer" : "Show All \(items.count)") {
                            withAnimation(Theme.Motion.snappy) { showAll.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Font.callout)
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 50)
                        .padding(.vertical, 6)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    static func symbol(_ kind: ConfigKind) -> String {
        switch kind {
        case .skill: return "sparkles"
        case .subagent: return "person.2"
        case .command: return "command"
        case .mcpServer: return "server.rack"
        case .hook: return "arrow.triangle.turn.up.right.diamond"
        case .memory: return "brain"
        case .plugin: return "puzzlepiece.extension"
        case .setting: return "slider.horizontal.3"
        case .extensionBundle: return "shippingbox"
        }
    }
}

private struct ItemRow: View {
    let item: ConfigItem

    var body: some View {
        Button {
            if let url = item.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(Theme.Font.body).lineLimit(1)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if item.isEnabled == false {
                    Text("Off").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 50)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(HoverRowStyle())
        .disabled(item.url == nil)
        .help(item.url.map { "Show \($0.lastPathComponent) in Finder" } ?? "")
    }
}

/// A notice about an install: something worth knowing, with what to do about it.
struct InstallNotice: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Notice")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.m)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.bordered)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
    }
}
