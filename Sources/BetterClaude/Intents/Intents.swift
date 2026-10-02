import AppIntents
import CoworkKit
import Foundation

/// Search every conversation from Shortcuts, Spotlight or Siri, without opening the app.
struct SearchHistoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Claude History"
    static let description = IntentDescription("Finds past conversations from every Claude on this Mac that mention these words.")

    @Parameter(title: "Words")
    var words: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Claude history for \(\.$words)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let index = try HistoryIndex(readingFrom: HistoryIndex.defaultURL())
        var options = HistorySearch.Options()
        options.limit = 8
        let hits = try await index.search(words, options: options)
        let titles = hits.map(\.title)
        let dialog: IntentDialog = titles.isEmpty ? "Nothing in your history mentions that."
            : "\(titles.count) conversations: \(titles.prefix(3).joined(separator: ", "))."
        return .result(value: titles, dialog: dialog)
    }
}

/// Every account's limits, read aloud or passed along.
struct ShowLimitsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Claude Limits"
    static let description = IntentDescription("How much of each account's five-hour and weekly limits is used, as Claude last reported it.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot = await Catalog().snapshot()
        let lines = QuotaReader.accounts(in: snapshot).map { quota -> String in
            let five = quota.window(.fiveHour).flatMap { $0.isStale ? nil : "\(Int($0.percent.rounded()))% of five hours" }
            let weeks = quota.weeklyWindows.map { window in
                "\(Int(window.percent.rounded()))% of the week" + (window.kind == .weekly ? "" : " for \(window.scope ?? "one model")")
            }
            let parts = [five].compactMap { $0 } + weeks
            return "\(quota.account.displayName): " + (parts.isEmpty ? "nothing read lately" : parts.joined(separator: ", "))
        }
        let text = lines.isEmpty ? "No limits have been recorded on this Mac yet." : lines.joined(separator: ". ") + "."
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct BetterClaudeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SearchHistoryIntent(), phrases: ["Search \(.applicationName) history"],
                    shortTitle: "Search History", systemImageName: "magnifyingglass")
        AppShortcut(intent: ShowLimitsIntent(), phrases: ["Show my \(.applicationName) limits"],
                    shortTitle: "Show Limits", systemImageName: "gauge.with.dots.needle.50percent")
    }
}
