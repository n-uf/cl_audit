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
            return SettingNote(title: "Renew sign-in · \(b.autoRenew ? "on" : "off")", text: b.autoRenew
                ? "When \(p)'s access key runs out, cl_audit runs Claude Code once with a tiny prompt so it fetches a fresh one (a sliver of usage)."
                : "When \(p)'s access key runs out, the usage waits until you next use Claude Code.")
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
            return SettingNote(title: "Usage shows for · \(t)", text: "After a click the usage stays up for \(t), then the Claude window comes forward.")
        }
        if a.longPressDetails != b.longPressDetails {
            return SettingNote(title: "Press and hold · \(b.longPressDetails ? "on" : "off")", text: b.longPressDetails
                ? "Press and hold the Dock icon for the details panel next to a short menu."
                : "Press and hold shows only the Dock menu.")
        }
        if a.iconHidden != b.iconHidden {
            return SettingNote(title: "Usage in the Dock · \(b.iconHidden ? "off" : "on")", text: b.iconHidden
                ? "No Dock icon for \(p). Its usage still shows on the dashboard, in the launcher and in alerts: cl_audit reads it for every profile. The Dock restarts once to take the icon out."
                : "A Dock icon shows \(p)'s usage again, back where it was. The Dock restarts once to put it in.")
        }
        if a.claudeWindow != b.claudeWindow {
            return SettingNote(title: "Claude window · \(b.claudeWindow ? "on" : "off")", text: b.claudeWindow
                ? "\(p) has a Claude window again, signed in to its account; open it from the dashboard or the Dock icon."
                : "No Claude window for \(p): nothing opens one. Its sign-in is kept, so turning it back on needs no new sign-in.")
        }
        if a.dockRuns != b.dockRuns {
            let text: String
            switch b.dockRuns {
            case .atLogin: text = "\(p)'s Dock icon starts when you log in to your Mac and stays until you quit it."
            case .withWindow: text = b.claudeWindow ? "\(p)'s Dock icon starts when its Claude window opens and quits 10 s after the window quits."
                                                    : "\(p) has no Claude window, so its Dock icon runs only when you start it."
            case .whenStarted: text = "\(p)'s Dock icon runs only when you start it. Its usage is read either way."
            }
            return SettingNote(title: "Dock icon runs · \(b.dockRuns.title)", text: text)
        }
        if a.windowFollowsDock != b.windowFollowsDock {
            return SettingNote(title: "Claude window · \(b.windowFollowsDock ? "with the Dock icon" : "on its own")", text: b.windowFollowsDock
                ? "Starting \(p)'s Dock icon opens its Claude window, and quitting it quits the window (not at login; Claude can ask about unsent work)."
                : "\(p)'s Claude window opens and quits only when you open or quit it.")
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
