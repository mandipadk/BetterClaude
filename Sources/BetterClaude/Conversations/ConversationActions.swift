import AppKit
import CoworkKit
import SwiftUI

/// Everything you can do with a conversation, in one order and one set of words, for the
/// reader's ⋯ menu and every row's context menu.
struct ConversationActions: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef
    /// A row's menu starts with Open and the primary action, which the reader shows as buttons.
    var asContextMenu = false

    var body: some View {
        let external = conversation.external != nil
        let missing = conversation.isTranscriptMissing
        if asContextMenu {
            Button("Open") { services.show(conversation) }
            if external {
                Button("Write a Handoff…") { services.beginHandoff(conversation) }
            } else {
                Button("Continue in…") { services.beginContinue(conversation) }.disabled(missing)
            }
            Divider()
        }
        if !external {
            Button("Show Changes…") { services.rewinding = RewindModel(conversation: conversation) }
            Button("Play Changes…") { services.rewinding = RewindModel(conversation: conversation, playing: true) }
        }
        Button("Replay on Another Model…") { services.replaying = ReplayModel(conversation: conversation) }
            .disabled(missing)
        if let project = services.coworkProject(for: conversation) {
            Button("Move Project “\(project.name)” to Claude Code…") { services.beginPort(project) }
            Button("Copy Project “\(project.name)” to…") { services.beginProjectCopy(project) }
        }
        if !external {
            Button("Write a Handoff…") { services.beginHandoff(conversation) }.disabled(missing)
        }
        Divider()
        if let session = conversation.claudeCodeSession, !session.resolvedCwd.isEmpty,
           !session.transcriptURL.path.hasPrefix(Vault.root.path) {
            Button("Resume in Terminal") {
                services.resumeInTerminal(cwd: session.resolvedCwd, sessionId: session.sessionId)
            }
        }
        // Exports read what the reader has open.
        if conversation.id == services.reader.conversation?.id {
            Button("Export as Markdown…") { services.reader.exportMarkdown() }
            Button("Export as Web Page…") { services.reader.exportWebPage() }
        }
        Button("Show in Finder") { services.revealInFinder(conversation) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("betterclaude://conversation/\(conversation.id)", forType: .string)
        }
        if let install = services.install(for: conversation), install.appURL != nil {
            Divider()
            Button("Open in \(install.name)") { services.open(install) }
        }
    }
}

/// The toolbar's Share menu: everything that makes something to give someone.
struct ShareActions: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef

    var body: some View {
        Button("Export as Markdown…") { services.reader.exportMarkdown() }
        Button("Export as Web Page…") { services.reader.exportWebPage() }
        Divider()
        Button("Write a Handoff…") { services.beginHandoff(conversation) }.disabled(conversation.isTranscriptMissing)
        Button("Replay on Another Model…") { services.replaying = ReplayModel(conversation: conversation) }
            .disabled(conversation.isTranscriptMissing)
    }
}

/// The toolbar's ⋯ menu: everything else.
struct MoreActions: View {
    @Environment(AppServices.self) private var services
    let conversation: ConversationRef

    var body: some View {
        if let session = conversation.claudeCodeSession, !session.resolvedCwd.isEmpty,
           !session.transcriptURL.path.hasPrefix(Vault.root.path) {
            Button("Resume in Terminal") { services.resumeInTerminal(cwd: session.resolvedCwd, sessionId: session.sessionId) }
        }
        if conversation.external == nil {
            Button("Play Changes…") { services.rewinding = RewindModel(conversation: conversation, playing: true) }
        }
        if let project = services.coworkProject(for: conversation) {
            Button("Move Project “\(project.name)” to Claude Code…") { services.beginPort(project) }
            Button("Copy Project “\(project.name)” to…") { services.beginProjectCopy(project) }
        }
        Button("Find in Conversation") { services.reader.showsFind = true }.keyboardShortcut("f")
        Divider()
        Button("Show in Finder") { services.revealInFinder(conversation) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("betterclaude://conversation/\(conversation.id)", forType: .string)
        }
        if let install = services.install(for: conversation), install.appURL != nil {
            Divider()
            Button("Open in \(install.name)") { services.open(install) }
        }
    }
}
