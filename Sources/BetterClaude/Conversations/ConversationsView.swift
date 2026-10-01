import CoworkKit
import SwiftUI

/// Every conversation on the Mac as one timeline, with the open one beside it.
struct ConversationsView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        HStack(spacing: 0) {
            TimelineColumn()
                .frame(width: services.showsInspector ? 280 : 320)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ReaderView()
                .frame(maxWidth: .infinity)
            if services.showsInspector {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                ReaderInspector()
                    .frame(width: 290)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.snappy, value: services.showsInspector)
        .toolbar {
            if let conversation = services.reader.conversation {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ConversationActions(conversation: conversation)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("More for this conversation")
                }
                ToolbarItem(placement: .primaryAction) {
                    if conversation.external != nil {
                        Button("Write a Handoff…") { services.beginHandoff(conversation) }
                            .buttonStyle(.borderedProminent)
                            .help("A one-page brief of this conversation, to continue it in a fresh one")
                    } else {
                        Button("Continue in…") { services.beginContinue(conversation) }
                            .buttonStyle(.borderedProminent)
                            .disabled(conversation.isTranscriptMissing)
                            .help("Carry this conversation to another Claude or to Claude Code")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { services.showsInspector.toggle() } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide details (⌥⌘I)")
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}

// MARK: - Timeline

struct TimelineColumn: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        let conversations = services.visibleConversations
        VStack(alignment: .leading, spacing: 0) {
            header(count: showsMessageHits ? services.search.hits.count : conversations.count)
            if showsMessageHits {
                MessageHitsList()
            } else if conversations.isEmpty {
                emptyTimeline
            } else {
                List(selection: $services.selectedConversationID) {
                    ForEach(TimelineGroup.group(conversations)) { group in
                        // A plain row rather than a section header: section headers stick to
                        // the top on their own opaque band, which breaks the one surface.
                        Text(group.title)
                            .font(Theme.Font.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, group.id == "Today" ? 0 : 10)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.conversations) { conversation in
                            ConversationRow(conversation: conversation,
                                            install: services.install(for: conversation),
                                            live: services.pulse.session(forConversation: conversation.cliSessionId)?.state)
                                .tag(conversation.id)
                                .listRowSeparator(.hidden)
                                .contextMenu { ConversationActions(conversation: conversation, asContextMenu: true) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 44)
            }
        }
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                Button("All conversations") { services.filter = .all }
                Section("Installs") {
                    ForEach(services.installs.filter { services.conversationCount(in: $0) > 0 }) { install in
                        Button(install.name) { services.filter = .install(install.id) }
                    }
                }
                let projects = services.projects
                if !projects.isEmpty {
                    Section("Projects") {
                        ForEach(projects.prefix(12), id: \.path) { project in
                            Button(project.name) { services.filter = .project(project.path) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(services.filterTitle)
                        .font(Theme.Font.title)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Show \(services.filterTitle)")

            Text(countText(count))
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countText(_ count: Int) -> String {
        if !services.hasLoaded { return "Looking…" }
        if showsMessageHits { return count == 1 ? "1 conversation matches" : "\(count) conversations match" }
        if !services.query.isEmpty { return count == 1 ? "1 title matches" : "\(count) titles match" }
        return count == 1 ? "1 conversation" : "\(count) conversations"
    }

    /// Once the index has caught up, a search looks inside every message; until then it
    /// narrows the timeline by title.
    private var showsMessageHits: Bool {
        !services.query.trimmingCharacters(in: .whitespaces).isEmpty && services.index.isReady
    }

    @ViewBuilder
    private var emptyTimeline: some View {
        if !services.hasLoaded {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading your conversations…")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !services.query.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: "No titles match",
                       message: "Search inside messages to look through what was said, not just titles.")
        } else {
            EmptyState(systemImage: "bubble.left.and.bubble.right", title: "No conversations yet",
                       message: "Conversations from Claude, its copies, and Claude Code appear here as soon as they exist.")
        }
    }
}

/// Conversations bucketed the way people remember them.
struct TimelineGroup: Identifiable {
    let title: String
    let conversations: [ConversationRef]
    var id: String { title }

    static func group(_ conversations: [ConversationRef], now: Date = .now) -> [TimelineGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [ConversationRef]] = [:]
        for conversation in conversations {
            let title = bucket(conversation.lastActivity, now: now, calendar: calendar)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(conversation)
        }
        return order.map { TimelineGroup(title: $0, conversations: buckets[$0] ?? []) }
    }

    static func bucket(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: date, to: now).day ?? 0
        if days < 7 { return "Previous 7 days" }
        if days < 30 { return "Previous 30 days" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

struct ConversationRow: View {
    let conversation: ConversationRef
    let install: Install?
    /// Set while Claude Code is running this conversation.
    var live: LiveSession.State?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let install {
                    InstallIcon(install: install, size: 22)
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.title)
                        .font(Theme.Font.bodyMedium)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    switch live {
                    case .needsYou:
                        Text("Needs you").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(Theme.attention)
                    case .working:
                        Text("Working").font(Theme.Font.caption).foregroundStyle(.secondary)
                    default:
                        Text(conversation.lastActivity.listStamp)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 4) {
                    if conversation.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Starred")
                    }
                    Text(secondLine)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var secondLine: String {
        if conversation.isTranscriptMissing { return "Messages were removed" }
        if let project = conversation.projectName { return project }
        return install?.name ?? ""
    }
}

// MARK: - Message search results

struct MessageHitsList: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let search = services.search
        if search.hits.isEmpty && (search.isSearching || search.lastQuery != services.query.trimmingCharacters(in: .whitespaces)) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.hits.isEmpty {
            EmptyState(systemImage: "text.magnifyingglass", title: "Nothing found",
                       message: "No message in any conversation contains “\(search.lastQuery)”.")
        } else {
            List {
                ForEach(search.hits) { hit in
                    Button {
                        if let conversation = services.snapshot.conversations.first(where: { $0.id == hit.conversationID }) {
                            services.query = ""
                            services.show(conversation)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(hit.title).font(Theme.Font.bodyMedium).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(matchText(hit))
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            ForEach(hit.excerpts.prefix(2)) { excerpt in
                                Text(highlighted(excerpt))
                                    .font(Theme.Font.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let conversation = services.snapshot.conversations.first(where: { $0.id == hit.conversationID }) {
                            ConversationActions(conversation: conversation, asContextMenu: true)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private func matchText(_ hit: HistorySearch.Hit) -> String {
        switch hit.matchingMessages {
        case 0: return "In the title"
        case 1: return "1 message"
        default: return "\(hit.matchingMessages) messages"
        }
    }

    private func highlighted(_ excerpt: HistorySearch.Excerpt) -> AttributedString {
        var text = AttributedString(excerpt.text)
        for range in excerpt.matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].foregroundColor = .primary
            text[lower..<upper].font = Theme.Font.callout.weight(.semibold)
        }
        return text
    }
}
