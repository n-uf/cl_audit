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
    /// (nil) is not an empty one. AccountID's looser comparison is a proposal for a later step (Core/README.md).
    public func same(_ o: Seat?) -> Bool { o.map { account == $0.account && organization == $0.organization } ?? false }
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
    public var source: Source

    public init(account: String?, email: String?, organization: String?, source: Source) {
        self.account = account; self.email = email; self.organization = organization; self.source = source
    }

    /// A seat's identity (from a file unless said otherwise).
    public init(_ s: Seat, source: Source = .guessed) {
        self.init(account: s.account, email: s.email, organization: s.organization, source: source)
    }

    /// The same account: by the ids when both have one; else by address (case doesn't count) and organisation.
    public func matches(_ o: AccountIdentity) -> Bool {
        if let a = account, let b = o.account { return AccountID.same(a, b) && AccountID.sameOrganization(organization, o.organization) }
        guard let e = email?.lowercased(), !e.isEmpty, e == o.email?.lowercased() else { return false }
        return AccountID.sameOrganization(organization, o.organization)
    }
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
