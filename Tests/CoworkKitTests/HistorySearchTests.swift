import Foundation
import Testing

@testable import CoworkKit

@Suite("History search")
struct HistorySearchTests {

    static let account = "acct-search"

    /// An index in memory holding conversations made up on the spot.
    static func index(_ conversations: [(id: String, title: String, messages: [String])],
                      account: String = account, project: String? = nil, session: String? = nil) async throws -> HistoryIndex {
        let index = try HistoryIndex(url: nil)
        try await add(conversations, to: index, account: account, project: project, session: session)
        return index
    }

    static func add(_ conversations: [(id: String, title: String, messages: [String])], to index: HistoryIndex,
                    account: String = account, project: String? = nil, session: String? = nil) async throws {
        for conversation in conversations {
            _ = try await index.rows("""
                INSERT INTO conversations (id, session_id, install_id, account_id, kind, title, project_path,
                                           last_activity, present, message_count)
                VALUES (?, ?, 'install', ?, 'claudeCode', ?, ?, ?, 1, ?)
                """, [.text(conversation.id), .text(session ?? conversation.id), .text(account), .text(conversation.title),
                      .optional(project), .date(Date()), .int(Int64(conversation.messages.count))])
            for (ordinal, text) in conversation.messages.enumerated() {
                _ = try await index.rows("""
                    INSERT INTO messages (conversation_id, ordinal, role, kind, text) VALUES (?, ?, 'user', 'message', ?)
                    """, [.text(conversation.id), .int(Int64(ordinal)), .text(text)])
            }
        }
    }

    static func filler(_ count: Int) -> String {
        (0..<count).map { "filler\($0)" }.joined(separator: " ")
    }

    @Test("Every word counts wherever it is in a conversation, not only near another match")
    func coverageAcrossTheWholeConversation() async throws {
        let index = try await Self.index([
            ("far", "Notes", ["alpha " + Self.filler(120) + " omega"]),
            ("split", "Notes", ["alpha " + Self.filler(60), Self.filler(60) + " omega"]),
            ("half", "Notes", ["alpha " + Self.filler(10)]),
        ])
        let hits = try await index.search("alpha omega")
        #expect(Set(hits.map(\.conversationID)) == ["far", "split"])
        #expect(hits.allSatisfy { $0.coverage == 1 })
        var loose = HistorySearch.Options()
        loose.requireAllWords = false
        let partial = try await index.search("alpha omega", options: loose)
        #expect(partial.first { $0.conversationID == "half" }?.coverage == 0.5)
    }

    @Test("Accents don't matter, either way round")
    func accents() async throws {
        let index = try await Self.index([("cafe", "Notes", ["Meet at the café on the corner, crème brûlée after"])])
        #expect(try await index.search("cafe creme").map(\.conversationID) == ["cafe"])
        #expect(try await index.search("CAFÉ brulee").map(\.conversationID) == ["cafe"])
        #expect(HistorySearch.terms(in: "Café_Crème") == ["cafe", "creme"])
    }

    @Test("Words joined by underscores are found together, as the index splits them")
    func underscores() async throws {
        let index = try await Self.index([
            ("together", "Notes", ["call remove_older_indexes before opening"]),
            ("apart", "Notes", ["remove the folder, older ones first, then rebuild indexes"]),
        ])
        #expect(try await index.search("remove_older_indexes").map(\.conversationID) == ["together"])
        #expect(try await index.search("older_index").map(\.conversationID) == ["together"])
        #expect(Set(try await index.search("remove indexes").map(\.conversationID)) == ["together", "apart"])
    }

    @Test("Conversations out of scope never crowd in-scope ones out of the results")
    func scopeBeforeLimit() async throws {
        let index = try await Self.index([("busy", "Elsewhere", (0..<5_200).map { "deploy log line \($0)" })],
                                         account: "other")
        try await Self.add([("mine", "Mine", ["the deploy finally went out"])], to: index)
        var options = HistorySearch.Options(accountIDs: [Self.account])
        options.limit = 5
        #expect(try await index.search("deploy", options: options).map(\.conversationID) == ["mine"])
        let busy = try await index.search("deploy", options: .init(accountIDs: ["other"]))
        #expect(busy.first?.matchingMessages == 5_200)
        #expect(busy.first?.excerpts.count == 3)
    }

    @Test("A project filter matches its text literally, underscores and percent signs included")
    func projectFilterIsLiteral() async throws {
        let index = try await Self.index([("literal", "Notes", ["release checklist"])], project: "/work/app_one")
        try await Self.add([("lookalike", "Notes", ["release checklist"])], to: index, project: "/work/appXone")
        try await Self.add([("percent", "Notes", ["release checklist"])], to: index, project: "/work/100%done")
        var options = HistorySearch.Options()
        options.projectContaining = "app_one"
        #expect(try await index.search("release", options: options).map(\.conversationID) == ["literal"])
        options.projectContaining = "0%d"
        #expect(try await index.search("release", options: options).map(\.conversationID) == ["percent"])

        let recall = Recall(index: index, accounts: [Self.account])
        let recent = try await recall.recent(project: "app_one", days: 7, limit: 10)
        #expect(recent.contains("/work/app_one"))
        #expect(!recent.contains("/work/appXone"))
        let found = try await recall.search(query: "release", project: "app_one", sinceDays: nil, limit: 1)
        #expect(found.contains("1 past conversation match"))
    }

    @Test("What Claude reads back never holds a key, even one an excerpt or a page would cut in half")
    func recallHidesKeysBeforeCutting() async throws {
        let key = "sk-" + "ant-" + "api03-" + String(repeating: "Fq8wT3test", count: 9) + "AA"
        let body = String(key.dropFirst(14).prefix(16))
        let pasted = Self.filler(40) + " the key is " + key + " " + Self.filler(3) + " webhook retries " + Self.filler(40)
        let long = String(repeating: "x", count: 3_950) + " " + key + " webhook"
        let index = try await Self.index([("leaky", "Webhook setup", [pasted, long])])
        let recall = Recall(index: index, accounts: [Self.account])

        let found = try await recall.search(query: "webhook", project: nil, sinceDays: nil, limit: 5)
        #expect(found.contains("webhook"))
        #expect(!found.contains(body))
        #expect(!found.contains("sk-ant-api03"))
        let read = try await recall.read(id: "leaky", from: nil, limit: 10)
        #expect(!read.contains(body))
        #expect(!read.contains("sk-ant-api03"))
        #expect(read.contains("[anthropic api key hidden]"))
    }

    @Test("A session copied into two installs is named so that reading it opens the copy search found")
    func copiesGetTheirOwnIDs() async throws {
        let index = try await Self.index([("cc:/one/s.jsonl", "First copy", ["the lighthouse plan, first take"])], session: "s-shared")
        try await Self.add([("cc:/two/s.jsonl", "Second copy", Array(repeating: "unrelated", count: 5))], to: index, session: "s-shared")
        try await Self.add([("cc:/three/t.jsonl", "Alone", ["the lighthouse again"])], to: index, session: "s-alone")
        let recall = Recall(index: index, accounts: [Self.account])
        let found = try await recall.search(query: "lighthouse", project: nil, sinceDays: nil, limit: 5)
        #expect(found.contains("id: cc:/one/s.jsonl"))
        #expect(found.contains("id: s-alone"))
        #expect(try await recall.read(id: "cc:/one/s.jsonl", from: nil, limit: 5).contains("First copy"))
    }

    @Test("Excerpts cut from a whole message mark the words that matched")
    func excerptsFromText() {
        let text = Self.filler(30) + "\nthe Café_crème order " + Self.filler(30)
        let (excerpt, ranges) = HistorySearch.excerpt(of: text, phrases: [["cafe", "creme"], ["ord"]])
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…"))
        #expect(!excerpt.contains("\n"))
        #expect(ranges.map { String(excerpt[$0]) } == ["Café_crème", "order"])
    }
}
