// SwitchView: the Switch page (Switch.swift), opened from the dashboard's at-limit box, the alert's Switch button and
// the Dock and menu bar menus. It says what stays, what follows and what will happen. Read-only for now: the switch
// itself comes in a later build, so its key is off and one grey line says so.

import AppKit
import SwiftUI
import UserNotifications

/// The alert's Switch button (Reader.swift posts it, main.swift's --post-alert gives it its button), answered here in
/// cl_audit's own window: the Switch page. A tap on the alert itself only brings cl_audit forward, as before.
extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        defer { done() }
        guard response.actionIdentifier == SwitchAlert.action,
              let key = response.notification.request.content.userInfo[SwitchAlert.keyField] as? String else { return }
        DispatchQueue.main.async {
            if self.launched { self.manager.closePalette(); self.manager.showSwitch(key) } else { self.pendingSwitch = key }
        }
    }

    /// cl_audit at the front: its alerts still show.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
}

/// An alert with a Switch accounts button: one category for every alert (its words name no account), and the target
/// rides along in the alert's userInfo.
enum SwitchAlert {
    static let category = "switch"
    static let action = "switch"
    static let later = "later"
    static let keyField = "switch"

    /// Registers the alert's one category (Switch accounts, Later), kept with any others but the per-account ones older
    /// builds made ("switch.<key>"), and waits until macOS has it (up to 2 s): setting categories doesn't say when it's
    /// done, and an alert added before would show without its buttons. The target rides in each alert's userInfo.
    @discardableResult
    static func register(center: UNUserNotificationCenter = .current()) -> String {
        func current() -> Set<UNNotificationCategory> {
            var got: Set<UNNotificationCategory> = []
            let done = DispatchSemaphore(value: 0)
            center.getNotificationCategories { got = $0; done.signal() }
            _ = done.wait(timeout: .now() + 2)
            return got
        }
        var set = current().filter { !$0.identifier.hasPrefix("switch.") && $0.identifier != category }
        set.insert(UNNotificationCategory(identifier: category,
                                          actions: [UNNotificationAction(identifier: action, title: SwitchWords.button, options: [.foreground]),
                                                    UNNotificationAction(identifier: later, title: "Later", options: [])],
                                          intentIdentifiers: [], options: []))
        center.setNotificationCategories(set)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !current().contains(where: { $0.identifier == category }) { usleep(100_000) }
        return category
    }
}

/// What a dashboard card offers while a limit is full: "ultra-2: week 8% used" and "Switch to ultra-2…".
struct CardOffer {
    let text: String
    let key: String
    let action: () -> Void

    init(_ o: SwitchOffer, open: @escaping (String) -> Void) {
        text = o.usedWords; key = "Switch to \(o.short)…"
        let k = o.key
        action = { open(k) }
    }
}

struct CardOfferRow: View {
    let offer: CardOffer
    @Environment(\.face) private var face

    // the key alone: the account's own limits are just below, in its Standby block
    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            key
        }
        .help(offer.text)
    }

    private var key: some View {
        Button(offer.key, action: offer.action).buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
    }
}

/// A standby account's limits on its profile's dashboard card, small: "Standby · ultra-1@example.com", then a row
/// per limit (name, bar, percentage, "in 3 days" or, full, when it's back).
struct StandbyLimits: View {
    let email: String
    let limits: [Limit]
    let design: PanelDesign
    @Environment(\.face) private var face

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text("Standby ·").foregroundStyle(face.muted)
                    Text(Privacy.masked(email)).foregroundStyle(face.soft).lineLimit(1).truncationMode(.tail).hidesEmail()
                }
                .font(.system(size: 11.5))
                ForEach(limits) { l in row(l, now: ctx.date) }
            }
        }
    }

    private func row(_ l: Limit, now: Date) -> some View {
        let full = AtLimit.holding(l.p, l.resets, now: now)
        let words = full ? (l.resets.map { TimeWords.back($0, now: now) } ?? "full") : (l.resets.map { "in " + DetailsFormat.short($0) } ?? "")
        return HStack(spacing: 8) {
            Text(l.name).font(.system(size: 11.5)).foregroundStyle(face.soft).frame(width: 46, alignment: .leading).lineLimit(1)
            Group {
                if design == .segments { SegmentBar(p: l.p, height: 5) } else { LevelBar(p: l.p, height: 4) }
            }
            .frame(maxWidth: .infinity)
            Text(Painter.pct(l.p)).font(.system(size: 11, weight: .bold, design: .monospaced)).monospacedDigit()
                .foregroundStyle(l.p == nil ? face.muted : face.levelColor(l.p)).frame(width: 38, alignment: .trailing)
            Text(words).font(.system(size: 10.5)).foregroundStyle(full ? face.danger : face.muted).lineLimit(1)
                .frame(width: 92, alignment: .leading)
        }
    }
}

struct SwitchPage: View {
    let entry: AccountEntry
    let standby: StandbyAccount
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner
    var width: CGFloat = 980
    @State private var counts: SidebarCounts??          // nil: still counting; .some(nil): the window has nothing
    @State private var asks = true                      // the helper session will ask before each move (step 5)
    @State private var unfinished: [SwitchReceipt] = [] // this profile's switches that stopped half way
    @State private var confirm = false
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    /// The account it switches from (once switched, the one the receipt names).
    private var from: String {
        // the receipt names accounts by id only: once switched, the account it came from is the one on standby
        let was = runner.receipt.flatMap { r in r.from.same(entry.seat) ? nil : entry.standby.first { r.from.same($0.seat) }?.email }
        return AccountNames.short(was ?? entry.seat?.email ?? Account.expectedEmail(configDir: entry.configDir) ?? "its account")
    }
    private var to: String { AccountNames.short(standby.email) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Switch Claude \(name) to \(to)").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
                DisplayWindow(text: from, dim: "→ \(to)", height: 20, size: 9.5)
                Spacer(minLength: 0)
            }
            SettingsColumns(width: width, groups: [[AnyView(accountsCard), AnyView(staysCard)],
                                                  [AnyView(followsCard), AnyView(stepsCard)]])
        }
        .task(id: entry.id + standby.id) { await count() }
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
        let id = e.id
        unfinished = await Task.detached(priority: .utility) { SwitchEngine.unfinished(profile: id) }.value
    }

    /// A switch of this profile that stopped half way (this one, or one from before), with what it moved: Undo first.
    private var pending: SwitchReceipt? {
        if let r = runner.receipt, r.unfinished, runner.phase != .codeSignIn { return r }
        return runner.phase == .ready || isFailed ? unfinished.first : nil
    }

    private var accountsCard: some View {
        let now = Store.status(for: entry)
        let target = Store.status(for: entry, standby: standby)
        // "Ultra · Personal", as in Settings ▸ Accounts
        func detail(_ st: IconStatus?, _ dir: String?) -> String {
            let f = dir.flatMap { FolderFactsCache.facts($0) }
            return [st?.plan.map(Account.planWords) ?? f?.plan, f?.org].compactMap { $0 }.joined(separator: " · ")
        }
        // once switched, the account it came from is the one standing by
        let switched = entry.seat.map { $0.same(standby.seat) } ?? false
        let cameFrom = runner.receipt?.from
        let other: StandbyAccount? = switched ? entry.standby.first(where: { s in cameFrom?.same(s.seat) ?? false }) : standby
        let otherStatus = other.flatMap { Store.status(for: entry, standby: $0) }
        return SCard(title: "Accounts", info: "The account \(name) works on now, and the one it would switch to, with their limits as cl_audit last read them.") {
            VStack(alignment: .leading, spacing: 8) {
                AccountBox(lamp: FaceTheme.ledOn, badge: "In use", badgeTone: .ok, detail: detail(now, entry.configDir)) {
                    Text(Privacy.masked(entry.seat?.email ?? "its account")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
                } content: { limits(now, entry) }
                if let other {
                    AccountBox(lamp: nil, badge: switched ? "Standby" : "Switch to", detail: detail(switched ? otherStatus : target, other.configDir)) {
                        Text(Privacy.masked(other.email)).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
                    } content: { limits(switched ? otherStatus : target, entry.readerEntry(for: other) ?? entry) }
                }
            }
            .padding(.vertical, 6)
        }
    }

    /// Both accounts with the same bars (no at-limit box here, so a full account and one with room read alike).
    @ViewBuilder private func limits(_ st: IconStatus?, _ e: AccountEntry) -> some View {
        let row = AccountRow(entry: e, status: st)
        if row.limits.contains(where: { $0.p != nil }) {
            CardLimits(limits: row.limits, design: DashboardPrefs.shared.cardStyle, credits: st?.credits, fullBox: false)
        } else {
            Text("No numbers yet.").font(.system(size: 11.5)).foregroundStyle(face.muted)
        }
    }

    private var staysCard: some View {
        SCard(title: "Stays as it is", info: "Switching changes only the account \(name) works on. Everything that makes it \(name) stays.") {
            SRow(label: "Profile", first: true) { value("Name, Dock icon, look") }
            SRow(label: "Folder") { value("\(entry.configDir): projects, settings, MCP, CLAUDE.md") }
            SRow(label: "History") { value("Claude Code's, for claude --resume") }
        }
    }

    private var followsCard: some View {
        SCard(title: "Follows to \(to)", info: "With Sessions follow on (Settings ▸ \(name) ▸ Claude Code), the Claude window's Code sidebar goes with the account: its sessions, sections and groups, pins and scheduled tasks, so the window opens the same. They come back when \(name) switches back. Chats and Projects on claude.ai belong to each account and don't move.") {
            if !entry.sessionsFollow {
                SRow(label: "Sessions", first: true) { value("nothing: Sessions follow is off") }
                SRowLine(text: "Each account keeps its own sessions; the window opens with \(to)'s.")
            } else {
                switch counts {
                case nil:
                    SRow(label: "Sessions", first: true) { value("counting…") }
                case .some(nil):
                    SRow(label: "Sessions", first: true) { value("none in the window for \(from)") }
                case .some(.some(let c)):
                    let w = c.words
                    SRow(label: "Sessions", first: true) { value(w[0]) }
                    if w.count > 2 { SRow(label: "Sidebar") { value(w[1]) } }
                    SRow(label: "Routines") { value(w.last ?? "") }
                }
                SRowLine(text: "Chats and Projects on claude.ai don't move; they belong to each account.")
            }
        }
    }

    /// Which step is under way (1 to 5), or 6 when all are done; 0 before starting.
    private var at: Int {
        switch runner.phase {
        case .ready, .failed, .cancelled: return 0
        case .closing: return 1
        case .moving: return 2
        case .codeSignIn, .windowSignIn: return 3
        case .sidebar: return 5
        case .done: return arranges && runner.sidebarPlan != nil && !runner.sidebarOpened ? 5 : 6   // the sidebar still to do
        }
    }

    /// The sidebar step: there with Sessions follow on and a Claude window to arrange.
    private var arranges: Bool { entry.sessionsFollow && entry.claudeWindow }

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
        let window = entry.desktop == .standard ? "the usual Claude app" : "\(name)'s Claude window"
        let w = window.prefix(1).uppercased() + window.dropFirst()
        let code = runner.phase == .codeSignIn, win = runner.phase == .windowSignIn
        return SCard(title: "Steps", info: "What switching does, in order. Each step is checked before the next. A receipt in cl_audit's folder keeps what moved: until Claude Code has signed in, Cancel puts it back; after that the way back is a switch the other way.") {
            VStack(alignment: .leading, spacing: 0) {
                step(1, "\(w) closes", "Only that window, for about half a minute; your other Claude windows stay open.")
                step(2, "The sessions move to \(to)", entry.sessionsFollow
                     ? "Same ids; nothing is copied. Their groups and pins are noted for step 5."
                     : "Skipped: Sessions follow is off.")
                step(3, code ? "Claude Code signs in as \(to)" : win ? "The window signs in as \(to)" : "Claude Code and the window sign in as \(to)",
                     code ? "Finish in the browser as \(Privacy.masked(standby.email)); Terminal shows Claude Code's sign-in."
                     : win ? "In the window: log out, then sign in as \(Privacy.masked(standby.email))."
                     : "Claude Code in Terminal and the browser, then the window's own sign-in.")
                step(4, "\(name) works on \(to)", "Its numbers then are \(to)'s; \(from) waits on standby.")
                if arranges { step(5, "The sidebar, as before", sidebarWords) }
            }
            keys.padding(.top, 8)
            if let line = statusLine { SRowLine(text: line, color: isFailed ? face.danger : nil) }
        }
        .alert("Switch Claude \(name) to \(to)?", isPresented: $confirm) {
            Button("Close and switch") { runner.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmWords)
        }
    }

    private var isFailed: Bool { if case .failed = runner.phase { return true }; return false }

    private var confirmWords: String {
        let moved: String = {
            guard entry.sessionsFollow, case .some(.some(let c)) = counts else { return "" }
            return " Its \(c.sessions + c.archived) sessions and \(c.tasks) scheduled tasks move to \(to), with a receipt to undo it."
        }()
        let sidebar = arranges ? " Once it's on \(to), a session opens there to arrange the sidebar: press Return in it." : ""
        return "\(entry.desktop == .standard ? "The usual Claude app" : "\(name)'s Claude window") closes.\(moved) Then Claude Code signs in as \(to) in Terminal and the browser, and the window opens for its own sign-in.\(sidebar)"
    }

    private var statusLine: String? {
        if let p = pending {
            let when = p.started.formatted(date: .abbreviated, time: .shortened)
            var lead = ""
            if case .failed(let why) = runner.phase, !why.hasPrefix("An earlier switch") { lead = why + " " }
            if let n = runner.note { lead += n + " " }
            return lead + "A switch on \(when) stopped half way: \(p.moved) \(p.moved == 1 ? "session" : "sessions") moved, \(name) not switched. Undo puts them back."
        }
        switch runner.phase {
        case .failed(let why): return why
        case .cancelled: return "Cancelled: the sessions are back with \(from)."
        case .done: return runner.note ?? "Done: \(name) works on \(to)."
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
                    Button("Undo") {
                        runner.undoUnfinished(p.id)
                        unfinished = SwitchEngine.unfinished(profile: entry.id)
                    }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                } else {
                    Button(isFailed ? "Try again" : "Close and switch to \(to)") { confirm = true }
                        .buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                        .disabled(runner.phase == .cancelled || (!entry.sessionsFollow ? false : counts == nil))
                }
            case .closing, .moving:
                Spacer(minLength: 6)
                Text(runner.phase == .closing ? "closing the window…" : "moving…").font(.system(size: 12)).foregroundStyle(face.caution)
            case .codeSignIn:
                Button("Cancel switch") { runner.cancel() }.buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                Button("Sign in again…") { runner.signInCode() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            case .windowSignIn:
                Spacer(minLength: 6)
                Button("Show window") { Launcher.openClaude(Account(entry)) }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Done") { runner.finish() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            case .sidebar:
                Button(runner.sidebarOpened ? "Open it again" : "Open the session") { runner.arrangeSidebar() }
                    .buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                Button("Done") { runner.finish() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            case .done:
                if arranges, runner.sidebarPlan != nil, !runner.sidebarOpened {
                    Button("Arrange the sidebar…") { runner.arrangeSidebar() }.buttonStyle(.plain).foregroundStyle(face.muted)
                }
                Spacer(minLength: 6)
                Button("Back to \(name)") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
            }
        }
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        let done = at > n, now = at == n
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().stroke(now ? FaceTheme.ledOn : face.muted.opacity(0.6), lineWidth: 1.2)
                if done { Circle().fill(FaceTheme.ledOn); Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.75)) }
                else { Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(now ? FaceTheme.ledOn : face.muted) }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
