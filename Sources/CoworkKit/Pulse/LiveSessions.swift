import Darwin
import Foundation

/// One Claude Code session that is running right now, in a terminal or in a Desktop app's
/// Code tab.
public struct LiveSession: Sendable, Hashable, Identifiable {
    public enum State: String, Sendable, Hashable {
        /// Claude is thinking or running tools.
        case working
        /// Claude asked something — a permission, a question — and is waiting on the person.
        case needsYou
        /// Claude finished and is waiting for the next message.
        case idle
    }

    public var id: String { "\(pid):\(sessionID)" }
    public let pid: Int32
    public let sessionID: String
    public let cwd: String
    public let state: State
    /// When `state` last changed, as Claude Code recorded it.
    public let since: Date
    public let startedAt: Date?
    /// `cli` for a terminal, `claude-desktop` for a Desktop app's Code tab.
    public let entrypoint: String?
    /// The name the session was given, if any.
    public let name: String?
    /// The Claude Code config folder the session belongs to.
    public let configDir: URL

    public var isInDesktop: Bool { entrypoint == "claude-desktop" }

    public var projectName: String {
        cwd.isEmpty ? "Claude Code" : URL(fileURLWithPath: cwd).lastPathComponent
    }

    public init(pid: Int32, sessionID: String, cwd: String, state: State, since: Date, startedAt: Date?,
                entrypoint: String?, name: String?, configDir: URL) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.state = state
        self.since = since
        self.startedAt = startedAt
        self.entrypoint = entrypoint
        self.name = name
        self.configDir = configDir
    }
}

/// Reads the live-session files Claude Code keeps in `<config>/sessions/<pid>.json`.
///
/// Each running session rewrites its file as it goes between busy, waiting and idle, which is
/// the same signal Claude Code's own agent view reads. Only the `.json` files are read: the
/// `.key` files beside them hold a secret for talking to the session and are never opened.
public enum LiveSessions {

    /// Every Claude Code config folder on the Mac: the usual one, and any a Parallex copy was
    /// given of its own.
    public static func configDirs(paths: HostPaths = .current) -> [URL] {
        var dirs = [paths.claudeCodeConfigDir]
        let instances = paths.applicationSupport.appendingPathComponent("Parallex/instances", isDirectory: true)
        for instance in (try? FileManager.default.contentsOfDirectory(
            at: instances, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let own = instance.appendingPathComponent("claude-code", isDirectory: true)
            if Discovery.isDirectory(own) { dirs.append(own) }
        }
        return dirs
    }

    public static func sessionsDir(in configDir: URL) -> URL {
        configDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// The sessions running now, most recently changed first.
    public static func running(paths: HostPaths = .current,
                               isAlive: (Int32, String?) -> Bool = LiveSessions.isAlive(_:procStart:)) -> [LiveSession] {
        var found: [LiveSession] = []
        for config in configDirs(paths: paths) {
            let dir = sessionsDir(in: config)
            for url in (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let session = parse(data, configDir: config),
                      isAlive(session.pid, procStart(in: data)) else { continue }
                found.append(session)
            }
        }
        return found.sorted { $0.since > $1.since }
    }

    static func parse(_ data: Data, configDir: URL) -> LiveSession? {
        guard let record = try? JSONValue.parse(data),
              let pid = record["pid"]?.intValue, pid > 0,
              let sessionID = record["sessionId"]?.stringValue else { return nil }
        let kind = record["kind"]?.stringValue ?? "interactive"
        guard kind == "interactive" else { return nil }
        let millis = { (key: String) -> Date? in
            record[key]?.intValue.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        }
        return LiveSession(
            pid: Int32(pid), sessionID: sessionID, cwd: record["cwd"]?.stringValue ?? "",
            state: state(for: record["status"]?.stringValue),
            since: millis("statusUpdatedAt") ?? millis("updatedAt") ?? millis("startedAt") ?? .distantPast,
            startedAt: millis("startedAt"), entrypoint: record["entrypoint"]?.stringValue,
            name: record["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }, configDir: configDir)
    }

    /// Claude Code's own vocabulary, as its agent view reads it: busy is working, waiting is
    /// blocked on the person, anything else is at rest.
    static func state(for status: String?) -> LiveSession.State {
        switch status {
        case "busy", "working", "running", "starting", "resuming": return .working
        case "waiting", "blocked": return .needsYou
        default: return .idle
        }
    }

    static func procStart(in data: Data) -> String? {
        (try? JSONValue.parse(data))?["procStart"]?.stringValue
    }

    // MARK: Processes

    /// Whether `pid` is still the process that wrote the file: it exists, and when Claude
    /// Code recorded its start time, it started then — so a recycled pid doesn't count.
    public static func isAlive(_ pid: Int32, procStart: String?) -> Bool {
        guard let info = processInfo(pid) else { return false }
        guard let procStart, let recorded = parseProcStart(procStart) else { return true }
        return abs(info.startTime.timeIntervalSince(recorded)) < 2
    }

    /// `ps -o lstart` output, which Claude Code records in UTC.
    static func parseProcStart(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.replacingOccurrences(of: "  ", with: " "))
    }

    public struct ProcessDetails: Sendable {
        public let pid: Int32
        public let parent: Int32
        public let startTime: Date
    }

    public static func processInfo(_ pid: Int32) -> ProcessDetails? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        return ProcessDetails(pid: pid, parent: info.kp_eproc.e_ppid,
                              startTime: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6))
    }

    /// `pid` and its parents, nearest first, up to launchd.
    public static func ancestry(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while current > 1, chain.count < 32, let info = processInfo(current) {
            chain.append(current)
            current = info.parent
        }
        return chain
    }
}
