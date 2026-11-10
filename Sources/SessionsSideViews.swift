// SessionsSideViews: the pages' rows for a moved session's side files (SessionsSide.swift).
//
//   SideRows        Import of a move (and Restore of its backup): each kind the file carries as a row with its count and size, on for a
//                   move like its memory (the project MCP servers off until added); once it ran, what was written and what waits for a
//                   folder.
//   SideExportRow   Export ▸ Move to another Mac: what goes in, the keys found in it, Rewind as a row of its own with its size (off).

import SwiftUI

struct SideRows: View {
    @ObservedObject var runner: RestoreRunner
    var undone = false
    var choose: ((SideFiles.Kinds) -> Void)? = nil
    @Environment(\.face) private var face

    private var ran: Bool { runner.phase == .done || runner.phase == .sidebar || runner.phase == .undone }

    var body: some View {
        if let p = runner.sidePlan {
            let k = runner.sideKinds
            // once it ran: what was written and what waits for a folder, kind by kind (not what was planned)
            let r = ran ? runner.sided : nil
            let gone = undone || r?.undone != nil
            let waits = r?.waiting.filter { $0.pick == nil } ?? []
            let waitLines = waits.reduce(0) { $0 + $1.historyLines }
            let waitTrust = Set(waits.flatMap { $0.trust.filter { $0.trusted || !$0.allowedTools.isEmpty }.map(\.key) }).count
            Group {
                if p.taskLists > 0 {
                    row("Task lists", done(k.tasks, r.map { SideWords.after($0.written.taskLists, "task list", "task lists") }) ?? SideWords.row(p.taskLists, "task list", "task lists", bytes: p.taskBytes, on: k.tasks), on: k.tasks) { var n = k; n.tasks = $0; return n }
                }
                if p.plans > 0 {
                    row("Plans", done(k.plans, r.map { SideWords.after($0.written.plans, "plan", "plans") }) ?? SideWords.row(p.plans, "plan", "plans", bytes: p.planBytes, on: k.plans), on: k.plans) { var n = k; n.plans = $0; return n }
                }
                if p.historyLines > 0 {
                    row("Prompt history", done(k.history, r.map { SideWords.after($0.written.historyLines, "typed prompt", "typed prompts", waiting: waitLines) })
                        ?? SideWords.row(p.historyLines, "typed prompt", "typed prompts", bytes: p.historyBytes + p.pasteBytes, on: k.history) + (p.pastes > 0 ? " · \(SideWords.n(p.pastes, "pasted text", "pasted texts"))" : ""),
                        on: k.history, info: "What was typed in these sessions, for the up-arrow in their project. It is added at the end of Claude Code's prompt history file for this profile, each prompt pointed at the session's folder on this Mac, the way Claude Code adds its own so nothing collides, and only while Claude Code isn't running for this profile and its Claude window is closed. A prompt already there isn't added twice. A session whose folder isn't here yet gets its prompts when you pick its folder.") { var n = k; n.history = $0; return n }
                }
                if p.trust > 0 {
                    row("Trust", done(k.trust, r.map { SideWords.after($0.written.trust, "folder", "folders", waiting: waitTrust) })
                        ?? SideWords.n(p.trust, "folder", "folders") + ": " + (k.trust ? "trust and allowed tools added where a folder has none" : "left out (Claude Code asks again)")
                           + (p.tools.isEmpty ? "" : " · allowed tools: " + p.tools.prefix(6).joined(separator: ", ") + (p.tools.count > 6 ? " and \(p.tools.count - 6) more" : "")),
                        on: k.trust,
                        info: "Each project folder's trust and allowed tools from the old Mac. cl_audit adds that folder's entry to Claude Code's settings file for this profile only when it has none (an entry already there wins), changing nothing else in the file, the way Claude Code writes it so nothing collides, and only while Claude Code isn't running here and the window is closed. Never for the top of the disk, /Users or your home folder. Undo takes the entry back while it is still as written.") { var n = k; n.trust = $0; return n }
                }
                if p.mcpServers > 0 {
                    row("Project MCP servers", done(k.mcp, r.map { SideWords.after($0.written.mcp, "folder's servers", "folders' servers") })
                        ?? SideWords.n(p.mcpServers, "server", "servers") + ": " + (k.mcp ? "added with the folder's trust" : "left out"), on: k.mcp,
                        info: "MCP servers a project folder kept in Claude Code's settings (what each runs, with the settings each one needs). Like the window's MCP settings, they are left out unless you add them, and then only with that folder's trust, where it has no entry yet.") { var n = k; n.mcp = $0; return n }
                }
                if p.rewindFiles > 0 {
                    row("Rewind", done(k.rewind, r.map { SideWords.after($0.written.rewind, "copy", "copies") }) ?? SideWords.row(p.rewindFiles, "copy", "copies", bytes: p.rewindBytes, on: k.rewind), on: k.rewind,
                        info: "Rewind's copies of the files these sessions edited, so Rewind can put them back. Its saved paths are pointed at the folder you pick on this Mac, like the rest of the session.") { var n = k; n.rewind = $0; return n }
                } else if p.rewindOnOldMac > 0 {
                    SRow(label: "Rewind", stacked: true) { value("not in the file (\(SideWords.size(p.rewindOnOldMac)) on the old Mac): Rewind starts empty for these sessions") }
                }
                if !p.hits.isEmpty {
                    SRowLine(text: "Keys found on the old Mac: " + p.hits.prefix(4).map { "\($0.what) (\($0.kinds.map(\.words).joined(separator: ", ")))" + ($0.kept ? "" : ": that part is left out") }.joined(separator: "; ")
                             + (p.hits.count > 4 ? "; and \(p.hits.count - 4) more" : "") + ".", color: face.caution)
                }
                ForEach(Array(p.leftOut.prefix(4).enumerated()), id: \.offset) { _, s in SRowLine(text: s, color: face.muted) }
                if p.leftOut.count > 4 { SRowLine(text: "…and \(p.leftOut.count - 4) more left out.", color: face.muted) }
                if gone, r != nil { SRowLine(text: "The side files were added, then taken away by Undo.", color: face.muted) }
                if ran, let note = runner.sideNote { SRowLine(text: note, color: face.caution) }
            }
        }
    }

    /// A row's words once the import ran: nil before (the plan's words show), "left out" for a kind that was off.
    private func done(_ on: Bool, _ words: String?) -> String? {
        guard ran else { return nil }
        if !on { return "left out" }
        if undone || runner.sided?.undone != nil { return "were added, then taken away by Undo" }
        return words ?? "none added"
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ label: String, _ words: String, on: Bool, info: String? = nil, _ set: @escaping (Bool) -> SideFiles.Kinds) -> some View {
        SRow(label: label, info: info, stacked: true) {
            VStack(alignment: .leading, spacing: 6) {
                value(words)
                if let choose, runner.phase == .ready {
                    Menu {
                        Button("Leave them out") { choose(set(false)) }
                        Button("Add them") { choose(set(true)) }
                    } label: { MenuWell(text: on ? "Add them" : "Leave them out", fill: true) }
                    .faceMenuFill()
                }
            }
        }
    }
}

struct SideExportRow: View {
    let preview: SideFiles.Preview?
    let kinds: SideFiles.Kinds
    var counting = false
    var rewind: ((Bool) -> Void)? = nil
    @Environment(\.face) private var face

    var body: some View {
        SRow(label: "Side files", info: "What each moved session keeps beside its conversation: its task list, its plan, the prompts typed in it (the up-arrow history, with pasted text) and its project folder's trust and allowed tools, with the folder's MCP servers (left out on the new Mac until added there). They go into the encrypted disk image only. \(SideWords.notCarried)", stacked: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(counting || preview == nil ? "counting…" : SideWords.carried(preview!, kinds: kinds)).font(.system(size: 12.5)).foregroundStyle(face.soft)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if let p = preview, let note = p.configNote, kinds.trust { Text(note).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true) }
                if let p = preview { ForEach(Array(p.leftOut.prefix(3).enumerated()), id: \.offset) { _, s in Text(s).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true) } }
            }
        }
        SRow(label: "Rewind", info: "Rewind's copies of the files these sessions edited, so Rewind works on the new Mac. They can be hundreds of MB, so a move leaves them out unless you include them; they go into the encrypted disk image only, and Rewind's saved paths are pointed at the folder you pick on the new Mac.", stacked: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(preview.map { SideWords.rewind($0, on: kinds.rewind) } ?? "counting…").font(.system(size: 12.5)).foregroundStyle(face.soft)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                if let rewind, (preview?.rewindFiles ?? 0) > 0 {
                    Menu {
                        Button("Leave them out") { rewind(false) }
                        Button("Include them") { rewind(true) }
                    } label: { MenuWell(text: kinds.rewind ? "Include them" : "Leave them out", fill: true) }
                    .faceMenuFill()
                }
            }
        }
    }
}
