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
        guard let key = response.notification.request.content.userInfo[SwitchAlert.keyField] as? String else { return }
        if SwitchAlert.isQuiet(response.actionIdentifier) {
            // Stay on "the other account is back": the offer goes from the card and the menus
            if response.actionIdentifier == SwitchAlert.stay { BackWatch.dismiss(key) }
            // started just for this button: show nothing, quit. (A Stay within 5 s of opening cl_audit yourself quits it
            // too, but only while none of its windows is on screen yet.)
            DispatchQueue.main.async { if Date().timeIntervalSince(self.launchedAt) < 5 { self.quietLaunch = true; self.quitIfQuiet() } }
            return
        }
        guard response.actionIdentifier == SwitchAlert.action else { return }
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
    static let backCategory = "switchBack"              // "the other account is back": Switch back, Stay
    static let backKind = "back"                        // --post-alert's last word for it
    static let action = "switch"
    static let later = "later"
    static let stay = "stay"
    static let keyField = "switch"

    /// A button that needs no window: Stay, Later.
    static func isQuiet(_ action: String?) -> Bool { action == stay || action == later }
}

/// What the settings app shows when it starts. An alert's Stay or Later can start it in the background (macOS hands
/// the button to cl_audit): then it does that, shows nothing and quits, instead of opening the Dashboard.
enum LaunchPlan: Equatable {
    case quiet              // started only for Stay or Later
    case waitForAlert       // started by an alert: its button may still be on its way; shown after a moment unless quiet
    case show

    static func decide(launchAction: String?, launchIsDefault: Bool?) -> LaunchPlan {
        if SwitchAlert.isQuiet(launchAction) { return .quiet }
        if launchAction != nil || launchIsDefault == false { return .waitForAlert }
        return .show
    }
}

extension SwitchAlert {

    /// Registers the alerts' two categories (Switch accounts and Later; Switch back and Stay), kept with any others but
    /// the per-account ones older builds made ("switch.<key>"), and waits until macOS has the one asked for (up to 2 s):
    /// setting categories doesn't say when it's done, and an alert added before would show without its buttons. The
    /// target rides in each alert's userInfo.
    @discardableResult
    static func register(center: UNUserNotificationCenter = .current(), back: Bool = false) -> String {
        func current() -> Set<UNNotificationCategory> {
            var got: Set<UNNotificationCategory> = []
            let done = DispatchSemaphore(value: 0)
            center.getNotificationCategories { got = $0; done.signal() }
            _ = done.wait(timeout: .now() + 2)
            return got
        }
        var set = current().filter { !$0.identifier.hasPrefix("switch.") && $0.identifier != category && $0.identifier != backCategory }
        set.insert(UNNotificationCategory(identifier: category,
                                          actions: [UNNotificationAction(identifier: action, title: SwitchWords.button, options: [.foreground]),
                                                    UNNotificationAction(identifier: later, title: "Later", options: [])],
                                          intentIdentifiers: [], options: []))
        set.insert(UNNotificationCategory(identifier: backCategory,
                                          actions: [UNNotificationAction(identifier: action, title: "Switch back", options: [.foreground]),
                                                    UNNotificationAction(identifier: stay, title: "Stay", options: [])],
                                          intentIdentifiers: [], options: []))
        center.setNotificationCategories(set)
        let wanted = back ? backCategory : category
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !current().contains(where: { $0.identifier == wanted }) { usleep(100_000) }
        return wanted
    }
}

/// A standby account that is back, on its profile's dashboard card (SwitchBack.swift): "ultra-1 is back: its week
/// starts again", Stay, and Switch back to ultra-1….
struct BackOfferRow: View {
    let offer: BackOffer
    let open: (String) -> Void
    @Environment(\.face) private var face

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { words; Spacer(minLength: 6); stay; key }
            VStack(alignment: .leading, spacing: 6) {
                words
                HStack(spacing: 8) { Spacer(minLength: 0); stay; key }
            }
        }
    }

    private var words: some View {
        Text(offer.words).font(.system(size: 12)).foregroundStyle(face.soft).lineLimit(1)
    }
    private var stay: some View {
        Button("Stay") { BackWatch.dismiss(offer.key) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(face.muted).fixedSize()
    }
    private var key: some View {
        Button(offer.title) { open(offer.key) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
    }
}

/// Flush on the right of a profile's tile, only while its Switch page is open, and while a switch of it is unfinished
/// even with the page closed: "Switch from / ultra-1" (unlit), mint "Switching ● / to ultra-2" while it runs,
/// "Switched to / ultra-2" at Done; amber "Stopped half way / Undo it" for one that stopped; red "Stopped / step 3".
/// Otherwise the tile stands alone. A click opens the Switch page.
struct SwitchTileDisplay: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.tick
        if let r = model.switchRunner(of: entry.id) {
            RunnerTileDisplay(entry: entry, model: model, runner: r)
        } else if let u = model.unfinishedSwitch(of: entry.id) {
            TileDisplayGlass(l1: "Stopped half way", l2: "Undo it", tone: .amber) {
                model.showSwitch(AccountEntry.standbyStatusID(u.profile, u.standby))
            }
        }
    }
}

private struct RunnerTileDisplay: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner

    var body: some View {
        let open = model.selection == SettingsModel.switchID && model.switching == runner.key
        let to = runner.targetShort ?? "the other account"
        let failed: Bool = { if case .failed = runner.phase { return true }; return false }()
        switch runner.phase {
        case .closing, .moving, .codeSignIn, .windowSignIn, .sidebar:
            TileDisplayGlass(l1: "Switching ●", l2: "to \(to)", tone: .mint, l1Lit: true) { model.showSwitch(runner.key) }
        case .done where open:
            TileDisplayGlass(l1: "Switched to", l2: to, tone: .mint) { }
        case .failed where runner.receipt?.unfinished == true:
            TileDisplayGlass(l1: "Stopped half way", l2: "Undo it", tone: .amber) { model.showSwitch(runner.key) }
        default:
            // a switch that stopped half way (an earlier one too) shows before anything else, as on the page
            if let u = model.unfinishedSwitch(of: entry.id) {
                TileDisplayGlass(l1: "Stopped half way", l2: "Undo it", tone: .amber) { model.showSwitch(AccountEntry.standbyStatusID(u.profile, u.standby)) }
            } else if open, failed {
                TileDisplayGlass(l1: "Stopped", l2: runner.failedStep.map { "at step \($0)" } ?? "nothing moved", tone: .warn) { }
            } else if open, runner.phase == .ready || runner.phase == .cancelled {
                TileDisplayGlass(l1: "Switch from", l2: AccountNames.short(entry.seat?.email ?? "its account"), tone: .normal, unlit: true) { }
            }
        }
    }
}

/// The display itself: recessed glass flush beside the tile, two lines (what it's about, small and dim; the account).
struct TileDisplayGlass: View {
    let l1: String
    let l2: String
    var tone: DisplayWindow.Tone = .normal
    var unlit = false
    var l1Lit = false
    let action: () -> Void
    @Environment(\.face) private var face

    var body: some View {
        let lit: Color = {
            switch tone {
            case .mint: return face.light ? .hex(0x0b6b60) : .hex(0xa6fff3)
            case .amber: return face.light ? .hex(0xa85f00) : .hex(0xffb24a)
            case .warn: return face.light ? .hex(0xb42318) : .hex(0xff8a7a)
            case .ok: return face.light ? .hex(0x11743a) : FaceTheme.ledOn
            case .normal: return face.displayText
            }
        }()
        let c = unlit ? face.displayText.opacity(0.30) : lit
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l1).font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1.4).textCase(.uppercase)
                    .foregroundStyle(l1Lit && !unlit ? c : c.opacity(unlit ? 1 : 0.45))
                Text(l2).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(c)
                    .shadow(color: unlit || !face.displayGlow ? .clear : c.opacity(0.7), radius: 1.5)
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 14)
            .frame(minWidth: 128, minHeight: 42, alignment: .leading)
            .background(DisplayGlass(radius: 5))
            .offset(y: 1)
        }
        .buttonStyle(.plain)
    }
}

/// One standby account on the dashboard card: its offer (Switch.swift) and its limits as the card draws them.
struct CardTray: Identifiable {
    let offer: SwitchOffer
    let limits: [Limit]
    var id: String { offer.key }
}

extension AccountEntry {
    /// The standby accounts the card shows, as trays, most room first (SwitchOffer order): those with a kept sign-in and
    /// numbers. One with no numbers stays off the card. A tray shows the 5-hour and weekly rows (a plan without a 5-hour
    /// limit, just the week); a model's own limit is on the Switch page and in Settings.
    func cardTrays(status: (String) -> IconStatus? = Store.status, now: Date = Date()) -> [CardTray] {
        switchOffers(status: status, now: now).compactMap { o in
            guard o.status?.weekly != nil || o.status?.fiveHour != nil, let e = readerEntry(for: o.standby) else { return nil }
            let all = AccountRow(entry: e, status: o.status).limits
            let main = all.filter { $0.id == "5h" || $0.id == "wk" }
            return CardTray(offer: o, limits: main.isEmpty ? all : main)
        }
    }

    /// The one preselected while a limit is full: the tray with the most room that can be switched to, unless it is back and
    /// has its own row with Switch back (SwitchBack.swift).
    func cardBest(_ trays: [CardTray], backs: [BackOffer]) -> String? {
        trays.first { t in t.offer.room && AccountSettings.canSwitch(t.offer.standby) && !backs.contains { $0.key == t.offer.key } }?.id
    }
}

/// Which tray on the card is selected. While a limit is full the one with the most room is selected already, and a click
/// picks another instead (never deselects). With room left nothing is selected: a click selects, a second click on the
/// same tray deselects, as in Settings.
enum TrayPick {
    static func selected(picked: String?, full: Bool, best: String?, keys: [String]) -> String? {
        if let p = picked, keys.contains(p) { return p }
        return full ? best.flatMap { keys.contains($0) ? $0 : nil } : nil
    }

    /// The pick after a click on `key`, given what is selected now.
    static func tapped(_ key: String, selected: String?, full: Bool) -> String? {
        full ? key : (selected == key ? nil : key)
    }
}

/// A profile's standby accounts on its dashboard card: unlit trays under the limits, their levels dimmed. Only the account
/// in use is lit. The selected tray lights mint across the card (the lit bar), and its Standby display becomes the lit
/// Switch account key, which opens the Switch page with that account picked.
struct StandbyTrays: View {
    let limits: [Limit]                 // the account in use's: whether one is full
    let trays: [CardTray]
    let best: String?                   // preselected while a limit is full
    let design: PanelDesign
    let open: (String) -> Void
    @State private var picked: String?
    @Environment(\.face) private var face

    /// `picked`: the tray clicked at the start (renders only).
    init(limits: [Limit], trays: [CardTray], best: String?, design: PanelDesign, open: @escaping (String) -> Void, picked: String? = nil) {
        self.limits = limits; self.trays = trays; self.best = best; self.design = design; self.open = open
        _picked = State(initialValue: picked)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let full = AtLimit.blocker(limits, now: ctx.date) != nil
            let sel = TrayPick.selected(picked: picked, full: full, best: best, keys: trays.filter { AccountSettings.canSwitch($0.offer.standby) }.map(\.id))
            VStack(spacing: 9) {
                ForEach(trays) { t in tray(t, selected: sel == t.id, full: full, selection: sel, now: ctx.date) }
            }
            // a pick belongs to the state it was made in: a full limit that resets starts over
            .onChange(of: full) { _ in picked = nil }
        }
    }

    private func tray(_ t: CardTray, selected: Bool, full: Bool, selection: String?, now: Date) -> some View {
        let key = t.offer.key
        let can = AccountSettings.canSwitch(t.offer.standby)       // an account not linked yet can't be selected
        let help = !can ? "" : selected ? (full ? "Click another account to pick it instead" : "Click to deselect")
                                        : "Click to select, then Switch account"
        // a click on the address or the limits selects; the lit key (and the Standby display) stay outside the click area, so
        // the key never selects or deselects, as in Settings
        return AccountBox(lamp: nil, badge: "Standby", detail: nil, unlit: !selected, dimsContent: true,
                          selected: selected, litBadge: "Switch account", litAction: { open(key) }, compact: true) {
            Text(Privacy.masked(t.offer.standby.email)).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(selected ? (face.light ? Face.std.theme.text : face.text) : face.soft)
                .lineLimit(1).truncationMode(.tail).hidesEmail()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if can { picked = TrayPick.tapped(key, selected: selection, full: full) } }
                .help(help)
        } content: {
            TrayRows(limits: t.limits, design: design, now: now)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { if can { picked = TrayPick.tapped(key, selected: selection, full: full) } }
                .help(help)
        }
    }
}

/// A standby account's limits in its tray, small: a row per limit (name, bar, percentage, "in 3 days" or, full, when it's
/// back).
struct TrayRows: View {
    let limits: [Limit]
    let design: PanelDesign
    var now: Date
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(limits) { l in row(l, now: now) }
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




