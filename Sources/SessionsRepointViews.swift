// SessionsRepointViews: the pages' parts for a moved session's folder and code (SessionsRepoint.swift, CodeChecklist.swift).
//
//   FoldersRow        Import (and Restore of an imported backup): the sessions whose folder isn't on this Mac, each with "Pick its folder on
//                     this Mac…"; the picks are re-pointed right after the import. Once it ran: what each re-point did.
//   CodeCard          Import of a move: the code checklist per project (clone source, path, branch, what wasn't pushed or committed on the
//                     old Mac) with the commands as text to copy. cl_audit never runs git on this Mac.
//   MissingFoldersRow Settings ▸ a profile ▸ Sessions: imported sessions whose folder isn't on this Mac, each with "Pick its folder…", so the
//                     code can be cloned first and the session pointed at it afterwards. The Code-tab entry is written with the window
//                     closed: the same quit (only that window) and reopen as a restore, through RepointRunner. Undo takes back the last.

import AppKit
import SwiftUI

// MARK: - Import: Folder not here

struct FoldersRow: View {
    let entry: AccountEntry
    @ObservedObject var runner: RestoreRunner
    var undone = false
    @Environment(\.face) private var face

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
    private var ran: Bool { runner.phase == .done || runner.phase == .sidebar || runner.phase == .undone }

    var body: some View {
        SRow(label: "Folder not here", info: "Claude Code files a session under the folder it ran in, and the Code tab runs it there. A session whose folder isn't on this Mac (not cloned yet, or cloned somewhere else) is added anyway; pick where its folder is on this Mac and the session is pointed there right after the import: its transcript moves under that folder's name, the folder paths in its lines and in its Code-tab entry are rewritten (nothing else), and a worktree that isn't here is dropped so it runs in the project folder. Undo this import takes that back too. You can also leave it and pick later, once the code is here, under the profile's Sessions.", stacked: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(runner.folderSessions.prefix(40)) { s in item(s) }
                if runner.folderSessions.count > 40 { line("…and \(runner.folderSessions.count - 40) more: pick them later under \(entry.name)'s Sessions.") }
                if let nt = runner.repointNote { line(nt, face.caution) }
            }
        }
    }

    private var summary: String {
        let k = runner.folderSessions.count
        if k == 0 { return runner.foldersMissing == 0 ? "none: each session's folder is on this Mac" : "\(runner.foldersMissing): added, shown once that folder exists" }
        if undone { return "\(n(k, "session", "sessions")) whose folder wasn't here: were added, and taken away again" }
        if ran {
            let moved = runner.repointed?.sessions.filter { !$0.undone }.count ?? 0
            return moved == 0 ? "\(k): added; pick each one's folder later under \(entry.name)'s Sessions" : "\(k): \(moved) pointed at the folder you picked" + (k > moved ? "; the rest: pick later under \(entry.name)'s Sessions" : "")
        }
        let picked = runner.picks.count
        return "\(n(k, "session", "sessions")) whose folder isn't on this Mac: added anyway" + (picked > 0 ? "; \(picked) will be pointed at the folder you picked" : ". Pick where each one's folder is here, or later under Sessions")
    }

    private func item(_ s: SessionsRepoint.Session) -> some View {
        let done = runner.repointed?.sessions.first { $0.session == s.id && !$0.undone }
        return VStack(alignment: .leading, spacing: 3) {
            Text(RepointWords.title(s)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(face.text).lineLimit(1).truncationMode(.tail)
            line("was in \(tilde(s.folder))" + (s.worktree.map { " · worktree \(($0 as NSString).lastPathComponent)" } ?? ""))
            if let d = done {
                line(RepointWords.done(d), face.soft)
            } else if let p = runner.picks[s.id] {
                line("→ \(tilde(p))" + (ran ? "" : ": pointed there when it is imported"), face.soft)
                if runner.phase == .ready {
                    HStack(spacing: 8) {
                        Button("Change…") { runner.pickFolder(s.id) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                        Button("Leave it") { runner.setPick(s.id, nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(face.muted).fixedSize()
                    }
                }
            } else if runner.phase == .ready {
                Button("Pick its folder on this Mac…") { runner.pickFolder(s.id) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }

    private func line(_ s: String, _ color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Import: the code checklist

struct CodeCard: View {
    let list: CodeChecklist.File
    @Environment(\.face) private var face

    var body: some View {
        SCard(title: "Code", info: "A move carries the sessions, not the code they ran in. On the old Mac, cl_audit read each project with read-only git: where to clone it from (any user name, password or token taken out of the address), the branch and last commit, and how many commits weren't pushed and files weren't committed there. It travels only in the encrypted disk image. cl_audit never runs git on this Mac: the commands are here for you to copy. Clone first or after: once a folder is here, point its sessions at it (Pick its folder on this Mac…).") {
            if list.projects.isEmpty {
                SRow(label: "Projects", first: true, stacked: true) { value("none: the sessions named no folder") }
            }
            ForEach(Array(list.projects.enumerated()), id: \.offset) { i, p in
                let here = SessionsRepoint.folderHere(expand(p.path))
                SRow(label: CodeChecklist.name(p.path), first: i == 0, stacked: true) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(CodeChecklist.lines(p, here: here).enumerated()), id: \.offset) { k, s in
                            Text(s).font(.system(size: k == 0 ? 12 : 11)).foregroundStyle(k == 0 ? face.soft : face.caution)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        let cmds = CodeChecklist.commands(p, here: here)
                        if !cmds.isEmpty { commands(cmds) }
                    }
                }
            }
            if let g = list.git { SRowLine(text: "Read without git: \(g), so only the folders are listed.", color: face.caution) }
            ForEach(Array((list.notes ?? []).prefix(8).enumerated()), id: \.offset) { _, s in SRowLine(text: s, color: face.caution) }
            SRowLine(text: "Read on the old Mac on \(SessionsBackup.dateWords(list.created)). cl_audit runs nothing here: copy the commands into Terminal yourself.")
        }
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commands(_ cmds: [String]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(cmds.enumerated()), id: \.offset) { _, c in
                    Text(c).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmds.joined(separator: "\n"), forType: .string)
            }
            .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            .help("Copies the commands; cl_audit doesn't run them")
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }
}

// MARK: - Sessions: imported sessions whose folder isn't here

/// One re-point from the Sessions page: the profile's window closes when an entry is written (only that window, the same quit as a
/// restore), the session is re-pointed, the window opens again. Undo takes back the last one the same way.
final class RepointRunner: ObservableObject {
    @Published private(set) var sessions: [SessionsRepoint.Session] = []
    @Published private(set) var last: SessionsRepoint.Receipt?
    @Published private(set) var busy = false
    @Published private(set) var note: String?
    private var timer: Timer?
    private var frozen = false
    let markName = "repoint-" + UUID().uuidString.prefix(8).lowercased()

    func load(_ e: AccountEntry) {
        guard !frozen else { return }
        let t = SessionsRestore.Target(e)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = SessionsRepoint.missing(t)
            let last = SessionsRepoint.last(profile: e.id)
            DispatchQueue.main.async { self?.sessions = list; self?.last = last }
        }
    }

    func pick(_ s: SessionsRepoint.Session, entry e: AccountEntry) {
        guard !busy else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false; p.canCreateDirectories = false
        p.title = "Pick the session's folder on this Mac"; p.prompt = "Pick"
        p.message = "Where is \(tilde(s.folder)) on this Mac? \(RepointWords.title(s)) is pointed at the folder you pick."
        guard p.runModal() == .OK, let url = p.url else { return }
        run(e, needsWindow: !s.entries.isEmpty) { t, mark, closed in
            try SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: s.id, folder: url.path)], mark: mark, windowClosed: closed)
        }
    }

    func undo(entry e: AccountEntry) {
        guard !busy, let r = last else { return }
        run(e, needsWindow: r.touchesWindow) { _, _, closed in try SessionsRepoint.undo(r.id, windowClosed: closed) }
    }

    /// The window closed when needed (claimed with this runner's mark, asked to quit, watched for 45 seconds), the work done off the main
    /// thread, the window opened again when it was closed for this.
    private func run(_ e: AccountEntry, needsWindow: Bool, _ work: @escaping (SessionsRestore.Target, String, () -> Bool) throws -> SessionsRepoint.Receipt) {
        busy = true; note = nil
        let window = Launcher.dataDirKey(of: Account(e)), mark = markName
        var claimed = false, closedByUs = false
        func finish(_ result: Result<SessionsRepoint.Receipt, Error>) {
            if claimed { SwitchMarker.release(window, profile: e.id, standby: mark) }
            if closedByUs, e.claudeWindow { Launcher.openClaude(Account(e)) }
            busy = false
            switch result {
            case .success(let r): note = r.problems.isEmpty ? nil : r.problems.prefix(3).joined(separator: " ")
            case .failure(let err): note = "\(err)"
            }
            load(e)
        }
        func go() {
            let t = SessionsRestore.Target(e)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try work(t, mark, { SwitchRunner.windowClosed(e) }) }
                DispatchQueue.main.async { finish(result) }
            }
        }
        guard needsWindow else { go(); return }
        if let why = SessionsRestore.blocker(profile: e.id) { busy = false; note = why.words; return }
        guard SwitchMarker.claim(window, profile: e.id, standby: mark) else { busy = false; note = "A switch or restore of this Claude window is under way; try again once it ends."; return }
        claimed = true
        let apps = SwitchRunner.windowApps(e)
        if apps.isEmpty { go(); return }
        closedByUs = true
        apps.forEach { $0.terminate() }
        let started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            if SwitchRunner.windowClosed(e) { t.invalidate(); self?.timer = nil; go(); return }
            if Date().timeIntervalSince(started) > 45 {
                t.invalidate(); self?.timer = nil
                SwitchMarker.release(window, profile: e.id, standby: mark)
                self?.busy = false
                self?.note = "The window didn't close; it may be asking about work under way. Answer it, then try again. Nothing was changed."
            }
        }
    }

    /// Renders only.
    func preview(sessions s: [SessionsRepoint.Session], last l: SessionsRepoint.Receipt? = nil, note n: String? = nil) {
        frozen = true; sessions = s; last = l; note = n
    }
}

struct MissingFoldersRow: View {
    let entry: AccountEntry
    @ObservedObject var runner: RepointRunner
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if runner.sessions.isEmpty {
                text("Every imported session's folder is on this Mac.")
            } else {
                text("\(runner.sessions.count) imported \(runner.sessions.count == 1 ? "session's folder isn't" : "sessions' folders aren't") on this Mac. Clone or copy the code first, then point each session at it.")
            }
            ForEach(runner.sessions.prefix(30)) { s in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RepointWords.title(s)).font(.system(size: 12, weight: .semibold)).foregroundStyle(face.text).lineLimit(1).truncationMode(.tail)
                        Text("was in \(tilde(s.folder))" + (s.worktree.map { " · worktree \(($0 as NSString).lastPathComponent)" } ?? ""))
                            .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Pick its folder…") { runner.pick(s, entry: entry) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(runner.busy)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(face.text.opacity(0.05)))
            }
            if runner.sessions.count > 30 { note("…and \(runner.sessions.count - 30) more.") }
            if let l = runner.last {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("Undo") { runner.undo(entry: entry) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(runner.busy)
                    text("Last pointed \(SessionsBackup.dateWords(l.started)): " + (l.sessions.first.map { "\($0.title.map { "“\($0)”" } ?? "a session") \(RepointWords.done($0))" } ?? "nothing"))
                }
            }
            if runner.busy { note("Working… the window closes only if a Code-tab entry changes.") }
            if let n = runner.note { note(n, color: face.caution) }
        }
        .task(id: entry.id) { runner.load(entry) }
    }

    private func text(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func note(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
