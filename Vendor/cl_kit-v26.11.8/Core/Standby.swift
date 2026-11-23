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

    /// The entry as the one owner rule compares it (AccountIdentity.sameAccount): its seat, with the entry's address when
    /// the seat has none; else its address only.
    public var identity: AccountIdentity {
        var i = seat.map { AccountIdentity($0) } ?? AccountIdentity(account: nil, email: nil, organization: nil, source: .guessed)
        if (i.email ?? "").isEmpty { i.email = email }
        return i
    }

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
    /// list, in an alert): the first in `offerOrder` that has a seat and isn't known to be full, or nil.
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
    /// tidied: the standby list held one seat twice, or the profile's own account in use; it was tidied to one entry per
    /// seat (StandbyTidy), said once.
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

/// The standby lists as they must be: within one profile, one entry per seat (account id and organisation; an entry
/// known only by its address, by that), never the profile's own account in use. A seat may stand by in several profiles,
/// and be one profile's account in use while it stands by in another: only the same seat twice inside one profile is
/// tidied. A personal plan and a Team seat on one account id are two seats. An entry whose organisation isn't known (nil
/// or "") is the seat not known yet: it joins the one seat the account has in that profile (or the one its record names,
/// when it has several there); with none to join it stays apart. An app applies it when it reads its profiles; a list
/// that changes is said once in its note.
public enum StandbyTidy {
    /// The one entry a seat has on a standby list: its account id and organisation in normal form ("<id>|<organisation>",
    /// "<id>|" when the organisation isn't known), else "@" and its address (any case). Two entries with one key are one
    /// seat here.
    public static func key(_ s: StandbyAccount) -> String {
        guard let seat = s.seat else { return "@" + s.email.lowercased() }
        return AccountID.normal(seat.account) + "|" + (org(seat) ?? "")
    }

    /// A seat's organisation in normal form, nil when it isn't known (nil or "").
    static func org(_ s: Seat?) -> String? { s?.organization.flatMap { $0.isEmpty ? nil : AccountID.normal($0) } }

    /// `recordOrgs`: the organisation each account's own record names (asked only when an entry whose organisation isn't
    /// known meets two or more seats of its account in one profile).
    public static func apply<P: StandbyHolder>(_ list: [P], recordOrgs: () -> [String: String] = { [:] }, now: Date = Date())
        -> (accounts: [P], changed: Bool) {
        var out = list
        var orgs: [String: String]?
        var changed = false
        withoutActuallyEscaping(recordOrgs) { recordOrgs in
            // asked once for all the profiles, and only when needed
            let asked: () -> [String: String] = {
                if orgs == nil { orgs = recordOrgs() }
                return orgs ?? [:]
            }
            for i in out.indices {
                let kept = tidied(out[i].standby, inUse: out[i].seat, recordOrgs: asked)
                if kept != out[i].standby {
                    out[i].standby = kept
                    out[i].accountNote = AccountNote(kind: .tidied, email: "", profile: out[i].name, at: now)
                    changed = true
                }
            }
        }
        return (out, changed)
    }

    /// `list` with `incoming` entries joined to it, as the tidy keeps one profile's list: each seat once (the list's own
    /// entries first, in their order), never `inUse` (the profile's account in use). Every caller that adds standby
    /// entries to a profile (a profile's accounts moving to another) uses it, so the next tidy changes nothing.
    public static func merge(_ incoming: [StandbyAccount], into list: [StandbyAccount], inUse: Seat?,
                             recordOrgs: () -> [String: String] = { [:] }) -> [StandbyAccount] {
        tidied(list + incoming, inUse: inUse, recordOrgs: recordOrgs)
    }

    /// One profile's standby list tidied: one entry per seat, never the account in use.
    static func tidied(_ standby: [StandbyAccount], inUse own: Seat?, recordOrgs: () -> [String: String]) -> [StandbyAccount] {
        var orgs: [String: String]?
        let ownAccount = own.map { AccountID.normal($0.account) }, ownOrg = org(own)
        // the seats each account has in this profile, by their known organisations (its standby entries' and its own)
        var seats: [String: Set<String>] = [:]
        for s in standby.map(\.seat) + [own] {
            if let s, let o = org(s) { seats[AccountID.normal(s.account), default: []].insert(o) }
        }
        // a seat's key in this profile: an organisation not known joins the account's one seat here, or its record's
        func key(_ seat: Seat) -> String {
            let a = AccountID.normal(seat.account)
            if let o = org(seat) { return a + "|" + o }
            let known = seats[a] ?? []
            if known.count == 1 { return a + "|" + known.first! }
            if known.count > 1 {
                if orgs == nil { orgs = recordOrgs() }
                if let r = orgs?[a].flatMap({ $0.isEmpty ? nil : AccountID.normal($0) }), known.contains(r) { return a + "|" + r }
            }
            return a + "|"
        }
        var kept: [StandbyAccount] = []
        var at: [String: Int] = [:]
        for s in standby {
            // the profile's own account in use: its seat; with its organisation not known, only the entries of its id whose
            // organisation isn't known either (it never takes a known seat of its id for its own)
            if let seat = s.seat, let a = ownAccount, AccountID.normal(seat.account) == a {
                if let o = ownOrg { if key(seat) == a + "|" + o { continue } }
                else if org(seat) == nil { continue }
            }
            let k = s.seat.map(key) ?? "@" + s.email.lowercased()
            guard let n = at[k] else { at[k] = kept.count; kept.append(s); continue }
            kept[n] = joined(kept[n], s)
        }
        return kept
    }

    /// Two entries of one seat as one. Alike (both with a known organisation, or both without): the newer one's seat,
    /// last use, week and plan. One not known joining a known one: the known entry's seat, plan and week stay (they are
    /// that seat's own), and only a newer last use is taken.
    static func joined(_ one: StandbyAccount, _ s: StandbyAccount) -> StandbyAccount {
        var out = one
        let newer = (s.lastInUse ?? .distantPast) > (one.lastInUse ?? .distantPast)
        switch (org(one.seat) != nil, org(s.seat) != nil) {
        case (true, false):
            if newer { out.lastInUse = s.lastInUse }
        case (false, true):
            // the known one's own values, in the place (and under the id) of the entry it joins
            out = s
            out.id = one.id
            if !newer { out.lastInUse = one.lastInUse ?? s.lastInUse }
            if out.addedAt == nil { out.addedAt = one.addedAt }
        default:
            if newer {
                out.seat = s.seat; out.lastInUse = s.lastInUse; out.lastWeek = s.lastWeek; out.lastWeekResets = s.lastWeekResets
                out.plan = s.plan ?? one.plan
            }
        }
        if out.email.isEmpty { out.email = one.email.isEmpty ? s.email : one.email }
        return out
    }
}
