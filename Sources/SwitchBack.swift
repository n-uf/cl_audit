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

    /// Stay (on the alert or the card): the offer goes until the account comes back again.
    static func dismiss(_ key: String) {
        guard FileManager.default.fileExists(atPath: url(key).path) else { return }
        try? FileManager.default.removeItem(at: url(key))
        changed(key)
    }

    private static func changed(_ key: String) {
        DistributedNotificationCenter.default().postNotificationName(Store.statusChanged, object: key, userInfo: nil, deliverImmediately: true)
    }

    /// The agent, every beat: for each profile's standby accounts, a full limit is remembered (sbfull.<key>: "5h" or
    /// "wk") and, once it no longer holds (fresh numbers not full, or its reset time passed), the account is back: its
    /// file, and `send` (the alert) once. Full again: no longer back. A file whose account isn't on standby any more goes.
    static func check(_ list: [AccountEntry], defaults: UserDefaults, now: Date = Date(),
                      status: (AccountEntry, StandbyAccount) -> IconStatus? = { Store.status(for: $0, standby: $1) },
                      send: (AccountEntry, StandbyAccount, Back) -> Void) {
        var keys = Set<String>()
        for e in list {
            for s in e.standby {
                let key = AccountEntry.standbyStatusID(e.id, s.id)
                keys.insert(key)
                guard let st = status(e, s) else { continue }
                let mark = "sbfull.\(key)"
                if let full = AtLimit.blocker(fiveHour: st.fiveHour, fiveHourResets: st.fiveHourResets,
                                              weekly: st.weekly, weeklyResets: st.weeklyResets, now: now) {
                    if defaults.string(forKey: mark) != full.id { defaults.set(full.id, forKey: mark) }
                    dismiss(key)                                      // full again: not back
                } else if let was = defaults.string(forKey: mark) {
                    defaults.removeObject(forKey: mark)
                    let b = Back(at: now, week: was == "wk")
                    save(key, b)
                    send(e, s, b)
                }
            }
        }
        for f in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where f.hasSuffix(".json") {
            let key = String(f.dropLast(".json".count))
            if !keys.contains(key) { dismiss(key); defaults.removeObject(forKey: "sbfull.\(key)") }
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
