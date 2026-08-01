import CoworkKit
import SwiftUI

/// Every piece of Claude configuration on the machine, in one list, and two installs side by
/// side.
///
/// The list is the whole point, so it gets the whole pane: filters are one line of text each,
/// the comparison chooser only appears once it has been asked for, and every row is a single
/// line. Skills, MCP servers and hooks are things people have hundreds of; anything that
/// spends two lines on one of them shows a third as much of the thing being looked for.
struct ControlView: View {
    let scopes: [ConfigScope]
    let items: [ConfigItem]
    @Binding var comparison: ConfigComparison?
    var onCompare: (ConfigScope, ConfigScope) -> Void
    var onRefresh: () -> Void

    @Binding var scopeFilter: ConfigScope?

    @State private var query = ""
    @State private var kindFilter: ConfigKind?
    @State private var isChoosingComparison = false
    @State private var left: ConfigScope?
    @State private var right: ConfigScope?
    @State private var onlyDifferences = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if comparison != nil {
                comparisonBody
            } else {
                listBody
            }
            Hairline()
            actionBar
        }
        .background(Design.Palette.background)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(comparison == nil ? "Control" : "Compare")
                    .font(Design.Typography.title)
                    .foregroundStyle(Design.Palette.primary)
                Text(headerSubtitle)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Design.Space.l)
            SearchField(text: $query)
                .frame(width: 190)
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Design.Palette.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rescan configuration")
            .accessibilityLabel("Refresh")
        }
        .padding(.leading, Design.Space.gutter)
        .padding(.trailing, Design.Space.m)
        .padding(.top, WindowMetrics.titlebarInset)
        .padding(.bottom, Design.Space.m)
    }

    private var headerSubtitle: String {
        if let comparison {
            return "\(comparison.left.title) · \(comparison.right.title)"
        }
        if let scopeFilter {
            let scoped = items.filter { $0.scope == scopeFilter }.count
            return "\(scoped) item\(scoped == 1 ? "" : "s") in \(scopeFilter.title)"
        }
        let installs = scopes.count
        return "\(items.count) item\(items.count == 1 ? "" : "s") across "
            + "\(installs) install\(installs == 1 ? "" : "s")"
    }

    // MARK: - List

    private var listBody: some View {
        VStack(spacing: 0) {
            filters
            Hairline()
            if isChoosingComparison {
                comparisonChooser
                Hairline()
            }
            if items.isEmpty {
                Empty(headline: "Nothing to show yet",
                      detail: "No Claude configuration was found on this machine.")
            } else if visible.isEmpty {
                Empty(headline: "Nothing here matches",
                      detail: "No configuration matches the current filters.")
            } else {
                itemList
            }
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow(label: "What") {
                FilterChip(title: "All", isSelected: kindFilter == nil) { kindFilter = nil }
                ForEach(presentKinds, id: \.self) { kind in
                    FilterChip(title: kind.title, isSelected: kindFilter == kind) {
                        kindFilter = kindFilter == kind ? nil : kind
                    }
                }
            }
        }
        .padding(.bottom, Design.Space.xs)
    }

    /// A label in a fixed leading column and a horizontally scrolling row of choices, so both
    /// filter rows start on the same left edge as the list below them.
    private func filterRow<Content: View>(label: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: Design.Space.s) {
            SubHead(text: label)
                .frame(width: 40, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Design.Space.s) { content() }
            }
            .fadingTrailingEdge(28)
        }
        .frame(height: 26)
        .padding(.leading, Design.Space.gutter)
        .padding(.trailing, Design.Space.s)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.kind) { group in
                    HStack(spacing: Design.Space.s) {
                        SectionLabel(text: group.kind.title)
                        Text("\(group.items.count)")
                            .font(Design.Typography.numeric)
                            .foregroundStyle(Design.Palette.muted)
                        Spacer(minLength: 0)
                    }
                    .gutter()
                    .padding(.top, Design.Space.l)
                    .padding(.bottom, Design.Space.xs)

                    ForEach(group.items) { item in
                        ItemRow(item: item, showsScope: scopeFilter == nil)
                        if item.id != group.items.last?.id { Hairline() }
                    }
                }
                Color.clear.frame(height: Design.Space.xl)
            }
        }
        .scrollContentBackground(.hidden)
        .fadingBottomEdge(56)
    }

    // MARK: - Comparison chooser

    private var comparisonChooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow(label: "Left") {
                ForEach(scopes, id: \.id) { scope in
                    FilterChip(title: scope.title, isSelected: left == scope) { left = scope }
                }
            }
            filterRow(label: "Right") {
                ForEach(scopes, id: \.id) { scope in
                    FilterChip(title: scope.title, isSelected: right == scope) { right = scope }
                }
            }
        }
        .padding(.vertical, Design.Space.xs)
    }

    // MARK: - Comparison

    @ViewBuilder
    private var comparisonBody: some View {
        if let comparison {
            ComparisonPane(comparison: comparison, query: query, onlyDifferences: $onlyDifferences)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: Design.Space.s) {
            Text(statusText)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
            Spacer()
            if comparison != nil {
                Button("Back to everything") { comparison = nil }
                    .buttonStyle(QuietButtonStyle())
            } else if isChoosingComparison {
                Button("Cancel") { isChoosingComparison = false }
                    .buttonStyle(QuietButtonStyle())
                Button("Compare") {
                    if let left, let right { onCompare(left, right) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(left == nil || right == nil || left == right)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Compare two installs") {
                    isChoosingComparison = true
                    if left == nil { left = scopes.first }
                    if right == nil { right = scopes.dropFirst().first }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(scopes.count < 2)
            }
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, Design.Space.s)
    }

    private var statusText: String {
        if let comparison {
            let summary = comparison.summary
            return "\(summary.different) different · \(summary.onlyLeft) only left · "
                + "\(summary.onlyRight) only right · \(summary.same) identical"
        }
        if isChoosingComparison {
            return left == right && left != nil
                ? "Choose two different installs"
                : "Choose an install on each side"
        }
        return "\(visible.count) of \(items.count) shown"
    }

    // MARK: - Filtering

    private var visible: [ConfigItem] {
        items.filter { item in
            if let scopeFilter, item.scope != scopeFilter { return false }
            if let kindFilter, item.kind != kindFilter { return false }
            guard !query.isEmpty else { return true }
            return item.name.localizedCaseInsensitiveContains(query)
                || (item.detail ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var presentKinds: [ConfigKind] {
        let present = Set(items.map(\.kind))
        return ConfigKind.allCases.filter { present.contains($0) }.sorted { $0.order < $1.order }
    }

    private var grouped: [KindGroup] {
        var buckets: [ConfigKind: [ConfigItem]] = [:]
        for item in visible { buckets[item.kind, default: []].append(item) }
        return buckets.keys.sorted { $0.order < $1.order }.map { kind in
            KindGroup(kind: kind, items: (buckets[kind] ?? []).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedSame
                    ? $0.scope.title < $1.scope.title
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
    }
}

private struct KindGroup: Identifiable {
    let kind: ConfigKind
    let items: [ConfigItem]
    var id: ConfigKind { kind }
}

// MARK: - Comparison pane

private struct ComparisonPane: View {
    let comparison: ConfigComparison
    let query: String
    @Binding var onlyDifferences: Bool

    private var rows: [ConfigComparison.Row] {
        let byStatus = onlyDifferences ? comparison.rows.filter { $0.status != .same } : comparison.rows
        guard !query.isEmpty else { return byStatus }
        return byStatus.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Design.Space.m) {
                Checkbox(title: "Only differences", isOn: $onlyDifferences)
                    .fixedSize()
                Spacer(minLength: Design.Space.m)
                columnHeading(comparison.left.title)
                columnHeading(comparison.right.title)
            }
            .gutter()
            .frame(height: 30)
            Hairline()
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            Empty(headline: "These two match",
                  detail: onlyDifferences
                      ? "Everything in one install is present, and identical, in the other."
                      : "Neither install has any configuration to compare.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        ComparisonRowView(row: row)
                        if row.id != rows.last?.id { Hairline() }
                    }
                    Color.clear.frame(height: Design.Space.xl)
                }
            }
            .scrollContentBackground(.hidden)
            .fadingBottomEdge(56)
        }
    }

    private func columnHeading(_ text: String) -> some View {
        Text(text)
            .font(Design.Typography.label)
            .tracking(0.6)
            .foregroundStyle(Design.Palette.muted)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 96, alignment: .center)
    }
}

// MARK: - Rows

private struct ItemRow: View {
    let item: ConfigItem
    let showsScope: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(item.name)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Fixed so every description shares one left edge; without it the column
                // started wherever the preceding name happened to end, varying by 118pt.
                .frame(width: 200, alignment: .leading)
            if item.isEnabled == false {
                Text("off")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
            }
            if let detail = item.detail {
                Text(detail)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Design.Space.m)
            if showsScope {
                Text(item.scope.title)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 104, alignment: .leading)
            }
            Text(item.bytes > 0 ? item.bytes.fileSize : "—")
                .font(Design.Typography.numeric)
                .foregroundStyle(Design.Palette.secondary)
                .frame(width: 62, alignment: .trailing)
            Text(item.modified?.compactStamp ?? "—")
                .font(Design.Typography.numeric)
                .foregroundStyle(Design.Palette.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .gutter()
        .frame(height: Design.Space.rowHeight)
        .background(isHovering ? Design.Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(item.url?.path.abbreviatingHome ?? item.name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.name)
        .accessibilityValue("\(item.kind.title), \(item.scope.title)")
    }
}

private struct ComparisonRowView: View {
    let row: ConfigComparison.Row
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Design.Space.m) {
            // Only a genuine content difference earns a leading mark: a row present on one
            // side alone is already stated by its two columns, and marking it too would leave
            // nothing on the line that means "look here first".
            if row.status == .different {
                StatusMark(kind: .warning)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            Text(row.name)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let detail = (row.left ?? row.right)?.detail {
                Text(detail)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Design.Space.m)
            Text(row.kind.title)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.muted)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)
            side(present: row.left != nil)
            side(present: row.right != nil)
        }
        .gutter()
        .frame(height: Design.Space.rowHeight)
        .background(isHovering ? Design.Palette.hover : .clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.name)
        .accessibilityValue(spokenStatus)
    }

    @ViewBuilder
    private func side(present: Bool) -> some View {
        Group {
            if present {
                StatusMark(kind: .ok)
            } else {
                Text("—")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.muted)
            }
        }
        .frame(width: 96, alignment: .center)
    }

    private var spokenStatus: String {
        switch row.status {
        case .onlyLeft: return "\(row.kind.title), left only"
        case .onlyRight: return "\(row.kind.title), right only"
        case .same: return "\(row.kind.title), identical"
        case .different: return "\(row.kind.title), different"
        }
    }
}

// MARK: - Filter chip

/// One choice in a filter row. Selection is an accent underline rather than a filled pill:
/// a pill is a card, and fifteen of them in a row is a card grid.
private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(isSelected ? Design.Palette.primary : Design.Palette.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle()
                    .fill(isSelected ? Design.Palette.accent : Color.clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, Design.Space.xs)
            .frame(height: 22)
            .background(isHovering && !isSelected ? Design.Palette.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
