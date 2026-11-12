// AccountsView: one of a profile's accounts, drawn in Settings ▸ a profile ▸ Claude Code ▸ Accounts (Accounts.swift):
// a lamp, the address (a pop-up for what can be done with it), its plan and organisation, IN USE or STANDBY, and under
// them its limits as bars, the dashboard's, or one line saying why there are none.

import SwiftUI

struct AccountBox<Header: View, Content: View>: View {
    var lamp: Color?                    // lit for the account in use; nil: off
    var badge: String
    var badgeTone: DisplayWindow.Tone = .normal
    var detail: String?                 // "Ultra · Personal"
    /// Only the account in use is lit: every other one is unlit (recessed, lamp off, its levels in their own colours
    /// but dimmed).
    var unlit = false
    /// Unlit, its levels dim; off for a box whose content is a warning or a key, which keep full strength.
    var dimsContent = true
    /// Picked (to switch to): its row lights in mint across the panel, with a lit bar, a mint lamp and a lit display
    /// in the badge's place (`litBadge`: "Switch account" as a key, or "Switching to").
    var selected = false
    var litBadge: String? = nil
    var litAction: (() -> Void)? = nil
    /// A tray on the dashboard card: tighter, its head on one line (lamp, address, display) centred.
    var compact = false
    /// The account in use (Settings ▸ Accounts): sunk into a deep well like the display glass (Silver: its own display
    /// glass), a thin green-tinted inner border with a faint green glow, and a lit green bar on its left edge (`lamp` on).
    /// Standby boxes keep the plain window well.
    var inUse = false
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @Environment(\.face) private var outer
    @Environment(\.colorScheme) private var scheme

    /// The in-use green on this face (DisplayWindow's ok tone).
    private func green(_ f: FaceTheme) -> Color { f.light ? .hex(0x11743a) : FaceTheme.ledOn }

    /// The face what the box holds is printed with: a picked box is dark glass on every face, printed with the dark face
    /// as on Std; in the dark in-use well, empty bar segments are a touch lighter than the well, so they still read.
    private var boxFace: FaceTheme {
        var f = selected && outer.light ? Face.std.theme : outer
        if inUse, !selected, !f.light { f.segOff = .hex(0x1d1d20) }
        return f
    }

    var body: some View {
        let face = boxFace
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: compact ? .center : .top, spacing: 8) {
                LED(color: selected ? FaceTheme.mint : (lamp ?? .clear), lit: selected || lamp != nil).padding(.top, compact ? 0 : 5)
                VStack(alignment: .leading, spacing: 2) {
                    header()
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(face.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected, let litBadge {
                    LitDisplay(text: litBadge, action: litAction).padding(.top, compact ? 0 : 1)
                } else {
                    DisplayWindow(text: badge, tone: badgeTone, height: 18, size: 9).padding(.top, compact ? 0 : 1)
                }
            }
            content().opacity(unlit && dimsContent ? 0.6 : 1)
        }
        .environment(\.face, face)
        .environment(\.colorScheme, selected && outer.light ? .dark : scheme)    // the bars' own labels follow it
        .padding(.horizontal, compact ? 10 : 11).padding(.top, compact ? 7 : 9).padding(.bottom, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hex(0x141518))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FaceTheme.mint.opacity(0.22), lineWidth: 1))
            } else if inUse {
                let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
                let g = green(face)
                WellShape(well: face.light ? face.display : InUseLook.well, radius: 8)
                    .overlay { shape.fill(Color.clear.shadow(.inner(color: g.opacity(face.light ? 0.10 : 0.09), radius: 12))) }
                    .overlay { shape.strokeBorder(face.light ? g.opacity(0.32) : .hex(0x24372a), lineWidth: 1) }
                    .overlay(alignment: .leading) {
                        if lamp != nil {
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(g)
                                .frame(width: 3).padding(.vertical, 10).offset(x: -1)
                                .shadow(color: g.opacity(face.light ? 0.35 : 0.6), radius: 4)
                        }
                    }
            } else {
                WellShape(well: face.win, radius: 8)
                    .overlay { if unlit { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(face.light ? 0.06 : 0.24)) } }
            }
        }
        .mintRow(selected)
    }
}

/// The account in use's well on the dark faces (AccountBox `inUse`): near-black, a step off the display glass's teal.
enum InUseLook {
    static let well = Well(stops: Finish.stops((0x111214, 0), (0x0e0f11, 1)), inner: .black(0.7), innerRadius: 1.5, innerY: 1,
                           lip: .white(0.05))
}

/// A line of text inside an account box. It reads the face from the environment inside the box, not from the caller: a
/// selected row is dark glass whatever the face, and AccountBox gives what is inside it the dark faces' print then.
struct BoxNote: View {
    enum Tone { case muted, caution, danger }
    let text: String
    var size: CGFloat = 11.5
    var tone: Tone = .muted
    @Environment(\.face) private var face

    var body: some View {
        Text(text).font(.system(size: size)).foregroundStyle(tone == .danger ? face.danger : tone == .caution ? face.caution : face.muted)
    }
}

/// Settings ▸ Accounts' one line about a switch of the profile (SwitchPage.settingsStrip): while it runs, or when it was
/// refused before anything, in the Switch page's strip words. Nothing otherwise; the account rows stay as they are.
struct SwitchStripLine: View {
    @ObservedObject var runner: SwitchRunner

    var body: some View {
        if let s = SwitchPage.settingsStrip(runner.phase, again: runner.goal?.again == true, canUndo: runner.canUndo,
                                            failedAt: runner.failedStep, started: runner.goal?.started) {
            DisplayWindow(text: s.text, dim: s.dim, tone: s.tone, height: 22, size: 10)
        }
    }
}

/// The address at the top of an account box, as a pop-up: the address, then ⌃⌄. Shortened at the end ("…") rather
/// than widening the card.
struct AccountBoxTitle: View {
    let text: String
    var tint: Color? = nil
    var icon: String? = nil
    @Environment(\.face) private var face

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint ?? face.text) }
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint ?? face.text)
                .lineLimit(1).truncationMode(.tail)
                .settingsEmail(text.contains("@"))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(face.muted)
        }
        .contentShape(Rectangle())
    }
}

/// What Claude Code recorded about a folder's account (AccountFacts), read again only when its .claude.json changed:
/// the account boxes are drawn every few seconds. Main thread only.
enum FolderFactsCache {
    private static var kept: [String: (stamp: Date?, facts: AccountFacts?)] = [:]

    static func facts(_ configDir: String) -> AccountFacts? { read(configDir).facts }

    /// When the folder's .claude.json last changed (nil: there is none).
    static func stamp(_ configDir: String) -> Date? { read(configDir).stamp }

    /// Both, from one look at the file's date.
    static func read(_ configDir: String) -> (stamp: Date?, facts: AccountFacts?) {
        let path = Account.claudeJSON(configDir: configDir)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let k = kept[path], k.stamp == stamp { return (k.stamp, k.facts) }
        let f = AccountFacts.of(claudeJSON: path)
        kept[path] = (stamp, f)
        return (stamp, f)
    }
}
