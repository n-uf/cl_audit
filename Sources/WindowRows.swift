// WindowRows: the "MCP settings" and "Scheduled tasks" rows of What happens, for an import and for a restore (ImportPage.swift,
// RestorePage.swift). The rules are SessionsRestoreWindow.swift's: MCP settings are left out unless asked and added only where the
// profile has no claude_desktop_config.json; an import's tasks are left out unless asked, and come paused.

import SwiftUI

private struct RowText {
    let face: FaceTheme
    func value(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(color ?? face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    func small(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    func key(_ show: String, _ hide: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(on.wrappedValue ? hide : show).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(face.muted)
    }
    func lines(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.prefix(60).enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if list.count > 60 { Text("…and \(list.count - 60) more").font(.system(size: 10.5)).foregroundStyle(face.muted) }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }
}

/// The words of the two rows (so a check can read them).
enum WindowWords {
    private static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// "3 MCP servers and the window's other settings", "the window's settings (no MCP servers)" (the file's name is in the row's info)
    static func config(_ cp: SessionsRestore.ConfigPlan) -> String {
        cp.servers.isEmpty ? "the window's settings (no MCP servers)" : n(cp.servers.count + cp.moreServers, "MCP server", "MCP servers") + " and the window's other settings"
    }

    /// The MCP row's value before the run.
    static func configValue(_ cp: SessionsRestore.ConfigPlan, name: String, imported: Bool) -> String {
        if !cp.present { return "not in the \(imported ? "file" : "backup")" + (cp.leftOutAtSource.map { ": \($0.hasPrefix("it ") ? "the file " + $0.dropFirst(3) : $0)" } ?? "") }
        if cp.unreadable { return "the \(imported ? "file" : "backup")'s claude_desktop_config.json can't be read: never added" }
        switch cp.status {
        case .blocked(let why): return "can't be added: \(why)"
        case .here: return "not added: \(name)'s claude_desktop_config.json stays as it is"
        case .new: return config(cp) + (cp.leftOut ? ": left out" : ": added")
        }
    }

    /// The MCP row's value once the run is done (or undone).
    static func configDone(_ cp: SessionsRestore.ConfigPlan, added: Bool, undone: Bool, name: String, imported: Bool, leftByUndo: Bool = false) -> String {
        if undone, added, leftByUndo { return "\(config(cp)): was added; Undo left the file as it is, because the window has changed it since" }
        if undone { return added ? "\(config(cp)): was added, and taken away again" : "none was added" }
        if added { return "added: \(config(cp))" }
        return cp.leftOut || cp.status == .new ? "none added (left out)" : configValue(cp, name: name, imported: imported)
    }

    /// The rest of the file, which adding writes too.
    static func otherKeys(_ cp: SessionsRestore.ConfigPlan) -> String? {
        guard !cp.otherKeys.isEmpty else { return nil }
        return "Also added with it, whole: the window's other settings (\(cp.otherKeys.prefix(6).joined(separator: ", "))\(cp.otherKeys.count > 6 ? ", …" : ""); values not shown)"
    }

    /// What Undo says (SessionsRestore.undo) about a config the window changed since it was added.
    static let configChangedProblem = "claude_desktop_config.json changed since; left as it is."
    /// The done line's note: the window rewrites this file when it opens, so Undo may find it changed.
    static let configUndoNote = "The Claude window may rewrite claude_desktop_config.json when it opens. If it has, Undo leaves the file as it is, with these servers in it: remove them in the window yourself."

    /// The servers a file that is here lacks (nothing is merged into it).
    static func lacking(_ cp: SessionsRestore.ConfigPlan, name: String, imported: Bool) -> String? {
        guard cp.status == .here, !cp.lacking.isEmpty else { return nil }
        let k = cp.lacking.count + cp.moreLacking, it = k == 1 ? "it" : "them"
        return "\(n(k, "server", "servers")) in the \(imported ? "file" : "backup") \(k == 1 ? "isn't" : "aren't") in \(name)'s settings: \(cp.lacking.prefix(5).joined(separator: ", "))\(k > 5 ? ", …" : ""). Nothing is merged into \(name)'s settings: add \(it) in the Claude window yourself if you want \(it)."
    }

    /// The key that shows what the servers run: while the file can't be added, both keys keep the caveat, so the commands never show
    /// without the line saying they won't run (as the setup row's hooks key does).
    static func serversKey(_ cp: SessionsRestore.ConfigPlan, imported: Bool) -> (show: String, hide: String) {
        let whose = imported ? "file" : "backup"
        switch cp.status {
        case .new: return ("What each server runs (the program only: arguments and env values aren't shown)", "Hide what they run")
        case .here: return ("What the \(whose)'s servers would run (not added: your claude_desktop_config.json stays)", "Hide (not added: your claude_desktop_config.json stays)")
        case .blocked: return ("What the \(whose)'s servers would run (not added: it can't be added here)", "Hide (not added: it can't be added here)")
        }
    }

    /// The key of the tasks' list: on an import, how many can't come; on a restore every task comes back with the file, so how many
    /// come without their prompt.
    static func tasksKey(_ notAdded: Int, imported: Bool) -> String {
        guard notAdded > 0 else { return "Show the tasks" }
        return imported ? "Show the tasks (\(notAdded) can't come)" : "Show the tasks (\(notAdded) without the backup's prompt)"
    }

    /// The Scheduled tasks row's value before the run.
    static func tasksValue(_ tp: SessionsRestore.TaskPlan, imported: Bool) -> String {
        let coming = tp.comingCount
        if !imported {
            switch tp.status {
            case .blocked(let why): return "can't come back: \(why)"
            case .here: return "a task file is here: it stays as it is"
            case .new: return tp.writes ? "the task file comes back as it was, not paused (they are this Mac's own tasks)" + (tp.prompts > 0 ? ", with \(n(tp.prompts, "prompt", "prompts"))" : "") : "none"
            }
        }
        switch tp.status {
        case .blocked(let why): return "can't be added: \(why)"
        case .here: return "not added: the task file here stays as it is"
        case .new:
            if coming == 0 { return "none can be added (see the list)" }
            return n(coming, "task", "tasks") + (tp.leftOut ? ": left out" : ": added, paused")
        }
    }

    /// Where the person turns the tasks on (cl_audit never does).
    static func turnOn(_ window: String) -> String {
        "Paused, so a task doesn't run on both Macs. To use one, turn it on with its own switch in Scheduled tasks in \(window). cl_audit never changes a task after this."
    }

    /// The window the tasks are turned on in: "the usual Claude app", "Main's own window (open it from its Dock icon)".
    static func window(_ e: AccountEntry) -> String {
        e.desktop == .standard ? "the usual Claude app" : "\(e.name.isEmpty ? "this profile" : e.name)'s own window (open it from its Dock icon)"
    }

    /// The Scheduled tasks row's value once the import is done (or undone).
    /// `count` and `risky` are of all the tasks added (`added` names the first of them).
    static func tasksDone(_ added: [String], count: Int? = nil, risky: Int = 0, undone: Bool, leftOut: Bool) -> String {
        let k = max(count ?? added.count, added.count)
        if undone { return k == 0 ? "none were added" : "\(n(k, "task was", "tasks were")) added, paused, and taken away again" }
        if k == 0 { return "none added" + (leftOut ? " (left out)" : "") }
        let flagged = risky > 0 ? ", \(risky) with permission checks off or approved permissions" : ""
        return "\(n(k, "task", "tasks")) added, paused\(flagged): \(added.prefix(5).joined(separator: ", "))" + (k > 5 ? ", …" : "")
    }

    /// The tasks that don't come, with why, and (a task file here) the ones it lacks.
    /// The tasks that come with permission checks off or with permissions approved on the other Mac: said in the row's words.
    static func riskyWords(_ tp: SessionsRestore.TaskPlan) -> String? {
        let k = tp.risky
        guard k > 0 else { return nil }
        return "\(n(k, "task runs", "tasks run")) with permission checks off or with permissions approved on the other Mac (see the list): look at \(k == 1 ? "it" : "each") before you turn \(k == 1 ? "it" : "them") on."
    }

    static func taskLines(_ tp: SessionsRestore.TaskPlan) -> [String] {
        // (a task file that is here, or none can be written: no task is listed as if it came)
        // each with its schedule, folder and permission mode: what turning it on would run
        // (with a task file here none is added, so the list is only what that file doesn't have)
        guard tp.status == .new else {
            guard tp.status == .here, !tp.lacking.isEmpty else { return [] }
            return ["The task file here stays as it is. It doesn't have: " + tp.lacking.prefix(10).joined(separator: ", ") + (tp.lacking.count + tp.moreLacking > 10 ? ", …" : "")]
        }
        var out = tp.tasks.map { $0.why == nil ? $0.line : tp.imported ? "\($0.name): not added, \($0.why!)" : "\($0.line): \($0.why!)" }
        if tp.moreTasks > 0 { out.append("…and \(tp.moreTasks) more") }
        return out
    }
}

struct McpRow: View {
    let entry: AccountEntry
    @ObservedObject var runner: RestoreRunner
    var imported: Bool
    var choose: ((Bool) -> Void)? = nil
    @State private var showServers = SetupRow.renderOpen
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }

    var body: some View {
        let t = RowText(face: face)
        if let cp = runner.plan?.config, cp.present || cp.leftOutAtSource != nil {
            SRow(label: "MCP settings", info: "The Claude window's claude_desktop_config.json in the \(imported ? "file" : "backup"), without its sidebar part: its MCP servers and the window's other settings. MCP servers run commands on their own, so they are left out unless you add them. Adding writes the whole file only where \(name) has no claude_desktop_config.json yet: one that is here stays as it is, byte for byte, and nothing is merged into it. Undo takes back exactly what was added.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    let undone = runner.phase == .undone
                    if let r = runner.receipt, undone || runner.phase == .done || runner.phase == .sidebar {
                        t.value(WindowWords.configDone(cp, added: r.configAdded, undone: undone, name: name, imported: imported,
                                                       leftByUndo: r.problems.contains(WindowWords.configChangedProblem)))
                        if !undone, r.configAdded { t.small(WindowWords.configUndoNote) }
                    } else {
                        t.value(WindowWords.configValue(cp, name: name, imported: imported), color: cp.unreadable ? face.caution : nil)
                    }
                    if runner.phase == .ready, cp.present, !cp.unreadable, cp.status == .new, let choose {
                        Menu {
                            Button("Leave them out") { choose(false) }
                            Button("Add them") { choose(true) }
                        } label: { MenuWell(text: cp.leftOut ? "Leave them out" : "Add them", fill: true) }
                        .faceMenuFill()
                    }
                    if !undone, let l = WindowWords.lacking(cp, name: name, imported: imported) { t.small(l, color: face.caution) }
                    if !undone, cp.present, !cp.unreadable, cp.status == .new, let o = WindowWords.otherKeys(cp) { t.small(o) }
                    if !cp.servers.isEmpty {
                        let k = WindowWords.serversKey(cp, imported: imported)
                        t.key(k.show, k.hide, $showServers)
                        if showServers { t.lines(cp.servers.map { "\($0.name): \($0.runs.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" } + (cp.moreServers > 0 ? ["…and \(cp.moreServers) more"] : [])) }
                    }
                }
            }
        }
    }
}

struct TasksRow: View {
    let entry: AccountEntry
    @ObservedObject var runner: RestoreRunner
    var choose: ((Bool) -> Void)? = nil
    @State private var showTasks = SetupRow.renderOpen
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }

    var body: some View {
        let t = RowText(face: face)
        if let tp = runner.plan?.taskPlan, tp.present {
            let imported = tp.imported
            SRow(label: "Scheduled tasks", info: imported
                 ? "The file's scheduled tasks, each with its prompt. Left out unless you add them; added, they come into the folder of the account \(name) works on now, only when that folder has no task file (one that is here stays), and every one paused, so nothing runs twice. A task comes only with its prompt. The sessions a task ran come in with it. Undo takes back exactly what was added."
                 : "The account in use's task file comes back only when none is here, as it was in the backup (its own tasks, not paused), with the prompts that are missing.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    let undone = runner.phase == .undone
                    if imported, let r = runner.receipt, undone || runner.phase == .done || runner.phase == .sidebar {
                        t.value(WindowWords.tasksDone(r.tasksAdded, count: r.tasksAddedCount, risky: r.tasksRisky, undone: undone, leftOut: tp.leftOut))
                        if !undone, !r.tasksAdded.isEmpty { t.small(WindowWords.turnOn(WindowWords.window(entry)), color: face.caution) }
                    } else {
                        t.value(WindowWords.tasksValue(tp, imported: imported))
                        if imported, runner.phase == .ready, tp.status == .new, tp.comingCount > 0, let choose {
                            Menu {
                                Button("Leave them out") { choose(false) }
                                Button("Add them, paused") { choose(true) }
                            } label: { MenuWell(text: tp.leftOut ? "Leave them out" : "Add them, paused", fill: true) }
                            .faceMenuFill()
                        }
                        if imported, !undone, tp.status == .new, tp.comingCount > 0 { t.small((tp.leftOut ? "If added: " : "") + WindowWords.turnOn(WindowWords.window(entry))) }
                        if imported, !undone, tp.status == .new, let w = WindowWords.riskyWords(tp) { t.small(w, color: face.caution) }
                    }
                    let lines = WindowWords.taskLines(tp)
                    if !undone, !lines.isEmpty {
                        let notAdded = tp.status == .new ? tp.tasks.filter { $0.why != nil }.count : 0
                        t.key(WindowWords.tasksKey(notAdded, imported: imported), "Hide the tasks", $showTasks)
                        if showTasks { t.lines(lines) }
                    }
                }
            }
        }
    }
}
