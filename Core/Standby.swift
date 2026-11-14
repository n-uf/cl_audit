// ProfileCore · standby accounts: one of a profile's other accounts, the account book (how long ago, which one to pick),
// the note an account's move between profiles leaves, and the tidy standby list. Rules only: what an app says about
// them (a switch's words, a note's sentence) stays in the app.

import Foundation

/// One of a profile's other accounts.
public struct StandbyAccount: Codable, Equatable, Hashable, Identifiable {
    public var id: String                 // short and fixed: an app may name what it keeps for the account by it
    public var email: String              // as found or typed; shown
    public var seat: Seat?                // the account and organisation, once a sign-in or the window's records said
    public var addedAt: Date?
    public var plan: String?              // Claude's own name for its plan ("Ultra"), as last seen in use
    public var lastInUse: Date?           // when it was last the profile's account in use (it left the folder then); nil: never here
    /// Its week as last read while it was in use, and when that week starts again: kept to pick which standby account a
    /// full limit offers (AccountBook.offerOrder), never shown. A standby account isn't read.
    public var lastWeek: Double?
    public var lastWeekResets: Date?

    public init(email: String, seat: Seat? = nil, addedAt: Date? = Date(), id: String = StandbyAccount.newID(),
                plan: String? = nil, lastInUse: Date? = nil, lastWeek: Double? = nil, lastWeekResets: Date? = nil) {
        self.id = id; self.email = email; self.seat = seat; self.addedAt = addedAt
        self.plan = plan; self.lastInUse = lastInUse; self.lastWeek = lastWeek; self.lastWeekResets = lastWeekResets
    }

    public static func newID() -> String { String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(8)) }

    /// The decoder's clock, when a caller gives one (`decoder.userInfo[StandbyAccount.now]`); else the Mac's.
    public static let now = CodingUserInfoKey(rawValue: "profilecore.now")!

    private enum CodingKeys: String, CodingKey { case id, email, seat, addedAt, plan, lastInUse, lastWeek, lastWeekResets }

    /// Read with every date and the week kept in a sane range (AccountBook.sane): a hand-edited or crafted value is
    /// dropped, never trusted (a date from far away would trap the words that say how long ago it was).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.decode(String.self, forKey: .email)
        seat = try c.decodeIfPresent(Seat.self, forKey: .seat)
        plan = try? c.decodeIfPresent(String.self, forKey: .plan)
        let now = decoder.userInfo[Self.now] as? Date ?? Date()
        addedAt = AccountBook.sane((try? c.decodeIfPresent(Date.self, forKey: .addedAt)) ?? nil, now: now)
        lastInUse = AccountBook.sane((try? c.decodeIfPresent(Date.self, forKey: .lastInUse)) ?? nil, now: now)
        lastWeekResets = AccountBook.sane((try? c.decodeIfPresent(Date.self, forKey: .lastWeekResets)) ?? nil, now: now, ahead: 60 * 86400)
        lastWeek = ((try? c.decodeIfPresent(Double.self, forKey: .lastWeek)) ?? nil).flatMap { $0.isFinite && $0 >= 0 && $0 <= 1000 ? $0 : nil }
    }

    /// Known to be full: its week was full when it was last read, and that week hasn't started again yet.
    public func knownFull(now: Date = Date()) -> Bool {
        guard let w = lastWeek, AtLimit.isFull(w) else { return false }
        return (lastWeekResets ?? .distantFuture) > now
    }
}

/// The bookkeeping of a profile's accounts that needs nothing but its records (cl_quick's AccountBook): how long ago, and
/// which standby account to pick. Picks are separate functions side by side, one per question an app asks: `best` (which
/// to offer while a limit is full: the least used with room) and `mostRecent` (the one seen most recently); an app adds
/// its own beside them rather than bending one ranking.
public enum AccountBook {
    /// "just now", "12 min ago", "3 h ago", "yesterday", "4 days ago", "3 weeks ago".
    public static func ago(_ d: Date, now: Date = Date()) -> String {
        // never a trap: a gap that isn't a number, or longer than ~300 years, is said as that much
        let raw = now.timeIntervalSince(d)
        let s = raw.isFinite ? min(max(0, raw), 1e10) : 0
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        case ..<(2 * 86400): return "yesterday"
        case ..<(14 * 86400): return "\(Int(s / 86400)) days ago"
        default: return "\(Int(s / (7 * 86400))) weeks ago"
        }
    }

    /// A date read from a saved record, or nil when it isn't one an app could have written: not a number, before 2000,
    /// or later than now plus `ahead` (a day, or a reset up to two months ahead).
    public static func sane(_ d: Date?, now: Date = Date(), ahead: TimeInterval = 86400) -> Date? {
        guard let d, d.timeIntervalSinceReferenceDate.isFinite,
              d >= Date(timeIntervalSince1970: 946_684_800), d <= now.addingTimeInterval(ahead) else { return nil }
        return d
    }

    /// The standby accounts in the order a full limit offers them (cl_quick's rule): those not known to be full first, the
    /// least used first by their week as last read (one never read here counts as unknown, after those read), then the most
    /// recently in use; those known to be full last. Only accounts with a seat can be switched to; the others come at the
    /// end, in the profile's order.
    public static func offerOrder(_ list: [StandbyAccount], now: Date = Date()) -> [StandbyAccount] {
        list.enumerated().sorted { a, b in
            func rank(_ s: StandbyAccount) -> Int { s.seat == nil ? 2 : s.knownFull(now: now) ? 1 : 0 }
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            // a week that started again since it was read counts as empty
            func used(_ s: StandbyAccount) -> Double {
                guard let w = s.lastWeek else { return 101 }
                return (s.lastWeekResets.map { $0 <= now } ?? false) ? 0 : w
            }
            if used(x) != used(y) { return used(x) < used(y) }
            let (p, q) = (x.lastInUse ?? .distantPast, y.lastInUse ?? .distantPast)
            return p != q ? p > q : a.offset < b.offset
        }.map(\.element)
    }

    /// The one rule for the standby account offered while a limit is full (wherever an app offers one: preselected, in a
    /// menu, in an alert): the first in `offerOrder` that has a seat and isn't known to be full, or nil.
    /// An account remembered by its address only (no seat yet) is never the one offered: whether it has room isn't known,
    /// and switching to it moves nothing (only a sign-in), so it is listed, and picked by hand, but never offered first.
    public static func best(_ list: [StandbyAccount], now: Date = Date()) -> StandbyAccount? {
        offerOrder(list, now: now).first { $0.seat != nil && !$0.knownFull(now: now) }
    }

    /// Another pick: the standby account seen in use most recently (with a seat), whatever its numbers; ties keep the
    /// list's order. nil when none was ever in use here.
    public static func mostRecent(_ list: [StandbyAccount]) -> StandbyAccount? {
        list.enumerated().filter { $0.element.seat != nil && $0.element.lastInUse != nil }
            .max { a, b in a.element.lastInUse! != b.element.lastInUse! ? a.element.lastInUse! < b.element.lastInUse! : a.offset > b.offset }?.element
    }
}

/// What happened to a profile's accounts, kept to be said once: an account that moved between two profiles by signing in
/// to another one's folder, or a tidied list.
public struct AccountNote: Codable, Equatable, Hashable {
    /// came / left: an account signed in to another profile's folder. standsBy: an account this profile remembered on
    /// standby was another profile's account in use until now, and stands by there (one account, one standby list).
    /// tidied: the standby list held more than one entry for an account (one per organisation), or another profile's
    /// account in use; it was tidied to one entry per account (StandbyTidy), said once.
    /// noCopy: the app's own record of its profiles was rewritten, but the copy it keeps first couldn't be kept.
    public enum Kind: String, Codable { case came, left, standsBy, tidied, noCopy }
    public var kind: Kind
    public var email: String              // the account (an app may show it masked)
    public var profile: String            // the other profile's name
    public var at: Date

    public init(kind: Kind, email: String, profile: String, at: Date) {
        self.kind = kind; self.email = email; self.profile = profile; self.at = at
    }
}

/// What StandbyTidy needs of a profile: its account in use, its name, its standby list and its note.
public protocol StandbyHolder {
    var seat: Seat? { get }
    var name: String { get }
    var standby: [StandbyAccount] { get set }
    var accountNote: AccountNote? { get set }
}

/// The standby lists as they must be: one entry per account (by its id; an entry known only by its address, by that),
/// never the profile's own account in use nor another profile's. An app applies it when it reads its profiles: an older
/// list (one entry per account and organisation) is tidied once, and its note says so once.
public enum StandbyTidy {
    /// `recordOrgs`: the organisation each account's own record names (asked only when two entries of one account meet).
    public static func apply<P: StandbyHolder>(_ list: [P], recordOrgs: () -> [String: String] = { [:] }, now: Date = Date())
        -> (accounts: [P], changed: Bool) {
        var out = list
        let inUse = out.map { $0.seat.map { AccountID.normal($0.account) } }
        var orgs: [String: String]?
        var changed = false
        for i in out.indices {
            let others = Set(inUse.enumerated().filter { $0.offset != i }.compactMap(\.element))
            var kept: [StandbyAccount] = []
            var at: [String: Int] = [:]
            for s in out[i].standby {
                let account = s.seat.map { AccountID.normal($0.account) }
                if let a = account, others.contains(a) || a == inUse[i] { continue }          // in use somewhere: not standby
                let key = account ?? "@" + s.email.lowercased()
                guard let k = at[key] else { at[key] = kept.count; kept.append(s); continue }
                // a second entry of the same account: one stays, with the newest last use and its record's organisation
                var one = kept[k]
                if orgs == nil { orgs = recordOrgs() }
                let want = account.flatMap { orgs?[$0] }
                let newer = (s.lastInUse ?? .distantPast) > (one.lastInUse ?? .distantPast)
                if s.seat?.organization?.lowercased() == want, one.seat?.organization?.lowercased() != want || newer { one.seat = s.seat }
                else if want == nil, newer { one.seat = s.seat }
                if newer { one.lastInUse = s.lastInUse; one.lastWeek = s.lastWeek; one.lastWeekResets = s.lastWeekResets; one.plan = s.plan ?? one.plan }
                if one.email.isEmpty { one.email = s.email }
                kept[k] = one
            }
            if kept != out[i].standby {
                out[i].standby = kept
                out[i].accountNote = AccountNote(kind: .tidied, email: "", profile: out[i].name, at: now)
                changed = true
            }
        }
        return (out, changed)
    }
}
