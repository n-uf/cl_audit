// ClaudeAuth · the saved key: what an app keeps an account (and its numbers) under. A seat is (account id, organisation):
// a personal plan and a Team seat on one address are two keys. Until the account id is known, the address stands in for
// it ("email:" and the address); until the organisation's id is known, its name stands in ("name:" and the name); with no
// organisation at all the seat isn't known yet. Each is upgraded in place once the better one appears, never replaced by
// another account's or seat's.

import Foundation
import ProfileCore

public struct AccountKey: Codable, Hashable {
    public static let addressPrefix = "email:"
    public static let namePrefix = "name:"

    /// The account id in its normal form (AccountID.normal), or `addressPrefix` and the address in lower case until the
    /// id is known.
    public var account: String
    /// The organisation's id in its normal form, or `namePrefix` and its name in lower case until the id is known; nil
    /// while the seat isn't known (no organisation named yet).
    public var organization: String?

    /// A key as written (case doesn't count: both parts are kept in lower case, as the other initialisers keep them).
    public init(account: String, organization: String? = nil) {
        self.account = account.lowercased(); self.organization = organization?.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case account, organization }

    /// A saved key read back in lower case too (one written by hand, or by an older build, in another case).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(account: try c.decode(String.self, forKey: .account),
                  organization: try c.decodeIfPresent(String.self, forKey: .organization))
    }

    /// The key of an account as a source names it; nil when it names nobody (no id, no address).
    public init?(_ a: SignedInAccount) {
        guard let account = a.accountID.map(AccountID.normal) ?? a.email.map({ Self.addressPrefix + $0.lowercased() }) else { return nil }
        self.account = account
        organization = a.organizationID.map(AccountID.normal) ?? a.organizationName.map { Self.namePrefix + $0.lowercased() }
    }

    /// The account is known by its address only (no id yet).
    public var isPlaceholder: Bool { account.hasPrefix(Self.addressPrefix) }
    /// The seat is known: an organisation is named (by its id, or its name until the id is known).
    public var seatKnown: Bool { organization != nil }

    /// The key as one text, for a key inside a larger one ("<profile>|<key>"): the account, then "|" and the organisation
    /// when it is known. "%" and "|" inside either part are escaped ("%25", "%7C"), so `init(text:)` reads it back.
    public var text: String { Self.escape(account) + (organization.map { "|" + Self.escape($0) } ?? "") }

    public init?(text: String) {
        let parts = text.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let a = parts[0].removingPercentEncoding, !a.isEmpty else { return nil }
        account = a.lowercased()
        if parts.count == 2 {
            guard let o = parts[1].removingPercentEncoding, !o.isEmpty else { return nil }
            organization = o.lowercased()
        }
    }

    /// The key as an account (guessed): its id or its address, its organisation's id or its name.
    public var identity: SignedInAccount {
        func after(_ prefix: String, _ s: String?) -> String? { s.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil } }
        let org = organization.flatMap { $0.hasPrefix(Self.namePrefix) ? nil : $0 }
        return SignedInAccount(accountID: isPlaceholder ? nil : account, email: after(Self.addressPrefix, account),
                               organizationID: org, organizationName: after(Self.namePrefix, organization), origin: .record)
    }

    /// How `a` compares with this key (the one seat comparison). A key with an account id is compared by ids: an
    /// account that names no id (a running claude's word alone) isn't this key's by the key alone.
    public func match(_ a: SignedInAccount) -> SeatMatch { identity.match(a) }

    /// This key with what `a` knows better filled in: the account id for an address placeholder, and the organisation's id
    /// for a name placeholder of the same seat. The key itself when `a` adds nothing; nil when `a` is another account or
    /// seat (never a key moved onto another one).
    ///
    /// A key whose seat isn't known gets an organisation only when `seatOfTheNumbers` is true: the caller says `a` is the
    /// account the numbers kept under this key came from (their own source named that seat). Otherwise the key stays
    /// apart: the first seat seen on an address isn't, by itself, the seat its numbers were read on.
    public func upgraded(with a: SignedInAccount, seatOfTheNumbers: Bool = false) -> AccountKey? {
        let m = match(a)
        guard m != .different else { return nil }
        var k = self
        if isPlaceholder, let id = a.accountID { k.account = AccountID.normal(id) }
        if organization == nil {
            if seatOfTheNumbers {
                k.organization = a.organizationID.map(AccountID.normal) ?? a.organizationName.map { Self.namePrefix + $0.lowercased() }
            }
        } else if organization?.hasPrefix(Self.namePrefix) == true, m == .seat, let id = a.organizationID {
            k.organization = AccountID.normal(id)
        }
        return k
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "|", with: "%7C")
    }
}
