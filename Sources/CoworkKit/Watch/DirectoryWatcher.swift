import CoreServices
import Foundation

/// Tells its owner when anything changes under a set of folders, at most once per `latency`.
///
/// One FSEvents stream for every folder rather than a file descriptor per directory: it
/// recurses on its own, costs nothing while nothing changes, and coalesces a burst of writes
/// (Claude appending to a transcript line by line) into a single call.
///
/// A folder that doesn't exist yet — Codex installed after the app started, a config folder
/// not written to yet — is waited for at the nearest folder above it that does, which only
/// reports its own entries changing, and joins the stream once it's there.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var waiting: [DispatchSourceFileSystemObject] = []
    private var watched: (roots: Set<String>, above: Set<String>) = ([], [])
    private var stopped = false
    private let queue = DispatchQueue(label: "BetterClaude.DirectoryWatcher")
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let roots: [URL]
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void

    /// Starts watching `roots`. `onChange` runs on a background queue.
    public init?(roots: [URL], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        guard !roots.isEmpty else { return nil }
        self.roots = roots
        self.latency = latency
        self.onChange = onChange
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
        onQueue { start() }
    }

    public func stop() {
        onQueue {
            stopped = true
            teardown()
        }
    }

    deinit { stop() }

    /// Looks again for folders that didn't exist; for owners that refresh on their own clock.
    public func refresh() {
        onQueue { recheck() }
    }

    /// The folders in the stream now.
    var watching: Set<String> {
        var roots: Set<String> = []
        onQueue { roots = watched.roots }
        return roots
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) { body() } else { queue.sync(execute: body) }
    }

    private func start() {
        let manager = FileManager.default
        let present = roots.map(\.path).filter { manager.fileExists(atPath: $0) }
        let above = Set(roots.filter { !manager.fileExists(atPath: $0.path) }.compactMap(Self.nearestExisting(above:)))
        watched = (Set(present), above)

        if !present.isEmpty {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
            if let stream = FSEventStreamCreate(
                nil, callback, &context, present as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)) {
                self.stream = stream
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
            }
        }

        for folder in above {
            let descriptor = open(folder, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .link, .rename, .delete], queue: queue)
            source.setEventHandler { [weak self] in self?.recheck() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            waiting.append(source)
        }
    }

    private func teardown() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        for source in waiting { source.cancel() }
        waiting = []
    }

    private func recheck() {
        guard !stopped else { return }
        let manager = FileManager.default
        let present = Set(roots.map(\.path).filter { manager.fileExists(atPath: $0) })
        let above = Set(roots.filter { !manager.fileExists(atPath: $0.path) }.compactMap(Self.nearestExisting(above:)))
        guard present != watched.roots || above != watched.above else { return }
        let before = watched.roots
        teardown()
        start()
        // A folder can arrive with files already in it. `start` looks again, so it may find one
        // made since `present` was taken.
        if !watched.roots.isSubset(of: before) { onChange() }
        // Folders made while the new watches were being set up send no event of their own.
        if !watched.above.isEmpty { queue.async { [weak self] in self?.recheck() } }
    }

    /// The closest folder above `url` that exists.
    static func nearestExisting(above url: URL) -> String? {
        var folder = url.deletingLastPathComponent()
        while folder.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return folder.path
            }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    /// Where conversations are written, for every install on the Mac.
    public static func conversationRoots(for installs: [Install], paths: HostPaths = .current) -> [URL] {
        var roots: [URL] = [paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)]
        for install in installs where install.isDesktop {
            roots.append(install.dataRoot.appendingPathComponent(StoreLayout.sessionsDirName, isDirectory: true))
            if let codeTab = install.codeTabRoot { roots.append(codeTab) }
        }
        roots.append(CodexSessions.home(paths: paths).appendingPathComponent("sessions", isDirectory: true))
        return roots
    }
}
