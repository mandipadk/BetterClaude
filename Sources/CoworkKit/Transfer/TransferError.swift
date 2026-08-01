import Foundation

public enum TransferError: Error, CustomStringConvertible {
    case preconditionsFailed([String])
    case sourceTranscriptMissing(sessionId: String)
    case bundleUnreadable(String)
    case bundleTooNew(found: Int, supported: Int)
    case secretsFound(ScanReport)
    case chainBroken(orphans: Int)
    case pickerFilterViolation([PickerViolation])
    case noDonorSession(account: String)
    case destinationExists(URL)
    case notSameVolume(URL, URL)
    case insufficientSpace(needed: Int64, available: Int64)
    case variantRunning([RunningVariant])
    case postConditionFailed(String)

    public var description: String {
        switch self {
        case .preconditionsFailed(let messages):
            return "preconditions failed:\n" + messages.map { "  · \($0)" }.joined(separator: "\n")
        case .sourceTranscriptMissing(let id):
            return "session \(id) has no locatable transcript, so there is no chat to transfer"
        case .bundleUnreadable(let why):
            return "bundle is unreadable: \(why)"
        case .bundleTooNew(let found, let supported):
            return "bundle format version \(found) was produced by a newer version of this tool (this build supports \(supported))"
        case .secretsFound(let report):
            let names = report.findings.filter { $0.tier == "block" }
                .map { "\($0.path) [\($0.ruleId)]" }
            return "export blocked — credential-shaped content found in:\n"
                + names.map { "  · \($0)" }.joined(separator: "\n")
                + "\n(the matched values are deliberately not shown)"
        case .chainBroken(let orphans):
            return "transcript has \(orphans) records whose parent is missing; importing it would render a truncated conversation"
        case .pickerFilterViolation(let violations):
            let list = violations.map { "  · record \($0.recordIndex): \($0.token) in \($0.window) window" }
            return "transcript contains tokens that make Claude Code silently hide the session from the resume picker:\n"
                + list.joined(separator: "\n")
        case .noDonorSession(let account):
            return "account \(account) has no existing session to copy environment settings from — open Claude once in that account first"
        case .destinationExists(let url):
            return "refusing to overwrite existing \(url.lastPathComponent)"
        case .notSameVolume(let a, let b):
            return "staging (\(a.path)) and destination (\(b.path)) are on different volumes, so the final move could not be atomic"
        case .insufficientSpace(let needed, let available):
            return "needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) but only "
                + "\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is free"
        case .variantRunning(let variants):
            let names = variants.map { $0.userDataDir.lastPathComponent }.joined(separator: ", ")
            return "Claude is running against the destination store (\(names)). Quit it first — a running app can "
                + "overwrite an imported session from its in-memory copy."
        case .postConditionFailed(let what):
            return "post-condition failed after writing: \(what)"
        }
    }
}

/// One checked precondition, surfaced to the user as a checklist before anything is written.
public struct PreconditionResult: Sendable {
    public let id: String
    public let title: String
    public let passed: Bool
    public let detail: String?

    public init(id: String, title: String, passed: Bool, detail: String? = nil) {
        self.id = id
        self.title = title
        self.passed = passed
        self.detail = detail
    }
}
