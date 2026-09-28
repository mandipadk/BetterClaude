import Foundation
import Testing

@testable import CoworkKit

@Suite("Pulse")
struct PulseTests {

    private func withHome(_ body: (HostPaths) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = HostPaths.fixture(at: root)
        try FileManager.default.createDirectory(at: paths.claudeCodeConfigDir, withIntermediateDirectories: true)
        try HostPaths.$current.withValue(paths) { try body(paths) }
    }

    private func writeSession(_ fields: [String: Any], pid: Int, in paths: HostPaths) throws {
        let dir = LiveSessions.sessionsDir(in: paths.claudeCodeConfigDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var record: [String: Any] = ["pid": pid, "sessionId": "s-\(pid)", "cwd": "/work/billing",
                                     "kind": "interactive", "entrypoint": "cli",
                                     "startedAt": 1_790_000_000_000, "statusUpdatedAt": 1_790_000_100_000]
        record.merge(fields) { $1 }
        try JSONSerialization.data(withJSONObject: record).write(to: dir.appendingPathComponent("\(pid).json"))
        // The secret beside it must never be read.
        try Data("secret".utf8).write(to: dir.appendingPathComponent("\(pid).abc.key"))
    }

    @Test("Session files read as working, needs you, or idle, and dead ones are skipped")
    func readsSessions() throws {
        try withHome { paths in
            try writeSession(["status": "busy"], pid: 101, in: paths)
            try writeSession(["status": "waiting"], pid: 102, in: paths)
            try writeSession(["status": "idle", "entrypoint": "claude-desktop"], pid: 103, in: paths)
            try writeSession(["status": "busy"], pid: 104, in: paths)
            try writeSession(["status": "busy", "kind": "daemon"], pid: 105, in: paths)

            let sessions = LiveSessions.running(paths: paths) { pid, _ in pid != 104 }
            let states = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0.state) })
            #expect(states == [101: .working, 102: .needsYou, 103: .idle])
            #expect(sessions.first { $0.pid == 103 }?.isInDesktop == true)
            #expect(sessions.first?.projectName == "billing")
        }
    }

    @Test("A recycled pid isn't mistaken for the session that wrote the file")
    func checksStartTime() throws {
        let me = getpid()
        let started = try #require(LiveSessions.processInfo(me)?.startTime)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        #expect(LiveSessions.isAlive(me, procStart: formatter.string(from: started)))
        #expect(!LiveSessions.isAlive(me, procStart: formatter.string(from: started.addingTimeInterval(-3600))))
        #expect(LiveSessions.isAlive(me, procStart: nil))
        #expect(LiveSessions.ancestry(of: me).first == me)
    }

    @Test("Hooks install beside the person's own, and removing them leaves the rest untouched")
    func hooksRoundTrip() throws {
        try withHome { paths in
            let config = paths.claudeCodeConfigDir
            let settings = config.appendingPathComponent("settings.json")
            let original = """
            {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
            """
            try Data(original.utf8).write(to: settings)

            try PulseHooks.install(in: config, paths: paths)
            #expect(PulseHooks.isInstalled(in: config))
            let installed = try JSONValue.parse(Data(contentsOf: settings))
            #expect(installed["model"]?.stringValue == "opus")
            #expect(installed["hooks"]?["Stop"]?.arrayValue?.count == 2)
            #expect(installed["hooks"]?["Notification"]?.arrayValue?.count == 1)

            // Installing twice doesn't double up.
            try PulseHooks.install(in: config, paths: paths)
            #expect(try JSONValue.parse(Data(contentsOf: settings))["hooks"]?["Stop"]?.arrayValue?.count == 2)

            try PulseHooks.uninstall(in: config, paths: paths)
            #expect(!PulseHooks.isInstalled(in: config))
            let removed = try JSONValue.parse(Data(contentsOf: settings))
            #expect(removed == (try JSONValue.parse(Data(original.utf8))))
            let backups = try FileManager.default.contentsOfDirectory(
                atPath: paths.betterClaudeSupport.appendingPathComponent("Backups").path)
            #expect(!backups.isEmpty)
        }
    }

    @Test("The hook command hands its event to the app, which reads it once")
    func hookCommandDelivers() throws {
        try withHome { paths in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", PulseHooks.command(paths: paths)]
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data("""
            {"hook_event_name":"Notification","session_id":"abc","cwd":"/work/billing",
             "message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}
            """.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)

            let events = PulseHooks.drain(paths: paths)
            #expect(events.count == 1)
            #expect(events.first?.notificationType == "permission_prompt")
            #expect(events.first?.message == "Claude needs your permission to use Bash")
            #expect(PulseHooks.drain(paths: paths).isEmpty)
        }
    }
}
