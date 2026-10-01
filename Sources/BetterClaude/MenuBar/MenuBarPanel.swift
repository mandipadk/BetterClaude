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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            search
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if query.isEmpty, !services.pulse.needingYou.isEmpty || !services.pulse.working.isEmpty {
                running
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            if query.isEmpty, !services.usage.quotas.isEmpty {
                limits
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            results
                .frame(maxHeight: 360)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(width: 340)
        .task {
            if !services.hasLoaded { services.refresh() }
            searchFocused = true
        }
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

    private var header: some View {
        HStack(spacing: 8) {
            BMark(size: 16)
            Text("Better Claude").font(Theme.Font.headline)
            Spacer()
            if services.isLoading {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find a conversation", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .focused($searchFocused)
                .onSubmit { if let first = matches.first { open(first) } }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    /// How much of each account's week is used, the tightest first.
    private var limits: some View {
        Button { showInWindow { services.destination = .usage } } label: {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(services.usage.quotas.prefix(3)) { quota in
                    let weekly = quota.window(.weekly)?.percent ?? 0
                    HStack(spacing: 8) {
                        Text(quota.account.displayName)
                            .font(Theme.Font.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Capsule().fill(Theme.subtleFill)
                            .frame(width: 60, height: 5)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Theme.accentBright)
                                    .frame(width: max(3, 60 * min(1, weekly / 100)), height: 5)
                            }
                        Text("\(Int(weekly.rounded()))% of the week")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 96, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(PanelRowStyle())
        .accessibilityLabel("Usage")
    }

    /// Claude Code sessions waiting for you, then the ones working.
    private var running: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Running now")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            ForEach((services.pulse.needingYou + services.pulse.working).prefix(4)) { session in
                LiveSessionRow(session: session, compact: true)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.bottom, 4)
    }

    private var matches: [ConversationRef] {
        if let found { return found }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let all = services.snapshot.conversations.filter { !$0.isArchived }
        guard !needle.isEmpty else { return Array(all.prefix(8)) }
        return Array(all.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.projectName?.localizedCaseInsensitiveContains(needle) ?? false)
        }.prefix(8))
    }

    @ViewBuilder
    private var results: some View {
        let list = matches
        VStack(alignment: .leading, spacing: 0) {
            Text(query.isEmpty ? "Recent" : list.isEmpty ? "Nothing matches" : "Matches")
                .font(Theme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if list.isEmpty, !query.isEmpty {
                Button {
                    showInWindow { services.query = query; services.search.search(query, immediately: true) }
                } label: {
                    Label("Search inside messages in Better Claude", systemImage: "text.magnifyingglass")
                        .font(Theme.Font.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
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
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button { showInWindow {} } label: {
                HStack {
                    Text("Open Better Claude")
                    Spacer()
                    KeyCaps(keys: ["⌘", "O"])
                }
                .font(Theme.Font.body)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(PanelRowStyle())
            .keyboardShortcut("o", modifiers: .command)
            Button { AppDelegate.quit() } label: {
                HStack {
                    Text("Quit Better Claude")
                    Spacer()
                    KeyCaps(keys: ["⌥", "⌘", "Q"])
                }
                .font(Theme.Font.body)
                .padding(.horizontal, 14)
                .frame(height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(PanelRowStyle())
            // The same keys as everywhere else: ⌘Q only closes the window to the menu bar.
            .keyboardShortcut("q", modifiers: [.command, .option])
        }
        .padding(.vertical, 5)
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
        HStack(spacing: 9) {
            if let install { InstallIcon(install: install, size: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(conversation.title).font(Theme.Font.body).lineLimit(1)
                Text(conversation.projectName ?? install?.name ?? "")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(conversation.lastActivity.listStamp)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .contentShape(.rect)
    }
}

/// A panel row: a quiet fill under the pointer, a little deeper while pressed.
struct PanelRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed ? Color.primary.opacity(0.12)
                          : hovering ? Theme.subtleFill : .clear)
                    .padding(.horizontal, 5)
            }
            .onHover { hovering = $0 }
    }
}
