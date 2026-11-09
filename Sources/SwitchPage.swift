// SwitchPage: one switch of a profile to another of its accounts, from before anything happens to Done or the way out
// (SwitchRunner.swift runs it, SwitchEngine.swift moves the files). Every block stays while it runs; only the steps move
// on, and the line at the top says how far it got.
//
// Display colours, one meaning each: green = in use; mint (the display's own print, lit full) = switching and the
// account switched to; amber = waiting for you, or a warning; red = something failed. Only the account in use is lit.

import AppKit
import SwiftUI

struct SwitchPage: View {
    let entry: AccountEntry
    let standby: StandbyAccount
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner
    var width: CGFloat = 980
    @State private var counts: SidebarCounts??          // nil: still counting; .some(nil): the window has nothing
    @State private var asks = true                      // the helper session will ask before each move (step 5)
    @State private var unfinished: [SwitchReceipt] = [] // this profile's switches that stopped half way
    @State private var back: BackWatch.Back?             // the account to switch to is back (SwitchBack.swift)
    @State private var kept: SessionsBackup.Kept?        // what a backup would take (nil: still counting)
    @State private var made: SessionsBackup.Manifest?    // the backup this switch's receipt names
    @State private var madeLoaded: String?               // the ref (id + place) loadMade() has finished for
    @State private var undone: SessionsBackup.Manifest?  // Undo this switch: the backup of the switch being undone
    @ObservedObject private var backups = BackupPrefs.shared
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    /// The account it switches from (once switched, the one the receipt names).
    private var from: String {
        // the receipt names accounts by id only: once switched, the account it came from is the one on standby
        let was = runner.receipt.flatMap { r in r.from.same(entry.seat) ? nil : entry.standby.first { r.from.same($0.seat) }?.email }
        return AccountNames.short(was ?? entry.seat?.email ?? Account.expectedEmail(configDir: entry.configDir) ?? "its account")
    }
    private var to: String { AccountNames.short(standby.email) }
    /// Linked: the profile works on the account switched to.
    private var switched: Bool { entry.seat.map { $0.same(standby.seat) } ?? false }
    /// Back to the account the profile was on before its last switch, until the switch is done.
    private var goesBack: Bool { entry.isBack(to: standby) && !switched }
    private var isFailed: Bool { if case .failed = runner.phase { return true }; return false }
    private var moves: Bool { runner.moveSessions == true }
    /// The answers (Move them?, the backup's transcripts) can still change: before it starts, after a cancel, and after a
    /// stop with nothing moved.
    private var canChoose: Bool { runner.phase == .ready || runner.phase == .cancelled || (isFailed && runner.receipt == nil) }
    /// The sidebar step: the sessions move and there's a Claude window to arrange.
    private var arranges: Bool { moves && entry.claudeWindow }
    /// How many steps this switch has: the sidebar's is the fifth.
    private var steps: Int { arranges ? 5 : 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            if let t = topLine { topBar(t) }
            undoBanner
            // the Backup card shows when "Move to …" is the answer: the sessions are backed up first
            SettingsColumns(width: width, groups: [[AnyView(accountsCard), AnyView(staysCard)],
                                                  [AnyView(sessionsCard)] + (moves ? [AnyView(backupCard)] : []) + [AnyView(stepsCard)]])
        }
        .task(id: entry.id + standby.id) { await count() }
        .task(id: (runner.backupRef.map { $0.id + $0.place } ?? "")) { await loadMade() }
        .task(id: (runner.undoes.map { $0.backup + $0.place } ?? "")) { await loadUndone() }
    }

    private var title: String {
        if runner.isRunning { return "Switching Claude \(name) to \(to)" }
        if runner.phase == .done { return "Switched Claude \(name) to \(to)" }
        return "Switch Claude \(name) \(goesBack ? "back to" : "to") \(to)"
    }

    /// The window's sidebar for the account in use, counted off the main thread (the entries can be large).
    private func count() async {
        counts = nil                                      // another profile's counts never show meanwhile
        let e = entry
        let dir = e.desktop == .standard ? FolderKey.standardDataDir : (Account(e).claudeUserDataDir ?? "")
        let account = FolderRules.windowAccount(e) ?? e.seat?.account ?? ""
        // the account the helper session runs on: the one switched to
        let target = runner.receipt?.to.account ?? standby.seat?.account
        let (c, a): (SidebarCounts?, Bool) = await Task.detached(priority: .utility) {
            (dir.isEmpty || account.isEmpty ? nil : SidebarCounts.read(dataDir: dir, account: account),
             dir.isEmpty || SidebarPlan.asksBeforeMoves(dataDir: dir, account: target))
        }.value
        counts = .some(c)
        asks = a
        let id = e.id, key = AccountEntry.standbyStatusID(e.id, standby.id)
        (unfinished, back) = await Task.detached(priority: .utility) { (SwitchEngine.unfinished(profile: id), BackWatch.load(key)) }.value
        // what the backup would take (shown at once from the last count, counted again meanwhile)
        let source = SessionsBackup.Source(e)
        kept = SessionsBackup.KeptCache.get(id)
        let k = await Task.detached(priority: .utility) { SessionsBackup.kept(source) }.value
        SessionsBackup.KeptCache.set(id, k)
        kept = k
    }

    /// The backup the receipt names, read from the backups folder.
    private func loadMade() async {
        guard let ref = runner.backupRef else { made = nil; madeLoaded = nil; return }
        let profile = entry.id
        made = await Task.detached(priority: .utility) {
            SessionsBackup.load(profile: profile, id: ref.id, place: URL(fileURLWithPath: ref.place))
        }.value
        madeLoaded = ref.id + ref.place
    }

    /// A switch of this profile that stopped half way (this one, or one from before), with what it moved: Undo first.
    private var pending: SwitchReceipt? {
        if let r = runner.receipt, r.unfinished, runner.phase != .codeSignIn { return r }
        return runner.phase == .ready || isFailed ? unfinished.first : nil
    }

    // MARK: the line at the top: how far it got, and the keys that lead out

    private struct Top { var text: String; var dim: String?; var tone: DisplayWindow.Tone }

    private var topLine: Top? {
        if let p = pending, runner.phase == .ready || isFailed {
            return Top(text: "Stopped half way", dim: "· \(p.moved) moved, set aside · \(p.started.formatted(date: .abbreviated, time: .shortened))", tone: .amber)
        }
        switch runner.phase {
        case .ready: return nil
        case .closing: return Top(text: "Switching", dim: "· step 1 of \(steps) · the window closes", tone: .mint)
        case .moving: return Top(text: "Switching", dim: "· step 2 of \(steps) · the sessions", tone: .mint)
        case .codeSignIn: return Top(text: "Switching", dim: "· step 3 of \(steps) · Claude Code", tone: .mint)
        case .windowSignIn: return Top(text: "Switching", dim: "· step 4 of \(steps) · the window", tone: .mint)
        case .sidebar:
            if runner.sidebarMissed { return Top(text: "Switched", dim: "· step 5 of 5 · the sidebar session didn't open", tone: .warn) }
            return Top(text: "Switching", dim: "· step 5 of 5 · the sidebar", tone: .mint)
        case .done: return Top(text: "\(name) works on \(to)", dim: "· \(from) on standby", tone: .ok)
        case .cancelled: return Top(text: "Cancelled", dim: "· everything put back", tone: .normal)
        case .failed:
            if runner.undoStopped { return Top(text: "Undo stopped", dim: "· the receipt keeps the rest", tone: .warn) }
            return Top(text: "Stopped", dim: runner.failedStep.map { "· at step \($0) of \(steps)" } ?? "· nothing moved", tone: .warn)
        }
    }

    /// The display and the keys on one line; when they don't fit the page, the keys go under the display (one under the
    /// other if they still don't fit).
    private func topBar(_ t: Top) -> some View {
        let display = DisplayWindow(text: t.text, dim: DisplayWindow.narrowed(t.dim, width: width), tone: t.tone, height: 24, size: 10)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { display; Spacer(minLength: 6); topKeys }
            VStack(alignment: .leading, spacing: 8) { display; HStack(spacing: 10) { topKeys } }
            VStack(alignment: .leading, spacing: 8) { display; VStack(alignment: .leading, spacing: 8) { topKeys } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cancel stays in sight while a switch runs; at Done and after a stop, the keys lead out.
    @ViewBuilder private var topKeys: some View {
        switch runner.phase {
        case .closing:
            Button("Cancel switch") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .moving:
            Button("Cancel switch") {}.buttonStyle(.pill(FaceTheme.ledRed, compact: true)).disabled(true)
                .help("The sessions are moving; Cancel comes back in a moment and puts them back")
        case .codeSignIn:
            Button("Cancel switch, put everything back") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .windowSignIn, .sidebar:
            // linked: the way back is a switch the other way
            Button("Undo this switch…") { switchBack() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .done:
            if runner.undoes != nil {
                // the second half of Undo this switch: the Restore page, on the backup the undone switch made
                Button("Put back from the backup…") { openRestore() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            } else {
                Button("Undo this switch…") { switchBack() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            }
        case .cancelled:
            Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .ready, .failed:
            EmptyView()
        }
    }

    /// The account the profile came from, now on standby: the Switch page the other way. This switch is linked by
    /// then, so it ends here as done: nothing of it keeps waiting or opens the sidebar session later.
    private func switchBack() {
        if runner.isRunning { runner.finish() }
        guard let r = runner.receipt, let s = entry.standby.first(where: { r.from.same($0.seat) }) else {
            model.selection = entry.id; return
        }
        // the switch the other way, then what this switch changed comes back from its backup (the Restore page)
        model.showUndoSwitch(r, key: AccountEntry.standbyStatusID(entry.id, s.id))
    }

    // MARK: Undo this switch: switch back, then put back from the backup

    /// The backup the switch being undone made, read for its title.
    private func loadUndone() async {
        guard let u = runner.undoes else { undone = nil; return }
        let profile = entry.id
        undone = await Task.detached(priority: .utility) {
            SessionsBackup.load(profile: profile, id: u.backup, place: URL(fileURLWithPath: u.place))
        }.value
    }

    private var undoneTitle: String { undone.map { SessionsBackup.title($0, target: RestoreRunner.targetWord($0, for: entry)) } ?? "the switch's backup" }

    /// Said before it starts and kept in sight: this is two things in one flow, and the second writes only what is missing.
    @ViewBuilder private var undoBanner: some View {
        if runner.undoes != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Undo this switch").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(face.text)
                Text(runner.phase == .done
                     ? "Switched back. Last: anything the switch changed comes back from \(undoneTitle). The Restore page counts first and writes nothing until you press its key; nothing is overwritten."
                     : "Switches back to \(to), then puts back anything the switch changed from its backup (\(undoneTitle)): nothing is overwritten. The sessions move back with it.")
                    .font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(face.text.opacity(0.05)))
        }
    }

    /// The last step of an Undo this switch, after the switch back: the Restore page, opened on that backup.
    private func openRestore() {
        guard let u = runner.undoes else { return }
        model.showRestore(RestoreKey(profile: entry.id, backup: u.backup, place: u.place, afterSwitch: u.receipt))
    }

    // MARK: accounts: NOW lit, TO most room first (the picked one in mint)

    private var accountsCard: some View {
        SCard(title: "Accounts", info: "The account \(name) works on now, and the one it switches to, with their limits as cl_audit last read them. Only the account in use is lit.") {
            VStack(alignment: .leading, spacing: 12) {
                if switched {
                    labelled("Now") { inUseBox(entry, status: Store.status(for: entry)) }
                    if let was = cameFrom { labelled("Before") { standbyBox(was, selected: false) } }
                } else {
                    labelled("Now") {
                        VStack(alignment: .leading, spacing: 6) {
                            inUseBox(entry, status: Store.status(for: entry))
                            ownFolderNote
                        }
                    }
                    let list = pickList
                    labelled(runner.isRunning || isFailed ? "Next" : "To") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(list) { s in standbyBox(s, selected: s.id == standby.id) }
                            if runner.phase == .ready, list.count > 1 {
                                Text("Pick the account to switch to; the one with the most room is on top. Click another to switch to it instead.")
                                    .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Before it starts, every standby account, most room first; once it runs, only the one it switches to.
    private var pickList: [StandbyAccount] {
        guard runner.phase == .ready || runner.phase == .cancelled, runner.receipt == nil else { return [standby] }
        let all = SwitchOffer.byRoom(entry)
        return all.contains { $0.id == standby.id } ? all : [standby] + all
    }

    private var cameFrom: StandbyAccount? {
        guard let r = runner.receipt else { return nil }
        return entry.standby.first { r.from.same($0.seat) }
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(face.muted).lineLimit(1).fixedSize().frame(width: 50, alignment: .leading).padding(.top, 12)
            content()
        }
    }

    // "Ultra · Personal", as in Settings ▸ Accounts
    private func detail(_ st: IconStatus?, _ dir: String?) -> String {
        let f = dir.flatMap { FolderFactsCache.facts($0) }
        return [st?.plan.map(Account.planWords) ?? f?.plan, f?.org].compactMap { $0 }.joined(separator: " · ")
    }

    private func inUseBox(_ e: AccountEntry, status st: IconStatus?) -> some View {
        AccountBox(lamp: FaceTheme.ledOn, badge: "In use", badgeTone: .ok, detail: detail(st, e.readingFolder)) {
            Text(Privacy.masked(e.seat?.email ?? "its account")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
        } content: { limits(st, e) }
    }

    /// Text in an account box, coloured by the face the box sets for its content (a selected box is dark glass on every
    /// face): read here from the environment, never taken from the page's own.
    private struct BoxText: View {
        enum Role { case title, softTitle, note }
        let text: String
        let role: Role
        @Environment(\.face) private var face
        var body: some View {
            switch role {
            case .title: Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
            case .softTitle: Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.soft).lineLimit(1).truncationMode(.tail).settingsEmail()
            case .note: Text(text).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func standbyBox(_ s: StandbyAccount, selected: Bool) -> some View {
        let st = Store.status(for: entry, standby: s)
        let pickable = runner.phase == .ready && runner.receipt == nil && !selected && AccountSettings.canSwitch(s)
        let backWords = selected && back != nil && !switched ? " · back" : ""
        return AccountBox(lamp: nil, badge: "Standby", detail: detail(st, s.configDir) + backWords,
                          unlit: !selected, selected: selected, litBadge: switched ? nil : "Switching to") {
            BoxText(text: Privacy.masked(s.email), role: selected ? .title : .softTitle)
        } content: {
            if s.configDir == nil {
                BoxText(text: "Limits unknown: no sign-in kept for it. You sign in during the switch anyway.", role: .note)
            } else {
                limits(st, entry.readerEntry(for: s) ?? entry)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard pickable else { return }
            // the answers given so far go with the account picked instead (after showSwitch, which starts an ended
            // switch of it over)
            let was = runner
            model.showSwitch(AccountEntry.standbyStatusID(entry.id, s.id))
            model.runner(entry, s).carry(from: was)
        }
    }

    /// The NOW account's own folder: its limits stay in sight after the switch, or the page offers that sign-in first.
    @ViewBuilder private var ownFolderNote: some View {
        if SwitchRunner.hasOwnFolder(entry), let k = entry.keptFolder {
            Text("Its limits stay in sight after the switch: it's signed in once in a folder of its own, \(tilde(expand(k))).")
                .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
        } else if runner.phase == .ready {
            Text("No folder of its own yet: the steps offer that sign-in first, so its limits stay in sight after the switch.")
                .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Both accounts with the same bars (no at-limit box here, so a full account and one with room read alike).
    @ViewBuilder private func limits(_ st: IconStatus?, _ e: AccountEntry) -> some View {
        let row = AccountRow(entry: e, status: st)
        if let reset = Self.resetSinceRead(st) {
            // read while full, and its reset time has passed since: those bars would be old (SwitchBack.swift)
            BoxText(text: "Its \(reset.week ? "week" : "5-hour limit") started again at \(TimeWords.when(reset.at)); cl_audit hasn't read it since.", role: .note)
        } else if row.limits.contains(where: { $0.p != nil }) {
            CardLimits(limits: row.limits, design: DashboardPrefs.shared.cardStyle, credits: st?.credits, fullBox: false)
        } else {
            BoxText(text: "No numbers yet.", role: .note)
        }
    }

    /// Numbers read while a limit was full whose reset time has passed since (the week, else the 5-hour limit), or nil.
    static func resetSinceRead(_ st: IconStatus?, now: Date = Date()) -> (week: Bool, at: Date)? {
        guard let st else { return nil }
        if AtLimit.isFull(st.weekly), let r = st.weeklyResets, r <= now, (st.updatedAt ?? .distantPast) < r { return (true, r) }
        if AtLimit.isFull(st.fiveHour), let r = st.fiveHourResets, r <= now, (st.updatedAt ?? .distantPast) < r { return (false, r) }
        return nil
    }

    private var staysCard: some View {
        SCard(title: "Stays as it is", info: "Switching changes only the account \(name) works on. Everything that makes it \(name) stays.") {
            SRow(label: "Profile", first: true) { value("Name, Dock icon, look") }
            SRow(label: "Folder") { value("\(entry.configDir): projects, settings, MCP, CLAUDE.md") }
            SRow(label: "History") { value("Claude Code's, for claude --resume") }
        }
    }

    // MARK: the sessions: asked every time, no answer chosen

    private var sessionsCard: some View {
        SCard(title: "Sessions", info: "The Claude window's Code sessions, its sidebar (sections, groups, pins) and its scheduled tasks. Moved, they go with \(name) to \(to), the way claude-transplant moves them, and come back when it switches back. Left, each account keeps its own. Chats and Projects on claude.ai belong to each account and never move.") {
            // the label above, the keys side by side when they fit the card, else one under the other: never wider than the card
            SRow(label: "Move them?", first: true, stacked: true) {
                let moveKey = choice("Move to \(to)", picked: runner.moveSessions == true) { runner.moveSessions = true }
                let leaveKey = choice("Leave with \(from)", picked: runner.moveSessions == false) { runner.moveSessions = false }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { moveKey; leaveKey }
                    VStack(alignment: .leading, spacing: 8) { moveKey; leaveKey }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(!canChoose)
            }
            SRowLine(text: "The sessions are in \(entry.windowDataWords)\(entry.desktop == .standard ? "" : ", opened from its Dock icon").")
            SRowLine(text: runner.moveSessions == nil ? "Choose one to go on: nothing is chosen for you."
                     : runner.phase == .ready ? (moves ? "They move to \(to); \(from) keeps none. Cancel puts them back." : "Each account keeps its own; the window opens with \(to)'s.")
                     : "Your answer. It can't change while the switch runs; Cancel puts everything back.")
            // once it ran: what moved, from its receipt (the window's own count would be of the account it left)
            if let r = runner.receipt, moves {
                SRow(label: "Sessions") { value("\(r.moved) moved to \(to)\(r.undone != nil ? ", then put back" : "")") }
                let tasks = r.steps.contains { $0.kind == .tasks && $0.done }
                SRow(label: "Routines") { value(tasks ? "moved with them" : "none to move") }
                if let p = r.sidebar, !p.isEmpty {
                    SRow(label: "Sidebar") { value("\(p.groups.count) \(p.groups.count == 1 ? "group" : "groups") and \(p.pinned.count) \(p.pinned.count == 1 ? "pin" : "pins") noted for step 5") }
                }
            } else {
                liveCounts
            }
            SRowLine(text: "Chats and Projects on claude.ai don't move; they belong to each account.")
        }
    }

    @ViewBuilder private var liveCounts: some View {
            switch counts {
            case nil:
                SRow(label: "Sessions") { value("counting…") }
            case .some(nil):
                SRow(label: "Sessions") { value("none in the window for \(from)") }
            case .some(.some(let c)):
                let w = c.words
                SRow(label: "Sessions") { value(w[0]) }
                if w.count > 2 { SRow(label: "Sidebar") { value(w[1]) } }
                SRow(label: "Routines") { value(w.last ?? "") }
            }
    }

    private func choice(_ title: String, picked: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(PillButtonStyle(tint: picked ? FaceTheme.mint : nil, compact: true)).fixedSize()
    }

    // MARK: the backup: made right after the window closes, before anything moves

    private var backupCard: some View {
        let placeWords = backups.placeWords
        return SCard(title: "Backup", info: "A copy of what the switch is about to move, made on this Mac right after the window closes and before anything moves: the window's Code-tab list for both accounts with its scheduled tasks, its sidebar records and cl_audit's own, and, if you leave it on, Claude Code's transcripts. Clones: seconds, and they share space with the originals. If it can't be made, nothing moves. It's listed under \(name)'s Sessions in its settings.") {
            if let ref = runner.backupRef {
                SRow(label: "Made", first: true, stacked: true) { value(madeWords(ref)) }
                SRowLine(text: "The switch's receipt names it, so Undo and the backup point at each other.")
            } else if runner.phase == .moving {
                SRow(label: "Making it", first: true, stacked: true) { value("Right now, before anything moves…") }
            } else {
                let editable = canChoose
                // stacked rows: the label above, the words the card's full width, at any column width
                SRow(label: "When", first: true, stacked: true) { value("Every time the sessions move, as claude\u{2011}transplant keeps what it moves: right after the window closes, before anything moves") }
                SRow(label: "What", stacked: true) { value("The window's Code-tab list for both accounts, scheduled tasks, its sidebar records; cl_audit's records") }
                SRow(label: "Transcripts", stacked: true) {
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $runner.backupTranscripts).smallSwitch().disabled(!editable)
                        Text(transcriptWords).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                    }
                }
                SRow(label: "Takes", stacked: true) { value(takesWords) }
                SRowLine(text: "Never in a backup: sign-ins, and the sidebar kept on claude.ai (the switch's own record puts that back). Kept in \(placeWords), listed under \(name)'s Sessions, until you delete it or it ages out.")
                    .padding(.top, 4)
            }
        }
    }

    /// "Claude Code's too: 37 transcripts"
    private var transcriptWords: String {
        guard runner.backupTranscripts else { return "Not taken: they stay in Claude Code's folder" }
        guard let n = kept?.transcripts else { return "Claude Code's too: counting…" }
        return "Claude Code's too: \(n) \(n == 1 ? "transcript" : "transcripts")"
    }

    /// "Before switch to ultra-2 · 5 Nov 18:40 · 3 s"
    private func madeWords(_ ref: SwitchRunner.BackupRef) -> String {
        guard madeLoaded == ref.id + ref.place else { return "…" }                  // still being read
        guard let m = made, m.id == ref.id else { return "it isn't in \(tilde(ref.place)) any more" }
        return "\(SessionsBackup.title(m, target: to)) · \(SessionsBackup.secondsWords(m.seconds))"
    }

    private var takesWords: String {
        let place = BackupPrefs.placeURL
        let dir = entry.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(entry).claudeUserDataDir ?? expand("~"))
        if SessionsBackup.sameVolume(place, as: dir) { return "A few seconds, as clones: they share space with the originals" }
        let size = kept.map { SessionsBackup.sizeWords($0.bytes - (runner.backupTranscripts ? 0 : $0.transcriptBytes)) }
        return "Longer: \(tilde(place.path)) is on another volume, so it's a full copy" + (size.map { " (\($0))" } ?? "")
    }

    // MARK: the steps: each one's state, each sign-in checked

    private enum StepState { case pending, now, waiting, done, failed }

    private func state(_ n: Int) -> StepState {
        if case .failed = runner.phase {
            guard let f = runner.failedStep else { return .pending }
            return n < f ? .done : n == f ? .failed : .pending
        }
        if n > steps { return runner.phase == .done ? .waiting : .pending }        // Undo this switch: the Restore page comes last
        switch runner.phase {
        case .ready, .cancelled: return n == 2 && runner.moveSessions == nil && runner.phase == .ready ? .waiting : .pending
        case .closing: return n == 1 ? .now : .pending
        case .moving: return n < 2 ? .done : n == 2 ? .now : .pending
        case .codeSignIn: return n < 3 ? .done : n == 3 ? .waiting : .pending
        case .windowSignIn: return n < 4 ? .done : n == 4 ? .waiting : .pending
        case .sidebar: return n < 5 ? .done : runner.sidebarMissed ? .failed : .waiting
        case .done: return n == 5 && arranges && runner.sidebarPlan != nil && !runner.sidebarOpened ? .waiting : .done
        case .failed: return .pending
        }
    }

    private var sidebarWords: String {
        let ask = "Press Return in the session that opens, so the sidebar is arranged as before."
            + (asks ? " It may ask to move each session; allow them." : "")
        guard runner.receipt != nil else { return ask }                  // nothing moved yet
        guard let p = runner.sidebarPlan else { return "Nothing to arrange: none of the moved sessions sat in a group or was pinned." }
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var what: [String] = []
        if p.filed > 0 { what.append("\(n(p.filed, "session goes", "sessions go")) back in \(n(p.groups.count, "group", "groups"))") }
        if !p.pinned.isEmpty { what.append("\(n(p.pinned.count, "session is", "sessions are")) pinned again") }
        let more = p.left.map { " \($0) more stay ungrouped (one session arranges at most \(SidebarPlan.maxSessions))." } ?? ""
        return "\(ask) \(what.joined(separator: "; ")).\(more) It archives itself when done."
    }

    private var stepsCard: some View {
        let w = entry.windowWordsCap
        let movedCount = runner.receipt?.moved ?? 0
        return SCard(title: "Steps", info: "What switching does, in order. Each step is checked before the next. A receipt in cl_audit's folder keeps what moved: until Claude Code has signed in, Cancel puts it back; after that the way back is a switch the other way.") {
            if keepsOwnFolderFirst { ownFolderStep.padding(.bottom, 6) }
            VStack(alignment: .leading, spacing: 0) {
                // the backup is made right after the window closes: step 1 says so once the receipt names it
                step(1, runner.backupFailed ? "\(w) closed, backup not made"
                        : state(1) == .done ? "\(w) closed\(moves && runner.backupRef != nil ? ", backup made" : "")" : "\(w) closes",
                     runner.backupFailed ? "The backup couldn't be made, so nothing moved. Try again, or change where backups go in General ▸ Backups."
                     : runner.failedStep == 1 ? "It didn't close: it may be asking about work under way. Answer it, then try again. Nothing moved."
                     : "Only that window, for about half a minute; your other Claude windows stay open.",
                     check: backupCheck)
                step(2, sessionsTitle(movedCount), sessionsDetail)
                step(3, "Claude Code signs in as \(to)", "Terminal and the browser; cl_audit checks it's \(to) before going on.",
                     check: codeCheck)
                step(4, "The Claude window signs in as \(to)", windowDetail, check: windowCheck)
                if arranges { step(5, "The sidebar, as before", sidebarWords) }
                if runner.undoes != nil {
                    step(steps + 1, "Then: what the switch changed comes back",
                         "From \(undoneTitle), on the Restore page: it counts what is missing, changed or in use first, and writes only what is missing. Nothing is overwritten. \(runner.phase == .done ? "The key at the top opens it." : "The key at the top opens it once this switch is done.")")
                }
            }
            keys.padding(.top, 8)
            if let line = statusLine { SRowLine(text: line, color: isFailed ? face.danger : nil) }
        }
    }

    private func sessionsTitle(_ moved: Int) -> String {
        switch runner.moveSessions {
        case nil: return "The sessions: waiting for your answer"
        case false?: return "The sessions stay with each account"
        case true?:
            if state(2) == .done { return "\(moved) \(moved == 1 ? "session" : "sessions") moved to \(to)" }
            return "The sessions move to \(to)"
        }
    }

    private var sessionsDetail: String {
        switch runner.moveSessions {
        case nil: return "Move to \(to), or leave with \(from)."
        case false?: return "Nothing moves; the window opens with \(to)'s sessions."
        case true?:
            if runner.failedStep == 2 { return "Stopped part way: what moved is set aside, not deleted. Undo puts it back." }
            if state(2) == .done { return "Set aside, not deleted: Cancel puts them back. Their groups and pins are noted for step 5." }
            return "Same ids; nothing is deleted. Their groups and pins are noted for step 5."
        }
    }

    private var windowDetail: String {
        if state(4) == .waiting, runner.windowOnTarget == false {
            return "The window asked you to sign in again. Sign out there, then sign in as \(Privacy.masked(standby.email)); if the browser offers another account, switch it in the browser first. cl_audit waits here until the window is on \(to)."
        }
        return "The window asks you to sign in again; cl_audit checks it's \(to) before going on."
    }

    /// "Backup · 3 s ✓" once the receipt names a backup that is there.
    private var backupCheck: (String, DisplayWindow.Tone)? {
        guard moves, let ref = runner.backupRef, let m = made, m.id == ref.id else { return nil }
        return ("Backup · \(SessionsBackup.secondsWords(m.seconds)) ✓", .ok)
    }

    /// What the Claude Code check saw: ✓ on the account switched to, amber on another (by account id, not the name).
    private var codeCheck: (String, DisplayWindow.Tone)? {
        if state(3) == .done { return ("Claude Code · \(to) ✓", .ok) }
        guard let seen = runner.codeSeen, let on = runner.codeOnTarget, state(3) != .pending else { return nil }
        return on ? ("Claude Code · \(to) ✓", .ok) : ("Signed in as \(seen)", .amber)
    }

    private var windowCheck: (String, DisplayWindow.Tone)? {
        if state(4) == .done { return ("Window · \(to) ✓", .ok) }
        guard let seen = runner.windowSeen, let on = runner.windowOnTarget, state(4) == .waiting else { return nil }
        return on ? ("Window · \(to) ✓", .ok) : ("Window · \(seen) · not \(to)", .amber)
    }

    /// Before Close and switch: the account it leaves has no folder of its own yet, and it wasn't skipped.
    private var keepsOwnFolderFirst: Bool {
        runner.phase == .ready && runner.ownFolder != .skipped && entry.seat != nil && !SwitchRunner.hasOwnFolder(entry)
    }

    /// "Keep ultra-1's limits showing after the switch": Sign in ultra-1… or Skip.
    private var ownFolderStep: some View {
        let signing = runner.ownFolder == .signing
        return VStack(alignment: .leading, spacing: 6) {
            Text("Keep \(from)'s limits showing after the switch").font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text)
            Text(signing ? "Finish the sign-in in the browser as \(Privacy.masked(entry.seat?.email ?? from)); Terminal shows Claude Code's sign-in."
                         : "Sign it in once to a folder of its own (one confirmation in the browser). Without it, \(from)'s limits show as last read until \(name) switches back.")
                .font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            ClaudeMissingLine(model: model)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Skip") { runner.skipOwnFolder() }.buttonStyle(.plain).foregroundStyle(face.muted)
                Button(signing ? "Sign in again…" : "Sign in \(from)…") { runner.keepOwnFolder() }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(face.text.opacity(0.05)))
    }

    private var statusLine: String? {
        if let p = pending {
            var lead = ""
            if case .failed(let why) = runner.phase, !why.hasPrefix("An earlier switch") { lead = why + " " }
            if let n = runner.note { lead += n + " " }
            return lead + "\(p.moved) \(p.moved == 1 ? "session" : "sessions") moved and set aside; \(name) not switched."
                + (lead.contains("Undo puts") ? "" : " Undo puts them back.")
        }
        switch runner.phase {
        case .failed(let why): return why
        case .cancelled: return "Cancelled: the sessions are back with \(from)."
        case .done: return runner.note
        // still pending, however long it waits: the window stays closed until it's signed in or cancelled
        case .codeSignIn: return [runner.note, "The switch is waiting for this sign-in; \(name)'s window stays closed until it's done or cancelled."]
            .compactMap { $0 }.joined(separator: " ")
        default: return runner.note
        }
    }

    @ViewBuilder private var keys: some View {
        HStack(spacing: 10) {
            switch runner.phase {
            case .ready, .failed, .cancelled:
                Button("Back") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                if let p = pending {
                    Button(runner.undoStopped ? "Try Undo again" : "Undo") {
                        runner.undoUnfinished(p.id)
                        unfinished = SwitchEngine.unfinished(profile: entry.id)
                    }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                } else {
                    // after Cancel, the same switch can start again
                    Button(isFailed ? "Try again" : "Close and switch \(goesBack ? "back to" : "to") \(to)") { runner.start() }
                        .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                        .disabled(runner.moveSessions == nil || keepsOwnFolderFirst || (moves && counts == nil))
                }
            case .closing, .moving:
                Button("Cancel switch") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true)).disabled(runner.phase == .moving)
                Spacer(minLength: 6)
                Text(runner.phase == .closing ? "closing the window…" : "moving…").font(.system(size: 12)).foregroundStyle(face.caution)
            case .codeSignIn:
                Button("Cancel switch") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
                Spacer(minLength: 6)
                Button("Sign in again…") { runner.signInCode() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            case .windowSignIn:
                Button("Undo this switch…") { switchBack() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
                Spacer(minLength: 6)
                Button("Show the Claude window") { Launcher.openClaude(Account(entry)) }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Done") { runner.finish() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            case .sidebar:
                Button("Undo this switch…") { switchBack() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
                Spacer(minLength: 6)
                Button(runner.sidebarOpened ? "Open it again" : "Open the session") { runner.arrangeSidebar() }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Done") { runner.finish() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            case .done:
                // the keys that lead out are in the line at the top
                if arranges, runner.sidebarPlan != nil, !runner.sidebarOpened {
                    Spacer(minLength: 6)
                    Button("Arrange the sidebar…") { runner.arrangeSidebar() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                }
            }
        }
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String, _ detail: String, check: (String, DisplayWindow.Tone)? = nil) -> some View {
        let s = state(n)
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
                    Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(s == .pending ? face.muted : ring)
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
