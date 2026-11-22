// SwitchRunner: one profile's switch to another of its accounts (cl_quick's AccountSwitcher), for the Switch page
// (SwitchPage.swift). A profile is one Claude Code folder, and the folder holds one signed-in account at a time, so a
// switch is signing in again on the same folder, as the other account: Claude Code's own `claude auth login`, in
// Terminal with the address filled in, finished in the browser. The browser's claude.ai session decides which account
// signs in, so the result is checked: the folder's .claude.json is looked at every 2 s, for at most 10 minutes, until its
// account changes. Then:
//
//   reached     the folder is on the account wanted: the profile works on it, the one before stands by
//   other       the folder is on another account (the browser was signed in as someone else): the profile follows it
//               all the same (FolderRules.noteAccounts), and the page offers to sign in again as the one wanted
//   timed out   nothing signed in for 10 minutes: nothing changed
//
// Before the sign-in, a switch to a standby account moves the profile's Claude window sessions and scheduled tasks to
// that account, inside the profile's folder, the way claude-transplant does (SwitchEngine.swift): the window closes (its
// own quit, only that window, ClaudeWindow.swift's WindowHold) and stays closed until the switch is settled (the account
// reached, Undo, or Leave it as it is; then it opens again, SwitchEngine.settled); a backup is made first; the receipt keeps Undo
// possible until Claude Code is on the new account (reached: the receipt is linked). Sessions a running Claude Code owns
// are held where they are. With nothing to move (or a standby account whose ids aren't known yet), only the sign-in runs.
// Claude Code's transcripts stay in the folder; the Claude window's own sign-in is the person's to change: cl_audit never
// signs anything in or out, never sees a password or a token and never touches the Keychain. "Sign in again" on the
// account in use is the same watch with no move: the folder's account doesn't change then, so only Claude Code's login
// ending well (the script leaves a marker, ClaudeCLI.openLogin) says it's done.

import AppKit
import ProfileCore

final class SwitchRunner: ObservableObject {
    enum Phase: Equatable {
        case ready
        case closing                    // the profile's Claude window was asked to quit; waiting for it (at most 45 s)
        case moving                     // the backup, then the window's sessions and tasks move to the account wanted
        case waiting                    // Terminal shows Claude Code's sign-in; the folder is looked at every 2 s
        case reached                    // the folder is on the account wanted
        case other(String)              // the folder is on another account: its address
        case timedOut                   // no sign-in came in 10 minutes
        case failed(String)             // it couldn't start or the move stopped: why
        case undone                     // Undo put the moved sessions back
    }

    /// A switch under way: the account wanted, and the account the folder was on when it began.
    struct Goal: Equatable {
        var standby: String?            // the standby account's id; nil: signing in again on the account in use
        var wantedSeat: Seat?           // nil for an address remembered without a sign-in yet
        var wantedEmail: String
        var from: Seat?
        var started: Date
        /// Signing in again on the account already in use: the folder's account is the same before and after.
        var again: Bool { standby == nil && from != nil }
    }

    enum Outcome: Equatable { case reached, other(Seat), timedOut }

    /// How long a sign-in is waited for, and how often the folder is looked at.
    static let giveUp: TimeInterval = 10 * 60
    static let every: TimeInterval = 2

    let profile: String
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var goal: Goal?
    /// The account the switch went for, as it was on standby: once reached it isn't on standby any more, and the page keeps
    /// showing it from this copy.
    private(set) var targetSnapshot: StandbyAccount?
    /// The move's receipt (SwitchEngine): what moved, for Undo until Claude Code is on the new account.
    @Published private(set) var receipt: SwitchReceipt? { didSet { countStillMoved() } }
    /// What the receipt still has moved ("41 sessions, 3 tasks", movedWords), counted off the main thread whenever the
    /// receipt changes, never on a render: the tile and the What changed card read it. nil until the count lands (then
    /// `movedShown` gives the receipt's own record, without reading a file).
    @Published private(set) var stillMovedWords: String?
    private var countGeneration = 0

    /// What the tile and the card say is moved: the count, or until it lands what the receipt wrote down (recordedWords).
    var movedShown: String { stillMovedWords ?? receipt.map(Self.recordedWords) ?? "" }

    /// "41 sessions, 3 tasks" from what the receipt wrote down, without looking at the files (a first paint).
    static func recordedWords(_ r: SwitchReceipt) -> String {
        let s = r.moved, t = r.steps.contains { $0.kind == .tasks && $0.done } ? (r.tasksMoved ?? 1) : 0
        return [s > 0 ? "\(s) \(s == 1 ? "session" : "sessions")" : nil,
                t > 0 ? "\(t) \(t == 1 ? "task" : "tasks")" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private func countStillMoved() {
        countGeneration += 1
        let gen = countGeneration
        stillMovedWords = nil
        guard let r = receipt else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let w = Self.movedWords(r)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.countGeneration == gen else { return }
                self.stillMovedWords = w
            }
        }
    }

    // The notes below are kept as TEMPLATES: where a sentence names an account it holds a marker (`oldMark`, `toMark`) and the
    // runner keeps the address apart (`oldAccount`, `toAddress`). The page asks for the sentence (`moveText`, `leftText`,
    // `windowText`, `said`) when it draws, so it follows Show emails as it is then, never as it was when the note was made.
    /// The account a plan leaves things with: the one the profile was on before the switch, named by address.
    private(set) var oldAccount: String?
    /// The account an earlier stopped switch went for (showStopped), by address; else the goal's, else the target's.
    private(set) var stoppedTo: String?
    /// The page shows an earlier stopped switch (showStopped): its account is `stoppedTo` and nothing else. When that is nil (the
    /// receipt's account isn't among the profile's) it says "its account": the goal and the target belong to another switch.
    private(set) var stoppedShown = false
    static let oldMark = "{old}", toMark = "{to}"
    /// The address of the account the switch went for, nil when it has none.
    var toAddress: String? {
        if stoppedShown { return stoppedTo }
        return stoppedTo ?? [goal?.wantedEmail, targetSnapshot?.email].compactMap { $0 }.first { !$0.isEmpty }
    }
    /// A template as the page says it now: the accounts named as Show emails lets them be named.
    func said(_ template: String) -> String {
        template
            .replacingOccurrences(of: Self.oldMark, with: oldAccount.map(AccountNames.short) ?? "the old account")
            .replacingOccurrences(of: Self.toMark, with: toAddress.map(AccountNames.short) ?? (stoppedShown ? "its account" : "the account it went for"))
    }
    var moveText: String? { moveNote.map(said) }
    var leftText: String? { leftNote.map(said) }
    var windowText: String? { windowNote.map(said) }

    /// What the move said (a template: `moveText`): sessions held (a running Claude Code owns them), entries that didn't move,
    /// why tasks stayed.
    @Published private(set) var moveNote: String?
    /// What the old account keeps because it isn't a session entry ("Left with ann: …", leftWords; a template: `leftText`), apart
    /// from moveNote so a page can leave it out when nothing moved: the switch stopped before the move, so nothing was left behind.
    @Published private(set) var leftNote: String?
    /// Where the profile's Claude window stands once the switch let go of it: closed until the switch is settled (moved
    /// sessions not linked yet: windowStaysClosed), open again (windowOpenAgain), or watched after a Cancel (windowLateClose).
    /// nil: nothing to say (it wasn't closed by this switch). A template: `windowText`.
    @Published private(set) var windowNote: String?
    /// The plan before it ran: how many sessions and tasks move (the page's steps say it).
    @Published private(set) var planned: SwitchPlan?
    /// What the folder named at the switch's last look (the page's check line): the switch's own read, never the page's.
    @Published private(set) var seen: Seat?
    /// Where it failed, for the page's steps: before anything (refused), the window's close, the backup, the move, or
    /// Claude Code's sign-in. (The account check's own outcomes are the phases .other and .timedOut.)
    enum FailedStep: Equatable { case notStarted, closing, backup, move, signIn }
    @Published private(set) var failedStep: FailedStep?

    /// The tile's two lines for a switch that stopped: "nothing changed" only when nothing did; a switch that moved
    /// sessions before it stopped says how many, and that Undo puts them back.
    static func failedWords(_ r: SwitchReceipt?, moved: String? = nil) -> (l1: String, l2: String) {
        // changed: the receipt still has something to undo (sessions, tasks, a pointer line)
        guard let r, r.unfinished else { return ("Not started", "nothing changed") }
        let w = moved ?? movedWords(r)                         // (the runner's count, when it has one: no file reads here)
        return ("Stopped part way", (w.isEmpty ? "changed" : w + " moved") + " · Undo puts them back")
    }

    /// "41 sessions, 3 tasks": what a switch's receipt still has moved now (SwitchReceipt.stillMoved); "" when only a
    /// pointer line or a placed copy is left.
    static func movedWords(_ r: SwitchReceipt) -> String {
        let m = r.stillMoved()
        return [m.sessions > 0 ? "\(m.sessions) \(m.sessions == 1 ? "session" : "sessions")" : nil,
                m.tasks > 0 ? "\(m.tasks) \(m.tasks == 1 ? "task" : "tasks")" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// It stopped: where, and why.
    private func fail(_ at: FailedStep, _ why: String) { failedStep = at; phase = .failed(why) }
    private weak var model: SettingsModel?
    private var timer: Timer?
    /// This switch's hold on the profile's Claude window (ClaudeWindow.swift): its mark, its close, and reopening it.
    private var hold: WindowHold?
    private let reads = DispatchQueue(label: "cl_audit.switch-reads", qos: .utility)

    init(profile: String, model: SettingsModel) {
        self.profile = profile; self.model = model
    }

    var isRunning: Bool { phase == .closing || phase == .moving || phase == .waiting }

    /// The window mark's name for this switch (SwitchMarker): the window stays closed from the move until the sign-in ends.
    private var markName: String { "switch-" + (goal?.standby ?? "again") }

    /// The page's words for the window (windowNote).
    static func windowStaysClosed(_ to: String) -> String {
        "The Claude window stays closed until you Undo the move, sign in as \(to), or pick Leave it as it is on the Sessions card."
    }
    static let windowStaysPrefix = "The Claude window stays closed"
    static let windowOpenAgain = "The Claude window is open again."
    /// The window this switch asked to quit stalled (it was asking about work under way): if it closed by that answer since,
    /// the next try counts it as closed by this switch, so it opens again once the switch is settled.
    private var quitAsked = false

    /// The Switch page's key for the account it went for ("<profile>~<standby id>").
    var key: String { AccountEntry.switchKey(profile, goal?.standby ?? targetSnapshot?.id ?? "") }

    /// The account it went for, short ("ultra-2").
    var targetShort: String? { (goal?.wantedEmail ?? targetSnapshot?.email).map(AccountNames.short) }

    private var entry: AccountEntry? { model?.accounts.first { $0.id == profile } }

    /// The marker a sign-in again leaves when Claude Code's login ended well.
    /// Named after the profile id's hash, so a hand-edited id ("../x") never names a file outside cl_audit's folder. A
    /// Terminal sign-in that ends after a newer one began can leave its marker late; the newer run cleared the old one when
    /// it began and judges the folder's account first, so a late marker only ends a sign-in again whose account is
    /// already the one in use (cl_quick's SignIn works the same way).
    static func marker(for profile: String) -> URL { Store.folder.appendingPathComponent("signed-in-\(Account.sha8(profile)).done") }
    private func clearMarker() { try? FileManager.default.removeItem(at: Self.marker(for: profile)) }

    // MARK: going

    /// Switch to a standby account: the profile's Claude window closes, its sessions and scheduled tasks move to that
    /// account (SwitchEngine, with a backup first), then Claude Code's sign-in on the profile's folder with its address
    /// filled in, and the folder is watched. Nothing to move (or the account's ids aren't known yet: an address remembered
    /// without a sign-in): only the sign-in.
    func start(_ s: StandbyAccount) {
        guard !isRunning, let e = entry else { return }
        targetSnapshot = s; receipt = nil; moveNote = nil; leftNote = nil; windowNote = nil; planned = nil; failedStep = nil
        oldAccount = nil; stoppedTo = nil; stoppedShown = false
        let g = Goal(standby: s.id, wantedSeat: s.seat, wantedEmail: s.email,
                     from: Account.signedInSeat(configDir: e.configDir) ?? e.seat, started: Date())
        // the profile's folder deleted: nothing closes, moves or signs in (a sign-in would make it again), said instead
        if let why = ClaudeCLI.goneLine(e.configDir) { goal = g; fail(.notStarted, why); return }
        // a switch that stopped half way is put back first: never a second move on top of it
        if let u = SwitchEngine.unfinished(profile: profile).first {
            goal = g
            showStopped(u, e)
            return
        }
        // a restore or import that stopped half way, or the move to the default profile: said, which and where (Flows.swift)
        // (one that is still running holds cl_audit's lock: then it is said to be under way, not stopped)
        if let why = Flows.blocker(profile: profile, for: .switching) { goal = g; fail(.notStarted, Flows.busy() ?? why); return }
        guard e.seat != nil, s.seat != nil else { begin(e, g); return }
        switch SwitchEngine.plan(e, standby: s) {
        case .failure(let why): goal = g; fail(.notStarted, why.description)
        case .success(let p):
            planned = p
            oldAccount = p.from.email
            moveNote = Self.stayWords(p); leftNote = Self.leftBehind(p)
            // the finish line: the folder is on the target already; the switch goes from the Claude app's account
            var g = g
            if p.finishLine { g.from = p.from }
            if p.moves { closeAndMove(e, g) } else { begin(e, g) }
        }
    }

    /// An Undo that left some things as they were: what, and that Undo can be tried again.
    static func partlyWords(_ r: SwitchReceipt) -> String {
        // (said by kind and count, never by file name: the receipt keeps the names, the problems list says each)
        let left = r.left ?? []
        let entries = left.filter(ClaudeFiles.isEntryName).count
        let tasks = left.filter { $0 == TaskRegistry.fileName }.count
        let other = left.count - entries - tasks
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        let kinds = [entries > 0 ? n(entries, "Code-tab session", "Code-tab sessions") : nil,
                     tasks == 1 ? "the scheduled tasks file" : tasks > 1 ? n(tasks, "scheduled tasks file", "scheduled tasks files") : nil,
                     other > 0 ? n(other, entries + tasks > 0 ? "other file" : "file", entries + tasks > 0 ? "other files" : "files") : nil].compactMap { $0 }
        let shown = kinds.count > 1 ? kinds.dropLast().joined(separator: ", ") + " and " + kinds[kinds.count - 1] : kinds.first ?? "something"
        return "Partly undone: \(shown) \(left.count == 1 ? "was" : "were") left as \(left.count == 1 ? "it was" : "they were"). The rest is back; Undo again once that's sorted."
    }

    /// What stays where it is, and why: the sessions a running Claude Code owns, and the scheduled tasks (with their
    /// sessions) that can't move because of how the new account's own tasks differ. nil when nothing stays.
    static func stayWords(_ p: SwitchPlan) -> String? {
        var parts: [String] = []
        // (one that can't be read is held too, but not because Claude Code runs it: said apart)
        let owned = p.held.count - p.taskHeld.count - p.unreadable.count
        if owned > 0 { parts.append(heldWords(owned)) }
        if !p.unreadable.isEmpty { parts.append(unreadableWords(p.unreadable.count)) }
        if let why = p.taskStay {
            // named by address (the marker, filled when drawn): after the sign-in "the account in use" is the new one
            let out = p.taskStayTwin ? "Remove one of the two, then switch again." : "Fix that, then switch again."
            parts.append("The scheduled tasks stay with \(oldMark), and so do their sessions: \(why). \(out)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// What the plan leaves with the old account: its odd names, said in the past tense ("Left with ann: …"), kept in
    /// `leftNote` apart from stayWords. nil when none.
    static func leftBehind(_ p: SwitchPlan) -> String? {
        leftWords(p.odd, old: oldMark)
    }

    /// The names in the old account's folder shaped like a Code-tab session that aren't one: never moved, said (with the
    /// account they stay with, `old`, named by address like the tasks) so nobody thinks everything moved. nil when none.
    /// `before`: said before Switch is pressed, so "Will stay with ann: …" instead of "Left with ann: …".
    static func leftWords(_ odd: [SessionTransfer.Odd], old: String, before: Bool = false) -> String? {
        guard !odd.isEmpty else { return nil }
        let kinds: [(SessionTransfer.Odd, String, String)] = [(.link, "a link", "links"),
                                                             (.unknownName, "a file not named by an id", "files not named by an id"),
                                                             (.notAFile, "something that isn't a file", "things that aren't files")]
        let what = kinds.compactMap { k, one, many -> String? in
            let n = odd.filter { $0 == k }.count
            return n == 0 ? nil : n == 1 ? one : "\(n) \(many)"
        }
        let n = odd.count
        return "\(before ? "Will stay with" : "Left with") \(old): \(n) \(n == 1 ? "file named like a Code-tab session that isn't one" : "files named like a Code-tab session that aren't one") (\(what.joined(separator: ", ")))."
    }

    static func heldWords(_ n: Int) -> String {
        "\(n) \(n == 1 ? "session stays" : "sessions stay") with the account in use: Claude Code is running \(n == 1 ? "it" : "them") now. A later switch moves \(n == 1 ? "it" : "them") once \(n == 1 ? "it's" : "they're") closed."
    }

    /// Sessions held because their Code-tab record can't be read whole (too large, or unreadable): never "Claude Code is running".
    static func unreadableWords(_ n: Int) -> String {
        "\(n) \(n == 1 ? "session stays" : "sessions stay") with the account in use: \(n == 1 ? "its record" : "their records") couldn't be read. A later switch moves \(n == 1 ? "it" : "them") once \(n == 1 ? "it can" : "they can") be read."
    }

    /// The window closes (its own quit, which may ask about work under way; only this profile's window, by its data
    /// folder), and stays closed until the sign-in ends: no window opener starts it meanwhile (SwitchMarker, WindowHold).
    private func closeAndMove(_ e: AccountEntry, _ g: Goal) {
        goal = g
        let h = WindowHold(e, profile: profile, run: markName)
        guard h.claim() else {
            fail(.closing, "Another run on \(e.name)'s Claude window is under way (a restore, an import or a switch)."); return
        }
        hold = h
        // (closed by its own answer since an earlier try asked it to quit: still this switch's to open again)
        if h.isClosed { h.close(askedBefore: quitAsked, closed: {}, stalled: {}); quitAsked = false; move(e, g); return }
        phase = .closing
        h.close(closed: { [weak self] in
            guard let self, self.phase == .closing else { return }
            guard let e = self.entry else { self.hold?.release(); self.hold = nil; self.phase = .ready; return }   // the profile went meanwhile: never reopened
            self.quitAsked = false
            self.move(e, g)
        }, stalled: { [weak self] in
            guard let self else { return }
            self.hold = nil                                    // the mark is gone; the window is still open
            self.quitAsked = true
            self.fail(.closing, "\(e.name)'s Claude window didn't close; it may be asking about work under way. Answer it, then try again. Nothing moved.")
        })
    }

    /// The backup and the move, off the main thread (planned again now that the window is closed), then the sign-in.
    private func move(_ e: AccountEntry, _ g: Goal) {
        guard let s = targetSnapshot, case .success(let p) = SwitchEngine.plan(e, standby: s) else {
            windowDone(); fail(.move, "The switch couldn't be planned again. Nothing moved."); return
        }
        planned = p
        phase = .moving
        let closedIt = hold?.closedByUs == true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.run(p, windowClosed: { !ClaudeWindow.isOpen(Account(e)) }, closedWindow: closedIt) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let r):
                    self.receipt = r
                    self.oldAccount = p.from.email
                    let notes = (Self.stayWords(p).map { [$0] } ?? []) + r.problems
                    self.moveNote = notes.isEmpty ? nil : PlainWords.stored(notes)
                    self.leftNote = Self.leftBehind(p)
                    self.begin(e, g)
                case .failure(let err):
                    // stopped half way: its receipt, for Undo; nothing moved: nothing to put back
                    self.receipt = SwitchEngine.unfinished(profile: self.profile).first
                    self.windowDone()
                    // the backup, or (once it was made) the move itself
                    let backup: Bool = { if case .backup = err as? SwitchError { return true }; return false }()
                    self.fail(backup ? .backup : .move, PlainWords.why(err))
                }
            }
        }
    }

    /// The switch lets go of the window: its mark goes. While sessions it moved aren't linked yet (unsettled: Undo, Same
    /// account again or Leave it as it is to come) the window stays closed, and the page says so; once settled, the window it
    /// closed opens again (a receipt's own settle, SwitchEngine.settled, opens it for a move; with nothing moved, the hold).
    private func windowDone() {
        let h = hold ?? entry.map { WindowHold($0, profile: profile, run: markName) }
        hold = nil
        guard let h else { return }
        if let r = receipt, r.closedWindow == true || h.closedByUs {
            h.release()
            if r.unfinished { windowNote = Self.windowStaysClosed(Self.toMark) }
            else if entry?.claudeWindow == true { windowNote = Self.windowOpenAgain }       // settled: opened by its settle
            return
        }
        if receipt == nil, h.closedByUs, entry?.claudeWindow == true { windowNote = Self.windowOpenAgain }
        h.finish()                                             // nothing moved: the window it closed opens again
    }

    /// Undo: the move put back from its receipt (the window must be closed), before Claude Code is on the new account.
    func undo() {
        guard !isRunning, let r = receipt, r.linked == nil, r.undone == nil, let e = entry else { return }
        phase = .moving
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SwitchEngine.undoHolding(r.id, account: Account(e), windowClosed: { !ClaudeWindow.isOpen(Account(e)) }) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let back):
                    self.receipt = back
                    self.moveNote = back.problems.isEmpty ? nil : PlainWords.stored(back.problems)
                    self.leftNote = nil
                    // only partly: it stays open, and says what was left
                    if back.undone != nil {
                        self.phase = .undone
                        self.windowSettled(back)                   // (undone: its settle opens the window it closed)
                    } else { self.fail(.move, Self.partlyWords(back)) }
                case .failure(let err): self.fail(.move, PlainWords.why(err))
                }
            }
        }
    }

    /// Undo applies: a move that is neither linked nor undone.
    var canUndo: Bool { receipt.map { $0.unfinished } ?? false }

    /// Sign in again on the account in use (its sign-in stopped working, or the folder is signed out): the same watch.
    /// `email`: the address to sign in to (the caller's, ProfileShow.loginAddress); nil: the profile's seat, else the folder's.
    func signInAgain(email given: String? = nil) {
        guard !isRunning, let e = entry, let email = given ?? e.seat?.email ?? Account.expectedEmail(configDir: e.configDir) else { return }
        targetSnapshot = nil; receipt = nil; moveNote = nil; leftNote = nil; windowNote = nil; planned = nil; failedStep = nil
        // (the seat is the one to reach only when it is that address: another address is watched by its address)
        let seat = e.seat.flatMap { s in s.email.map { $0.lowercased() == email.lowercased() } == true ? s : nil }
        begin(e, Goal(standby: nil, wantedSeat: given == nil ? e.seat : seat, wantedEmail: email,
                      from: Account.signedInSeat(configDir: e.configDir), started: Date()))
    }

    /// The same account again (after another account signed in, or nothing did in time).
    func retry() {
        guard let g = goal, !isRunning else { return }
        if g.standby == nil { signInAgain(email: g.wantedEmail); return }
        // a finish line's move that stopped part way: Claude Code is on the account already, so a sign-in would finish
        // nothing and would link the half-done move; Undo, or Leave it as it is
        if canUndo, let r = receipt, Self.halfDoneFinishLine(r) {
            fail(.move, Self.finishLineStopped); return
        }
        // the sessions moved already (Undo not used): only the sign-in again, the window kept closed meanwhile
        if canUndo, let e = entry {
            let h = WindowHold(e, profile: profile, run: markName)
            guard h.claim() else {
                fail(.signIn, "Another run on \(e.name)'s Claude window is under way."); return     // the sign-in it was retrying
            }
            hold = h; windowNote = nil
            begin(e, Goal(standby: g.standby, wantedSeat: g.wantedSeat, wantedEmail: g.wantedEmail, from: g.from, started: Date()))
            return
        }
        if let s = entry?.standby.first(where: { $0.id == g.standby }) ?? targetSnapshot { start(s) }
    }

    private func begin(_ e: AccountEntry, _ g: Goal) {
        clearMarker()
        // the profile's folder deleted: never made again by a sign-in (FolderGuard), said instead
        if let why = ClaudeCLI.goneLine(e.configDir) { goal = g; windowDone(); fail(.signIn, why); return }
        // the folder on the account wanted already (the finish line: Claude Code was signed in to it elsewhere): there is no
        // sign-in to open, it is reached; what's left is the Claude app's own sign-in (the page says so)
        if g.standby != nil, let cur = Account.signedInSeat(configDir: e.configDir), Self.reached(g, cur),
           !(g.from.map { cur.same($0) } ?? false) {
            goal = g; end(.reached); return
        }
        guard let claude = model?.requireClaude() else { goal = g; windowDone(); fail(.signIn, model?.noClaudeWhy ?? ClaudeInstall.missing + "."); return }
        let started = ClaudeCLI.startLogin(claude, account: Account(e), email: g.wantedEmail.isEmpty ? nil : g.wantedEmail,
                                           marker: g.again ? Self.marker(for: profile) : nil)
        guard started == .opened else {
            goal = g; windowDone(); fail(.signIn, Self.loginWords(started, folder: e.configDir)); return
        }
        goal = g
        phase = .waiting
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in self?.look() }
    }

    /// Stops waiting: nothing changed, so there is nothing to put back.
    /// While the window closes: nothing moved; it was asked to quit already, so if it closes by its own answer within a
    /// minute it is opened again (WindowHold.cancelClosing).
    /// While the sign-in is waited for after a move: the moved sessions stay where they went, and Undo puts them back; the
    /// window stays closed until then (windowDone).
    func cancel() {
        guard phase != .moving else { return }               // the move finishes or stops by itself
        timer?.invalidate(); timer = nil
        clearMarker()
        if phase == .closing, let h = hold {
            hold = nil
            if h.cancelClosing(busy: { [weak self] in self?.isRunning ?? true }, watched: { [weak self] in
                if self?.windowNote == Self.windowLateClose { self?.windowNote = nil }
            }) { windowNote = Self.windowLateClose }
        } else {
            windowDone()
        }
        if phase == .waiting || phase == .closing { phase = .ready }
    }

    /// A switch this page shows was settled (undone, left as it is): the window it closed is opened by the receipt's settle
    /// (SwitchEngine.settled); the page says so instead of "stays closed".
    func windowSettled(_ r: SwitchReceipt) {
        guard r.closedWindow == true else { if windowNote?.hasPrefix(Self.windowStaysPrefix) == true { windowNote = nil }; return }
        windowNote = entry?.claudeWindow == true ? Self.windowOpenAgain : nil
    }

    /// Why Claude Code's sign-in didn't open, in the switch step's words (ClaudeCLI.loginWords, then its Try again key).
    static func loginWords(_ s: ClaudeCLI.LoginStart, folder: String) -> String {
        let w = ClaudeCLI.loginWords(s, folder: folder)
        return s == .alreadyOpen || s == .cantTell ? w + " Then Try again." : w
    }

    static let windowLateClose = "The Claude window was already asked to quit: if it closes, cl_audit opens it again."

    /// Back to the start, for another switch from the page.
    func reset() { cancel(); guard phase != .moving else { return }; phase = .ready; goal = nil; moveNote = nil; leftNote = nil; planned = nil; failedStep = nil
        quitAsked = false; oldAccount = nil; stoppedTo = nil; stoppedShown = false
        if windowNote != Self.windowLateClose { windowNote = nil }          // (a Cancel's late-close watch still says its line)
        if !canUndo { receipt = nil }
        // a switch of this profile that moved sessions, closed the window and isn't settled holds the window closed: the page
        // shows it at once (its Undo, and why the window stays closed), as Switch would; a click on the window comes here
        if let e = entry, let u = SwitchEngine.unfinished(profile: profile).first, u.closedWindow == true { showStopped(u, e) }
    }

    /// An earlier switch of this profile that stopped half way: shown as the page's own stop (its Undo below), with the
    /// window's line when it closed the window.
    /// A finish line's move that stopped before it finished: never linked by a sign-in (none is left to make), only by Undo
    /// or Leave it as it is.
    static func halfDoneFinishLine(_ r: SwitchReceipt) -> Bool { r.finishLine == true && r.finished == nil }
    static let finishLineStopped = "The move stopped part way. Claude Code is on that account already, so there's no sign-in to finish it: Undo puts the moved sessions back, or Leave it as it is (Sessions card)."

    private func showStopped(_ u: SwitchReceipt, _ e: AccountEntry) {
        receipt = u
        // never for good: Undo puts it back, and signing in as the account it went for finishes it (linkReached)
        // (the account it went for is kept by address; the failure text and the window's line hold its marker, `said` at draw time)
        stoppedTo = ([e.seat] + e.standby.map(\.seat)).compactMap { $0 }.first { u.to.same($0) }?.email
        stoppedShown = true                                          // (an account of none of the profile's: "its account", never the goal's)
        let to = Self.toMark
        if Self.halfDoneFinishLine(u) {
            fail(.notStarted, "An earlier switch of \(e.name) stopped half way. \(Self.finishLineStopped) Then switch again.")
            if u.closedWindow == true { windowNote = Self.windowStaysClosed(to) }
            return
        }
        fail(.notStarted, "An earlier switch of \(e.name) stopped half way. Undo it (below, or on the Sessions card), sign in as \(to) to finish it, or Leave it as it is (Sessions card); then switch again.")
        if u.closedWindow == true { windowNote = Self.windowStaysClosed(to) }
    }

    /// One look at the folder: its file is read off the main thread, and what it said is judged here, on the main thread.
    func look() {
        guard phase == .waiting, let g = goal else { return }
        // the profile was removed while its sign-in was waited for: stop looking (nothing to note it on)
        guard let e = entry else { cancel(); return }
        let dir = e.configDir, marker = Self.marker(for: profile)
        reads.async { [weak self] in
            let now = Account.signedInSeat(configDir: dir)
            let done = FileManager.default.fileExists(atPath: marker.path)
            DispatchQueue.main.async {
                guard let self, self.phase == .waiting, self.goal == g else { return }
                if self.seen != now { self.seen = now }
                if let o = Self.judge(g, now: now, markerDone: done) { self.end(o) }
            }
        }
    }

    /// What the folder says for a goal: reached, another account, timed out, or nil (still waiting). Signed out for a moment
    /// is still waiting. The account wanted is found by its ids, or by its address when it has none yet.
    static func judge(_ g: Goal, now: Seat?, markerDone: Bool, at: Date = Date()) -> Outcome? {
        if at.timeIntervalSince(g.started) > giveUp { return .timedOut }
        guard let cur = now else { return nil }
        if g.again {
            // the same account is no news until Claude Code's login says it ended well; another account is news at once
            if let from = g.from, cur.same(from) { return markerDone ? .reached : nil }
            return .other(cur)
        }
        if let from = g.from, cur.same(from) { return nil }
        return reached(g, cur) ? .reached : .other(cur)
    }

    static func reached(_ g: Goal, _ cur: Seat) -> Bool {
        // an account found by its id alone (no organisation known): the same account id is it
        if let w = g.wantedSeat { return w.organization == nil ? w.account.lowercased() == cur.account.lowercased() : w.same(cur) }
        return cur.email.map { $0.lowercased() == g.wantedEmail.lowercased() } ?? false
    }

    private func end(_ o: Outcome) {
        timer?.invalidate(); timer = nil
        clearMarker()
        // Claude Code on the account the sessions went to: the move is linked (the way back is a switch the other way)
        // (never a finish line's half-done move: nothing a sign-in did finished it)
        if o == .reached, let r = receipt, !Self.halfDoneFinishLine(r) { SwitchEngine.markLinked(r.id); receipt = SwitchEngine.store.load(r.id) ?? r }
        windowDone()                                          // (linked: its settle opens the window it closed, after this turn)
        // the account now in the folder is the one the profile works on, at once (the agent would within seconds too)
        if o != .timedOut { model?.noteAccounts(); model?.resolveNow(profile) }
        switch o {
        case .reached: phase = .reached
        case .other(let s): phase = .other(s.email ?? "another account")
        case .timedOut: phase = .timedOut
        }
    }

    /// Renders only: the page as it looks in a phase.
    func preview(_ p: Phase, goal g: Goal?, target: StandbyAccount? = nil, planned plan: SwitchPlan? = nil, receipt r: SwitchReceipt? = nil,
                 note: String? = nil, left: String? = nil, seen s: Seat? = nil, failedAt f: FailedStep? = nil,
                 window: String? = nil, old: String? = nil, stoppedTo to: String? = nil) {
        phase = p; goal = g; targetSnapshot = target ?? targetSnapshot
        planned = plan; receipt = r; moveNote = note; leftNote = left; seen = s; failedStep = f
        windowNote = window; oldAccount = old; stoppedTo = to; stoppedShown = to != nil
    }
}
