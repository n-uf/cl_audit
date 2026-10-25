// "What this does now": after a change to a setting that has no picture of its own, a short plain-language
// note says what the new value does. It floats over the bottom of the settings page, so nothing moves.

import SwiftUI

struct SettingNote: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let text: String
}

enum SettingNotes {
    /// The note for the first setting that differs between two versions of one profile, or nil when the
    /// change is visual (icon, colours, panel design, open dot, Opening and closing) or typing (name, label).
    static func note(from a: AccountEntry, to b: AccountEntry) -> SettingNote? {
        guard a.id == b.id else { return nil }
        let p = b.name.trimmingCharacters(in: .whitespaces).isEmpty ? "this profile" : b.name
        if a.autoRenew != b.autoRenew {
            return SettingNote(title: "Renew if expired · \(b.autoRenew ? "on" : "off")", text: b.autoRenew
                ? "When \(p)'s Claude Code login expires, cl_audit renews it with one tiny Claude Code request (it uses a little usage)."
                : "An expired login stays expired until you sign in again; the card shows Sign in…")
        }
        if a.desktop != b.desktop {
            switch b.desktop {
            case .standard:
                return SettingNote(title: "Claude window · Standard", text: "Opens the standard Claude app with whatever account it is signed in to. Only one profile can use it.")
            case .separate:
                return SettingNote(title: "Claude window · Separate", text: "Opens \(p)'s own Claude app, with its own sign-in and data folder, side by side with the others.")
            case .none:
                return SettingNote(title: "Claude window · None", text: "No Claude window: \(p) is Claude Code in Terminal only. A click shows its usage.")
            }
        }
        if a.desktopDataDir != b.desktopDataDir, b.desktop == .separate {
            return SettingNote(title: "Data folder · \((b.desktopDataDir as NSString).lastPathComponent)",
                               text: "\(p)'s own Claude window keeps its sign-in and data in this folder.")
        }
        if a.configDir != b.configDir {
            return SettingNote(title: "Folder · \(b.configDir)", text: "\(p) now reads its sign-in and usage from this Claude Code folder.")
        }
        if a.pollMinutes != b.pollMinutes {
            return SettingNote(title: "Refresh every · \(b.pollMinutes) min",
                               text: "Asks Anthropic for \(p)'s usage every \(b.pollMinutes) min. It doesn't use any of your limits.")
        }
        if a.notify != b.notify || a.notifyPercent != b.notifyPercent {
            return SettingNote(title: "Notify at · \(b.notify ? "\(b.notifyPercent)%" : "off")", text: b.notify
                ? "A macOS notification when \(p)'s 5-hour or weekly limit reaches \(b.notifyPercent)%."
                : "No usage notifications for \(p).")
        }
        if a.clickAction != b.clickAction {
            let text: String
            switch b.clickAction {
            case .peekThenOpen: text = "A click on the Dock icon shows \(p)'s usage for a moment while its Claude window opens."
            case .open: text = "A click on the Dock icon brings \(p)'s Claude window forward right away."
            case .details: text = "A click on the Dock icon shows the details panel; open Claude from there."
            }
            return SettingNote(title: "Click · \(b.clickAction.shortTitle)", text: text)
        }
        if a.peekSeconds != b.peekSeconds {
            let t = PeekDuration.text(b.peekSeconds)
            return SettingNote(title: "Show usage for · \(t)", text: "After a click the usage stays up for \(t), then the Claude window comes forward.")
        }
        if a.longPressDetails != b.longPressDetails {
            return SettingNote(title: "Press and hold · \(b.longPressDetails ? "on" : "off")", text: b.longPressDetails
                ? "Press and hold the Dock icon for the details panel next to a short menu."
                : "Press and hold shows only the Dock menu.")
        }
        if a.iconHidden != b.iconHidden {
            return SettingNote(title: "Show in the Dock · \(b.iconHidden ? "off" : "on")", text: b.iconHidden
                ? "The Dock icon keeps running without a tile, so it still refreshes and alerts. The Dock restarts to take its pin out."
                : "The Dock icon gets its tile back. The Dock restarts to put the pin where it was.")
        }
        if a.openAtLogin != b.openAtLogin {
            return SettingNote(title: "Open at login · \(b.openAtLogin ? "on" : "off")", text: b.openAtLogin
                ? "\(p)'s Dock icon starts when you log in to your Mac."
                : "\(p)'s Dock icon starts only when you start it, or with its Claude window.")
        }
        return nil
    }

    static func emails(_ on: Bool) -> SettingNote {
        SettingNote(title: "Show emails · \(on ? "on" : "off")", text: on
            ? "Email addresses show everywhere in cl_audit."
            : "Email addresses are left out of the launcher, dashboard, panels and Dock menus, and blurred in Settings, for screen sharing.")
    }
}

/// The note, floating at the bottom of the settings page. It closes after 6 s (not while the pointer is on
/// it), with ×, or when the next note replaces it.
struct SettingNoteBanner: View {
    let note: SettingNote
    let hover: (Bool) -> Void
    let close: () -> Void
    @Environment(\.face) private var outer

    /// A small raised plate over the page: the title in a display window, the explanation, a close key.
    /// It stays dark on the light Silver face too, like the app's other floating parts.
    var body: some View {
        let face: FaceTheme = outer.light ? Face.std.theme : outer
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                DisplayWindow(text: note.title)
                Text(note.text).font(.system(size: 12)).foregroundStyle(face.soft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).frame(width: 6) }
                .buttonStyle(PillButtonStyle(compact: true)).help("Close")
        }
        .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 10)
        .frame(maxWidth: 520)
        .background(RaisedShape(finish: Finish(stops: Finish.stops((0x343437, 0), (0x29292b, 1)), grain: face.module.grain,
                                               hi: .white(0.1), lo: .black(0.4), ring: .black, shadow: .black(0.6), shadowRadius: 18, shadowY: 10),
                                radius: face.moduleRadius == 10 ? 8 : 4))
        .environment(\.face, face)
        .environment(\.colorScheme, .dark)
        .onHover(perform: hover)
        .accessibilityElement(children: .combine)
    }
}
