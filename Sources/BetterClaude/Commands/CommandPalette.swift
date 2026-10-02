import AppKit
import CoworkKit
import SwiftUI

// MARK: - Commands

/// One thing the palette can do: go somewhere, act on what's selected, or open a conversation.
/// Declared once here, so its name, symbol and shortcut read the same everywhere.
struct PaletteCommand: Identifiable {
    enum Group: Int, CaseIterable {
        case conversation, goTo, actions, conversations, projects, ask

        var title: String {
            switch self {
            case .conversation: return "This conversation"
            case .goTo: return "Go to"
            case .actions: return "Actions"
            case .conversations: return "Conversations"
            case .projects: return "Projects"
            case .ask: return "Search and ask"
            }
        }
    }

    let id: String
    let title: String
    var detail: String?
    let symbol: String
    var keys: String?
    /// Other words people use for it.
    var aliases: [String] = []
    let group: Group
    let run: @MainActor () -> Void
}

extension SidebarDestination {
    /// The name of a page, as the sidebar and the palette say it.
    var title: String {
        switch self {
        case .home: return "Home"
        case .thisMac: return "This Mac"
        case .conversations: return "Conversations"
        case .projects: return "Projects"
        case .running: return "Running"
        case .ask: return "Ask"
        case .usage: return "Usage"
        case .files: return "Files"
        case .prompts: return "Prompts"
        case .library: return "Library"
        case .install: return "Install"
        case .history: return "Activity"
        case .kept: return "Kept"
        case .storage: return "Storage"
        case .memory: return "Memory"
        case .secrets: return "Secrets"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .thisMac: return "laptopcomputer"
        case .conversations: return "bubble.left.and.bubble.right"
        case .projects: return "folder"
        case .running: return "waveform.path.ecg"
        case .ask: return "sparkle.magnifyingglass"
        case .usage: return "chart.bar.xaxis"
        case .files: return "doc.text.magnifyingglass"
        case .prompts: return "text.quote"
        case .library: return "books.vertical"
        case .install: return "app"
        case .history: return "clock.arrow.circlepath"
        case .kept: return "archivebox"
        case .storage: return "internaldrive"
        case .memory: return "brain"
        case .secrets: return "key"
        }
    }
}

@MainActor
enum CommandRegistry {
    static let pages: [(SidebarDestination, [String])] = [
        (.home, ["today", "start", "overview", "worth a look"]),
        (.conversations, ["chats", "transcripts"]),
        (.projects, ["folders", "repos", "corrections", "decisions"]),
        (.running, ["now", "live", "sessions", "needs you", "jobs"]),
        (.ask, ["question", "answer"]),
        (.usage, ["limits", "cost", "quota", "tokens", "spend", "cache", "month"]),
        (.files, ["file history", "versions", "edits"]),
        (.library, ["outputs", "documents", "images", "code", "made"]),
        (.prompts, ["skills", "snippets", "repeated"]),
        (.kept, ["backup", "vault", "archive", "deleted"]),
        (.storage, ["space", "disk", "clean up", "free up"]),
        (.memory, ["CLAUDE.md", "MEMORY.md", "notes"]),
        (.secrets, ["keys", "tokens", "api key", "rotate", "leaked"]),
        (.history, ["undo", "activity", "receipts"]),
        (.thisMac, ["upkeep", "mac", "backups", "other macs"]),
    ]

    /// Everything that doesn't depend on what's typed.
    static func fixed(_ services: AppServices, openSettings: @escaping @MainActor () -> Void) -> [PaletteCommand] {
        var commands: [PaletteCommand] = []
        if let conversation = services.reader.conversation {
            let external = conversation.external != nil
            let missing = conversation.isTranscriptMissing
            if !external && !missing {
                commands.append(.init(id: "continue", title: "Continue in…", symbol: "arrow.right.circle",
                                      aliases: ["move", "carry", "transfer", "resume"], group: .conversation) {
                    services.beginContinue(conversation)
                })
            }
            if !external {
                commands.append(.init(id: "changes", title: "Show Changes…", symbol: "clock.arrow.circlepath", keys: "⇧⌘C",
                                      aliases: ["rewind", "undo edits", "diff", "what changed", "put back"], group: .conversation) {
                    services.rewinding = RewindModel(conversation: conversation)
                })
                commands.append(.init(id: "play", title: "Play Changes…", symbol: "play",
                                      aliases: ["timelapse", "time-lapse", "watch"], group: .conversation) {
                    services.rewinding = RewindModel(conversation: conversation, playing: true)
                })
            }
            if !missing {
                commands.append(.init(id: "handoff", title: "Write a Handoff…", symbol: "doc.text",
                                      aliases: ["brief", "summary", "summarize"], group: .conversation) {
                    services.beginHandoff(conversation)
                })
                commands.append(.init(id: "replay", title: "Replay on Another Model…", symbol: "arrow.triangle.2.circlepath",
                                      aliases: ["rerun", "compare models", "try again"], group: .conversation) {
                    services.replaying = ReplayModel(conversation: conversation)
                })
            }
            if services.reader.canExport(conversation) {
                commands.append(.init(id: "markdown", title: "Export as Markdown…", symbol: "square.and.arrow.up",
                                      aliases: ["save", "md"], group: .conversation) { services.reader.exportMarkdown() })
                commands.append(.init(id: "webpage", title: "Export as Web Page…", symbol: "safari",
                                      aliases: ["html", "share"], group: .conversation) { services.reader.exportWebPage() })
            }
            commands.append(.init(id: "finder", title: "Show in Finder", symbol: "folder",
                                  group: .conversation) { services.revealInFinder(conversation) })
            commands.append(.init(id: "link", title: "Copy Link", symbol: "link", group: .conversation) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("betterclaude://conversation/\(conversation.id)", forType: .string)
            })
        }
        let keys: [SidebarDestination: String] = [.home: "⌘1", .conversations: "⌘2", .projects: "⌘3",
                                                  .usage: "⌘4", .library: "⌘5", .thisMac: "⌘6"]
        for (page, aliases) in pages {
            commands.append(.init(id: "page.\(page.title)", title: page.title, symbol: page.symbol, keys: keys[page],
                                  aliases: aliases, group: .goTo) { services.go(to: page) })
        }
        for install in services.installs {
            commands.append(.init(id: "install.\(install.id)", title: install.name, detail: "Install",
                                  symbol: "app", group: .goTo) { services.destination = .install(install.id) })
        }
        commands.append(.init(id: "settings", title: "Settings…", symbol: "gearshape", keys: "⌘,",
                              aliases: ["preferences", "notifications", "alerts", "api key"], group: .goTo, run: openSettings))
        commands.append(.init(id: "refresh", title: "Look for New Conversations", symbol: "arrow.clockwise", keys: "⌘R",
                              aliases: ["refresh", "reload", "scan"], group: .actions) { services.refresh() })
        commands.append(.init(id: "month", title: "Your Month…", symbol: "calendar",
                              aliases: ["wrapped", "card", "stats"], group: .actions) {
            services.destination = .usage
            services.lookingBack = MonthModel()
        })
        commands.append(.init(id: "backup", title: "Back Up…", symbol: "lock",
                              aliases: ["backup", "export", "encrypt"], group: .actions) {
            services.destination = .kept
            services.pendingBackupSheet = true
        })
        commands.append(.init(id: "import", title: "Import claude.ai Export…", symbol: "square.and.arrow.down",
                              keys: "⇧⌘I", aliases: ["claude.ai", "web"], group: .actions) { services.importClaudeWebExport() })
        commands.append(.init(id: "othermac", title: "Open Another Mac's Backup…", symbol: "laptopcomputer",
                              aliases: ["other mac", "restore"], group: .actions) { services.openOtherMac() })
        return commands
    }

    /// What matches `query`, best first, grouped. With no query: this conversation's actions,
    /// the pages, and recent conversations.
    static func results(_ fixed: [PaletteCommand], query: String, services: AppServices) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            let recent = services.recentConversations(5).map { conversationCommand($0, services: services) }
            return fixed.filter { $0.group == .conversation || $0.group == .goTo } + recent
        }
        var scored: [(PaletteCommand, Int)] = fixed.compactMap { command in
            score(q, command).map { (command, $0) }
        }
        let conversations = services.snapshot.conversations.compactMap { conversation -> (PaletteCommand, Int)? in
            // Conversations match on words, never on scattered letters: there are too many.
            guard let s = score(q, title: conversation.title.lowercased(), aliases: []), s >= 60 else { return nil }
            return (conversationCommand(conversation, services: services), s + recency(conversation))
        }
        scored += conversations.sorted { $0.1 > $1.1 }.prefix(6)
        var projects: [String: (String, Date)] = [:]
        for conversation in services.snapshot.conversations where !conversation.isArchived {
            guard let path = conversation.projectPath.map(Projects.root(of:)), !path.isEmpty else { continue }
            if (projects[path]?.1 ?? .distantPast) < conversation.lastActivity {
                projects[path] = (URL(fileURLWithPath: path).lastPathComponent, conversation.lastActivity)
            }
        }
        let matchingProjects = projects.compactMap { path, value -> (PaletteCommand, Int)? in
            guard let s = score(q, title: value.0.lowercased(), aliases: []), s >= 60 else { return nil }
            let command = PaletteCommand(id: "project.\(path)", title: value.0, detail: "Project",
                                         symbol: "folder", group: .projects) {
                services.showConversations(.project(path))
            }
            return (command, s)
        }
        scored += matchingProjects.sorted { $0.1 > $1.1 }.prefix(4)
        if q.count > 1 {
            let words = query.trimmingCharacters(in: .whitespaces)
            scored.append((PaletteCommand(id: "search", title: "Search every message for “\(words)”", symbol: "text.magnifyingglass",
                                          group: .ask) {
                services.showConversations(.all)
                services.query = words
            }, 1))
        }
        if case .available = services.ask.availability, q.count > 2 {
            let question = query.trimmingCharacters(in: .whitespaces)
            scored.append((PaletteCommand(id: "ask", title: "Ask “\(question)”", symbol: "sparkle.magnifyingglass",
                                          keys: "⌘↩", group: .ask) { services.askHistory(question) }, 0))
        }
        // Groups keep their order; inside each, the best match leads.
        return scored.sorted {
            $0.0.group.rawValue != $1.0.group.rawValue ? $0.0.group.rawValue < $1.0.group.rawValue : $0.1 > $1.1
        }.map(\.0)
    }

    static func conversationCommand(_ conversation: ConversationRef, services: AppServices) -> PaletteCommand {
        PaletteCommand(id: "conversation.\(conversation.id)", title: conversation.title,
                       detail: conversation.projectName ?? services.install(for: conversation)?.name,
                       symbol: "bubble.left", group: .conversations) { services.show(conversation) }
    }

    private static func recency(_ conversation: ConversationRef) -> Int {
        let days = -conversation.lastActivity.timeIntervalSinceNow / 86_400
        return days < 1 ? 6 : days < 7 ? 3 : 0
    }

    static func score(_ q: String, _ command: PaletteCommand) -> Int? {
        score(q, title: command.title.lowercased(), aliases: command.aliases.map { $0.lowercased() })
    }

    /// Prefix beats word start beats substring beats alias beats letters in order.
    static func score(_ q: String, title: String, aliases: [String]) -> Int? {
        if title.hasPrefix(q) { return 100 }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 80 }
        if title.contains(q) { return 60 }
        if aliases.contains(where: { $0.hasPrefix(q) || $0.contains(q) }) { return 50 }
        var rest = Substring(title)
        for character in q {
            guard let index = rest.firstIndex(of: character) else { return nil }
            rest = rest[rest.index(after: index)...]
        }
        return q.count >= 3 ? 20 : nil
    }
}

// MARK: - Palette

/// ⌘K: one field that finds every page, every action on what's selected, and every
/// conversation. Its rows show their shortcuts, so it teaches the keyboard as it goes.
struct CommandPalette: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    let close: () -> Void

    var body: some View {
        let fixed = CommandRegistry.fixed(services) { openSettings() }
        let results = CommandRegistry.results(fixed, query: query, services: services)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                TextField("Search for a page, an action or a conversation", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { run(results, at: selected) }
                if let conversation = services.reader.conversation {
                    Text(conversation.title)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Divider()
            if results.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                                if index == 0 || results[index - 1].group != command.group {
                                    Text(command.group.title)
                                        .font(Theme.Font.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.top, index == 0 ? 6 : 12)
                                        .padding(.bottom, 4)
                                }
                                row(command, isSelected: index == selected)
                                    .id(index)
                                    .onTapGesture { run(results, at: index) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: listHeight(results))
                    .onChange(of: selected) { _, index in proxy.scrollTo(index) }
                }
            }
            Divider()
            HStack(spacing: 16) {
                Spacer()
                hint("Open", keys: "↩")
                if case .available = services.ask.availability { hint("Ask", keys: "⌘↩") }
                hint("Close", keys: "esc")
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        .onAppear {
            focused = true
            query = services.paletteSeed
            services.paletteSeed = ""
        }
        .onChange(of: query) { selected = 0 }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let question = query.trimmingCharacters(in: .whitespaces)
            guard !question.isEmpty, case .available = services.ask.availability else { return .handled }
            close()
            services.askHistory(question)
            return .handled
        }
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ command: PaletteCommand, isSelected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: command.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(command.title).font(Theme.Font.body).lineLimit(1)
            Spacer(minLength: 12)
            if let keys = command.keys {
                Text(keys).font(Theme.Font.callout).foregroundStyle(.secondary)
            } else if let detail = command.detail {
                Text(detail).font(Theme.Font.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(isSelected ? Color.primary.opacity(0.09) : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
    }

    /// Tall enough for what's there, up to about ten rows.
    private func listHeight(_ results: [PaletteCommand]) -> CGFloat {
        let headers = zip(results, [nil] + results.map(Optional.some)).filter { $0.0.group != $0.1?.group }.count
        return min(400, CGFloat(results.count) * 34 + CGFloat(headers) * 26 + 18)
    }

    private func hint(_ label: String, keys: String) -> some View {
        HStack(spacing: 5) {
            Text(keys).font(Theme.Font.caption.weight(.medium))
            Text(label).font(Theme.Font.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func run(_ results: [PaletteCommand], at index: Int) {
        guard results.indices.contains(index) else { return }
        close()
        results[index].run()
    }
}
