import Foundation

/// Optional Claude Code hooks that tell Better Claude why a session needs you, the moment it
/// does.
///
/// Without them the app still sees every session go busy, waiting and idle from Claude Code's
/// own session files; the hooks add what Claude said ("Claude needs your permission to use
/// Bash") and when a turn failed. Each hook only writes the event Claude Code hands it into
/// Better Claude's folder, so it works while the app is closed and needs no network port.
///
/// Installing edits `settings.json` in one Claude Code config folder. The file is backed up
/// first, every entry added carries ``marker``, and removing takes out exactly the entries
/// that carry it, leaving everything else as it was.
public enum PulseHooks {

    public static let marker = "#better-claude-pulse"
    public static let events = ["Notification", "Stop", "StopFailure"]

    public static func eventsDir(paths: HostPaths = .current) -> URL {
        paths.betterClaudeSupport.appendingPathComponent("Pulse/Events", isDirectory: true)
    }

    static func settingsURL(in configDir: URL) -> URL {
        configDir.appendingPathComponent("settings.json")
    }

    /// The shell command each hook runs: write the event to a file of its own, then rename it
    /// into place so a half-written event is never read.
    static func command(paths: HostPaths) -> String {
        let dir = eventsDir(paths: paths).path.replacingOccurrences(of: "'", with: "'\\''")
        return "d='\(dir)'; f=\"$d/$(date +%s)-$$\"; mkdir -p \"$d\" && cat > \"$f.part\" && mv \"$f.part\" \"$f.json\" \(marker)"
    }

    public static func isInstalled(in configDir: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL(in: configDir)) else { return false }
        return String(decoding: data, as: UTF8.self).contains(marker)
    }

    public static func install(in configDir: URL, paths: HostPaths = .current) throws {
        var settings = try readSettings(in: configDir)
        try backUp(configDir: configDir, paths: paths)
        settings = removing(from: settings)
        var hooks = settings["hooks"]?.objectValue ?? JSONObject()
        let entry = JSONValue.object(JSONObject([
            ("hooks", .array([.object(JSONObject([
                ("type", .string("command")),
                ("command", .string(command(paths: paths))),
                ("timeout", .int(5)),
            ]))])),
        ]))
        for event in events {
            var groups = hooks[event]?.arrayValue ?? []
            groups.append(entry)
            hooks[event] = .array(groups)
        }
        settings["hooks"] = .object(hooks)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try AtomicWrite.write(settings.serializedPretty(), to: settingsURL(in: configDir))
    }

    public static func uninstall(in configDir: URL, paths: HostPaths = .current) throws {
        guard isInstalled(in: configDir) else { return }
        let settings = try readSettings(in: configDir)
        try backUp(configDir: configDir, paths: paths)
        try AtomicWrite.write(removing(from: settings).serializedPretty(), to: settingsURL(in: configDir))
    }

    /// `settings` without any hook that carries the marker, and without groups or events that
    /// leaves empty.
    static func removing(from settings: JSONValue) -> JSONValue {
        guard var hooks = settings["hooks"]?.objectValue else { return settings }
        for (event, value) in hooks.orderedPairs {
            guard let groups = value.arrayValue else { continue }
            var kept: [JSONValue] = []
            for group in groups {
                guard var object = group.objectValue, let inner = object["hooks"]?.arrayValue else {
                    kept.append(group)
                    continue
                }
                let remaining = inner.filter { !($0["command"]?.stringValue?.contains(marker) ?? false) }
                if remaining.count == inner.count {
                    kept.append(group)
                } else if !remaining.isEmpty {
                    object["hooks"] = .array(remaining)
                    kept.append(.object(object))
                }
            }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        var result = settings
        result["hooks"] = hooks.count == 0 ? nil : .object(hooks)
        return result
    }

    static func readSettings(in configDir: URL) throws -> JSONValue {
        let url = settingsURL(in: configDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return .object(JSONObject()) }
        let value = try JSONValue.parse(try Data(contentsOf: url))
        guard case .object = value else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return value
    }

    static func backUp(configDir: URL, paths: HostPaths) throws {
        let source = settingsURL(in: configDir)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let dir = paths.betterClaudeSupport.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "settings-\(configDir.lastPathComponent)-\(stamp).json"
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
    }

    // MARK: Events

    public struct Event: Sendable, Equatable {
        public let name: String
        public let sessionID: String
        public let cwd: String?
        /// What Claude said, for a notification.
        public let message: String?
        /// `permission_prompt`, `idle_prompt`, … for a notification.
        public let notificationType: String?
        public let date: Date
    }

    /// Takes every waiting event, oldest first, and deletes their files. Events older than
    /// `maxAge` are dropped unread: they describe a moment that has passed.
    public static func drain(paths: HostPaths = .current, maxAge: TimeInterval = 600) -> [Event] {
        let dir = eventsDir(paths: paths)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var events: [Event] = []
        for url in files where url.pathExtension == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            guard Date().timeIntervalSince(date) < maxAge,
                  let data = try? Data(contentsOf: url), let event = parse(data, date: date) else { continue }
            events.append(event)
        }
        // Leftovers from a hook that was killed mid-write.
        for url in files where url.pathExtension == "part" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(date) > 60 { try? FileManager.default.removeItem(at: url) }
        }
        return events.sorted { $0.date < $1.date }
    }

    static func parse(_ data: Data, date: Date) -> Event? {
        guard let record = try? JSONValue.parse(data),
              let name = record["hook_event_name"]?.stringValue,
              let session = record["session_id"]?.stringValue else { return nil }
        return Event(name: name, sessionID: session, cwd: record["cwd"]?.stringValue,
                     message: record["message"]?.stringValue ?? record["error"]?.stringValue,
                     notificationType: record["notification_type"]?.stringValue, date: date)
    }
}
