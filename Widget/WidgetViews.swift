// What the cl_audit widget draws, shared by the widget (Widget.swift, a sandboxed extension) and cl_audit itself (the
// Widget card in Settings ▸ General shows the real widget as its preview). Self-contained: no WidgetKit here and nothing
// from Sources/, so both programs build it. Names start with W (or Widget) so they don't meet cl_audit's own.
//
// The look is kept in usage-n-uf/widget.json, which cl_audit writes and the widget reads (its sandbox may read that
// folder only): the plate (System, Std, Black, Silver), the layout (Fill, Hero, List), how the limits are drawn (Glow,
// Rings, Numbers, Segments, Pace) and what to show (reset times, Fable's limit, the next resets).

import SwiftUI
import os

private let wlog = Logger(subsystem: "local.usage-n-uf", category: "widget")

// MARK: what it reads

struct WidgetProfile: Identifiable {
    let id: String
    let name: String
    let accent: String
    var five: Double?
    var fiveResets: Date?
    var week: Double?
    var weekResets: Date?
    var fable: Double?
    var plan: String?
    var updated: Date?

    /// The full limit that holds the profile back now (the later reset when both are), or nil.
    func full(now: Date) -> (name: String, resets: Date?)? {
        func holding(_ p: Double?, _ r: Date?) -> Bool { (p.map { $0.rounded() >= 100 } ?? false) && (r.map { $0 > now } ?? true) }
        let f = holding(five, fiveResets), w = holding(week, weekResets)
        if f && w { return (fiveResets ?? .distantFuture) > (weekResets ?? .distantFuture) ? ("5-hour", fiveResets) : ("Week", weekResets) }
        if f { return ("5-hour", fiveResets) }
        if w { return ("Week", weekResets) }
        return nil
    }

    /// For picking the few with the least room: a full one first (the longest wait), then the fullest.
    func room(now: Date) -> Double {
        if let f = full(now: now) { return 1000 + (f.resets.map { $0.timeIntervalSince(now) / 60 } ?? 100_000) }
        return max(five ?? 0, week ?? 0)
    }

    /// The fuller of the two: "five" or "week".
    var fullerIsFive: Bool { (five ?? -1) >= (week ?? -1) }
}

enum AgentFiles {
    /// The real home folder: inside the widget's sandbox NSHomeDirectory() is its own container.
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/usage-n-uf")
    }

    private struct Accounts: Decodable { let accounts: [Entry] }
    private struct Entry: Decodable { let id: String; let name: String; let accent: String? }
    private struct Status: Decodable {
        let fiveHour: Double?; let fiveHourResets: Double?; let weekly: Double?; let weeklyResets: Double?
        let updatedAt: Double?; let plan: String?; let scoped: [Scoped]?
    }
    private struct Scoped: Decodable { let name: String; let percent: Double? }

    static func load() -> [WidgetProfile] {
        let dec = JSONDecoder()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("accounts.json")),
              let list = try? dec.decode(Accounts.self, from: data) else {
            wlog.error("widget: can't read the profiles file")
            return []
        }
        let profiles = list.accounts.map { e -> WidgetProfile in
            var p = WidgetProfile(id: e.id, name: e.name, accent: e.accent ?? "orange")
            if let d = try? Data(contentsOf: folder.appendingPathComponent("status/\(e.id).json")),
               let s = try? dec.decode(Status.self, from: d) {
                p.five = s.fiveHour; p.week = s.weekly; p.plan = s.plan
                p.fiveResets = s.fiveHourResets.map { Date(timeIntervalSince1970: $0) }
                p.weekResets = s.weeklyResets.map { Date(timeIntervalSince1970: $0) }
                p.updated = s.updatedAt.map { Date(timeIntervalSince1970: $0) }
                p.fable = s.scoped?.first(where: { $0.name == "Fable" })?.percent
            }
            return p
        }
        wlog.log("widget: read \(profiles.count) profiles")
        return profiles
    }

    static let demo = [
        WidgetProfile(id: "home", name: "Home", accent: "orange", five: 34, fiveResets: Date().addingTimeInterval(6120), week: 57,
                      weekResets: Date().addingTimeInterval(240_000), fable: 7, plan: "max", updated: Date()),
        WidgetProfile(id: "work", name: "Work", accent: "teal", five: 13, fiveResets: Date().addingTimeInterval(11_000), week: 12,
                      weekResets: Date().addingTimeInterval(400_000), fable: 0, plan: "team", updated: Date())]
}

// MARK: the look

struct WidgetLook: Codable, Equatable {
    enum Plate: String, Codable, CaseIterable, Identifiable {
        case system, std, black, silver
        var id: String { rawValue }
        var title: String { self == .system ? "System" : rawValue.capitalized }
    }
    enum Layout: String, Codable, CaseIterable, Identifiable {
        case fill, hero, list
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var blurb: String {
            switch self {
            case .fill: return "Every profile, bigger when there are few; the large size adds the next resets."
            case .hero: return "The profile with the least room large, the others compact."
            case .list: return "One row per profile, for many profiles; the rows spread over the height."
            }
        }
    }
    enum Design: String, Codable, CaseIterable, Identifiable {
        case glow, rings, numbers, segments, pace
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Rows and lists draw rings and numbers as bars: there's no room for them.
        var flat: Design { self == .rings || self == .numbers ? .glow : self }
        var round: Bool { self == .rings || self == .numbers }
    }

    var plate: Plate = .system
    var layout: Layout = .fill
    var design: Design = .glow
    var resets = true
    var fable = true
    var next = true

    static var file: URL { AgentFiles.folder.appendingPathComponent("widget.json") }

    static func load() -> WidgetLook {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(WidgetLook.self, from: $0) } ?? WidgetLook()
    }

    /// cl_audit only (the widget may not write).
    func save() throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        try enc.encode(self).write(to: Self.file, options: .atomic)
    }
}

enum WidgetSize { case small, medium, large }

// MARK: colours and words

struct WTheme {
    let ink: Color, muted: Color, track: Color, panel: Bool
    static func of(_ plate: WidgetLook.Plate) -> WTheme {
        switch plate {
        case .system: return WTheme(ink: .primary, muted: .secondary, track: Color.primary.opacity(0.13), panel: false)
        case .std, .black: return WTheme(ink: Color(white: 0.95), muted: Color(white: 1, opacity: 0.55), track: Color(white: 1, opacity: 0.12), panel: true)
        case .silver: return WTheme(ink: Color(white: 0.11), muted: Color(white: 0, opacity: 0.55), track: Color(white: 0, opacity: 0.13), panel: true)
        }
    }
}

enum WKit {
    static let green = Color(red: 0.13, green: 0.77, blue: 0.37)
    static let amber = Color(red: 0.96, green: 0.62, blue: 0.04)
    static let red = Color(red: 0.94, green: 0.27, blue: 0.27)

    static func level(_ p: Double?) -> Color? {
        guard let p else { return nil }
        return p >= 80 ? red : p >= 50 ? amber : green
    }

    static func accent(_ name: String) -> Color {
        switch name {
        case "yellow": return .yellow
        case "lime": return Color(red: 0.6, green: 0.85, blue: 0.2)
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "fuchsia": return Color(red: 0.85, green: 0.27, blue: 0.94)
        case "pink": return .pink
        case "graphite": return .gray
        default: return .orange
        }
    }

    static func pct(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "–" }

    private static func format(_ f: String, _ d: Date) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = f
        return df.string(from: d)
    }

    /// "17:51" today, "Fri 01:00" within the week, "11 Nov" later.
    static func when(_ d: Date, now: Date) -> String {
        if Calendar.current.isDate(d, inSameDayAs: now) { return format("HH:mm", d) }
        return format(d.timeIntervalSince(now) < 6 * 86400 ? "EEE HH:mm" : "d MMM", d)
    }

    /// When a limit resets, short: "in 3h 11m" within a day, else "Fri 01:00".
    static func resets(_ d: Date?, now: Date) -> String? {
        guard let d, d > now else { return nil }
        let m = Int(ceil(d.timeIntervalSince(now) / 60))
        if m < 60 { return "in \(m)m" }
        if m < 24 * 60 { return "in \(m / 60)h \(m % 60)m" }
        return when(d, now: now)
    }

    static func back(_ d: Date?, now: Date) -> String {
        guard let d else { return "full" }
        return Calendar.current.isDate(d, inSameDayAs: now) ? "back at \(format("HH:mm", d))" : "back \(when(d, now: now))"
    }

    /// How much of a limit's window has passed, 0…1, for the pace marker.
    static func elapsed(_ resets: Date?, window: TimeInterval, now: Date) -> Double? {
        guard let resets else { return nil }
        return min(max(1 - resets.timeIntervalSince(now) / window, 0), 1)
    }
}

// MARK: one limit

struct WBar: View {
    let design: WidgetLook.Design
    let p: Double?
    var elapsed: Double? = nil
    var height: CGFloat = 5
    let theme: WTheme

    var body: some View {
        switch design {
        case .segments:
            let on = Int(((p ?? 0) / 100 * 12).rounded())
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < on ? (i < 6 ? WKit.green : i < 9 ? WKit.amber : WKit.red) : theme.track)
                }
            }
            .frame(height: height + 1)
        default:
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    if let p, let c = WKit.level(p) {
                        Capsule().fill(c).frame(width: max(height, g.size.width * CGFloat(min(max(p, 0), 100)) / 100))
                            .shadow(color: design == .glow ? c.opacity(0.7) : .clear, radius: 3)
                    }
                    if design == .pace, let e = elapsed {
                        RoundedRectangle(cornerRadius: 1).fill(theme.ink).frame(width: 2, height: height + 4)
                            .offset(x: g.size.width * CGFloat(e) - 1)
                    }
                }
            }
            .frame(height: height)
        }
    }
}

struct WRing: View {
    let p: Double?
    let size: CGFloat
    let theme: WTheme
    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: size * 0.1)
            if let p {
                Circle().trim(from: 0, to: CGFloat(min(max(p, 0), 100)) / 100)
                    .stroke(WKit.level(p) ?? theme.track, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(p.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: size * 0.28, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(theme.ink)
        }
        .frame(width: size, height: size)
    }
}

/// A limit drawn in a design: name (and, if asked, when it resets), the number and its bar, ring or big number.
struct WLimit: View {
    let design: WidgetLook.Design
    let name: String
    let p: Double?
    var resets: String? = nil
    var elapsed: Double? = nil
    var big = false
    let theme: WTheme

    var body: some View {
        switch design {
        case .rings:
            VStack(spacing: 2) {
                WRing(p: p, size: big ? 50 : 40, theme: theme)
                Text(name).font(.system(size: 10)).foregroundStyle(theme.muted)
                if let resets { Text(resets).font(.system(size: 9.5)).foregroundStyle(theme.muted).lineLimit(1) }
            }
        case .numbers:
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 10)).foregroundStyle(theme.muted)
                number
                WBar(design: .glow, p: p, height: 3, theme: theme)
                if let resets { Text(resets).font(.system(size: 9.5)).foregroundStyle(theme.muted).lineLimit(1) }
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name).font(.system(size: big ? 12 : 11)).foregroundStyle(theme.muted)
                    if let resets { Text("· \(resets)").font(.system(size: 9.5)).foregroundStyle(theme.muted).lineLimit(1) }
                    Spacer(minLength: 2)
                    Text(WKit.pct(p)).font(.system(size: big ? 12 : 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(WKit.level(p) ?? theme.ink)
                }
                WBar(design: design, p: p, elapsed: elapsed, height: big ? 7 : 5, theme: theme)
            }
        }
    }

    /// The big number: a glowing display window on the panel plates, plain on System.
    @ViewBuilder private var number: some View {
        let c = WKit.level(p) ?? theme.ink
        if theme.panel {
            Text(WKit.pct(p)).font(.system(size: big ? 17 : 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(p == nil ? Color(red: 0.5, green: 0.98, blue: 0.92) : c)
                .shadow(color: c.opacity(0.6), radius: 3)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(
                    colors: [Color(red: 0.01, green: 0.02, blue: 0.03), Color(red: 0.05, green: 0.08, blue: 0.09)], startPoint: .top, endPoint: .bottom)))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(p.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: big ? 30 : 22, weight: .heavy, design: .rounded))
                if p != nil { Text("%").font(.system(size: big ? 15 : 12, weight: .bold, design: .rounded)) }
            }
            .monospacedDigit().foregroundStyle(c)
        }
    }
}

// MARK: the widget

/// The whole widget for a size, the profiles and the look. The background (the plate) is the caller's.
struct WidgetContent: View {
    let profiles: [WidgetProfile]
    let look: WidgetLook
    let size: WidgetSize
    var now = Date()

    private var theme: WTheme { WTheme.of(look.plate) }
    private var sorted: [WidgetProfile] { profiles.sorted { $0.room(now: now) > $1.room(now: now) } }
    private var many: Bool { profiles.count > 2 }

    var body: some View {
        Group {
            if profiles.isEmpty {
                VStack(spacing: 4) {
                    Text("cl_audit").font(.headline).foregroundStyle(theme.ink)
                    Text("No profiles yet: open cl_audit to add one.").font(.caption).foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var content: some View {
        let d = look.design
        switch (size, look.layout) {
        case (.small, .list), (.small, _) where many:
            evenly { smallRows(look.layout == .list ? Array(profiles.prefix(4)) : Array(sorted.prefix(3))) }
        case (.small, .hero):
            VStack(alignment: .leading, spacing: 6) {
                head(sorted[0], meta: "least room")
                limits(sorted[0], which: .both, short: true, fable: false, resets: false)
                Spacer(minLength: 0)
            }
        case (.small, _):
            if d.round {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(profiles) { p in block(p, which: p.fullerIsFive ? .five : .week, big: true, short: true, fable: false) }
                }
                .frame(maxHeight: .infinity)          // centred: rings and numbers don't stretch
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { divider }
                        block(p, which: p.fullerIsFive ? .five : .week, short: true, fable: false).frame(maxHeight: .infinity)
                    }
                }
            }
        case (_, .list):
            evenly { rows(Array(profiles.prefix(size == .large ? 8 : 4)), fable: size == .large && look.fable) }
        case (.medium, .hero):
            let h = sorted[0]
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    head(h, meta: "least room")
                    limits(h, which: .both, big: !d.round, fable: false, resets: look.resets)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                evenly { smallRows(Array(sorted.dropFirst().prefix(2))) }.frame(maxWidth: .infinity)
            }
        case (.large, .hero):
            let h = sorted[0], rest = Array(sorted.dropFirst())
            VStack(alignment: .leading, spacing: 0) {
                head(h, meta: "least room").padding(.bottom, 6)
                limits(h, which: .both, big: true, fable: look.fable, resets: look.resets)
                Spacer(minLength: 6); divider; Spacer(minLength: 6)
                if many {
                    evenly { rows(rest, fable: false) }
                } else {
                    ForEach(rest) { p in block(p, which: .both, short: true, fable: false, resets: false) }
                    if look.next { Spacer(minLength: 6); divider; Spacer(minLength: 6); nextResets }
                }
            }
        case (.medium, _):   // fill
            let cols = many && d.round ? 4 : 2
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<cols, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(profiles.prefix(4).enumerated()).filter { $0.offset % cols == c }, id: \.element.id) { _, p in
                            block(p, which: many ? (p.fullerIsFive ? .five : .week) : .both, big: !many, short: many,
                                  fable: false, resets: look.resets && !many, spread: !many && !d.round)
                        }
                    }
                    // bars spread over the height; rings and numbers keep their size, so they're centred
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: d.round ? .leading : .topLeading)
                }
            }
        case (.large, _):    // fill
            if many {
                evenly { rows(Array(profiles.prefix(8)), fable: look.fable) }
            } else {
                // the room that's left is shared out between the parts, not left at the bottom
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { Spacer(minLength: 6); divider; Spacer(minLength: 6) }
                        block(p, which: .both, meta: p.plan?.capitalized, big: true, fable: look.fable, resets: look.resets)
                    }
                    if look.next { Spacer(minLength: 6); divider; Spacer(minLength: 6); nextResets }
                }
            }
        }
    }

    // MARK: parts

    enum Which { case five, week, both }

    private var divider: some View { Rectangle().fill(theme.track.opacity(0.6)).frame(height: 1).padding(.vertical, 2) }

    private func evenly<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }.frame(maxHeight: .infinity)
    }

    @ViewBuilder private func head(_ p: WidgetProfile, meta: String? = nil) -> some View {
        HStack(spacing: 5) {
            Circle().fill(WKit.accent(p.accent)).frame(width: 6, height: 6)
            Text(theme.panel ? p.name.uppercased() : p.name)
                .font(theme.panel ? .system(size: 10, weight: .bold) : .system(size: 12.5, weight: .semibold))
                .tracking(theme.panel ? 1.4 : 0).foregroundStyle(theme.ink).lineLimit(1)
            Spacer(minLength: 4)
            if let f = p.full(now: now) {
                Text(WKit.back(f.resets, now: now)).font(.system(size: 10, weight: .semibold)).foregroundStyle(WKit.red).lineLimit(1)
            } else if let meta {
                Text(meta).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func limits(_ p: WidgetProfile, which: Which, big: Bool = false, short: Bool = false,
                                     fable: Bool, resets: Bool, spread: Bool = false) -> some View {
        let d = look.design
        let five = WLimit(design: d, name: short ? "5h" : "5-hour", p: p.five, resets: resets ? WKit.resets(p.fiveResets, now: now) : nil,
                          elapsed: WKit.elapsed(p.fiveResets, window: 5 * 3600, now: now), big: big, theme: theme)
        let week = WLimit(design: d, name: short ? "wk" : "Week", p: p.week, resets: resets ? WKit.resets(p.weekResets, now: now) : nil,
                          elapsed: WKit.elapsed(p.weekResets, window: 7 * 86400, now: now), big: big, theme: theme)
        let showFable = fable && which == .both && p.fable != nil
        if d.round {
            HStack(alignment: .top, spacing: 8) {
                if which != .week { five }
                if which != .five { week }
                if showFable { WLimit(design: d, name: "Fable", p: p.fable, big: big, theme: theme) }
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: spread ? 0 : 6) {
                if which != .week { five }
                if spread && which == .both { Spacer(minLength: 6) }
                if which != .five { week }
                if showFable { WLimit(design: d, name: "Fable", p: p.fable, big: big, theme: theme) }
            }
            .frame(maxHeight: spread ? .infinity : nil, alignment: .top)
        }
    }

    @ViewBuilder private func block(_ p: WidgetProfile, which: Which, meta: String? = nil, big: Bool = false, short: Bool = false,
                                    fable: Bool, resets: Bool = false, spread: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            head(p, meta: meta)
            limits(p, which: which, big: big, short: short, fable: fable, resets: resets, spread: spread)
        }
        .frame(maxHeight: spread ? .infinity : nil, alignment: .top)
    }

    /// One line per profile: its name, its fuller limit and that limit's bar under it.
    @ViewBuilder private func smallRows(_ ps: [WidgetProfile]) -> some View {
        ForEach(Array(ps.enumerated()), id: \.element.id) { i, p in
            if i > 0 { Spacer(minLength: 4) }
            let five = p.fullerIsFive, v = five ? p.five : p.week
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(WKit.accent(p.accent)).frame(width: 6, height: 6)
                    Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                    Spacer(minLength: 2)
                    if let f = p.full(now: now) {
                        Text(WKit.back(f.resets, now: now)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WKit.red).lineLimit(1)
                    } else {
                        Text(five ? "5h" : "wk").font(.system(size: 9.5)).foregroundStyle(theme.muted)
                        Text(WKit.pct(v)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit().foregroundStyle(WKit.level(v) ?? theme.ink)
                    }
                }
                WBar(design: look.design.flat, p: v, height: 5, theme: theme)
            }
        }
    }

    /// One row per profile: name | 5-hour | week (| Fable).
    @ViewBuilder private func rows(_ ps: [WidgetProfile], fable: Bool) -> some View {
        ForEach(Array(ps.enumerated()), id: \.element.id) { i, p in
            if i > 0 { Spacer(minLength: 4) }
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(WKit.accent(p.accent)).frame(width: 6, height: 6)
                    Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WLimit(design: look.design.flat, name: "5h", p: p.five, theme: theme).frame(maxWidth: .infinity)
                WLimit(design: look.design.flat, name: "wk", p: p.week, theme: theme).frame(maxWidth: .infinity)
                if fable { WLimit(design: look.design.flat, name: "Fable", p: p.fable, theme: theme).frame(maxWidth: .infinity) }
            }
        }
    }

    /// The next three resets across the profiles.
    private var nextResets: some View {
        let items: [(String, String, Date)] = profiles.flatMap { p -> [(String, String, Date)] in
            [p.fiveResets.map { (p.name, "5-hour", $0) }, p.weekResets.map { (p.name, "week", $0) }].compactMap { $0 }
        }
        .filter { $0.2 > now }.sorted { $0.2 < $1.2 }
        return VStack(alignment: .leading, spacing: 3) {
            Text("NEXT RESETS").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(theme.muted)
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, it in
                HStack {
                    Text(it.0).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.ink)
                    + Text(" \(it.1)").font(.system(size: 11)).foregroundColor(theme.muted)
                    Spacer()
                    Text(WKit.when(it.2, now: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
                }
            }
        }
    }
}

/// The widget's plate: the system's own background, or one of cl_audit's faces.
struct WidgetPlate: View {
    let plate: WidgetLook.Plate
    var body: some View {
        switch plate {
        case .system: Color.clear
        case .std: LinearGradient(colors: [Color(white: 0.17), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
        case .black: LinearGradient(colors: [Color(white: 0.115), Color(white: 0.068)], startPoint: .top, endPoint: .bottom)
        case .silver: LinearGradient(colors: [Color(white: 0.92), Color(white: 0.82)], startPoint: .top, endPoint: .bottom)
        }
    }
}
