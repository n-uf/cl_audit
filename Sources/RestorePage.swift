// RestorePage: restoring a backup of a profile's sessions (Settings ▸ a profile ▸ Sessions ▸ Restore…), from the preview
// to Restored or the way out (RestoreRunner.swift runs it, SessionsRestore.swift writes the files). A sibling of the
// Switch page, with the same building blocks: the line at the top says how far it got, every card stays while it runs.
//
//   Preview      nothing written yet · nothing is ever overwritten: What happens (counted from the backup against what
//                is there now), Stays as it is, Sidebar, Steps
//   Restoring    step 2 of 3 · 52 of 86 back · Stop, keep what's back
//   Restored     86 back · nothing overwritten · 3 listed · Undo this restore, Back to Main's settings
//   Not yet      one thing first · nothing written: a switch that stopped half way, another switch/restore/import, or
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

    private var title: String {
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
            return runner.undoing ? Top(text: "Undoing ●", dim: "· the window closes", tone: .mint) : Top(text: "Restoring ●", dim: "· step 1 of 3 · the window closes", tone: .mint)
        case .undoing: return Top(text: "Undoing ●", dim: "· taking back what it put back", tone: .mint)
        case .writing: return Top(text: "Restoring ●", dim: "· step 2 of 3 · \(runner.progress.done) of \(runner.progress.total) back", tone: .mint)
        case .sidebar:
            if runner.sidebarMissed { return Top(text: "Restored", dim: "· step 3 of 3 · the sidebar session didn't open", tone: .warn) }
            return Top(text: "Restoring ●", dim: "· step 3 of 3 · the sidebar", tone: .mint)
        case .done:
            let listed = (r?.changedCount ?? 0) + (r?.inUseCount ?? 0)
            return Top(text: "Restored", dim: "· \(r?.back ?? 0) back · nothing overwritten" + (listed > 0 ? " · \(listed) listed" : ""), tone: .ok)
        case .stopped:
            let t = r?.planned ?? runner.progress.total
            return Top(text: "Stopped", dim: "· \(r?.back ?? 0) of \(t) back · kept", tone: .amber)
        case .failed: return Top(text: "Stopped", dim: "· nothing written", tone: .warn)
        case .undone:
            let taken = r.map { r in r.steps.filter { $0.done && $0.kind != .dir }.count } ?? 0
            return Top(text: "Undone", dim: "· \(taken) taken away", tone: .normal)
        }
    }

    private func topBar(_ t: Top) -> some View {
        let display = DisplayWindow(text: t.text, dim: t.dim, tone: t.tone, height: 24, size: 10)
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
            Button("Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
        case .done:
            Button("Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .stopped:
            Button("Undo this restore") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            // also with nothing left to write: a restore stopped after its last file is only marked finished
            Button("Finish restoring\(count > 0 ? " \(count)" : "")") { runner.start() }
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

    private var happensCard: some View {
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
                SRow(label: "In use", info: "A Claude Code session is seen by its id on a process's command line (--resume <id>, --session-id <id>). A session resumed from its own picker or with --continue isn't named there, so a missing transcript of such a session is not seen as held and is written back. A transcript that is already there is never written to either way; one changed in the last two minutes is only listed here.", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(held.isEmpty ? "none" : "\(n(held.count, "transcript", "transcripts")) a running Claude Code session holds: left alone, listed")
                        if !held.isEmpty { listKey("Show the list", "Hide the list", $showHeld); if showHeld { names(held) } }
                    }
                }
                if !p.partial.isEmpty {
                    SRow(label: "Partial copy", info: "The file there is the first part of the backup's file: a copy a crash cut short (a copy from another volume isn't made whole in one step). It is left as it is, never completed or replaced; delete it and restore again to bring the whole file back.", stacked: true) {
                        value("\(n(p.partial.count, "file", "files")): the first part of the backup's file, left as it is")
                    }
                }
                if p.deletedSince.count > 0 || (r?.deletedCount ?? 0) > 0 {
                    SRow(label: "Deleted since", stacked: true) {
                        value("\(max(p.deletedSince.count, r?.deletedCount ?? 0)): the window deleted them, so they stay deleted")
                    }
                }
                SRow(label: "Older than \(p.days ?? 30) days", info: "Claude Code deletes its own transcripts after cleanupPeriodDays (\(tilde(CodeCleanup.file(entry.configDir)))). A transcript comes back with its real age, so one older than that would be deleted again.", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(oldWords(p))
                        if p.old > 0, let d = p.days, d < 90, runner.phase == .ready {
                            Button("Keep for 90 days") { runner.keepForDays(90) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                        }
                        if let f = runner.keepFailed { Text(f).font(.system(size: 10.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
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
        if !p.tasks.isEmpty { parts.append("the scheduled tasks file") }
        if !p.files.isEmpty { parts.append(n(p.files.count, "other file", "other files") + " with the transcripts") }
        return p.count == 0 ? "none: everything in the backup is here" : parts.joined(separator: " · ")
    }

    private func whereWords(_ p: SessionsRestore.Plan) -> String {
        var s = "Entries go into \(inUse)'s folder in the window, where \(name) works now; never into the folder of an account it no longer uses."
        if p.otherAccount > 0 { s += " \(n(p.otherAccount, "was", "were")) on another account in the backup: written as a switch would place them." }
        return s
    }

    private func oldWords(_ p: SessionsRestore.Plan) -> String {
        guard p.days != nil else { return "unknown: settings.json doesn't say how long Claude Code keeps them" }
        if p.old == 0 { return "none of the transcripts that come back" }
        return "\(p.old): Claude Code would delete them again. Keep for 90 days first"
    }

    // MARK: Stays as it is, Sidebar

    private var staysCard: some View {
        SCard(title: "Stays as it is", info: "Restore only adds what is missing. The account, the sign-ins, MCP settings and claude.ai are not part of it.") {
            SRow(label: "Account", first: true) { rowValue("\(name) stays on \(inUse): Switch back changes that") }
            SRow(label: "Sign-ins") { rowValue("Never in a backup, never written") }
            SRow(label: "MCP") { rowValue("The window's MCP settings, and settings.json other than Keep for: never touched") }
            SRow(label: "Scheduled tasks") { rowValue("A task file that is there stays as it is; only a missing one comes back") }
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
        case .ready, .undone: return .pending
        case .closing: return i == 1 ? .now : .pending
        case .writing, .undoing: return i == 1 ? .done : i == 2 ? .now : .pending
        case .sidebar: return i < 3 ? .done : runner.sidebarMissed ? .failed : .waiting
        case .done: return i == 3 && sidebarPlanNow?.isEmpty == false && !runner.sidebarOpened ? .waiting : .done
        case .stopped: return i == 1 ? .done : i == 2 ? .waiting : .pending
        case .failed: return i == 1 ? .failed : .pending
        }
    }

    private var stepsCard: some View {
        let w = entry.desktop == .standard ? "The usual Claude app" : "\(name)'s Claude window"
        let back = runner.receipt?.back ?? 0
        let needsWindow = plan?.windowNeeded ?? true
        return SCard(title: "Steps", info: "What restoring does, in order. A receipt in cl_audit's folder keeps what was put back as it goes: if the Mac stops, cl_audit offers to finish it, and Undo this restore takes back exactly that.") {
            VStack(alignment: .leading, spacing: 0) {
                step(1, needsWindow ? (state(1) == .done ? "\(w) closed" : "\(w) closes") : "The window stays as it is",
                     needsWindow ? "Only that window, for about half a minute; your other Claude windows stay open."
                                 : "Nothing in the window comes back, so it needn't close.")
                step(2, undoMode ? "What it put back is taken away" : state(2) == .done ? "What's listed came back" : "What's listed comes back",
                     undoMode ? "Each file is checked against its receipt line first; one that changed since stays."
                     : state(2) == .done && (runner.receipt?.changedCount ?? 0) > 0
                        ? "\(runner.receipt?.changedCount ?? 0) changed since stayed as they were."
                        : "Merged by the rules on the left; nothing overwritten.",
                     check: stepTwoCheck(back))
                step(3, undoMode ? "The window opens again" : state(3) == .done ? "The window is open; the sidebar, as before" : "The window opens; the sidebar, as before",
                     undoMode ? "Only what the receipt names was taken back; anything changed since stays." :
                     sidebarPlanNow?.isEmpty == false ? "Press Return in the session that opens, so the sidebar is arranged as before." : "Nothing to arrange.")
            }
            keys.padding(.top, 8)
            if let line = statusLine { SRowLine(text: line, color: { if case .failed = runner.phase { return face.danger }; return nil }()) }
            if !footnote.isEmpty { SRowLine(text: footnote).padding(.top, 8) }
        }
    }

    private var footnote: String {
        switch runner.phase {
        case .ready: return "It keeps a receipt as it goes, like a switch: if the Mac stops, the next start of cl_audit offers to finish it first."
        case .done, .sidebar: return "Undo this restore takes back exactly what it put back, as Undo does for a switch."
        default: return ""
        }
    }

    private func stepTwoCheck(_ back: Int) -> (String, DisplayWindow.Tone)? {
        switch runner.phase {
        case .writing: return ("\(runner.progress.done) of \(runner.progress.total) · nothing overwritten", .mint)
        case .done, .sidebar: return ("\(back) back · 0 overwritten ✓", .ok)
        case .stopped: return ("\(back) back · kept", .amber)
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
                Text(runner.phase == .closing ? "closing the window…" : runner.phase == .undoing ? "taking back…" : "restoring…").font(.system(size: 12)).foregroundStyle(face.caution)
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
        let needsWindow = plan?.windowNeeded ?? true
        return Button(plan == nil ? "Counting…" : count == 0 && plan?.refusal == nil ? "Nothing to restore" : needsWindow ? "Close and restore \(count)" : "Restore \(count)") { runner.start() }
            .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(!ok)
    }

    // MARK: Not yet: one thing first

    private var firstCard: some View {
        let nyt = runner.notYet
        return SCard(title: "First", info: "A restore waits for what is under way: a switch that stopped half way (Undo puts back exactly what it moved), another switch, restore or import, and claude-transplant while it moves sessions. Nothing is written until then.") {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().stroke(FaceTheme.ledAmber, lineWidth: 1.2)
                    Text("1").font(.system(size: 11, weight: .semibold)).foregroundStyle(FaceTheme.ledAmber)
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(nyt?.title ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text).fixedSize(horizontal: false, vertical: true)
                    Text(nyt?.words ?? "").font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                    if let k = nyt?.switchKey {
                        Button("Open the switch") { model.showSwitch(k) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize().padding(.top, 2)
                    }
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
            SRowLine(text: "One switch, restore or import at a time, and none while claude-transplant is moving sessions.")
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
                Text(detail).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
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
        let open = model.selection == SettingsModel.restoreID && model.restoring == runner.key
        switch runner.phase {
        case .closing, .writing, .undoing, .sidebar:
            TileDisplayGlass(l1: runner.undoing || runner.phase == .undoing ? "Undoing ●" : "Restoring ●", l2: runner.phase == .writing ? "\(runner.progress.done) of \(runner.progress.total)" : "the window", tone: .mint, l1Lit: true) { model.showRestore(runner.key) }
        case .done where open:
            TileDisplayGlass(l1: "Restored", l2: "\(runner.receipt?.back ?? 0) back", tone: .ok) { }
        case .stopped:
            TileDisplayGlass(l1: "Restore stopped", l2: "Finish or undo", tone: .amber) { model.showRestore(runner.key) }
        case .failed where open:
            TileDisplayGlass(l1: "Restore stopped", l2: "nothing written", tone: .warn) { }
        case .ready where open:
            TileDisplayGlass(l1: "Restore from", l2: "a backup", tone: .normal, unlit: true) { }
        default:
            if let u = model.unfinishedRestore(of: entry.id) {
                TileDisplayGlass(l1: "Restore stopped", l2: "Finish or undo", tone: .amber) { model.showRestore(finishing: u) }
            }
        }
    }
}
