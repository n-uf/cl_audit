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

/// An alert with a Switch button: its category is per target ("switch.<profile>~<account>"), since a button's words
/// belong to the category; the target rides along in the alert's userInfo.
enum SwitchAlert {
    static let action = "switch"
    static let later = "later"
    static let keyField = "switch"
    static func category(_ key: String) -> String { "switch.\(key)" }

    /// Registers the category for one alert (kept with the ones registered before) and returns it.
    static func register(key: String, button: String, center: UNUserNotificationCenter = .current()) -> String {
        let id = category(key)
        let done = DispatchSemaphore(value: 0)
        center.getNotificationCategories { have in
            var set = have.filter { $0.identifier != id }
            set.insert(UNNotificationCategory(identifier: id,
                                              actions: [UNNotificationAction(identifier: action, title: button, options: [.foreground]),
                                                        UNNotificationAction(identifier: later, title: "Later", options: [])],
                                              intentIdentifiers: [], options: []))
            center.setNotificationCategories(set)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return id
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(offer.text).font(.system(size: 12)).foregroundStyle(face.soft).lineLimit(1)
                Spacer(minLength: 6)
                key
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(offer.text).font(.system(size: 12)).foregroundStyle(face.soft).lineLimit(1)
                key
            }
        }
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
    var width: CGFloat = 980
    @State private var counts: SidebarCounts??          // nil: still counting; .some(nil): the window has nothing
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    private var from: String { AccountNames.short(entry.seat?.email ?? Account.expectedEmail(configDir: entry.configDir) ?? "its account") }
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
        let e = entry
        let dir = e.desktop == .standard ? FolderKey.standardDataDir : (Account(e).claudeUserDataDir ?? "")
        let account = FolderRules.windowAccount(e) ?? e.seat?.account ?? ""
        let c: SidebarCounts? = await Task.detached(priority: .utility) {
            dir.isEmpty || account.isEmpty ? nil : SidebarCounts.read(dataDir: dir, account: account)
        }.value
        counts = .some(c)
    }

    private var accountsCard: some View {
        let now = Store.status(entry.id)
        let target = Store.status(AccountEntry.standbyStatusID(entry.id, standby.id))
        // "Ultra · Personal", as in Settings ▸ Accounts
        func detail(_ st: IconStatus?, _ dir: String?) -> String {
            let f = dir.flatMap { AccountFacts.of(configDir: $0) }
            return [st?.plan.map(Account.planWords) ?? f?.plan, f?.org].compactMap { $0 }.joined(separator: " · ")
        }
        return SCard(title: "Accounts", info: "The account \(name) works on now, and the one it would switch to, with their limits as cl_audit last read them.") {
            VStack(alignment: .leading, spacing: 8) {
                AccountBox(lamp: FaceTheme.ledOn, badge: "In use", badgeTone: .ok, detail: detail(now, entry.configDir)) {
                    Text(Privacy.masked(entry.seat?.email ?? "its account")).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
                } content: { limits(now, entry) }
                AccountBox(lamp: nil, badge: "Switch to", detail: detail(target, standby.configDir)) {
                    Text(Privacy.masked(standby.email)).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(face.text).lineLimit(1).truncationMode(.tail).settingsEmail()
                } content: { limits(target, entry.readerEntry(for: standby) ?? entry) }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder private func limits(_ st: IconStatus?, _ e: AccountEntry) -> some View {
        let row = AccountRow(entry: e, status: st)
        if row.limits.contains(where: { $0.p != nil }) {
            CardLimits(limits: row.limits, design: DashboardPrefs.shared.cardStyle, credits: st?.credits)
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

    private var stepsCard: some View {
        let window = entry.desktop == .standard ? "the usual Claude app" : "\(name)'s Claude window"
        return SCard(title: "Steps", info: "What switching does, in order. Each step is checked before the next, and a receipt makes it undoable.") {
            VStack(alignment: .leading, spacing: 0) {
                step(1, "\(window.prefix(1).uppercased() + window.dropFirst()) closes", "Only that window, for about half a minute; your other Claude windows stay open.")
                step(2, "The sessions and the sidebar move to \(to)", entry.sessionsFollow ? "Same ids; nothing is copied. A receipt makes it undoable." : "Skipped: Sessions follow is off.")
                step(3, "Claude Code and the window sign in as \(to)", "One click in the browser.")
                step(4, "The window opens again on \(to)", "\(name)'s numbers then are \(to)'s.")
            }
            HStack(spacing: 10) {
                Button("Cancel") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
                Spacer(minLength: 6)
                Button("Switch to \(to)") {}.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(true)
            }
            .padding(.top, 8)
            SRowLine(text: "The switch itself comes in the next cl_audit build: nothing changes from this page yet.")
        }
    }

    private func value(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.muted)
                .frame(width: 22, height: 22).overlay(Circle().stroke(face.muted.opacity(0.6), lineWidth: 1.2))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
