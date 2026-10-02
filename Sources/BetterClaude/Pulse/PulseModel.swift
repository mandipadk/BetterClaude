import AppKit
import CoworkKit
import Observation
import UserNotifications

/// Every Claude Code session running on the Mac, and which of them are waiting for you.
///
/// Claude Code rewrites a small file per session as it goes between working, waiting and
/// idle; watching those files is enough to know when an agent is stuck on a question. The
/// optional hooks add what Claude actually asked.
@MainActor
@Observable
final class PulseModel {
    private(set) var sessions: [LiveSession] = []
    /// The latest thing each session said through a hook, by session id.
    private(set) var notes: [String: PulseHooks.Event] = [:]
    /// Config folders with the hooks installed.
    private(set) var hooked: Set<URL> = []
    private(set) var configDirs: [URL] = []

    var needingYou: [LiveSession] { sessions.filter { $0.state == .needsYou } }
    var working: [LiveSession] { sessions.filter { $0.state == .working } }

    private let paths: HostPaths
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var hasBaseline = false
    private var reading = false
    private var readAgain = false
    let notifier = PulseNotifier()

    init(paths: HostPaths) {
        self.paths = paths
    }

    func start() {
        guard watcher == nil else { return }
        configDirs = LiveSessions.configDirs(paths: paths)
        let events = PulseHooks.eventsDir(paths: paths)
        try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        for dir in configDirs {
            try? FileManager.default.createDirectory(at: LiveSessions.sessionsDir(in: dir), withIntermediateDirectories: true)
        }
        watcher = DirectoryWatcher(roots: configDirs.map(LiveSessions.sessionsDir(in:)) + [events], latency: 0.5) {
            [weak self] in Task { @MainActor in self?.read() }
        }
        // A session that quits without tidying its file only shows up on a later look.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        refreshHooked()
        read()
    }

    func read() {
        // A change during a read may have landed after it looked: look again once it's done.
        guard !reading else { readAgain = true; return }
        reading = true
        readAgain = false
        let paths = paths
        Task {
            let (fresh, events) = await Task.detached(priority: .utility) { Self.look(paths) }.value
            reading = false
            apply(fresh, events: events)
            if readAgain { read() }
        }
    }

    nonisolated private static func look(_ paths: HostPaths) -> ([LiveSession], [PulseHooks.Event]) {
        // The sample Mac's sessions have made-up pids; count them as running.
        let sessions = paths.isFixture
            ? LiveSessions.running(paths: paths, isAlive: { _, _ in true })
            : LiveSessions.running(paths: paths)
        return (sessions, PulseHooks.drain(paths: paths))
    }

    private func apply(_ fresh: [LiveSession], events: [PulseHooks.Event]) {
        let previous = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for event in events {
            if event.name == "Notification" {
                notes[event.sessionID] = event
            } else if event.name == "StopFailure", hasBaseline {
                let session = fresh.first { $0.sessionID == event.sessionID }
                notifier.post(.failed, session: session, sessionID: event.sessionID,
                              project: session?.projectName ?? projectName(event.cwd),
                              detail: event.message, host: session.flatMap(host(of:)))
            }
        }
        if hasBaseline {
            for session in fresh {
                let before = previous[session.id]
                guard before?.state != session.state else { continue }
                switch session.state {
                case .needsYou:
                    notifier.post(.needsYou, session: session, sessionID: session.sessionID,
                                  project: session.projectName, detail: notes[session.sessionID]?.message,
                                  host: host(of: session))
                case .idle where before?.state == .working:
                    // Short turns end before you've looked away; only longer ones are news.
                    if let before, session.since.timeIntervalSince(before.since) >= 60 {
                        notifier.post(.finished, session: session, sessionID: session.sessionID,
                                      project: session.projectName, detail: nil, host: host(of: session))
                    }
                default:
                    break
                }
                if session.state == .working { notes[session.sessionID] = nil }
            }
        }
        let live = Set(fresh.map(\.sessionID))
        notes = notes.filter { live.contains($0.key) }
        if fresh != sessions { sessions = fresh }
        hasBaseline = true
    }

    private func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    // MARK: Where a session lives

    /// The app a session is running in: the terminal for one started there, or the Claude
    /// app whose Code tab started it.
    func host(of session: LiveSession) -> NSRunningApplication? {
        for pid in LiveSessions.ancestry(of: session.pid).dropFirst() {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    func show(_ session: LiveSession) {
        host(of: session)?.activate()
    }

    func session(forConversation sessionID: String) -> LiveSession? {
        sessions.first { $0.sessionID == sessionID }
    }

    // MARK: Hooks

    func refreshHooked() {
        hooked = Set(configDirs.filter { PulseHooks.isInstalled(in: $0) })
    }

    var hooksInstalled: Bool { !configDirs.isEmpty && configDirs.allSatisfy { hooked.contains($0) } }

    func setHooks(_ on: Bool) throws {
        defer { refreshHooked() }
        for dir in configDirs {
            if on { try PulseHooks.install(in: dir, paths: paths) } else { try PulseHooks.uninstall(in: dir, paths: paths) }
        }
    }
}

/// Posts the moments worth an interruption: an agent needs you, finished a long turn, or
/// stopped with an error. Nothing is posted while the app the session runs in is in front.
@MainActor
final class PulseNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Kind: String {
        case needsYou, finished, failed
    }

    static let needsYouKey = "notifyNeedsYou"
    static let finishedKey = "notifyFinished"

    /// Brings a session's app forward when its notification is clicked, by session id.
    var onOpen: ((String) -> Void)?
    /// Shows Usage when a limit notification is clicked.
    var onOpenUsage: (() -> Void)?
    /// Opens a conversation in Better Claude, by its id.
    var onOpenConversation: ((String) -> Void)?
    static let limitsKey = "notifyLimits"
    static let contextKey = "notifyContext"
    static let cacheKey = "notifyCache"
    /// Their own switches since 0.28. Until someone sets them, they follow the switch that
    /// used to control them, so nobody's notifications change on update.
    static let driftKey = "notifyDrift"
    static let jobsKey = "notifyJobs"

    static func setting(_ key: String, fallback: String) -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) as? Bool ?? defaults.object(forKey: fallback) as? Bool ?? true
    }

    /// A background job finished, failed, or stopped without finishing.
    func post(job: Unattended.Job) {
        guard Self.available, Self.setting(Self.jobsKey, fallback: Self.finishedKey) else { return }
        let content = UNMutableNotificationContent()
        switch job.outcome {
        case .finished: content.title = "\(job.name) finished"
        case .failed: content.title = "\(job.name) failed"
        case .stalled: content.title = "\(job.name) stopped without finishing"
        case .running: return
        }
        content.body = job.result.map { String($0.prefix(180)) }
            ?? (job.outcome == .finished ? "It ended without a final message." : "It hasn't been heard from in half an hour.")
        if let session = job.sessionID { content.userInfo = ["session": session] }
        let request = UNNotificationRequest(identifier: "job.\(job.id).\(job.outcome.rawValue)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A session waiting on you whose cache is about to go cold.
    func post(cacheExpiring session: String, conversationID: String, minutes: Int, context: Int64, extra: Double, key: String) {
        guard Self.available, UserDefaults.standard.object(forKey: Self.cacheKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(session)'s cache expires in \(minutes == 1 ? "a minute" : "\(minutes) minutes")"
        content.body = "Replying after that writes its \(context / 1_000)K tokens into the cache again, about \(extra.formatted(.currency(code: "USD").precision(.fractionLength(2)))) more at list prices. Replying, compacting or handing off before then avoids it."
        content.userInfo = ["conversation": conversationID]
        content.threadIdentifier = conversationID
        let request = UNNotificationRequest(identifier: "cache.\(key)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A running session's replies switched model with nothing on record asking for it.
    func post(drift change: ModelDrift.Switch, project: String) {
        guard Self.available, Self.setting(Self.driftKey, fallback: Self.contextKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(project) switched to \(humanModelName(change.to)) on its own"
        content.body = "Its replies came from \(humanModelName(change.from)) until now, and nothing on record asked for the change."
        content.userInfo = ["conversation": change.conversationID]
        content.threadIdentifier = change.conversationID
        let request = UNNotificationRequest(identifier: "drift.\(change.id)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A running session has read most of its context window.
    func post(_ nudge: ContextCoach.Nudge) {
        guard Self.available, UserDefaults.standard.object(forKey: Self.contextKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(nudge.project) has read \(nudge.percent)% of its context"
        content.body = "Each reply now rereads about \(nudge.context / 1_000)K tokens. Compacting now, or a handoff to a fresh session, keeps it fast and cheaper."
        content.userInfo = ["conversation": nudge.conversationID]
        content.threadIdentifier = nudge.sessionID
        let request = UNNotificationRequest(identifier: "context.\(nudge.key)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
    private var authorized: Bool?

    static var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    override init() {
        super.init()
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ kind: Kind, session: LiveSession?, sessionID: String, project: String, detail: String?,
              host: NSRunningApplication?) {
        guard Self.available, isEnabled(kind), host?.isActive != true else { return }
        let content = UNMutableNotificationContent()
        switch kind {
        case .needsYou:
            content.title = "\(project) needs you"
            content.body = detail ?? "Claude is waiting for your answer."
            content.interruptionLevel = .timeSensitive
        case .finished:
            content.title = "\(project) is done"
            content.body = "Claude finished and is waiting for your next message."
        case .failed:
            content.title = "\(project) stopped"
            content.body = detail ?? "Claude stopped with an error."
        }
        if let host = host?.localizedName { content.subtitle = "In \(host)" }
        content.userInfo = ["session": sessionID]
        content.threadIdentifier = sessionID
        let request = UNNotificationRequest(identifier: "\(kind.rawValue).\(sessionID)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Close to a limit, before hitting it.
    func post(_ alert: LimitAlerts.Alert) {
        guard Self.available, UserDefaults.standard.object(forKey: Self.limitsKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        let window = alert.window == .fiveHour ? "five-hour limit"
            : alert.scope.map { "weekly \($0) limit" } ?? "weekly limit"
        content.title = "\(alert.account) has used \(Int(alert.percent.rounded()))% of its \(window)"
        var body: [String] = []
        if let reset = alert.resetsAt {
            let format = alert.window == .fiveHour ? Date.FormatStyle(date: .omitted, time: .shortened)
                                                   : Date.FormatStyle().weekday(.wide).hour().minute()
            body.append("It resets \(alert.window == .fiveHour ? "at" : "on") \(reset.formatted(format)).")
        }
        if let other = alert.alternative { body.append("\(other.name) has \(Int(other.left))% left.") }
        content.body = body.isEmpty ? "Better Claude's Usage page shows what used it." : body.joined(separator: " ")
        content.userInfo = ["usage": true]
        content.threadIdentifier = "limits"
        let request = UNNotificationRequest(identifier: "limit.\(alert.key)", content: content, trigger: nil)
        Task {
            guard await ensureAuthorized() else { return }
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func isEnabled(_ kind: Kind) -> Bool {
        let defaults = UserDefaults.standard
        switch kind {
        case .needsYou, .failed: return defaults.object(forKey: Self.needsYouKey) as? Bool ?? true
        case .finished: return defaults.object(forKey: Self.finishedKey) as? Bool ?? true
        }
    }

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let granted: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional: granted = true
        case .notDetermined: granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: granted = false
        }
        authorized = granted
        return granted
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let session = info["session"] as? String
        let usage = info["usage"] as? Bool ?? false
        let conversation = info["conversation"] as? String
        await MainActor.run {
            if let session { onOpen?(session) }
            if usage { onOpenUsage?() }
            if let conversation { onOpenConversation?(conversation) }
        }
    }
}
