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

    /// One account rendering under two names is what this prevents.
    ///
    /// `emailAddress` is read out of session metadata, so an org with no sessions has none —
    /// even when a sibling org of the same account names the person. Before this, Claude-Work
    /// showed "iris" for the org holding conversations and "Claude-Work" for the org holding
    /// none, side by side in the sidebar, reading as two unrelated accounts.
    @Test("An account's empty orgs inherit the identity of its populated ones")
    func identityPropagatesAcrossOrgs() {
        func org(_ id: String, sessions: Int, email: String?, account: String) -> AccountRef {
            AccountRef(store: StoreRef(variantDirName: "Claude-Work",
                                       userDataDir: URL(fileURLWithPath: "/tmp/w"),
                                       sessionsRoot: URL(fileURLWithPath: "/tmp/w/s"),
                                       launcher: nil),
                       accountId: account, orgId: id, dirScheme: .fullUUID,
                       root: URL(fileURLWithPath: "/tmp/w/s/\(account)/\(id)"),
                       sessionCount: sessions, emailAddress: email, accountName: nil,
                       isSignedIn: true)
        }
        let resolved = Discovery.propagatingIdentityAcrossOrgs([
            org("empty-a", sessions: 0, email: nil, account: "5f327c44"),
            org("populated", sessions: 3, email: "iris@example.com", account: "5f327c44"),
            org("empty-b", sessions: 0, email: nil, account: "5f327c44"),
            // A different account must not borrow it.
            org("other", sessions: 0, email: nil, account: "c29bdd82"),
        ])
        #expect(resolved.filter { $0.accountId == "5f327c44" }
            .allSatisfy { $0.emailAddress == "iris@example.com" })
        #expect(resolved.first { $0.accountId == "c29bdd82" }?.emailAddress == nil)
        // Session counts are untouched — only the identity is shared.
        #expect(resolved.first { $0.orgId == "empty-a" }?.sessionCount == 0)
        #expect(resolved.first { $0.orgId == "populated" }?.sessionCount == 3)
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
