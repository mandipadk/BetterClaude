import CoworkKit
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()
    @State private var transfer: TransferModel?
    @State private var query = ""
    /// Bumped to move focus into the search field from a menu command.
    @State private var focusRequest = 0

    var body: some View {
        // A plain split rather than NavigationSplitView: the system version draws the sidebar
        // as an inset floating panel, which is a card.
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 236)
            Rectangle()
                .fill(Design.Palette.separator)
                .frame(width: 1 / (NSScreen.main?.backingScaleFactor ?? 2))
            detail
        }
        .background(Design.Palette.background)
        // Modal separation cannot come from raising the sheet alone: without this, the
        // window's own accented Transfer button stays fully saturated behind the sheet, so
        // two identical clay buttons sit on screen at once and the brightest pixel belongs
        // to the layer that is disabled by modality.
        .overlay(Color.black.opacity(transfer == nil && model.branching == nil ? 0 : 0.38)
            .ignoresSafeArea())
        .animation(.easeInOut(duration: Design.Duration.quick),
                   value: transfer == nil && model.branching == nil)
        .ignoresSafeArea(.container, edges: .top)
        .ownsWindowChrome()
        .task { model.refresh() }
        .sheet(item: Binding(
            get: { transfer.map { TransferBox(model: $0) } },
            set: { if $0 == nil { transfer = nil } }
        )) { box in
            TransferSheet(model: box.model, app: model) {
                transfer = nil
                model.refresh()
            }
        }
        .sheet(isPresented: Binding(get: { model.branching != nil },
                                    set: { if !$0 { model.cancelBranch() } })) {
            if let branching = model.branching {
                BranchSheet(conversationTitle: branching.row.title,
                            points: branching.points,
                            totalMessages: branching.totalMessages,
                            selected: Binding(get: { model.branchPoint },
                                              set: { model.branchPoint = $0 }),
                            newTitle: Binding(get: { model.branchTitle },
                                              set: { model.branchTitle = $0 }),
                            onCancel: { model.cancelBranch() },
                            onBranch: { model.applyBranch() })
            }
        }
        .background(
            Button("") { focusRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var filtered: [SessionRow] {
        guard !query.isEmpty else { return model.rows }
        return model.rows.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.pane {
        case .conversations: conversationsPane
        case .control:
            ControlView(scopes: model.configScopes,
                        items: model.configItems,
                        comparison: Binding(get: { model.comparison },
                                            set: { model.comparison = $0 }),
                        onCompare: { model.compareScopes($0, $1) },
                        onRefresh: { Task { await model.loadConfig() } },
                        scopeFilter: Binding(get: { model.configScopeFilter },
                                             set: { model.configScopeFilter = $0 }))
        case .library:
            LibraryView(summary: model.harvest,
                        isHarvesting: model.isHarvesting,
                        query: Binding(get: { model.libraryQuery },
                                       set: { model.libraryQuery = $0 }),
                        kindFilter: Binding(get: { model.libraryKind },
                                            set: { model.libraryKind = $0 }),
                        selected: Binding(get: { model.selectedArtifact },
                                          set: { model.selectedArtifact = $0 }),
                        onHarvest: { Task { await model.runHarvest() } },
                        onReveal: { model.revealArtifact($0) },
                        onCopy: { model.copyArtifact($0) })
        }
    }

    @ViewBuilder
    private var conversationsPane: some View {
        if let reading = model.reading {
            ConversationView(title: reading.row.title,
                             subtitle: reading.subtitle,
                             messages: reading.messages,
                             onClose: { model.closeReading() },
                             onExport: { model.exportOpenConversation() })
        } else {
            conversationList
        }
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if model.isSearchingEverywhere {
                scopeBar
                Hairline()
                SearchResults(model: model)
            } else {
                if !query.isEmpty {
                    scopeBar
                    Hairline()
                }
                if model.rows.isEmpty {
                    Empty(headline: "No conversations here",
                          detail: "Choose an account or a project on the left.")
                } else if filtered.isEmpty {
                    Empty(headline: "Nothing here matches",
                          detail: "No conversation in this account matches “\(query)”.")
                } else {
                    SessionList(rows: filtered, selection: $model.selectedRowIDs)
                }
            }
            Hairline()
            actionBar
        }
    }

    /// Widens the search from the selected account to the whole machine. Local filtering is
    /// instant and is what people want most of the time; reading every transcript is not, so
    /// it stays an explicit second step rather than something that happens as you type.
    private var scopeBar: some View {
        HStack(spacing: Design.Space.s) {
            if model.isSearchingEverywhere {
                Text("Every conversation · “\(model.globalQuery)”")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                if model.isIndexing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                Spacer()
                Button("Back to this account") {
                    model.exitGlobalSearch()
                    query = ""
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                Text("\(filtered.count) here")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                Spacer()
                Button("Search every conversation") {
                    Task { await model.searchEverywhere(query) }
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, 5)
    }

    // MARK: - Header

    /// One chrome band, not two: the title and search sit in the space the titlebar would
    /// otherwise occupy, so nothing above the first row is empty.
    private var header: some View {
        HStack(alignment: .center, spacing: Design.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.sourceTitle)
                    .font(Design.Typography.title)
                    .foregroundStyle(Design.Palette.primary)
                    .lineLimit(1)
                Text(model.sourceSubtitle)
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Design.Space.l)
            SearchField(text: $query, focusRequest: focusRequest)
                .frame(width: 190)
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Design.Palette.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rescan for Claude installs and conversations")
            .accessibilityLabel("Refresh")
        }
        .padding(.leading, Design.Space.gutter)
        .padding(.trailing, Design.Space.m)
        .padding(.top, WindowMetrics.titlebarInset)
        .padding(.bottom, Design.Space.m)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        let transferable = model.selectedRows.filter(\.hasTranscript)
        return HStack(spacing: Design.Space.s) {
            Text(statusText)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
            Spacer()
            Button("Deselect") { model.selectedRowIDs = [] }
                .buttonStyle(QuietButtonStyle())
                // Kept in the layout when empty so the primary action does not shift
                // horizontally the moment a row is selected.
                .opacity(model.selectedRowIDs.isEmpty ? 0 : 1)
                .disabled(model.selectedRowIDs.isEmpty)
            Button("Read") {
                if let only = transferable.first { model.openForReading(only) }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(transferable.count != 1)
            .keyboardShortcut("o", modifiers: .command)
            Button("Branch") {
                if let only = transferable.first { model.openBranch(only) }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(transferable.count != 1 || !(transferable.first.map(model.canBranch) ?? false))
            .help("Fork this conversation at a chosen message into a new one")
            .keyboardShortcut("b", modifiers: .command)
            Button("Transfer") {
                transfer = TransferModel(sessions: transferable)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(transferable.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Design.Space.gutter)
        .padding(.vertical, Design.Space.s)
    }

    private var statusText: String {
        let count = model.selectedRowIDs.count
        if count == 0 {
            return "\(filtered.count) conversation\(filtered.count == 1 ? "" : "s")"
        }
        let skipped = model.selectedRows.filter { !$0.hasTranscript }.count
        let base = "\(count) selected"
        return skipped == 0 ? base : "\(base) · \(skipped) without a transcript"
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: WindowMetrics.titlebarInset)
                ForEach(Pane.allCases) { pane in
                    PaneRow(pane: pane, isSelected: model.pane == pane) {
                        model.pane = pane
                        if pane == .control && model.configItems.isEmpty { Task { await model.loadConfig() } }
                        if pane == .library && model.harvest == nil { Task { await model.runHarvest() } }
                    }
                }
                switch model.pane {
                case .conversations:
                    group("Accounts", items: model.desktopSources)
                    if !model.projectSources.isEmpty {
                        group("Projects", items: model.projectSources)
                    }
                case .control:
                    SectionLabel(text: "Installs")
                        .padding(.leading, Design.Space.gutter)
                        .padding(.top, Design.Space.m)
                        .padding(.bottom, Design.Space.xs)
                    ScopeRow(title: "Everything", badge: "\(model.configItems.count)",
                             isSelected: model.configScopeFilter == nil) {
                        model.configScopeFilter = nil
                    }
                    // An install with nothing in it selects into an empty pane and tells the
                    // reader nothing, so it is not offered. The count beside "Everything"
                    // still reflects every scope that was scanned.
                    ForEach(model.populatedConfigScopes, id: \.id) { scope in
                        ScopeRow(title: scope.title,
                                 badge: "\(model.configItems.filter { $0.scope == scope }.count)",
                                 isSelected: model.configScopeFilter == scope) {
                            model.configScopeFilter = model.configScopeFilter == scope ? nil : scope
                        }
                    }
                case .library:
                    SectionLabel(text: "Kinds")
                        .padding(.leading, Design.Space.gutter)
                        .padding(.top, Design.Space.m)
                        .padding(.bottom, Design.Space.xs)
                    ScopeRow(title: "Everything",
                             badge: "\(model.harvest?.artifacts.count ?? 0)",
                             isSelected: model.libraryKind == nil) { model.libraryKind = nil }
                    ForEach(ArtifactKind.allCases, id: \.self) { kind in
                        let count = model.harvest?.artifacts.filter { $0.kind == kind }.count ?? 0
                        if count > 0 {
                            ScopeRow(title: kind.label, badge: "\(count)",
                                     isSelected: model.libraryKind == kind) {
                                model.libraryKind = model.libraryKind == kind ? nil : kind
                            }
                        }
                    }
                }
                Color.clear.frame(height: Design.Space.xl)
            }
        }
        .scrollContentBackground(.hidden)
        .fadingBottomEdge(56)
    }

    @ViewBuilder
    private func group(_ title: String, items: [SidebarItem]) -> some View {
        SectionLabel(text: title)
            // Aligned to the same edge as the row label below it, so the sidebar has one
            // left edge rather than three.
            .padding(.leading, Design.Space.gutter)
            .padding(.top, Design.Space.m)
            .padding(.bottom, Design.Space.xs)
        ForEach(items) { item in
            SidebarRow(item: item, isSelected: model.selectedSource == item.source) {
                model.selectedSource = item.source
                model.loadSessions()
            }
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Text(item.title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(Design.Palette.primary)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.xs)
                if let badge = item.badge {
                    Text(badge)
                        .font(Design.Typography.numeric)
                        .foregroundStyle(Design.Palette.muted)
                        // Fixed width so the badge does not shift as counts change digits.
                        .frame(width: item.badgeIsWide ? 62 : 24, alignment: .trailing)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.leading, Design.Space.s)
            .padding(.trailing, Design.Space.s)
            .frame(height: Design.Space.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(isSelected ? Design.Palette.selection : (isHovering ? Design.Palette.hover : .clear))
            )
            .overlay(alignment: .leading) {
                // A wash alone reads at barely over 1:1. The bar is what makes the selected
                // row unmistakable at a glance without shouting.
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Design.Palette.accent)
                        .frame(width: 2, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Space.s)
        .onHover { isHovering = $0 }
        .help(item.help)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Session list

private struct SessionList: View {
    let rows: [SessionRow]
    @Binding var selection: Set<String>
    @State private var anchor: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SessionRowView(row: row, isSelected: selection.contains(row.id)) { modifiers in
                        handleClick(row: row, index: index, modifiers: modifiers)
                    }
                    if index < rows.count - 1 { Hairline() }
                }
                // Trailing room so the fade finishes above the footer rule instead of
                // leaving residual ink smeared against it.
                Color.clear.frame(height: Design.Space.m)
            }
        }
        .scrollContentBackground(.hidden)
        .fadingBottomEdge(64)
    }

    /// Click, ⌘-click to toggle, ⇧-click to extend — the selection behaviour a macOS list is
    /// expected to have, which a hand-rolled list has to implement itself.
    private func handleClick(row: SessionRow, index: Int, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
            anchor = row.id
        } else if modifiers.contains(.shift), let anchor,
                  let start = rows.firstIndex(where: { $0.id == anchor }) {
            let range = start <= index ? start...index : index...start
            selection.formUnion(rows[range].map(\.id))
        } else {
            selection = [row.id]
            anchor = row.id
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    let isSelected: Bool
    let onClick: (EventModifiers) -> Void
    @State private var isHovering = false

    /// Rows are `Button`s rather than tap-gesture surfaces so they carry button traits and
    /// are reachable by VoiceOver and by UI automation. Modifier state is read from the
    /// current event at action time, which avoids stacking gesture recognisers that would
    /// swallow the plain click.
    private var currentModifiers: EventModifiers {
        let flags = NSEvent.modifierFlags
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    var body: some View {
        Button { onClick(currentModifiers) } label: { content }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.title)
            .accessibilityValue("\(row.modelName), \(row.byteSize.fileSize), \(row.date.compactStamp)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One line per conversation. The model name was previously a second line under every
    /// title, where it repeated identically down the whole list and cost 40% of the visible
    /// rows; as a column it stays scannable and the list shows half again as many.
    private var content: some View {
        HStack(spacing: Design.Space.m) {
            Text(row.title)
                .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                .foregroundStyle(Design.Palette.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !row.hasTranscript {
                Text("no transcript")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.secondary)
            }
            Spacer(minLength: Design.Space.m)
            Text(row.modelName)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.muted)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
            Text(row.byteSize.fileSize)
                .font(Design.Typography.numeric)
                .foregroundStyle(Design.Palette.secondary)
                .frame(width: 62, alignment: .trailing)
            Text(row.date.compactStamp)
                .font(Design.Typography.numeric)
                .foregroundStyle(Design.Palette.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, Design.Space.gutter)
        .frame(height: Design.Space.rowHeight)
        .background(isSelected ? Design.Palette.selection : (isHovering ? Design.Palette.hover : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

// MARK: - Small parts

struct SearchField: View {
    @Binding var text: String
    var focusRequest: Int = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Design.Palette.faint)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(Design.Typography.body)
                .tint(Design.Palette.secondary)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Design.Palette.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                .fill(Design.Palette.hover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                .strokeBorder(focused ? Design.Palette.secondary : Design.Palette.controlStroke,
                              lineWidth: 1)
        )
        // Without this the only hit target is the glyphs of the text itself, so clicking
        // anywhere in the field's chrome does nothing and typing goes to the list instead.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .onChange(of: focusRequest) { _, _ in focused = true }
    }
}

struct Empty: View {
    let headline: String
    let detail: String

    var body: some View {
        VStack(spacing: Design.Space.xs) {
            Text(headline)
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.secondary)
            Text(detail)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondary)
                // Centred and bounded. With neither, a long detail line ran to 3.5pt from
                // the window edge at the minimum size — past the pane's own 16pt rail —
                // and, being leading-aligned inside a centred frame, wrapped full-bleed on
                // line one and ragged on line two. Shared by every empty state, so the
                // measure belongs here rather than at each call site.
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A floor as well as a ceiling. `fixedSize(vertical:)` under a maxWidth with no
        // minimum answers a zero-width proposal by wrapping to roughly one character per
        // line, which published a 1828pt minimum height for the first-run Library pane. The
        // window's own minimum absorbs it today, so this is a landmine rather than a live
        // defect — but any future container that asks Empty for its minimum would get that.
        .frame(minWidth: 240, maxWidth: 440)
        .gutter()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TransferBox: Identifiable {
    let model: TransferModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

/// A top-level pillar in the sidebar. Taller than a source row and carrying a one-line
/// summary, so the three pillars read as the app's structure rather than as more sources.
private struct PaneRow: View {
    let pane: Pane
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(Design.Palette.primary)
                Text(pane.summary)
                    .font(Design.Typography.caption)
                    // `muted` is calibrated against the window background; on the selected
                    // row's tinted wash it drops to 2.8:1, so the selected row steps up.
                    .foregroundStyle(isSelected ? Design.Palette.secondary : Design.Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, Design.Space.s)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(isSelected ? Design.Palette.selection : (isHovering ? Design.Palette.hover : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Design.Palette.accent)
                        .frame(width: 2, height: 20)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Space.s)
        .onHover { isHovering = $0 }
        .accessibilityLabel(pane.title)
        .accessibilityHint(pane.summary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A sidebar row for a filter dimension — a Control install or a Library kind. Shares the
/// account row's shape so the sidebar reads the same whichever pillar is open.
private struct ScopeRow: View {
    let title: String
    let badge: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Text(title)
                    .font(isSelected ? Design.Typography.bodyEmphasis : Design.Typography.body)
                    .foregroundStyle(Design.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Design.Space.xs)
                Text(badge)
                    .font(Design.Typography.numeric)
                    .foregroundStyle(Design.Palette.muted)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, Design.Space.s)
            .frame(height: Design.Space.sidebarRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(isSelected ? Design.Palette.selection : (isHovering ? Design.Palette.hover : .clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Design.Palette.accent)
                        .frame(width: 2, height: 16)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Design.Space.s)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
