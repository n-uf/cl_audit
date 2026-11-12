// SwitchPage: one switch of a profile to another of its accounts (SwitchRunner.swift runs it), from before anything
// happens to the outcome. A switch signs Claude Code in again on the profile's own folder, as the other account, and moves
// nothing: the page says what that changes (Claude Code on that folder, sessions running now included) and what doesn't
// (the sessions stay in the folder, each with its account; the Claude window keeps its own sign-in).
//
//   Ready        the account in use (lit) and the one picked; Switch to ultra-2
//   Waiting      Terminal shows Claude Code's sign-in; the folder is looked at every 2 s, for 10 minutes
//   Reached      Main works on ultra-2 · ultra-1 on standby
//   Other        signed in as ultra-3, not ultra-2: the profile is on ultra-3 now (unless another profile works on it)
//   Timed out    no sign-in in 10 minutes: nothing changed
//
// Display colours, one meaning each: green = in use; mint = switching and the account switched to; amber = waiting for
// you, or a warning; red = something failed. Only the account in use is lit.

import AppKit
import SwiftUI

struct SwitchPage: View {
    let entry: AccountEntry
    let standby: StandbyAccount
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner
    var width: CGFloat = 980
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    /// A sign-in again on the account in use (no standby account picked).
    private var again: Bool { runner.goal?.again == true }
    /// The account it goes to (or went to), short.
    private var to: String { AccountNames.short(runner.goal.map { $0.wantedEmail.isEmpty ? standby.label : $0.wantedEmail } ?? standby.label) }
    /// The account it came from, short: the one in use when it began.
    private var from: String {
        AccountNames.short(runner.goal?.from?.email ?? view.numbersOwner ?? "its account")
    }
    /// What the folder is signed in to now (its .claude.json, read again only when it changed).
    private var seen: Seat? { runner.seen }
    /// The profile's account as its record says it (AccountResolver).
    var view: AccountView { _ = model.tick; return AccountView.of(Store.status(for: entry)) }
    /// The account landed on is another profile's account in use: the profile didn't follow it.
    private var clash: (seat: Seat?, owner: String)? { view.clash.map { (nil, $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            if let t = topLine { topBar(t) }
            // once undone, no steps: ticked steps would read as if the move had happened
            SettingsColumns(width: width, groups: [[AnyView(accountsCard)],
                                                   runner.phase == .undone ? [AnyView(changesCard)] : [AnyView(changesCard), AnyView(stepsCard)]])
        }
    }

    /// After a switch: Claude Code is on the account wanted, but the Claude app (the record's account in use, A's rule) is
    /// still on another one until it's signed in there. Then the page says both, never only "Now on …".
    private var appBehind: Bool {
        guard runner.phase == .reached, !again, let a = view.label?.lowercased(),
              let w = runner.goal?.wantedEmail.lowercased(), !w.isEmpty else { return false }
        return a != w && view.numbersOwner?.lowercased() == w
    }
    private var appShort: String { AccountNames.short(view.label ?? "another account") }

    private var title: String {
        if appBehind { return "Switched Claude Code of \(name) to \(to)" }
        if again { return runner.phase == .reached ? "Logged Claude \(name) in" : "Log Claude \(name) in" }
        switch runner.phase {
        case .closing, .moving, .waiting: return "Switching Claude \(name) to \(to)"
        case .reached: return "Switched Claude \(name) to \(to)"
        case .other(let e): return "Claude \(name) signed in as \(AccountNames.short(e))"
        default: return "Switch Claude \(name) to \(to)"
        }
    }

    // MARK: the line at the top: how far it got, and the keys that lead out

    private struct Top { var text: String; var dim: String?; var tone: DisplayWindow.Tone }

    /// The strip's words for a switch running or stopped (waiting, closing, moving, failed); nil for the other phases, whose
    /// words need the page's accounts. Settings ▸ Accounts says the same words (`settingsStrip`).
    static func strip(_ phase: SwitchRunner.Phase, again: Bool, canUndo: Bool, started: Date?) -> (text: String, dim: String?, tone: DisplayWindow.Tone)? {
        switch phase {
        case .waiting:
            let until = (started ?? Date()).addingTimeInterval(SwitchRunner.giveUp)
            // short words: the display never gets wider than the page (it is one line)
            return (again ? "Signing in" : "Switching", "· waiting · until \(until.formatted(date: .omitted, time: .shortened))", .mint)
        case .failed:
            if canUndo { return ("Stopped", "· Undo puts it back", .warn) }
            return ("Not started", "· nothing changed", .warn)
        case .closing: return ("Switching", "· closing the window", .mint)
        case .moving: return ("Switching", "· moving sessions", .mint)
        default: return nil
        }
    }

    /// The one line Settings ▸ Accounts shows about a switch of the profile (B5): while it runs (closing, moving, the
    /// sign-in waited for), and when it was refused before anything (a gone folder); in the Switch page's strip words. Its
    /// rows stay as they are meanwhile. nil otherwise (and for a sign-in again, which its in-use box says itself).
    static func settingsStrip(_ phase: SwitchRunner.Phase, again: Bool, canUndo: Bool, failedAt: SwitchRunner.FailedStep?,
                              started: Date?) -> (text: String, dim: String?, tone: DisplayWindow.Tone)? {
        guard !again else { return nil }
        switch phase {
        case .closing, .moving, .waiting: return strip(phase, again: false, canUndo: canUndo, started: started)
        case .failed where failedAt == .notStarted && !canUndo: return strip(phase, again: false, canUndo: false, started: started)
        default: return nil
        }
    }

    private var topLine: Top? {
        if let s = Self.strip(runner.phase, again: again, canUndo: runner.canUndo, started: runner.goal?.started) {
            return Top(text: s.text, dim: s.dim, tone: s.tone)
        }
        switch runner.phase {
        case .ready: return nil
        case .waiting, .closing, .moving, .failed: return nil       // said by `strip` above
        case .reached:
            if again { return Top(text: "Logged in", dim: "· \(to)", tone: .ok) }
            if appBehind { return Top(text: "Claude Code on \(to)", dim: "· the Claude app still on \(appShort)", tone: .amber) }
            return Top(text: "Now on \(to)", dim: "· \(from) on standby", tone: .ok)
        case .other(let e):
            if let c = clash { return Top(text: "Signed in as \(AccountNames.short(e))", dim: "· \(c.owner)'s account", tone: .warn) }
            return Top(text: "Signed in as \(AccountNames.short(e))", dim: "· not \(to)", tone: .amber)
        case .timedOut:
            if runner.canUndo { return Top(text: "No sign-in", dim: "· sessions on \(to)", tone: .amber) }
            return Top(text: "No sign-in", dim: "· nothing changed", tone: .amber)
        case .undone: return Top(text: "Undone", dim: "· still on \(from)", tone: .ok)
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

    @ViewBuilder private var topKeys: some View {
        switch runner.phase {
        case .waiting:
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .reached:
            if !again, let back = cameFrom {
                Button("Switch back to \(AccountNames.short(back.email))…") { model.showSwitch(AccountEntry.switchKey(entry.id, back.id)) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
            Button("Back to \(name)'s settings") { leave() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .other(let e):
            Button(again ? "Log in…" : "Sign in as \(to) again") { runner.retry() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            if runner.canUndo { undoKey }
            if clash == nil, !runner.canUndo {
                Button("Keep \(AccountNames.short(e))") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
        case .timedOut, .failed:
            Button("Try again") { runner.retry() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            if runner.canUndo { undoKey }
            Button("Back to \(name)'s settings") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
        case .closing:
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .undone:
            Button("Back to \(name)'s settings") { leave() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .ready, .moving:
            EmptyView()
        }
    }

    /// Undo the move: the sessions back under the account in use (the window must be closed; it is, until the sign-in ends).
    private var undoKey: some View {
        Button("Undo the move") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            .help("Puts \(name)'s sessions and scheduled tasks back under \(from), from the switch's receipt. Quit \(name)'s Claude window first if it's open.")
    }

    /// Back to the profile's settings; the page starts over the next time it opens.
    private func leave() {
        // while the sign-in is waited for, Back only leaves the page: the watch goes on (the tile and the alert say so)
        if !runner.isRunning { runner.reset() }
        model.selection = entry.id
    }

    /// The account it was on before, now on standby (by its ids).
    private var cameFrom: StandbyAccount? {
        guard let from = runner.goal?.from else { return nil }
        return entry.standby.first { from.same($0.seat) }
    }

    // MARK: accounts: NOW lit, TO picked (in mint)

    private var accountsCard: some View {
        SCard(title: "Accounts", info: "The account \(name) works on now, with its limits, and the one it switches to. A standby account isn't read, so it shows no limits: only when it was last in use here.") {
            VStack(alignment: .leading, spacing: 12) {
                labelled("Now") { inUseBox }
                if runner.phase == .reached, !again, let was = cameFrom {
                    // never the account in use on standby too: the Claude app may still be on it (not signed in to the
                    // new account yet), and then it's in use, not "before"
                    if !view.isActive(was) { labelled("Before") { standbyBox(was, selected: false) } }
                } else if !again, !(runner.phase == .reached) {
                    let list = pickList
                    labelled(runner.phase == .ready ? "To" : runner.phase == .waiting ? "Next" : "Wanted") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(list) { s in standbyBox(s, selected: s.id == standby.id) }
                            if runner.phase == .ready, list.count > 1 {
                                Text("The one offered first is on top. Click another to switch to it instead.")
                                    .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Before it starts, every standby account, the one a full limit offers first on top; once it runs, only the one it
    /// switches to.
    /// Never the account in use (the record's): the same list as every other screen's (`listed(by:)`).
    var pickList: [StandbyAccount] {
        guard runner.phase == .ready else { return [standby] }
        let all = AccountBook.offerOrder(entry.listed(by: view).standby)
        if view.isActive(standby) { return all }
        return all.contains { $0.id == standby.id } ? all : [standby] + all
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(face.muted).lineLimit(1).fixedSize().frame(width: 56, alignment: .leading).padding(.top, 12)
            content()
        }
    }

    private var inUseBox: some View {
        // the active account and the one line of state, from the profile's record (AccountResolver)
        let st = Store.status(for: entry)
        let v = AccountView.of(st)
        let detail = st?.plan.map(Account.planWords) ?? ""
        let row = AccountRow(entry: entry, status: st)
        return AccountBox(lamp: v.lit ? FaceTheme.ledOn : nil, badge: "In use", badgeTone: v.lit ? .ok : .warn, detail: detail) {
            Text(Privacy.masked(v.label ?? "its account")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
        } content: {
            if let n = v.line { BoxText(text: n, role: .note) }
            if row.limits.contains(where: { $0.p != nil }) {
                CardLimits(limits: row.limits, design: DashboardPrefs.shared.cardStyle, credits: st?.credits, fullBox: false)
            } else {
                BoxText(text: "No numbers yet: the agent reads them within a few minutes.", role: .note)
            }
        }
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

    /// A standby account: its address, plan and when it was last in use. No limits: it isn't read.
    private func standbyBox(_ s: StandbyAccount, selected: Bool) -> some View {
        let pickable = runner.phase == .ready && !selected && s.seat != nil
        func box(_ lit: String?) -> some View {
            AccountBox(lamp: nil, badge: "Standby", detail: s.plan.map(Account.planWords),
                       unlit: !selected, selected: selected, litBadge: lit) {
                BoxText(text: Privacy.masked(s.label), role: selected ? .title : .softTitle)
            } content: {
                BoxText(text: (s.lastInUse.map { "Last in use " + AccountBook.ago($0) } ?? "Not in use on \(name) yet") + ".", role: .note)
            }
        }
        // the lit badge while it's going: "Switching to" when the address fits beside it in the box's own width, else the
        // short "To"; once it has ended the account wanted is still a standby account, and says so
        let going = selected && (runner.phase == .ready || runner.phase == .waiting)
        return Group {
            if going {
                ViewThatFits(in: .horizontal) { box("Switching to"); box("To") }
            } else {
                box(nil)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard pickable else { return }
            model.showSwitch(AccountEntry.switchKey(entry.id, s.id))
        }
    }

    // MARK: what changes, and what doesn't

    @ViewBuilder private var changesCard: some View {
        if again { againCard } else { switchChanges }
    }

    /// A sign-in again on the account in use: the same account, so nothing moves to anything.
    private var againCard: some View {
        SCard(title: "What changes", info: "Log in: Claude Code's own sign-in on \(name)'s folder, as the account in use, in Terminal, finished in the browser. It moves nothing.") {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value("Claude Code on \(entry.configDir) logs in as \(to). Sessions and the Claude window are not touched.")
            }
        }
    }

    @ViewBuilder private var switchChanges: some View {
        switch runner.phase {
        case .ready, .closing, .moving, .waiting: switchPlan
        case .reached: switchDone
        case .other(let e): switchOther(e)
        case .timedOut, .failed, .undone: switchNothing
        }
    }

    private var changesInfo: String { "A switch moves \(name)'s Claude window sessions and scheduled tasks from the account in use to the other one, inside \(name)'s folder (claude-transplant's way: with a backup first, a receipt and Undo), then signs Claude Code in again on that folder as the other account, in Terminal, finished in the browser. The Claude app's own sign-in is yours to change: cl_audit never signs anything in or out." }

    /// What this switch moves: the plan it ran with, or (before it starts) one read now. Sessions a running Claude Code
    /// owns are counted when it starts.
    private var plan: SwitchPlan? {
        if let p = runner.planned { return p }
        guard runner.phase == .ready, !again, standby.seat != nil,
              case .success(let p) = SwitchEngine.plan(entry, standby: standby, owned: []) else { return nil }
        return p
    }
    private var moves: Bool { plan?.moves == true || runner.receipt != nil }

    private func sessionWords(_ p: SwitchPlan?) -> String {
        guard let p, p.moves else { return "none of the Claude window's sessions are on \(from), so nothing moves" }
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var parts: [String] = []
        if !p.move.isEmpty { parts.append(n(p.move.count, "Code-tab session", "Code-tab sessions")) }
        if p.tasks > 0 { parts.append(n(p.tasks, "scheduled task", "scheduled tasks")) }
        return parts.joined(separator: " and ")
    }

    /// Once it reached the account: what is true now, in the past tense.
    private var switchDone: some View {
        SCard(title: "What changed", info: changesInfo) {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value("Terminal and editors on \(entry.configDir) work on \(to) now, sessions that were running included.")
            }
            SRow(label: "Sessions", stacked: true) {
                value(runner.receipt != nil
                      ? "\(sessionWords(plan).prefix(1).uppercased() + sessionWords(plan).dropFirst()) moved to \(to), with a backup made first. Claude Code's transcripts stayed in \(entry.configDir)."
                      : "Nothing moved: none of the Claude window's sessions were on \(from).")
            }
            if appBehind {
                SRow(label: "Claude window", stacked: true) {
                    value("Claude Code is on \(to). The Claude app is still on \(appShort): sign it in to \(to) there to finish (\(entry.windowWords)). Until then \(appShort) is the account in use.")
                }
            } else if entry.claudeWindow {
                SRow(label: "Claude window", stacked: true) {
                    value("Open it and sign it in to \(to) yourself (\(entry.windowWords)): its sessions show on that account.")
                }
            }
            SRow(label: "Stayed", stacked: true) { value("\(name)'s name, Dock icon, look, folder and settings") }
            if !appBehind { SRowLine(text: "\(from) stands by on \(name) now: nothing read, switch back any time.") }
            if let n = runner.moveNote { SRowLine(text: n) }
        }
    }

    /// Another account signed in: what the folder is on now, and where the moved sessions are.
    private func switchOther(_ e: String) -> some View {
        SCard(title: "What changed", info: changesInfo) {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value("Terminal and editors on \(entry.configDir) signed in as \(AccountNames.short(e)), not \(to).")
            }
            if runner.canUndo {
                SRow(label: "Sessions", stacked: true) {
                    value("\(sessionWords(plan).prefix(1).uppercased() + sessionWords(plan).dropFirst()) moved to \(to) already. Sign in as \(to) again, or Undo the move to put them back under \(from).")
                }
            }
        }
    }

    /// No sign-in, stopped, or undone: what is where now.
    private var switchNothing: some View {
        SCard(title: "What changed", info: changesInfo) {
            if runner.canUndo {
                SRow(label: "Sessions", first: true, stacked: true) {
                    // what the receipt really has moved now (the same numbers as the tile), not the whole plan
                    let w = runner.receipt.map(SwitchRunner.movedWords) ?? ""
                    value((w.isEmpty ? "Part of the move" : w.prefix(1).uppercased() + w.dropFirst()) + " moved to \(to); Claude Code on \(entry.configDir) is still on \(from). Try again, or Undo the move to put them back.")
                }
            } else {
                SRow(label: "Nothing", first: true, stacked: true) {
                    value(runner.phase == .undone
                          ? "The move is undone: \(name)'s sessions and scheduled tasks are back under \(from), and Claude Code is still on \(from)."
                          : "\(name) is still on \(from): Claude Code on \(entry.configDir), its sessions, the Claude window and \(name)'s settings are as they were.")
                }
            }
            if let n = runner.moveNote { SRowLine(text: n) }
        }
    }

    private var switchPlan: some View {
        let isDefault = Account(entry).isDefaultDir
        return SCard(title: "What changes", info: changesInfo) {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value(AccountBook.switchWords(folder: entry.configDir, email: Privacy.masked(runner.goal?.wantedEmail ?? standby.email), isDefault: isDefault))
            }
            SRow(label: "Sessions", stacked: true) {
                value(moves
                      ? "\(sessionWords(plan).prefix(1).uppercased() + sessionWords(plan).dropFirst()) move from \(from) to \(to), inside \(name)'s folder, with a backup made first. A session Claude Code is running stays with \(from) until a later switch. Transcripts stay in \(entry.configDir)."
                      : standby.seat == nil ? "Nothing moves now: \(to) hasn't been signed in on this Mac, so its sessions' folder isn't known yet."
                      : "Nothing moves: \(sessionWords(plan)).")
            }
            if entry.claudeWindow {
                SRow(label: "Claude window", stacked: true) {
                    value(moves ? "It closes for the move (\(entry.windowWords)). Sign it in to \(to) yourself when you open it again: cl_audit never signs it in or out."
                                : "Its own sign-in stays as it is (\(entry.windowWords)): sign it in to \(to) yourself if you like.")
                }
            }
            SRow(label: "Stays", stacked: true) { value("\(name)'s name, Dock icon, look, folder and settings") }
            SRowLine(text: "\(from) stays on \(name) as a standby account: nothing read, switch back any time.")
            if let n = runner.moveNote { SRowLine(text: n) }
        }
    }

    // MARK: the steps

    enum StepState { case pending, now, waiting, done, failed }

    private func state(_ n: Int) -> StepState { Self.stepState(n, phase: runner.phase, failedAt: runner.failedStep, moves: moves) }

    /// The sign-in's three steps, after the window's close and the move when the switch moves sessions (steps 1 and 2).
    /// A failure marks the step where it stopped (`failedAt`, from the runner), the ones before it done: the window that
    /// didn't close is step 1; the backup or the move, step 2; Claude Code's sign-in, the first of its steps; refused before
    /// anything started, no step at all (the line under them says why).
    static func stepState(_ n: Int, phase: SwitchRunner.Phase, failedAt at: SwitchRunner.FailedStep?, moves: Bool) -> StepState {
        let k = moves ? 2 : 0                                  // the sign-in's steps start after the move's
        let failedAt: Int? = {
            switch at {
            case .notStarted: return nil
            case .closing: return moves ? 1 : nil
            case .backup, .move: return moves ? 2 : nil
            case .signIn, nil: return k + 1
            }
        }()
        switch phase {
        case .ready: return .pending
        case .closing: return n == 1 ? .now : .pending
        case .moving: return n == 1 ? .done : n == 2 ? .now : .pending
        case .waiting: return n <= k + 1 ? .done : n == k + 2 ? .waiting : .now
        case .reached: return .done
        case .other: return n < k + 3 ? .done : .failed
        case .timedOut: return n <= k + 1 ? .done : n == k + 2 ? .failed : .pending
        case .failed:
            guard let f = failedAt else { return .pending }
            return n < f ? .done : n == f ? .failed : .pending
        case .undone: return n <= k ? .done : .pending
        }
    }

    private var stepsCard: some View {
        let k = moves ? 2 : 0
        return SCard(title: "Steps", info: "When the switch moves sessions: the profile's Claude window closes, a backup is made, the sessions and scheduled tasks move (with a receipt, for Undo). Then Claude Code's own sign-in, and a check of the account it signed in. cl_audit never sees a password or a token. cl_audit itself never reads or writes Keychain items during a switch; Claude Code's own sign-in updates its own item.") {
            ClaudeMissingLine(model: model)
            VStack(alignment: .leading, spacing: 0) {
                if moves {
                    step(1, "\(name)'s Claude window closes", "Only that window, by its own quit; it stays closed until the sign-in ends.")
                    step(2, "Its sessions move to \(to)", "A backup first, then \(sessionWords(plan)), each checked; a receipt keeps Undo possible.")
                }
                step(k + 1, "Claude Code's sign-in opens in Terminal", "For \(entry.configDir), with \(Privacy.masked(runner.goal?.wantedEmail ?? standby.email)) filled in.")
                step(k + 2, "Finish it in the browser as \(to)", "If the browser is signed in to claude.ai as someone else, switch its account there first.")
                step(k + 3, again ? "cl_audit checks Claude Code's sign-in ended well" : "cl_audit checks the account",
                     "The folder is looked at every 2 seconds, for up to 10 minutes.", check: check)
            }
            // the keys, then the line under them: one under the other, never side by side
            VStack(alignment: .leading, spacing: 8) {
                keys
                if let line = statusLine {
                    Text(line).font(.system(size: 10.5)).foregroundStyle(isBad ? face.danger : face.muted)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
        }
    }

    private var isBad: Bool {
        if case .failed = runner.phase { return true }
        return clash != nil && runner.phase != .ready
    }

    /// What the folder says now: ✓ on the account wanted, amber on another (by its ids).
    private var check: (String, DisplayWindow.Tone)? {
        guard runner.phase != .ready, let s = seen else { return nil }
        let short = AccountNames.short(s.email ?? "another account")
        if case .other = runner.phase { return ("Claude Code · \(short) · not \(to)", .amber) }
        if runner.phase == .reached { return ("Claude Code · \(to) ✓", .ok) }
        return ("Claude Code · \(short) now", .normal)
    }

    private var statusLine: String? {
        switch runner.phase {
        case .ready:
            return standby.seat == nil ? "Remembered by its address: the sign-in tells which account it is." : nil
        case .closing:
            return "Waiting for \(name)'s Claude window to quit (it may ask about work under way). Nothing has moved yet."
        case .moving:
            return runner.receipt == nil ? "Making the backup, then moving the sessions. The window stays closed." : "Putting the sessions back."
        case .waiting:
            if again { return "Nothing else changes: \(name) stays on \(from). cl_audit waits for Claude Code's sign-in to end. Back keeps waiting." }
            if runner.receipt != nil { return "The sessions are under \(to) now; Claude Code stays on \(from) until Claude Code is signed in as another account. Back keeps waiting." }
            return "Nothing has changed yet: \(name) stays on \(from) until Claude Code is signed in as another account. Back keeps waiting."
        case .reached:
            if again { return "Claude Code's sign-in on \(entry.configDir) works again." }
            return entry.claudeWindow ? "Open \(name)'s Claude window and sign it in to \(to): cl_audit doesn't sign the app in or out." : nil
        case .other(let e):
            if let c = clash {
                return "\(Privacy.masked(e)) is \(c.owner)'s account, so \(name) doesn't take it: its numbers wait until you sign in as \(to) (or another of \(name)'s accounts)."
            }
            return "\(name) works on \(AccountNames.short(e)) now, and \(from) is on standby. To get \(to), switch the browser's claude.ai account first, then sign in again."
        case .timedOut:
            return runner.canUndo ? "No sign-in came in 10 minutes: Claude Code is still on \(from)." : "Nothing changed: \(name) is still on \(from)."
        case .failed(let why):
            return why
        case .undone:
            return runner.moveNote
        }
    }

    @ViewBuilder private var keys: some View {
        HStack(spacing: 10) {
            Button("Back") { leave() }.buttonStyle(.plain).foregroundStyle(face.muted)
            Spacer(minLength: 6)
            switch runner.phase {
            case .ready:
                Button("Switch to \(to)") { runner.start(standby) }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                    .disabled(standby.seat == nil && standby.email.isEmpty)
            case .waiting:
                Button("Show Terminal") { _ = Installer.run("/usr/bin/open", ["-a", "Terminal"]) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true))
            default:
                EmptyView()
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
