import CoworkKit
import Foundation

/// Whether Better Claude still understands what this Mac's Claude Code and Codex write,
/// checked from their latest conversations at most once an hour.
@MainActor
@Observable
final class FormatModel {
    private(set) var reports: [FormatSurvey.Report] = []
    private var checkedAt: Date?

    func check(_ conversations: [ConversationRef]) {
        if let checkedAt, Date().timeIntervalSince(checkedAt) < 3_600 { return }
        checkedAt = Date()
        Task {
            reports = await Task.detached(priority: .utility) {
                FormatSurvey.check(conversations, recent: 8, byteLimit: 96 << 20)
            }.value
        }
    }

    /// The report for an install's own files, when something it shows is affected.
    func breaking(for install: Install) -> FormatSurvey.Report? {
        let format: String
        switch install.kind {
        case .claudeCode: format = FormatContract.claudeCode.format
        case .external(.codex): format = FormatContract.codex.format
        default: return nil
        }
        return reports.first { $0.contract.format == format && !$0.breaking.isEmpty }
    }

    #if DEBUG
    func show(_ report: FormatSurvey.Report) {
        checkedAt = Date()
        reports = [report]
    }
    #endif
}

extension FormatSurvey.Report {
    /// What a person could lose, once each: "token usage and file versions".
    var affected: String {
        var seen: [String] = []
        for feature in breaking.compactMap(\.feature) where !seen.contains(feature) { seen.append(feature) }
        return ListFormatter.localizedString(byJoining: seen)
    }

    /// The shape and what it shows, to attach to a bug report: field names only.
    var shareable: String {
        let findings = breaking.map { "- \($0)" }.joined(separator: "\n")
        let fields = (try? shape.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(contract.name) \(shape.version) changed:\n\(findings)\n\n\(fields)"
    }
}
