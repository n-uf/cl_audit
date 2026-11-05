// AccountsView: one of a profile's accounts, drawn in Settings ▸ a profile ▸ Claude Code ▸ Accounts (Accounts.swift):
// a lamp, the address (a pop-up for what can be done with it), its plan and organisation, IN USE or STANDBY, and under
// them its limits as bars, the dashboard's, or one line saying why there are none.

import SwiftUI

struct AccountBox<Header: View, Content: View>: View {
    var lamp: Color?                    // lit for the account in use; nil: off
    var badge: String
    var badgeTone: DisplayWindow.Tone = .normal
    var detail: String?                 // "Ultra · Personal"
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Content
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                LED(color: lamp ?? .clear, lit: lamp != nil).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    header()
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(face.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DisplayWindow(text: badge, tone: badgeTone, height: 18, size: 9).padding(.top, 1)
            }
            content()
        }
        .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WellShape(well: face.win, radius: 8))
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

/// What Add account found, kept for half a minute per profile: finding reads a few small files and the window's folder
/// list, and the card is drawn again every few seconds.
enum FoundAccountsCache {
    private static var kept: [String: (at: Date, list: [FoundAccount])] = [:]

    static func list(for e: AccountEntry, among accounts: [AccountEntry], now: Date = Date()) -> [FoundAccount] {
        let key = e.id + "|" + e.standby.map(\.id).joined(separator: ",") + "|" + accounts.map(\.id).joined(separator: ",")
        if let k = kept[key], now.timeIntervalSince(k.at) < 30 { return k.list }
        let list = AccountDiscovery.found(for: e, among: accounts)
        kept[key] = (now, list)
        return list
    }

    static func forget() { kept = [:] }
}
