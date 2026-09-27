import CoreServices
import Foundation

/// Tells its owner when anything changes under a set of folders, at most once per `latency`.
///
/// One FSEvents stream for every folder rather than a file descriptor per directory: it
/// recurses on its own, costs nothing while nothing changes, and coalesces a burst of writes
/// (Claude appending to a transcript line by line) into a single call.
public final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "BetterClaude.DirectoryWatcher")
    private let onChange: @Sendable () -> Void

    /// Starts watching `roots` that exist. `onChange` runs on a background queue.
    public init?(roots: [URL], latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        let paths = roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return nil }

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf))
        else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    /// Where conversations are written, for every install on the Mac.
    public static func conversationRoots(for installs: [Install], paths: HostPaths = .current) -> [URL] {
        var roots: [URL] = [paths.claudeCodeConfigDir.appendingPathComponent("projects", isDirectory: true)]
        for install in installs where install.isDesktop {
            roots.append(install.dataRoot.appendingPathComponent(StoreLayout.sessionsDirName, isDirectory: true))
            if let codeTab = install.codeTabRoot { roots.append(codeTab) }
        }
        return roots
    }
}
