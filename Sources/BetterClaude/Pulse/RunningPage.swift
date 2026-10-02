import AppKit
import CoworkKit
import SwiftUI

/// Every Claude Code session running now, the ones waiting for you first.
struct RunningPage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openSettings) private var openSettings

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
                UnattendedSection()

                Button("Notification Settings…") { openSettings() }
                    .buttonStyle(.link)
                    .font(Theme.Font.callout)
                    .padding(.top, Theme.Space.xl)
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
                    .foregroundStyle(session.state == .needsYou ? Theme.attention : .secondary)
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(elapsed)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !compact {
                MoreMenu { actions(host: host, conversation: conversation) }
            }
        }
        .padding(.vertical, compact ? 6 : 10)
        .contentShape(.rect)
        .contextMenu { actions(host: host, conversation: conversation) }
        .onTapGesture { services.pulse.show(session) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Brings its app to the front")
    }

    @ViewBuilder
    private func actions(host: NSRunningApplication?, conversation: ConversationRef?) -> some View {
        if let host {
            Button("Show in \(host.localizedName ?? "Its App")") { services.pulse.show(session) }
        }
        if let conversation {
            Button("Open Conversation") { services.show(conversation) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
        }
        .disabled(session.cwd.isEmpty)
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

/// Background jobs and self-running loops: what each is doing, how it ended, and the ones that
/// stopped without saying.
private struct UnattendedSection: View {
    @Environment(AppServices.self) private var services
    @State private var jobs: [Unattended.Job] = []
    @State private var loops: [Unattended.Loop] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !jobs.isEmpty || !loops.isEmpty {
                DetailSection(title: "Unattended", subtitle: "Background jobs and conversations that keep themselves going, in the last week.") {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(jobs.prefix(10)) { job in jobRow(job) }
                        ForEach(loops.prefix(6)) { loop in
                            Button {
                                services.show(conversationID: loop.conversationID)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(loop.title).font(Theme.Font.body).foregroundStyle(Theme.accent).lineLimit(1)
                                        Text("Looped \(loop.wakeups) time\(loop.wakeups == 1 ? "" : "s")\(loop.last.map { ", last \($0.listStamp.lowercasedIfWordLocal)" } ?? "")")
                                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: "\(services.index.generation)#\(services.pulse.sessions.count)") {
            let paths = services.snapshot.paths
            jobs = Unattended.recent(await Task.detached { Unattended.jobs(configDirs: LiveSessions.configDirs(paths: paths)) }.value,
                                     within: 7 * 86_400)
            if let index = services.index.index {
                loops = (try? await Unattended.loops(index: index, since: Date().addingTimeInterval(-7 * 86_400))) ?? []
            }
        }
    }

    private func jobRow(_ job: Unattended.Job) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol(job.outcome))
                .foregroundStyle(job.outcome == .failed || job.outcome == .stalled ? AnyShapeStyle(Theme.attention) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).font(Theme.Font.body).lineLimit(1)
                Text(status(job)).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                if let text = job.result ?? job.lastUpdate {
                    Text(text.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.Font.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Space.m)
            if let session = job.sessionID, let conversation = services.conversation(forSession: session) {
                Button("Open") {
                    services.show(conversationID: conversation.id)
                }
                .buttonStyle(.secondary)
            }
        }
    }

    private func symbol(_ outcome: Unattended.Job.Outcome) -> String {
        switch outcome {
        case .running: return "play.circle"
        case .finished: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .stalled: return "pause.circle"
        }
    }

    private func status(_ job: Unattended.Job) -> String {
        let when = job.updated.map { $0.listStamp.lowercasedIfWordLocal } ?? "at some point"
        let project = job.cwd.map { " in \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? ""
        switch job.outcome {
        case .running: return "Working\(project), last heard from \(when)"
        case .finished: return job.result == nil ? "Finished\(project), \(when), without a final message" : "Finished\(project), \(when)"
        case .failed: return "Failed\(project), \(when)"
        case .stalled: return "Stopped\(project) without finishing, last heard from \(when)"
        }
    }
}
