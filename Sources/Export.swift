// Export: the usage history as a CSV file, for a spreadsheet or a report. One row per day, profile and model (and
// project, when asked), with the replies and each kind of token. Read from the same session files as the charts, for
// the period and the profiles the dashboard shows. Projects are folder names, never full paths.

import AppKit
import UniformTypeIdentifiers

enum UsageExport {
    struct Key: Hashable { let day: String; let profile: String; let model: String; let project: String }
    struct Sum {
        var replies = 0, input = 0, output = 0, write5m = 0, write1h = 0, read = 0, tokens = 0
        var cost = 0.0, priced = false            // at API list prices (Pricing.swift); empty for a model without one
    }

    /// The CSV text. `byProject` adds a project column and splits the rows by it.
    static func csv(_ replies: [Reply], names: [String: String], byProject: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var sums: [Key: Sum] = [:]
        for r in replies {
            let k = Key(day: f.string(from: r.date), profile: names[r.account] ?? r.account, model: r.model,
                        project: byProject ? r.project : "")
            var s = sums[k] ?? Sum()
            s.replies += 1
            s.input += r.input; s.output += r.output
            s.write5m += r.cacheWrite5m; s.write1h += r.cacheWrite1h; s.read += r.cacheRead
            s.tokens += r.tokens
            if let c = Pricing.cost(r) { s.cost += c; s.priced = true }
            sums[k] = s
        }
        let head = ["date", "profile", "model"] + (byProject ? ["project"] : [])
            + ["replies", "input_tokens", "output_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens",
               "cache_read_tokens", "total_tokens", "estimated_cost_usd_at_list_prices"]
        var lines = [head.joined(separator: ",")]
        let keys = sums.keys.sorted { ($0.day, $0.profile, $0.model, $0.project) < ($1.day, $1.profile, $1.model, $1.project) }
        for k in keys {
            let s = sums[k]!
            let text = [k.day, k.profile, k.model] + (byProject ? [k.project] : [])
            let numbers = [s.replies, s.input, s.output, s.write5m, s.write1h, s.read, s.tokens].map(String.init)
                + [s.priced ? String(format: "%.4f", s.cost) : ""]
            lines.append((text.map(field) + numbers).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One text field: quoted when it holds a comma, quote or line break; a leading = + - @ is kept as text, so a
    /// spreadsheet doesn't read a folder name as a formula.
    static func field(_ s: String) -> String {
        var v = s
        if let c = v.first, "=+-@".contains(c) { v = "'" + v }
        guard v.contains(where: { ",\"\n\r".contains($0) }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Asks where to save, then reads the session files for the period and writes the file.
    static func run(range: StatsRange, entries: [AccountEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let day = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
        panel.nameFieldStringValue = "claude-usage-\(range.title.replacingOccurrences(of: " ", with: ""))-\(day).csv"
        panel.title = "Export usage history"
        panel.message = "One row per day, profile and model, for the \(range.title) on the dashboard, from the session files on this Mac."
        let split = NSButton(checkboxWithTitle: "Split by project (folder names only)", target: nil, action: nil)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 34))
        split.frame.origin = NSPoint(x: 14, y: 9); split.sizeToFit()
        box.addSubview(split)
        panel.accessoryView = box
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let byProject = split.state == .on
        let names = Dictionary(entries.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async {
            let text = csv(StatsScanner.replies(for: entries, since: range.since), names: names, byProject: byProject)
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
    }
}
