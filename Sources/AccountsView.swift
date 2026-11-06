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
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @Environment(\.face) private var face

    var body: some View {
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
        // a selected row is always dark glass (below): on the light face its print is the dark faces' too
        .environment(\.face, selected && face.light ? Face.std.theme : face)
        .padding(.horizontal, compact ? 10 : 11).padding(.top, compact ? 7 : 9).padding(.bottom, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.hex(0x141518))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FaceTheme.mint.opacity(0.22), lineWidth: 1))
            } else {
                WellShape(well: face.win, radius: 8)
                    .overlay { if unlit { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(face.light ? 0.06 : 0.24)) } }
            }
        }
        .mintRow(selected)
    }
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

/// Add account's key: "ADD ACCOUNT ▾", a menu.
struct AddAccountKey: View {
    var body: some View {
        KeyLook(height: 26, radius: 4, hPad: 11) {
            HStack(spacing: 5) {
                Text("Add account")
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
            }
        }
    }
}

/// What Add account found, per profile, looked for off the main thread (it reads a few small files and the window's
/// folder list) and again once a minute; the card, drawn every few seconds, shows the last result. Main thread only.
enum FoundAccountsCache {
    private static var kept: [String: (at: Date, list: [FoundAccount])] = [:]
    private static var looking: Set<String> = []

    /// The last list for this profile, nil while the first look is under way.
    static func list(for e: AccountEntry, among accounts: [AccountEntry], now: Date = Date()) -> [FoundAccount]? {
        let key = e.id + "|" + e.standby.map(\.id).joined(separator: ",") + "|" + accounts.map(\.id).joined(separator: ",")
        let k = kept[key]
        if (k == nil || now.timeIntervalSince(k!.at) >= 60), !looking.contains(key) {
            looking.insert(key)
            DispatchQueue.global(qos: .utility).async {
                let list = AccountDiscovery.found(for: e, among: accounts)
                DispatchQueue.main.async { kept[key] = (Date(), list); looking.remove(key) }
            }
        }
        return k?.list
    }

    static func forget() { kept = [:] }
}

/// What Claude Code recorded about a folder's account (AccountFacts), read again only when its .claude.json changed:
/// the account boxes are drawn every few seconds. Main thread only.
enum FolderFactsCache {
    private static var kept: [String: (stamp: Date?, facts: AccountFacts?)] = [:]

    static func facts(_ configDir: String) -> AccountFacts? {
        let path = Account.claudeJSON(configDir: configDir)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let k = kept[path], k.stamp == stamp { return k.facts }
        let f = AccountFacts.of(claudeJSON: path)
        kept[path] = (stamp, f)
        return f
    }
}
