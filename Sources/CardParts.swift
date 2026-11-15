import AppKit
import ProfileCore
import SwiftUI

// The dashboard card's parts (the approved UI-fixes sketch, 2026-11-15): what it says in place of its numbers, the plan
// badge with the last refresh, and the two face keys (Sign in…, Switch account).

/// What the card says in place of its numbers. The account in use is the Claude app's (a usage-only profile: the one its
/// record names); the card shows numbers only while Claude Code in Terminal on the profile's folder is signed in to that
/// account. Every other state: a one-line heading about Terminal's sign-in, then one sentence saying what to do. Red: the
/// sign-in is on the wrong account or gone. Amber: it's fine but can't be read yet, or a switch waits for the Claude app.
struct UsageNotice: Equatable {
    enum Tone { case red, amber }
    enum Key { case signIn, refresh, none }
    let tone: Tone
    let heading: String
    let line: String
    let key: Key
    /// Signed out or expired: no sign-in to show the window or Terminal on, so both wait in ⋯.
    var signedOut = false

    /// The notice for the card's profile, from its one value (ProfileShow): the split, the sign-in on another account than
    /// the folder's, another profile's account, expired, signed out, or not readable while there are no numbers. The key is
    /// the value's (Sign in… whenever it has one), to the value's address (ProfileShow.loginAddress).
    static func of(_ row: AccountRow) -> UsageNotice? {
        let show = row.show, d = show.display
        let name = row.entry.name.isEmpty ? "this profile" : row.entry.name
        func signIn(_ address: String?) -> String {
            guard let a = address, a.contains("@") else { return "Sign in to read \(name)'s usage." }
            return "Sign in as \(Privacy.masked(a)) to read \(name)'s usage."
        }
        let address = show.loginAddress
        let key: Key = d.key != nil ? .signIn : .none
        if d.split != nil, let split = show.splitWords {
            if split.switched {
                let to = Privacy.masked(split.code)
                return UsageNotice(tone: .amber, heading: SplitUsage.switchingHead(split.code),
                                  line: "Sign the Claude app in to \(to) to finish.", key: key)
            }
            // (no key when the app's account is known by its id only: the key only fills in the app's own address)
            return UsageNotice(tone: .red, heading: "Terminal is signed in to \(Privacy.masked(split.code))",
                              line: d.key == nil ? split.hint.map { $0 + "." } ?? signIn(nil) : signIn(address), key: key)
        }
        if d.otherAccount {
            return UsageNotice(tone: .red, heading: "Terminal is signed in to another account", line: signIn(address), key: key)
        }
        if let other = d.clash {
            return UsageNotice(tone: .red, heading: "Terminal is signed in to \(other.name)'s account", line: signIn(address), key: key)
        }
        switch d.sign {
        case .expired:
            return UsageNotice(tone: .red, heading: "Terminal's sign-in has expired", line: signIn(address), key: key, signedOut: true)
        case .signedOut:
            return UsageNotice(tone: .red, heading: "Terminal is signed out", line: signIn(address), key: key, signedOut: true)
        // the sign-in fine but not readable now: the last numbers stay while there are any; the notice only without them
        case .unreadable where d.usage == nil:
            if row.status?.state == "denied" {
                return UsageNotice(tone: .amber, heading: "Can't read Terminal's sign-in yet",
                                  // `security` refused or timed out (Login.read): no prompt is shown, a locked Keychain is the usual cause
                                  line: "The Keychain didn't hand it over: unlock it, then Refresh now.", key: .refresh)
            }
            return UsageNotice(tone: .amber, heading: "Can't read Terminal's sign-in",
                              line: "Claude Code saved it in a form cl_audit doesn't know.", key: .refresh)
        default:
            return nil
        }
    }
}

/// The notice in the limits' place: the heading (one line) over the sentence, tinted by its tone.
struct UsageNoticeView: View {
    let notice: UsageNotice
    @Environment(\.face) private var face

    var body: some View {
        let strong: Color = notice.tone == .red ? face.danger : (face.light ? .hex(0xa85f00) : .hex(0xffb24a))
        VStack(alignment: .leading, spacing: 3) {
            Text(notice.heading).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(strong)
                .lineLimit(1).truncationMode(.middle)
            Text(notice.line).font(.system(size: 12)).foregroundStyle(strong.opacity(face.light ? 0.85 : 0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The last refresh in words for the plan badge: AccountBook's short forms, capped at 8 weeks ("long ago"), "reading…"
/// before the first reading. Shortest "1 h ago", longest "13 days ago" / "8 weeks ago".
enum CardAgo {
    static func words(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "reading…" }
        return now.timeIntervalSince(d) >= 9 * 7 * 86400 ? "long ago" : AccountBook.ago(d, now: now)
    }
}

/// The plan badge: the plan over the last refresh, one fixed size on every card (the longest plan, Enterprise, over the
/// longest time), so it never moves as the minutes tick. Red while a limit is full or the sign-in is wrong or gone, amber
/// while it can't be read yet or a switch waits.
struct PlanBadge: View {
    let plan: String?
    let updated: Date?
    var tone: DisplayWindow.Tone = .normal
    @Environment(\.face) private var face

    static let width: CGFloat = 92
    static let height: CGFloat = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let c = color
            VStack(spacing: 1) {
                Text(plan.map(Account.planWords) ?? "–").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4).foregroundStyle(c)
                    .shadow(color: face.displayGlow ? c.opacity(0.75) : .clear, radius: 1.5)
                Text(CardAgo.words(updated, now: ctx.date)).font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(0.8).foregroundStyle(c.opacity(0.55))
            }
            .textCase(.uppercase).lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(width: Self.width, height: Self.height)
            .background(DisplayGlass(radius: 4))
            .clipped()
        }
    }

    private var color: Color {
        switch tone {
        case .warn: return face.light ? .hex(0xb42318) : .hex(0xff8a7a)
        case .amber: return face.light ? .hex(0xa85f00) : .hex(0xffb24a)
        default: return face.displayText
        }
    }
}

/// A face key in the cl-quick Download key's build: a coloured gradient with fine pinstripes, a light top edge, a dark rim,
/// dark printing. Red: Sign in… (the sign-in is wrong or gone). Orange: Switch account (a limit is full).
struct FaceKeyStyle: ButtonStyle {
    enum Tint { case red, orange }
    var tint: Tint
    var width: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        FaceKeyLabel(tint: tint, width: width, pressed: configuration.isPressed) { configuration.label }
    }
}

/// The face key's look, also used as a menu's label (Switch account opens a menu).
struct FaceKeyLabel<L: View>: View {
    let tint: FaceKeyStyle.Tint
    var width: CGFloat? = nil
    var pressed = false
    @ViewBuilder let label: () -> L
    @State private var hover = false

    var body: some View {
        let (top, bottom, rim, ink): (UInt32, UInt32, UInt32, UInt32) = tint == .red
            ? (0xf4907f, 0xdc5a4b, 0x5e170d, 0x1f0705) : (0xf4a075, 0xe47b4c, 0x5e240d, 0x1d0b04)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        // under the full box (`width`): tighter print, and at least the box's width, never narrower than its label
        label()
            .font(.system(size: width == nil ? 11 : 10.5, weight: .semibold)).tracking(width == nil ? 1.1 : 0.6).textCase(.uppercase)
            .foregroundStyle(Color.hex(ink))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, width == nil ? 12 : 8)
            .frame(minWidth: width, minHeight: 26, maxHeight: 26)
            .background(
                shape.fill(LinearGradient(colors: [.hex(top), .hex(bottom)], startPoint: .top, endPoint: .bottom))
                    .overlay(Pinstripes().clipShape(shape))
                    .overlay(shape.inset(by: 0.5).stroke(Color.white.opacity(0.35), lineWidth: 1).mask(
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
                    .overlay(shape.stroke(Color.hex(rim), lineWidth: 1))
                    .shadow(color: .black.opacity(0.45), radius: 3.5, y: 2)
                    .shadow(color: tint == .orange && hover ? Color.hex(0xff7a3d).opacity(0.6) : .clear, radius: 8)
            )
            .brightness(pressed ? -0.06 : (hover ? 0.02 : 0))
            .contentShape(shape)
            .onHover { hover = $0 }
    }
}

/// Fine vertical lines over a face key, as on cl-quick's keys.
private struct Pinstripes: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.12)))
                ctx.fill(Path(CGRect(x: x + 1, y: 0, width: 1, height: size.height)), with: .color(.black.opacity(0.05)))
                x += 2
            }
        }
        .allowsHitTesting(false)
    }
}
