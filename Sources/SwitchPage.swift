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
    private var to: String { AccountNames.short(runner.goal?.wantedEmail ?? standby.email) }
    /// The account it came from, short: the one in use when it began.
    private var from: String {
        AccountNames.short(runner.goal?.from?.email ?? entry.seat?.email ?? Account.expectedEmail(configDir: entry.configDir) ?? "its account")
    }
    /// What the folder is signed in to now (its .claude.json, read again only when it changed).
    private var seen: Seat? { _ = model.tick; return FolderFactsCache.facts(entry.configDir)?.seat }
    /// The account landed on is another profile's account in use: the profile didn't follow it.
    private var clash: (seat: Seat, owner: AccountEntry)? { _ = model.tick; return FolderRules.inUseElsewhere(entry, among: model.accounts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            if let t = topLine { topBar(t) }
            SettingsColumns(width: width, groups: [[AnyView(accountsCard)], [AnyView(changesCard), AnyView(stepsCard)]])
        }
    }

    private var title: String {
        if again { return runner.phase == .reached ? "Signed Claude \(name) in again" : "Sign Claude \(name) in again" }
        switch runner.phase {
        case .waiting: return "Switching Claude \(name) to \(to)"
        case .reached: return "Switched Claude \(name) to \(to)"
        case .other(let e): return "Claude \(name) signed in as \(AccountNames.short(e))"
        default: return "Switch Claude \(name) to \(to)"
        }
    }

    // MARK: the line at the top: how far it got, and the keys that lead out

    private struct Top { var text: String; var dim: String?; var tone: DisplayWindow.Tone }

    private var topLine: Top? {
        switch runner.phase {
        case .ready: return nil
        case .waiting:
            let until = (runner.goal?.started ?? Date()).addingTimeInterval(SwitchRunner.giveUp)
            return Top(text: again ? "Signing in again" : "Switching", dim: "· waiting for the sign-in · gives up at \(until.formatted(date: .omitted, time: .shortened))", tone: .mint)
        case .reached:
            if again { return Top(text: "Signed in again", dim: "· \(to)", tone: .ok) }
            return Top(text: "\(name) works on \(to)", dim: "· \(from) on standby", tone: .ok)
        case .other(let e):
            if let c = clash { return Top(text: "Signed in as \(AccountNames.short(e))", dim: "· \(c.owner.name)'s account", tone: .warn) }
            return Top(text: "Signed in as \(AccountNames.short(e))", dim: "· not \(to)", tone: .amber)
        case .timedOut: return Top(text: "No sign-in", dim: "· 10 minutes passed · nothing changed", tone: .amber)
        case .failed: return Top(text: "Not started", dim: "· nothing changed", tone: .warn)
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
            Button("Sign in as \(to) again") { runner.retry() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            if clash == nil {
                Button("Keep \(AccountNames.short(e))") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
        case .timedOut, .failed:
            Button("Try again") { runner.retry() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            Button("Back to \(name)'s settings") { leave() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
        case .ready:
            EmptyView()
        }
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
                    labelled("Before") { standbyBox(was, selected: false) }
                } else if !again, !(runner.phase == .reached) {
                    let list = pickList
                    labelled(runner.phase == .ready ? "To" : "Next") {
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
    private var pickList: [StandbyAccount] {
        guard runner.phase == .ready else { return [standby] }
        let all = AccountBook.offerOrder(entry.standby)
        return all.contains { $0.id == standby.id } ? all : [standby] + all
    }

    private func labelled<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(1.4).textCase(.uppercase)
                .foregroundStyle(face.muted).lineLimit(1).fixedSize().frame(width: 50, alignment: .leading).padding(.top, 12)
            content()
        }
    }

    private var inUseBox: some View {
        let st = Store.status(for: entry)
        let f = FolderFactsCache.facts(entry.configDir)
        let detail = [st?.plan.map(Account.planWords) ?? f?.plan, f?.org].compactMap { $0 }.joined(separator: " · ")
        let row = AccountRow(entry: entry, status: st)
        return AccountBox(lamp: FaceTheme.ledOn, badge: "In use", badgeTone: .ok, detail: detail) {
            Text(Privacy.masked(entry.seat?.email ?? "its account")).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
        } content: {
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
        let full = s.knownFull() ? "its week was full when it left" : nil
        return AccountBox(lamp: nil, badge: "Standby", detail: s.plan.map(Account.planWords),
                          unlit: !selected, selected: selected, litBadge: runner.phase == .reached ? nil : "Switching to") {
            BoxText(text: Privacy.masked(s.email), role: selected ? .title : .softTitle)
        } content: {
            BoxText(text: [s.lastInUse.map { "Last in use " + AccountBook.ago($0) } ?? "Not in use on \(name) yet", full]
                        .compactMap { $0 }.joined(separator: "; ") + ".", role: .note)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard pickable else { return }
            model.showSwitch(AccountEntry.switchKey(entry.id, s.id))
        }
    }

    // MARK: what changes, and what doesn't

    private var changesCard: some View {
        let isDefault = Account(entry).isDefaultDir
        return SCard(title: "What changes", info: "A switch signs Claude Code in again on \(name)'s folder as the other account, in Terminal, finished in the browser. It moves nothing.") {
            SRow(label: "Claude Code", first: true, stacked: true) {
                value(AccountBook.switchWords(folder: entry.configDir, email: Privacy.masked(runner.goal?.wantedEmail ?? standby.email), isDefault: isDefault))
            }
            SRow(label: "Sessions", stacked: true) {
                value("They stay in \(entry.configDir), each with the account it ran on: one started on \(from) isn't continued on \(to).")
            }
            if entry.claudeWindow {
                SRow(label: "Claude window", stacked: true) {
                    value("Its own sign-in, sessions, sidebar and scheduled tasks stay as they are (\(entry.windowWords)).")
                }
            }
            SRow(label: "Stays", stacked: true) { value("\(name)'s name, Dock icon, look, folder and settings") }
            SRowLine(text: "\(from) stays on \(name) as a standby account: no folder of its own, nothing read, switch back any time.")
        }
    }

    // MARK: the steps

    private enum StepState { case pending, now, waiting, done, failed }

    private func state(_ n: Int) -> StepState {
        switch runner.phase {
        case .ready: return .pending
        case .waiting: return n == 1 ? .done : n == 2 ? .waiting : .now
        case .reached: return .done
        case .other: return n < 3 ? .done : .failed
        case .timedOut: return n == 1 ? .done : n == 2 ? .failed : .pending
        case .failed: return n == 1 ? .failed : .pending
        }
    }

    private var stepsCard: some View {
        SCard(title: "Steps", info: "Claude Code's own sign-in, then a check of the account it signed in. cl_audit never sees a password or a token and doesn't touch the Keychain.") {
            ClaudeMissingLine(model: model)
            VStack(alignment: .leading, spacing: 0) {
                step(1, "Claude Code's sign-in opens in Terminal", "For \(entry.configDir), with \(Privacy.masked(runner.goal?.wantedEmail ?? standby.email)) filled in.")
                step(2, "Finish it in the browser as \(to)", "If the browser is signed in to claude.ai as someone else, switch its account there first.")
                step(3, again ? "cl_audit checks Claude Code's sign-in ended well" : "cl_audit checks the account",
                     "The folder is looked at every 2 seconds, for up to 10 minutes.", check: check)
            }
            keys.padding(.top, 8)
            if let line = statusLine { SRowLine(text: line, color: isBad ? face.danger : nil) }
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
        case .waiting:
            return "Nothing has changed yet: \(name) stays on \(from) until the folder names another account."
        case .reached:
            return again ? "Claude Code's sign-in on \(entry.configDir) works again." : "\(from) is on standby: switch back any time."
        case .other(let e):
            if let c = clash {
                return "\(Privacy.masked(e)) is \(c.owner.name)'s account, so \(name) doesn't take it: its numbers wait until you sign in as \(to) (or another of \(name)'s accounts)."
            }
            return "\(name) works on \(AccountNames.short(e)) now, and \(from) is on standby. To get \(to), switch the browser's claude.ai account first, then sign in again."
        case .timedOut:
            return "Nothing changed: \(name) is still on \(from)."
        case .failed(let why):
            return why
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
