// Stats: usage history from the session files Claude Code writes under <settings folder>/projects.
// Every assistant reply records its time, model, token counts, project folder (cwd) and surface
// (entrypoint). Only those fields are read; message text is never kept. Files are re-read only when
// they change, so after the first scan (a few seconds) updates are quick.

import AppKit
import SwiftUI

struct Reply {
    let account: String        // account id
    let date: Date
    let model: String
    let project: String
    let surface: String
    let tokens: Int            // input + cache writes + output (cache reads are left out: they dwarf the rest)
}

enum StatsScanner {
    private struct Cached { let mtime: Date; let size: Int; let replies: [Reply] }
    private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    /// All replies of the given accounts since `since`. Call off the main thread.
    static func replies(for entries: [AccountEntry], since: Date) -> [Reply] {
        var out: [Reply] = []
        let fm = FileManager.default
        for e in entries {
            let projects = URL(fileURLWithPath: Account(e).configDir).appendingPathComponent("projects")
            for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys:
                                [.contentModificationDateKey, .fileSizeKey])) ?? []
                for f in files where f.pathExtension == "jsonl" {
                    guard let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let mtime = v.contentModificationDate, mtime >= since else { continue }
                    let size = v.fileSize ?? 0
                    let key = e.id + "|" + f.path
                    lock.lock(); let hit = cache[key]; lock.unlock()
                    let replies: [Reply]
                    if let hit, hit.mtime == mtime, hit.size == size {
                        replies = hit.replies
                    } else {
                        replies = parse(f, account: e.id)
                        lock.lock(); cache[key] = Cached(mtime: mtime, size: size, replies: replies); lock.unlock()
                    }
                    out.append(contentsOf: replies.lazy.filter { $0.date >= since })
                }
            }
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let assistantTag = Data(#""type":"assistant""#.utf8)

    /// One reply per API response: a response split over several entries shares message.id and usage.
    static func parse(_ url: URL, account: String) -> [Reply] {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        var seen = Set<String>()
        var out: [Reply] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end == data.endIndex ? end : data.index(after: end)
            guard line.range(of: assistantTag) != nil,
                  let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  j["type"] as? String == "assistant",
                  let msg = j["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let ts = j["timestamp"] as? String, let date = iso.date(from: ts) else { continue }
            let model = msg["model"] as? String ?? ""
            if model.hasPrefix("<") { continue }                       // synthetic entries
            let id = (msg["id"] as? String) ?? (j["requestId"] as? String) ?? (j["uuid"] as? String) ?? ts
            if !seen.insert(id).inserted { continue }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            out.append(Reply(account: account, date: date, model: modelName(model),
                             project: projectName(j["cwd"] as? String),
                             surface: surfaceName(j["entrypoint"] as? String),
                             tokens: n("input_tokens") + n("cache_creation_input_tokens") + n("output_tokens")))
        }
        return out
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func modelName(_ id: String) -> String {
        var parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return "Other" }
        let family = parts.removeFirst().capitalized
        let version = parts.filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// The project folder's name; worktrees count as their repository.
    static func projectName(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "Other" }
        let parts = cwd.split(separator: "/").map(String.init)
        var name = parts.last ?? "Other"
        if let i = parts.firstIndex(of: "worktrees"), i + 1 < parts.count { name = parts[i + 1] }
        if let r = name.range(of: "--") { name = String(name[..<r.lowerBound]) }
        return name == NSUserName() ? "~ (home)" : name
    }

    static func surfaceName(_ entry: String?) -> String {
        switch entry {
        case "claude-desktop": return "Desktop Code tab"
        case "claude-vscode": return "VS Code"
        case "cli": return "Terminal"
        case let e? where e.hasPrefix("sdk"): return "SDK apps (T3…)"
        default: return "Other"
        }
    }
}

// MARK: - Aggregates for the charts

enum StatsRange: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var title: String { self == .day ? "24 h" : self == .week ? "7 d" : "30 d" }
    var days: Int { self == .day ? 1 : self == .week ? 7 : 30 }
    /// The first moment shown: midnight `days - 1` days ago (24 h shows today and yesterday by hour).
    var since: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: self == .day ? -1 : -(days - 1), to: today) ?? today
    }
}

struct TokenBar: Identifiable {
    let id = UUID()
    let bucket: Date          // day (or hour for 24 h)
    let account: String
    let tokens: Int
}

struct ShareRow: Identifiable {
    var id: String { name }
    let name: String
    let share: Double         // 0…1 of the tokens in the range
    let color: Color
}

struct Breakdown {
    var projects: [ShareRow] = []
    var models: [ShareRow] = []
    var surfaces: [ShareRow] = []
}

final class StatsModel: ObservableObject {
    // the period, picked on the dashboard and remembered between launches
    @Published var range: StatsRange = DashboardPrefs.shared.range {
        didSet { if DashboardPrefs.shared.range != range { DashboardPrefs.shared.range = range }; reload() }
    }
    @Published var loading = false
    @Published var bars: [TokenBar] = []
    @Published var heat: [[[String: Int]]] = []     // [day row][hour] → replies per account
    @Published var heatDays: [Date] = []
    @Published var breakdown = Breakdown()
    @Published var totalTokens = 0
    @Published var totalReplies = 0
    var accounts: [AccountEntry] = []
    var hidden: Set<String> = []            // accounts the dashboard leaves out
    private var generation = 0

    func color(_ account: String) -> Color {
        guard let e = accounts.first(where: { $0.id == account }) else { return .gray }
        return Color(nsColor: e.accentNSColor)
    }

    func reload() {
        // The accounts change together with the bars (on the main thread, below): a bar for an account the
        // chart doesn't list makes Swift Charts crash.
        let entries = Store.load().filter { !hidden.contains($0.id) }, range = self.range
        generation += 1
        let gen = generation
        loading = true
        DispatchQueue.global(qos: .utility).async {
            let replies = StatsScanner.replies(for: entries, since: range.since)
            let result = Self.aggregate(replies, range: range)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.accounts = entries
                self.bars = result.bars
                self.heat = result.heat
                self.heatDays = result.days
                self.totalTokens = result.tokens
                self.totalReplies = replies.count
                self.breakdown = Breakdown(
                    projects: self.shares(result.byProject, top: 6, palette: nil),
                    models: self.shares(result.byModel, top: 4, palette: [.purple, .blue, .pink, .green]),
                    surfaces: self.shares(result.bySurface, top: 4, palette: [.orange, .blue, .gray, .teal]))
                self.loading = false
            }
        }
    }

    private func shares(_ dict: [String: (Int, String)], top: Int, palette: [Color]?) -> [ShareRow] {
        let total = max(dict.values.map(\.0).reduce(0, +), 1)
        let sorted = dict.sorted { $0.value.0 > $1.value.0 }
        var rows = sorted.prefix(top).enumerated().map { i, kv in
            ShareRow(name: kv.key, share: Double(kv.value.0) / Double(total),
                     color: palette.map { $0[i % $0.count] } ?? color(kv.value.1))
        }
        let rest = sorted.dropFirst(top).map(\.value.0).reduce(0, +)
        if rest > 0 { rows.append(ShareRow(name: "other", share: Double(rest) / Double(total), color: .gray)) }
        return rows
    }

    private struct Result {
        var bars: [TokenBar]; var heat: [[[String: Int]]]; var days: [Date]; var tokens: Int
        var byProject: [String: (Int, String)]; var byModel: [String: (Int, String)]; var bySurface: [String: (Int, String)]
    }

    private static func aggregate(_ replies: [Reply], range: StatsRange) -> Result {
        let cal = Calendar.current
        let start = range.since
        let dayCount = range == .day ? 2 : range.days
        let days = (0..<dayCount).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        var heat = Array(repeating: Array(repeating: [String: Int](), count: 24), count: dayCount)
        var buckets: [String: [Date: Int]] = [:]
        var byProject: [String: (Int, String)] = [:], byModel: [String: (Int, String)] = [:], bySurface: [String: (Int, String)] = [:]
        var tokens = 0
        let barSince = range == .day ? Date().addingTimeInterval(-24 * 3600) : start
        for r in replies {
            let dayIndex = cal.dateComponents([.day], from: start, to: cal.startOfDay(for: r.date)).day ?? -1
            let hour = cal.component(.hour, from: r.date)
            if (0..<dayCount).contains(dayIndex) { heat[dayIndex][hour][r.account, default: 0] += 1 }
            guard r.date >= barSince else { continue }
            let bucket = range == .day
                ? cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: r.date)) ?? r.date
                : cal.startOfDay(for: r.date)
            buckets[r.account, default: [:]][bucket, default: 0] += r.tokens
            tokens += r.tokens
            byProject[r.project, default: (0, r.account)].0 += r.tokens
            byModel[r.model, default: (0, r.account)].0 += r.tokens
            bySurface[r.surface, default: (0, r.account)].0 += r.tokens
        }
        let bars = buckets.flatMap { acc, m in m.map { TokenBar(bucket: $0.key, account: acc, tokens: $0.value) } }
            .sorted { $0.bucket < $1.bucket }
        return Result(bars: bars, heat: heat, days: days, tokens: tokens,
                      byProject: byProject, byModel: byModel, bySurface: bySurface)
    }
}

// MARK: - The launcher's dashboard card

/// The last 7 days in a nutshell (tokens per day per account, totals), for the launcher's dashboard card.
/// Independent of the dashboard's own range; leaves out the accounts the dashboard hides.
final class WeekSummary: ObservableObject {
    struct Part { let account: String; let tokens: Int }
    struct Day: Identifiable { let id: Date; let parts: [Part]; let total: Int }
    struct Result { var days: [Day] = []; var replies = 0; var tokens = 0; var colors: [String: Color] = [:] }

    @Published private(set) var result = Result()
    @Published private(set) var loaded = false
    private var generation = 0

    /// `wait` computes on the spot (for rendering to an image).
    func reload(hidden: Set<String>, wait: Bool = false) {
        let entries = Store.load().filter { !hidden.contains($0.id) }
        if wait { result = Self.compute(entries); loaded = true; return }
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .utility).async {
            let r = Self.compute(entries)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                self.result = r
                self.loaded = true
            }
        }
    }

    static func compute(_ entries: [AccountEntry]) -> Result {
        let since = StatsRange.week.since
        let replies = StatsScanner.replies(for: entries, since: since)
        let cal = Calendar.current
        var byDay: [Date: [String: Int]] = [:]
        for r in replies { byDay[cal.startOfDay(for: r.date), default: [:]][r.account, default: 0] += r.tokens }
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: since) }.map { d -> Day in
            let m = byDay[d] ?? [:]
            let parts = entries.map { Part(account: $0.id, tokens: m[$0.id] ?? 0) }.filter { $0.tokens > 0 }
            return Day(id: d, parts: parts, total: parts.reduce(0) { $0 + $1.tokens })
        }
        var colors: [String: Color] = [:]
        for e in entries { colors[e.id] = Color(nsColor: e.accentNSColor) }   // the dashboard's account colours
        return Result(days: days, replies: replies.count, tokens: days.reduce(0) { $0 + $1.total }, colors: colors)
    }
}

/// Seven tiny stacked bars, one per day, coloured by account.
struct WeekSpark: View {
    let result: WeekSummary.Result
    var height: CGFloat = 26

    var body: some View {
        let top = CGFloat(max(result.days.map(\.total).max() ?? 0, 1))
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(result.days) { d in
                Group {
                    if d.total == 0 {
                        RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.14)).frame(height: 2)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(d.parts, id: \.account) { p in
                                Rectangle().fill(result.colors[p.account] ?? .gray)
                                    .frame(height: max(1, height * CGFloat(p.tokens) / top))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                }
                .frame(width: 6, height: height, alignment: .bottom)
            }
        }
    }
}

/// The launcher's way to the dashboard: this week's tokens and a summary line; click or ⌘D opens it.
struct DashboardCard: View {
    @ObservedObject var week: WeekSummary
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                WeekSpark(result: week.result)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dashboard").font(.system(size: 13, weight: .semibold))
                    Text(week.loaded
                         ? "\(week.result.replies) replies · \(StatsFormat.tokens(week.result.tokens)) tokens · last 7 days"
                         : "Usage history and limits")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Kbd(text: "⌘D")
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hover ? 0.11 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open the dashboard")
    }
}
