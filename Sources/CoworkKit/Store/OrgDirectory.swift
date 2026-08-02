import Foundation

extension Sequence {
    /// `compactMap { $0 }` for a sequence of optionals, without the closure.
    func compacted<Wrapped>() -> [Wrapped] where Element == Wrapped? { compactMap { $0 } }
}

/// What an organisation actually is, rather than what its directory is called.
///
/// A Claude account belongs to several organisations at once — a Team it was invited to and
/// the personal one that carries its own plan — and the session store names them only by UUID.
/// Two destinations reading `org 16a5cf52…` and `org 27450961…` are not a choice anyone can
/// make.
public struct OrgIdentity: Sendable, Hashable {
    /// `analyticsandsociety`, or `florence@example.com's Organization`.
    public let name: String?
    /// The raw plan string as Claude writes it: `claude_team`, `claude_max`, `claude_pro`.
    public let planRaw: String?
    /// The account this record came from, useful when the store itself has no session to
    /// read an address out of.
    public let email: String?

    public init(name: String?, planRaw: String?, email: String?) {
        self.name = name
        self.planRaw = planRaw
        self.email = email
    }

    /// A short badge: `Team`, `Max`, `Pro`, `Enterprise`.
    ///
    /// Unknown values are prettified rather than dropped — the set of plans grows, and showing
    /// an unfamiliar plan verbatim is more useful than showing nothing.
    public var planLabel: String? {
        guard let planRaw, !planRaw.isEmpty else { return nil }
        switch planRaw {
        case "claude_team": return "Team"
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_enterprise": return "Enterprise"
        case "claude_free": return "Free"
        default:
            let stripped = planRaw.hasPrefix("claude_") ? String(planRaw.dropFirst(7)) : planRaw
            return stripped.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The org's name as a person would say it.
    ///
    /// A personal organisation is named `<email>'s Organization` by the server, which is both
    /// long and redundant next to the account address it is already shown beside. Claude's own
    /// account menu calls it "Personal"; so does this.
    public func displayName(besideAccount accountEmail: String?) -> String? {
        guard let name else { return nil }
        for candidate in [accountEmail, email].compacted() where name == "\(candidate)'s Organization" {
            return "Personal"
        }
        return name
    }

    var isEmpty: Bool { name == nil && planRaw == nil && email == nil }
}

/// Resolves organisation names and plans by reading the `oauthAccount` records Claude leaves
/// on disk.
///
/// Nothing else on disk carries this. The Cowork session store records the org only as a
/// directory name; session metadata has an account address but no org at all; the app's own
/// caches keep usage samples and feature flags, and the per-org allowlist cache is encrypted.
/// The one place it appears in the clear is `.claude.json`, which Claude Code writes both at
/// `~/.claude.json` and inside each Cowork session's workspace.
///
/// Identity is keyed by organisation, not by account, so a record found under any account in
/// any install resolves that organisation everywhere it appears. On this machine one Team org
/// is shared by three accounts and is learned once.
public enum OrgDirectory {

    /// How many session workspaces to open per org before giving up on it.
    ///
    /// Most workspace `.claude.json` files carry no `oauthAccount` block at all — on this
    /// machine 5 of 51 do — so a resolvable org is usually found in the first few, and an
    /// unresolvable one must not cost a walk through hundreds of directories.
    static let workspaceProbeLimit = 12

    public struct Resolved: Sendable {
        public var orgs: [String: OrgIdentity] = [:]
        public var accountEmails: [String: String] = [:]
        /// How many distinct accounts on this machine hold each organisation.
        ///
        /// A personal organisation belongs to exactly one account; one that appears under
        /// several is shared, which is what a Team is. Not all orgs can be named — some
        /// `oauthAccount` records carry a UUID with a null name and type — and for those this
        /// is the only thing left that distinguishes one from another.
        public var accountsPerOrg: [String: Int] = [:]
    }

    /// Build the directory from every store on the machine plus the Claude Code CLI's config.
    public static func build(stores: [StoreRef],
                             claudeCodeConfigDir: URL = Discovery.defaultClaudeCodeConfigDir())
        -> Resolved {
        var resolved = Resolved()
        var holders: [String: Set<String>] = [:]

        // The CLI's own record first: it is a single cheap file, and it is the only source for
        // an install that has been signed into but never used, which has no workspace to read.
        absorb(fileAt: claudeCodeConfigDir.deletingLastPathComponent()
                .appendingPathComponent(".claude.json"), into: &resolved)
        absorb(fileAt: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json"), into: &resolved)

        for store in stores {
            let accountDirs = (try? FileManager.default.contentsOfDirectory(
                at: store.sessionsRoot, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for accountDir in accountDirs {
                let accountId = accountDir.lastPathComponent
                guard StoreLayout.isAccountDirName(accountId) else { continue }
                let orgDirs = (try? FileManager.default.contentsOfDirectory(
                    at: accountDir, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                for orgDir in orgDirs {
                    let orgId = orgDir.lastPathComponent
                    guard StoreLayout.isAccountDirName(orgId) else { continue }
                    holders[orgId, default: []].insert(accountId)
                    if resolved.orgs[orgId] != nil { continue }
                    absorb(orgDirectory: orgDir, into: &resolved)
                }
            }
        }
        resolved.accountsPerOrg = holders.mapValues(\.count)
        return resolved
    }

    /// Look for an `oauthAccount` in an org directory: first the org-level file, then a
    /// bounded number of session workspaces.
    static func absorb(orgDirectory: URL, into resolved: inout Resolved) {
        absorb(fileAt: orgDirectory.appendingPathComponent(".claude.json"), into: &resolved)
        let orgId = orgDirectory.lastPathComponent
        if resolved.orgs[orgId] != nil { return }

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: orgDirectory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        // Newest first: a recent session is likelier to carry a current record.
        let workspaces = entries
            .filter { $0.lastPathComponent.hasPrefix(StoreLayout.sessionPrefix) }
            .sorted { modified($0) > modified($1) }
            .prefix(workspaceProbeLimit)

        for workspace in workspaces {
            absorb(fileAt: workspace.appendingPathComponent(".claude/.claude.json"),
                   into: &resolved)
            if resolved.orgs[orgId] != nil { return }
        }
    }

    /// Read one `.claude.json` and record whatever identity it names.
    ///
    /// Only the `oauthAccount` metadata block is read. That file can also hold history and
    /// project state, and its sibling `.credentials.json` holds tokens; neither is touched.
    static func absorb(fileAt url: URL, into resolved: inout Resolved) {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return }

        if let accountUuid = account["accountUuid"] as? String,
           let email = account["emailAddress"] as? String,
           !email.isEmpty {
            resolved.accountEmails[accountUuid] = email
        }

        guard let orgUuid = account["organizationUuid"] as? String, !orgUuid.isEmpty else { return }
        let identity = OrgIdentity(name: account["organizationName"] as? String,
                                   planRaw: account["organizationType"] as? String,
                                   email: account["emailAddress"] as? String)
        // A record naming only an address says nothing about the organisation. Storing one
        // would claim the slot and stop a later, fuller record from filling it, leaving the
        // org counted as resolved while still rendering as a bare UUID.
        guard identity.name != nil || identity.planRaw != nil else { return }
        // First writer wins: sources are visited cheapest and most authoritative first.
        if resolved.orgs[orgUuid] == nil { resolved.orgs[orgUuid] = identity }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
    }
}
