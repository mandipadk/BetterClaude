import Foundation
import Testing

@testable import CoworkKit

/// One Claude account belongs to several organisations at once — a shared Team and its own
/// personal one — and the session store names them only by UUID. An install signed into one
/// account therefore offers two destinations that used to read `org 16a5cf52…` and
/// `org 27450961…`, which is not a choice anyone can make.
@Suite("Organisation directory")
struct OrgDirectoryTests {

    @Test("Plan strings become the badges Claude's own account menu shows")
    func planLabels() {
        func plan(_ raw: String?) -> String? {
            OrgIdentity(name: nil, planRaw: raw, email: nil).planLabel
        }
        #expect(plan("claude_team") == "Team")
        #expect(plan("claude_max") == "Max")
        #expect(plan("claude_pro") == "Pro")
        #expect(plan("claude_enterprise") == "Enterprise")
        #expect(plan(nil) == nil)
        #expect(plan("") == nil)
        // An unfamiliar plan is shown, not swallowed: the set of plans grows.
        #expect(plan("claude_super_duper") == "Super Duper")
        #expect(plan("something_else") == "Something Else")
    }

    @Test("A personal org is called Personal, not by its generated name")
    func personalOrgIsNamedPersonal() {
        let identity = OrgIdentity(name: "florence@example.com's Organization",
                                   planRaw: "claude_max", email: "florence@example.com")
        // Matched against the account the row is shown beside…
        #expect(identity.displayName(besideAccount: "florence@example.com") == "Personal")
        // …or against the address the record itself carries.
        #expect(identity.displayName(besideAccount: nil) == "Personal")
        // A different person's org keeps its real name rather than being mislabelled.
        #expect(identity.displayName(besideAccount: "iris@example.com") == "Personal")

        let team = OrgIdentity(name: "analyticsandsociety", planRaw: "claude_team", email: nil)
        #expect(team.displayName(besideAccount: "florence@example.com") == "analyticsandsociety")
    }

    @Test("An oauth record naming only an address does not claim the org")
    func emailOnlyRecordDoesNotClaimTheSlot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("org-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Most workspace records look like this: an org UUID with a null name and type. Storing
        // one would claim the slot and stop a later, fuller record from filling it — the org
        // would count as resolved while still rendering as a bare UUID.
        let thin = dir.appendingPathComponent("thin.json")
        try Data("""
        {"oauthAccount":{"accountUuid":"acct-1","emailAddress":"iris@example.com",
          "organizationUuid":"org-1","organizationName":null,"organizationType":null}}
        """.utf8).write(to: thin)

        var resolved = OrgDirectory.Resolved()
        OrgDirectory.absorb(fileAt: thin, into: &resolved)
        #expect(resolved.orgs["org-1"] == nil)
        // The address is still worth keeping: an install signed into but never used has no
        // session to read one from.
        #expect(resolved.accountEmails["acct-1"] == "iris@example.com")

        let full = dir.appendingPathComponent("full.json")
        try Data("""
        {"oauthAccount":{"accountUuid":"acct-1","emailAddress":"iris@example.com",
          "organizationUuid":"org-1","organizationName":"analyticsandsociety",
          "organizationType":"claude_team"}}
        """.utf8).write(to: full)
        OrgDirectory.absorb(fileAt: full, into: &resolved)
        #expect(resolved.orgs["org-1"]?.planLabel == "Team")
        #expect(resolved.orgs["org-1"]?.name == "analyticsandsociety")
    }

    @Test("An org that cannot be named still says what is known about it")
    func unnamedOrgFallsBackToWhatIsTrue() {
        func account(org: OrgIdentity?, holders: Int) -> AccountRef {
            AccountRef(store: StoreRef(variantDirName: "Claude-Work",
                                       userDataDir: URL(fileURLWithPath: "/tmp/w"),
                                       sessionsRoot: URL(fileURLWithPath: "/tmp/w/s"),
                                       launcher: nil),
                       accountId: "acct", orgId: "69354d9a-dced-459f-87ef-47186025ee9a",
                       dirScheme: .fullUUID, root: URL(fileURLWithPath: "/tmp/w/s/a/o"),
                       sessionCount: 9, emailAddress: "cassandra@example.com",
                       accountName: nil, isSignedIn: false, org: org, orgAccountCount: holders)
        }
        // Held by one account and unnameable: nothing to say but the id.
        #expect(account(org: nil, holders: 1).orgLabel == "org 69354d9a…")
        // Held by several: that is the fact that distinguishes it, and it is a fact rather
        // than a guess at the plan.
        #expect(account(org: nil, holders: 2).orgLabel == "org 69354d9a… · shared by 2 accounts")
        // Once it can be named, the name wins.
        let named = OrgIdentity(name: "analyticsandsociety", planRaw: "claude_team", email: nil)
        #expect(account(org: named, holders: 3).orgLabel == "analyticsandsociety · Team")
    }
}
