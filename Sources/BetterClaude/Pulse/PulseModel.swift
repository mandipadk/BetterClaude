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
        guard !reading else { return }
        reading = true
        let paths = paths
        Task {
            let (fresh, events) = await Task.detached(priority: .utility) { Self.look(paths) }.value
            reading = false
            apply(fresh, events: events)
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
        let session = response.notification.request.content.userInfo["session"] as? String
        await MainActor.run {
            if let session { onOpen?(session) }
        }
    }
}
