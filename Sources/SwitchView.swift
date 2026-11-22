// SwitchView: the Switch page (Switch.swift), opened from the dashboard's at-limit box, the alert's Switch button and
// the Dock and menu bar menus. It says what stays, what follows and what will happen. Read-only for now: the switch
// itself comes in a later build, so its key is off and one grey line says so.

import AddressPrivacy
import AppKit
import ProfileCore
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
            // Cancel switch on "the switch is waiting for you": the runner's own cancel, only while Claude Code's sign-in waits
            // (a cl_audit started just for this button has no switch to cancel and quits again below)
            if response.actionIdentifier == SwitchAlert.cancelSwitch {
                DispatchQueue.main.async { if self.launched { self.manager.cancelWaitingSwitch(key) } }
            }
            // started just for this button: show nothing, quit. (A Later within 5 s of opening cl_audit yourself quits it
            // too, but only while none of its windows is on screen yet.)
            DispatchQueue.main.async { if Date().timeIntervalSince(self.launchedAt) < 5 { self.quietLaunch = true; self.quitIfQuiet() } }
            return
        }
        guard SwitchAlert.opensPage(action: response.actionIdentifier, category: response.notification.request.content.categoryIdentifier) else { return }
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

/// An alert with a Switch account… button: one category for every alert (its words name no account), and the target
/// rides along in the alert's userInfo.
enum SwitchAlert {
    static let category = "switch"
    static let action = "switch"
    static let later = "later"
    /// "the other account is back"'s Stay (26.11.13 and earlier): an old alert's button still needs no window.
    static let stay = "stay"
    /// Categories older builds registered: taken away when the categories are set again.
    static let retired: Set<String> = ["switchBack", "switchWaitingLinked"]
    static let keyField = "switch"
    /// "the switch is waiting for you" (SwitchWaiting.swift): Show switch (the `action` above) and Cancel switch.
    static let waitingCategory = "switchWaiting"
    static let cancelSwitch = "cancelSwitch"

    /// A response that opens the Switch page: the Show/Switch button of any alert, or a plain click on "the switch is waiting
    /// for you" (the other alerts' plain click only brings cl_audit forward, as before).
    static func opensPage(action: String, category: String) -> Bool {
        action == self.action || (action == UNNotificationDefaultActionIdentifier && category == waitingCategory)
    }

    /// A button that needs no window: Stay, Later, Cancel switch.
    static func isQuiet(_ action: String?) -> Bool { action == stay || action == later || action == cancelSwitch }
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

    /// The alerts' categories: Switch account… and Later; Show switch and Cancel switch.
    static func categories() -> [UNNotificationCategory] {
        [UNNotificationCategory(identifier: category,
                                actions: [UNNotificationAction(identifier: action, title: SwitchWords.button, options: [.foreground]),
                                          UNNotificationAction(identifier: later, title: "Later", options: [])],
                                intentIdentifiers: [], options: []),
         UNNotificationCategory(identifier: waitingCategory,
                                actions: [UNNotificationAction(identifier: action, title: SwitchWaiting.showButton, options: [.foreground]),
                                          UNNotificationAction(identifier: cancelSwitch, title: SwitchWaiting.cancelButton, options: [])],
                                intentIdentifiers: [], options: [])]
    }

    /// Registers the alerts' categories (`categories()`), kept with any others but the per-account ones older builds made
    /// ("switch.<key>"), and waits until macOS has the one asked for (up to 2 s): setting categories doesn't say when it's
    /// done, and an alert added before would show without its buttons. The target rides in each alert's userInfo. Never on
    /// the main thread.
    @discardableResult
    static func register(center: UNUserNotificationCenter = .current(), wanting: String? = nil) -> String {
        func current() -> Set<UNNotificationCategory> {
            var got: Set<UNNotificationCategory> = []
            let done = DispatchSemaphore(value: 0)
            center.getNotificationCategories { got = $0; done.signal() }
            _ = done.wait(timeout: .now() + 2)
            return got
        }
        let ours = Set(categories().map(\.identifier))
        var set = current().filter { !$0.identifier.hasPrefix("switch.") && !ours.contains($0.identifier) && !retired.contains($0.identifier) }
        categories().forEach { set.insert($0) }
        center.setNotificationCategories(set)
        let wanted = wanting ?? category
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !current().contains(where: { $0.identifier == wanted }) { usleep(100_000) }
        return wanted
    }
}

/// Flush on the right of a profile's tile, only while its Switch page is open, and while its switch waits for the sign-in
/// even with the page closed: "Switch from / ultra-1" (unlit), mint "Switching ● / to ultra-2" while it waits,
/// "Switched to / ultra-2" once there; amber "Signed in as / ultra-3" or "No sign-in / try again". Otherwise the tile
/// stands alone. A click opens the Switch page.
struct SwitchTileDisplay: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel

    var body: some View {
        let _ = model.tick
        if let r = model.switchRunner(of: entry.id) {
            RunnerTileDisplay(entry: entry, model: model, runner: r)
        } else if let rr = model.restoreRunner(of: entry.id) {
            RestoreTileDisplay(entry: entry, model: model, runner: rr)
        } else if let u = model.unfinishedRestore(of: entry.id) {
            // a restore that stopped half way (also one cl_audit stopped in): its page finishes it or undoes it
            TileDisplayGlass(l1: u.importedFrom != nil ? "Import stopped" : "Restore stopped", l2: "Finish or undo", tone: .amber) { model.showRestore(finishing: u) }
        }
    }
}

private struct RunnerTileDisplay: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: SwitchRunner
    @ObservedObject private var privacy = AddressPrivacy.shared      // (it names accounts: drawn again when Show emails changes)

    var body: some View {
        let open = model.selection == SettingsModel.switchID && model.switching == runner.key
        let to = runner.targetShort ?? "the other account"
        switch runner.phase {
        case .waiting:
            TileDisplayGlass(l1: "Switching ●", l2: "to \(to)", tone: .mint, l1Lit: true) { model.showSwitch(runner.key) }
        case .reached where open:
            TileDisplayGlass(l1: "Switched to", l2: to, tone: .mint) { }
        case .other(let e) where open:
            TileDisplayGlass(l1: "Signed in as", l2: AccountNames.short(e), tone: .amber) { }
        case .timedOut where open:
            TileDisplayGlass(l1: "No sign-in", l2: "try again", tone: .amber) { }
        case .failed where open:
            let w = SwitchRunner.failedWords(runner.receipt, moved: runner.movedShown)
            TileDisplayGlass(l1: w.l1, l2: w.l2, tone: .warn) { }
        case .ready where open:
            TileDisplayGlass(l1: "Switch from", l2: AccountNames.short(AccountView.of(Store.status(for: entry)).numbersOwner ?? "its account"), tone: .normal, unlit: true) { }
        default:
            EmptyView()
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

/// One standby account in the card's Switch account menu: its offer (Switch.swift). Never its usage: a standby account
/// isn't read.
struct CardTray: Identifiable {
    let offer: SwitchOffer
    var id: String { offer.key }
}

extension AccountEntry {
    /// The standby accounts the card's Switch account menu lists, in the order a full limit offers them (AccountBook.offerOrder).
    func cardTrays(now: Date = Date()) -> [CardTray] {
        switchOffers(now: now).map { CardTray(offer: $0) }
    }
}

