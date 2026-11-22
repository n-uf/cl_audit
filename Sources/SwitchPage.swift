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

import AddressPrivacy
import AppKit
import ProfileCore
import SwiftUI

struct SwitchPage: View {
    let entry: AccountEntry
    let standby: StandbyAccount
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner
    var width: CGFloat = 980
    @Environment(\.face) private var face
    /// Its sentences and help name the accounts by the setting (AddressSettings.words): redrawn when it changes.
    @ObservedObject private var privacy = AddressPrivacy.shared
    /// A switch (or its retry) waiting for consent (Experimental.swift): it starts only from the sheet's Continue.
    @State private var consent: ConsentRequest?
    /// A clash move-back as it was when the switch started, and whose account the folder was signed in to: once Claude Code is
    /// back on the profile's own account the clash is gone, and the page still says what the move was. Used only for the
    /// switch it was made for (`backNote`).
    @State private var startedBack: ClashBack?
    struct ClashBack: Equatable { var key: String; var owner: String? }

    /// The remembered move-back, only while it is this pick's (the switch key) and a switch is under way or ended: after a
    /// Cancel (ready again), another pick or another profile's page it says nothing.
    static func backNote(_ started: ClashBack?, key: String, phase: SwitchRunner.Phase) -> ClashBack? {
        guard let started, started.key == key, phase != .ready else { return nil }
        return started
    }
    private var backNote: ClashBack? { Self.backNote(startedBack, key: AccountEntry.switchKey(entry.id, standby.id), phase: runner.phase) }
    /// A clash move-back: the pick is the profile's own account in a clash (ProfileShow.ownStandbyID, as the menus decide it),
    /// or the one remembered from the switch that is running or ended.
    private var movesBack: Bool { backNote != nil || standby.id == show.ownStandbyID }

    /// The page's title before anything starts, and the key's: a clash move-back says it moves Claude Code back.
    static func readyTitle(name: String, to: String, moveBack: Bool) -> String {
        moveBack ? "Move Claude Code back to \(to)" : "Switch Claude \(name) to \(to)"
    }
    static func goTitle(to: String, moveBack: Bool) -> String { moveBack ? "Move back to \(to)" : "Switch to \(to)" }

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
    /// The profile's one value (ProfileShow): the in-use box draws it.
    var show: ProfileShow { _ = model.tick; return ProfileShow.load(entry) }
    var view: AccountView { show.view }
    /// The in-use box's profile as the card has it (the lamp, the line, the numbers): the box draws this.
    var inUseRow: AccountRow { AccountRow(entry: entry, show: show) }
    /// The account landed on is another profile's account in use: the profile didn't follow it.
    private var clash: (seat: Seat?, owner: String)? { view.clash.map { (nil, $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ExperimentalPanel(flow: "Account switching")
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            if let t = topLine { topBar(t) }
            // once undone, no steps: ticked steps would read as if the move had happened
            SettingsColumns(width: width, groups: [[AnyView(accountsCard)],
                                                   runner.phase == .undone ? [AnyView(changesCard)] : [AnyView(changesCard), AnyView(stepsCard)]])
        }
        .experimentalConsent($consent)
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
        if again { return runner.phase == .reached ? "Signed Claude \(name) in" : "Sign Claude \(name) in" }
        return Self.phaseTitle(runner.phase, name: name, to: to, moveBack: movesBack)
    }

    /// The title for a switch's phase (a sign-in again and a Claude app left behind have their own, above).
    static func phaseTitle(_ phase: SwitchRunner.Phase, name: String, to: String, moveBack: Bool) -> String {
        switch phase {
        case .closing, .moving, .waiting: return "Switching Claude \(name) to \(to)"
        case .reached: return "Switched Claude \(name) to \(to)"
        case .other(let e): return "Claude \(name) signed in as \(AccountNames.short(e))"
        case .ready: return readyTitle(name: name, to: to, moveBack: moveBack)
        // (stopped or put back: the usual title; only the ready one says a clash move-back)
        case .timedOut, .failed, .undone: return readyTitle(name: name, to: to, moveBack: false)
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
            if again { return Top(text: "Signed in", dim: "· \(to)", tone: .ok) }
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
                Button("Switch back…") { model.showSwitch(AccountEntry.switchKey(entry.id, back.id)) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true))
                    .help("Switch back to \(AddressSettings.words(back.email))")
            }
            Button("‹ Back") { leave() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).help("Back to \(name)'s settings")
        case .other(let e):
            Button(again ? "Sign in…" : "Sign in as \(to) again") { if again { runner.retry() } else { consent = ConsentRequest(flow: "Account switching") { runner.retry() } } }
                .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            if runner.canUndo { undoKey }
            if clash == nil, !runner.canUndo {
                Button("Keep \(AccountNames.short(e))") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
        case .timedOut, .failed:
            // (an earlier switch that stopped half way: Undo and Leave it as it is are what moves it on, not another try)
            if !(runner.failedStep == .notStarted && runner.canUndo) {
                Button("Try again") { if again { runner.retry() } else { consent = ConsentRequest(flow: "Account switching") { runner.retry() } } }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            }
            if runner.canUndo { undoKey }
            Button("‹ Back") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).help("Back to \(name)'s settings")
        case .closing:
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .undone:
            Button("‹ Back") { leave() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).help("Back to \(name)'s settings")
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
        SCard(title: "Accounts", info: "The account \(name) works on now, with its limits, and the one it switches to. A standby account isn't read, so it shows no limits: only when it was last used here.") {
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

    /// The in-use box's name: the account in use as every surface names it (ProfileShow.inUseLabel); for an old record
    /// with none worked out, the folder's own address, except in a clash with no own account known (that address is the
    /// other profile's); else "its account".
    static func inUseName(_ s: ProfileShow, expected: String?) -> String {
        s.inUseLabel ?? (s.inUseUnknown ? nil : expected) ?? "its account"
    }

    /// The in-use box's plan (ProfileShow.plan: none in a clash).
    static func inUseDetail(plan: String?) -> String { plan.map(Account.planWords) ?? "" }

    private var inUseBox: some View {
        // the account in use, its lamp, the one line and the numbers: the profile's one value, as the card draws it
        let row = inUseRow
        let detail = Self.inUseDetail(plan: row.show.plan)
        let limits = row.limits
        // the in-use well, as in Settings ▸ Accounts; resting (the unlit shade) while a standby box below is the selected one,
        // so only one box is dark
        return AccountBox(lamp: row.lit ? FaceTheme.ledOn : nil, badge: "In use", badgeTone: row.lit ? .ok : .warn, detail: detail,
                          inUse: true, rest: !again && runner.phase != .reached) {
            BoxText(text: Self.inUseName(row.show, expected: row.status?.expectedEmail), role: .title)
        } content: {
            if let n = row.line { BoxText(text: n, role: .note) }
            if limits.contains(where: { $0.p != nil }) {
                CardLimits(limits: limits, design: DashboardPrefs.shared.cardStyle, credits: row.usage?.credits, fullBox: false)
            } else {
                // (in the split the line above says why: here, what gives the numbers)
                BoxText(text: row.show.numbersHint ?? "No numbers yet: the agent reads them within a few minutes.", role: .note)
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
        /// A title is the REAL address (or an account id's label): while addresses are hidden it is drawn as AddressPrivacy's
        /// stand-in and read as "hidden address", never as a mask of itself (a title that is no address is plain).
        @ViewBuilder private func title(_ color: Color) -> some View {
            AccountValue(text: text, size: 13)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
        }
        var body: some View {
            switch role {
            case .title: title(face.text)
            case .softTitle: title(face.soft)
            case .note: Text(text).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A standby account: its address, plan and when it was last in use. No limits: it isn't read.
    private func standbyBox(_ s: StandbyAccount, selected: Bool) -> some View {
        let pickable = runner.phase == .ready && !selected && s.seat != nil
        // a clash: the profile's own account (the Claude app is on it) is in this list once, as the way back for Claude Code
        let back = s.id == show.ownStandbyID
        func box(_ lit: String?) -> some View {
            AccountBox(lamp: nil, badge: back ? "Move back" : "Standby", detail: s.plan.map(Account.planWords),
                       unlit: !selected, selected: selected, litBadge: lit) {
                BoxText(text: s.label, role: selected ? .title : .softTitle)
            } content: {
                BoxText(text: Self.boxWords(s, back: back, name: name, moveCount: selected && plan?.moves == true ? sessionWords(plan) : nil), role: .note)
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

    /// A standby box's line: when it was last in use; the profile's own account in a clash (the way back): what choosing it
    /// does ("Move Claude Code back here (41 Code-tab sessions)"), with the count once it is the one picked.
    static func boxWords(_ s: StandbyAccount, back: Bool, name: String, moveCount: String?, now: Date = Date()) -> String {
        if back {
            let words = SwitchOffer.moveBackWords
            return words.prefix(1).uppercased() + words.dropFirst() + (moveCount.map { " (\($0))" } ?? "") + "."
        }
        return (s.lastInUse.map { "Last used " + AccountBook.ago($0, now: now) } ?? "Not used on \(name) yet") + "."
    }

    // MARK: what changes, and what doesn't

    @ViewBuilder private var changesCard: some View {
        if again { againCard } else { switchChanges }
    }

    /// A sign-in again on the account in use: the same account, so nothing moves to anything.
    private var againCard: some View {
        SCard(title: "What changes", info: "Sign in: Claude Code's own sign-in on \(name)'s folder, as the account in use, in Terminal, finished in the browser. It moves nothing.") {
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

    /// Before Switch is pressed: the files in the old account's folder named like a Code-tab session that aren't one, from
    /// the plan read now (SwitchEngine's `odd`, the receipt's leftInPlace), in the runner's words (leftWords) in the future
    /// tense ("Will stay with ann: …"). Once it started, the runner's leftNote says it ("Left with ann: …"), so nil then.
    static func leftBefore(_ p: SwitchPlan?, started: Bool) -> String? {
        guard !started, let p else { return nil }
        return SwitchRunner.leftWords(p.odd, old: p.from.email.map(AccountNames.short) ?? "the old account", before: true)
    }

    /// The runner's leftNote as the page shows it: after a switch that moved nothing (it stopped before the move), none
    /// (nothing moved, so nothing was left behind).
    static func leftShown(_ left: String?, movedNothing: Bool) -> String? { movedNothing ? nil : left }

    /// The left-behind line on the plan card: "Left with …" (the runner's leftNote) only once something moved (a receipt);
    /// until then, also while it closes or moves, and after a Cancel back to Ready, "Will stay with …" from the plan.
    static func leftInPlan(left: String?, moved: Bool, plan: SwitchPlan?) -> String? {
        moved ? left : leftBefore(plan, started: false)
    }

    /// Whether the plan card's line is past tense: a receipt, while it isn't back at Ready. At Ready the card shows the plan
    /// of the next switch ("Will stay with"), also when a reset kept an unfinished receipt (whose leftNote went with it).
    static func movedForPlanLine(receipt: SwitchReceipt?, phase: SwitchRunner.Phase) -> Bool { receipt != nil && phase != .ready }

    /// The one note line: what the move said (moveNote), then what stayed (the runner's leftNote, or before Switch leftBefore); nil when none.
    static func noteLine(_ note: String?, _ left: String?) -> String? {
        let parts = [note, left].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func sessionWords(_ p: SwitchPlan?) -> String {
        guard let p, p.moves else { return "none of the Claude window's sessions are on \(from), so nothing moves" }
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        var parts: [String] = []
        if !p.move.isEmpty { parts.append(n(p.move.count, "Code-tab session", "Code-tab sessions")) }
        if p.tasks > 0 { parts.append(n(p.tasks, "scheduled task", "scheduled tasks")) }
        return parts.joined(separator: " and ")
    }

    /// What a switch moved, in sessionWords' words, from its receipt (what was written down, not the plan: tasks that stayed
    /// at the move, and their sessions, aren't counted); "" when nothing moved. The plan's words without a receipt.
    private var movedWords: String {
        guard let r = runner.receipt else { return sessionWords(plan) }
        return Self.receiptWords(r)
    }

    static func receiptWords(_ r: SwitchReceipt) -> String {
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
        let s = r.moved, t = r.steps.contains { $0.kind == .tasks && $0.done } ? (r.tasksMoved ?? 1) : 0
        return [s > 0 ? n(s, "Code-tab session", "Code-tab sessions") : nil, t > 0 ? n(t, "scheduled task", "scheduled tasks") : nil]
            .compactMap { $0 }.joined(separator: " and ")
    }

    /// Once it reached the account: what is true now, in the past tense.
    private var switchDone: some View {
        SCard(title: "What changed", info: changesInfo) {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value("Terminal and editors on \(entry.configDir) work on \(to) now, sessions that were running included.")
            }
            SRow(label: "Sessions", stacked: true) {
                let w = movedWords
                value(runner.receipt == nil ? "Nothing moved: none of the Claude window's sessions were on \(from)."
                      : w.isEmpty ? "Nothing moved to \(to); a backup was made first."
                      : "\(w.prefix(1).uppercased() + w.dropFirst()) moved to \(to), with a backup made first. Claude Code's transcripts stayed in \(entry.configDir).")
            }
            if appBehind {
                SRow(label: "Claude window", stacked: true) {
                    value("Claude Code is on \(to). The Claude app is still on \(appShort): sign it in to \(to) there to finish (\(entry.windowWords)). Until then \(appShort) is the account in use.")
                }
            } else if entry.claudeWindow {
                SRow(label: "Claude window", stacked: true) {
                    value("Sign it in to \(to) yourself there (\(entry.windowWords)): its sessions show on that account.")
                }
            }
            SRow(label: "Stayed", stacked: true) { value("\(name)'s name, Dock icon, look, folder and settings") }
            if !appBehind { SRowLine(text: "\(from) stands by on \(name) now: nothing read, switch back any time.") }
            if let n = Self.noteLine(runner.moveText, runner.leftText) { SRowLine(text: n) }
            if let w = runner.windowText { SRowLine(text: w) }
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
                    let w = movedWords
                    value((w.isEmpty ? "Part of the move" : w.prefix(1).uppercased() + w.dropFirst()) + " moved to \(to) already. Sign in as \(to) again, or Undo the move to put them back under \(from).")
                }
            }
            if let w = runner.windowText { SRowLine(text: w) }
        }
    }

    /// No sign-in, stopped, or undone: what is where now.
    private var switchNothing: some View {
        SCard(title: "What changed", info: changesInfo) {
            if runner.canUndo {
                SRow(label: "Sessions", first: true, stacked: true) {
                    // what the receipt really has moved now (the same numbers as the tile), not the whole plan
                    let w = runner.movedShown                      // counted when the receipt changed, not on each render
                    value((w.isEmpty ? "Part of the move" : w.prefix(1).uppercased() + w.dropFirst()) + " moved to \(to); Claude Code on \(entry.configDir) is still on \(from). Try again, or Undo the move to put them back.")
                }
            } else {
                SRow(label: "Nothing", first: true, stacked: true) {
                    value(runner.phase == .undone
                          ? "The move is undone: \(name)'s sessions and scheduled tasks are back under \(from), and Claude Code is still on \(from)."
                          : "\(name) is still on \(from): Claude Code on \(entry.configDir), its sessions, the Claude window and \(name)'s settings are as they were.")
                }
            }
            // (stopped before the move: nothing was left behind, so the note says nothing of it)
            if let n = Self.noteLine(runner.moveText, Self.leftShown(runner.leftText, movedNothing: runner.receipt == nil && runner.phase != .undone)) {
                SRowLine(text: n)
            }
            if let w = runner.windowText { SRowLine(text: w) }
        }
    }

    private var switchPlan: some View {
        let isDefault = Account(entry).isDefaultDir
        return SCard(title: "What changes", info: changesInfo) {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value(AccountBook.switchWords(folder: entry.configDir, email: AddressSettings.words(runner.goal?.wantedEmail ?? standby.email), isDefault: isDefault))
            }
            SRow(label: "Sessions", stacked: true) {
                value(moves
                      ? "\(sessionWords(plan).prefix(1).uppercased() + sessionWords(plan).dropFirst()) move from \(from) to \(to), inside \(name)'s folder, with a backup made first. A session Claude Code is running stays with \(from) until a later switch. Transcripts stay in \(entry.configDir)."
                      : standby.seat == nil ? "Nothing moves now: \(to) hasn't been signed in on this Mac, so its sessions' folder isn't known yet."
                      : "Nothing moves: \(sessionWords(plan)).")
            }
            if entry.claudeWindow {
                SRow(label: "Claude window", stacked: true) {
                    value(moves ? "It closes for the move (\(entry.windowWords)) and opens again when the switch is done. Sign it in to \(to) yourself there: cl_audit never signs it in or out."
                                : "Its own sign-in stays as it is (\(entry.windowWords)): sign it in to \(to) yourself if you like.")
                }
            }
            SRow(label: "Stays", stacked: true) { value("\(name)'s name, Dock icon, look, folder and settings") }
            SRowLine(text: Self.staysLine(from: from, name: name, moveBack: movesBack,
                                          owner: backNote == nil ? view.clash : backNote?.owner))
            if let n = Self.noteLine(runner.moveText, Self.leftInPlan(left: runner.leftText, moved: Self.movedForPlanLine(receipt: runner.receipt, phase: runner.phase), plan: plan)) { SRowLine(text: n) }
            if let w = runner.windowText { SRowLine(text: w) }               // (a Cancel's late-close watch, said here too)
        }
    }

    /// As the switch starts: a clash move-back is remembered (`startedBack`).
    private func noteBack() {
        startedBack = standby.id == show.ownStandbyID ? ClashBack(key: AccountEntry.switchKey(entry.id, standby.id), owner: view.clash) : nil
    }

    /// What happens to the account Claude Code leaves. A normal switch: it stays on the profile as a standby account. A clash
    /// move-back (the account is another profile's, `owner`): it stays with that profile, never the profile's standby.
    static func staysLine(from: String, name: String, moveBack: Bool, owner: String?) -> String {
        if moveBack { return "\(from) stays with \(owner ?? "the profile it belongs to"): nothing read here." }
        return "\(from) stays on \(name) as a standby account: nothing read, switch back any time."
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
        // stopped part way through the backup or the move (or undone): the plan's counts aren't what was done, so none is shown
        let partWay: Bool = {
            switch runner.phase {
            case .failed: return runner.failedStep == .backup || runner.failedStep == .move
            case .undone: return true
            default: return false
            }
        }()
        // once a receipt exists, what it wrote down (tasks that stayed at the move aren't named); the plan's words before
        let done = runner.receipt.map(Self.receiptWords) ?? ""
        let moved = partWay ? ((plan?.tasks ?? 0) > 0 ? "the sessions and scheduled tasks" : "the sessions") : done.isEmpty ? sessionWords(plan) : done
        return SCard(title: "Steps", info: "When the switch moves sessions: the profile's Claude window closes, a backup is made, the sessions and scheduled tasks move (with a receipt, for Undo). Then Claude Code's own sign-in, and a check of the account it signed in. cl_audit never sees a password or a token. cl_audit itself never reads or writes Keychain items during a switch; Claude Code's own sign-in updates its own item.") {
            ClaudeMissingLine(model: model)
            VStack(alignment: .leading, spacing: 0) {
                let finishLine = plan?.finishLine == true
                if moves {
                    step(1, "\(name)'s Claude window closes", finishLine ? "Only that window, by its own quit; it opens again once the sessions have moved."
                                                                        : "Only that window, by its own quit; it stays closed until the sign-in ends.")
                    step(2, "Its sessions move to \(to)", finishLine
                         ? "A backup first, then \(moved), each checked. Undo only if the move stops part way: Claude Code is on \(to) already, so a finished move stays (the backup keeps a copy)."
                         : "A backup first, then \(moved), each checked; a receipt keeps Undo possible.")
                }
                if finishLine {
                    // the finish line: Claude Code signed in to it elsewhere; only the Claude app's sign-in is left
                    step(k + 1, "Claude Code is on \(to) already", "It signed in elsewhere, so no sign-in opens for \(entry.configDir).")
                    step(k + 2, "Sign the Claude app in to \(to)", "In \(name)'s Claude window, once it opens again: its sessions are there.")
                } else {
                    step(k + 1, "Claude Code's sign-in opens in Terminal", "For \(entry.configDir), with \(AddressSettings.words(runner.goal?.wantedEmail ?? standby.email)) filled in.")
                    step(k + 2, "Finish it in the browser as \(to)", "If the browser is signed in to claude.ai as someone else, switch its account there first.")
                }
                step(k + 3, again ? "cl_audit checks Claude Code's sign-in ended well" : "cl_audit checks the account",
                     finishLine ? "At once: Claude Code is on it already." : "The folder is looked at every 2 seconds, for up to 10 minutes.", check: check)
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
                return "\(AddressSettings.words(e)) is \(c.owner)'s account, so \(name) doesn't take it: its numbers wait until you sign in as \(to) (or another of \(name)'s accounts)."
            }
            return "\(name) works on \(AccountNames.short(e)) now, and \(from) is on standby. To get \(to), switch the browser's claude.ai account first, then sign in again."
        case .timedOut:
            return runner.canUndo ? "No sign-in came in 10 minutes: Claude Code is still on \(from)." : "Nothing changed: \(name) is still on \(from)."
        case .failed(let why):
            return runner.said(why)                       // (a stopped switch names its account by a marker, filled now)
        case .undone:
            return runner.moveText
        }
    }

    @ViewBuilder private var keys: some View {
        HStack(spacing: 10) {
            Button("Back") { leave() }.buttonStyle(.plain).foregroundStyle(face.muted)
            Spacer(minLength: 6)
            switch runner.phase {
            case .ready:
                Button(Self.goTitle(to: to, moveBack: movesBack)) { consent = ConsentRequest(flow: "Account switching") { noteBack(); runner.start(standby) } }
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
