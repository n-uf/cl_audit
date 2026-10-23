// The "Show emails" setting, for screen sharing and screenshots. With it off, email addresses are left
// out of the launcher, dashboard, panels and Dock menus; Settings keeps them, blurred until hovered.
// Shared by the settings app and every icon app: stored in the settings app's preferences and
// announced with a note.

import AppKit
import SwiftUI

final class Privacy: ObservableObject {
    static let shared = Privacy()
    static let key = "showEmails"
    static let changedNote = Notification.Name("local.usage-n-uf.privacy-changed")

    private static var defaults: UserDefaults {
        Bundle.main.bundleIdentifier == Installer.managerID ? .standard
            : UserDefaults(suiteName: Installer.managerID) ?? .standard
    }

    private static func read() -> Bool {
        let d = defaults
        if d.object(forKey: key) != nil { return d.bool(forKey: key) }
        return !d.bool(forKey: "blurEmails")          // the earlier "blur" switch
    }

    @Published private(set) var show = Privacy.read()

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.changedNote, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func set(show on: Bool) {
        show = on
        Self.defaults.set(on, forKey: Self.key)
        Self.defaults.removeObject(forKey: "blurEmails")
        DistributedNotificationCenter.default().postNotificationName(Self.changedNote, object: nil, deliverImmediately: true)
    }

    func reload() {
        let on = Self.read()
        if on != show { show = on }
    }

    /// Settings text that can't blur (menus, sentences): masked while emails are hidden.
    static func masked(_ email: String) -> String { shared.show ? email : mask(email) }

    /// you@example.com → y••••••@example.com
    static func mask(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = email[..<at]
        return String(local.prefix(1)) + String(repeating: "•", count: max(3, min(local.count - 1, 7))) + email[at...]
    }
}

/// Outside Settings: leaves an email address out while emails are hidden.
struct HiddenEmail: ViewModifier {
    @ObservedObject private var privacy = Privacy.shared
    let isEmail: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isEmail && !privacy.show { EmptyView() } else { content }
    }
}

/// In Settings: blurs an email address while emails are hidden; hovering shows it.
struct SettingsEmail: ViewModifier {
    @ObservedObject private var privacy = Privacy.shared
    let isEmail: Bool
    @State private var peek = false

    func body(content: Content) -> some View {
        content
            .blur(radius: isEmail && !privacy.show && !peek ? 3.5 : 0)
            .onHover { peek = $0 }
            .animation(.easeOut(duration: 0.15), value: peek)
    }
}

extension View {
    func hidesEmail(_ isEmail: Bool = true) -> some View { modifier(HiddenEmail(isEmail: isEmail)) }
    func settingsEmail(_ isEmail: Bool = true) -> some View { modifier(SettingsEmail(isEmail: isEmail)) }
}

/// "Show emails" in the Settings page's top bar.
struct ShowEmailsSwitch: View {
    @ObservedObject private var privacy = Privacy.shared

    var body: some View {
        HStack(spacing: 6) {
            Text("Show emails").font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("", isOn: Binding(get: { privacy.show }, set: { privacy.set(show: $0) })).smallSwitch()
        }
        .help("Off: email addresses are left out of the launcher, dashboard, panels and Dock menus, and blurred here in Settings (hover to see one).")
    }
}
