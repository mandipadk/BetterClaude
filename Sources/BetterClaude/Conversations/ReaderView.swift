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
                LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                    ForEach(reader.visibleEntries) { entry in
                        switch entry {
                        case .message(let message):
                            MessageView(message: message,
                                        onFork: reader.forkPoints[message.id] == nil ? nil : {
                                            services.forking = ForkRequest(messageID: message.id)
                                        })
                        case .tools(_, let names):
                            ToolsLine(names: names)
                        case .compaction(let compaction):
                            CompactionMarker(compaction: compaction)
                        case .recap(_, let text, _):
                            RecapLine(text: text)
                        }
                    }
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

struct ReaderHeader: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    let install: Install?
    let readable: ReadableConversation?

    var body: some View {
        @Bindable var reader = services.reader
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Text(conversation.title)
                    .font(Theme.Font.display)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if conversation.external != nil {
                    // Outside conversations can't become Claude Code transcripts; a brief
                    // carries them on instead.
                    Button("Write a Handoff…") { services.beginHandoff(conversation) }
                        .buttonStyle(.primary)
                        .help("A one-page brief of this conversation, to continue it in a fresh one")
                } else {
                    Button("Continue in…") {
                        services.beginContinue(conversation)
                    }
                    .buttonStyle(.primary)
                    .disabled(conversation.isTranscriptMissing)
                    .help("Carry this conversation to another Claude or to Claude Code")
                }
                MoreMenu {
                    if conversation.external == nil {
                        Button("Write a Handoff…") { services.beginHandoff(conversation) }
                            .disabled(conversation.isTranscriptMissing)
                        Divider()
                    }
                    if let session = conversation.claudeCodeSession, !session.resolvedCwd.isEmpty,
                       !session.transcriptURL.path.hasPrefix(Vault.root.path) {
                        Button("Resume in Terminal") {
                            services.resumeInTerminal(cwd: session.resolvedCwd, sessionId: session.sessionId)
                        }
                        Divider()
                    }
                    Button("Export as Markdown…") { services.reader.exportMarkdown() }
                    Button("Show in Finder") { services.revealInFinder(conversation) }
                    if let install, install.appURL != nil {
                        Divider()
                        Button("Open \(install.name)") { services.open(install) }
                    }
                }
            }

            HStack(alignment: .top, spacing: 28) {
                if let install {
                    Fact(label: "In") {
                        HStack(spacing: 5) {
                            InstallIcon(install: install, size: 16)
                            Text(install.name)
                        }
                    }
                }
                if let project = conversation.projectName {
                    Fact(label: "Project") { Text(project) }
                }
                if let model = readable?.model ?? conversation.model {
                    Fact(label: "Model") { Text(humanModelName(model)) }
                }
                Fact(label: "Last active") { Text(conversation.lastActivity.listStamp) }
                if let readable {
                    Fact(label: "Messages") { Text("\(readable.messageCount)") }
                }
                if let deletion = deletionText {
                    Fact(label: "Claude Code deletes it") { Text(deletion) }
                        .help("Claude Code removes conversations \(Int(services.kept.period / 86_400)) days after they were last used. Better Claude keeps a copy.")
                }
                Spacer(minLength: 0)
            }

            FindField(text: $reader.findQuery)
                .frame(maxWidth: 260)
        }
    }
}

extension ReaderHeader {
    /// "in 3 days" when Claude Code's cleanup is near, for a conversation Claude Code owns.
    var deletionText: String? {
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fade, value: hovering)
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
    let compaction: ReadableConversation.Compaction
    @State private var expanded = false

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
        }
        .accessibilityElement(children: .contain)
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

