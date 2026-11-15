// ClaudeAuth · identity: which account a folder is signed in to, as each source says it, and the one answer.
//
// Three sources, two kinds:
// - verified: the running `claude` itself (its `initialize` answer's account: address and organisation name, no ids), or
//   Anthropic's reply about the folder's own sign-in (the profile reply: ids, address, organisation);
// - guessed: the folder's sign-in record (.claude.json's oauthAccount), which Claude Code writes at a different moment
//   than its Keychain item and which can be stale or hand-edited.
// Two of them are the same account by their account ids when both have one, else by address and organisation.

import Foundation
import ProfileCore

/// An account as one source names it. Never a token: ids, address, organisation and plan only.
public struct SignedInAccount: Equatable, Hashable {
    /// Where it was read. `process` and `server` are verified; `record` is guessed.
    public enum Origin: String, Codable { case process, server, record }

    public var accountID: String?          // Claude's accountUuid (a running process doesn't say it)
    public var email: String?
    public var organizationID: String?     // organizationUuid
    public var organizationName: String?   // what a running process says of its organisation
    public var plan: String?               // the record's planDisplayName, as it is
    public var origin: Origin

    public init(accountID: String? = nil, email: String? = nil, organizationID: String? = nil, organizationName: String? = nil,
                plan: String? = nil, origin: Origin) {
        func clean(_ s: String?) -> String? {
            s.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        }
        self.accountID = clean(accountID); self.email = clean(email); self.organizationID = clean(organizationID)
        self.organizationName = clean(organizationName); self.plan = clean(plan); self.origin = origin
    }

    /// Verified (said by the process or by Anthropic) or guessed (read from a file).
    public var source: AccountIdentity.Source { origin == .record ? .guessed : .verified }

    /// It names someone: an account id or an address.
    public var names: Bool { accountID != nil || email != nil }

    /// ProfileCore's identity (organisation by its id), for the rules there. Its `matches` is stricter than this one's
    /// where only one side names an organisation (there: another account); between sources, use `matches` here.
    public var identity: AccountIdentity {
        AccountIdentity(account: accountID, email: email, organization: organizationID, source: source)
    }

    /// The same account. By the account ids when both have one (case doesn't count), with the organisations' ids
    /// (none recorded is the same as an empty one, as ProfileCore's AccountID has it). Else by the address (case doesn't
    /// count; both must have one) and the organisation: by its id when both have one, else by its name when both have
    /// one; an organisation only one side names doesn't tell them apart (a running process names its organisation, the
    /// record has both).
    public func matches(_ o: SignedInAccount) -> Bool { match(o) != .different }

    /// How two accounts compare: `seat` when the ids, or the address and an organisation both name, say they are the
    /// same seat; `address` when only the address does (an organisation one side doesn't name); else `different`.
    public enum Match: Equatable { case seat, address, different }

    public func match(_ o: SignedInAccount) -> Match {
        if let a = accountID, let b = o.accountID {
            return AccountID.same(a, b) && AccountID.sameOrganization(organizationID, o.organizationID) ? .seat : .different
        }
        guard let e = email?.lowercased(), e == o.email?.lowercased() else { return .different }
        if let x = organizationID, let y = o.organizationID { return AccountID.same(x, y) ? .seat : .different }
        if let x = organizationName, let y = o.organizationName { return x.lowercased() == y.lowercased() ? .seat : .different }
        return .address
    }

    // MARK: reading each source (never a token)

    /// The folder's record: .claude.json's oauthAccount block (accountUuid, emailAddress, organizationUuid,
    /// organizationName, planDisplayName). nil when it names nobody (signed out).
    public static func record(_ oauthAccount: [String: Any]?) -> SignedInAccount? {
        guard let o = oauthAccount else { return nil }
        let a = SignedInAccount(accountID: o["accountUuid"] as? String, email: o["emailAddress"] as? String,
                                organizationID: o["organizationUuid"] as? String, organizationName: o["organizationName"] as? String,
                                plan: o["planDisplayName"] as? String, origin: .record)
        return a.names ? a : nil
    }

    /// A running `claude`'s own word: its `initialize` answer's `account` (email, organization; no ids). nil when it
    /// names nobody (a process on a key or a token, or a Claude Code that doesn't say).
    public static func process(_ account: [String: Any]?) -> SignedInAccount? {
        guard let a = account else { return nil }
        let s = SignedInAccount(email: a["email"] as? String, organizationName: a["organization"] as? String, origin: .process)
        return s.email != nil ? s : nil
    }

    /// Anthropic's reply about the folder's sign-in (the OAuth profile reply: account.uuid and email_address,
    /// organization.uuid and name). nil when it names nobody.
    public static func server(_ reply: Data) -> SignedInAccount? {
        guard let j = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any] else { return nil }
        let a = j["account"] as? [String: Any], o = j["organization"] as? [String: Any]
        let s = SignedInAccount(accountID: a?["uuid"] as? String, email: (a?["email_address"] ?? a?["email"]) as? String,
                                organizationID: o?["uuid"] as? String, organizationName: o?["name"] as? String, origin: .server)
        return s.names ? s : nil
    }
}

/// The one answer: which account the folder is signed in to, and how sure that is.
public struct FolderSignIn: Equatable {
    public enum Verdict: String, Equatable {
        /// A verified source names it, and the record agrees (or has nothing).
        case verified
        /// Only the record names it.
        case guessed
        /// A verified source names another account than the record: Claude Code is between the two writes (a sign-in
        /// landing), or the record is stale or edited. `account` is the verified one; the record is in `record`.
        case differs
        /// Nobody is named: signed out, or nothing known yet.
        case none
    }

    public var verdict: Verdict
    /// The account the folder is signed in to: the verified one where there is one (with the record's ids and plan added
    /// when the two are the same seat, not on the address alone), else the record's.
    public var account: SignedInAccount?
    public var record: SignedInAccount?
    public var verified: SignedInAccount?

    /// Is the folder signed in to `a` (by `SignedInAccount.matches`)? False when nobody is named.
    public func isSignedIn(to a: SignedInAccount) -> Bool { account?.matches(a) ?? false }

    /// The answer from the record (guessed) and a verified word (the process, or Anthropic), either of which may be missing.
    public static func answer(record: SignedInAccount?, verified: SignedInAccount?) -> FolderSignIn {
        let r = record?.names == true ? record : nil
        let v = verified?.names == true && verified?.origin != .record ? verified : nil
        switch (r, v) {
        case (nil, nil): return FolderSignIn(verdict: .none, account: nil, record: nil, verified: nil)
        case (let r?, nil): return FolderSignIn(verdict: .guessed, account: r, record: r, verified: nil)
        case (nil, let v?): return FolderSignIn(verdict: .verified, account: v, record: nil, verified: v)
        case (let r?, let v?):
            let m = v.match(r)
            guard m != .different else { return FolderSignIn(verdict: .differs, account: v, record: r, verified: v) }
            // the record's ids and plan only when it is the same seat: on the address alone they may be another seat's
            // (a personal plan and a team seat on one address)
            guard m == .seat else { return FolderSignIn(verdict: .verified, account: v, record: r, verified: v) }
            var merged = v
            merged.accountID = v.accountID ?? r.accountID
            merged.email = v.email ?? r.email
            merged.organizationID = v.organizationID ?? r.organizationID
            merged.organizationName = v.organizationName ?? r.organizationName
            merged.plan = r.plan ?? v.plan
            return FolderSignIn(verdict: .verified, account: merged, record: r, verified: v)
        }
    }
}
