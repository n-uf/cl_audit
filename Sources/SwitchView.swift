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




