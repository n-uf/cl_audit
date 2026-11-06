// SwitchWaiting: "Claude Main: the switch is waiting for you". A switch that has reached a step only the operator can do
// (Claude Code's sign-in in the browser, the Claude window's own sign-in, the Return in the sidebar session) is easy to
// miss with the browser or the Claude window in front: the Switch page waits out of sight. So, once per step, and only
// while the Switch page isn't in front (cl_audit's window isn't the key window, or another page is selected), one alert
// says which step. Its buttons: Show switch (opens that switch's page) and, at Claude Code's sign-in, Cancel switch (the
// runner's own cancel: the sessions go back). After linking there is nothing to cancel, so Show switch alone. A plain
// click on the alert is Show switch too.
//
// Several switches can wait at once (one per profile): each has its own state and its own alert (the id carries the
// switch's key). A step that is over in a moment never alerts: it must be seen on two looks in a row (or last 4 s); the
// window's sign-in of a profile without a Claude window, and the Return step before the session is open (or after its
// link missed), never do.
//
// The settings app posts it itself (it holds the SwitchRunner, and it is cl_audit, so macOS lists the alert under cl_audit)
// and answers its buttons (SwitchView.swift). It goes when the step moves on, the switch ends, or the page comes to the
// front, and none outlives cl_audit (cleared at launch and at quit). Alerts reach the lock screen: the words never name
// an account, by its address or any part of it.

import Foundation
import UserNotifications

enum SwitchWaiting {
    static let showButton = "Show switch"
    static let cancelButton = "Cancel switch"
    /// Every waiting alert's id starts with this (the clean-up at launch and quit finds them by it).
    static let idPrefix = "switchwaiting."
    /// A step must have been seen on this many looks in a row, or have lasted this long, before it alerts.
    static let settledLooks = 2
    static let settledAfter: TimeInterval = 4

    /// A switch waiting at one step: which (the Switch page's key) and where.
    struct Step: Equatable {
        let key: String
        let phase: SwitchRunner.Phase
    }

    /// A switch that waits for the operator now, with what its alert needs.
    struct Waiting: Equatable {
        let step: Step
        let name: String            // its profile's name
        let steps: Int              // how many steps the switch has
        let notify: Bool            // the profile's alerts are on
    }

    /// The phases that wait for the operator.
    static func waits(_ p: SwitchRunner.Phase) -> Bool {
        switch p {
        case .codeSignIn, .windowSignIn, .sidebar: return true
        default: return false
        }
    }

    /// Whether a waiting phase is worth an alert now. Claude Code's sign-in always. The window's sign-in only for a profile
    /// with a Claude window (without one the switch is over at once). The Return step only once the session is there: not
    /// while the window is still being opened, nor after the link missed (the page says what to do).
    static func alertable(phase: SwitchRunner.Phase, hasWindow: Bool, linkSent: Bool, missed: Bool) -> Bool {
        switch phase {
        case .codeSignIn: return true
        case .windowSignIn: return hasWindow
        case .sidebar: return linkSent && !missed
        default: return false
        }
    }

    /// Cancel switch is offered only while Claude Code's sign-in waits: after that the profile is linked.
    static func canCancel(_ p: SwitchRunner.Phase) -> Bool { p == .codeSignIn }

    static func category(_ p: SwitchRunner.Phase) -> String {
        canCancel(p) ? SwitchAlert.waitingCategory : SwitchAlert.waitingLinkedCategory
    }

    /// The alert's words for a step ("Step 3 of 5"): never an address or any part of one, only the profile's name.
    static func words(profile name: String, phase: SwitchRunner.Phase, steps: Int) -> (title: String, body: String)? {
        let title = "Claude \(name.isEmpty ? "New profile" : name): the switch is waiting for you"
        switch phase {
        case .codeSignIn:
            return (title, "Step 3 of \(steps): finish the sign-in in the browser. cl_audit checks the account before it goes on.")
        case .windowSignIn:
            return (title, "Step 4 of \(steps): finish the sign-in in the Claude window. cl_audit checks the account before it goes on.")
        case .sidebar:
            return (title, "Step 5 of \(steps): press Return in the new session in the Claude window. It puts the sidebar back as it was.")
        default:
            return nil
        }
    }

    static func identifier(_ key: String) -> String { idPrefix + key }

    // MARK: once per step

    /// What the watcher remembers for one switch: the step it posted for (kept after the alert goes because the page came to
    /// the front, so the same step never posts twice), whether the alert is on the screen now, and how long the step has
    /// been seen.
    struct State: Equatable {
        var announced: Step?
        var delivered = false
        var seen: Step?
        var looks = 0
        var since: Date?
        var isEmpty: Bool { announced == nil && !delivered && seen == nil }
    }

    struct Plan: Equatable {
        var state: State
        var withdraw: Step?             // the alert of this step goes
        var post: Step?                 // a new alert for this step
    }

    /// One look at one switch: `running` is its step when it waits for the operator and is worth an alert (nil otherwise),
    /// `front` whether its Switch page is in front. Posts once per step, only once the step has settled (two looks in a row,
    /// or 4 s) and only while the page isn't in front; withdraws when the step moves on, the switch ends or the page comes
    /// to the front.
    static func next(_ s: State, running: Step?, front: Bool, now: Date = Date()) -> Plan {
        var st = s
        var withdraw: Step?, post: Step?
        if let r = running {
            if st.seen == r { st.looks += 1 } else { st.seen = r; st.looks = 1; st.since = now }
            let settled = st.looks >= settledLooks || now.timeIntervalSince(st.since ?? now) >= settledAfter
            if st.announced != r {
                if st.delivered, let a = st.announced { withdraw = a }          // the step moved on
                st.announced = nil; st.delivered = false
                if settled && !front { post = r; st.announced = r; st.delivered = true }
            } else if front, st.delivered {
                withdraw = r; st.delivered = false                              // the page is in front: it needs no alert
            }
        } else {
            if st.delivered, let a = st.announced { withdraw = a }              // the switch ended
            st = State()
        }
        return Plan(state: st, withdraw: withdraw, post: post)
    }

    // MARK: posting

    enum Event: Equatable {
        case post(id: String, title: String, body: String, category: String, key: String)
        case remove(id: String)
    }

    /// Tests only: takes the alerts instead of macOS.
    static var sink: ((Event) -> Void)?
    /// What the real alerts go through (the app's own notification center).
    static let delivery = WaitingDelivery(center: SystemWaitingCenter())

    static func deliver(_ e: Event) {
        if let sink { sink(e); return }
        switch e {
        case .remove(let id): delivery.withdraw(id)
        case .post(let id, let title, let body, let category, let key):
            delivery.post(WaitingAlert(id: id, title: title, body: body, category: category, key: key))
        }
    }

    /// Every waiting alert on the screen or waiting to show goes: at launch (the switches live in memory, so none is left
    /// that means anything) and at quit.
    static func clearAll(wait: Bool) {
        if let sink { sink(.remove(id: idPrefix + "*")); return }
        delivery.clearAll(wait: wait)
    }
}

/// One alert to hand to the notification center.
struct WaitingAlert: Equatable {
    let id: String
    let title: String
    let body: String
    let category: String
    let key: String
}

/// What the alerts need from macOS; tests give a fake that completes later.
protocol WaitingAlertCenter: AnyObject {
    /// Whether cl_audit may alert (may wait for macOS).
    func allowed() -> Bool
    /// Adds the alert; `done` once macOS has it (any thread, later).
    func add(_ a: WaitingAlert, done: @escaping () -> Void)
    func remove(id: String)
    /// Removes every delivered and pending alert whose id starts with `prefix` (may wait for macOS).
    func removeAll(prefix: String)
}

/// Hands the waiting alerts to the center, in order. `add` finishes later than it is called, so a withdrawal queued right
/// behind it can run first and the alert would stay: a withdrawn id is remembered, and the alert is removed again when its
/// add completes.
final class WaitingDelivery {
    private let center: WaitingAlertCenter
    private let queue = DispatchQueue(label: "cl_audit.switch-waiting", qos: .userInitiated)
    private var withdrawn = Set<String>()                // only on the queue

    init(center: WaitingAlertCenter) { self.center = center }

    func post(_ a: WaitingAlert) {
        queue.async { [self] in
            withdrawn.remove(a.id)
            guard center.allowed() else {
                agentLog.log("cl_audit: the switch-waiting alert waits: notifications for cl_audit aren't allowed")
                return
            }
            center.add(a) { [self] in
                queue.async { [self] in if withdrawn.contains(a.id) { center.remove(id: a.id) } }
            }
        }
    }

    func withdraw(_ id: String) {
        queue.async { [self] in
            withdrawn.insert(id)
            center.remove(id: id)
        }
    }

    func clearAll(wait: Bool) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            center.removeAll(prefix: SwitchWaiting.idPrefix)
            done.signal()
        }
        // at quit: 2 s at most, however slow the notification service is (the next launch clears what is left)
        if wait { _ = done.wait(timeout: .now() + 2) }
    }

    /// Tests only: returns once everything handed over so far has run.
    func drain() { queue.sync {} }
}

/// The app's own notification center.
final class SystemWaitingCenter: WaitingAlertCenter {
    func allowed() -> Bool {
        let got = DispatchSemaphore(value: 0)
        var ok = false
        UNUserNotificationCenter.current().getNotificationSettings { s in
            ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            got.signal()
        }
        _ = got.wait(timeout: .now() + 5)
        return ok
    }

    func add(_ a: WaitingAlert, done: @escaping () -> Void) {
        let center = UNUserNotificationCenter.current()
        SwitchAlert.register(center: center, wanting: a.category)
        let c = UNMutableNotificationContent()
        c.title = a.title; c.body = a.body
        c.threadIdentifier = SwitchOffer.parse(a.key)?.profile ?? "switch"
        c.categoryIdentifier = a.category
        c.userInfo = [SwitchAlert.keyField: a.key]
        c.sound = .default
        center.add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil)) { err in
            if err != nil { agentLog.error("cl_audit: the switch-waiting alert wasn't sent") }
            done()
        }
    }

    func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    func removeAll(prefix: String) {
        let center = UNUserNotificationCenter.current()
        let a = DispatchSemaphore(value: 0), b = DispatchSemaphore(value: 0)
        center.getDeliveredNotifications { list in
            center.removeDeliveredNotifications(withIdentifiers: list.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
            a.signal()
        }
        center.getPendingNotificationRequests { list in
            center.removePendingNotificationRequests(withIdentifiers: list.map(\.identifier).filter { $0.hasPrefix(prefix) })
            b.signal()
        }
        _ = a.wait(timeout: .now() + 2); _ = b.wait(timeout: .now() + 2)
    }
}

/// Looks at the switches every moment or two, in the settings app, and posts or withdraws each one's waiting alert.
final class SwitchWaitWatch {
    private(set) var states: [String: SwitchWaiting.State] = [:]

    /// `running`: every switch waiting for the operator and worth an alert now, whatever else runs; `front`: whether a
    /// switch's Switch page is in front. Each switch has its own state and its own alert: another one starting or ending
    /// changes nothing for the rest.
    func tick(running: [SwitchWaiting.Waiting], front: (String) -> Bool, now: Date = Date()) {
        let wanted = Dictionary(running.filter(\.notify).map { ($0.step.key, $0) }, uniquingKeysWith: { a, _ in a })
        for key in Set(states.keys).union(wanted.keys).sorted() {
            let w = wanted[key]
            let plan = SwitchWaiting.next(states[key] ?? SwitchWaiting.State(), running: w?.step, front: front(key), now: now)
            if plan.state.isEmpty { states[key] = nil } else { states[key] = plan.state }
            if let old = plan.withdraw { SwitchWaiting.deliver(.remove(id: SwitchWaiting.identifier(old.key))) }
            if let p = plan.post, let w, let words = SwitchWaiting.words(profile: w.name, phase: p.phase, steps: w.steps) {
                SwitchWaiting.deliver(.post(id: SwitchWaiting.identifier(p.key), title: words.title, body: words.body,
                                            category: SwitchWaiting.category(p.phase), key: p.key))
            }
        }
    }
}
