import Foundation
import Testing

@testable import CoworkKit

/// An empty account cannot be a *source*. That says nothing about it as a *destination*.
///
/// The app used to require `sessionCount > 0` everywhere — sidebar, transfer picker, and the
/// PC9b precondition — on the reasoning that an account with no sessions had never been signed
/// into. A freshly signed-in install has no sessions and is exactly where you would want to
/// send a conversation, so the install you were signed into was the one place you could not
/// transfer to, and it was invisible in the sidebar as well.
@Suite("Destination eligibility")
struct DestinationEligibilityTests {

    private func account(sessions: Int, signedIn: Bool) -> AccountRef {
        let root = URL(fileURLWithPath: "/tmp/store/acct/org")
        return AccountRef(
            store: StoreRef(variantDirName: "Claude-Secondary",
                            userDataDir: URL(fileURLWithPath: "/tmp/store"),
                            sessionsRoot: URL(fileURLWithPath: "/tmp/store/local-agent-mode-sessions"),
                            launcher: nil),
            accountId: "acct", orgId: "org", dirScheme: .fullUUID, root: root,
            sessionCount: sessions, emailAddress: nil, accountName: nil, isSignedIn: signedIn)
    }

    @Test("A signed-in account with no conversations can still receive one")
    func emptySignedInIsAValidDestination() {
        #expect(account(sessions: 0, signedIn: true).canReceiveTransfer)
    }

    @Test("An account that is neither signed into nor populated cannot")
    func emptyAndSignedOutIsNot() {
        #expect(!account(sessions: 0, signedIn: false).canReceiveTransfer)
    }

    @Test("A populated account stays eligible even when another account is signed in")
    func populatedStaysEligible() {
        // A store records one signed-in account, so a second account holding conversations
        // would start failing a check it has always passed if this were `isSignedIn` alone.
        #expect(account(sessions: 9, signedIn: false).canReceiveTransfer)
    }

    @Test("The signed-in account is read from config.json, not inferred from session count")
    func readsSignedInAccountFromConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = StoreRef(variantDirName: "Claude-Secondary", userDataDir: dir,
                             sessionsRoot: dir.appendingPathComponent("local-agent-mode-sessions"),
                             launcher: nil)

        // No config file at all.
        #expect(Discovery.signedInAccountId(in: store) == nil)

        let config = dir.appendingPathComponent("config.json")
        // The real file carries `oauth:tokenCache` beside it. Present here to pin that the
        // reader takes one key and never touches the credential next to it.
        try Data("""
        {"lastKnownAccountUuid":"277378b3-dda1-43ac-8558-350d74a59e6f",
         "oauth:tokenCache":"SECRET-MUST-NOT-BE-READ","locale":"en-US"}
        """.utf8).write(to: config)
        let found = Discovery.signedInAccountId(in: store)
        #expect(found == "277378b3-dda1-43ac-8558-350d74a59e6f")
        #expect(found?.contains("SECRET") != true)

        // An empty value is not an account.
        try Data(#"{"lastKnownAccountUuid":""}"#.utf8).write(to: config)
        #expect(Discovery.signedInAccountId(in: store) == nil)

        // Malformed JSON must not throw or crash the whole discovery walk.
        try Data("{not json".utf8).write(to: config)
        #expect(Discovery.signedInAccountId(in: store) == nil)
    }
}
