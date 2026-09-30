import CoworkKit
import Foundation

// Better Claude's MCP server: lets a Claude search and read the person's past conversations
// from every Claude on this Mac, as far as that account is allowed to see.
//
// It speaks MCP over stdio (one JSON-RPC message per line) and only ever reads Better
// Claude's index; the app keeps that index current. Nothing here writes anywhere.
//
//   bc-recall --account <account id>

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let access = RecallAccess.load()
let account = access.consumer(registered: value(after: "--account"),
                              environment: ProcessInfo.processInfo.environment)

let serverInstructions = """
This server holds the person's past conversations with Claude on this Mac: Claude Desktop \
chats, Cowork tasks, Claude Code sessions and the Code tab, including ones Claude has since \
deleted. Use it when the person refers to earlier work ("like we did last time", "what did we \
decide about…"), before redoing research or a decision that may already exist, and to find \
which conversation changed a file. Search first, then read the relevant part of a \
conversation. Quote what was actually said rather than paraphrasing from memory, and give \
the conversation's title and date when you rely on it.
"""

let tools: [JSONValue] = [
    tool("search_history",
         "Search the person's past Claude conversations by words that appear in them. Every word must appear somewhere in a conversation; words match as prefixes. Returns the best conversations with matching excerpts and message numbers.",
         properties: [
            ("query", ["type": "string", "description": "Words to look for, e.g. \"retry cap webhook\"."]),
            ("project", ["type": "string", "description": "Only conversations whose project folder contains this text."]),
            ("since_days", ["type": "integer", "description": "Only conversations active in this many recent days."]),
            ("limit", ["type": "integer", "description": "How many conversations, 1 to 20. Default 8."]),
         ], required: ["query"]),
    tool("read_conversation",
         "Read a past conversation's messages in order, from a message number. Long conversations come in pages; the reply says where to continue.",
         properties: [
            ("id", ["type": "string", "description": "The id from search_history or recent_work."]),
            ("start", ["type": "integer", "description": "Message number to start from. Start a few before a search match for context."]),
            ("limit", ["type": "integer", "description": "How many messages, up to 120. Default 40."]),
         ], required: ["id"]),
    tool("recent_work",
         "List the conversations active recently, with what was first asked and Claude's latest recap. Useful to pick up where the person left off.",
         properties: [
            ("project", ["type": "string", "description": "Only conversations whose project folder contains this text."]),
            ("days", ["type": "integer", "description": "How many days back. Default 7."]),
            ("limit", ["type": "integer", "description": "How many conversations, up to 30. Default 12."]),
         ], required: []),
    tool("file_history",
         "Find the past conversations that read or changed a file, with which tools and when. Pass a full path, or just a file name to match it in any folder.",
         properties: [
            ("path", ["type": "string", "description": "An absolute path, or a file name like Package.swift."]),
         ], required: ["path"]),
    tool("decisions",
         "List what was decided in past conversations, newest first, each with the conversation it came from. Check it before re-deciding something, like a library, a limit, or an approach.",
         properties: [
            ("project", ["type": "string", "description": "Only this project folder, as a full path."]),
            ("topic", ["type": "string", "description": "Only decisions mentioning these words, like \"retry cap\"."]),
         ], required: []),
    tool("conversation_changes",
         "List every file a past conversation edited or created, with how many lines differ from the version saved before it started. Use it to see what an earlier session did to the code.",
         properties: [
            ("id", ["type": "string", "description": "The conversation's id, from search_history or recent_work."]),
         ], required: ["id"]),
]

func tool(_ name: String, _ description: String, properties: [(String, [String: String])],
          required: [String]) -> JSONValue {
    var props = JSONObject()
    for (key, spec) in properties {
        props[key] = .object(JSONObject(spec.sorted { $0.key < $1.key }.map { ($0.key, JSONValue.string($0.value)) }))
    }
    return .object(JSONObject([
        ("name", .string(name)),
        ("description", .string(description)),
        ("inputSchema", .object(JSONObject([
            ("type", .string("object")),
            ("properties", .object(props)),
            ("required", .array(required.map(JSONValue.string))),
        ]))),
        ("annotations", .object(JSONObject([("readOnlyHint", .bool(true)), ("openWorldHint", .bool(false))]))),
    ]))
}

func send(_ message: JSONValue) {
    var data = message.serialized()
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: JSONValue, result: JSONValue) {
    send(.object(JSONObject([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])))
}

func fail(_ id: JSONValue, code: Int64, _ message: String) {
    send(.object(JSONObject([("jsonrpc", .string("2.0")), ("id", id),
                             ("error", .object(JSONObject([("code", .int(code)), ("message", .string(message))])))])))
}

func text(_ body: String, isError: Bool = false) -> JSONValue {
    .object(JSONObject([
        // Keys and tokens that were pasted into a conversation stay out of what Claude reads back.
        ("content", .array([.object(JSONObject([("type", .string("text")), ("text", .string(SecretSweep.redact(body)))]))])),
        ("isError", .bool(isError)),
    ]))
}

func call(_ name: String, _ input: JSONValue) async -> JSONValue {
    guard let account else {
        return text("Better Claude's history server was started without an account, so it can't tell which history this Claude may read. Turn it off and on again in Better Claude.", isError: true)
    }
    let index: HistoryIndex
    do {
        index = try HistoryIndex(readingFrom: HistoryIndex.defaultURL())
    } catch {
        return text(String(describing: error), isError: true)
    }
    // Read afresh each call, so a door opened in Better Claude applies straight away.
    let recall = Recall(index: index, accounts: RecallAccess.load().allowed(for: account))
    let int = { (key: String) in input[key]?.intValue.map(Int.init) }
    do {
        switch name {
        case "search_history":
            guard let query = input["query"]?.stringValue, !query.isEmpty else {
                return text("search_history needs a query.", isError: true)
            }
            return text(try await recall.search(query: query, project: input["project"]?.stringValue,
                                                sinceDays: int("since_days"), limit: int("limit") ?? 8))
        case "read_conversation":
            guard let id = input["id"]?.stringValue else { return text("read_conversation needs an id.", isError: true) }
            return text(try await recall.read(id: id, from: int("start"), limit: int("limit") ?? 40))
        case "recent_work":
            return text(try await recall.recent(project: input["project"]?.stringValue,
                                                days: int("days") ?? 7, limit: int("limit") ?? 12))
        case "file_history":
            guard let path = input["path"]?.stringValue else { return text("file_history needs a path.", isError: true) }
            return text(try await recall.fileHistory(path: path))
        case "decisions":
            return text(try await recall.decisions(project: input["project"]?.stringValue, topic: input["topic"]?.stringValue))
        case "conversation_changes":
            guard let id = input["id"]?.stringValue else { return text("conversation_changes needs an id.", isError: true) }
            return text(try await recall.changes(id: id))
        default:
            return text("There's no tool called \(name).", isError: true)
        }
    } catch {
        return text("Couldn't read the history: \(error)", isError: true)
    }
}

let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

func handle(_ message: JSONValue) async {
    guard let method = message["method"]?.stringValue else { return }
    // Notifications carry no id and get no answer.
    guard let id = message["id"] else { return }
    let params = message["params"] ?? .object(JSONObject())
    switch method {
    case "initialize":
        let asked = params["protocolVersion"]?.stringValue ?? ""
        reply(id, result: .object(JSONObject([
            ("protocolVersion", .string(supportedVersions.contains(asked) ? asked : supportedVersions[1])),
            ("capabilities", .object(JSONObject([("tools", .object(JSONObject()))]))),
            ("serverInfo", .object(JSONObject([("name", .string("better-claude")),
                                               ("title", .string("Better Claude")),
                                               ("version", .string(AppVersion.current))]))),
            ("instructions", .string(serverInstructions)),
        ])))
    case "ping":
        reply(id, result: .object(JSONObject()))
    case "tools/list":
        reply(id, result: .object(JSONObject([("tools", .array(tools))])))
    case "tools/call":
        guard let name = params["name"]?.stringValue else { return fail(id, code: -32602, "Missing tool name") }
        reply(id, result: await call(name, params["arguments"] ?? .object(JSONObject())))
    default:
        fail(id, code: -32601, "Method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    guard let message = try? JSONValue.parse(line) else {
        send(.object(JSONObject([("jsonrpc", .string("2.0")), ("id", .null),
                                 ("error", .object(JSONObject([("code", .int(-32700)), ("message", .string("Parse error"))])))])))
        continue
    }
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        await handle(message)
        semaphore.signal()
    }
    semaphore.wait()
}
