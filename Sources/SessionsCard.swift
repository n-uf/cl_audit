// SessionsCard: Settings ▸ a profile ▸ Sessions (after the Claude Code card). What is kept here (Claude Code's
// transcripts, the Claude window's entries), how long Claude Code keeps its own, and the backups of the profile's
// sessions (SessionsBackup.swift): made by every switch that moves them and by Back up now, listed here, deleted here.
// Restore comes in a later build: its key is in place and off. Where backups go and how many are kept: General.

import AppKit
import SwiftUI

struct SessionsCard: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject private var prefs = BackupPrefs.shared
    @Environment(\.face) private var face

    @State private var kept: SessionsBackup.Kept?                  // nil: still counting
    @State private var backups: [SessionsBackup.Manifest] = []
    @State private var targets: [String: String] = [:]             // backup id → the account its switch went to, short
    @State private var days: Int? = CodeCleanup.standard           // nil: settings.json doesn't say (or can't be read)
    @State private var keepProblem: String?
    @State private var working = false
    @State private var problem: String?
    @State private var deleting: SessionsBackup.Manifest?          // Delete… asks first

    private var name: String { entry.name.isEmpty ? "This profile" : entry.name }
    private var source: SessionsBackup.Source { SessionsBackup.Source(entry) }
    /// The profile's Claude window is open: it rewrites its entries from memory, so a copy now could be half way.
    private var windowOpen: Bool { _ = model.tick; return !SwitchRunner.windowClosed(entry) }
    private var switching: Bool { _ = model.tick; return SwitchMarker.blocks(Account(entry)) }

    var body: some View {
        SCard(title: "Sessions", info: "\(name)'s sessions: Claude Code's transcripts (claude --resume) and the Claude window's Code-tab list. Backups are quick copies on this Mac, made by every switch that moves the sessions and by Back up now; Restore comes in a later build. Chats and Projects on claude.ai belong to each account and aren't here.") {
            SRow(label: "Kept here", info: "What \(name) has on this Mac now: Claude Code's session transcripts, the entries of the Claude window's Code tab (for every account it has used), and how much room they take.", first: true, stacked: true) {
                text(keptWords)
            }
            SRow(label: "Keep for", info: "How long Claude Code keeps its own transcripts before it deletes them: cleanupPeriodDays in \(tilde(CodeCleanup.file(entry.configDir))), kept with every other setting in that file. Claude Code's default is 30 days. A longer time keeps them available to claude --resume and for backups; it can't bring back what is already deleted.", stacked: true) {
                VStack(alignment: .leading, spacing: 4) {
                    keepForMenu
                    if let keepProblem { note(keepProblem, color: face.danger) }
                }
            }
            SRow(label: "Backups", info: "Quick copies of \(name)'s sessions: the window's Code-tab list with its scheduled tasks and sidebar records, cl_audit's records and, usually, Claude Code's transcripts. Clones, so they take seconds and share space with the originals. Never a sign-in. Kept in \(prefs.placeWords).", stacked: true) {
                backupsList
            }
        }
        .task(id: entry.id + prefs.place + "\(model.switchChanges)") { await load() }
        .alert("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let m = deleting { delete(m) } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(deleting.map { "\(SessionsBackup.title($0, target: targets[$0.id])): \(SessionsBackup.summary($0)). The sessions it was made from are not touched." } ?? "")
        }
    }

    // MARK: Kept here, Keep for

    private var keptWords: String {
        guard let k = kept else { return "counting…" }
        func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v) \(v == 1 ? one : many)" }
        var parts = ["\(k.transcripts) in Claude Code", "\(k.entries) in the Claude window" + (k.sidebar > 0 ? " (\(k.sidebar) in the sidebar)" : ""),
                     SessionsBackup.sizeWords(k.bytes)]
        if let o = k.oldest { parts.append(SessionsBackup.tight("since " + Self.since(o))) }
        return parts.joined(separator: " · ") + ". " + (days.map { "Claude Code deletes its own after \($0) days." } ?? "How long Claude Code keeps its own isn't known (settings.json).")
    }

    private static func since(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }

    private var keepForMenu: some View {
        var options = CodeCleanup.choices.map(\.days)
        if let days, !options.contains(days) { options.insert(days, at: 0) }          // set by hand in the file
        return Menu {
            ForEach(options, id: \.self) { d in
                if d == days { Toggle(CodeCleanup.words(d), isOn: .constant(true)) }       // drawn with the menu's own tick
                else { Button(CodeCleanup.words(d)) { setDays(d) } }
            }
        } label: { MenuWell(text: CodeCleanup.words(days), fill: true) }
        .faceMenuFill()
        .disabled(working)
    }

    private func setDays(_ d: Int) {
        let dir = entry.configDir
        keepProblem = nil
        Task {
            do {
                try await Task.detached(priority: .utility) { try CodeCleanup.set(d, codeDir: dir) }.value
                days = d
            } catch { keepProblem = "\(error)" }               // the file was left as it was: the menu keeps what it showed
        }
    }

    // MARK: Backups

    private var backupsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if backups.isEmpty {
                text("None yet. One is made each time a switch moves \(name)'s sessions, and by Back up now.")
            }
            ForEach(backups) { m in row(m) }
            HStack(spacing: 8) {
                Button(working ? "Backing up…" : "Back up now") { backUpNow() }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(working || switching)
            }
            if switching {
                note("A switch of \(entry.name) is under way: it makes its own backup first.")
            } else if windowOpen {
                note("\(entry.name)'s window is open: close it first, or the Code-tab list and sidebar records are left out.")
            }
            if let problem { note(problem, color: face.danger) }
            closingLine
        }
    }

    private func row(_ m: SessionsBackup.Manifest) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionsBackup.title(m, target: targets[m.id])).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(face.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SessionsBackup.summary(m)).font(.system(size: 11)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore…") {}
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(true)
                .help("Restore comes in the next build")
            Menu {
                Button("Show in Finder") { reveal(m) }
                Divider()
                Button("Delete…") { deleting = m }
            } label: {
                KeyLook(height: 22, radius: 3, hPad: 0) { Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold)).frame(width: 24) }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Show in Finder, Delete…")
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(face.text.opacity(0.05)))
    }

    /// "The last 3 are kept, and any under 30 days; where they go and how many: General."
    private var closingLine: some View {
        var a = AttributedString("The last \(prefs.last) are kept, and any under \(prefs.days) days; where they go and how many: ")
        var g = AttributedString("General")
        g.link = URL(string: "cl-audit-settings://general")
        a += g + AttributedString(".")
        return Text(a).font(.system(size: 10.5)).foregroundStyle(face.muted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.absoluteString == "cl-audit-settings://general" else { return .systemAction }
                model.selection = SettingsModel.dashboardID
                return .handled
            })
    }

    private func text(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: doing things, off the main thread

    private func load() async {
        let e = entry, place = BackupPrefs.placeURL
        let src = SessionsBackup.Source(e)
        kept = SessionsBackup.KeptCache.get(e.id)
        let (list, tg, d) = await Task.detached(priority: .utility) { () -> ([SessionsBackup.Manifest], [String: String], (days: Int?, problem: String?)) in
            let list = SessionsBackup.list(profile: e.id, place: place)
            return (list, Self.targets(list, for: e), CodeCleanup.read(codeDir: e.configDir))
        }.value
        backups = list; targets = tg; days = d.days; keepProblem = d.problem
        let k = await Task.detached(priority: .utility) { SessionsBackup.kept(src) }.value
        SessionsBackup.KeptCache.set(e.id, k)
        kept = k
    }

    /// For each switch's backup, the account that switch went to (the receipt names it by id; this profile knows both
    /// accounts' addresses): "ultra-2".
    private nonisolated static func targets(_ list: [SessionsBackup.Manifest], for e: AccountEntry) -> [String: String] {
        var out: [String: String] = [:]
        let seats = [e.seat] + e.standby.map(\.seat)
        let emails = [e.seat?.email] + e.standby.map { $0.seat?.email ?? $0.email }
        for m in list {
            guard case .beforeSwitch(let rid) = m.kind, let r = SwitchEngine.load(rid),
                  let i = seats.firstIndex(where: { r.to.same($0) }), let email = emails[i] else { continue }
            out[m.id] = AccountNames.short(email)
        }
        return out
    }

    private func backUpNow() {
        let src = source, open = windowOpen, e = entry
        working = true; problem = nil
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try SessionsBackup.manual(src, window: !open, windowClosed: { SwitchRunner.windowClosed(e) }) }
            }.value
            if case .failure(let err) = result {
                var why = "\(err)"
                while why.hasSuffix(".") { why.removeLast() }
                problem = why.hasPrefix("The ") ? why : "The backup couldn't be made: " + why.prefix(1).lowercased() + why.dropFirst() + "."
            }
            working = false
            await load()
        }
    }

    private func delete(_ m: SessionsBackup.Manifest) {
        let id = m.id, profile = entry.id, place = BackupPrefs.placeURL
        deleting = nil; problem = nil
        Task {
            let result = await Task.detached(priority: .utility) { Result { try SessionsBackup.delete(profile: profile, id: id, place: place) } }.value
            if case .failure(let err) = result { problem = "\(err)" }
            await load()
        }
    }

    private func reveal(_ m: SessionsBackup.Manifest) {
        NSWorkspace.shared.activateFileViewerSelecting([SessionsBackup.folder(profile: m.profile, place: BackupPrefs.placeURL).appendingPathComponent(m.id)])
    }
}
