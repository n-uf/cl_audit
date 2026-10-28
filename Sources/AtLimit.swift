// When a limit is full: which limit holds the profile back and until when, in the words and times every place uses
// (the dashboard card, the details panels, the launcher, the Dock menu, the Dock icon and the alerts).
//
// Full means 100% (Anthropic's usage reply has no separate "refusing" flag; at 100% it refuses). A full limit whose
// reset time has passed no longer counts: the agent reads that profile again at the reset (Reader.swift).

import AppKit
import SwiftUI

/// Short, fixed times (24-hour, English weekday and month names), the same everywhere.
enum TimeWords {
    /// "11:38" today, "Thu 09:00" within 6 days either way, "11 Nov" further this year, "12 Jan 2027" another year.
    static func when(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0)
        f.dateFormat = days == 0 ? "HH:mm"
            : (1...6).contains(days) ? "EEE HH:mm"
            : cal.component(.year, from: d) == cal.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    /// When a limit is back: "back at 15:28" today, else "back Thu 09:00", "back 11 Nov", "back 12 Jan 2027".
    static func back(_ d: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(d, inSameDayAs: now) ? "back at \(when(d, now: now))" : "back \(when(d, now: now))"
    }

    /// Whole minutes left, rounded up (30 s left is "1m"; the reset itself is 0).
    static func minutesLeft(_ d: Date, now: Date = Date()) -> Int { max(0, Int((d.timeIntervalSince(now) / 60).rounded(.up))) }

    /// The countdown without "in": "19m", "1h 42m", "19h 14m", "2d 19h", "16 days". Its form changes as the reset
    /// gets closer.
    static func countdown(_ d: Date, now: Date = Date()) -> String {
        let m = minutesLeft(d, now: now)
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
        if m < 8 * 24 * 60 { return "\(m / 1440)d \(m % 1440 / 60)h" }
        return "\(m / 1440) days"
    }

    /// The countdown on the Dock icon, where one short value fits: ("19", "m"), ("1", "h42"), ("19", "h"), ("Thu", ""),
    /// ("16", "d"), ("Jan", "") — the first part large, the second small after it.
    static func tile(_ d: Date, now: Date = Date()) -> (String, String) {
        let m = minutesLeft(d, now: now)
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if m < 60 { return ("\(m)", "m") }
        if m < 10 * 60 { return ("\(m / 60)", String(format: "h%02d", m % 60)) }
        if m < 24 * 60 { return ("\(m / 60)", "h") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: d)).day ?? 0
        if days <= 6 { f.dateFormat = "EEE"; return (f.string(from: d), "") }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return ("\(m / 1440)", "d") }
        f.dateFormat = "MMM"; return (f.string(from: d), "")
    }
}

/// The full limit that holds a profile back: of the full ones, the one that resets last (an unknown reset counts as
/// last). `others` names any other full limit ("5-hour too").
struct FullLimit: Equatable {
    let id: String              // "5h" or "wk"
    let name: String            // "5-hour" or "Week"
    let resets: Date?
    let other: String?          // the other full limit's name, when both are full

    /// "5-hour full", or "Week full · 5-hour too".
    var title: String { "\(name) full" + (other.map { " · \($0) too" } ?? "") }
    /// The Dock icon's line under the time: "5H FULL", "WK FULL".
    var tileFooter: String { id == "5h" ? "5H FULL" : "WK FULL" }
    /// The alert's and Dock menu's name for it: "5-hour limit", "weekly limit".
    var limitName: String { id == "5h" ? "5-hour limit" : "weekly limit" }

    /// "in 1h 42m", or nil when the reset time isn't known.
    func countdown(_ now: Date = Date()) -> String? { resets.map { "in " + TimeWords.countdown($0, now: now) } }
    /// "back at 15:28", or "reset time unknown".
    func back(_ now: Date = Date()) -> String { resets.map { TimeWords.back($0, now: now) } ?? "reset time unknown" }
    /// Both times in one line: "back at 15:28, in 1h 42m", or "reset time unknown".
    func both(_ now: Date = Date()) -> String { resets.map { "\(TimeWords.back($0, now: now)), in \(TimeWords.countdown($0, now: now))" } ?? "reset time unknown" }
}

enum AtLimit {
    /// 100% as the cards show it (rounded).
    static func isFull(_ p: Double?) -> Bool { p.map { $0.rounded() >= 100 } ?? false }

    /// Full and not yet reset.
    static func holding(_ p: Double?, _ resets: Date?, now: Date = Date()) -> Bool {
        isFull(p) && (resets.map { $0 > now } ?? true)
    }

    /// The full limit that holds the profile back, or nil when nothing is full.
    static func blocker(fiveHour: Double?, fiveHourResets: Date?, weekly: Double?, weeklyResets: Date?,
                        now: Date = Date()) -> FullLimit? {
        let five = holding(fiveHour, fiveHourResets, now: now), week = holding(weekly, weeklyResets, now: now)
        switch (five, week) {
        case (false, false): return nil
        case (true, false): return FullLimit(id: "5h", name: "5-hour", resets: fiveHourResets, other: nil)
        case (false, true): return FullLimit(id: "wk", name: "Week", resets: weeklyResets, other: nil)
        case (true, true):
            // the one that resets last; unknown counts as last, and the week wins a tie
            let fiveLater = (fiveHourResets ?? .distantFuture) > (weeklyResets ?? .distantFuture)
            return fiveLater ? FullLimit(id: "5h", name: "5-hour", resets: fiveHourResets, other: "Week")
                             : FullLimit(id: "wk", name: "Week", resets: weeklyResets, other: "5-hour")
        }
    }

    static func blocker(_ limits: [Limit], now: Date = Date()) -> FullLimit? {
        let five = limits.first { $0.id == "5h" }, week = limits.first { $0.id == "wk" }
        return blocker(fiveHour: five?.p, fiveHourResets: five?.resets, weekly: week?.p, weeklyResets: week?.resets, now: now)
    }

    /// The Dock icon's countdown face for a full limit (D1), or nil when nothing is full.
    static func tileCountdown(fiveHour: Double?, fiveHourResets: Date?, weekly: Double?, weeklyResets: Date?,
                              now: Date = Date()) -> TileCountdown? {
        guard let b = blocker(fiveHour: fiveHour, fiveHourResets: fiveHourResets, weekly: weekly, weeklyResets: weeklyResets, now: now)
        else { return nil }
        let (big, small) = b.resets.map { TimeWords.tile($0, now: now) } ?? ("—", "")
        return TileCountdown(big: big, small: small, footer: b.tileFooter)
    }
}

/// What the Dock icon shows while a limit is full: the time large ("1" + "h42"), which limit under it.
struct TileCountdown: Equatable {
    var big: String
    var small: String
    var footer: String
}

// MARK: - The card's layout while a limit is full

/// The limits on the left (name, reset line, bar, percentage) and, on the right, one box for the full limit that holds
/// the profile back: its title, how long until it's back (large) and when. In a narrow card the columns are narrower.
struct FullLimitsView: View {
    let limits: [Limit]
    let design: PanelDesign
    let full: FullLimit
    var now = Date()
    @Environment(\.face) private var face
    @Environment(\.colorScheme) private var scheme

    private struct Metrics { var label: CGFloat; var pct: CGFloat; var gap: CGFloat; var box: CGFloat; var big: CGFloat; var bar: CGFloat }
    private static let wide = Metrics(label: 96, pct: 40, gap: 10, box: 172, big: 21, bar: 60)
    private static let narrow = Metrics(label: 68, pct: 34, gap: 6, box: 128, big: 16, bar: 40)

    var body: some View {
        // the first that fits: the sketch's sizes, or the narrow ones (a card at its narrowest)
        ViewThatFits(in: .horizontal) {
            layout(Self.wide)
            layout(Self.narrow)
        }
    }

    private func layout(_ m: Metrics) -> some View {
        HStack(alignment: .center, spacing: m.gap + 2) {
            VStack(spacing: 12) { ForEach(limits) { row($0, m) } }
                .frame(maxWidth: .infinity)
            box(m)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // In the cl_audit window the face sets the colours. The panels by the Dock icon have no face (system colours on the
    // system's light or dark material); their box keeps the dark display glass.
    private var plateLight: Bool { face.active ? face.light : scheme == .light }
    private var glassLight: Bool { face.active && face.light }
    private var text: Color { face.active ? face.text : .primary }
    private var muted: Color { face.active ? face.muted : .secondary }
    private var rowRed: Color { plateLight ? .hex(0xb42318) : .hex(0xfca5a5) }
    private var red: Color { glassLight ? .hex(0xb42318) : .hex(0xff7b6e) }
    private var redSoft: Color { glassLight ? .hex(0xb42318) : .hex(0xfca5a5) }
    private var glassSoft: Color { face.active ? face.soft : .white(0.82) }
    private var glassMuted: Color { face.active ? face.muted : .white(0.55) }

    /// Under the name: "full" for the box's limit, "full · resets 15:28" for another full one, else "in 3 days".
    private func line(_ l: Limit) -> (String, Bool) {
        if AtLimit.holding(l.p, l.resets, now: now) {
            return l.id == full.id ? ("full", true) : ("full · resets " + (l.resets.map { TimeWords.when($0, now: now) } ?? "?"), true)
        }
        return (l.resets.map { "in " + DetailsFormat.short($0) } ?? " ", false)
    }

    private func row(_ l: Limit, _ m: Metrics) -> some View {
        let (words, hot) = line(l)
        return HStack(spacing: m.gap) {
            VStack(alignment: .leading, spacing: 3) {
                Text(l.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(text)
                Text(words).font(.system(size: 11.5)).foregroundStyle(hot ? rowRed : muted).lineLimit(1).fixedSize()
            }
            .frame(minWidth: m.label, alignment: .leading)
            Group {
                if design == .segments { SegmentBar(p: l.p, height: 7) } else { LevelBar(p: l.p, height: 6) }
            }
            .frame(minWidth: m.bar, idealWidth: m.bar, maxWidth: .infinity)
            Text(Painter.pct(l.p)).font(.system(size: 12.5, weight: .bold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(l.p == nil ? muted : face.levelColor(l.p))
                .lineLimit(1).fixedSize()
                .frame(width: m.pct, alignment: .trailing)
        }
    }

    private func boxTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 8.5, weight: .semibold)).tracking(1.2).textCase(.uppercase)
            .foregroundStyle(redSoft).lineLimit(1).fixedSize()
    }

    private func box(_ m: Metrics) -> some View {
        VStack(spacing: 5) {
            // on one line, or, in a narrow box, "Week full" over "5-hour too"
            ViewThatFits(in: .horizontal) {
                boxTitle(full.title)
                VStack(spacing: 2) {
                    boxTitle("\(full.name) full")
                    if let o = full.other { boxTitle("\(o) too") }
                }
            }
            Group {
                if let r = full.resets {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text("in").font(.system(size: m.big * 0.57, weight: .semibold, design: .monospaced)).opacity(0.8)
                        Text(TimeWords.countdown(r, now: now)).font(.system(size: m.big, weight: .semibold, design: .monospaced))
                    }
                } else {
                    Text("full").font(.system(size: m.big, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(red).lineLimit(1).fixedSize()
            .shadow(color: face.displayGlow && !glassLight ? red.opacity(0.35) : .clear, radius: 3.5)
            Text(full.back(now)).font(.system(size: m.big * 0.6, weight: .semibold, design: .monospaced))
                .foregroundStyle(full.resets == nil ? glassMuted : glassSoft).lineLimit(1).minimumScaleFactor(0.85)
        }
        .padding(.vertical, 9).padding(.horizontal, 8)
        .frame(width: m.box)
        .frame(maxHeight: .infinity)
        .background(DisplayGlass(radius: 8))
    }
}

/// The card's limits: today's design, or, while a limit is full, the rows and the box. Redrawn every 15 s, so the
/// countdown keeps time and the card goes back to today's layout at the reset.
struct CardLimits: View {
    let limits: [Limit]
    let design: PanelDesign
    var large = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            if let full = AtLimit.blocker(limits, now: ctx.date) {
                FullLimitsView(limits: limits, design: design, full: full, now: ctx.date)
            } else {
                LimitsView(limits: limits, design: design, large: large)
            }
        }
    }
}
