import CoworkKit
import SwiftUI
import TipKit

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
        return VStack(spacing: 0) {
            // Outside the scroll view, so it stays put however far down you are.
            if reader.showsFind { findBar }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let conversation = reader.conversation {
                        ReaderHeader(conversation: conversation, install: reader.install,
                                     readable: reader.readable)
                            .padding(.bottom, 22)
                    }
                    if reader.conversation?.external == nil {
                        TipView(ReaderTip())
                            .tipBackground(Theme.Surface.group)
                            .padding(.bottom, Theme.Space.l)
                    }
                    entryList
                        .task(id: "\(reader.conversation?.id ?? "")#\(services.index.generation)#\(reader.state == .ready)") {
                            await reader.loadAnnotations(index: services.index.index)
                        }
                }
                .padding(.horizontal, 34)
                .padding(.top, 22)
                .padding(.bottom, 48)
                .frame(maxWidth: 748, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.Surface.window)
        .id(reader.conversation?.id)
    }

    private var findBar: some View {
        @Bindable var reader = services.reader
        return HStack(spacing: Theme.Space.s) {
            FindField(text: $reader.findQuery, focusRequest: reader.findFocusRequest)
                .frame(maxWidth: 260)
                .onKeyPress(.escape) { reader.closeFind(); return .handled }
            Spacer(minLength: 0)
            Button("Done") { reader.closeFind() }
                .buttonStyle(.plain)
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 8)
        .background(Theme.Surface.window)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.Surface.line).frame(height: 0.5) }
    }

    /// The messages and everything between them, worked out once per pass.
    private var entryList: some View {
        let reader = services.reader
        let entries = reader.visibleEntries
        let finding = reader.isFinding
        // While finding, only matching messages show, and markers between them would mislead.
        let anchors = finding ? [:] : TimelineMarkers.anchors(reader.markers, times: entries.map(\.time))
        let days = Self.dayStarts(entries)
        var summaries: [String: Int] = [:]
        for entry in entries {
            if case .compaction(let compaction) = entry, compaction.summary != nil {
                summaries[compaction.id] = summaries.count
            }
        }
        let assistant = reader.assistantName
        return VStack(alignment: .leading, spacing: 0) {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if let day = days[index] { DayLine(date: day) }
                    ForEach(anchors[index] ?? []) { marker in MarkerLine(marker: marker) }
                    switch entry {
                    case .message(let message):
                        MessageView(message: message,
                                    assistantName: assistant,
                                    claims: reader.claims(for: message),
                                    onFork: reader.forkPoints[message.id] == nil ? nil : {
                                        services.forking = ForkRequest(messageID: message.id)
                                    })
                    case .tools(_, let names):
                        ToolsLine(names: names)
                    case .compaction(let compaction):
                        CompactionMarker(compaction: compaction, conversation: reader.conversation,
                                         number: summaries[compaction.id])
                    case .recap(_, let text, _):
                        RecapLine(text: text, assistantName: assistant)
                    case .notice(let notice):
                        NoticeLine(notice: notice)
                    }
                }
                ForEach(anchors[entries.count] ?? []) { marker in MarkerLine(marker: marker) }
            }
            if entries.isEmpty, finding {
                Text("No message here contains “\(reader.findQuery.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The local day each entry starts, for the entries where it differs from the one before.
    static func dayStarts(_ entries: [ReadableConversation.Entry]) -> [Int: Date] {
        var starts: [Int: Date] = [:]
        var current: Date?
        for (index, entry) in entries.enumerated() {
            guard let time = entry.time else { continue }
            let day = Calendar.current.startOfDay(for: time)
            if let current, current != day { starts[index] = day }
            current = day
        }
        return starts
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
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Surface.primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(context)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Surface.secondary)
                .lineLimit(1)
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
    /// Changes when something asks for the cursor to be put here.
    var focusRequest: Int? = nil
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
        .onAppear { if focusRequest != nil { focused = true } }
        .onChange(of: focusRequest) { focused = true }
    }
}

struct MessageView: View {
    let message: MessageText
    /// Who replied: Claude, or Codex for a Codex conversation.
    var assistantName = "Claude"
    /// Claims in this reply that the transcript doesn't back.
    var claims: [Claims.Claim] = []
    var onFork: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.role == .user ? "You" : assistantName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Surface.primary)
                if let time = message.timestamp {
                    Text(time.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Surface.secondary)
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
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.Surface.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.Surface.fill, in: .rect(cornerRadius: 14, style: .continuous))
                }
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: name == "Image" ? "photo" : "doc")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Surface.secondary)
                        .lineLimit(1)
                }
            } else {
                MarkdownView(message.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(claims) { claim in
                Text(claimSentence(claim))
                    .font(.system(size: 12.5))
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
        case .notice(let notice): return notice.timestamp
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
            if case .subagents(let count, let descriptions, let cost) = marker.kind {
                // A burst of sub-agents: one grouped row, like a message of its own.
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 13))
                        .foregroundStyle(Theme.Surface.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(count == 1 ? "A sub-agent looked around" : "\(count) sub-agents looked around")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.Surface.primary)
                        if !descriptions.isEmpty {
                            Text(descriptions.joined(separator: ", ")).font(.system(size: 12))
                                .foregroundStyle(Theme.Surface.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if cost >= 0.01 { RowValue(text: Self.dollars(cost)) }
                    Chevron()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.Surface.group, in: .rect(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.Surface.line, lineWidth: 0.5))
                .contentShape(.rect)
            } else {
                HStack(spacing: 12) {
                    Rectangle().fill(Theme.Surface.line).frame(height: 0.5)
                    Text(sentence)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Surface.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .layoutPriority(1)
                    Rectangle().fill(Theme.Surface.line).frame(height: 0.5)
                }
                .contentShape(.rect)
            }
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
            return "Back after \(Self.duration(gap)). Rewriting the cache cost \(Self.dollars(cost)) more at list prices"
        }
    }

    static func duration(_ gap: TimeInterval) -> String {
        let minutes = Int(gap / 60)
        if minutes < 90 { return "\(minutes) minutes" }
        let hours = Int((gap / 3_600).rounded())
        return hours == 1 ? "an hour" : "\(hours) hours"
    }

    static func dollars(_ value: Double) -> String { Pricing.dollars(value) }
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
        return Text(names.count == 1 ? "Used \(unique[0])" : "Used \(names.count) tools: \(unique.prefix(4).joined(separator: ", "))")
            .lineLimit(1)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Surface.tertiary)
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
                        .buttonStyle(.secondary)
                        .disabled(added)
                        .confirmationDialog("Add \(forgotten.count == 1 ? "this" : "these \(forgotten.count)") to this project's CLAUDE.md?", isPresented: $confirming) {
                            Button("Add") {
                                let lines = forgotten.map { Corrections.rule(from: $0.text) }
                                do {
                                    try Corrections.add(lines, to: Corrections.target(for: Projects.root(of: project)))
                                    added = true
                                } catch {
                                    services.errorMessage = "Couldn't add them to CLAUDE.md: \(ContinueModel.explain(error))"
                                }
                            }
                        } message: {
                            Text("Every session in the project then starts knowing them. Undo it from History.")
                        }
                }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(forgotten.map { "- \($0.text)" }.joined(separator: "\n"), forType: .string)
                }
                .buttonStyle(.secondary)
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
    var assistantName = "Claude"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "text.append").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(assistantName)'s recap").font(Theme.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(text).font(Theme.Font.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}


/// Something between messages that isn't a message: a command you ran, a reply you stopped,
/// a background task that finished, a reply that failed, or an attempt you rewound.
struct NoticeLine: View {
    let notice: ReadableConversation.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.Surface.tertiary)
            Text(notice.text)
                .font(.system(size: 12))
                .foregroundStyle(notice.kind == .apiError ? Theme.attention : Theme.Surface.secondary)
                .lineLimit(notice.kind == .apiError ? 3 : 2)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.kind {
        case .command: return "command"
        case .shell: return "terminal"
        case .interrupted: return "stop.circle"
        case .notification: return "bell"
        case .apiError: return "exclamationmark.triangle"
        case .rewound: return "arrow.uturn.backward"
        }
    }
}

/// Where the conversation moves on to another day.
struct DayLine: View {
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.Surface.line).frame(height: 0.5)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Surface.secondary)
                .fixedSize()
            Rectangle().fill(Theme.Surface.line).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
