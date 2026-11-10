// AddAccount: Settings ▸ a profile ▸ Claude Code ▸ Accounts ▸ Add account.
//
// A profile is one Claude Code folder, signed in to one account at a time; its other accounts are remembered on it, signed
// out (Accounts.swift). So Add account only remembers an account: one found on this Mac (signed in in some Claude Code
// folder, or used by this profile's Claude window), or an address typed in. Nothing signs in, no folder is made: the
// account signs in when the profile switches to it (SwitchRunner.swift). An account that signs in to the folder by
// itself (`claude auth login` in Terminal) is remembered anyway (FolderRules.noteAccounts).
//
// Here: the pop-up Add account opens (macOS's own menu, two lines a row: the address, then in grey what is known about
// it), and what one click on a row does. Pure and without views, so the checks can drive them; Settings.swift
// (AccountSettings) puts them on screen.

import AppKit
import SwiftUI

// MARK: the pop-up

/// One line of Add account's pop-up.
struct AddAccountRow: Equatable, Identifiable {
    enum Kind: Equatable { case caption, note, account, divider, other }
    var id: String
    var kind: Kind
    var title = ""
    var detail: String?                  // the grey second line
    var enabled = true                   // an account of another profile is listed but can't be added
}

enum AddAccountPopup {
    /// "Found on this Mac", each account as two lines, a line, then "Another address…". `found` nil: the first look is
    /// under way.
    static func rows(found: [FoundAccount]?, profile: String, now: Date = Date()) -> [AddAccountRow] {
        var out = [AddAccountRow(id: "cap", kind: .caption, title: "Found on this Mac", enabled: false)]
        if found == nil { out.append(AddAccountRow(id: "looking", kind: .note, title: "Looking…", enabled: false)) }
        else if found?.isEmpty == true { out.append(AddAccountRow(id: "none", kind: .note, title: "Nothing else found", enabled: false)) }
        for f in found ?? [] {
            out.append(AddAccountRow(id: f.id, kind: .account, title: Privacy.masked(f.email),
                                     detail: f.second(profile: profile, now: now), enabled: f.owner == nil))
        }
        out.append(AddAccountRow(id: "div", kind: .divider))
        out.append(AddAccountRow(id: "other", kind: .other, title: "Another address…"))
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
            case .account, .other:
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
    /// The pop-up's grey line: plan · organisation · where it was seen.
    /// "Ultra · Personal · signed in at ~/.claude-ultra-3", "Pro · Personal · used in Main's window in August",
    /// "Work's · one profile per account".
    func second(profile: String, now: Date = Date()) -> String {
        if let owner { return "\(AddAccountWords.possessive(owner)) · one profile per account" }
        var parts = [plan, org].compactMap { $0 }
        if let folder { parts.append("signed in at \(tilde(expand(folder)))") }
        if let used = usedInWindow {
            parts.append("used in \(profile.isEmpty ? "this profile's" : AddAccountWords.possessive(profile)) window \(Self.whenUsed(used, now: now))")
        }
        return parts.joined(separator: " · ")
    }
}

extension AccountEntry {
    /// The profile with this found account remembered as a standby account (one click in the pop-up), or nil when it
    /// can't be: it is already one of the profile's, or another profile has it. Nothing signs in; no folder is used.
    func adding(_ f: FoundAccount, among accounts: [AccountEntry], now: Date = Date(),
                signedIn: (String) -> Seat? = Account.signedInSeat) -> AccountEntry? {
        guard !has(f.seat), !f.seat.same(signedIn(configDir)),
              FolderRules.seatOwner(f.seat, among: accounts, except: id, signedIn: signedIn) == nil else { return nil }
        var out = self
        out.standby.append(StandbyAccount(email: f.email, seat: Seat(account: f.seat.account, organization: f.seat.organization, email: f.email),
                                          addedAt: now, plan: f.plan))
        return out
    }

    /// The profile with an address remembered as a standby account (Another address…), or why it can't be. Its account
    /// is known once it signs in (the switch to it). One profile per account: an address another profile has is refused.
    func remembering(_ typed: String, among accounts: [AccountEntry], now: Date = Date()) -> Result<AccountEntry, AddAccountWords.Refusal> {
        let email = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AddAccountWords.looksLikeAddress(email) else { return .failure(.notAnAddress) }
        func addresses(_ e: AccountEntry) -> [String] {
            ([e.seat?.email, Account.expectedEmail(configDir: e.configDir)] + e.standby.map { $0.email }).compactMap { $0?.lowercased() }
        }
        if addresses(self).contains(email.lowercased()) { return .failure(.already(name)) }
        if let owner = accounts.first(where: { $0.id != id && addresses($0).contains(email.lowercased()) }) { return .failure(.other(owner.name)) }
        var out = self
        out.standby.append(StandbyAccount(email: email, addedAt: now))
        return .success(out)
    }
}

/// Add account's words.
enum AddAccountWords {
    enum Refusal: Error, Equatable {
        case notAnAddress, already(String), other(String)
        var words: String {
            switch self {
            case .notAnAddress: return "Type the account's email address."
            case .already(let p): return "That's already one of \(p.isEmpty ? "this profile" : p)'s accounts."
            case .other(let p): return "That's the account of “\(p)”. One profile per account."
            }
        }
    }

    /// The line under the address field of Another address…: nothing signs in now.
    static func rememberLine(profile: String) -> String {
        let who = profile.isEmpty ? "the profile" : profile
        return "Remembered on \(who), signed out: it signs in when you switch to it."
    }

    /// "Main's", "Work's"; a name ending in s takes only the apostrophe: "Boss'".
    static func possessive(_ name: String) -> String { name.lowercased().hasSuffix("s") ? "\(name)'" : "\(name)'s" }

    /// Something@something.something, no spaces: Claude Code's own sign-in page checks the rest.
    static func looksLikeAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains(where: { $0.isWhitespace || $0.isNewline }), let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let host = t[t.index(after: at)...]
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".") && !host.contains("@")
    }
}
