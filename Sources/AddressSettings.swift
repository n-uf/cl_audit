// The "Show emails" setting, for screen sharing and screenshots, as AddressPrivacy keeps it: one setting in the settings app's
// preferences domain (`local.usage-n-uf`, key `showEmails`, true = shown; the earlier inverted `blurEmails` is read when it
// is missing and removed at the next write), announced to every process with the distributed note
// `local.usage-n-uf.privacy-changed`. A missing setting means the addresses are hidden.
//
// With it off, no address is shown anywhere in clear: not its first letter, its length or its domain. A view draws one fixed
// blurred stand-in (the address itself only while the pointer is on it), a sentence says "hidden address", and the
// launcher, dashboard, Dock panels and Dock menus leave an address out (`hidesEmail`).
//
// Every process that shows an address calls `AddressSettings.start()` at launch (Sources/main.swift: the settings app, the
// icon apps and the agent all start there); the Dock tile plug-in shows none and has no observable object: if it ever
// does, it reads `AddressSettings.store.blurAddresses` on each draw.

import AddressPrivacy
import AppKit
import SwiftUI

enum AddressSettings {
    /// The preferences key (true = addresses shown); a move's settings carry it too (SessionsMove).
    static let key = "showEmails"

    /// Where the setting lives. The settings app is the domain's own process, so it reads and writes its standard defaults (the
    /// same domain; an app asking for a suite named like itself is not guaranteed one); every other process reads the suite.
    static let store = makeStore(prefs: Bundle.main.bundleIdentifier == Installer.managerID ? UserDefaults.standard : nil)

    /// The setting's store: `showEmails` in the `local.usage-n-uf` domain (true = shown), the older inverted `blurEmails`, the
    /// change note. `prefs`: where the booleans live, nil: that domain (a check passes a dictionary of its own).
    static func makeStore(prefs: AddressPrefs?) -> AddressDefaultsStore {
        AddressDefaultsStore(suite: Installer.managerID, key: key, valueMeansShown: true,
                             legacyKey: "blurEmails", changeNote: "local.usage-n-uf.privacy-changed", prefs: prefs)
    }

    /// At launch, in every process that shows an address: the module reads its setting here, and reloads on each change note.
    static func start() {
        AddressPrivacy.shared.store = store
        store.observe()
    }

    /// Whether a piece of text is something to hide: an address, an account id (AddressText.needsHiding), or the label of an
    /// account whose address isn't known, "account 1a2b3c4d" (an id prefix: it names the account as an address does).
    static func hides(_ text: String) -> Bool {
        if AddressText.needsHiding(text) { return true }
        let tag = "account "
        return text.hasPrefix(tag) && AddressText.isAccountID(String(text.dropFirst(tag.count)))
    }

    /// A piece of text that may hold an address, as running text (a sentence, a line, a tooltip, a pop-up row, an alert's
    /// words): "hidden address" in its place while addresses are hidden, whatever the address, and the text as it is when it
    /// is no address or id (a phrase like "another account"). `blur`: a test override of the setting (nil: the app's).
    static func words(_ text: String, blur: Bool? = nil) -> String {
        hides(text) ? AddressText.sentence(address: text, blur: blur ?? AddressPrivacy.shared.blur) : text
    }

    /// A move's import brought the other Mac's value (true = shown): taken through the store, which writes it and tells the
    /// other processes. Nothing happens when it is what this Mac has already.
    static func take(shown: Bool) {
        if AddressPrivacy.shared.blur == shown { AddressPrivacy.shared.setBlur(!shown) }
    }
}

/// A value in a view that is the REAL address of an account (or an account id) when AddressSettings.hides says so, and plain
/// text otherwise ("Choose an account", "signed in"). An address is drawn through AddressPrivacy: one fixed blurred stand-in
/// while emails are hidden (as wide as itself whatever the address: `reserve`, false only inline in flowing text), the
/// address only while the pointer is on it or Show emails is on, and read as "hidden address". The font, weight, colour and
/// line limit are the caller's; `size` is the font size, for the blur's radius.
struct AccountValue: View {
    let text: String
    var size: CGFloat = 12.5
    var reserve = true
    var blur: Bool? = nil

    var body: some View {
        if AddressSettings.hides(text) { BlurredAddress(address: text, size: size, reserve: reserve, blur: blur) } else { Text(text) }
    }
}

/// Outside Settings: leaves an email address out while emails are hidden.
struct HiddenEmail: ViewModifier {
    @ObservedObject private var privacy = AddressPrivacy.shared
    let isEmail: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isEmail && privacy.blur { EmptyView() } else { content }
    }
}

extension View {
    /// Left out entirely while emails are hidden (`isEmail`: the text holds an address or an account id,
    /// AddressText.needsHiding).
    func hidesEmail(_ isEmail: Bool = true) -> some View { modifier(HiddenEmail(isEmail: isEmail)) }
}

/// "Show emails" in the Settings page's top bar.
struct ShowEmailsSwitch: View {
    @ObservedObject private var privacy = AddressPrivacy.shared

    var body: some View {
        HStack(spacing: 6) {
            Text("Show emails").font(.system(size: 12)).foregroundStyle(.secondary)
            SSwitch(isOn: Binding(get: { !privacy.blur }, set: { privacy.setBlur(!$0) }), on: "", off: "")   // its label is before it
        }
        .help("Off: email addresses are left out of the launcher, dashboard, panels and Dock menus, and blurred here in Settings (hover to see one).")
    }
}
