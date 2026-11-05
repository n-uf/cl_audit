// SwitchBack: a standby account that is back. After a switch, the account the profile left (its week full, say) waits
// on standby; when its full limit resets, cl_audit says so once ("Claude Main: the other account is back · Its week
// starts again", with Switch back and Stay) and offers Switch back on the dashboard card and in the Dock and menu bar
// menus. Switch back is the same switch the other way (SwitchEngine.swift): every session in the window's sidebar goes,
// those started on the second account too.
//
// The agent watches it (BackWatch.check, every beat) from the account's saved numbers only (Store.status): fresh
// numbers that aren't full any more, or a full limit whose reset time has passed. That holds also for an account with
// no folder of its own, whose numbers nothing reads after a switch (Claude Code signs in again each time). "Back" is a
// file per account (switches/back/<profile>~<account>.json): the card and the menus read it; Stay takes it away, and so
// does the account filling up again, being switched to, or leaving the profile.

import Foundation

enum BackWatch {
    /// One account back: since when, and which limit came back (the week, else the 5-hour one).
    struct Back: Codable, Equatable {
        var at: Date
        var week: Bool
    }

    static var folder: URL { SwitchEngine.root.appendingPathComponent("back") }
    static func url(_ key: String) -> URL { folder.appendingPathComponent("\(key).json") }

    static func load(_ key: String) -> Back? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(key))).flatMap { try? dec.decode(Back.self, from: $0) }
    }

    static func save(_ key: String, _ b: Back) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let d = try? enc.encode(b) { try? d.write(to: url(key), options: .atomic) }
        changed(key)
    }

    /// Stay (on the alert or the card), or no longer back: the offer goes until the account comes back again. With the
    /// agent's defaults (the agent), its "was full" mark goes too.
    static func dismiss(_ key: String, defaults: UserDefaults? = nil) {
        defaults?.removeObject(forKey: markKey(key))
        guard FileManager.default.fileExists(atPath: url(key).path) else { return }
        try? FileManager.default.removeItem(at: url(key))
        changed(key)
    }

    /// The agent's mark of a standby account read as full: which limit ("5h"/"wk") and when it resets ("wk|1731000000",
    /// "wk|?" when unknown; an older "wk" alone reads as unknown).
    static func markKey(_ key: String) -> String { "sbfull.\(key)" }
    struct Mark: Equatable {
        var limit: String
        var resets: Date?
        var text: String { "\(limit)|\(resets.map { String(Int($0.timeIntervalSince1970.rounded())) } ?? "?")" }
        init(limit: String, resets: Date?) { self.limit = limit; self.resets = resets }
        init(_ text: String) {
            let p = text.split(separator: "|", maxSplits: 1).map(String.init)
            limit = p.first ?? "wk"
            resets = p.count > 1 ? Double(p[1]).map { Date(timeIntervalSince1970: $0) } : nil
        }
    }

    private static func changed(_ key: String) {
        DistributedNotificationCenter.default().postNotificationName(Store.statusChanged, object: key, userInfo: nil, deliverImmediately: true)
    }

    /// The agent, every beat: for each profile's standby accounts, a full limit is remembered (Mark: which, and when it
    /// resets) and the account is back, once, with its file and `send` (the alert):
    /// - with a folder of its own (something reads it): on numbers read after that reset, current, without a problem,
    ///   and not full; numbers older than the reset (a late reset) wait for one fresh read;
    /// - without one (nothing reads it after a switch): once the reset time has passed (the only thing known).
    /// No numbers (none yet, or read for another account) never count as "not full". Full again: no longer back. Files
    /// and marks of accounts that aren't on standby any more go.
    static func check(_ list: [AccountEntry], defaults: UserDefaults, now: Date = Date(),
                      status: (AccountEntry, StandbyAccount) -> IconStatus? = { Store.status(for: $0, standby: $1) },
                      send: (AccountEntry, StandbyAccount, Back) -> Void) {
        var keys = Set<String>()
        for e in list {
            let maxAge = max(15 * 60, 3 * Double(max(e.pollMinutes, 1)) * 60)
            for s in e.standby {
                let key = AccountEntry.standbyStatusID(e.id, s.id)
                keys.insert(key)
                guard let st = status(e, s) else { continue }
                let hasNumbers = st.fiveHour != nil || st.weekly != nil
                if hasNumbers, let full = AtLimit.blocker(fiveHour: st.fiveHour, fiveHourResets: st.fiveHourResets,
                                                          weekly: st.weekly, weeklyResets: st.weeklyResets, now: now) {
                    let m = Mark(limit: full.id, resets: full.resets).text
                    if defaults.string(forKey: markKey(key)) != m { defaults.set(m, forKey: markKey(key)) }
                    dismiss(key)                                      // full again: not back (its mark stays)
                    continue
                }
                guard let m = defaults.string(forKey: markKey(key)).map(Mark.init) else { continue }
                let back: Bool
                if !(s.configDir ?? "").isEmpty {
                    let read = st.updatedAt.map { now.timeIntervalSince($0) <= maxAge && $0 >= (m.resets ?? .distantPast) } ?? false
                    back = hasNumbers && read && st.state == "ok" && st.problem == nil
                } else {
                    back = m.resets.map { now >= $0 } ?? false
                }
                guard back else { continue }
                defaults.removeObject(forKey: markKey(key))
                let b = Back(at: now, week: m.limit == "wk")
                save(key, b)
                send(e, s, b)
            }
        }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".json") {
            let key = String(f.dropLast(".json".count))
            if !keys.contains(key) { dismiss(key, defaults: defaults) }
        }
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("sbfull.") && !keys.contains(String(k.dropFirst("sbfull.".count))) {
            defaults.removeObject(forKey: k)
        }
    }

    /// The alert's words. An alert reaches the lock screen, so it never names the account by its address or any part
    /// of it: "Claude Main: the other account is back" / "Its week starts again."
    static func words(_ e: AccountEntry, _ b: Back) -> (title: String, body: String) {
        let which = e.standby.count > 1 ? "another account" : "the other account"
        return ("Claude \(Account(e).name): \(which) is back", b.week ? "Its week starts again." : "Its 5-hour limit starts again.")
    }
}

/// A standby account that is back, offered with Switch back.
struct BackOffer: Identifiable, Equatable {
    let profile: String
    let standby: StandbyAccount
    let back: BackWatch.Back

    var key: String { AccountEntry.standbyStatusID(profile, standby.id) }
    var id: String { key }
    var short: String { AccountNames.short(standby.email) }
    /// "Switch back to ultra-1…"
    var title: String { "Switch back to \(short)…" }
    /// "ultra-1 is back: its week starts again"
    var words: String { "\(short) is back: its \(back.week ? "week" : "5-hour limit") starts again" }
}

extension AccountEntry {
    /// Its standby accounts that are back (BackWatch), in the profile's order.
    func backOffers() -> [BackOffer] {
        standby.compactMap { s in BackWatch.load(Self.standbyStatusID(id, s.id)).map { BackOffer(profile: id, standby: s, back: $0) } }
    }

    /// The Switch page goes "back to" the account the profile was on before its last switch.
    func isBack(to s: StandbyAccount) -> Bool { seat?.was.map { $0.lowercased() == s.email.lowercased() } ?? false }
}
