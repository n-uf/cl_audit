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
            Group {
                if p.taskLists > 0 { row("Task lists", SideWords.row(p.taskLists, "session's list", "sessions' lists", bytes: p.taskBytes, on: k.tasks), on: k.tasks) { var n = k; n.tasks = $0; return n } }
                if p.plans > 0 { row("Plans", SideWords.row(p.plans, "plan", "plans", bytes: p.planBytes, on: k.plans), on: k.plans) { var n = k; n.plans = $0; return n } }
                if p.historyLines > 0 {
                    row("Prompt history", SideWords.row(p.historyLines, "line", "lines", bytes: p.historyBytes + p.pasteBytes, on: k.history) + (p.pastes > 0 ? " · \(SideWords.n(p.pastes, "pasted text", "pasted texts"))" : ""),
                        on: k.history, info: "What was typed in these sessions, for the up-arrow in their project. The lines go at the end of this profile's history.jsonl (Claude Code reads it from the end), each pointed at the session's folder on this Mac, under Claude Code's own lock, and only while Claude Code isn't running for this profile and its Claude window is closed. A session whose folder isn't here yet gets them when you pick its folder.") { var n = k; n.history = $0; return n }
                }
                if p.trust > 0 {
                    row("Trust", SideWords.n(p.trust, "folder", "folders") + ": " + (k.trust ? "trusted again, with its allowed tools" : "left out (Claude Code asks again)"), on: k.trust,
                        info: "Each project folder's trust and allowed tools from the old Mac's .claude.json. cl_audit adds that folder's entry to this profile's .claude.json only when it has none (an entry already there wins), changing nothing else in the file, under Claude Code's own lock and only while Claude Code isn't running here and the window is closed. Undo takes the entry back while it is still as written.") { var n = k; n.trust = $0; return n }
                }
                if p.mcpServers > 0 {
                    row("Project MCP servers", SideWords.n(p.mcpServers, "server", "servers") + ": " + (k.mcp ? "added with the folder's trust" : "left out"), on: k.mcp,
                        info: "MCP servers a project folder kept in .claude.json (what each runs, with its env values). Like the window's MCP settings, they are left out unless you add them, and then only with that folder's trust, where it has no entry yet.") { var n = k; n.mcp = $0; return n }
                }
                if p.rewindFiles > 0 {
                    row("Rewind", SideWords.row(p.rewindFiles, "backup", "backups", bytes: p.rewindBytes, on: k.rewind), on: k.rewind,
                        info: "Rewind's copies of the files these sessions edited, so Rewind can put them back. Its saved paths are pointed at the folder you pick, like the rest of the session.") { var n = k; n.rewind = $0; return n }
                } else if p.rewindOnOldMac > 0 {
                    SRow(label: "Rewind", stacked: true) { value("not in the file (\(SideWords.size(p.rewindOnOldMac)) on the old Mac): Rewind starts empty for these sessions") }
                }
                if !p.hits.isEmpty {
                    SRowLine(text: "Keys found on the old Mac: " + p.hits.prefix(4).map { "\($0.what) (\($0.kinds.map(\.words).joined(separator: ", ")))" + ($0.kept ? "" : ": left out") }.joined(separator: "; ") + ".", color: face.caution)
                }
                ForEach(Array(p.leftOut.prefix(4).enumerated()), id: \.offset) { _, s in SRowLine(text: s, color: face.muted) }
                if ran, let r = runner.sided {
                    SRow(label: "Side files", stacked: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            value(undone || r.undone != nil ? "were added, and taken away again" : SideWords.written(r))
                            if let note = runner.sideNote { Text(note).font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                } else if ran, let note = runner.sideNote {
                    SRowLine(text: note, color: face.caution)
                }
            }
        }
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
        SRow(label: "Rewind", info: "Rewind's copies of the files these sessions edited (Claude Code's file-history), so Rewind works on the new Mac. They can be hundreds of MB, so a move leaves them out unless you include them; they go into the encrypted disk image only, and Rewind's saved paths are pointed at the folder you pick there.", stacked: true) {
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
