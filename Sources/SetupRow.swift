// SetupRow: the "Claude Code setup" row of What happens, for an import and for a restore (ImportPage.swift, RestorePage.swift).
// What the backup holds of CLAUDE.md, skills, agents, commands, output styles, keybindings, settings.json (with the commands its hooks
// run), the scripts it points to and the plugin list, each unit New / Already here / Different here: left out unless asked, never
// over or into what is here, never through a link (SessionsRestoreSetup.swift has the rules).

import SwiftUI

struct SetupRow: View {
    let entry: AccountEntry
    @ObservedObject var runner: RestoreRunner
    var imported: Bool
    /// The choice (nil on a page that only shows it).
    var choose: ((Bool) -> Void)? = nil
    /// A render's seam: the list and the hooks open from the start (only a test build has it as a variable).
    #if CL_AUDIT_TESTING
    nonisolated(unsafe) static var renderOpen = false
    #else
    static let renderOpen = false
    #endif
    @State private var showList = SetupRow.renderOpen
    @State private var showHooks = SetupRow.renderOpen
    @Environment(\.face) private var face

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    private func value(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(color ?? face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listKey(_ show: String, _ hide: String, _ on: Binding<Bool>) -> some View {
        Button(on.wrappedValue ? hide : show) { on.wrappedValue.toggle() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize()
    }

    private func lines(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.prefix(60).enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.muted).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if list.count > 60 { Text("…and \(list.count - 60) more").font(.system(size: 10.5)).foregroundStyle(face.muted) }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }

    static func title(_ u: Setup.Unit) -> String {
        switch u.kind {
        case .claude: return "CLAUDE.md"
        case .include: return "included file \(u.name)"
        case .skill: return "skill \(u.name)"
        case .agent: return "agent \(u.name)"
        case .command: return "command \(u.name)"
        case .style: return "output style \(u.name)"
        case .keybindings: return "keybindings.json"
        case .settings: return "settings.json"
        case .script: return "script \(u.name)"
        case .plugins: return "the plugin list"
        case .marketplaces: return "the plugin marketplaces"
        }
    }

    /// "New: skill foo", "Already here: agent x", "Different here: CLAUDE.md, stays as it is".
    private func listLines(_ sp: SessionsRestore.SetupPlan) -> [String] {
        var out: [String] = []
        for (label, status) in [("New", SessionsRestore.SetupPlan.Status.new), ("Already here", .same), ("Different here", .different)] {
            for e in sp.entries(status) { out.append("\(label): \(Self.title(e.unit))" + (e.files > 1 ? " (\(e.files) files)" : "") + (status == .different ? ", stays as it is" : "")) }
        }
        for e in sp.blocked { if case .blocked(let why) = e.status { out.append("Not added: \(Self.title(e.unit)), \(why)") } }
        return out
    }

    var body: some View {
        let p = runner.plan
        let undone = runner.phase == .undone
        let r = runner.receipt
        if let sp = p?.setup, sp.present || !sp.leftOutAtSource.isEmpty {
            SRow(label: "Claude Code setup", info: "CLAUDE.md and what it includes, skills, agents, commands, output styles, keybindings, settings.json with the scripts its hooks point to, and the plugin list, in the \(imported ? "file" : "backup"). Left out unless you add them: \(imported ? "a file can't prove it was made for a move, and hooks run commands on their own" : "a skill missing now was most likely deleted on purpose"). Adding puts back only what is missing here, as new files: nothing that is there is replaced, nothing is written into a skill folder that exists, and nothing through a link. Undo takes back exactly what was added.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    if undone, let r {
                        value(r.setupAdded.isEmpty ? "none were added" : "\(r.setupAdded.count): were added, and taken away again")
                    } else if let r, runner.phase == .done || runner.phase == .sidebar {
                        value(r.setupAdded.isEmpty ? "none added (\(sp.leftOut ? "left out" : "nothing new"))" : "added: \(r.setupAdded.prefix(6).joined(separator: ", "))" + (r.setupAdded.count > 6 ? ", …" : ""))
                    } else if sp.isEmpty {
                        value("nothing the setup could add")
                    } else if sp.leftOut {
                        value("\(Setup.words(sp.counts, extra: sp.extra)): left out")
                    } else {
                        value(sp.newEntries.isEmpty ? "nothing is new here: nothing to add" : "\(Setup.words(sp.newCounts, extra: sp.extra)): added")
                    }
                    if !undone, runner.phase == .ready, !sp.isEmpty, let choose {
                        Menu {
                            Button("Leave them out") { choose(false) }
                            Button("Add them") { choose(true) }
                        } label: { MenuWell(text: sp.leftOut ? "Leave them out" : "Add them", fill: true) }
                        .faceMenuFill()
                        let nw = sp.newEntries.count, same = sp.entries(.same).count, diff = sp.entries(.different).count
                        small("\(nw) new here · \(same) already here · \(diff) different here (stays as it is)" + (sp.blocked.isEmpty ? "" : " · \(sp.blocked.count) can't be added"))
                    }
                    if !undone, !sp.execNames.isEmpty { small("\(n(sp.execNames.count, "script", "scripts")) made executable (owner only), only inside what this adds") }
                    if !undone, !sp.execManual.isEmpty { small("\(n(sp.execManual.count, "script", "scripts")) to make executable yourself: their settings.json isn't added by this", color: face.caution) }
                    if !undone, !sp.settingsDiffer.isEmpty { small("settings.json here differs in \(sp.settingsDiffer.prefix(6).joined(separator: ", ")): it stays as it is", color: face.caution) }
                    ForEach(Array(sp.notes.enumerated()), id: \.offset) { _, s in small(s, color: face.caution) }
                    ForEach(Array(sp.missingPaths.prefix(5).enumerated()), id: \.offset) { _, s in small(s, color: face.caution) }
                    if !sp.leftOutAtSource.isEmpty { small("left out at the source: \(sp.leftOutAtSource.prefix(4).joined(separator: ", "))" + (sp.leftOutAtSource.count > 4 ? ", …" : "")) }
                    if !sp.isEmpty { listKey("Show the list", "Hide the list", $showList); if showList { lines(listLines(sp)) } }
                    if !sp.hooks.isEmpty {
                        listKey("What its hooks and status line run", "Hide what they run", $showHooks)
                        if showHooks { lines(sp.hooks) }
                    }
                }
            }
        } else if p != nil, !imported || runner.manifest.map({ $0.version < 2 }) == true {
            SRow(label: "Claude Code setup", stacked: true) { value("not in this \(imported ? "file" : "backup")") }
        }
    }
}
