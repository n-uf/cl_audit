// ProfileCore · times in words, and the one level rule the colours follow.

import Foundation

/// Short, fixed times (24-hour, English weekday and month names), the same everywhere. `calendar`: the Mac's unless a
/// caller (a check) gives another.
public enum TimeWords {
    /// "11:38" today, "Thu 09:00" within 6 days either way, "11 Nov" further this year, "12 Jan 2027" another year.
    public static func when(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let cal = calendar
        let f = TimeWords.formatter(timeZone: cal.timeZone)
        let days = abs(cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day ?? 0)
        f.dateFormat = days == 0 ? "HH:mm"
            : (1...6).contains(days) ? "EEE HH:mm"
            : cal.component(.year, from: d) == cal.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    /// When a limit is back: "back at 15:28" today, else "back Thu 09:00", "back 11 Nov", "back 12 Jan 2027".
    public static func back(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(d, inSameDayAs: now) ? "back at \(when(d, now: now, calendar: calendar))" : "back \(when(d, now: now, calendar: calendar))"
    }

    /// The formatter for these words: English names and the Gregorian calendar whatever the Mac's calendar is (a
    /// Buddhist, Japanese or Hijri system calendar would otherwise write "12 Jan 2570"); only the time zone comes from
    /// the caller's calendar.
    public static func formatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = timeZone
        return f
    }

    /// Whole minutes left, rounded up (30 s left is "1m"; the reset itself is 0).
    public static func minutesLeft(_ d: Date, now: Date = Date()) -> Int { max(0, Int((d.timeIntervalSince(now) / 60).rounded(.up))) }

    /// The countdown without "in": "19m", "1h 42m", "19h 14m", "2d 19h", "16 days". Its form changes as the reset
    /// gets closer.
    public static func countdown(_ d: Date, now: Date = Date()) -> String {
        let m = minutesLeft(d, now: now)
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
        if m < 8 * 24 * 60 { return "\(m / 1440)d \(m % 1440 / 60)h" }
        return "\(m / 1440) days"
    }
}

/// How full a limit is, the one rule every colour follows: none (no number, or old numbers), green under 50%, amber
/// 50–79%, red 80–94%, crimson from 95% as the person reads it (94.5 shows as 95, like AtLimit.isFull's 100). Each place
/// maps a level to its own colour.
public enum Level: Equatable {
    case none, green, amber, red, crimson

    public static func of(_ p: Double?, stale: Bool = false) -> Level {
        guard let p, !stale else { return .none }
        return p.rounded() >= 95 ? .crimson : p >= 80 ? .red : p >= 50 ? .amber : .green
    }
}
