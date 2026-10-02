import AppKit
import CoworkKit
import SwiftUI

/// Find any conversation from the menu bar and open it in one step.
struct MenuBarPanel: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openWindow) private var openWindow
    @State private var query = ""
    /// Conversations whose messages match, from the index.
    @State private var found: [ConversationRef]?
    @FocusState private var searchFocused: Bool
    @State private var listHeight: CGFloat = 0

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            if query.isEmpty {
                let waiting = services.pulse.needingYou
                if !waiting.isEmpty {
                    heading("Needs you")
                    ForEach(waiting.prefix(3)) { session in sessionRow(session) }
                }
                let now = services.pulse.sessions.filter { $0.state != .needsYou }
                if !now.isEmpty {
                    heading("Now")
                    ForEach(now.prefix(3)) { session in sessionRow(session) }
                }
                let quotas = services.usage.quotas.filter { $0.window(.weekly) != nil }
                if !quotas.isEmpty {
                    heading("Limits")
                    ForEach(quotas.prefix(3)) { quota in limitRow(quota) }
                }
            }
            results
            Rectangle().fill(Theme.Surface.line).frame(height: 0.5).padding(.horizontal, -8).padding(.top, 6)
            footer
        }
        .padding(8)
        .frame(width: 330)
        .background(Theme.Surface.window)
        .task {
            if !services.hasLoaded { services.refresh() }
            searchFocused = true
        }
        // Matches for the last query go as soon as it changes, so Return never opens one of them.
        .onChange(of: query) { found = nil }
        .task(id: query) {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty, services.index.isReady, let index = services.index.index else {
                found = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let hits = try? await index.search(needle, options: .init(limit: 8, excerptsPerHit: 0)) else { return }
            let byID = Dictionary(services.snapshot.conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            found = hits.compactMap { byID[$0.conversationID] }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Surface.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(Theme.Surface.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { if let first = matches.first { open(first) } }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.Surface.fill, in: .capsule)
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private func sessionRow(_ session: LiveSession) -> some View {
        let conversation = services.conversation(forSession: session.sessionID)
        let detail = services.pulse.notes[session.sessionID]?.message ?? conversation?.title ?? session.cwd
        return Button { services.pulse.show(session) } label: {
            HStack(spacing: 10) {
                Group {
                    if session.isInDesktop, let claude = services.installs.first(where: \.isDesktop) {
                        InstallIcon(install: claude, size: 22)
                    } else if let code = services.installs.first(where: { $0.kind == .claudeCode }) {
                        InstallIcon(install: code, size: 22)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name ?? session.projectName).font(.system(size: 13)).foregroundStyle(Theme.Surface.primary).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if session.state == .needsYou {
                    Text(HomePage.minutes(since: session.since)).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.attention)
                } else {
                    Text(session.state == .working ? "Working" : "Finished").font(.system(size: 12))
                        .foregroundStyle(Theme.Surface.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(PanelRowStyle())
    }

    private func limitRow(_ quota: AccountQuota) -> some View {
        let weekly = quota.window(.weekly)?.percent ?? 0
        return Button { showInWindow { services.destination = .usage } } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(quota.account.displayName).font(.system(size: 13)).foregroundStyle(Theme.Surface.primary).lineLimit(1)
                    Spacer()
                    Text("\(Int(weekly.rounded()))%").font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
                }
                ThinMeter(value: weekly / 100)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(PanelRowStyle())
    }

    private var matches: [ConversationRef] {
        if let found { return found }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return services.recentConversations(5) }
        let all = services.snapshot.conversations.filter { !$0.isArchived }
        return Array(all.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.projectName?.localizedCaseInsensitiveContains(needle) ?? false)
        }.prefix(8))
    }

    @ViewBuilder
    private var results: some View {
        let list = matches
        VStack(alignment: .leading, spacing: 0) {
            heading(query.isEmpty ? "Recent" : list.isEmpty ? "Nothing matches" : "Matches")
            if list.isEmpty, !query.isEmpty {
                Button {
                    showInWindow { services.query = query; services.search.search(query, immediately: true) }
                } label: {
                    Label("Search every message in Better Claude", systemImage: "text.magnifyingglass")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(.rect)
                }
                .buttonStyle(PanelRowStyle())
                .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(list) { conversation in
                            Button { open(conversation) } label: {
                                PanelConversationRow(conversation: conversation,
                                                     install: services.install(for: conversation))
                            }
                            .buttonStyle(PanelRowStyle())
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // As tall as its rows, up to a limit, so a short list leaves no empty space.
                .frame(height: min(listHeight, 300))
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Open Better Claude") { showInWindow {} }
                .keyboardShortcut("o", modifiers: .command)
            Spacer()
            Button("Settings…") { NSApp.activate(); openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            // With the window closed there's no menu bar to quit from, so it's here.
            Button("Quit") { AppDelegate.quit() }
                .keyboardShortcut("q", modifiers: [.command, .option])
                .help("Quit Better Claude (⌥⌘Q)")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.Surface.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }

    private func open(_ conversation: ConversationRef) {
        showInWindow { services.show(conversation) }
    }

    private func showInWindow(_ then: () -> Void) {
        then()
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct PanelConversationRow: View {
    let conversation: ConversationRef
    let install: Install?

    var body: some View {
        HStack(spacing: 10) {
            Group { if let install { InstallIcon(install: install, size: 22) } }
                .frame(width: 18, height: 18)
            Text(conversation.title).font(.system(size: 13)).foregroundStyle(Theme.Surface.primary).lineLimit(1)
            Spacer(minLength: 6)
            Text(conversation.lastActivity.listStamp)
                .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .contentShape(.rect)
    }
}

/// A panel row: a quiet fill under the pointer, a little deeper while pressed.
struct PanelRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? Theme.Surface.selection
                          : hovering ? Theme.Surface.fill : .clear)
            }
            .onHover { hovering = $0 }
    }
}
