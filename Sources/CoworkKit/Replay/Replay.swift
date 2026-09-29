import Foundation
import Security

/// Your own Anthropic API key, kept in the Keychain. Off until you add one; used only when
/// you run something that says what it will cost first.
public enum APIKeyStore {
    static let service = "Better Claude API key"
    static let account = "anthropic"

    public static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    public static var isSet: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func save(_ key: String) throws {
        remove()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecValueData as String: Data(key.utf8)]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func remove() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The Messages API, over plain HTTP: there's no official Swift SDK.
public struct AnthropicClient: Sendable {
    public let key: String
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public init(key: String) { self.key = key }

    public struct Reply: Sendable, Equatable {
        public let text: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let stopReason: String?
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(Int, String)
        case unreadable
        public var description: String {
            switch self {
            case .http(401, _): return "The API key wasn't accepted. Check it in Settings."
            case .http(429, _): return "The API is limiting requests right now. Try again in a minute."
            case .http(let code, let message): return "The API answered \(code): \(message)"
            case .unreadable: return "The API's answer couldn't be read."
            }
        }
    }

    public static func request(model: String, messages: [(role: String, text: String)], maxTokens: Int) -> JSONValue {
        .object(JSONObject([
            ("model", .string(model)),
            ("max_tokens", .int(Int64(maxTokens))),
            ("messages", .array(messages.map { .object(JSONObject([("role", .string($0.role)), ("content", .string($0.text))])) })),
        ]))
    }

    public func send(model: String, messages: [(role: String, text: String)], maxTokens: Int = 16_000) async throws -> Reply {
        var request = URLRequest(url: endpoint, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = Self.request(model: model, messages: messages, maxTokens: maxTokens).serialized()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSONValue.parse(data)
        guard status == 200 else {
            throw Failure.http(status, body?["error"]?["message"]?.stringValue ?? "no details")
        }
        guard let body else { throw Failure.unreadable }
        return Self.reply(from: body)
    }

    /// The reply's text blocks, skipping thinking, with its token counts.
    public static func reply(from body: JSONValue) -> Reply {
        let text = (body["content"]?.arrayValue ?? []).compactMap { block -> String? in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined(separator: "\n\n")
        let stop = body["stop_reason"]?.stringValue
        return Reply(text: stop == "refusal" && text.isEmpty ? "The model declined to answer this one." : text,
                     inputTokens: Int(body["usage"]?["input_tokens"]?.intValue ?? 0),
                     outputTokens: Int(body["usage"]?["output_tokens"]?.intValue ?? 0), stopReason: stop)
    }
}

/// Running a past conversation's prompts on another model, to compare its answers with the
/// ones you got.
///
/// Each turn is asked with the conversation as it really was up to that point — the original
/// replies, not the new model's — so every answer is what the new model would have said in
/// the same spot.
public enum Replay {

    public struct Turn: Sendable, Identifiable, Equatable {
        public var id: Int { number }
        public let number: Int
        public let prompt: String
        public let original: String?
        /// Everything before the prompt, alternating and starting with the person.
        public let history: [Message]
    }

    public struct Message: Sendable, Equatable {
        public let role: String
        public let text: String
    }

    public struct Model: Sendable, Identifiable, Hashable {
        public var id: String { identifier }
        public let identifier: String
        public let name: String
    }

    public static let models = [
        Model(identifier: "claude-fable-5-1", name: "Claude Fable 5.1"),
        Model(identifier: "claude-opus-5-5", name: "Claude Opus 5.5"),
        Model(identifier: "claude-opus-5", name: "Claude Opus 5"),
        Model(identifier: "claude-sonnet-5", name: "Claude Sonnet 5"),
        Model(identifier: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
    ]

    /// The conversation's turns: each thing asked, with what came before and what Claude said.
    public static func turns(from messages: [IndexedMessage]) -> [Turn] {
        // Only what was said; consecutive messages from one side read as one.
        var merged: [Message] = []
        for message in messages where message.kind == .message && (message.role == .user || message.role == .assistant) {
            let role = message.role == .user ? "user" : "assistant"
            if let last = merged.last, last.role == role {
                merged[merged.count - 1] = Message(role: role, text: last.text + "\n\n" + message.text)
            } else {
                merged.append(Message(role: role, text: message.text))
            }
        }
        while merged.first?.role == "assistant" { merged.removeFirst() }
        var turns: [Turn] = []
        for (index, message) in merged.enumerated() where message.role == "user" {
            let original = index + 1 < merged.count ? merged[index + 1].text : nil
            turns.append(Turn(number: turns.count + 1, prompt: message.text, original: original,
                              history: Array(merged[..<index])))
        }
        return turns
    }

    /// Roughly what replaying `turns` costs on `model`, before running it: every turn resends
    /// the conversation so far. About four characters to a token; replies guessed at the
    /// length of the originals.
    public static func estimate(_ turns: [Turn], model: String) -> (inputTokens: Int, outputTokens: Int, dollars: Double) {
        var input = 0, output = 0
        for turn in turns {
            input += (turn.history.reduce(0) { $0 + $1.text.count } + turn.prompt.count) / 4 + 20
            output += max(200, (turn.original?.count ?? 800) / 4)
        }
        let dollars = Pricing.cost(model: model, input: Int64(input), output: Int64(output), cacheRead: 0,
                                   cacheWrite5m: 0, cacheWrite1h: 0)
        return (input, output, dollars)
    }

    public static func messages(for turn: Turn) -> [(role: String, text: String)] {
        turn.history.map { ($0.role, $0.text) } + [("user", turn.prompt)]
    }
}
