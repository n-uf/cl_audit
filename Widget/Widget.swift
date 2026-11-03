// The cl_audit widget: every profile's 5-hour and weekly limits on the desktop or in Notification Center.
//
// A separate, sandboxed program (an app extension inside cl_audit.app, built by build.sh, not part of Sources/). It only
// reads what the cl_audit agent writes: usage-n-uf/accounts.json for the profile names and status/<id>.json for the
// numbers, through one read-only sandbox exception for that folder. No Keychain, no network, no writing.

import SwiftUI
import WidgetKit
import os

private let log = Logger(subsystem: "local.usage-n-uf", category: "widget")

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

    /// For picking the few with the least room: a full one first, then the fullest.
    func room(now: Date) -> Double {
        if let f = full(now: now) { return -1000 - (f.resets.map { $0.timeIntervalSince(now) / 60 } ?? 100_000) }
        return -max(five ?? 0, week ?? 0)
    }
}

enum AgentFiles {
    /// The real home folder: inside the sandbox NSHomeDirectory() is the widget's own container.
    static var folder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/usage-n-uf")
    }

    private struct Accounts: Decodable { let accounts: [Entry] }
    private struct Entry: Decodable { let id: String; let name: String; let accent: String? }
    private struct Status: Decodable {
        let fiveHour: Double?; let fiveHourResets: Double?; let weekly: Double?; let weeklyResets: Double?
        let updatedAt: Double?; let scoped: [Scoped]?
    }
    private struct Scoped: Decodable { let name: String; let percent: Double? }

    static func load() -> [WidgetProfile] {
        let dec = JSONDecoder()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("accounts.json")),
              let list = try? dec.decode(Accounts.self, from: data) else {
            log.error("widget: can't read the profiles file")
            return []
        }
        let profiles = list.accounts.map { e -> WidgetProfile in
            var p = WidgetProfile(id: e.id, name: e.name, accent: e.accent ?? "orange")
            if let d = try? Data(contentsOf: folder.appendingPathComponent("status/\(e.id).json")),
               let s = try? dec.decode(Status.self, from: d) {
                p.five = s.fiveHour; p.week = s.weekly
                p.fiveResets = s.fiveHourResets.map { Date(timeIntervalSince1970: $0) }
                p.weekResets = s.weeklyResets.map { Date(timeIntervalSince1970: $0) }
                p.updated = s.updatedAt.map { Date(timeIntervalSince1970: $0) }
                p.fable = s.scoped?.first(where: { $0.name == "Fable" })?.percent
            }
            return p
        }
        log.log("widget: read \(profiles.count) profiles")
        return profiles
    }

    static let demo = [
        WidgetProfile(id: "home", name: "Home", accent: "orange", five: 34, fiveResets: Date().addingTimeInterval(6120), week: 57,
                      weekResets: Date().addingTimeInterval(240_000), fable: 7, updated: Date()),
        WidgetProfile(id: "work", name: "Work", accent: "teal", five: 100, fiveResets: Date().addingTimeInterval(6120), week: 64,
                      weekResets: Date().addingTimeInterval(240_000), fable: 30, updated: Date()),
        WidgetProfile(id: "side", name: "Side", accent: "purple", five: 12, fiveResets: Date().addingTimeInterval(9000), week: 20,
                      weekResets: Date().addingTimeInterval(400_000), updated: Date()),
    ]
}

// MARK: timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let profiles: [WidgetProfile]
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: Date(), profiles: AgentFiles.demo) }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let real = AgentFiles.load()
        completion(UsageEntry(date: Date(), profiles: context.isPreview && real.isEmpty ? AgentFiles.demo : real))
    }

    /// The agent's files as they are now; macOS asks again in about five minutes (more rarely when it saves power).
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [UsageEntry(date: now, profiles: AgentFiles.load())],
                            policy: .after(now.addingTimeInterval(5 * 60))))
    }
}

// MARK: views

private func levelColor(_ p: Double?) -> Color {
    guard let p else { return .gray }
    return p >= 80 ? Color(red: 0.94, green: 0.27, blue: 0.27) : p >= 50 ? Color(red: 0.96, green: 0.62, blue: 0.04)
        : Color(red: 0.13, green: 0.77, blue: 0.37)
}

private func profileColor(_ name: String) -> Color {
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

private func pct(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "–" }

/// "back at 15:28" today, else "back Thu 09:00", "back 11 Nov".
private func backWords(_ d: Date, now: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
    let cal = Calendar.current
    if cal.isDate(d, inSameDayAs: now) { f.dateFormat = "HH:mm"; return "back at " + f.string(from: d) }
    f.dateFormat = d.timeIntervalSince(now) < 6 * 86400 ? "EEE HH:mm" : "d MMM"
    return "back " + f.string(from: d)
}

struct Bar: View {
    let p: Double?
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13))
                if let p {
                    Capsule().fill(levelColor(p)).frame(width: max(height, g.size.width * CGFloat(min(max(p, 0), 100)) / 100))
                }
            }
        }
        .frame(height: height)
    }
}

/// One profile: its name, then a bar and % per limit; full, when it's back.
struct ProfileBlock: View {
    let p: WidgetProfile
    let now: Date
    var showFable = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(spacing: 5) {
                Circle().fill(profileColor(p.accent)).frame(width: 6, height: 6)
                Text(p.name).font(.system(size: compact ? 11.5 : 12.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                if let f = p.full(now: now) {
                    Text(f.resets.map { backWords($0, now: now) } ?? "full")
                        .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                        .foregroundStyle(levelColor(100)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            row(compact ? "5h" : "5-hour", p.five)
            row(compact ? "wk" : "Week", p.week)
            if showFable, let fable = p.fable { row("Fable", fable) }
        }
    }

    private func row(_ name: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(name).font(.system(size: compact ? 9.5 : 10.5)).foregroundStyle(.secondary)
                .frame(width: compact ? 16 : 38, alignment: .leading)
            Bar(p: v, height: compact ? 4 : 5)
            Text(pct(v)).font(.system(size: compact ? 9.5 : 10.5, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: compact ? 31 : 34, alignment: .trailing)
        }
    }
}

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let now = entry.date
        let cap = family == .systemSmall ? 2 : family == .systemMedium ? 4 : 8
        // more profiles than fit: the ones with the least room, in the profiles' own order
        let picked = Set(entry.profiles.sorted { $0.room(now: now) < $1.room(now: now) }.prefix(cap).map(\.id))
        let shown = entry.profiles.filter { picked.contains($0.id) }
        Group {
            if shown.isEmpty {
                VStack(spacing: 4) {
                    Text("cl_audit").font(.headline)
                    Text("No profiles yet: open cl_audit to add one.").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if family == .systemMedium {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 10) {
                    ForEach(shown) { ProfileBlock(p: $0, now: now, compact: false) }
                }
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
                    ForEach(shown) { ProfileBlock(p: $0, now: now, showFable: family == .systemLarge, compact: family == .systemSmall) }
                    if family == .systemLarge { Spacer(minLength: 0) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "local.usage-n-uf.limits", provider: UsageProvider()) { UsageWidgetView(entry: $0) }
            .configurationDisplayName("Claude usage")
            .description("Every cl_audit profile's 5-hour and weekly limits, and when a full one is back.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct UsageWidgets: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
