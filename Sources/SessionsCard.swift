// SessionsCard: Settings ▸ a profile ▸ Sessions (after the Claude Code card). What is kept here (Claude Code's
// transcripts, the Claude window's entries), how long Claude Code keeps its own, and the backups of the profile's
// sessions (SessionsBackup.swift): made by every switch that moves them and by Back up now, listed here, deleted here.
// Restore… opens the Restore page (RestorePage.swift): a preview first, nothing written until the key is pressed. Where
// backups go and how many are kept: General. Export… (ExportPage.swift) makes the sessions one file for another Mac or for
// keeping; Import… (ImportPage.swift) restores such a file, and Undo last import takes back what the last one added.

import AppKit
import SwiftUI

struct SessionsCard: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject private var prefs = BackupPrefs.shared
    @Environment(\.face) private var face

    @State private var kept: SessionsBackup.Kept?                  // nil: still counting
    /// One row: a backup, and where it is when a receipt names it in another place than General ▸ Backups' (nil: there). A
    /// backup id can be in both places, so the row's identity is both.
    struct Listed: Identifiable, Equatable {
        var m: SessionsBackup.Manifest
        var place: String?
        var id: String { m.id + "@" + (place ?? "") }
    }
    @State private var backups: [Listed] = []
    @State private var targets: [String: String] = [:]             // backup id → the account its switch went to, short
    @State private var retention = Retention()                     // what Claude Code's clean-up does (days nil: settings.json doesn't say)
    private var days: Int? { retention.days }
    @State private var keepProblem: String?
    @State private var working = false
    @State private var problem: String?
    @State private var deleting: Listed?                           // Delete… asks first
    @State private var lastImport: SessionsRestore.Receipt?        // the last import that wasn't undone: Undo last import
    @State private var carriedImport = false                       // an import the default-profile move carried to the usual app
    @State private var exportWords = "Never exported. A file for another Mac or for keeping."

    private var name: String { entry.name.isEmpty ? "This profile" : entry.name }
    private var source: SessionsBackup.Source { SessionsBackup.Source(entry) }
    /// The profile's Claude window is open: it rewrites its entries from memory, so a copy now could be half way.
    private var windowOpen: Bool { _ = model.tick; return !SwitchRunner.windowClosed(entry) }
    private var switching: Bool { _ = model.tick; return SwitchMarker.blocks(Account(entry)) }

    var body: some View {
        SCard(title: "Sessions", info: "\(name)'s sessions: Claude Code's transcripts (claude --resume) and the Claude window's Code-tab list. Backups are quick copies on this Mac, made by every switch that moves the sessions and by Back up now; Restore… puts back what is missing, merged, and never overwrites anything. Chats and Projects on claude.ai belong to each account and aren't here.") {
            SRow(label: "Kept here", info: "What \(name) has on this Mac now: Claude Code's session transcripts, the entries of the Claude window's Code tab (for every account it has used), and how much room they take.", first: true, stacked: true) {
                text(keptWords)
            }
            SRow(label: "Keep for", info: Retention.keepForInfo(file: tilde(CodeCleanup.file(entry.configDir))), stacked: true) {
                VStack(alignment: .leading, spacing: 4) {
                    if retention.managed, let d = retention.days { text("\(d) days, set by your organisation") } else { keepForMenu }
                    if let keepProblem { note(keepProblem, color: face.danger) }
                    if let n = retention.keepForNote { note(n) }
                }
            }
            SRow(label: "Backups", info: "Quick copies of \(name)'s sessions: the window's Code-tab list with its scheduled tasks and sidebar records, cl_audit's records and, usually, Claude Code's transcripts. Clones, so they take seconds and share space with the originals. Never a sign-in. Kept in \(prefs.placeWords).", stacked: true) {
                backupsList
            }
            SRow(label: "Export", info: "\(name)'s sessions as one file, for another Mac or for keeping: a zip (Finder opens it), or an encrypted disk image when it keeps transcripts that hold keys. Made from a fresh copy or from a backup, with accounts as fingerprints only (never an address, an id or a sign-in). The same format as a backup, so Import restores it by the same rules.", stacked: true) {
                exportRow
            }
            SRow(label: "Import", info: "Puts an export's sessions into \(name): the file is checked and unpacked as a backup first, then restored from: the same rules as Restore. It only adds what is missing and never overwrites anything. An export of \(name), of another profile or of another Mac. Undo last import takes back exactly what it added.", stacked: true) {
                importRow
            }
        }
        .task(id: entry.id + prefs.place + "\(model.switchChanges)") { await load() }
        .alert("Delete this backup?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let l = deleting { delete(l) } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(deleting.map { l in
                "\(SessionsBackup.title(l.m, target: targets[l.m.id])): \(SessionsBackup.summary(l.m)). The sessions it was made from are not touched."
                    + (SessionsRestore.finishedRestores(of: l.m.id, profile: entry.id, place: placeOf(l).path) > 0
                       ? " A restore from it is finished: its receipt, which Undo this restore needs, goes with the backup, so that restore can't be undone afterwards." : "")
                    + (SessionsRestore.halfUndoneRestores(of: l.m.id, profile: entry.id, place: placeOf(l).path) > 0
                       ? " A restore from it is only partly undone (a running session held some of its transcripts): its receipt stays, and Undo can be tried again; it doesn't need the backup." : "")
            } ?? "")
        }
    }

    // MARK: Kept here, Keep for

    private var keptWords: String {
        guard let k = kept else { return "counting…" }
        func n(_ v: Int, _ one: String, _ many: String) -> String { "\(v) \(v == 1 ? one : many)" }
        var parts = ["\(k.transcripts) in Claude Code", "\(k.entries) in the Claude window" + (k.sidebar > 0 ? " (\(k.sidebar) in the sidebar)" : ""),
                     SessionsBackup.sizeWords(k.bytes)]
        if let o = k.oldest { parts.append(SessionsBackup.tight("since " + Self.since(o))) }
        return parts.joined(separator: " · ") + ". " + retention.keptHereWords
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
                retention.days = d
            } catch { keepProblem = "\(error)" }               // the file was left as it was: the menu keeps what it showed
        }
    }

    // MARK: Export, Import

    private var exportRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button("Export…") { model.showExport(entry.id) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                .help("Preview what an export would hold. Nothing is written until you press Export and the Save panel says where")
            Text(exportWords).font(.system(size: 12)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button("Import…") { model.showImport(entry.id) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                    .help("Choose an export (a .zip or .dmg) and preview what it would add. Nothing is written until you press Close and import, and nothing is ever overwritten")
                text("From an export of this profile, another profile or another Mac.")
            }
            if lastImport == nil, carriedImport {
                // an import into the old window's data, carried to the usual app by the default-profile move
                note(DefaultProfile.importNote)
            }
            if let l = lastImport {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button("Undo last import") { model.showRestore(RestoreKey(profile: entry.id, backup: l.backup, place: l.backupPlace, resume: l.id)) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                        .help("Opens the import's page, where Undo this import takes back exactly what it added")
                    text(SessionsBackup.tight("Last import \(SessionsBackup.dateWords(l.started)): ") + ((ImportWords.counts(sessions: l.sessionsAdded, entries: l.entriesAdded) ?? "nothing") + " added") + (l.importedFrom.map { " from \(($0 as NSString).deletingPathExtension)" } ?? ""))
                }
            }
        }
    }

    // MARK: Backups

    private var backupsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if backups.isEmpty {
                text("None yet. One is made each time a switch moves \(name)'s sessions, and by Back up now.")
            }
            ForEach(backups) { l in row(l) }
            HStack(spacing: 8) {
                Button(working ? "Backing up…" : "Back up now") { backUpNow() }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(working || switching)
            }
            if switching {
                note("A switch or a restore of \(entry.name) is under way: a switch makes its own backup first.")
            } else if windowOpen {
                note("\(entry.name)'s window is open: close it first, or the Code-tab list and sidebar records are left out.")
            }
            if let problem { note(problem, color: face.danger) }
            closingLine
        }
    }

    private func row(_ l: Listed) -> some View {
        let m = l.m
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionsBackup.title(m, target: targets[m.id])).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(face.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SessionsBackup.summary(m) + (l.place.map { " · in \(tilde($0))" } ?? "")).font(.system(size: 11)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore…") { model.showRestore(RestoreKey(profile: entry.id, backup: m.id, place: placeOf(l).path)) }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                .help("Preview what a restore would do. Nothing is written until you press Close and restore, and nothing is ever overwritten")
            Menu {
                Button("Show in Finder") { reveal(l) }
                Divider()
                Button("Delete…") { deleting = l }
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
        lastImport = await Task.detached(priority: .utility) { SessionsRestore.lastImport(of: e.id) }.value
        carriedImport = await Task.detached(priority: .utility) {
            SessionsRestore.headers().contains { $0.profile == e.id && $0.importedFrom != nil && $0.finished != nil && $0.undone == nil && SessionsRestore.carriedOver($0) }
        }.value
        exportWords = ExportPrefs.words(profile: e.id)
        let (list, tg, d) = await Task.detached(priority: .utility) { () -> ([Listed], [String: String], Retention) in
            SessionsImport.sweep(place: place)                 // unpacking and export folders a stopped run left (a day old)
            SessionsRestore.prune(profile: e.id)               // old receipts of finished restores
            let here = SessionsBackup.list(profile: e.id, place: place).map { Listed(m: $0, place: nil) }
            // backups a receipt names in another place (General ▸ Backups was changed since): listed too, with their place
            let more = SessionsBackup.elsewhere(profile: e.id, place: place).map { Listed(m: $0.manifest, place: $0.place) }
            let list = (here + more).sorted { $0.m.created != $1.m.created ? $0.m.created > $1.m.created : $0.id > $1.id }
            return (list, Self.targets(list.map(\.m), for: e), Retention.read(codeDir: e.configDir))
        }.value
        backups = list; targets = tg; retention = d; keepProblem = d.problem
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

    private func delete(_ l: Listed) {
        let id = l.m.id, profile = entry.id, place = placeOf(l)
        deleting = nil; problem = nil
        Task {
            let result = await Task.detached(priority: .utility) { Result { try SessionsBackup.delete(profile: profile, id: id, place: place) } }.value
            if case .failure(let err) = result { problem = "\(err)" }
            await load()
        }
    }

    private func reveal(_ l: Listed) {
        NSWorkspace.shared.activateFileViewerSelecting([SessionsBackup.folder(profile: l.m.profile, place: placeOf(l)).appendingPathComponent(l.m.id)])
    }

    /// Where a listed backup is: General ▸ Backups' folder, or the place a receipt named it in.
    private func placeOf(_ l: Listed) -> URL { l.place.map { URL(fileURLWithPath: $0) } ?? BackupPrefs.placeURL }
}
