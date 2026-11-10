// RestorePage: restoring a backup of a profile's sessions (Settings ▸ a profile ▸ Sessions ▸ Restore…), from the preview
// to Restored or the way out (RestoreRunner.swift runs it, SessionsRestore.swift writes the files). A sibling of the
// Switch page, with the same building blocks: the line at the top says how far it got, every card stays while it runs.
//
//   Preview      nothing written yet · nothing is ever overwritten: What happens (counted from the backup against what
//                is there now), Stays as it is, Sidebar, Steps
//   Restoring    step 2 of 3 · 52 of 86 back · Stop, keep what's back
//   Restored     86 back · nothing overwritten · 3 listed · Undo this restore, Back to Main's settings
//   Not yet      one thing first · nothing written: a restore that stopped half way, another restore/import/move, or
//                claude-transplant moving sessions
//
// Display colours, as on the Switch page: green = in use / done, mint = under way, amber = waiting or a warning, red = failed.

import AppKit
import SwiftUI

struct RestorePage: View {
    let entry: AccountEntry
    let key: RestoreKey
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: RestoreRunner
    var width: CGFloat = 980
    @State private var showChanged = false
    @State private var showHeld = false
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    private var inUse: String { AccountNames.short(entry.seat?.email ?? "its account") }
    private var backupWords: String {
        runner.manifest.map { SessionsBackup.title($0, target: RestoreRunner.targetWord($0, for: entry)) } ?? "a backup"
    }
    private var plan: SessionsRestore.Plan? { runner.plan }
    private var count: Int { plan?.count ?? 0 }
    /// Undo this restore is under way (its window closing, or taking back): the steps say so.
    private var undoMode: Bool { runner.phase == .undoing || (runner.phase == .closing && runner.undoing) }
    private var fromSwitch: Bool { if case .beforeSwitch? = runner.manifest?.kind { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            topBar(topLine)
            SettingsColumns(width: width, groups: [[AnyView(happensCard), AnyView(staysCard), AnyView(sidebarCard)],
                                                  [runner.notYet != nil && runner.phase == .ready ? AnyView(firstCard) : AnyView(stepsCard)]])
        }
        .task(id: key.id) { runner.refresh() }
    }

    /// The backup is an export's, unpacked: this is an import (the same page and steps, other words).
    private var imp: Bool { runner.isImport }
    private var fileWords: String { runner.importFile ?? "a file" }

    private var title: String {
        if imp {
            switch runner.phase {
            case .done, .sidebar: return "Imported into \(name) from \(fileWords)"
            case .undone: return "Undid the import into \(name)"
            default: return "Import into \(name) from \(fileWords)"
            }
        }
        switch runner.phase {
        case .done, .sidebar: return "Restored Claude \(name) from \(backupWords)"
        case .undone: return "Undid the restore of Claude \(name)"
        default: return "Restore Claude \(name) from \(backupWords)"
        }
    }

    // MARK: the line at the top

    private struct Top { var text: String; var dim: String?; var tone: DisplayWindow.Tone }

    private var topLine: Top {
        let r = runner.receipt
        switch runner.phase {
        case .ready:
            if let why = plan?.refusal { _ = why; return Top(text: "Refused", dim: "· nothing written", tone: .warn) }
            if runner.notYet != nil { return Top(text: "Not yet", dim: "· one thing first · nothing written", tone: .amber) }
            return Top(text: "Preview", dim: "· nothing written yet · nothing is ever overwritten", tone: .normal)
        case .closing:
            return runner.undoing ? Top(text: "Undoing ●", dim: "· the window closes", tone: .mint) : Top(text: imp ? "Importing ●" : "Restoring ●", dim: "· step 1 of 3 · the window closes", tone: .mint)
        case .undoing: return Top(text: "Undoing ●", dim: "· taking back what it put back", tone: .mint)
        case .writing: return Top(text: imp ? "Importing ●" : "Restoring ●", dim: "· step 2 of 3 · \(runner.progress.done) of \(runner.progress.total) \(imp ? "files added" : "back")", tone: .mint)
        case .sidebar:
            if runner.sidebarMissed { return Top(text: imp ? "Imported" : "Restored", dim: "· step 3 of 3 · the sidebar session didn't open", tone: .warn) }
            return Top(text: imp ? "Importing ●" : "Restoring ●", dim: "· step 3 of 3 · the sidebar", tone: .mint)
        case .done:
            // an Undo that left restored transcripts a session holds: said from the receipt, so it survives a relaunch
            if let r, r.undone == nil, r.undoLeft > 0 { return Top(text: "Partly undone", dim: "· \(r.undoLeft) left · Undo again once the session has ended", tone: .amber) }
            let listed = (r?.changedCount ?? 0) + (r?.inUseCount ?? 0)
            let added = ImportWords.counts(sessions: r?.sessionsAdded ?? 0, entries: r?.entriesAdded ?? 0) ?? "\(r?.back ?? 0) files"
            return Top(text: imp ? "Imported" : "Restored", dim: "· " + (imp ? "\(added) added" : "\(r?.back ?? 0) back") + " · nothing overwritten" + (listed > 0 ? " · \(listed) listed" : "")
                       + ((r?.unchecked ?? 0) > 0 ? " · \(r?.unchecked ?? 0) not checked" : ""), tone: (r?.unchecked ?? 0) > 0 ? .amber : .ok)
        case .stopped:
            let t = r?.planned ?? runner.progress.total
            return Top(text: "Stopped", dim: "· \(r?.back ?? 0) of \(t) \(imp ? "files added" : "back") · kept", tone: .amber)
        case .failed: return Top(text: "Stopped", dim: "· nothing written", tone: .warn)
        case .undone:
            let taken = r.map { r in r.steps.filter { $0.done && $0.kind != .dir }.count } ?? 0
            let what = imp ? ImportWords.counts(sessions: r?.sessionsAdded ?? 0, entries: r?.entriesAdded ?? 0).map { " (\($0))" } ?? "" : ""
            return Top(text: "Undone", dim: "· \(taken)\(imp ? (taken == 1 ? " file" : " files") : "") taken away\(what)", tone: .normal)
        }
    }

    private func topBar(_ t: Top) -> some View {
        let display = DisplayWindow(text: t.text, dim: DisplayWindow.narrowed(t.dim, width: width), tone: t.tone, height: 24, size: 10)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { display; Spacer(minLength: 6); topKeys }
            VStack(alignment: .leading, spacing: 8) { display; HStack(spacing: 10) { topKeys } }
            VStack(alignment: .leading, spacing: 8) { display; VStack(alignment: .leading, spacing: 8) { topKeys } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var topKeys: some View {
        switch runner.phase {
        case .closing:
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .writing:
            Button("Stop, keep what's back") { runner.stop() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .undoing:
            EmptyView()
        case .sidebar:
            Button(imp ? "Undo this import" : "Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
        case .done:
            Button(imp ? "Undo this import" : "Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .stopped:
            Button(imp ? "Undo this import" : "Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            // also with nothing left to write: a restore stopped after its last file is only marked finished
            Button("Finish \(imp ? "importing" : "restoring")\(count > 0 ? " \(count)" : "")") { runner.start() }
                .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(plan == nil || runner.notYet != nil)
        case .undone:
            Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .ready, .failed:
            EmptyView()
        }
    }

    // MARK: What happens: counted from the backup against what is there now

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func names(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.prefix(40).enumerated()), id: \.offset) { _, s in
                Text(Self.shortName(s)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.muted)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            if list.count > 40 { Text("…and \(list.count - 40) more").font(.system(size: 10.5)).foregroundStyle(face.muted) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }

    /// "local_<uuid>.json" as "session 0123abcd" (no title is ever read); a transcript by its path.
    static func shortName(_ s: String) -> String {
        if s.hasPrefix("local_"), s.hasSuffix(".json") { return "session " + s.dropFirst("local_".count).prefix(8) }
        return s
    }

    @ViewBuilder private var happensCard: some View {
        if imp { ImportHappens(entry: entry, runner: runner, addMemory: key.addMemory) } else { restoreHappensCard }
    }

    private var restoreHappensCard: some View {
        // while running or done, the lists are the receipt's (what was found when the run started)
        let r = runner.receipt
        let changed = r?.changed ?? plan?.changed ?? []
        let held = r?.inUse ?? plan?.inUse ?? []
        return SCard(title: "What happens", info: "Counted from the backup against what is there now, by session id across every account folder of the window's Code-tab list (and transcripts by their path under \(entry.configDir)/projects). Restore merges: it only writes what is missing, and nothing that is there is ever overwritten, deleted or moved.") {
            if let why = plan?.refusal {
                SRow(label: "Refused", first: true, stacked: true) { Text(why).font(.system(size: 12.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
            } else if let p = plan {
                SRow(label: "Back where it was", first: true, stacked: true) {
                    value("\(n(p.backEntries, "entry", "entries"))\(fromSwitch ? " the switch moved" : ""), unchanged since · \(n(p.backTranscripts, "transcript", "transcripts")) (nothing to do)")
                }
                SRow(label: "Missing, restored", stacked: true) {
                    value(missingWords(p))
                }
                if !p.entries.isEmpty || !p.tasks.isEmpty {
                    SRowLine(text: whereWords(p))
                }
                SRow(label: "Made after it", stacked: true) {
                    value(p.madeAfter == 0 ? "none" : "\(n(p.madeAfter, "session", "sessions"))\(p.madeAfterHere == p.madeAfter ? " on \(inUse)" : ""): kept")
                }
                SRow(label: "Changed since", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(changed.isEmpty ? "none" : "\(changed.count): this copy kept, listed (never overwritten)")
                        if !changed.isEmpty { listKey("Show the list", "Hide the list", $showChanged); if showChanged { names(changed) } }
                    }
                }
                SetupRow(entry: entry, runner: runner, imported: false, choose: { runner.setSetup($0) })
                // (this Mac's own backups keep no MCP settings: the row shows only for a backup an import staged; Stays as it is says why)
                McpRow(entry: entry, runner: runner, imported: false, choose: { runner.setConfig($0) })
                TasksRow(entry: entry, runner: runner, choose: nil)
                SRow(label: "In use", info: "A Claude Code session is seen by its id on a process's command line (--resume <id>, --session-id <id>). A session resumed from its own picker or with --continue isn't named there, so a missing transcript of such a session is not seen as held and is written back. A transcript that is already there is never written to either way; one changed in the last two minutes is only listed here.", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(held.isEmpty ? "none" : "\(n(held.count, "transcript", "transcripts")) a running Claude Code session holds: left alone, listed")
                        if !held.isEmpty { listKey("Show the list", "Hide the list", $showHeld); if showHeld { names(held) } }
                    }
                }
                if !p.partial.isEmpty || (r?.partialCount ?? 0) > 0 {
                    SRow(label: "Shorter copy", info: "The file there is a shorter copy of the backup's file: the backup's file begins with it. A crash during a copy from another volume leaves that, but it can't be told what cut it short. It is left as it is, never completed or replaced; delete it and restore again to bring the whole file back.", stacked: true) {
                        value("\(n(max(p.partial.count, r?.partialCount ?? 0), "file", "files")): a shorter copy of the backup's file, left as it is")
                    }
                }
                if p.deletedSince.count > 0 || (r?.deletedCount ?? 0) > 0 {
                    SRow(label: "Deleted since", stacked: true) {
                        value("\(max(p.deletedSince.count, r?.deletedCount ?? 0)): the window deleted them, so they stay deleted")
                    }
                }
                if p.showsWouldDelete {
                    SRow(label: "Would be deleted", info: p.retention.wouldDeleteInfo(file: tilde(CodeCleanup.file(entry.configDir)), comes: "comes back"), stacked: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            value(p.wouldDeleteWords)
                            if p.canKeepLonger, runner.phase == .ready {
                                Button("Keep for 90 days") { runner.keepForDays(90) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                            }
                            if let f = runner.keepFailed { Text(f).font(.system(size: 10.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                ForEach(Array(p.notes.enumerated()), id: \.offset) { _, s in SRowLine(text: s, color: face.caution) }
            } else {
                SRow(label: "What happens", first: true, stacked: true) { value("counting…") }
            }
        }
    }

    private func listKey(_ show: String, _ hide: String, _ on: Binding<Bool>) -> some View {
        Button(on.wrappedValue ? hide : show) { on.wrappedValue.toggle() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize()
    }

    private func missingWords(_ p: SessionsRestore.Plan) -> String {
        var parts: [String] = []
        parts.append(n(p.entries.count, "entry", "entries"))
        parts.append(n(p.transcripts.count, "transcript", "transcripts"))
        if !p.tasks.isEmpty { parts.append("the scheduled tasks file" + (p.taskPrompts.isEmpty ? "" : " with \(n(p.taskPrompts.count, "prompt", "prompts"))")) }
        if !p.configPieces.isEmpty { parts.append("the window's MCP settings") }
        if !p.files.isEmpty { parts.append(n(p.files.count, "other file", "other files") + " with the transcripts") }
        return p.count == 0 ? "none: everything in the backup is here" : parts.joined(separator: " · ")
    }

    private func whereWords(_ p: SessionsRestore.Plan) -> String {
        var s = "Entries go into \(entry.windowDataWords), in \(inUse)'s folder, where \(name) works now; never into the folder of an account it no longer uses. Open it from \(entry.desktop == .standard ? "the Dock or Applications" : "\(name)'s Dock icon")."
        if p.otherAccount > 0 { s += " \(n(p.otherAccount, "was", "were")) on another account in the backup: written without their old account's error marks and Remote Control ids." }
        return s
    }

    // MARK: Stays as it is, Sidebar

    private var staysCard: some View {
        SCard(title: "Stays as it is", info: "Restore only adds what is missing. The account, the sign-ins and claude.ai are not part of it; a file that is here (MCP settings, settings.json, a task file) is never replaced or merged into.") {
            SRow(label: "Account", first: true) { rowValue("\(name) stays on \(inUse): a switch changes that") }
            SRow(label: "Sign-ins") { rowValue(imp ? "Never in an export, never written" : "Never in a backup, never written") }
            SRow(label: "MCP") { rowValue(imp ? "Yours stay; the file's are added only if none is here and you pick Add them"
                                          : "Not in this Mac's backups: the window's MCP settings travel only in the encrypted export. Yours stay as they are") }
            SRow(label: "settings.json") { rowValue("Yours stay; one is added only if none is here and you pick Add them") }
            SRow(label: "Scheduled tasks") { rowValue(imp ? "A task file that is here stays as it is; the file's tasks come only if you picked Add them, paused" : "A task file that is there stays as it is; only a missing one comes back") }
            SRow(label: "claude.ai") { rowValue("Chats and Projects") }
        }
    }

    private func rowValue(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sidebarPlanNow: SidebarPlan? { runner.receipt?.sidebar ?? plan?.sidebar }

    private var sidebarCard: some View {
        SCard(title: "Sidebar", info: "The window keeps its sidebar's groups, order and pins per account, and claude.ai syncs them. The backup has the window's own records of them. Restored sessions come back ungrouped; one Return in a helper session puts them in their groups and pins them again, with the app's own sidebar tools.") {
            SRow(label: "Arrangement", first: true, stacked: true) { value(arrangementWords) }
            SRow(label: "Window's cache", stacked: true) { value("off: claude.ai's copy wins at sign-in") }
        }
    }

    private var arrangementWords: String {
        guard plan != nil else { return "counting…" }
        if imp { return ImportWords.arrangement(sidebarPlanNow, hasEntries: plan?.entries.isEmpty == false) }
        guard let p = sidebarPlanNow, !p.isEmpty else {
            return plan?.entries.isEmpty == false ? "Nothing to arrange: none of the restored sessions sat in a group or was pinned" : "Nothing to arrange: no session comes back"
        }
        var what: [String] = []
        if p.filed > 0 { what.append("\(n(p.filed, "session goes", "sessions go")) back in \(n(p.groups.count, "group", "groups"))") }
        if !p.pinned.isEmpty { what.append("\(n(p.pinned.count, "session is", "sessions are")) pinned again") }
        return "From the backup's sidebar records: \(what.joined(separator: "; ")). One Return in the helper session."
    }

    // MARK: Steps

    private enum StepState { case pending, now, waiting, done, failed }

    private func state(_ i: Int) -> StepState {
        switch runner.phase {
        case .ready: return .pending
        case .undone: return .done                                   // what the Undo did, as done steps
        case .closing: return i == 1 ? .now : .pending
        case .writing, .undoing: return i == 1 ? .done : i == 2 ? .now : .pending
        case .sidebar: return i < 3 ? .done : runner.sidebarMissed ? .failed : .waiting
        case .done: return i == 3 && sidebarPlanNow?.isEmpty == false && !runner.sidebarOpened ? .waiting : .done
        case .stopped: return i == 1 ? .done : i == 2 ? .waiting : .pending
        case .failed: return i == 1 ? .failed : .pending
        }
    }

    private var stepsCard: some View {
        let w = entry.windowWordsCap
        let back = runner.receipt?.back ?? 0
        let undoneNow = runner.phase == .undone
        // after an Undo the plan is the old one (or none): the receipt says whether window files were among what it took away
        let needsWindow = undoneNow ? (runner.receipt?.steps.contains { $0.inWindow } ?? true) : (plan.map { _ in runner.closesWindow } ?? true)
        // (the window closes only for a picked folder: that session's Code-tab entry changes)
        let forPicks = !undoneNow && !(plan?.windowNeeded ?? true) && runner.windowForPicks
        let verb = imp ? "added" : "put back"
        let grown = runner.receipt?.changedCount ?? 0
        return SCard(title: "Steps", info: "What \(imp ? "importing" : "restoring") does, in order. A receipt in cl_audit's folder keeps what was \(verb) as it goes: if the Mac stops, cl_audit offers to finish it, and Undo this \(imp ? "import" : "restore") takes back exactly that.") {
            VStack(alignment: .leading, spacing: 0) {
                step(1, needsWindow ? (state(1) == .done ? "\(w) closed" : "\(w) closes") : "The window stays as it is",
                     forPicks ? "Only that window, for about half a minute (a picked folder changes the session's Code-tab entry)."
                     : needsWindow ? "Only that window, for about half a minute; your other Claude windows stay open."
                                 : "Nothing in the window \(imp ? "comes in" : "comes back"), so it needn't close.")
                step(2, undoMode ? "What it \(verb) is taken away" : undoneNow ? "What it \(verb) was taken away"
                        : state(2) == .done ? (imp ? "What's listed was added" : "What's listed came back") : (imp ? "What's listed is added" : "What's listed comes back"),
                     undoMode ? "Each file is checked against its receipt line first; one that changed since stays."
                     : undoneNow ? (imp ? (ImportWords.counts(sessions: runner.receipt?.sessionsAdded ?? 0, entries: runner.receipt?.entriesAdded ?? 0).map { "\($0) taken away. " } ?? "") : "")
                                    + "Each file was checked against its receipt line first; one that changed since stayed."
                     : state(2) == .done && grown > 0
                        ? (imp ? "\(grown) grown on both sides: \(name)'s copy stayed as it was." : "\(grown) changed since stayed as they were.")
                        : "Merged by the rules on the left; nothing overwritten.",
                     check: stepTwoCheck(back))
                step(3, undoMode ? "The window opens again" : undoneNow ? (needsWindow ? "The window is open again" : "The window stayed as it was") : state(3) == .done ? "The window is open; the sidebar, as before" : "The window opens; the sidebar, as before",
                     undoMode ? "Only what the receipt names was taken back; anything changed since stays."
                     : undoneNow ? ""            // (step 2 has said what was taken away: nothing is repeated here)
                     : sidebarPlanNow?.isEmpty == false ? "Press Return in the session that opens, so the sidebar is arranged as before." : "Nothing to arrange.")
            }
            keys.padding(.top, 8)
            if let line = statusLine { SRowLine(text: line, color: { if case .failed = runner.phase { return face.danger }; return nil }()) }
            if !footnote.isEmpty { SRowLine(text: footnote).padding(.top, 8) }
        }
    }

    private var footnote: String {
        switch runner.phase {
        case .ready: return "It keeps a receipt as it goes: if the Mac stops, the next start of cl_audit offers to finish it first."
        case .done, .sidebar: return imp ? "Undo this import takes back exactly what it added; Undo last import, under \(name)'s Sessions, does the same later."
                                          : "Undo this restore takes back exactly what it put back."
        default: return ""
        }
    }

    private func stepTwoCheck(_ back: Int) -> (String, DisplayWindow.Tone)? {
        // an import's sessions and entries are named each, never both called "sessions"; files are files
        let r = runner.receipt
        let added = imp ? (ImportWords.counts(sessions: r?.sessionsAdded ?? 0, entries: r?.entriesAdded ?? 0) ?? "\(back) \(back == 1 ? "file" : "files")") : "\(back)"
        switch runner.phase {
        case .writing: return ("\(runner.progress.done) of \(runner.progress.total)\(imp ? " files" : "") · nothing overwritten", .mint)
        // (short: a display never wraps, and one wider than the column pushes its card out of it; "nothing overwritten" is said above)
        case .done, .sidebar: return (imp ? "\(added) added ✓" : "\(back) back · 0 overwritten ✓", .ok)
        case .stopped: return (imp ? "\(back) \(back == 1 ? "file" : "files") added · kept" : "\(back) back · kept", .amber)
        case .undone:
            let taken = r.map { r in r.steps.filter { $0.done && $0.kind != .dir }.count } ?? 0
            return (imp ? "\(taken) \(taken == 1 ? "file" : "files") taken away ✓" : "\(taken) taken away ✓", .ok)
        default: return nil
        }
    }

    private var statusLine: String? {
        switch runner.phase {
        case .failed(let why): return why
        case .stopped(let why): return runner.note == nil || runner.note == why ? why : "\(why) \(runner.note ?? "")"
        default: return runner.note
        }
    }

    @ViewBuilder private var keys: some View {
        HStack(spacing: 10) {
            switch runner.phase {
            case .ready, .failed:
                Button("Back") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                restoreKey
            case .closing, .writing, .undoing:
                Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true)).disabled(runner.phase != .closing)
                Spacer(minLength: 6)
                Text(runner.phase == .closing ? "closing the window…" : runner.phase == .undoing ? "taking back…" : imp ? "importing…" : "restoring…").font(.system(size: 12)).foregroundStyle(face.caution)
            case .sidebar:
                Spacer(minLength: 6)
                Button(runner.sidebarOpened ? "Open it again" : "Open the session") { runner.arrangeSidebar() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Done") { runner.finishPage() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            case .done:
                if sidebarPlanNow?.isEmpty == false, !runner.sidebarOpened {
                    Spacer(minLength: 6)
                    Button("Arrange the sidebar…") { runner.arrangeSidebar() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                }
            case .stopped, .undone:
                EmptyView()
            }
        }
    }

    private var restoreKey: some View {
        let ok = plan != nil && plan?.refusal == nil && count > 0 && runner.notYet == nil
        let needsWindow = plan.map { _ in runner.closesWindow } ?? true
        let verb = imp ? "import" : "restore"
        return Button(plan == nil ? "Counting…" : count == 0 && plan?.refusal == nil ? "Nothing to \(verb)" : needsWindow ? "Close and \(verb) \(count)" : "\(verb.capitalized) \(count)") { runner.start() }
            .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(!ok)
    }

    // MARK: Not yet: one thing first

    private var firstCard: some View {
        let nyt = runner.notYet
        return SCard(title: "First", info: "A restore waits for what is under way: a restore that stopped half way, another restore, import or move, and claude-transplant while it moves sessions. Nothing is written until then.") {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().stroke(FaceTheme.ledAmber, lineWidth: 1.2)
                    Text("1").font(.system(size: 11, weight: .semibold)).foregroundStyle(FaceTheme.ledAmber)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nyt?.title ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text).fixedSize(horizontal: false, vertical: true)
                    Text(nyt?.words ?? "").font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button("Back") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                restoreKey
            }
            .padding(.top, 8)
            SRowLine(text: "One restore, import or move at a time, and none while claude-transplant is moving sessions.")
        }
    }

    // MARK: a step

    private func step(_ i: Int, _ title: String, _ detail: String, check: (String, DisplayWindow.Tone)? = nil) -> some View {
        let s = state(i)
        let ring: Color = {
            switch s {
            case .now: return FaceTheme.mint
            case .waiting: return FaceTheme.ledAmber
            case .done: return FaceTheme.ledOn
            case .failed: return FaceTheme.ledRed
            case .pending: return face.muted.opacity(0.6)
            }
        }()
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().stroke(ring, lineWidth: 1.2)
                switch s {
                case .done:
                    Circle().fill(FaceTheme.ledOn)
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                case .failed:
                    Circle().fill(FaceTheme.ledRed)
                    Image(systemName: "exclamationmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.75))
                default:
                    Text("\(i)").font(.system(size: 11, weight: .semibold)).foregroundStyle(s == .pending ? face.muted : ring)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(s == .failed ? face.danger : face.text)
                if !detail.isEmpty { Text(detail).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true) }
                if let check { DisplayWindow(text: check.0, tone: check.1, height: 18, size: 9) }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Beside a profile's tile while a restore of it runs, its page is open, or one stopped half way (SwitchView.swift's
/// SwitchTileDisplay chooses): "Restoring ● / 52 of 86", "Restored / 86 back", amber "Restore stopped / Finish or undo".
struct RestoreTileDisplay: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: RestoreRunner

    var body: some View {
        let open = (model.selection == SettingsModel.restoreID && model.restoring == runner.key) || (model.selection == SettingsModel.importID && model.restoring == runner.key)
        let imp = runner.isImport
        switch runner.phase {
        case .closing, .writing, .undoing, .sidebar:
            TileDisplayGlass(l1: runner.undoing || runner.phase == .undoing ? "Undoing ●" : imp ? "Importing ●" : "Restoring ●", l2: runner.phase == .writing ? "\(runner.progress.done) of \(runner.progress.total)" : "the window", tone: .mint, l1Lit: true) { model.showRestore(runner.key) }
        case .done where open:
            TileDisplayGlass(l1: imp ? "Imported" : "Restored", l2: imp ? "\(runner.receipt?.back ?? 0) files" : "\(runner.receipt?.back ?? 0) back", tone: .ok) { }
        case .stopped:
            TileDisplayGlass(l1: imp ? "Import stopped" : "Restore stopped", l2: "Finish or undo", tone: .amber) { model.showRestore(runner.key) }
        case .failed where open:
            TileDisplayGlass(l1: imp ? "Import stopped" : "Restore stopped", l2: "nothing written", tone: .warn) { }
        case .ready where open:
            TileDisplayGlass(l1: imp ? "Import from" : "Restore from", l2: imp ? "a file" : "a backup", tone: .normal, unlit: true) { }
        default:
            if let u = model.unfinishedRestore(of: entry.id) {
                TileDisplayGlass(l1: u.importedFrom != nil ? "Import stopped" : "Restore stopped", l2: "Finish or undo", tone: .amber) { model.showRestore(finishing: u) }
            }
        }
    }
}
