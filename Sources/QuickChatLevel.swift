// QuickChatLevel: the quick chat's account line and its offer when a limit is full (QuickChat.swift).
//
// The numbers come from the agent's own reading of the profile (Reader.swift) as ProfileCore's Headline lets the profile's
// headline show them (Store.status(for:): never the split's, a stale reading's, or an old full limit), and after each
// answer from what Claude Code itself reports (its rate_limit_event), which is newer, only while the Headline says the
// record's numbers are the profile's (QuickChatTarget.liveCounts, `kept`). The colours are ProfileCore's one Level
// everywhere in cl_audit (Painter.color: green, amber from 50%, red from 80%, crimson from 95%). A full limit is AtLimit's:
// the one that holds the profile back. While one is, the bar says so before you send and offers the one offer every place
// makes (AccountEntry.fullOffer: not known to be full, the least used by its last week, never the account in use) through
// the switch (the Switch page); what you typed waits and goes once it's done.

import AppKit
import ProfileCore
import SwiftUI

struct QuickChatLevel: Equatable {
    var week: Double?
    var weekResets: Date?
    var fiveHour: Double?
    var fiveHourResets: Date?
    var noFiveHour = false
    /// When Claude Code last said the account is refusing (its rate_limit_event "rejected"), and until when.
    var refusedUntil: Date?

    /// A limit whose reset has passed comes without its percent (Usage.current).
    init(_ u: Usage?, now: Date = Date()) {
        let u = u?.current(now: now)
        week = u?.weekly; weekResets = u?.weeklyResets
        fiveHour = u?.fiveHour; fiveHourResets = u?.fiveHourResets
        noFiveHour = u?.noFiveHour ?? false
    }

    /// What Claude Code said after an answer: "seven_day" or "five_hour", the share used (0…1), refusing or not.
    /// `counts` false (QuickChatTarget.liveCounts): only whether it refuses and until when (the chat's own sign-in's,
    /// with its real reset), never its percents.
    mutating func apply(type: String?, used: Double?, status: String?, resets: Date?, counts: Bool = true) {
        if counts {
            let pct = used.map { min(100, max(0, $0 * 100)) }
            switch type {
            case "seven_day"?: if let pct { week = pct }; if let resets { weekResets = resets }
            case "five_hour"?: if let pct { fiveHour = pct }; if let resets { fiveHourResets = resets }
            default: break
            }
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
            return FullLimit(kind: five ? .fiveHour : .week, resets: until)
        }
        return nil
    }

    /// The line's number: the week, or a full 5-hour limit in its place. A week whose reset has passed has none.
    func shown(_ now: Date = Date()) -> (name: String, percent: Double?, resets: Date?) {
        if let f = full(now) { return (f.id == "5h" ? "5-hour" : "week", 100, f.resets) }
        let w = Freshness.current(week, resets: weekResets, now: now)
        return ("week", w.percent, w.resets)
    }

    /// Without the limits whose reset has passed: the panel stays open across a reset, its old percent never shown.
    func current(_ now: Date = Date()) -> QuickChatLevel {
        var l = self
        (l.week, l.weekResets) = Freshness.current(l.week, resets: l.weekResets, now: now)
        (l.fiveHour, l.fiveHourResets) = Freshness.current(l.fiveHour, resets: l.fiveHourResets, now: now)
        return l
    }

    /// The account line after a new look at the record: `record` is the agent's reading as the Headline lets it show
    /// (Store.status(for:)); `shown` is what the line has now, with what Claude Code itself said after an answer, which is
    /// newer. Those are kept where fuller, for the same window (resets within an hour), only for the same profile on the
    /// same account (`sameAccount`) and only while they count as the profile's (`counts`, QuickChatTarget.liveCounts).
    /// Otherwise the record's level alone: numbers the record doesn't show for the profile never come back from the chat.
    /// A refusal Claude Code met (refusedUntil) is the chat's own sign-in's: it stays for the same account while
    /// `refusals` (not the split), whether or not the numbers count yet. A percent from before a limit's reset is never
    /// kept (current). Live percents dropped while they didn't count stay dropped until Claude Code says them again
    /// (the next answer).
    static func kept(record: QuickChatLevel?, shown: QuickChatLevel?, sameAccount: Bool, counts: Bool, refusals: Bool,
                     now: Date = Date()) -> QuickChatLevel? {
        guard sameAccount, counts || refusals, let mine = shown?.current(now), var theirs = record else { return record }
        func same(_ a: Date?, _ b: Date?) -> Bool {
            guard let a, let b else { return true }
            return abs(a.timeIntervalSince(b)) < 3600
        }
        if counts {
            if let w = mine.week, w > (theirs.week ?? -1), same(mine.weekResets, theirs.weekResets) { theirs.week = w }
            if let f = mine.fiveHour, f > (theirs.fiveHour ?? -1), same(mine.fiveHourResets, theirs.fiveHourResets) { theirs.fiveHour = f }
        }
        if let r = mine.refusedUntil, r > now { theirs.refusedUntil = r }
        return theirs
    }

    static func color(_ p: Double?) -> Color { Color(nsColor: Painter.color(p, stale: false)) }
}

/// The standby account a full limit offers (AccountEntry.fullOffer, the alert's too: not known to be full, the least
/// used first, never the account in use), for the Switch page. `words`: when it was last in use, or empty.
struct QuickChatSwitchOffer: Equatable {
    var key: String
    var short: String
    var words: String

    static func best(_ e: AccountEntry, now: Date = Date()) -> QuickChatSwitchOffer? {
        e.fullOffer(now: now).map { o in
            QuickChatSwitchOffer(key: o.key, short: o.short, words: o.standby.lastInUse.map { AccountBook.ago($0, now: now) } ?? "")
        }
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
