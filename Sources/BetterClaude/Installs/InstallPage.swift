import AppKit
import CoworkKit
import SwiftUI

/// One Claude on this Mac: who it's signed into, what it holds, and where it lives.
struct InstallPage: View {
    @Environment(AppServices.self) private var services
    let install: Install
    @State private var confirmingRemoval = false
    @AppStorage("installTab") private var tab: InstallTab = .conversations

    enum InstallTab: String, CaseIterable, Identifiable {
        case conversations, setup, health
        var id: String { rawValue }
        var title: String {
            switch self {
            case .conversations: return "Conversations"
            case .setup: return "Setup"
            case .health: return "Health"
            }
        }
    }

    /// Setup for what can be set up; Health for what Claude Code's records can tell.
    private var tabs: [InstallTab] {
        var tabs: [InstallTab] = [.conversations]
        if !install.isExternal || RecallConnection.target(for: install) != nil { tabs.append(.setup) }
        if install.kind != .external(.otherMac) && !install.isExternal { tabs.append(.health) }
        return tabs
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, Theme.Space.l)
                notices
                if tabs.count > 1 {
                    Segmented(options: tabs.map { ($0, $0.title) }, selection: $tab)
                        .padding(.bottom, Theme.Space.s)
                }
                switch tabs.contains(tab) ? tab : .conversations {
                case .conversations:
                    conversations
                case .setup:
                    let others = services.installs.filter { $0.id != install.id && $0.kind != .science && !$0.isExternal }
                    if !install.isExternal, !others.isEmpty {
                        Menu("Compare With…") {
                            ForEach(others) { other in
                                Button(other.name) { services.comparing = InstallComparison(left: install, right: other) }
                            }
                        }
                        .menuStyle(.button)
                        .buttonStyle(.secondary)
                        .fixedSize()
                        .padding(.top, Theme.Space.m)
                        .padding(.bottom, Theme.Space.s)
                        .help("See what this install and another are set up with, side by side")
                    }
                    if !install.isExternal { SetupSection(install: install) }
                    if install.kind == .claudeCode { CommandRulesSection(configDir: install.dataRoot) }
                    if RecallConnection.target(for: install) != nil { RecallSection(install: install) }
                    details
                case .health:
                    HealthSection(install: install)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog(removalTitle, isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(install.kind == .external(.otherMac) ? "Remove History" : "Remove Conversations", role: .destructive) {
                if install.kind == .external(.otherMac) { services.removeOtherMac(install) } else { services.removeClaudeWebImport() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(install.kind == .external(.otherMac)
                 ? "Better Claude forgets what it read from this backup. The backup file itself stays where it is, and you can open it again."
                 : "Better Claude forgets the conversations it imported. Your export file stays where it is, and you can import it again.")
        }
    }

    private var removalTitle: String {
        install.kind == .external(.otherMac) ? "Remove \(install.name)'s history?" : "Remove the imported claude.ai conversations?"
    }

    private var isRunning: Bool { services.isRunning(install) }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            InstallIcon(install: install, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(install.name).font(Theme.Font.display)
                Text(summary)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.l)
            if install.appURL != nil {
                Button(isRunning ? "Show" : "Open") { services.open(install) }
                    .buttonStyle(.primary)
                    .keyboardShortcut("o", modifiers: .command)
            }
            MoreMenu {
                let others = services.installs.filter { $0.id != install.id && $0.kind != .science }
                if !others.isEmpty {
                    Menu("Compare With") {
                        ForEach(others) { other in
                            Button(other.name) {
                                services.comparing = InstallComparison(left: install, right: other)
                            }
                        }
                    }
                    Divider()
                }
                if install.kind == .external(.otherMac) {
                    Button("Open a Newer Backup…") { services.openOtherMac() }
                    Button("Remove This Mac's History…") { confirmingRemoval = true }
                    Divider()
                }
                if install.kind == .external(.claudeWeb) {
                    Button("Import a Newer Export…") { services.importClaudeWebExport() }
                    Button("Remove Imported Conversations…") { confirmingRemoval = true }
                    Divider()
                }
                Button("Show Data Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([install.dataRoot])
                }
                if let app = install.appURL {
                    Button("Show App in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                }
            }
        }
    }

    /// Who this install is signed into, or what kind of install it is.
    private var summary: String {
        if let email = account?.emailAddress {
            return isRunning ? "Open now, signed in as \(email)" : "Signed in as \(email)"
        }
        switch install.kind {
        case .claudeCode: return "The command line, and the Code tab's conversations"
        case .science: return "Research projects and their files"
        case .external(.claudeWeb): return "Conversations imported from your claude.ai export, read-only"
        case .external(.codex): return "Codex sessions on this Mac, read-only"
        case .external(.otherMac): return "Conversations kept on another Mac, opened from its backup, read-only"
        case .parallex: return isRunning ? "Open now, a copy made by Parallex" : "A copy of Claude made by Parallex"
        case .desktop: return isRunning ? "Open now" : "Claude for Mac"
        }
    }

    private var account: AccountRef? {
        let accounts = services.snapshot.accounts[install.id] ?? []
        return accounts.first(where: \.isSignedIn) ?? accounts.max { $0.sessionCount < $1.sessionCount }
    }

    // MARK: Sections

    @ViewBuilder
    private var notices: some View {
        let hints = services.credentialHints[install.id] ?? []
        let missing = services.snapshot.conversations(in: install.id).filter(\.isTranscriptMissing).count
        if !hints.isEmpty || missing > 0 {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !hints.isEmpty {
                    let names = hints.map(\.name)
                    InstallNotice(
                        symbol: "key.fill",
                        title: names.count == 1 ? "A key is saved in plain text" : "\(names.count) keys are saved in plain text",
                        detail: "\(names.joined(separator: ", ")) in \(hints[0].file.lastPathComponent). Any app that can read this folder can read \(names.count == 1 ? "it" : "them"). Keep keys in your shell profile or the Keychain instead.",
                        action: ("Show File", { NSWorkspace.shared.activateFileViewerSelecting([hints[0].file]) }))
                }
                if missing > 0 {
                    InstallNotice(
                        symbol: "clock.badge.xmark",
                        title: missing == 1 ? "One conversation lost its messages" : "\(missing) conversations lost their messages",
                        detail: "Claude Code deletes conversations 30 days after they were last used. Their titles are still listed, but what was said is gone.")
                }
            }
            .padding(.bottom, Theme.Space.xl)
        }
    }

    private var conversations: some View {
        let list = services.snapshot.conversations(in: install.id)
        return DetailSection(title: "Conversations", subtitle: conversationsSubtitle(list)) {
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(list.prefix(5)) { conversation in
                        Button {
                            services.show(conversation)
                        } label: {
                            HStack {
                                Text(conversation.title).font(Theme.Font.body).lineLimit(1)
                                Spacer(minLength: Theme.Space.m)
                                Text(conversation.lastActivity.listStamp)
                                    .font(Theme.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .contentShape(.rect)
                        }
                        .buttonStyle(HoverRowStyle())
                    }
                }
                .padding(.horizontal, -8)
                if list.count > 5 {
                    Button("Show All \(list.count)") {
                        services.filter = .install(install.id)
                        services.destination = .conversations
                    }
                    .buttonStyle(.secondary)
                }
            }
        }
    }

    private func conversationsSubtitle(_ list: [ConversationRef]) -> String {
        let missing = list.filter(\.isTranscriptMissing).count
        switch list.count {
        case 0: return install.kind == .science ? "Claude Science keeps projects rather than conversations." : "Nothing here yet."
        case 1: return missing == 1 ? "One conversation, whose messages were removed." : "One conversation."
        default:
            let base = "\(list.count) conversations"
            return missing == 0 ? base + "." : base + ". The messages of \(missing) were removed."
        }
    }

    private var details: some View {
        DetailSection(title: "Where it lives") {
            VStack(alignment: .leading, spacing: 6) {
                if let email = account?.emailAddress {
                    FactRow(label: "Account", value: email)
                }
                FactRow(label: "Data", value: services.snapshot.paths.abbreviating(install.dataRoot.path))
                if let app = install.appURL {
                    FactRow(label: "App", value: services.snapshot.paths.abbreviating(app.path))
                }
            }
        }
    }
}

/// A plain row that shows a quiet fill under the pointer.
struct HoverRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(hovering || configuration.isPressed ? Theme.subtleFill : .clear))
            .onHover { hovering = $0 }
    }
}
