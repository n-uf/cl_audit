// ExportPage: Settings ▸ a profile ▸ Sessions ▸ Export… A profile's sessions as one file, for another Mac or for keeping
// (SessionsExport.swift makes it). A sibling of the Restore page, with the same line at the top and the same keys.
//
//   Preview      nothing written yet: What (from, Claude Code, Claude window), Keys found (and what to do with them, and the
//                password), Preview (per project folder), the file's name, Cancel and "Export 305 sessions · ≈ 5.5 GB"
//   Exporting    what it is doing and how far; Stop
//   Exported     the file's name and size, Show in Finder, Back to Main's settings
//
// The Save panel asks where; the password is typed into a secure field here, handed to hdiutil on its stdin and cleared
// the moment the export starts. It is never stored or shown again.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One Export page's state. Counting (what there is, which sessions hold keys) happens off the main thread when the page opens
/// and when "From" changes; nothing is written until the key is pressed and the Save panel says where.
final class ExportRunner: ObservableObject {
    enum Source: Hashable {
        case now
        case backup(id: String, place: String?)         // a backup of the profile (place: where a receipt names it, nil: General ▸ Backups')
        case all                                        // every profile, as it is now
    }
    enum Container: Equatable { case zip, image }
    enum Phase: Equatable {
        case preview
        case working(String, Double)
        case done(SessionsExport.Outcome)
        case failed(String)
    }

    let profile: String
    private weak var model: SettingsModel?
    @Published var source: Source = .now { didSet { if source != oldValue { refresh() } } }
    @Published var keys: SessionsExport.Keys = .leaveOut
    @Published var container: Container = .zip
    @Published var password = ""
    @Published var again = ""
    @Published private(set) var phase: Phase = .preview
    /// One per profile exported: nil while counting.
    @Published private(set) var previews: [SessionsExport.Preview]?
    @Published private(set) var scanned: Int64 = 0
    @Published private(set) var backups: [(m: SessionsBackup.Manifest, place: String?)] = []
    @Published private(set) var note: String?
    private var generation = 0
    private let lock = NSLock()
    private var stopFlag = false
    private var frozen = false

    init(profile: String, model: SettingsModel) {
        self.profile = profile; self.model = model
        reloadBackups()
    }

    var entry: AccountEntry? { model?.accounts.first { $0.id == profile } }

    // MARK: what is exported from

    func reloadBackups() {
        guard let e = entry else { return }
        let here = SessionsBackup.list(profile: e.id).map { (m: $0, place: String?.none) }
        let more = SessionsBackup.elsewhere(profile: e.id).map { (m: $0.manifest, place: String?.some($0.place)) }
        backups = (here + more).sorted { $0.m.created > $1.m.created }
    }

    private func part(of e: AccountEntry) -> SessionsExport.Part {
        let emails = ([e.seat?.email] + e.standby.map { $0.seat?.email ?? $0.email }).compactMap { $0 }.filter { !$0.isEmpty }
        return SessionsExport.Part(profile: e.id, name: e.name.isEmpty ? e.id : e.name, source: SessionsBackup.Source(e), emails: emails,
                                   windowOpen: e.claudeWindow && !SwitchRunner.windowClosed(e), windowClosed: { SwitchRunner.windowClosed(e) })
    }

    /// The profiles and where each is exported from, for the current choice.
    func parts() -> [SessionsExport.Part] {
        guard let m = model, let e = entry else { return [] }
        switch source {
        case .now: return [part(of: e)]
        case .all: return m.accounts.map(part(of:))
        case .backup(let id, let place):
            var p = part(of: e)
            p.source = nil
            p.backup = SessionsRestore.Backup(profile: e.id, id: id, place: place.map { URL(fileURLWithPath: $0) } ?? BackupPrefs.placeURL)
            p.windowOpen = false
            return [p]
        }
    }

    // MARK: counting (read-only), off the main thread

    func refresh() {
        guard !frozen else { return }
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        previews = nil; scanned = 0; note = nil
        let list = parts()
        let current: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.generation != mine
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out: [SessionsExport.Preview] = []
            var bytes: Int64 = 0
            var lastTell = Date.distantPast
            for p in list {
                guard let pv = SessionsExport.preview(p, cancel: current, progress: { n in
                    bytes += n
                    if Date().timeIntervalSince(lastTell) > 0.3 { lastTell = Date(); let b = bytes; DispatchQueue.main.async { self?.scanned = b } }
                }) else { return }
                out.append(pv)
            }
            DispatchQueue.main.async {
                guard let self, !current() else { return }
                self.previews = out
            }
        }
    }

    /// The page is left: nothing is counted for it any more (an export under way goes on).
    func leave() {
        password = ""; again = ""                       // no password stays in a runner that is kept for later
        lock.lock(); generation += 1; lock.unlock()
    }

    // MARK: numbers for the words

    var total: SessionsExport.Preview? {
        guard let p = previews, !p.isEmpty else { return nil }
        if p.count == 1 { return p[0] }
        var t = SessionsExport.Preview(profile: "all", name: "All profiles")
        for x in p {
            t.sessions += x.sessions; t.transcriptBytes += x.transcriptBytes; t.entries += x.entries; t.tasks += x.tasks; t.windowBytes += x.windowBytes
            t.keyedSessions += x.keyedSessions; t.keyedBytes += x.keyedBytes; t.keyedFiles += x.keyedFiles; t.inUse += x.inUse
            t.windowLeftOut = t.windowLeftOut || x.windowLeftOut
            for (k, v) in x.keyKinds { t.keyKinds[k, default: 0] += v }
        }
        return t
    }

    /// Keeping keys needs the encrypted image.
    var imageNeeded: Bool { keys == .keep && (total?.keyed ?? 0) > 0 }
    var usesImage: Bool { container == .image || imageNeeded }
    var passwordProblem: String? {
        guard usesImage else { return nil }
        if password.count < 8 { return password.isEmpty ? "A password is needed." : "At least 8 characters." }
        if password != again { return "The two don't match." }
        return nil
    }
    var canExport: Bool { phase == .preview && previews != nil && passwordProblem == nil && (total?.sessionsIn(keys) ?? 0) + (total?.entries ?? 0) > 0 }

    /// "cl_audit Main 2026-11-05"
    func rootName(now: Date = Date()) -> String {
        SessionsExport.rootName(for: source == .all ? (model?.accounts.map(\.name) ?? []) : [entry?.name ?? profile], now: now)
    }
    func fileName(now: Date = Date()) -> String { rootName(now: now) + (usesImage ? ".dmg" : ".zip") }

    var isWorking: Bool { if case .working = phase { return true }; return false }

    // MARK: going

    func stop() { lock.lock(); stopFlag = true; lock.unlock() }
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stopFlag }

    /// The Save panel, then the export.
    func start() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName()
        panel.allowedContentTypes = usesImage ? [UTType(filenameExtension: "dmg") ?? .diskImage] : [.zip]
        panel.canCreateDirectories = true
        panel.title = "Export sessions"
        panel.prompt = "Export"
        if let last = ExportPrefs.folder, FileManager.default.fileExists(atPath: last) { panel.directoryURL = URL(fileURLWithPath: last) }
        else { panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ExportPrefs.folder = url.deletingLastPathComponent().path
        run(to: url)
    }

    /// Makes the file at `url` (the panel has already asked about replacing one).
    func run(to url: URL) {
        let list = parts()
        guard !list.isEmpty else { return }
        let image = usesImage
        let pw = image ? password : nil
        let job = SessionsExport.Job(parts: list, keys: keys, password: pw, destination: url, rootName: rootName())
        password = ""; again = ""                     // the secure fields are emptied the moment it starts; the job holds it until hdiutil has it
        lock.lock(); stopFlag = false; lock.unlock()
        phase = .working("starting", 0); note = nil
        let profiles = list.map(\.profile)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsExport.run(job, cancel: { self?.stopped ?? true }, progress: { what, f in
                DispatchQueue.main.async { if self?.isWorking == true { self?.phase = .working(what, f) } }
            }) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let o):
                    for p in profiles { ExportPrefs.remember(profile: p, date: Date(), bytes: o.bytes) }
                    self.phase = .done(o)
                    self.model?.forgetRestore()
                case .failure(let err):
                    var why = "\(err)"
                    while why.hasSuffix(".") { why.removeLast() }
                    self.phase = why == "Stopped" ? .preview : .failed(why + ". Nothing was left behind.")
                    if why == "Stopped" { self.note = "Stopped. Nothing was left behind." }
                }
            }
        }
    }

    func tryAgain() { phase = .preview; note = nil; refresh() }

    /// Renders only: the page as it looks at a step.
    func preview(_ p: Phase, previews pv: [SessionsExport.Preview]) {
        frozen = true
        phase = p; previews = pv
    }
}

/// A secure field drawn as a well, like the address field.
struct WellSecure: View {
    let placeholder: String
    @Binding var text: String
    @Environment(\.face) private var face

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(Color.white.opacity(0.32)))
            .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.hex(0xececee))
            .environment(\.colorScheme, .dark)
            .padding(.horizontal, 9).frame(height: 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WellShape(well: Well(stops: Well.flat(face.menuFill), inner: .black(0.75), lip: face.light ? .white(0.6) : .white(0.05)), radius: 4))
    }
}

struct ExportPage: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: ExportRunner
    var width: CGFloat = 980
    @State private var showProjects = false
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    private var pv: SessionsExport.Preview? { runner.total }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(runner.source == .all ? "Export all profiles' sessions" : "Export \(name)'s sessions").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            topBar
            SettingsColumns(width: width, groups: [[AnyView(whatCard), AnyView(keysCard)], [AnyView(previewCard), AnyView(fileCard)]])
        }
        .task(id: entry.id) { if runner.previews == nil, runner.phase == .preview { runner.refresh() } }
        .onDisappear { runner.leave() }
    }

    // MARK: the line at the top

    private var topBar: some View {
        let t = topLine
        let display = DisplayWindow(text: t.text, dim: t.dim, tone: t.tone, height: 24, size: 10)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { display; Spacer(minLength: 6); topKeys }
            VStack(alignment: .leading, spacing: 8) { display; HStack(spacing: 10) { topKeys } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topLine: (text: String, dim: String?, tone: DisplayWindow.Tone) {
        switch runner.phase {
        case .preview:
            if runner.previews == nil { return ("Counting", "· nothing written yet · \(SessionsBackup.sizeWords(runner.scanned)) looked at", .normal) }
            return ("Preview", "· nothing written yet", .normal)
        case .working(let what, let f): return ("Exporting ●", "· \(what) · \(Int(f * 100)) %", .mint)
        case .done(let o):
            return ("Exported", "· \(o.sessions) sessions · \(SessionsBackup.sizeWords(o.bytes))" + (o.keysLeftOut > 0 ? " · \(o.keysLeftOut) left out for keys" : ""), .ok)
        case .failed: return ("Stopped", "· nothing left behind", .warn)
        }
    }

    @ViewBuilder private var topKeys: some View {
        switch runner.phase {
        case .working: Button("Stop") { runner.stop() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true))
        case .done(let o):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([o.file]) }.buttonStyle(PillButtonStyle(tint: nil, compact: true))
            Button("Back to \(name)'s settings") { model.selection = entry.id }.buttonStyle(.pill(FaceTheme.ledOn, compact: true))
        default: EmptyView()
        }
    }

    // MARK: What

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    private func value(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(color ?? face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fromWords: String {
        switch runner.source {
        case .now: return "\(name) as it is now"
        case .all: return "All profiles"
        case .backup(let id, _):
            return runner.backups.first { $0.m.id == id }.map { backupWords($0.m) } ?? "a backup"
        }
    }

    /// "Main's backup of 5 Nov 18:40"
    private func backupWords(_ m: SessionsBackup.Manifest) -> String {
        var s = "\(name)'s backup of \(SessionsBackup.dateWords(m.created))"
        switch m.kind {
        case .beforeSwitch: s += " (before a switch)"
        case .imported: s += " (imported)"
        case .manual: break
        }
        return s
    }

    private var whatCard: some View {
        SCard(title: "What", info: "An export holds the same things as a backup (the Claude window's Code-tab entries and scheduled tasks, its sidebar records, Claude Code's transcripts), from a copy made now or from a backup you choose. Never a sign-in, an MCP setting, settings.json, a switch's receipt, an address or an account id: accounts appear only as a fingerprint of their id.") {
            SRow(label: "From", first: true) {
                Menu {
                    Button("\(name) as it is now") { runner.source = .now }
                    if !runner.backups.isEmpty {
                        Divider()
                        ForEach(runner.backups.indices, id: \.self) { i in
                            let b = runner.backups[i]
                            Button(backupWords(b.m)) { runner.source = .backup(id: b.m.id, place: b.place) }
                        }
                    }
                    if model.accounts.count > 1 { Divider(); Button("All profiles") { runner.source = .all } }
                } label: { MenuWell(text: fromWords, fill: true) }
                .faceMenuFill().disabled(runner.phase != .preview)
            }
            SRow(label: "Claude Code", stacked: true) {
                value(pv.map { "\(n($0.sessions, "session", "sessions")), with their sub-agent files · \(SessionsBackup.sizeWords($0.transcriptBytes))" } ?? "counting…")
            }
            SRow(label: "Claude window", stacked: true) {
                VStack(alignment: .leading, spacing: 4) {
                    value(pv.map { $0.windowLeftOut ? "left out: the window is open" : "\(n($0.entries, "Code-tab entry", "Code-tab entries")), \(n($0.tasks, "task", "tasks"))" } ?? "counting…")
                    if pv?.windowLeftOut == true, runner.source == .now {
                        Text("\(name)'s window is open: close it first, or the Code-tab list and sidebar records are left out.").font(.system(size: 10.5)).foregroundStyle(face.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SRow(label: "Cowork", stacked: true) { value("left out") }
        }
    }

    // MARK: Keys found

    private var keysFound: [(Secret, Int)] { (pv?.keyKinds ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) } }

    private var foundWords: String {
        guard let p = pv else { return "scanning the transcripts…" }
        if p.keyed == 0 { return "None found in the transcripts" }
        let kinds = keysFound.map { "\($0.1) \($0.0.words)" }.joined(separator: ", ")
        var s = "\(n(p.keyedSessions, "session holds", "sessions hold")) keys"
        if !kinds.isEmpty { s += ": " + kinds }
        if p.keyedFiles > 0 { s += " · \(n(p.keyedFiles, "other file", "other files")) too" }
        return s
    }

    private var keysCard: some View {
        let found = pv?.keyed ?? 0
        return SCard(title: "Keys found", info: "The transcripts are searched for GitHub tokens, AWS access keys, private keys, and Anthropic, OpenAI, Slack, Google, Stripe and npm keys. A session whose files hold one is left out, or, if you say so, kept in an encrypted disk image that needs a password. The keys themselves are never shown or written anywhere.") {
            SRow(label: "Found", first: true, stacked: true) { value(foundWords, color: found > 0 ? face.caution : nil) }
            if found > 0 {
                SRow(label: "Those \(pv?.keyed ?? 0)") {
                    Menu {
                        Button("Leave them out") { runner.keys = .leaveOut }
                        Button("Keep them: needs a password") { runner.keys = .keep }
                    } label: { MenuWell(text: runner.keys == .leaveOut ? "Leave them out" : "Keep them", fill: true) }
                    .faceMenuFill().disabled(runner.phase != .preview)
                }
            }
            SRow(label: "Password", info: "None: a zip, which Finder opens. An encrypted disk image (AES-256) needs the password to open at all. The password is typed here, handed to macOS's hdiutil on its standard input, and never stored, shown again or logged: lose it and the file can't be opened.", stacked: runner.usesImage) {
                VStack(alignment: .leading, spacing: 6) {
                    Menu {
                        Button("None: a zip") { runner.container = .zip }.disabled(runner.imageNeeded)
                        Button("An encrypted disk image") { runner.container = .image }
                    } label: { MenuWell(text: runner.usesImage ? "An encrypted disk image" : "None: a zip", fill: true) }
                    .faceMenuFill().disabled(runner.phase != .preview || runner.imageNeeded)
                    if runner.usesImage {
                        WellSecure(placeholder: "Password", text: $runner.password)
                        WellSecure(placeholder: "Again", text: $runner.again)
                        if let why = runner.passwordProblem, !(runner.password.isEmpty && runner.again.isEmpty) {
                            Text(why).font(.system(size: 10.5)).foregroundStyle(face.danger)
                        } else {
                            Text("Not stored anywhere. Lose it and the file can't be opened.").font(.system(size: 10.5)).foregroundStyle(face.muted)
                        }
                    }
                }
            }
            if runner.imageNeeded { SRowLine(text: "Keeping keys needs the encrypted disk image.") }
        }
    }

    // MARK: Preview

    private var previewCard: some View {
        SCard(title: "Preview", info: "Per project folder (read from the folder each transcript ran in): how many sessions, how much, and what is left out or cut. A transcript a running Claude Code session holds is copied up to its last full line.") {
            if let list = runner.previews {
                let lines = projectLines(list)
                ForEach(Array(lines.prefix(showProjects ? 200 : 8).enumerated()), id: \.offset) { i, l in
                    SRow(label: l.title, first: i == 0, stacked: true) { projectWords(l.project) }
                }
                if lines.count > 8 {
                    Button(showProjects ? "Show fewer" : "…and \(lines.count - 8) more folders") { showProjects.toggle() }
                        .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(face.muted).padding(.vertical, 4)
                }
                if lines.isEmpty { SRow(label: "Claude Code", first: true, stacked: true) { value("No sessions in it.") } }
            } else {
                SRow(label: "Folders", first: true, stacked: true) { value("counting…") }
            }
        }
    }

    private struct ProjectLine { var title: String; var project: SessionsExport.Preview.Project }

    private func projectLines(_ list: [SessionsExport.Preview]) -> [ProjectLine] {
        var out: [ProjectLine] = []
        for pv in list { for p in pv.projects { out.append(ProjectLine(title: (list.count > 1 ? pv.name + " · " : "") + p.name, project: p)) } }
        return out
    }

    /// "210 · 3.9 GB · 2 in use, copied up to their last full line", "5 with keys: left out"
    private func projectWords(_ p: SessionsExport.Preview.Project) -> some View {
        let left = runner.keys == .leaveOut ? p.keyed : 0
        var parts: [String] = []
        if p.sessions - left > 0 || p.keyed == 0 { parts.append("\(p.sessions - left) · \(SessionsBackup.sizeWords(p.bytes))") }
        if p.inUse > 0 { parts.append("\(p.inUse) in use, copied up to their last full line") }
        if p.keyed > 0 { parts.append("\(p.keyed) with keys: " + (runner.keys == .leaveOut ? "left out" : "kept")) }
        return value(parts.joined(separator: " · "), color: left > 0 ? face.caution : nil)
    }

    // MARK: the file

    private var count: Int { (pv?.sessionsIn(runner.keys) ?? 0) }
    private var exportLabel: String {
        guard let p = pv else { return "Counting…" }
        let sessions = p.sessionsIn(runner.keys)
        let what = sessions > 0 ? "\(sessions) \(sessions == 1 ? "session" : "sessions")" : "\(p.entries) \(p.entries == 1 ? "entry" : "entries")"
        return "Export \(what) · ≈ \(SessionsBackup.sizeWords(p.bytesIn(runner.keys)))"
    }

    @ViewBuilder private var exportKey: some View {
        switch runner.phase {
        case .working: Text("exporting…").font(.system(size: 12)).foregroundStyle(face.caution)
        case .done: EmptyView()
        case .failed: Button("Try again") { runner.tryAgain() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
        case .preview: Button(exportLabel) { runner.start() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(!runner.canExport).fixedSize()
        }
    }

    private var fileCard: some View {
        SCard(title: "The file", info: "One file made with macOS's own tools (ditto for a zip, hdiutil for the encrypted disk image), so Finder opens it. The Save panel asks where. Accounts appear only as a fingerprint of their id, never an address or a token.") {
            SRow(label: "Name", first: true, stacked: true) {
                Text(runner.fileName()).font(.system(size: 12, design: .monospaced)).foregroundStyle(face.text).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SRowLine(text: runner.usesImage
                     ? "One encrypted disk image (AES-256), made with macOS's own hdiutil; Finder asks for the password. Accounts appear only as a fingerprint of their id, never an address or a token."
                     : "One file, made with macOS's own ditto, so Finder opens it. Accounts appear only as a fingerprint of their id, never an address or a token.")
            if case .working(let what, let f) = runner.phase {
                SRowLine(text: "\(what) · \(Int(f * 100)) %", color: FaceTheme.mint)
            }
            if case .failed(let why) = runner.phase { SRowLine(text: why, color: face.danger) }
            if let note = runner.note { SRowLine(text: note) }
            // Back and the key on one line when they fit; else the key above Back (neither is ever cut off)
            let back = Button(runner.phase == .preview ? "Cancel" : "Back") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { back; Spacer(minLength: 6); exportKey }
                VStack(alignment: .leading, spacing: 10) { exportKey; back }
            }
            .padding(.top, 8)
        }
    }
}
