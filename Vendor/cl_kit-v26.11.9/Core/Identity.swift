// ProfileCore · identity: a Claude account seat, and the one way two of them are compared.
//
// ProfileCore holds rules true for any app that reads Claude Code's accounts and usage (cl_audit today, cl_quick later):
// Foundation only (never AppKit, SwiftUI or WidgetKit), no app's paths, files, wording or global state; every input is a
// parameter. Each app wraps it with its own screens and words (Core/README.md).

import Foundation

/// A Claude account seat: an account in an organisation. Usage limits belong to it, so a personal plan and a team
/// seat on the same email are two seats. Every set-up profile is linked to exactly one, and no two profiles share one.
public struct Seat: Codable, Equatable, Hashable {
    public var account: String            // Claude's accountUuid
    public var organization: String?      // its organizationUuid (nil when Claude recorded none)
    public var email: String?             // shown only; checks compare the ids
    public var linkedAt: Date?
    public var was: String?               // the email of the seat it replaced, when the profile was linked to another account

    public init(account: String, organization: String? = nil, email: String? = nil, linkedAt: Date? = nil, was: String? = nil) {
        self.account = account; self.organization = organization; self.email = email; self.linkedAt = linkedAt; self.was = was
    }

    /// The same seat (the ids; not the email or when it was linked), exactly as written: case counts, and no organisation
    /// (nil) is not an empty one. For "is this the same account / whose account is it" use `sameAccount`, the one owner
    /// rule; this exact equality is kept for change detection and saved keys (Core/README.md).
    public func same(_ o: Seat?) -> Bool { o.map { account == $0.account && organization == $0.organization } ?? false }

    /// The same account by the one owner rule (AccountIdentity.sameAccount).
    public func sameAccount(_ o: Seat?) -> Bool { o.map { AccountIdentity(self).sameAccount(AccountIdentity($0)) } ?? false }
}

/// An account and organisation by their ids only, as a record of a switch keeps them (no organisation is "").
public struct SeatID: Codable, Equatable, Hashable {
    public var account: String
    public var organization: String

    public init(_ s: Seat) { account = s.account; organization = s.organization ?? "" }
    public init(account: String, organization: String) { self.account = account; self.organization = organization }

    /// The same seat as `s`, exactly as written (case counts); a seat with no organisation matches "".
    public func same(_ s: Seat?) -> Bool { s.map { $0.account == account && ($0.organization ?? "") == organization } ?? false }

    /// The same seat as `s` whatever the case of the ids (AccountID): how a switch tells it reached its account.
    public func sameIgnoringCase(_ s: Seat?) -> Bool {
        s.map { AccountID.same(account, $0.account) && AccountID.sameOrganization(organization, $0.organization) } ?? false
    }

    /// The same seat as another SeatID whatever the case of the ids.
    public func sameIgnoringCase(_ o: SeatID) -> Bool {
        AccountID.same(account, o.account) && AccountID.sameOrganization(organization, o.organization)
    }
}

/// Who an account is, as far as one source knows: its id when the source gives one (a sign-in record does; a running
/// claude process's own account says only its address and organisation), and where that came from. Two identities are
/// the same account by their ids when both have one, else by address and organisation.
public struct AccountIdentity: Equatable, Hashable {
    /// Where an identity came from: said by the running claude process itself, or guessed from a file (a folder's
    /// .claude.json, a saved record), which can be stale.
    public enum Source: String, Codable { case verified, guessed }

    public var account: String?
    public var email: String?
    public var organization: String?
    /// The organisation's name, where a source names it (a running claude names its organisation by name only).
    public var organizationName: String?
    public var source: Source

    public init(account: String?, email: String?, organization: String?, organizationName: String? = nil, source: Source) {
        self.account = account; self.email = email; self.organization = organization
        self.organizationName = organizationName; self.source = source
    }

    /// A seat's identity (from a file unless said otherwise). An empty account id is none.
    public init(_ s: Seat, source: Source = .guessed) {
        self.init(account: s.account.isEmpty ? nil : s.account, email: s.email, organization: s.organization, source: source)
    }

    /// The same seat: `compare` says `.seat`. A seat that isn't known (an organisation only one side names) is not the same.
    public func matches(_ o: AccountIdentity) -> Bool { compare(o) == .seat }

    /// The kit's one seat comparison. First the account: by the ids when both have one (case doesn't count; never the
    /// address then), else by the address (case doesn't count; both must have one). Then the organisation: by its id
    /// when both have one, else by its name when both have one (case doesn't count); none on either side is the same
    /// ("none recorded", as AccountID has it). An organisation only one side names doesn't tell the seats apart:
    /// `.seatNotKnown`, the same account but maybe another seat (a personal plan and a Team seat share an address and
    /// even an account id; only the organisation tells them apart).
    public func compare(_ o: AccountIdentity) -> SeatMatch {
        // every value as it is compared: trimmed, and an empty one is none
        func named(_ s: String?) -> String? {
            s.flatMap { let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t }
        }
        if let a = account, let b = o.account {
            guard AccountID.same(named(a) ?? a, named(b) ?? b) else { return .different }
        } else {
            guard let e = named(email)?.lowercased(), e == named(o.email)?.lowercased() else { return .different }
        }
        let (x, y) = (named(organization), named(o.organization))
        if let x, let y { return AccountID.same(x, y) ? .seat : .different }
        let (m, n) = (named(organizationName), named(o.organizationName))
        if let m, let n { return m.lowercased() == n.lowercased() ? .seat : .different }
        // none on both sides is one; anything else left (one side only, or an id on one and a name on the other) can't
        // be compared
        return x == nil && m == nil && y == nil && n == nil ? .seat : .seatNotKnown
    }

    /// An account known by its address only (a typed address, the address a reading was for).
    public static func address(_ email: String?, source: Source = .guessed) -> AccountIdentity {
        AccountIdentity(account: nil, email: email, organization: nil, source: source)
    }

    /// Known by its address only: no account id and no organisation (an address typed, a standby entry remembered by its
    /// address).
    /// An organisation named by its name only (a running claude's word) is an organisation: such an identity isn't known
    /// by its address only, so it never matches the other seat on its address by the address alone.
    public var addressOnly: Bool {
        (account ?? "").isEmpty && (organization ?? "").isEmpty
            && (organizationName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one owner rule, for every "is this the same account / whose account is it" check: `compare` says `.seat`
    /// (`matches`), except that one side known by its address only (no id, no organisation by id or name) is matched by
    /// the address (cl_quick's placeholder rule). It is `compare` with that one exception, not a second comparison.
    public func sameAccount(_ o: AccountIdentity) -> Bool {
        guard addressOnly || o.addressOnly else { return matches(o) }
        guard let e = email?.lowercased(), !e.isEmpty else { return false }
        return e == o.email?.lowercased()
    }

    /// The identity as a source that names no organisation knows it (a status record, the Claude app's config.json): an
    /// organisation not known there isn't "none", so a seat compared with such an identity leaves its own out too.
    public var withoutOrganization: AccountIdentity {
        AccountIdentity(account: account, email: email, organization: nil, source: source)
    }
}

/// How two accounts compare (AccountIdentity.compare, the one seat comparison).
public enum SeatMatch: String, Equatable {
    /// The same seat: the same account in the same organisation (or none named on either side).
    case seat
    /// The same account (its id, or its address), but an organisation only one side names: maybe another seat on it.
    /// Nothing seat-specific (ids, plan, numbers) is taken from one side for the other.
    case seatNotKnown
    /// Another account, or another seat of it.
    case different
}

/// Account and organisation ids compared loosely: case doesn't count (Claude writes them in lower case, a hand-edited file
/// or another tool may not), and an organisation that isn't recorded (nil) is the same as an empty one. Used where the
/// app already compared that way (an id read from a process or a record, a switch reaching its account); Seat.same and
/// SeatID.same stay exact for now (Core/README.md, open questions).
public enum AccountID {
    /// An id as it is compared and used as a key.
    public static func normal(_ id: String) -> String { id.lowercased() }

    /// The same account id (both there).
    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return normal(a) == normal(b)
    }

    /// The same organisation: nil and "" are one (none recorded).
    public static func sameOrganization(_ a: String?, _ b: String?) -> Bool { normal(a ?? "") == normal(b ?? "") }
}
