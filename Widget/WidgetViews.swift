// What the cl_audit widget draws, shared by the widget (Widget.swift, a sandboxed extension) and cl_audit itself (the
// Widget card in Settings ▸ General shows the real widget as its preview). Self-contained: no WidgetKit here and nothing
// from Sources/, so both programs build it. Names start with W (or Widget) so they don't meet cl_audit's own.
//
// The look is kept in usage-n-uf/widget.json, which cl_audit writes and the widget reads (its sandbox may read that
// folder only): the plate (System, Std, Black, Silver) and how the limits are drawn (Glow, Rings, Numbers, Segments,
// Pace). One layout fits every size: one or two profiles get large limits with their reset times, centred in the
// widget; more profiles get a row each. Fable's limit shows where the profile's settings say so.

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
    var fable: Double?                  // nil: the plan has none, or the profile doesn't show it
    var plan: String?
    var updated: Date?
    var noFive = false                  // the plan has no 5-hour limit (Ultra): the week alone, no 5-hour row

    /// The plan as words: Claude's own name as it is ("Ultra"), the sign-in's lower-case one capitalised ("Max").
    var planWords: String? { plan.map { $0 == $0.lowercased() ? $0.capitalized : $0 } }

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

    /// Whether the 5-hour limit is the fuller of the two.
    var fullerIsFive: Bool { !noFive && (five ?? -1) >= (week ?? -1) }
}

enum AgentFiles {
    /// The real home folder: inside the widget's sandbox NSHomeDirectory() is its own container.
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/usage-n-uf")
    }

    private struct Accounts: Decodable { let accounts: [Entry] }
    private struct Entry: Decodable { let id: String; let name: String; let accent: String?; let showFable: Bool? }
    private struct Status: Decodable {
        let fiveHour: Double?; let fiveHourResets: Double?; let weekly: Double?; let weeklyResets: Double?
        let updatedAt: Double?; let plan: String?; let scoped: [Scoped]?; let noFiveHour: Bool?
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
                p.noFive = s.noFiveHour ?? false
                if e.showFable ?? true { p.fable = s.scoped?.first(where: { $0.name == "Fable" })?.percent }
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
                      weekResets: Date().addingTimeInterval(400_000), fable: nil, plan: "team", updated: Date())]
}

// MARK: the look

struct WidgetLook: Codable, Equatable {
    enum Plate: String, Codable, CaseIterable, Identifiable {
        case system, std, black, silver
        var id: String { rawValue }
        var title: String { self == .system ? "System" : rawValue.capitalized }
    }
    enum Design: String, Codable, CaseIterable, Identifiable {
        case glow, rings, numbers, segments, pace
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var round: Bool { self == .rings || self == .numbers }
    }

    var plate: Plate = .system
    var design: Design = .glow

    init(plate: Plate = .system, design: Design = .glow) { self.plate = plate; self.design = design }

    private enum Keys: String, CodingKey { case plate, design }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        plate = (try? c.decodeIfPresent(Plate.self, forKey: .plate)) ?? .system
        design = (try? c.decodeIfPresent(Design.self, forKey: .design)) ?? .glow
    }

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

// MARK: colours, sizes and words

struct WTheme {
    let ink: Color, muted: Color, track: Color
    let printed: Bool       // names as printed uppercase labels (cl_audit's faces)
    let display: Bool       // big numbers in a glowing display window (the dark faces)
    static func of(_ plate: WidgetLook.Plate) -> WTheme {
        switch plate {
        case .system:
            return WTheme(ink: .primary, muted: .secondary, track: Color.primary.opacity(0.12), printed: false, display: false)
        case .std, .black:
            return WTheme(ink: Color(white: 0.95), muted: Color(white: 1, opacity: 0.55), track: Color(white: 1, opacity: 0.12),
                          printed: true, display: true)
        case .silver:
            return WTheme(ink: Color(white: 0.1), muted: Color(white: 0, opacity: 0.55), track: Color(white: 0, opacity: 0.14),
                          printed: true, display: false)
        }
    }
}

/// Type and mark sizes: larger when there's room.
struct WScale {
    let name, label, pct, bar, ring, number: CGFloat
    static let small = WScale(name: 12.5, label: 10.5, pct: 12.5, bar: 6, ring: 46, number: 24)
    static let medium = WScale(name: 13.5, label: 11.5, pct: 14, bar: 7, ring: 48, number: 26)
    static let largeOne = WScale(name: 16, label: 13, pct: 20, bar: 10, ring: 80, number: 46)    // one profile
    static let large = WScale(name: 14.5, label: 11.5, pct: 14, bar: 7, ring: 54, number: 30)
    static let largeFour = WScale(name: 12.5, label: 10.5, pct: 12.5, bar: 6, ring: 36, number: 21)   // three or four profiles
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

// MARK: the marks

struct WBar: View {
    let design: WidgetLook.Design
    let p: Double?
    var elapsed: Double? = nil
    var height: CGFloat = 6
    let theme: WTheme

    var body: some View {
        switch design {
        case .segments:
            let on = Int(((p ?? 0) / 100 * 12).rounded())
            HStack(spacing: 2) {
                ForEach(0..<12, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < on ? (i < 6 ? WKit.green : i < 9 ? WKit.amber : WKit.red) : theme.track)
                }
            }
            .frame(height: height)
        default:
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    if let p, let c = WKit.level(p) {
                        Capsule().fill(c).frame(width: max(height, g.size.width * CGFloat(min(max(p, 0), 100)) / 100))
                            .shadow(color: design == .glow ? c.opacity(0.6) : .clear, radius: 3)
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
    var number = true
    let theme: WTheme
    var body: some View {
        ZStack {
            Circle().stroke(theme.track, lineWidth: max(2.5, size * 0.1))
            if let p {
                Circle().trim(from: 0, to: CGFloat(min(max(p, 0), 100)) / 100)
                    .stroke(WKit.level(p) ?? theme.track, style: StrokeStyle(lineWidth: max(2.5, size * 0.1), lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if number {
                Text(p.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                    .monospacedDigit().foregroundStyle(theme.ink)
            }
        }
        .frame(width: size, height: size)
    }
}

/// The big number: a glowing display window on the dark faces, plain digits in the level colour elsewhere.
struct WNumber: View {
    let p: Double?
    let size: CGFloat
    let theme: WTheme
    var body: some View {
        let c = WKit.level(p) ?? theme.ink
        if theme.display {
            Text(WKit.pct(p)).font(.system(size: size * 0.62, weight: .semibold, design: .monospaced))
                .foregroundStyle(p == nil ? Color(red: 0.5, green: 0.98, blue: 0.92) : c)
                .shadow(color: c.opacity(0.6), radius: 3)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(LinearGradient(
                    colors: [Color(red: 0.01, green: 0.02, blue: 0.03), Color(red: 0.05, green: 0.08, blue: 0.09)], startPoint: .top, endPoint: .bottom)))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(p.map { "\(Int($0.rounded()))" } ?? "–").font(.system(size: size, weight: .heavy, design: .rounded))
                if p != nil { Text("%").font(.system(size: size * 0.5, weight: .bold, design: .rounded)) }
            }
            .monospacedDigit().foregroundStyle(p == nil ? theme.muted : c)
        }
    }
}

/// One limit in the chosen design: its name (and when it resets, if there's room), with a bar, a ring or a big number.
struct WLimit: View {
    let design: WidgetLook.Design
    let name: String
    let p: Double?
    var resets: String? = nil
    var elapsed: Double? = nil
    let scale: WScale
    let theme: WTheme

    var body: some View {
        switch design {
        case .rings:
            VStack(spacing: 3) {
                WRing(p: p, size: scale.ring, theme: theme)
                Text(name).font(.system(size: scale.label, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
                if let resets { Text(resets).font(.system(size: scale.label - 1.5)).foregroundStyle(theme.muted).lineLimit(1) }
            }
        case .numbers:
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: scale.label, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
                WNumber(p: p, size: scale.number, theme: theme)
                if let resets { Text(resets).font(.system(size: scale.label - 1.5)).foregroundStyle(theme.muted).lineLimit(1) }
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(name).font(.system(size: scale.label, weight: .medium)).foregroundStyle(theme.muted).lineLimit(1)
                    if let resets { Text("· \(resets)").font(.system(size: scale.label - 1.5)).foregroundStyle(theme.muted).lineLimit(1) }
                    Spacer(minLength: 2)
                    Text(WKit.pct(p)).font(.system(size: scale.pct, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WKit.level(p) ?? theme.muted)
                }
                WBar(design: design, p: p, elapsed: elapsed, height: scale.bar, theme: theme)
            }
        }
    }
}

/// A limit in a row (many profiles): a small ring, a number or a bar, as the design says.
struct WMini: View {
    let design: WidgetLook.Design
    let name: String
    let p: Double?
    let theme: WTheme

    var body: some View {
        switch design {
        case .rings:
            HStack(spacing: 5) {
                WRing(p: p, size: 18, number: false, theme: theme)
                Text(WKit.pct(p)).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WKit.level(p) ?? theme.muted)
            }
        case .numbers:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(name).font(.system(size: 10)).foregroundStyle(theme.muted).lineLimit(1)
                Text(WKit.pct(p)).font(.system(size: 15, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WKit.level(p) ?? theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)           // "100%" in a narrow column stays on one line
            }
        default:
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name).font(.system(size: 10)).foregroundStyle(theme.muted)
                    Spacer(minLength: 2)
                    Text(WKit.pct(p)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(WKit.level(p) ?? theme.muted)
                }
                WBar(design: design, p: p, height: 5, theme: theme)
            }
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

    /// A size picked by the large layout (it tries the bigger ones first); nil: the size's own.
    var forcedScale: WScale? = nil

    private var theme: WTheme { WTheme.of(look.plate) }
    private var scale: WScale {
        forcedScale ?? (size == .small ? .small : size == .medium ? .medium : profiles.count > 2 ? .largeFour : .large)
    }
    private func scaled(_ s: WScale) -> WidgetContent { var c = self; c.forcedScale = s; return c }
    private var sorted: [WidgetProfile] { profiles.sorted { $0.room(now: now) > $1.room(now: now) } }

    var body: some View {
        Group {
            if profiles.isEmpty {
                VStack(spacing: 4) {
                    Text("cl_audit").font(.headline).foregroundStyle(theme.ink)
                    Text("No profiles yet: open cl_audit to add one.").font(.caption).foregroundStyle(theme.muted)
                        .multilineTextAlignment(.center)
                }
            } else if profiles.count > (size == .large ? 4 : 2) {
                rows
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: one or two profiles

    /// Each profile's fuller limit, centred: bars one under the other, rings and numbers side by side.
    @ViewBuilder private var small: some View {
        if look.design.round && profiles.count == 2 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(profiles) { p in
                    VStack(spacing: 6) {
                        head(p, compact: true)
                        limit(p, five: p.fullerIsFive, resets: false)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { divider }
                    VStack(alignment: .leading, spacing: 6) {
                        head(p)
                        if profiles.count == 1 { limits(p, fable: false, resets: false) }
                        else { limit(p, five: p.fullerIsFive, resets: false) }
                    }
                }
            }
        }
    }

    /// A column per profile with all its limits and when they reset, centred; one profile spreads its limits across.
    private var medium: some View {
        HStack(alignment: .top, spacing: 18) {
            ForEach(profiles) { p in
                VStack(alignment: .leading, spacing: 8) {
                    head(p)
                    limits(p, fable: true, resets: true, across: profiles.count == 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One profile: its limits big, spread over the height, each with when it resets. Two: every limit with when it
    /// resets, then the next resets. Three or four: a block each, limits side by side, then the next resets when
    /// there's room. The biggest arrangement that fits is used, and the room left is shared out evenly between the
    /// parts, so no part of the widget stays empty.
    @ViewBuilder private var large: some View {
        switch profiles.count {
        case 1:
            // the height decides: the widths follow the widget (segment bars ask for more than they need)
            ViewThatFits(in: .vertical) {
                scaled(.largeOne).blocks(resets: true, footer: false)
                scaled(.large).blocks(resets: true, footer: false)
            }
        case 2:
            ViewThatFits(in: .vertical) {
                scaled(.large).blocks(resets: true, footer: true)
                scaled(.large).blocks(resets: true, footer: false)
                scaled(.largeFour).blocks(resets: false, footer: false)
            }
        default:
            ViewThatFits(in: .vertical) {
                scaled(.large).blocks(resets: false, footer: true)
                scaled(.large).blocks(resets: false, footer: false)
                scaled(.largeFour).blocks(resets: false, footer: true)
                scaled(.largeFour).blocks(resets: false, footer: false)
            }
        }
    }

    /// The large size's parts in one size: a block per profile, then (footer) the next resets, with the room left
    /// shared out between them. One profile's limits are spread out over its block.
    private func blocks(resets: Bool, footer: Bool) -> some View {
        let one = profiles.count == 1
        let across = profiles.count > 2 || look.design.round
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Spacer(minLength: 6); divider; Spacer(minLength: 6) }
                VStack(alignment: .leading, spacing: one ? 0 : 8) {
                    head(p, meta: p.planWords)
                    if one {
                        spread(p, resets: resets, across: across)
                    } else {
                        limits(p, fable: true, resets: resets, across: across)
                    }
                }
            }
            if footer {
                Spacer(minLength: 6); divider; Spacer(minLength: 6)
                nextResets
            }
        }
    }

    /// One profile's limits filling the height: bars one under the other with the room between them, rings and
    /// numbers side by side in the middle.
    @ViewBuilder private func spread(_ p: WidgetProfile, resets: Bool, across: Bool) -> some View {
        let f = WLimit(design: look.design, name: "Fable", p: p.fable, scale: scale, theme: theme)
        if across {
            Spacer(minLength: 8)
            limits(p, fable: true, resets: resets, across: true)
            Spacer(minLength: 8)
        } else {
            if !p.noFive { Spacer(minLength: 10); limit(p, five: true, resets: resets) }
            Spacer(minLength: 10); limit(p, five: false, resets: resets)
            if p.fable != nil { Spacer(minLength: 10); f }
            Spacer(minLength: 4)
        }
    }

    // MARK: many profiles

    /// A row per profile: its name, then 5-hour and week (and Fable in the large size) in the chosen design.
    private var rows: some View {
        // the small size picks the three with the least room; every size lists them in the profiles' order
        let few = Set(sorted.prefix(3).map(\.id))
        let list = size == .small ? profiles.filter { few.contains($0.id) } : Array(profiles.prefix(size == .large ? 8 : 4))
        let fable = size == .large && list.contains { $0.fable != nil }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, p in
                if i > 0 { Spacer(minLength: 4) }
                if size == .small {
                    HStack(spacing: 6) {
                        dot(p)
                        Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                        Spacer(minLength: 2)
                        if let f = p.full(now: now) {
                            Text(WKit.back(f.resets, now: now)).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(WKit.red).lineLimit(1)
                        } else {
                            WMini(design: look.design == .numbers || look.design == .rings ? look.design : .glow,
                                  name: p.fullerIsFive ? "5h" : "wk", p: p.fullerIsFive ? p.five : p.week, theme: theme)
                                .frame(maxWidth: look.design.round ? nil : 70)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        HStack(spacing: 6) {
                            dot(p)
                            Text(p.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if p.noFive { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }   // keeps the columns lined up
                        else { WMini(design: look.design, name: "5h", p: p.five, theme: theme).frame(maxWidth: .infinity, alignment: .leading) }
                        WMini(design: look.design, name: "wk", p: p.week, theme: theme).frame(maxWidth: .infinity, alignment: .leading)
                        if fable { WMini(design: look.design, name: "Fable", p: p.fable, theme: theme).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                }
            }
        }
    }

    // MARK: parts

    private var divider: some View { Rectangle().fill(theme.track).frame(height: 1) }

    private func dot(_ p: WidgetProfile) -> some View { Circle().fill(WKit.accent(p.accent)).frame(width: 7, height: 7) }

    /// A profile's name; compact: just the dot and name, centred (small side by side).
    private func head(_ p: WidgetProfile, meta: String? = nil, compact: Bool = false) -> some View {
        HStack(spacing: 6) {
            dot(p)
            Text(theme.printed ? p.name.uppercased() : p.name)
                .font(theme.printed ? .system(size: scale.name - 3, weight: .bold) : .system(size: scale.name, weight: .semibold))
                .tracking(theme.printed ? 1.4 : 0).foregroundStyle(theme.ink).lineLimit(1)
            if !compact { Spacer(minLength: 4) }
            if compact {
                EmptyView()
            } else if let f = p.full(now: now) {
                Text(WKit.back(f.resets, now: now)).font(.system(size: scale.label - 1, weight: .semibold)).foregroundStyle(WKit.red).lineLimit(1)
            } else if let meta {
                Text(meta).font(.system(size: scale.label - 1)).foregroundStyle(theme.muted).lineLimit(1)
            }
        }
    }

    private func limit(_ p: WidgetProfile, five: Bool, resets: Bool) -> WLimit {
        five ? WLimit(design: look.design, name: "5-hour", p: p.five, resets: resets ? WKit.resets(p.fiveResets, now: now) : nil,
                      elapsed: WKit.elapsed(p.fiveResets, window: 5 * 3600, now: now), scale: scale, theme: theme)
             : WLimit(design: look.design, name: "Week", p: p.week, resets: resets ? WKit.resets(p.weekResets, now: now) : nil,
                      elapsed: WKit.elapsed(p.weekResets, window: 7 * 86400, now: now), scale: scale, theme: theme)
    }

    /// A profile's limits: rings and numbers side by side; bars one under the other (or side by side when across).
    @ViewBuilder private func limits(_ p: WidgetProfile, fable: Bool, resets: Bool, across: Bool = false) -> some View {
        let withFable = fable && p.fable != nil
        let f = WLimit(design: look.design, name: "Fable", p: p.fable, scale: scale, theme: theme)
        if look.design.round || across {
            HStack(alignment: .top, spacing: look.design.round ? 10 : 16) {
                if !p.noFive { limit(p, five: true, resets: resets) }
                limit(p, five: false, resets: resets)
                if withFable { f }
            }
            .frame(maxWidth: .infinity, alignment: look.design.round ? .center : .leading)
        } else {
            VStack(alignment: .leading, spacing: size == .large ? 7 : 9) {
                if !p.noFive { limit(p, five: true, resets: resets) }
                limit(p, five: false, resets: resets)
                if withFable { f }
            }
        }
    }

    /// The next three resets across the profiles.
    private var nextResets: some View {
        let items: [(String, String, Date)] = profiles.flatMap { p -> [(String, String, Date)] in
            [p.fiveResets.map { (p.name, "5-hour", $0) }, p.weekResets.map { (p.name, "week", $0) }].compactMap { $0 }
        }
        .filter { $0.2 > now }.sorted { $0.2 < $1.2 }
        return VStack(alignment: .leading, spacing: 4) {
            Text("NEXT RESETS").font(.system(size: 9.5, weight: .bold)).tracking(1.4).foregroundStyle(theme.muted)
            ForEach(Array(items.prefix(3).enumerated()), id: \.offset) { _, it in
                HStack {
                    Text(it.0).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.ink)
                    + Text(" \(it.1)").font(.system(size: 12)).foregroundColor(theme.muted)
                    Spacer()
                    Text(WKit.when(it.2, now: now)).font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.muted)
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
        case .silver: LinearGradient(colors: [Color(white: 0.93), Color(white: 0.84)], startPoint: .top, endPoint: .bottom)
        }
    }
}
