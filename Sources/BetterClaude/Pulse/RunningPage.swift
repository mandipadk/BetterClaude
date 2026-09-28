import AppKit
import CoworkKit
import SwiftUI

/// Every Claude Code session running now, the ones waiting for you first.
struct RunningPage: View {
    @Environment(AppServices.self) private var services
    @AppStorage(PulseNotifier.needsYouKey) private var notifyNeedsYou = true
    @AppStorage(PulseNotifier.finishedKey) private var notifyFinished = true
    @State private var hookError: String?

    var body: some View {
        let pulse = services.pulse
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(pulse).padding(.bottom, Theme.Space.xl)

                if pulse.sessions.isEmpty {
                    DetailSection(title: "Nothing running") {
                        Text("When Claude Code is working in a terminal or in Claude's Code tab, it shows up here, and you'll hear from Better Claude the moment it needs you.")
                            .font(Theme.Font.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                group("Needs you", subtitle: "Claude asked something and is waiting for your answer.",
                      pulse.sessions.filter { $0.state == .needsYou })
                group("Working", subtitle: nil, pulse.sessions.filter { $0.state == .working })
                group("Waiting for your next message", subtitle: nil, pulse.sessions.filter { $0.state == .idle })

                DetailSection(title: "Alerts") {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ExplainedToggle(title: "When Claude needs you",
                                        detail: "A permission to grant or a question to answer. Not shown while you're already in the app it's running in.",
                                        isOn: $notifyNeedsYou)
                        ExplainedToggle(title: "When a long turn finishes",
                                        detail: "After Claude has been working for a minute or more.",
                                        isOn: $notifyFinished)
                        ExplainedToggle(title: "Say what Claude asked",
                                        detail: hookError ?? "Adds three small hooks to Claude Code's settings so an alert can include Claude's question and any error. Turning this off takes out exactly those hooks. Your settings are backed up first.",
                                        isOn: Binding(get: { pulse.hooksInstalled }, set: { setHooks($0) }))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { pulse.read() }
    }

    private func header(_ pulse: PulseModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Running now").font(Theme.Font.display)
            Text("Claude Code sessions on this Mac, in any terminal and in Claude's Code tab.")
                .font(Theme.Font.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(pulse.sessions.count)")
                    .font(Theme.Font.title)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(pulse.sessions.count == 1 ? "session" : "sessions")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                if !pulse.needingYou.isEmpty {
                    Text("\(pulse.needingYou.count) need\(pulse.needingYou.count == 1 ? "s" : "") you")
                        .font(Theme.Font.callout.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 8)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func group(_ title: String, subtitle: String?, _ sessions: [LiveSession]) -> some View {
        if !sessions.isEmpty {
            DetailSection(title: title, subtitle: subtitle) {
                VStack(spacing: 0) {
                    ForEach(sessions) { session in
                        LiveSessionRow(session: session)
                        if session.id != sessions.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func setHooks(_ on: Bool) {
        do {
            try services.pulse.setHooks(on)
            hookError = nil
        } catch {
            hookError = "Couldn't change Claude Code's settings: \(error.localizedDescription)"
        }
    }
}

struct LiveSessionRow: View {
    @Environment(AppServices.self) private var services
    let session: LiveSession
    var compact = false

    var body: some View {
        let host = services.pulse.host(of: session)
        let conversation = services.conversation(forSession: session.sessionID)
        HStack(spacing: Theme.Space.m) {
            Group {
                if let icon = host?.icon {
                    Image(nsImage: icon).resizable()
                } else if session.isInDesktop, let claude = services.installs.first(where: \.isDesktop) {
                    InstallIcon(install: claude, size: compact ? 22 : 28)
                } else {
                    Image(systemName: "terminal").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? session.projectName)
                    .font(Theme.Font.bodyMedium)
                    .lineLimit(1)
                Text(detail(conversation: conversation))
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateWord)
                    .font(Theme.Font.callout.weight(session.state == .needsYou ? .semibold : .regular))
                    .foregroundStyle(session.state == .needsYou ? Theme.accent : .secondary)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(elapsed)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !compact {
                MoreMenu {
                    if let host {
                        Button("Show in \(host.localizedName ?? "its app")") { services.pulse.show(session) }
                    }
                    if let conversation {
                        Button("Read the Conversation") { services.show(conversation) }
                    }
                    Button("Show Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
                    }
                    .disabled(session.cwd.isEmpty)
                }
            }
        }
        .padding(.vertical, compact ? 6 : 10)
        .contentShape(.rect)
        .onTapGesture { services.pulse.show(session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Brings its app to the front")
    }

    private var stateWord: String {
        switch session.state {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .idle: return "Done"
        }
    }

    private var elapsed: String {
        let seconds = max(0, Date().timeIntervalSince(session.since))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "for \(minutes) min" }
        let hours = minutes / 60
        return hours < 24 ? "for \(hours) h" : "since \(session.since.listStamp)"
    }

    private func detail(conversation: ConversationRef?) -> String {
        if session.state == .needsYou, let asked = services.pulse.notes[session.sessionID]?.message {
            return asked
        }
        if let title = conversation?.title, !title.isEmpty { return title }
        return session.cwd.isEmpty ? "" : HostPaths.current.abbreviating(session.cwd)
    }
}
