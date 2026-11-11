// QuickChatLevel: the quick chat's account line and its offer when a limit is full (QuickChat.swift).
//
// The numbers come from the agent's own reading of the profile (Reader.swift), and after each answer from what Claude
// Code itself reports (its rate_limit_event), which is newer. The colours are the levels' everywhere in cl_audit
// (Painter.color: green, amber from 50%, red from 80%, crimson from 95%). A full limit is AtLimit's: the one that holds
// the profile back. While one is, the bar says so before you send and offers the profile's standby account with the most
// room through the existing switch (SwitchMenu.best → the Switch page); what you typed waits and goes once it's done.

import AppKit
import SwiftUI

struct QuickChatLevel: Equatable {
    var week: Double?
    var weekResets: Date?
    var fiveHour: Double?
    var fiveHourResets: Date?
    var noFiveHour = false
    /// When Claude Code last said the account is refusing (its rate_limit_event "rejected"), and until when.
    var refusedUntil: Date?

    init(_ u: Usage?) {
        week = u?.weekly; weekResets = u?.weeklyResets
        fiveHour = u?.fiveHour; fiveHourResets = u?.fiveHourResets
        noFiveHour = u?.noFiveHour ?? false
    }

    /// What Claude Code said after an answer: "seven_day" or "five_hour", the share used (0…1), refusing or not.
    mutating func apply(type: String?, used: Double?, status: String?, resets: Date?) {
        let pct = used.map { min(100, max(0, $0 * 100)) }
        switch type {
        case "seven_day"?: if let pct { week = pct }; if let resets { weekResets = resets }
        case "five_hour"?: if let pct { fiveHour = pct }; if let resets { fiveHourResets = resets }
        default: break
        }
        if status == "rejected" { refusedUntil = resets ?? Date().addingTimeInterval(3600) }
        else if status == "allowed" { refusedUntil = nil }
    }

    /// The full limit that holds the profile back now, if any.
    func full(_ now: Date = Date()) -> FullLimit? {
        if let f = AtLimit.blocker(fiveHour: noFiveHour ? nil : fiveHour, fiveHourResets: fiveHourResets, weekly: week,
                                   weeklyResets: weekResets, now: now) { return f }
        // Claude Code refused though the numbers we have aren't at 100% yet
        if let until = refusedUntil, until > now {
            let five = !noFiveHour && (fiveHour ?? 0) >= (week ?? 0)
            return FullLimit(id: five ? "5h" : "wk", name: five ? "5-hour" : "Week", resets: until, other: nil)
        }
        return nil
    }

    /// The line's number: the week, or a full 5-hour limit in its place.
    func shown(_ now: Date = Date()) -> (name: String, percent: Double?, resets: Date?) {
        if let f = full(now) { return (f.id == "5h" ? "5-hour" : "week", 100, f.resets) }
        return ("week", week, weekResets)
    }

    static func color(_ p: Double?) -> Color { Color(nsColor: Painter.color(p, stale: false)) }
}

/// The standby account a full limit offers: the one with the most room (SwitchMenu.best), for the Switch page.
struct QuickChatSwitchOffer: Equatable {
    var key: String
    var short: String
    var words: String

    static func best(_ e: AccountEntry) -> QuickChatSwitchOffer? {
        let listed = e.listed(by: AccountView.of(Store.status(for: e)))     // never the account in use on standby too
        let lines = SwitchMenu.lines(listed)
        return SwitchMenu.best(lines, backs: listed.backOffers()).map { QuickChatSwitchOffer(key: $0.key, short: $0.short, words: $0.words) }
    }
}

/// The level in the account line and the bar: a thin meter in the level's colour, then the number.
struct QCLevelView: View {
    let level: QuickChatLevel
    var long = true

    var body: some View {
        let s = level.shown()
        let full = level.full() != nil
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(QCColor.text.opacity(0.13))
                Capsule().fill(QuickChatLevel.color(s.percent)).frame(width: 38 * CGFloat(min(100, s.percent ?? 0)) / 100)
            }
            .frame(width: 38, height: 4)
            Text(full ? "full" : Painter.pct(s.percent))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(s.percent == nil ? QCColor.muted : QuickChatLevel.color(s.percent))
            if long {
                Text(longWords(s, full: full)).font(.system(size: 12)).foregroundColor(QCColor.muted).lineLimit(1)
            }
        }
        .help(full ? "\(s.name.capitalized) full" : "\(s.name.capitalized) used so far")
    }

    private func longWords(_ s: (name: String, percent: Double?, resets: Date?), full: Bool) -> String {
        guard let r = s.resets else { return s.name }
        return full ? "\(s.name) · \(TimeWords.back(r))" : "\(s.name) · resets \(TimeWords.when(r))"
    }
}
