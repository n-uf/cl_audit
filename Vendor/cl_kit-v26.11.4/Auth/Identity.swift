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

    /// It names someone: an account id or an address (either is enough to be signed in).
    public var names: Bool { accountID != nil || email != nil }

    /// ProfileCore's identity (the organisation by its id and its name), where the one seat comparison lives.
    public var identity: AccountIdentity {
        AccountIdentity(account: accountID, email: email, organization: organizationID, organizationName: organizationName,
                        source: source)
    }

    /// Maybe the same account: `match` isn't `.different` (the same seat, or the same account whose seat isn't known).
    /// Looser than ProfileCore's `AccountIdentity.matches` (the same seat): named apart so the two aren't taken for one.
    public func maybeSame(_ o: SignedInAccount) -> Bool { match(o) != .different }

    /// How two accounts compare: ProfileCore's one seat comparison (AccountIdentity.compare). The account by its ids
    /// when both have one, else by its address (case doesn't count); then the organisation by its id when both have one,
    /// else by its name (case doesn't count); one only one side names is `.seatNotKnown`.
    public typealias Match = SeatMatch

    public func match(_ o: SignedInAccount) -> Match { identity.compare(o.identity) }

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

/// The one answer to "which account is Claude Code's on this folder", and how sure that is; and whose numbers a verified
/// source's are. It answers for Claude Code only: an app with other sign-ins of its own (a desktop window's) asks those
/// apart and names them apart.
///
/// The rule: a verified word (a running claude's own `initialize` account, or Anthropic's reply about the folder's
/// stored sign-in) beats the record, which is only a guess. Numbers belong to the source that gave them: to the
/// verified account, never moved to the record's when the two disagree.
public struct FolderSignIn: Equatable {
    public enum Verdict: String, Equatable {
        /// A verified source names it, and the record names the same seat (or nobody).
        case verified
        /// A verified source names the record's account (the same id or address), but only one of them names an
        /// organisation, so the seat isn't known (a personal plan and a Team seat share an address). `account` is the
        /// verified word as it is: no ids, plan or organisation taken from the record, which may be the other seat's.
        case seatNotKnown
        /// Only the record names it.
        case guessed
        /// A verified source names another account or seat than the record: Claude Code is between the two writes (a
        /// sign-in landing under a running claude), or the record is stale or edited. `account` is the verified one;
        /// the record is in `record`.
        case differs
        /// Nobody is named: signed out, or nothing known yet.
        case none
    }

    public var verdict: Verdict
    /// Claude Code's account on the folder: the verified one where there is one (with the record's ids and plan added
    /// only when the two are the same seat), else the record's.
    public var account: SignedInAccount?
    public var record: SignedInAccount?
    public var verified: SignedInAccount?
    /// The account the verified source's numbers belong to: the verified account (also when it differs from the record);
    /// with a process trail, the record's while a silent process's folder still names the seat it started on. nil: no
    /// numbers are anyone's (a guess alone owns none).
    public var numbersBelongTo: SignedInAccount?

    public init(verdict: Verdict, account: SignedInAccount?, record: SignedInAccount?, verified: SignedInAccount?,
                numbersBelongTo: SignedInAccount? = nil) {
        self.verdict = verdict; self.account = account; self.record = record; self.verified = verified
        self.numbersBelongTo = numbersBelongTo
    }

    /// Signed in, by D1's rule: someone is named, by an account id or an address.
    public var isSignedIn: Bool { account?.names ?? false }

    /// Is the folder maybe signed in to `a` (by `SignedInAccount.maybeSame`)? False when nobody is named.
    public func isSignedIn(to a: SignedInAccount) -> Bool { account?.maybeSame(a) ?? false }

    /// The answer from the record (guessed) and a verified word (the process, or Anthropic), either of which may be missing.
    public static func answer(record: SignedInAccount?, verified: SignedInAccount?) -> FolderSignIn {
        let r = record?.names == true ? record : nil
        let v = verified?.names == true && verified?.origin != .record ? verified : nil
        switch (r, v) {
        case (nil, nil): return FolderSignIn(verdict: .none, account: nil, record: nil, verified: nil)
        case (let r?, nil): return FolderSignIn(verdict: .guessed, account: r, record: r, verified: nil)
        case (nil, let v?): return FolderSignIn(verdict: .verified, account: v, record: nil, verified: v, numbersBelongTo: v)
        case (let r?, let v?):
            switch v.match(r) {
            case .different: return FolderSignIn(verdict: .differs, account: v, record: r, verified: v, numbersBelongTo: v)
            // the record's ids and plan only when it is the same seat: otherwise they may be another seat's
            case .seatNotKnown: return FolderSignIn(verdict: .seatNotKnown, account: v, record: r, verified: v, numbersBelongTo: v)
            case .seat:
                let merged = v.filled(from: r)
                return FolderSignIn(verdict: .verified, account: merged, record: r, verified: v, numbersBelongTo: merged)
            }
        }
    }

    /// The answer with a running claude's trail (ProcessTrail): its word, with the launch record's ids and organisation id
    /// when it named the seat the process started on, so an organisation renamed while it runs is still its own. A
    /// process that said nothing owns its numbers only while the record still names the seat it started on.
    public static func answer(record: SignedInAccount?, trail: ProcessTrail) -> FolderSignIn {
        if let word = trail.verified { return answer(record: record, verified: word) }
        var a = answer(record: record, verified: nil)
        if let launch = trail.launchedOn, let now = a.record, launch.match(now) == .seat { a.numbersBelongTo = now }
        return a
    }
}

extension SignedInAccount {
    /// This account with what it doesn't say taken from `other` (the same seat): ids, address and organisation where
    /// this one has none, and `other`'s plan (a record's plan is the one Claude Code wrote).
    func filled(from other: SignedInAccount) -> SignedInAccount {
        var m = self
        m.accountID = accountID ?? other.accountID
        m.email = email ?? other.email
        m.organizationID = organizationID ?? other.organizationID
        m.organizationName = organizationName ?? other.organizationName
        m.plan = other.plan ?? plan
        return m
    }
}
