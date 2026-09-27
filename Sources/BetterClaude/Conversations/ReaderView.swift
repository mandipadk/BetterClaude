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
                            MessageView(message: message)
                        case .tools(_, let names):
                            ToolsLine(names: names)
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
                Button("Continue in…") {
                    services.beginTransfer(conversation)
                }
                .buttonStyle(.primary)
                .disabled(conversation.isTranscriptMissing)
                .help("Carry this conversation to another Claude or to Claude Code")
                MoreMenu {
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
                Spacer(minLength: 0)
            }

            FindField(text: $reader.findQuery)
                .frame(maxWidth: 260)
        }
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
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Find in conversation", text: $text)
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
