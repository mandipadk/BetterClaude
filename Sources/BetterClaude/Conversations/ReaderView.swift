import CoworkKit
import SwiftUI

/// Reads a conversation without opening Claude.
struct ReaderView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reader = services.reader
        Group {
            switch reader.state {
            case .idle:
                EmptyState(systemImage: "text.bubble",
                           title: "Pick a conversation",
                           message: "Choose one on the left to read it here. Claude doesn't need to be open.")
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Opening…").font(Theme.Font.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                missing
            case .failed(let message):
                EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't open it", message: message)
            case .ready:
                document
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.fade, value: reader.state)
    }

    private var missing: some View {
        let name = services.reader.install?.name ?? "Claude"
        return EmptyState(
            systemImage: "clock.badge.xmark",
            title: "Its messages are gone",
            message: "\(name) still lists this conversation, but Claude Code deleted its messages. It removes conversations 30 days after they were last used.")
    }

    // MARK: Document

    private var document: some View {
        let reader = services.reader
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let conversation = reader.conversation {
                    ReaderHeader(conversation: conversation, install: reader.install,
                                 readable: reader.readable)
                        .padding(.bottom, Theme.Space.xl)
                }
                let entries = reader.visibleEntries
                // While finding, only matching messages show, and markers between them would mislead.
                let anchors = reader.findQuery.isEmpty
                    ? TimelineMarkers.anchors(reader.markers, times: entries.map(\.time)) : [:]
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        ForEach(anchors[index] ?? []) { marker in MarkerLine(marker: marker) }
                        switch entry {
                        case .message(let message):
                            MessageView(message: message,
                                        claims: message.role == .user ? [] : message.timestamp.flatMap { reader.doubtfulClaims[$0] } ?? [],
                                        onFork: reader.forkPoints[message.id] == nil ? nil : {
                                            services.forking = ForkRequest(messageID: message.id)
                                        })
                        case .tools(_, let names):
                            ToolsLine(names: names)
                        case .compaction(let compaction):
                            CompactionMarker(compaction: compaction, conversation: reader.conversation,
                                             number: entries.compactMap { entry -> String? in
                                                 if case .compaction(let other) = entry, other.summary != nil { return other.id }
                                                 return nil
                                             }.firstIndex(of: compaction.id))
                        case .recap(_, let text, _):
                            RecapLine(text: text)
                        }
                    }
                    ForEach(anchors[entries.count] ?? []) { marker in MarkerLine(marker: marker) }
                }
                .task(id: "\(reader.conversation?.id ?? "")#\(services.index.generation)#\(reader.state == .ready)") {
                    await reader.loadAnnotations(index: services.index.index, generation: services.index.generation)
                }
                if reader.visibleEntries.isEmpty, !reader.findQuery.isEmpty {
                    Text("No message here contains “\(reader.findQuery)”.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 56)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(reader.conversation?.id)
    }
}

extension EnvironmentValues {
    /// True where the reader is shown inside a sheet, which can't open another sheet on top.
    @Entry var readerActionsHidden = false
}

struct ReaderHeader: View {
    @Environment(AppServices.self) private var services
    @Environment(\.readerActionsHidden) private var actionsHidden
    let conversation: ConversationRef
    let install: Install?
    let readable: ReadableConversation?

    var body: some View {
        @Bindable var reader = services.reader
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text(conversation.title)
                    .font(Theme.Font.title)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(context)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            FindField(text: $reader.findQuery)
                .frame(maxWidth: 260)
        }
    }
}

extension ReaderHeader {
    /// One line of where and when: "Claude Code in billing-service, today at 1:21 PM".
    var context: String {
        var line = install?.name ?? "Claude"
        if let project = conversation.projectName { line += " in \(project)" }
        let when = conversation.lastActivity
        let day = Calendar.current.isDateInToday(when) ? "today" : Calendar.current.isDateInYesterday(when) ? "yesterday"
            : when.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return "\(line), \(day) at \(when.formatted(date: .omitted, time: .shortened))"
    }

    /// The conversations this one came from or went on in, when they're still on this Mac.
    func related(_ readable: ReadableConversation) -> [(label: String, conversation: ConversationRef)] {
        Self.related(readable, services: services)
    }

    static func related(_ readable: ReadableConversation, services: AppServices) -> [(label: String, conversation: ConversationRef)] {
        readable.relatives.compactMap { relative in
            switch relative {
            case .continuedIn(let id):
                return services.conversation(forSession: id).map { ("Continued in", $0) }
            case .forkedFrom(let id):
                return services.conversation(forSession: id).map { ("Forked from", $0) }
            }
        }
    }

    /// "In 3 days" when Claude Code's cleanup is near, for a conversation Claude Code owns.
    static func deletionText(_ conversation: ConversationRef, services: AppServices) -> String? {
        guard let url = conversation.claudeCodeSession?.transcriptURL,
              !url.path.hasPrefix(Vault.root.path),
              let expiry = Vault.expiry(of: url, period: services.kept.period) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: .now, to: expiry).day ?? 0
        guard days < 10 else { return nil }
        return days <= 0 ? "Today" : days == 1 ? "Tomorrow" : "In \(days) days"
    }
}

/// One fact as a small label over its value — structure instead of a joined line.
struct Fact<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            value
                .font(Theme.Font.callout)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FindField: View {
    @Binding var text: String
    var prompt = "Find in conversation"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Font.callout)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.control))
        .background {
            Button("") { focused = true }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}

struct MessageView: View {
    let message: MessageText
    /// Claims in this reply that the transcript doesn't back.
    var claims: [Claims.Claim] = []
    var onFork: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.role == .user ? "You" : "Claude")
                    .font(Theme.Font.headline)
                if let time = message.timestamp {
                    Text(time.formatted(.dateTime.hour().minute()))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if let onFork {
                    Button(action: onFork) {
                        Label("Fork from here", systemImage: "arrow.triangle.branch")
                            .font(Theme.Font.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
                    .help("Start a new conversation with everything up to this message")
                    .accessibilityHidden(!hovering)
                }
            }
            if message.role == .user {
                Text(message.text)
                    .font(Theme.Font.reading)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile, style: .continuous))
            } else {
                MarkdownView(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(claims) { claim in
                Text(claimSentence(claim))
                    .font(Theme.Font.callout)
                    .foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .contextMenu {
            if let onFork { Button("Fork from Here…", action: onFork) }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
    }
}

extension ReadableConversation.Entry {
    /// When it happened, where the transcript says.
    var time: Date? {
        switch self {
        case .message(let message): return message.timestamp
        case .tools: return nil
        case .compaction(let compaction): return compaction.timestamp
        case .recap(_, _, let timestamp): return timestamp
        }
    }
}

/// Something that happened during the conversation, at the moment it happened: one quiet line
/// between messages. Opening it shows the matching tab in the inspector.
struct MarkerLine: View {
    @Environment(AppServices.self) private var services
    let marker: TimelineMarker

    var body: some View {
        Button {
            services.inspectorTab = tab
            services.showsInspector = true
        } label: {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(sentence)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .layoutPriority(1)
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(sentence)
    }

    private var tab: InspectorTab {
        switch marker.kind {
        case .subagents: return .activity
        case .modelSwitch: return .checks
        case .cacheBreak: return .cost
        }
    }

    private var symbol: String {
        switch marker.kind {
        case .subagents: return "arrow.triangle.branch"
        case .modelSwitch: return "arrow.triangle.swap"
        case .cacheBreak: return "clock"
        }
    }

    private var help: String {
        switch marker.kind {
        case .subagents: return "Show who was working when"
        case .modelSwitch: return "Show every change of model"
        case .cacheBreak: return "Show cost and context"
        }
    }

    private var sentence: String {
        switch marker.kind {
        case .subagents(let count, let descriptions, let cost):
            let what = count == 1 ? (descriptions.first.map { "A sub-agent set off: \($0)" } ?? "A sub-agent set off")
                                  : "\(count) sub-agents set off together"
            return cost >= 0.01 ? "\(what), \(Self.dollars(cost))" : what
        case .modelSwitch(let change):
            return ModelSwitchesView.sentence(change)
        case .cacheBreak(let gap, let cost):
            return "Back after \(Self.duration(gap)). This reply rewrote the cache, \(Self.dollars(cost)) at list prices"
        }
    }

    static func duration(_ gap: TimeInterval) -> String {
        let minutes = Int(gap / 60)
        if minutes < 90 { return "\(minutes) minutes" }
        let hours = Int((gap / 3_600).rounded())
        return hours == 1 ? "an hour" : "\(hours) hours"
    }

    static func dollars(_ value: Double) -> String {
        value < 0.01 ? "under 1¢" : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}

extension MessageView {
    func claimSentence(_ claim: Claims.Claim) -> String {
        switch claim.verdict {
        case .contradicted(let evidence): return "Says “\(claim.sentence)”, but \(evidence)."
        default: return "Says “\(claim.sentence)”, but nothing in the transcript does this."
        }
    }
}

struct ToolsLine: View {
    let names: [String]

    var body: some View {
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return HStack(spacing: 7) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 11))
            Text(names.count == 1 ? "Used \(unique[0])" : "Used \(names.count) tools: \(unique.prefix(4).joined(separator: ", "))")
                .lineLimit(1)
        }
        .font(Theme.Font.callout)
        .foregroundStyle(.secondary)
    }
}

/// Where Claude compacted the conversation, and what it kept.
struct CompactionMarker: View {
    @Environment(AppServices.self) private var services
    let compaction: ReadableConversation.Compaction
    var conversation: ConversationRef? = nil
    /// Which summary of the conversation this is, to match what it forgot.
    var number: Int? = nil
    @State private var expanded = false
    @State private var forgotten: [CompactionGaps.Item] = []
    @State private var confirming = false
    @State private var added = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 10) {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Text(compaction.trigger == "manual" ? "Compacted on request" : "Claude compacted the conversation here")
                    .font(Theme.Font.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            Text(explanation)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = compaction.summary, !summary.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    MarkdownView(summary)
                        .padding(.top, Theme.Space.s)
                } label: {
                    Text("What Claude kept").font(Theme.Font.callout.weight(.medium))
                }
                .tint(Theme.accent)
            }
            if !forgotten.isEmpty { forgottenList }
        }
        .accessibilityElement(children: .contain)
        .task(id: "\(conversation?.id ?? "")#\(number ?? -1)#\(services.index.generation)") {
            guard let conversation, let number, let index = services.index.index else { return }
            let gaps = (try? await CompactionGaps.gaps(conversationID: conversation.id, index: index)) ?? []
            forgotten = gaps.indices.contains(number) ? gaps[number].forgotten : []
        }
    }

    private var forgottenList: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.bubble").foregroundStyle(.secondary)
                Text("The summary doesn't mention \(forgotten.count == 1 ? "one thing" : "\(forgotten.count) things") you said before it, so Claude no longer knows \(forgotten.count == 1 ? "it" : "them"):")
                    .font(Theme.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(forgotten.prefix(8)) { item in
                Text("“\(item.text)”")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Spacer().frame(width: 16)
                if let project = conversation?.projectPath {
                    Button(added ? "Added to CLAUDE.md" : "Add to CLAUDE.md…") { confirming = true }
                        .buttonStyle(.bordered)
                        .disabled(added)
                        .confirmationDialog("Add \(forgotten.count == 1 ? "this" : "these \(forgotten.count)") to this project's CLAUDE.md?", isPresented: $confirming) {
                            Button("Add") {
                                let lines = forgotten.map { Corrections.rule(from: $0.text) }
                                added = (try? Corrections.add(lines, to: Corrections.target(for: Projects.root(of: project)))) != nil
                            }
                        } message: {
                            Text("Every session in the project then starts knowing them. Undo it from History.")
                        }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(forgotten.map { "- \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
    }

    private var explanation: String {
        let past = "From here on, Claude no longer sees the messages above, only its summary of them."
        guard let before = compaction.tokensBefore, let after = compaction.tokensAfter, before > 0 else { return past }
        let shrink = Int((1 - Double(after) / Double(before)) * 100)
        return "\(past) It went from \(Self.tokens(before)) to \(Self.tokens(after)) tokens, \(shrink)% smaller."
    }

    static func tokens(_ count: Int) -> String {
        count >= 1_000 ? "\(count / 1_000)K" : "\(count)"
    }
}

/// A recap Claude wrote when you stepped away.
struct RecapLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.append").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude's recap").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(Theme.Font.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

