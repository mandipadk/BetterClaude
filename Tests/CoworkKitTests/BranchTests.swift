import Foundation
import Testing

@testable import CoworkKit

@Suite("ConversationBranch")
struct BranchTests {

    // MARK: - Fixtures

    static let sourceSession = "11111111-1111-1111-1111-111111111111"

    /// A transcript on disk, because a branch has to record where it came from and
    /// ``ConversationBranch/plan(transcript:cutAt:newTitle:)`` refuses to invent an origin.
    static func loaded(_ records: [JSONValue]) throws -> Transcript {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sourceSession).jsonl")
        try Transcript(records: records).write(to: url)
        return try Transcript(contentsOf: url)
    }

    static func turn(_ role: String, _ uuid: String, parent: String?, text: String) -> JSONValue {
        let message = JSONObject([
            ("role", .string(role)),
            ("content", .array([.object(JSONObject([
                ("type", .string("text")), ("text", .string(text)),
            ]))])),
        ])
        return .object(JSONObject([
            ("type", .string(role)),
            ("uuid", .string(uuid)),
            ("parentUuid", parent.map { JSONValue.string($0) } ?? .null),
            ("sessionId", .string(sourceSession)),
            ("cwd", .string("/tmp/project")),
            ("timestamp", .string("2026-07-01T10:00:00.000Z")),
            ("message", .object(message)),
        ]))
    }

    /// An assistant turn that says something *and* calls a tool — the common shape, and the
    /// one that makes a naive cut unresumable.
    static func toolCall(_ uuid: String, parent: String, text: String, toolId: String) -> JSONValue {
        let message = JSONObject([
            ("role", .string("assistant")),
            ("content", .array([
                .object(JSONObject([("type", .string("text")), ("text", .string(text))])),
                .object(JSONObject([
                    ("type", .string("tool_use")), ("id", .string(toolId)),
                    ("name", .string("Read")),
                ])),
            ])),
        ])
        return .object(JSONObject([
            ("type", .string("assistant")),
            ("uuid", .string(uuid)),
            ("parentUuid", .string(parent)),
            ("sessionId", .string(sourceSession)),
            ("message", .object(message)),
        ]))
    }

    static func toolResult(_ uuid: String, parent: String, toolId: String) -> JSONValue {
        let message = JSONObject([
            ("role", .string("user")),
            ("content", .array([.object(JSONObject([
                ("type", .string("tool_result")),
                ("tool_use_id", .string(toolId)),
                ("content", .string("file contents")),
            ]))])),
        ])
        return .object(JSONObject([
            ("type", .string("user")),
            ("uuid", .string(uuid)),
            ("parentUuid", .string(parent)),
            ("sessionId", .string(sourceSession)),
            ("message", .object(message)),
        ]))
    }

    static func bookkeeping(_ type: String, _ pairs: [(String, JSONValue)] = []) -> JSONValue {
        .object(JSONObject([("type", .string(type))] + pairs))
    }

    /// Chain order and line order deliberately disagree: `abandoned` is a second child of
    /// the root, sitting in the file *before* records that are on the kept path.
    static func interleaved() throws -> Transcript {
        try loaded([
            turn("user", "u1", parent: nil, text: "How do I parse this?"),
            turn("assistant", "a1", parent: "u1", text: "Use a recursive descent parser."),
            turn("user", "abandoned", parent: "u1", text: "Never mind, different approach."),
            turn("user", "u2", parent: "a1", text: "Show me the tokenizer."),
            turn("assistant", "a2", parent: "u2", text: "Here is the tokenizer."),
            bookkeeping("mode", [("mode", .string("default"))]),
            turn("user", "u3", parent: "a2", text: "Now the error handling."),
            turn("assistant", "a3", parent: "u3", text: "Errors bubble up."),
        ])
    }

    static func uuids(of transcript: Transcript) -> [String] {
        transcript.records.compactMap { $0["uuid"]?.stringValue }
    }

    // MARK: - Truncation

    @Test("Truncation follows the parentUuid chain, not the line order")
    func followsChainNotLineOrder() throws {
        let transcript = try Self.interleaved()
        let points = ConversationBranch.points(in: transcript)
        let cut = try #require(points.first { $0.id == "u2" })

        let branch = ConversationBranch.truncate(transcript, at: cut)

        #expect(Self.uuids(of: branch) == ["u1", "a1", "u2"])
        // The abandoned retry sits at record index 2, before the cut at index 3 — an
        // index-based truncation would have kept it.
        #expect(!Self.uuids(of: branch).contains("abandoned"))
    }

    @Test("A truncated transcript has one root and no orphans")
    func truncationLeavesChainIntact() throws {
        let transcript = try Self.interleaved()
        let points = ConversationBranch.points(in: transcript)

        for cut in points {
            let branch = ConversationBranch.truncate(transcript, at: cut)
            let integrity = branch.chainIntegrity()
            #expect(integrity.orphans.isEmpty, "cut at \(cut.id) orphaned \(integrity.orphans)")
            #expect(integrity.roots == 1, "cut at \(cut.id) produced \(integrity.roots) roots")
        }
    }

    @Test("Branching at the first user message keeps exactly one exchange")
    func firstMessageKeepsOneExchange() throws {
        let transcript = try Self.interleaved()
        let points = ConversationBranch.points(in: transcript)

        let firstUser = try #require(points.first { $0.role == .user })
        #expect(Self.uuids(of: ConversationBranch.truncate(transcript, at: firstUser)) == ["u1"])

        let firstReply = try #require(points.first { $0.role == .assistant })
        #expect(Self.uuids(of: ConversationBranch.truncate(transcript, at: firstReply)) == ["u1", "a1"])
    }

    @Test("Bookkeeping records after the cut are dropped, those before it survive")
    func bookkeepingFollowsTheCut() throws {
        let transcript = try Self.interleaved()
        let points = ConversationBranch.points(in: transcript)

        let early = try #require(points.first { $0.id == "u2" })
        let earlyTypes = ConversationBranch.truncate(transcript, at: early).recordTypeHistogram
        #expect(earlyTypes["mode"] == nil)

        let late = try #require(points.first { $0.id == "a3" })
        let lateTypes = ConversationBranch.truncate(transcript, at: late).recordTypeHistogram
        #expect(lateTypes["mode"] == 1)
    }

    @Test("A cut that leaves a tool call open pulls its result forward")
    func settlesOpenToolCalls() throws {
        let transcript = try Self.loaded([
            Self.turn("user", "u1", parent: nil, text: "Read the config."),
            Self.toolCall("a1", parent: "u1", text: "Reading it now.", toolId: "toolu_01"),
            Self.toolResult("r1", parent: "a1", toolId: "toolu_01"),
            Self.turn("assistant", "a2", parent: "r1", text: "The config sets three flags."),
            Self.turn("user", "u2", parent: "a2", text: "Change the second one."),
        ])
        let points = ConversationBranch.points(in: transcript)
        // `a1` is readable — it has prose — so it is offered as a cut point even though it
        // also carries a tool call.
        let cut = try #require(points.first { $0.id == "a1" })

        let branch = ConversationBranch.truncate(transcript, at: cut)

        #expect(Self.uuids(of: branch) == ["u1", "a1", "r1"])
        #expect(ConversationBranch.openToolUseIds(
            in: branch.records, kept: Set(Self.uuids(of: branch))).isEmpty)
    }

    /// Observed on a real transcript: a `tool_use` record with two children, where the
    /// conversation carried on through the one that is *not* the result. The call is left
    /// open in the source too, so a branch must inherit that shape rather than drag the
    /// abandoned subtree in behind it.
    @Test("A tool call the source itself abandoned does not pull records past the cut")
    func doesNotChaseAnAbandonedToolCall() throws {
        let transcript = try Self.loaded([
            Self.turn("user", "u1", parent: nil, text: "Read the config."),
            Self.toolCall("a1", parent: "u1", text: "Reading it now.", toolId: "toolu_01"),
            // First child in file order, and the path the conversation took.
            Self.turn("user", "u2", parent: "a1", text: "Actually, stop — do it by hand."),
            Self.toolResult("r1", parent: "a1", toolId: "toolu_01"),
            Self.turn("assistant", "a2", parent: "u2", text: "By hand, then."),
            Self.turn("user", "u3", parent: "a2", text: "Thanks."),
        ])
        let cut = try #require(ConversationBranch.points(in: transcript).first { $0.id == "a2" })

        let branch = ConversationBranch.truncate(transcript, at: cut)

        #expect(Self.uuids(of: branch) == ["u1", "a1", "u2", "a2"])
        #expect(!Self.uuids(of: branch).contains("r1"))
        // Still open — exactly as it is on the source's own path.
        #expect(ConversationBranch.openToolUseIds(
            in: branch.records, kept: Set(Self.uuids(of: branch))) == ["toolu_01"])
    }

    // MARK: - Points

    @Test("points() offers readable turns only, never tool plumbing")
    func pointsSkipToolPlumbing() throws {
        var meta = JSONObject()
        meta["type"] = .string("user")
        meta["uuid"] = .string("meta1")
        meta["parentUuid"] = .string("u1")
        meta["isMeta"] = .bool(true)
        meta["message"] = .object(JSONObject([
            ("role", .string("user")),
            ("content", .string("<command-name>/clear</command-name>")),
        ]))

        let transcript = try Self.loaded([
            Self.turn("user", "u1", parent: nil, text: "Read the config."),
            .object(meta),
            Self.toolCall("a1", parent: "meta1", text: "Reading it now.", toolId: "toolu_01"),
            Self.toolResult("r1", parent: "a1", toolId: "toolu_01"),
            Self.bookkeeping("ai-title", [("aiTitle", .string("Config work"))]),
            Self.turn("assistant", "a2", parent: "r1", text: "Three flags."),
        ])

        let ids = ConversationBranch.points(in: transcript).map(\.id)

        #expect(ids == ["u1", "a1", "a2"])
        // The tool result and the harness-injected meta turn are records in the chain but
        // nothing a person wrote or read.
        #expect(!ids.contains("r1"))
        #expect(!ids.contains("meta1"))
    }

    @Test("A point carries a collapsed preview and its position")
    func pointShape() throws {
        let long = String(repeating: "word ", count: 100)
        let transcript = try Self.loaded([
            Self.turn("user", "u1", parent: nil, text: "  Line one\n\n  Line two  "),
            Self.turn("assistant", "a1", parent: "u1", text: long),
        ])
        let points = ConversationBranch.points(in: transcript)

        #expect(points[0].preview == "Line one Line two")
        #expect(points[0].messageIndex == 0)
        #expect(points[0].recordIndex == 0)
        #expect(points[1].preview.count == ConversationBranch.previewLimit)
        #expect(points[1].messageIndex == 1)
        #expect(points[1].timestamp != nil)
    }

    // MARK: - Plan

    @Test("The branch gets a new session id, stamped on every record that carries one")
    func restampsSessionId() throws {
        let transcript = try Self.interleaved()
        let cut = try #require(ConversationBranch.points(in: transcript).first { $0.id == "u2" })

        let (plan, branch) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: "Tokenizer, second attempt")

        #expect(plan.newSessionId != Self.sourceSession)
        let stamped = branch.records.compactMap { $0["sessionId"]?.stringValue }
        #expect(!stamped.isEmpty)
        #expect(stamped.allSatisfy { $0 == plan.newSessionId })
        #expect(branch.stats().sessionIdsSeen == [plan.newSessionId])
        #expect(plan.destinationURL.lastPathComponent == "\(plan.newSessionId).jsonl")
        #expect(plan.destinationURL.deletingLastPathComponent()
            == plan.source.deletingLastPathComponent())
    }

    @Test("The custom-title record is last, and the origin marker sits just before it")
    func titleRecordIsLast() throws {
        let transcript = try Self.interleaved()
        let cut = try #require(ConversationBranch.points(in: transcript).first { $0.id == "u2" })

        let (plan, branch) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: "Tokenizer, second attempt")

        let last = try #require(branch.records.last)
        #expect(last["type"]?.stringValue == "custom-title")
        #expect(last["customTitle"]?.stringValue == "Tokenizer, second attempt")
        #expect(branch.resolvedTitle().title == "Tokenizer, second attempt")
        #expect(branch.resolvedTitle().source == .customTitle)

        let origin = try #require(branch.records.dropLast().last)
        #expect(origin["type"]?.stringValue == ConversationBranch.originRecordType)
        #expect(origin["sourceSessionId"]?.stringValue == Self.sourceSession)
        #expect(origin["cutUuid"]?.stringValue == "u2")
        // The origin marker is outside the conversation tree, so it cannot orphan anything.
        #expect(origin["uuid"] == nil)
        #expect(plan.title == "Tokenizer, second attempt")
    }

    @Test("The source's own title is replaced, not competed with")
    func replacesSourceTitle() throws {
        let transcript = try Self.loaded([
            Self.bookkeeping("custom-title", [("customTitle", .string("Parser work"))]),
            Self.turn("user", "u1", parent: nil, text: "How do I parse this?"),
            Self.turn("assistant", "a1", parent: "u1", text: "Recursive descent."),
        ])
        let cut = try #require(ConversationBranch.points(in: transcript).first { $0.id == "a1" })

        let (_, branch) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: "Tokenizer instead")

        let titles = branch.records.compactMap { $0["customTitle"]?.stringValue }
        #expect(titles == ["Tokenizer instead", "Tokenizer instead"])
        #expect(branch.resolvedTitle().title == "Tokenizer instead")
    }

    /// The picker parses whole lines from a 64 KiB window at each end, and `tailStart` is
    /// clamped to the end of the head window — so a file just over 64 KiB has a tail of a
    /// few dozen bytes starting mid-record, and every trailing record fails to parse. A
    /// title written only at the end of the file disappears in that band.
    @Test("The title survives the file size where the tail window parses nothing")
    func titleSurvivesTheWindowGap() throws {
        var landedInTheGap = false

        for padding in stride(from: 64_800, through: 65_800, by: 89) {
            let transcript = try Self.loaded([
                Self.bookkeeping("ai-title", [("aiTitle", .string("The source title"))]),
                Self.turn("user", "u1", parent: nil, text: String(repeating: "x", count: padding)),
            ])
            let cut = try #require(ConversationBranch.points(in: transcript).first)
            let (_, branch) = try ConversationBranch.plan(
                transcript: transcript, cutAt: cut, newTitle: "Branch title")

            let size = branch.serializedData().count
            if size > Transcript.pickerWindowBytes,
               size < Transcript.pickerWindowBytes * 2 { landedInTheGap = true }

            #expect(branch.resolvedTitle().title == "Branch title",
                    "resolved from the wrong source at \(size) bytes")
            #expect(branch.resolvedTitle().source == .customTitle)
        }

        #expect(landedInTheGap, "the sweep never entered the band it exists to cover")
    }

    @Test("Without a title the branch inherits the source's, marked as a branch")
    func defaultTitle() throws {
        let transcript = try Self.loaded([
            Self.bookkeeping("custom-title", [("customTitle", .string("Parser work"))]),
            Self.turn("user", "u1", parent: nil, text: "How do I parse this?"),
            Self.turn("assistant", "a1", parent: "u1", text: "Recursive descent."),
        ])
        let cut = try #require(ConversationBranch.points(in: transcript).first)

        let (plan, _) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: nil)

        #expect(plan.title == "Parser work (branch)")
    }

    @Test("Sidecar records that reference state the branch will not have are dropped")
    func dropsSidecarTypes() throws {
        let sidecars = [
            "worktree-state", "fork-context-ref", "relocated",
            "file-history-snapshot", "file-history-delta", "frame-link", "pr-link",
        ]
        var records: [JSONValue] = [Self.turn("user", "u1", parent: nil, text: "Start here.")]
        // Off-chain by construction, as they are on disk: no uuid, so they survive the
        // ancestor walk and can only be removed by the sidecar rule.
        records += sidecars.map { Self.bookkeeping($0, [("originalCwd", .string("/gone"))]) }
        records.append(Self.turn("assistant", "a1", parent: "u1", text: "Here is an answer."))

        let transcript = try Self.loaded(records)
        let cut = try #require(ConversationBranch.points(in: transcript).first { $0.id == "a1" })

        #expect(ConversationBranch.truncate(transcript, at: cut).records.count == 9)

        let (_, branch) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: "Clean")

        for type in sidecars {
            #expect(branch.recordTypeHistogram[type] == nil, "\(type) survived")
        }
        #expect(Self.uuids(of: branch) == ["u1", "a1"])
    }

    @Test("The branch is intact and visible to the resume picker")
    func planProducesAResumableSession() throws {
        let transcript = try Self.interleaved()

        for cut in ConversationBranch.points(in: transcript) {
            let (plan, branch) = try ConversationBranch.plan(
                transcript: transcript, cutAt: cut, newTitle: "Branch")
            #expect(branch.chainIntegrity().orphans.isEmpty)
            #expect(branch.chainIntegrity().roots == 1)
            #expect(branch.pickerFilterViolations().isEmpty)
            #expect(plan.keptRecords + plan.droppedRecords == transcript.records.count)
            #expect(plan.keptRecords == branch.records.count - 3)
        }
    }

    @Test("An sdk-cli entrypoint is normalised rather than left to hide the branch")
    func normalisesEntrypoint() throws {
        var record = Self.turn("user", "u1", parent: nil, text: "Start here.").objectValue!
        record["entrypoint"] = .string("sdk-cli")
        let transcript = try Self.loaded([.object(record)])
        let cut = try #require(ConversationBranch.points(in: transcript).first)

        #expect(!transcript.pickerFilterViolations().isEmpty)

        let (_, branch) = try ConversationBranch.plan(
            transcript: transcript, cutAt: cut, newTitle: "Branch")

        #expect(branch.records.compactMap { $0["entrypoint"]?.stringValue } == ["cli"])
        #expect(branch.pickerFilterViolations().isEmpty)
    }

    @Test("A cut point the transcript does not contain is refused")
    func rejectsUnknownPoint() throws {
        let transcript = try Self.interleaved()
        let stranger = BranchPoint(id: "nope", messageIndex: 0, recordIndex: 0,
                                   role: .user, preview: "", timestamp: nil)

        #expect(throws: BranchError.self) {
            _ = try ConversationBranch.plan(transcript: transcript, cutAt: stranger, newTitle: nil)
        }
        // `truncate` is total, so it hands back what it was given rather than an empty file.
        #expect(ConversationBranch.truncate(transcript, at: stranger).records.count
            == transcript.records.count)
    }

    @Test("A transcript that was never on disk has no origin to record")
    func rejectsTranscriptWithoutSource() throws {
        let transcript = Transcript(records: [
            Self.turn("user", "u1", parent: nil, text: "Start here.")
        ])
        let cut = try #require(ConversationBranch.points(in: transcript).first)

        #expect(throws: BranchError.self) {
            _ = try ConversationBranch.plan(transcript: transcript, cutAt: cut, newTitle: nil)
        }
    }
}

@Suite("Branch point filtering")
struct BranchPointFilterTests {

    private func userRecord(_ text: String, uuid: String) -> JSONValue {
        .object(JSONObject([
            ("type", .string("user")), ("uuid", .string(uuid)),
            ("timestamp", .string("2026-03-11T20:56:15.545Z")),
            ("message", .object(JSONObject([("role", .string("user")),
                                            ("content", .string(text))]))),
        ]))
    }

    @Test("Slash-command scaffolding is not offered as a cut point")
    func skipsMachineText() {
        // These are written into the transcript in the user's voice by the harness, but
        // nobody said them, and offering them as places to fork is meaningless.
        let transcript = Transcript(records: [
            userRecord("<command-name>/login</command-name>", uuid: "a"),
            userRecord("<local-command-stdout>Login successful</local-command-stdout>", uuid: "b"),
            userRecord("<command-message>skill-creator is running</command-message>", uuid: "c"),
            userRecord("Actually rewrite the migration to be idempotent", uuid: "d"),
        ])
        let points = ConversationBranch.points(in: transcript)
        #expect(points.count == 1)
        #expect(points.first?.id == "d")
    }

    @Test("Prose that merely contains an angle bracket is kept")
    func keepsRealProse() {
        let transcript = Transcript(records: [
            userRecord("use <T> as the generic parameter", uuid: "a"),
            userRecord("compare a < b before the swap", uuid: "b"),
        ])
        #expect(ConversationBranch.points(in: transcript).count == 2)
    }
}
