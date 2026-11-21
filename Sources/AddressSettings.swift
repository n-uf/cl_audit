// The "Show emails" setting, for screen sharing and screenshots, as AddressPrivacy keeps it: one setting in the settings app's
// preferences domain (`local.usage-n-uf`, key `showEmails`, true = shown; the earlier inverted `blurEmails` is read when it
// is missing and removed at the next write), announced to every process with the distributed note
// `local.usage-n-uf.privacy-changed`. A missing setting means the addresses are hidden.
//
// The default (`settleDefault`, once, in the settings app's own start-up): an install that was already set up when this
// version first starts (its profiles file is there) keeps showing what it showed before, so `showEmails` = true is written
// once; a fresh install (no profiles file) gets `showEmails` = false written, so it stays hidden for good, also after its
// first profile is made. A key that is there (the new one or the legacy `blurEmails`) is never touched.
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
    /// The earlier, inverted key (true = hidden).
    static let legacyKey = "blurEmails"

    /// Whether this process is the settings app (the domain's own process).
    static var isSettingsApp: Bool { Bundle.main.bundleIdentifier == Installer.managerID }

    /// The change note every process reloads on. A check build (Checks/run.sh's compile, CL_AUDIT_CHECKS) names one of its own:
    /// a distributed note isn't scoped to a home, so the real one would reach the operator's running cl_audit and agent.
    static let changeNote: String = {
        #if CL_AUDIT_CHECKS
        return "local.usage-n-uf.privacy-changed.checks-\(getpid())"
        #else
        return "local.usage-n-uf.privacy-changed"
        #endif
    }()

    /// Where the setting lives. The settings app is the domain's own process, so it reads and writes its standard defaults (the
    /// same domain; an app asking for a suite named like itself is not guaranteed one); every other process reads the suite.
    /// A check build keeps it in memory: no suite reads or writes the operator's own Show emails.
    #if CL_AUDIT_CHECKS
    static let store = makeStore(prefs: CheckPrefs())
    #else
    static let store = makeStore(prefs: isSettingsApp ? UserDefaults.standard : nil)
    #endif

    /// The setting's store: `showEmails` in the `local.usage-n-uf` domain (true = shown), the older inverted `blurEmails`, the
    /// change note. `prefs`: where the booleans live, nil: that domain (a check passes a dictionary of its own).
    static func makeStore(prefs: AddressPrefs?) -> AddressDefaultsStore {
        AddressDefaultsStore(suite: Installer.managerID, key: key, valueMeansShown: true,
                             legacyKey: legacyKey, changeNote: changeNote, prefs: prefs)
    }

    #if CL_AUDIT_CHECKS
    /// A check build's setting: in memory, empty at start (hidden), never the `local.usage-n-uf` domain.
    final class CheckPrefs: AddressPrefs {
        private var d: [String: Bool] = [:]
        func addressBool(_ key: String) -> Bool? { d[key] }
        func setAddressBool(_ value: Bool, _ key: String) { d[key] = value }
        func removeAddressKey(_ key: String) { d[key] = nil }
    }
    #endif

    /// The default, settled once. Neither `showEmails` nor `blurEmails` is stored (the first start of the version that has the
    /// setting): an install that was already set up (`setUp`: its profiles file is there) keeps what it saw before, the addresses
    /// shown (`showEmails` = true), and a fresh install is written hidden (`showEmails` = false), so a profile made later never
    /// turns them on. Written through the store, so it posts the change note. A stored key, of either sense, is never changed.
    /// Returns what it wrote (true = shown), nil when it left the setting alone. Only the settings app calls it (`start`): it is
    /// the domain's own process, so no icon app or agent ever races it (the others hear the change note).
    @discardableResult
    static func settleDefault(prefs: AddressPrefs, store: AddressDefaultsStore, setUp: Bool) -> Bool? {
        guard prefs.addressBool(key) == nil, prefs.addressBool(legacyKey) == nil else { return nil }
        store.blurAddresses = !setUp
        return setUp
    }

    /// At launch, in every process that shows an address: the module reads its setting here, and reloads on each change note.
    /// The settings app first settles the default (`settleDefault`) for an install that has no setting yet.
    static func start() {
        if isSettingsApp { settleDefault(prefs: UserDefaults.standard, store: store, setUp: Store.exists) }
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

    /// The setting as `store` has it now (its key, else the older one, else hidden), taken as above: after a move's import or its
    /// Undo has written the preference directly (MoveLive.reload), whatever it left, a missing key (hidden) included.
    static func takeStored(_ from: AddressDefaultsStore = store) {
        take(shown: !from.blurAddresses)
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
        .help("Off: email addresses are left out of the launcher, dashboard, panels and Dock menus. Here in Settings and in the Switch menus each one is a blurred stand-in, the same for every account (point at it to read it), and a sentence says \"hidden address\".")
    }
}
