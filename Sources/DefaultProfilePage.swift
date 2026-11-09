// DefaultProfilePage: the page of "Make the default profile the one Claude opens directly" (DefaultProfile.swift,
// DefaultProfileRunner.swift), and the card that offers it. A sibling of the Switch and Restore pages with the same
// blocks: the line at the top says how far it got, every card stays while it runs, and each step shows like a switch's.
//
//   Offer      nothing is changed yet · Why, What moves, What each setting becomes, Steps; Make the default profile, Not now
//   Running    step 2 of 4 · the sign-in, the windows closing, the backup, the restore (its numbers, and its page)
//   Done       moved · nothing overwritten · what the old profile becomes (a standby account, or removed) · Undo this move
//
// The card: on Settings ▸ General (the first card, until "Not now"; then one quiet line there) and a line under the profile's
// Claude window switch (Settings ▸ the profile ▸ Claude window).

import AppKit
import SwiftUI

struct DefaultProfileCard: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.face) private var face

    var body: some View {
        // a move that stopped part way comes first: its files are written, and only its restore can finish or undo them
        if let r = DefaultProfile.unfinished() {
            unfinished(r)
        }
    }

    private func offer(_ s: DefaultProfile.Situation) -> some View {
        SCard(title: DefaultProfile.title, info: "One time, and never automatic. It moves \(s.old.name)'s sessions to the usual Claude app, with a backup first and nothing overwritten, and has an Undo. \"Not now\" hides this card; it stays in Settings ▸ General (and on the profile's Claude window card).") {
            VStack(alignment: .leading, spacing: 8) {
                Text(DefaultProfile.why(s)).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Make the default profile…") { model.showDefaultProfile() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
                    Button("Not now") { DefaultProfile.dismissed = true; model.objectWillChange.send() }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func quiet(_ s: DefaultProfile.Situation) -> some View {
        SCard(title: "Default profile", info: "The profile on ~/.claude with the usual Claude app is what Claude shows when opened directly. \(s.old.name) uses its own window.") {
            SRow(label: "Opens directly", first: true) {
                HStack(spacing: 8) {
                    Text("Another window than \(s.old.name)'s").font(.system(size: 12)).foregroundStyle(face.muted).lineLimit(1)
                    Button("Make the default profile…") { model.showDefaultProfile() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                }
            }
        }
    }

    private func unfinished(_ r: DefaultProfile.Record) -> some View {
        let rc = DefaultProfile.restoreFor(r).flatMap { $0.undone == nil ? SessionsRestore.load($0.id) : nil }
        return SCard(title: "The move to the default profile stopped", info: "cl_audit stopped part way through the move. Its restore keeps a receipt of every file it wrote, so it can be finished or undone exactly; the profile's window kind goes back only with an Undo.") {
    /// A move that changed the profile and wasn't finished or undone. With files written, only that restore's page can finish
    /// or undo them (never "Put it back": the window kind stays with the files).
            VStack(alignment: .leading, spacing: 8) {
                if let rc {
                    Text("\(rc.back) \(rc.back == 1 ? "file is" : "files are") already in the usual app's data. Open the restore to finish the move or undo it.")
                        .font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                    Button("Open the restore") { model.showRestore(finishing: rc) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
                } else {
                    Text("Nothing was moved. Put the profile back as it was, then start again if you like.")
                        .font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                    Button("Put it back") { model.defaultMoveUndone(r.id) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct DefaultProfilePage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: DefaultProfileRunner
    var width: CGFloat = 980
    var counts: DefaultProfile.Preview? = nil           // renders only
    @State private var preview: DefaultProfile.Preview?
    @Environment(\.face) private var face

    private var s: DefaultProfile.Situation { runner.situation }
    private var name: String { s.old.name.isEmpty ? "the profile" : s.old.name }
    private var kind: DefaultProfile.Kind { s.kind }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            topBar
            SettingsColumns(width: width, groups: [[AnyView(whyCard), AnyView(movesCard), AnyView(settingsCard)],
                                                  [AnyView(stepsCard), AnyView(resultCard)]])
        }
        .task { if counts == nil { await loadPreview() } }
    }

    private var title: String {
        switch runner.phase {
        case .done: return "\(runner.target?.name ?? name) is the default profile"
        case .undone: return "Undid the move to the default profile"
        default: return DefaultProfile.title
        }
    }

    private func loadPreview() async {
        let old = s.old, other = s.kind == .otherFolder
        let p = await Task.detached(priority: .utility) { () -> DefaultProfile.Preview in
            DefaultProfile.preview(oldDataDir: Account(old).claudeUserDataDir ?? "", seat: old.seat,
                                   oldCodeDir: other ? Account(old).configDir : nil)
        }.value
        preview = p
    }

    // MARK: the line at the top

    private struct Top { var text: String; var dim: String?; var tone: DisplayWindow.Tone }

    private var topLine: Top {
        switch runner.phase {
        case .ready: return Top(text: "Offer", dim: "· nothing changed yet · nothing is ever overwritten", tone: .normal)
        case .signingIn: return Top(text: "Signing in ●", dim: "· step 1 of \(stepCount) · Claude Code in Terminal", tone: .mint)
        case .closing: return Top(text: "Moving ●", dim: "· step \(kind == .windowOnly ? 1 : 2) of \(stepCount) · the windows close", tone: .mint)
        case .backingUp: return Top(text: "Moving ●", dim: "· step \(kind == .windowOnly ? 1 : 2) of \(stepCount) · the backups", tone: .mint)
        case .moving:
            let p: (done: Int, total: Int) = runner.inner?.progress ?? (0, 0)
            return Top(text: "Moving ●", dim: "· step \(kind == .windowOnly ? 2 : 3) of \(stepCount) · \(p.done) of \(p.total) files", tone: .mint)
        case .done:
            let r = runner.inner?.receipt
            let added = r.map { "\($0.back) files added" } ?? "the window kind changed"
            return Top(text: "Moved", dim: "· \(added) · nothing overwritten" + ((r?.changedCount ?? 0) > 0 ? " · \(r?.changedCount ?? 0) listed" : ""), tone: .ok)
        case .failed: return Top(text: "Stopped", dim: "· nothing moved", tone: .warn)
        case .undone: return Top(text: "Undone", dim: "· the window kind is as it was", tone: .normal)
        }
    }

    private var stepCount: Int { kind == .windowOnly ? 3 : 4 }

    private var topBar: some View {
        let t = topLine
        let display = DisplayWindow(text: t.text, dim: t.dim, tone: t.tone, height: 24, size: 10)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { display; Spacer(minLength: 6); topKeys }
            VStack(alignment: .leading, spacing: 8) { display; HStack(spacing: 10) { topKeys } }
            VStack(alignment: .leading, spacing: 8) { display; VStack(alignment: .leading, spacing: 8) { topKeys } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var topKeys: some View {
        switch runner.phase {
        case .ready, .failed:
            Button("Make the default profile") { runner.start() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
                .disabled(preview == nil && counts == nil)
            Button("Not now") { DefaultProfile.dismissed = true; model.selection = model.homeSelection }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true))
        case .signingIn:
            Button("Show Terminal") { _ = Installer.run("/usr/bin/open", ["-a", "Terminal"]) }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .closing:
            Button("Cancel") { runner.cancel() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .backingUp:
            EmptyView()
        case .moving:
            if let k = runner.inner?.key { Button("Show the restore") { model.showRestore(k) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)) }
        case .done:
            Button("Undo this move") { runner.undo() }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            Button("Back to the settings") { model.selection = runner.targetID ?? model.homeSelection }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        case .undone:
            Button("Back to the settings") { model.selection = model.homeSelection }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        }
    }

    // MARK: cards

    private func value(_ t: String) -> some View {
        Text(t).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whyCard: some View {
        SCard(title: "Why", info: "The default profile is the one on ~/.claude with the usual Claude app: what Claude shows when it is opened from the Dock or Applications, and what `claude` uses in Terminal. Profiles you add later get their own folders and windows.") {
            VStack(alignment: .leading, spacing: 8) {
                Text(DefaultProfile.why(s)).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                SRowLine(text: kind == .windowOnly
                         ? "\(name) is already on ~/.claude, so there is no sign-in step and no transcript to move: only the window's data."
                         : "Claude Code is signed into ~/.claude first (its own login, in Terminal). cl_audit never moves or copies a sign-in.")
            }
            .padding(.vertical, 4)
        }
    }

    private var movesCard: some View {
        let p = counts ?? preview
        return SCard(title: "What moves", info: "Counted from \(name)'s own window folder against the usual app's data now, by session id. Every Code-tab entry and the sidebar arrangement move, not only an import's. An entry the usual app has already stays exactly as it is, and is listed.") {
            if let p {
                SRow(label: "Sessions list", first: true, stacked: true) {
                    value("\(n(p.entries, "entry", "entries")) in \(name)'s window\(p.tasks > 0 ? " · \(n(p.tasks, "scheduled task", "scheduled tasks"))" : "")\(p.groups > 0 ? " · \(n(p.groups, "sidebar group", "sidebar groups"))" : "")")
                }
                SRow(label: "Already in the usual app", stacked: true) {
                    value(p.inUsual == 0 ? "none" : "\(n(p.inUsual, "entry", "entries")) there now, \(p.same) of them \(name)'s, unchanged (nothing to do)\(p.clash > 0 ? " · \(p.clash) of \(name)'s differ from what is there: what is there stays, listed" : "")")
                }
                if kind == .otherFolder {
                    SRow(label: "Transcripts", stacked: true) { value("\(n(p.transcripts, "transcript", "transcripts")) go into ~/.claude/projects (never over one that is there)") }
                }
                SRowLine(text: "Both windows close first, and a backup of each is made. Nothing is deleted from \(name)'s window folder.")
            } else {
                SRow(label: "What moves", first: true, stacked: true) { value("counting…") }
            }
        }
    }

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    private var settingsCard: some View {
        SCard(title: "What each setting becomes", info: "Settings that depend on the kind of Claude window. After the move \(name) opens the usual Claude app; the rest of the profile (name, look, Dock icon, alerts) is as it was.") {
            VStack(alignment: .leading, spacing: 5) {
                let e = runner.target ?? s.old
                ForEach(Array(DefaultProfile.settingsAfter(kind == .windowOnly ? e : s.old).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                if kind == .otherFolder {
                    SRowLine(text: "The default profile is the one on ~/.claude: \(runner.target?.name ?? "a new profile") (made now if there is none), with the usual Claude app.")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: steps

    private enum StepState { case pending, current, done }

    private func states() -> [StepState] {
        let count = stepCount
        var out = [StepState](repeating: .pending, count: count)
        func upTo(_ done: Int, current: Int?) { for i in 0..<count { out[i] = i < done ? .done : i == current ? .current : .pending } }
        let w = kind == .windowOnly
        switch runner.phase {
        case .ready, .failed, .undone: break
        case .signingIn: upTo(0, current: 0)
        case .closing, .backingUp: upTo(w ? 0 : 1, current: w ? 0 : 1)
        case .moving: upTo(w ? 1 : 2, current: w ? 1 : 2); if w { out[2] = .done }
        case .done: upTo(w ? 3 : 3, current: w ? nil : (runner.oldHandled ? nil : 3)); if !w, runner.oldHandled { out[3] = .done }
        }
        return out
    }

    private var stepsCard: some View {
        let st = states()
        let list = DefaultProfile.steps(s)
        return SCard(title: "Steps", info: "Cancel works until the first file is written; a stopped move keeps what is back (Finish or Undo on the restore's page). Undo this move takes back exactly what it added and puts the window kind back.") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, text in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(st[i])
                        Text("\(i + 1) · \(text)").font(.system(size: 12)).foregroundStyle(st[i] == .pending ? face.muted : face.text)
                            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let note = runner.note { Text(note).font(.system(size: 11)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true) }
                if case .failed(let why) = runner.phase { Text(why).font(.system(size: 11)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private func marker(_ s: StepState) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(FaceTheme.ledOn)
        case .current: ProgressView().controlSize(.mini)
        case .pending: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(face.muted)
        }
    }

    // MARK: the result

    @ViewBuilder private var resultCard: some View {
        if runner.phase == .done || runner.phase == .moving {
            SCard(title: "Result", info: "What the restore wrote (its receipt is in cl_audit's folder, restores/): what is back, what stayed as it was, and what Undo takes back.") {
                VStack(alignment: .leading, spacing: 8) {
                    if let r = runner.inner?.receipt {
                        value("\(r.back) files added · \(r.changedCount) already in the usual app and different: left as they are, listed on the restore's page · \(r.inUseCount) held by a running session: left alone")
                    } else if runner.phase == .moving {
                        value("working…")
                    } else {
                        value("Nothing was in \(name)'s window folder to move; only the window kind changed.")
                    }
                    SRowLine(text: DefaultProfile.importNote)
                    if runner.phase == .done, kind == .otherFolder { oldProfile }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var oldProfile: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(name) now").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.muted)
            if runner.oldHandled {
                value("Done.")
            } else {
                if runner.canKeepOldAsStandby {
                    HStack(spacing: 8) {
                        Button("Keep \(name) as a standby account") { runner.keepOldAsStandby() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
                    }
                    SRowLine(text: "Its folder and sign-in stay exactly as they are; the default profile can switch to it when a limit is full.")
                }
                HStack(spacing: 8) {
                    Button("Remove \(name)…") { runner.removeOld() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                }
                SRowLine(text: runner.canKeepOldAsStandby ? "Removing signs its folder out with `claude auth logout`, and asks about deleting it."
                         : "It is the same Claude account as the default profile's, so it can't stand by. Removing signs its folder out with `claude auth logout`, and asks about deleting it.")
            }
        }
    }
}

/// The small mark of a profile on its own Claude window, on its dashboard card (the usual Claude app's profile has none), so two
/// profiles are told apart at a glance.
struct OwnWindowMark: View {
    @Environment(\.face) private var face
    var body: some View {
        Text(DesktopMode.ownMark).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.6)
            .foregroundStyle(face.muted).lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(face.text.opacity(0.08)))
            .help("This profile opens its own Claude window, with its own sessions. Claude opened from the Dock or Applications is another window.")
    }
}
