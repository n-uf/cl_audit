// AddAccount: Settings ▸ a profile ▸ Claude Code ▸ Accounts ▸ Add account.
//
// Here: the pop-up Add account opens (macOS's own menu, two lines a row: the address, then in grey what is known about
// it), what one click on a found account does, and the words and keys a standby account shows while it is new: signing
// in, signed in to the wrong account, added with no numbers yet. Pure and without views, so the checks can drive them;
// Settings.swift (AccountSettings) puts them on screen. Nothing here changes how a sign-in works: the folder, Terminal
// and the watching for the sign-in are Accounts.swift's, Config.swift's and Folders.swift's, as before.

import AppKit
import SwiftUI

// MARK: the pop-up

/// One line of Add account's pop-up.
struct AddAccountRow: Equatable, Identifiable {
    enum Kind: Equatable { case caption, note, account, divider, signInOther }
    var id: String
    var kind: Kind
    var title = ""
    var detail: String?                  // the grey second line
    var enabled = true                   // an account of another profile is listed but can't be added
}

enum AddAccountPopup {
    /// "Found on this Mac", each account as two lines (found accounts show no usage: cl_audit reads limits only for a
    /// profile's own accounts), a line, then "Sign in to another account…". `found` nil: the first look is under way.
    static func rows(found: [FoundAccount]?, profile: String, canSignIn: Bool, now: Date = Date()) -> [AddAccountRow] {
        var out = [AddAccountRow(id: "cap", kind: .caption, title: "Found on this Mac", enabled: false)]
        if found == nil { out.append(AddAccountRow(id: "looking", kind: .note, title: "Looking…", enabled: false)) }
        else if found?.isEmpty == true { out.append(AddAccountRow(id: "none", kind: .note, title: "Nothing else found", enabled: false)) }
        for f in found ?? [] {
            out.append(AddAccountRow(id: f.id, kind: .account, title: Privacy.masked(f.email),
                                     detail: f.second(profile: profile, now: now), enabled: f.owner == nil))
        }
        out.append(AddAccountRow(id: "div", kind: .divider))
        out.append(AddAccountRow(id: "other", kind: .signInOther, title: "Sign in to another account…", enabled: canSignIn))
        return out
    }

    /// The text of a two-line row: the address in the menu's own font, then the grey line; another profile's account
    /// dimmed as a disabled menu line is.
    static func title(_ r: AddAccountRow) -> NSAttributedString {
        let dim = !r.enabled
        let out = NSMutableAttributedString(string: r.title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: dim ? NSColor.disabledControlTextColor : NSColor.labelColor])
        if let d = r.detail, !d.isEmpty {
            out.append(NSAttributedString(string: "\n" + d, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .foregroundColor: dim ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor]))
        }
        return out
    }

    /// The menu. An item calls `onAdd` with the found account's id, or `onOther`; nothing else happens in it.
    static func menu(_ rows: [AddAccountRow], onAdd: @escaping (String) -> Void, onOther: @escaping () -> Void) -> NSMenu {
        let m = NSMenu(title: "Add account"); m.autoenablesItems = false
        for r in rows {
            switch r.kind {
            case .divider:
                m.addItem(.separator())
            case .caption:
                // a section's caption as macOS draws one: small, grey, not clickable
                let i = NSMenuItem(title: r.title, action: nil, keyEquivalent: ""); i.isEnabled = false
                i.attributedTitle = NSAttributedString(string: r.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor])
                m.addItem(i)
            case .note:
                let i = NSMenuItem(title: r.title, action: nil, keyEquivalent: ""); i.isEnabled = false
                m.addItem(i)
            case .account, .signInOther:
                let run = r.kind == .account ? { onAdd(r.id) } : { onOther() }
                let i = NSMenuItem(title: r.title, action: r.enabled ? #selector(MenuAction.fire) : nil, keyEquivalent: "")
                i.attributedTitle = title(r)
                i.isEnabled = r.enabled
                if r.enabled {
                    let a = MenuAction(run)
                    i.target = a
                    i.representedObject = a                     // the item keeps it alive; `target` doesn't
                }
                m.addItem(i)
            }
        }
        return m
    }
}

/// What a menu item calls.
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// A transparent layer over a key that opens an NSMenu under it when clicked (SwiftUI's own Menu can't draw two lines
/// in a row). The menu is built when it opens, so it shows the latest list.
struct MenuTrigger: NSViewRepresentable {
    let label: String
    /// Told when the menu opens (true) and closes (false), so the key under it can be drawn pressed meanwhile.
    var opened: (Bool) -> Void = { _ in }
    let menu: () -> NSMenu

    func makeNSView(context: Context) -> TriggerView {
        let v = TriggerView()
        v.focusRingType = .exterior
        v.setAccessibilityRole(.popUpButton)
        return v
    }
    func updateNSView(_ v: TriggerView, context: Context) {
        v.makeMenu = menu
        v.opened = opened
        v.setAccessibilityLabel(label)
    }

    final class TriggerView: NSView {
        var makeMenu: (() -> NSMenu)?
        var opened: (Bool) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // reachable by keyboard (Tab, then Space or Return) and by VoiceOver (press)
        override var acceptsFirstResponder: Bool { true }
        // a visible focus ring round the key while it has the keyboard
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
        override func becomeFirstResponder() -> Bool { noteFocusRingMaskChanged(); return super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return super.resignFirstResponder() }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityPerformPress() -> Bool { pop(); return true }
        override func mouseDown(with event: NSEvent) { pop() }
        override func keyDown(with event: NSEvent) {
            if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 76 { pop() } else { super.keyDown(with: event) }
        }
        func pop() {
            guard let m = makeMenu?() else { return }
            opened(true)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)    // under the key, as a pop-up's list is
            opened(false)
        }
    }
}

extension FoundAccount {
    /// The pop-up's grey line: plan · organisation · what's known of its sign-in · limits once added.
    /// "Ultra · Personal · signed in, ~/.claude-ultra-3 · limits once added",
    /// "Pro · Personal · needs a sign-in · used in Main's window in August", "Work's · one profile per account".
    func second(profile: String, now: Date = Date()) -> String {
        if let owner { return "\(AddAccountWords.possessive(owner)) · one profile per account" }
        var parts = [plan, org].compactMap { $0 }
        if let folder { parts.append("signed in, \(tilde(expand(folder)))") } else { parts.append("needs a sign-in") }
        if let used = usedInWindow {
            parts.append("used in \(profile.isEmpty ? "this profile's" : AddAccountWords.possessive(profile)) window \(Self.whenUsed(used, now: now))")
        }
        if signedIn { parts.append("limits once added") }
        return parts.joined(separator: " · ")
    }
}

extension AccountEntry {
    /// The profile with this found account added as a standby account (one click in the pop-up), or nil when it can't
    /// be: it is already one of the profile's, or another profile has it. Its folder, when a sign-in is kept there, is
    /// where its limits are read from; none is copied or moved.
    func adding(_ f: FoundAccount, among accounts: [AccountEntry], now: Date = Date(),
                signedIn: (String) -> Seat? = Account.signedInSeat) -> AccountEntry? {
        // not the profile's own, another profile's, or the one its working folder is signed in to (as linkStandbySeats)
        guard !has(f.seat), !f.seat.same(signedIn(configDir)),
              FolderRules.seatOwner(f.seat, among: accounts, except: id, signedIn: signedIn) == nil else { return nil }
        var seat = f.seat
        seat.linkedAt = now
        var out = self
        out.standby.append(StandbyAccount(email: f.email, seat: seat, configDir: f.folder))
        return out
    }
}

/// The line under the address field of "Sign in to another account…".
enum AddAccountWords {
    /// "Claude Code signs in through Terminal, in a folder of its own (~/.claude-ultra-4); Main keeps working meanwhile."
    /// The folder is named the way the sign-in will name it, once the address looks like one.
    static func signInLine(profile: String, typed: String,
                           exists: (String) -> Bool = { FileManager.default.fileExists(atPath: expand($0)) }) -> String {
        let who = profile.isEmpty ? "the profile" : profile
        let email = typed.trimmingCharacters(in: .whitespaces)
        let folder = Self.looksLikeAddress(email) ? " (\(StandbyFolder.name(for: email, exists: exists)))" : ""
        return "Claude Code signs in through Terminal, in a folder of its own\(folder); \(who) keeps working meanwhile."
    }

    /// "Main's", "Work's"; a name ending in s takes only the apostrophe: "Boss'".
    static func possessive(_ name: String) -> String { name.lowercased().hasSuffix("s") ? "\(name)'" : "\(name)'s" }

    static func looksLikeAddress(_ s: String) -> Bool { s.contains("@") && !s.hasPrefix("@") && !s.hasSuffix("@") }
}

// MARK: a new account's box

/// What a standby account's box says besides its limits: its display, one line of what's left, and the keys for it.
/// A new account is an ordinary standby box from the start; it never shows another account's numbers.
struct StandbyLook: Equatable {
    enum Key: Hashable { case cancel, showTerminal, signIn, signInAgain }
    /// The account its own folder is signed in to, when that isn't one this profile can have.
    enum Clash: Equatable { case own, other(String) }

    var badge = "Standby"
    var tone: DisplayWindow.Tone = .normal
    var line: String?                    // nil: its limits show
    var lineTone: BoxNote.Tone = .caution
    var keys: [Key] = []
    /// A warning or a line with a key keeps full strength; only limits (and "no numbers yet") dim in an unlit box.
    var dims = false

    /// How long a sign-in may take before the box says it didn't finish.
    static let staleAfter: TimeInterval = 15 * 60

    /// When the sign-in in this folder was last started, from what is already recorded (nothing new is saved): the
    /// Terminal script `openLogin` writes each time it starts one (its date), else `fallback` (when the account was
    /// added, for an account with no seat yet).
    static func signInStarted(configDir: String, addedAt fallback: Date?) -> Date? {
        let script = ClaudeCLI.loginScript(expand(configDir)).path
        let made = (try? FileManager.default.attributesOfItem(atPath: script))?[.modificationDate] as? Date
        return made ?? fallback
    }

    private static func sameSeat(_ a: Seat?, _ b: Seat?) -> Bool { a == nil && b == nil || (a?.same(b) ?? false) }

    /// - linked: the account has its seat (the account and organisation a sign-in named)
    /// - folderSeat: the account its folder is signed in to now (Claude Code's own record; the browser isn't visible
    ///   to cl_audit, so "the browser signed in as" is what that sign-in says)
    /// - clash: set when folderSeat is the profile's own account or another profile's (the sign-in is refused)
    /// - state: its saved status ("ok", "noLogin", "otherAccount", "expired"…)
    /// - attempt: the Sign in… clicked in this run of cl_audit (SignInAttempts): the folder's seat then and when. While
    ///   the folder's seat is still that one, the sign-in is under way, whatever Claude Code writes to the folder's
    ///   record meanwhile; a different seat ends it (the real result: linked, or the wrong account).
    /// - startedAt, signedInAt: with no attempt remembered (cl_audit restarted meanwhile), the dates: when a sign-in was
    ///   last started in the folder (`signInStarted`) and when the folder's record last changed; one started after the
    ///   record changed is under way.
    /// Only a sign-in that was started shows "Signing in" or "Not finished"; Cancel (take the account off the profile)
    /// is only for an account with no seat yet, never a linked one.
    static func of(email: String, hasFolder: Bool, linked: Bool, folderSeat: Seat?, clash: Clash?,
                   state: String?, hasNumbers: Bool, problem: String?,
                   attempt: SignInAttempt? = nil, startedAt: Date? = nil, signedInAt: Date? = nil,
                   now: Date = Date()) -> StandbyLook {
        let me = Privacy.masked(email)
        if !hasFolder {
            return StandbyLook(line: "Limits unknown: no sign-in kept for it.", keys: [.signIn])
        }
        // a sign-in under way: mint; a quarter of an hour on, still nothing new in the folder: not finished
        func underWay(since: Date?) -> StandbyLook {
            if let since, now.timeIntervalSince(since) >= Self.staleAfter {
                return StandbyLook(badge: "Not finished", tone: .amber,
                                   line: linked ? "The sign-in didn't finish. Sign in again." : "The sign-in didn't finish. Sign in again, or cancel.",
                                   lineTone: .caution, keys: linked ? [.signInAgain] : [.cancel, .signInAgain])
            }
            return StandbyLook(badge: "Signing in", tone: .mint, line: "Finish the sign-in in the browser, as \(me).",
                               lineTone: .muted, keys: linked ? [.showTerminal] : [.cancel, .showTerminal])
        }
        // started after the folder's record last changed (the dates, when nothing is remembered)
        let datesStarted: Date? = startedAt.flatMap { st in signedInAt.map { st > $0 } ?? false ? st : nil }
        // started after, or no record at all
        let datesStartedLenient: Date? = startedAt.flatMap { st in signedInAt.map { st > $0 } ?? true ? st : nil }
        /// The sign-in under way, and since when: the attempt while the folder's seat is still what it was, else the dates.
        func under(_ dates: Date?) -> Date? {
            if let attempt { return Self.sameSeat(folderSeat, attempt.seat) ? attempt.at : nil }
            return dates
        }
        if !linked {
            // not linked yet: the folder has no sign-in (under way), or one the profile can't have (the wrong account)
            if clash != nil {
                if let began = under(datesStarted) { return underWay(since: began) }
                let got = folderSeat?.email.map { AccountNames.short($0) } ?? "another account"
                let not = AccountNames.short(email)
                var line = "The browser signed in as \(got), not \(not). Switch the browser's account, then sign in again."
                if case .other(let name) = clash {
                    line = "The browser signed in as \(got), which is \(AddAccountWords.possessive(name)) account (one profile per account), not \(not). Switch the browser's account, then sign in again."
                }
                return StandbyLook(badge: "Wrong account", tone: .amber, line: line, lineTone: .caution, keys: [.cancel, .signInAgain])
            }
            // nothing in the folder yet: under way (since the click, else the script, else when it was added)
            if folderSeat == nil { return underWay(since: attempt?.at ?? startedAt) }
            // a free account's sign-in links by itself within seconds, whatever the start's age: never "not finished"
            return underWay(since: nil)
        }
        if state == "otherAccount" {
            if let began = under(datesStarted) { return underWay(since: began) }
            return StandbyLook(badge: "Wrong account", tone: .amber,
                               line: "Its folder is signed in to another account: sign in again as \(me).", keys: [.signInAgain])
        }
        // linked, but its folder holds no sign-in (an account found as needing one, signed in from its box): under way only
        // when a sign-in was started there since the folder's record changed; else the plain reminder. Never "No numbers
        // yet… from the sign-in kept in its folder" for a folder with none.
        if folderSeat == nil, state == "noLogin" || !hasNumbers {
            if let began = attempt?.at ?? datesStartedLenient { return underWay(since: began) }
            return StandbyLook(line: "Waiting for the sign-in: finish it in the browser, or sign in again.", keys: [.signInAgain])
        }
        if state == "noLogin" {
            return StandbyLook(line: "Waiting for the sign-in: finish it in the browser, or sign in again.", keys: [.signInAgain])
        }
        if !hasNumbers {
            return StandbyLook(line: problem ?? "No numbers yet: cl_audit reads them within a few minutes, from the sign-in kept in its folder, and keeps that sign-in renewed.",
                               lineTone: .muted, dims: true)
        }
        return StandbyLook(dims: true)
    }

    /// Whether the account's folder is signed in to an account the profile can't have (checked only while the account has
    /// no seat; once linked, a folder signed in to another account is "otherAccount" in its status).
    static func clash(of folderSeat: Seat?, for entry: AccountEntry, among accounts: [AccountEntry],
                      inUse: Seat? = nil, signedIn: (String) -> Seat? = Account.signedInSeat) -> Clash? {
        guard let folderSeat else { return nil }
        if let owner = FolderRules.seatOwner(folderSeat, among: accounts, except: entry.id, signedIn: signedIn) { return .other(owner.name) }
        if entry.has(folderSeat) || folderSeat.same(inUse) { return .own }
        return nil
    }
}

/// A sign-in started from a standby account's box in this run of cl_audit: the account its folder was signed in to when
/// the key was clicked (nil: none) and when. Kept in memory only; nothing is saved.
struct SignInAttempt: Equatable {
    var seat: Seat?
    var at: Date
}

/// The sign-ins started in this run of cl_audit, by standby account id. Main thread only.
enum SignInAttempts {
    private static var kept: [String: SignInAttempt] = [:]
    static func began(_ id: String, folderSeat: Seat?, now: Date = Date()) { kept[id] = SignInAttempt(seat: folderSeat, at: now) }
    static func attempt(_ id: String) -> SignInAttempt? { kept[id] }
    static func forget(_ id: String) { kept[id] = nil }
}
