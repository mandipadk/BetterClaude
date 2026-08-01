import AppKit
import Foundation

/// One running Claude Desktop process, attributed to the store it is actually using.
public struct RunningVariant: Sendable, Hashable, Identifiable {
    public let pid: pid_t
    /// Canonicalized bundle location. Every variant runs the *same* bundle, so this does not
    /// identify the store — it is only useful for relaunching.
    public let bundleURL: URL
    /// Canonicalized `--user-data-dir`, or the Electron default when the switch is absent.
    public let userDataDir: URL
    /// `false` when `userDataDir` was inferred from the absence of the switch rather than
    /// read out of the process's argv.
    public let userDataDirWasExplicit: Bool

    public var id: pid_t { pid }

    public init(pid: pid_t, bundleURL: URL, userDataDir: URL, userDataDirWasExplicit: Bool = true) {
        self.pid = pid
        self.bundleURL = bundleURL
        self.userDataDir = userDataDir
        self.userDataDirWasExplicit = userDataDirWasExplicit
    }
}

public enum GuardsError: Error, CustomStringConvertible {
    case couldNotTerminate(pid: pid_t)
    case relaunchFailed(bundlePath: String, status: Int32, output: String)

    public var description: String {
        switch self {
        case .couldNotTerminate(let pid):
            return "process \(pid) did not exit after SIGTERM and SIGKILL"
        case .relaunchFailed(let path, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "could not relaunch \(path) (open exited \(status))"
                + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}

/// Answers "is the app that owns this store running right now?" before we write into it.
///
/// The question is harder than it looks. Every Claude Desktop variant is the *same* bundle
/// with the *same* bundle identifier — `Claude Work.app` and friends are AppleScript applets
/// that run `open -n -a Claude.app --args --user-data-dir=…`. So the running process's
/// `bundleIdentifier` is `com.anthropic.claudefordesktop` and its `bundleURL` is
/// `/Applications/Claude.app` no matter which store it has open, and `pgrep -f Claude` sees
/// one indistinguishable binary. Attributing a process to a store by any of those is wrong,
/// and wrong in the dangerous direction: it reports "safe to write" for a store the app is
/// live in. The process's own argv is the only place the truth is recorded.
public enum Guards {

    /// `~/Library/Application Support/Claude` — where Electron puts its user data when no
    /// `--user-data-dir` is given.
    public static var defaultUserDataDirectory: URL {
        canonical(applicationSupportDirectory.appendingPathComponent("Claude", isDirectory: true))
    }

    /// Every live Claude Desktop main process, with the store each one actually has open.
    ///
    /// Chromium helper processes (renderer, GPU, utility) share the parent's bundle identity
    /// and inherit `--user-data-dir`, so counting them would report one variant several
    /// times. They are excluded by their `--type=` switch, which the browser process never
    /// carries.
    public static func runningVariants() throws -> [RunningVariant] {
        var found: [RunningVariant] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let identifier = app.bundleIdentifier?.lowercased(),
                  identifier.contains("anthropic.claude"),
                  let bundleURL = app.bundleURL
            else { continue }

            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let argv = processArguments(pid: pid) ?? []
            if argv.dropFirst().contains(where: { $0.hasPrefix("--type=") }) { continue }

            let explicit = userDataDirectory(inArguments: argv)
            found.append(RunningVariant(
                pid: pid,
                bundleURL: canonical(bundleURL),
                userDataDir: explicit ?? defaultUserDataDirectory,
                userDataDirWasExplicit: explicit != nil
            ))
        }
        return found.sorted { $0.pid < $1.pid }
    }

    /// Processes that have the endpoint's store open and would fight us for it.
    ///
    /// Comparison is on canonicalized paths: a store reached through `/tmp/...` and the same
    /// store reached through `/private/tmp/...` are one store, and string equality says they
    /// are two.
    public static func conflicts(with endpoint: Endpoint) throws -> [RunningVariant] {
        switch endpoint {
        case .claudeCode:
            // Claude Code reads its transcripts off disk on demand; there is no resident
            // process holding the store, so nothing can conflict.
            return []
        case .cowork(let account):
            let target = canonical(account.store.userDataDir).path
            return try runningVariants().filter { $0.userDataDir.path == target }
        }
    }

    /// Ask the app to quit, then insist.
    ///
    /// `terminate()` sends the Quit Apple event rather than a signal, which gives Electron a
    /// chance to flush its own writes to the store — the whole reason we quit it before
    /// importing. SIGKILL is the fallback only after `timeout` has passed.
    public static func quit(_ variant: RunningVariant, timeout: TimeInterval) throws {
        let app = NSRunningApplication(processIdentifier: variant.pid)
        if let app {
            if app.isTerminated { return }
            app.terminate()
        } else {
            guard isAlive(variant.pid) else { return }
            _ = Darwin.kill(variant.pid, SIGTERM)
        }

        if waitForExit(variant.pid, app: app, timeout: timeout) { return }

        _ = Darwin.kill(variant.pid, SIGKILL)
        if waitForExit(variant.pid, app: app, timeout: 5) { return }
        throw GuardsError.couldNotTerminate(pid: variant.pid)
    }

    /// Start the variant back up against the same store.
    ///
    /// `open -n` is required: without it, launch services sees the bundle is already running
    /// (or was), activates the existing instance, and silently drops `--args`.
    public static func relaunch(_ variant: RunningVariant) throws {
        var arguments = ["-n", "-a", variant.bundleURL.path]
        if variant.userDataDir.path != defaultUserDataDirectory.path {
            arguments += ["--args", "--user-data-dir=\(variant.userDataDir.path)"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GuardsError.relaunchFailed(
                bundlePath: variant.bundleURL.path,
                status: process.terminationStatus,
                output: String(decoding: errorData, as: UTF8.self)
            )
        }
    }

    /// Read a process's argument vector out of the kernel.
    ///
    /// `KERN_PROCARGS2` returns an opaque blob laid out as: a 4-byte `argc`, the executable
    /// path as a NUL-terminated string, a run of alignment NULs, then exactly `argc`
    /// NUL-terminated argument strings, then the environment. Nothing in that layout is
    /// length-checked by the kernel against what we asked for, so every step below is
    /// bounds-checked and any surprise yields `nil`.
    public static func processArguments(pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }

        var argumentMax: Int32 = 0
        var maxSize = MemoryLayout<Int32>.size
        var maxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&maxMIB, 2, &argumentMax, &maxSize, nil, 0) == 0, argumentMax > 0 else {
            return nil
        }

        var bytes = [UInt8](repeating: 0, count: Int(argumentMax))
        var byteCount = Int(argumentMax)
        var argsMIB: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            sysctl(&argsMIB, 3, buffer.baseAddress, &byteCount, nil, 0) == 0
        }
        guard ok, byteCount > MemoryLayout<Int32>.size, byteCount <= bytes.count else { return nil }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(rebasing: source[0..<4]))
            }
        }
        // A sane upper bound: a real argv is a handful of entries, and a corrupt argc would
        // otherwise drive the scan below far past anything meaningful.
        guard argc > 0, argc <= 8192 else { return nil }

        var index = MemoryLayout<Int32>.size
        while index < byteCount, bytes[index] != 0 { index += 1 }   // executable path
        guard index < byteCount else { return nil }
        while index < byteCount, bytes[index] == 0 { index += 1 }   // alignment padding
        guard index < byteCount else { return nil }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        var start = index
        while index < byteCount, arguments.count < Int(argc) {
            if bytes[index] == 0 {
                arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        // A final argument truncated by the buffer limit is still worth keeping.
        if arguments.count < Int(argc), start < byteCount {
            arguments.append(String(decoding: bytes[start..<byteCount], as: UTF8.self))
        }
        return arguments.isEmpty ? nil : arguments
    }

    /// Extract `--user-data-dir` from an argument vector.
    ///
    /// Chromium accepts both `--switch=value` and `--switch value`, and stores switches in a
    /// map, so a repeated switch resolves to the last occurrence. Returns `nil` when the
    /// switch is absent — which means the default store, not an unknown one.
    public static func userDataDirectory(inArguments arguments: [String]) -> URL? {
        let flag = "--user-data-dir"
        var value: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix(flag + "=") {
                value = String(argument.dropFirst(flag.count + 1))
            } else if argument == flag, index + 1 < arguments.count {
                value = arguments[index + 1]
                index += 1
            }
            index += 1
        }
        guard var path = value, !path.isEmpty else { return nil }
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        return canonical(URL(fileURLWithPath: path))
    }

    // MARK: - Internals

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    static func canonical(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        // EPERM means the process exists but belongs to someone else; only ESRCH is gone.
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitForExit(_ pid: pid_t, app: NSRunningApplication?, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app?.isTerminated == true { return true }
            if !isAlive(pid) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return app?.isTerminated == true || !isAlive(pid)
    }
}
