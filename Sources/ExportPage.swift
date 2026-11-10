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
    @Published var keys: SessionsExport.Keys = .leaveOut { didSet { if keys != oldValue { refreshSide() } } }
    /// Claude Code's setup (CLAUDE.md, skills, agents, commands …) goes in: on by default.
    @Published var setup = true
    /// cl_audit's own profiles and settings go in (SessionsMove.swift; the encrypted image only): off by default, on in the Move preset.
    @Published var profiles = false
    /// A move to another Mac: the real account ids and addresses stay (no fingerprints), so the new Mac puts the Code-tab entries and
    /// tasks back in each account's folder. Only ever the encrypted image: the zip choice is off while it is on.
    @Published var move = false { didSet { if move { container = .image }; if move != oldValue { refreshCode(); refreshSide() } } }
    /// A move's side files (SessionsSide.swift): task lists, plans, prompt history, trust go in; Rewind's backups only when included
    /// (they can be hundreds of MB).
    @Published var rewind = false { didSet { if rewind != oldValue { refreshSide() } } }
    var sideKinds: SideFiles.Kinds { var k = SideFiles.Kinds.movePreset; k.rewind = rewind; return k }
    /// What they come to now (read-only), with the keys found in them; nil while counting or outside a move.
    @Published private(set) var side: SideFiles.Preview?
    @Published private(set) var sideCounting = false
    private var sideGeneration = 0
    /// A move's code checklist as read now (CodeChecklist.swift): the page warns from it before the export; the export reads it again.
    @Published private(set) var code: CodeChecklist.File?
    @Published private(set) var codeCounting = false
    private var codeGeneration = 0
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
                self.refreshCode()
                self.refreshSide()
            }
        }
    }

    /// The session folders of what is exported (absolute) and how many sessions ran in each, from the preview.
    var codeFolders: [String: Int] {
        var out: [String: Int] = [:]
        for pv in previews ?? [] { for p in pv.projects { if let c = p.cwd { out[c, default: 0] += p.sessions } } }
        return out
    }

    /// A move: the code checklist read now with read-only git, off the main thread (nothing for an export that isn't a move).
    func refreshCode() {
        guard !frozen else { return }
        // (each call, and leaving the page, stops a reading under way)
        lock.lock(); codeGeneration += 1; let mine = codeGeneration; lock.unlock()
        guard move, previews != nil else { code = nil; codeCounting = false; return }
        let folders = codeFolders
        codeCounting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // (stopped as soon as the page counts again, the move is turned off or the page is left)
            let f = CodeChecklist.gather(folders, git: CodeChecklist.gitPath(), cancel: { [weak self] in
                guard let self else { return true }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.codeGeneration != mine
            })
            DispatchQueue.main.async {
                guard let self else { return }
                self.lock.lock(); let same = self.codeGeneration == mine; self.lock.unlock()
                guard same, self.move else { return }
                self.code = f; self.codeCounting = false
            }
        }
    }

    /// A move: the side files counted and key-scanned now, off the main thread (each profile exported as it is now; a backup keeps none).
    func refreshSide() {
        guard !frozen else { return }
        lock.lock(); sideGeneration += 1; let mine = sideGeneration; lock.unlock()
        guard move else { side = nil; sideCounting = false; return }
        let sources = parts().compactMap(\.source)
        let kinds = sideKinds, keys = keys
        sideCounting = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let current: () -> Bool = { [weak self] in
                guard let self else { return true }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.sideGeneration != mine
            }
            var total = SideFiles.Preview()
            total.rewindCarried = kinds.rewind
            for (i, s) in sources.enumerated() {
                var refs = SideFiles.sessions(codeDir: s.codeDir)
                let titles = s.dataDir.isEmpty ? [:] : SideFiles.titles(windowDir: (s.dataDir as NSString).appendingPathComponent("claude-code-sessions"))
                for k in refs.indices { refs[k].title = titles[refs[k].id] }
                guard let g = SideFiles.gather(codeDir: s.codeDir, sessions: refs, kinds: kinds, keys: keys, dir: "p\(i + 1)", out: nil, cancel: current) else { return }
                total.add(g.preview)
            }
            DispatchQueue.main.async {
                guard let self, !current(), self.move else { return }
                self.side = total; self.sideCounting = false
            }
        }
    }

    /// The page is left: nothing is counted for it any more (an export under way goes on).
    func leave() {
        password = ""; again = ""                       // no password stays in a runner that is kept for later
        lock.lock(); generation += 1; codeGeneration += 1; sideGeneration += 1; lock.unlock()
    }

    // MARK: numbers for the words

    var total: SessionsExport.Preview? {
        guard let p = previews, !p.isEmpty else { return nil }
        if p.count == 1 { return p[0] }
        var t = SessionsExport.Preview(profile: "all", name: "All profiles")
        for x in p {
            t.sessions += x.sessions; t.transcriptBytes += x.transcriptBytes; t.entries += x.entries; t.tasks += x.tasks; t.windowBytes += x.windowBytes
            t.keyedSessions += x.keyedSessions; t.keyedBytes += x.keyedBytes; t.keyedFiles += x.keyedFiles; t.inUse += x.inUse; t.connections += x.connections; t.unreadable += x.unreadable; t.markersOrphan += x.markersOrphan; t.markersKeyed += x.markersKeyed
            t.windowLeftOut = t.windowLeftOut || x.windowLeftOut
            for (k, v) in x.keyKinds { t.keyKinds[k, default: 0] += v }
            t.setup.add(x.setup)
            t.config.add(x.config); t.tasksWithPrompt += x.tasksWithPrompt
        }
        return t
    }

    /// Keeping keys needs the encrypted image. (Setup's sensitive part, settings.json and its scripts, doesn't force it: a zip leaves it out.)
    var imageNeeded: Bool { keys == .keep && (total?.keyed ?? 0) > 0 }
    var usesImage: Bool { container == .image || imageNeeded }
    var passwordProblem: String? {
        guard usesImage else { return nil }
        if password.count < 8 { return password.isEmpty ? "A password is needed." : "At least 8 characters." }
        if password != again { return "The two don't match." }
        return nil
    }
    var canExport: Bool {
        phase == .preview && previews != nil && passwordProblem == nil && (!move || usesImage)
            && (total?.sessionsIn(keys) ?? 0) + (total?.entries ?? 0) + (setup ? (total?.setup.units.count ?? 0) : 0) + (profiles && usesImage ? 1 : 0) > 0
    }

    /// Move to another Mac, in one click: every profile (when there are more than one), the encrypted image, Claude Code's setup, the
    /// window's MCP settings and scheduled tasks (an image carries them), cl_audit's profiles and settings, the real account ids. The
    /// keys choice stays as it is. Each row can still be changed afterwards (the zip only by turning the move off); a row the person had
    /// set otherwise and the preset changed is said on the page (`presetChanged`).
    func movePreset() {
        guard phase == .preview else { return }
        var changed: [String] = []
        let from: Source = (model?.accounts.count ?? 0) > 1 ? .all : { if case .backup = source { return .now }; return source }()
        if from != source { changed.append("From to \(from == .all ? "All profiles" : "the profile as it is now")") }
        if !setup { changed.append("Claude Code setup to Include them") }
        source = from
        move = true; container = .image; setup = true; profiles = true
        presetChanged = changed
    }
    /// The rows the Move preset set differently from what the person had chosen (said once, under the Move row).
    @Published var presetChanged: [String] = []

    /// The profiles exported (cl_audit's records of them), for cl_audit.json: those of the parts.
    func exportedEntries() -> [AccountEntry] {
        let ids = parts().map(\.profile)
        return (model?.accounts ?? []).filter { ids.contains($0.id) }
    }

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
        var plan = SessionsExport.Job(parts: list, keys: keys, password: pw, destination: url, rootName: rootName())
        plan.setup = setup
        let everyProfile = model?.accounts ?? []
        plan.move = move && image
        if plan.move { plan.side = sideKinds }
        if profiles {
            // (each profile's part folder is p1, p2 … in the order of the parts, as the engine names them)
            let dirs = Dictionary(list.enumerated().map { ($1.profile, "p\($0 + 1)") }, uniquingKeysWith: { a, _ in a })
            plan.profiles = SessionsMove.make(exportedEntries(), parts: dirs, all: everyProfile, move: plan.move)
        }
        password = ""; again = ""                     // the secure fields are emptied the moment it starts; the job holds it until hdiutil has it
        lock.lock(); stopFlag = false; lock.unlock()
        phase = .working("starting", 0); note = nil
        let profiles = list.map(\.profile)
        let folders = plan.move ? codeFolders : [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var job = plan
            job.known = Identities.of(accounts: everyProfile)         // every profile's accounts, whichever are exported
            // a move: the code checklist read again now (read-only git), into the encrypted image only
            if job.move {
                // (Stop stops the reading too)
                let list = CodeChecklist.gather(folders, git: CodeChecklist.gitPath(), cancel: { self?.stopped ?? true })
                job.checklist = CodeChecklist.encode(list)
            }
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
    func preview(_ p: Phase, previews pv: [SessionsExport.Preview], code c: CodeChecklist.File? = nil, side sd: SideFiles.Preview? = nil) {
        if let sd { side = sd }
        frozen = true
        phase = p; previews = pv
        if let c { code = c }
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

/// The words of the Export page that come from the numbers (so a check can read them): the setup row, what is left out of it, the Found line.
enum ExportWords {
    private static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// "CLAUDE.md, 23 skills, 4 agents, 6 commands" (what goes in: a zip leaves out settings.json, its scripts and the marketplaces).
    static func setupWords(_ pv: SessionsExport.Preview?, setup: Bool, image: Bool) -> String {
        guard let p = pv else { return "counting…" }
        let sp = p.setup
        if sp.units.isEmpty { return sp.linked.isEmpty ? "none" : "none carried (see below)" }
        if !setup { return "left out" }
        var plainExtra = Setup.Extra(); plainExtra.plugins = sp.extra.plugins          // (the plugin list is carried in a zip; only the marketplaces file is held back)
        return image ? Setup.words(sp.counts, extra: sp.extra)
            : (sp.plain.total == 0 ? "none: only settings.json and the like, which need the encrypted disk image" : Setup.words(sp.plain, extra: plainExtra))
    }

    /// What is left out and why: sensitive setup in a zip, links (and where they point: on this page only), what points outside the folder.
    static func setupNotes(_ pv: SessionsExport.Preview?, setup: Bool, image: Bool) -> [String] {
        guard let p = pv else { return [] }
        let sp = p.setup
        var out: [String] = []
        if setup, !image, let w = Setup.sensitiveWords(sp.sensitive, held: sp.held, unknown: sp.hooksUnknown) {
            out.append("\(w) \(sp.sensitive.total + sp.held.total == 1 ? "needs" : "need") the encrypted disk image: left out of a zip")
        }
        if setup, image, sp.envBlanked {
            out.append("settings.json comes with its env values blank (the names stay): backups don't keep those values. Export the profile as it is now to carry them.")
        }
        if setup, image, !sp.keysBlanked.isEmpty {
            let names = sp.keysBlanked.prefix(4).joined(separator: ", ") + (sp.keysBlanked.count > 4 ? ", …and \(sp.keysBlanked.count - 4) more" : "")
            out.append("settings.json comes with \(sp.keysBlanked.count == 1 ? "a value" : "\(sp.keysBlanked.count) values") blank where a backup found a key (\(names)). Export the profile as it is now to carry the keys.")
        }
        if setup, image, !sp.hooksDropped.isEmpty || !sp.rulesDropped.isEmpty {
            let k = sp.hooksDropped.count + sp.rulesDropped.count
            let names = (sp.hooksDropped + sp.rulesDropped).prefix(4).joined(separator: ", ") + (k > 4 ? ", …and \(k - 4) more" : "")
            out.append("settings.json comes without \(k == 1 ? "a hook or permission rule" : "\(k) hooks and permission rules") that held a key (\(names)): a backup doesn't keep one. Export the profile as it is now to carry \(k == 1 ? "it" : "them").")
        }
        if setup, image, !sp.keysLeftOut.isEmpty {
            out.append("\(sp.keysLeftOut.prefix(4).joined(separator: ", "))\(sp.keysLeftOut.count > 4 ? ", …" : "") held a key and isn't in the backup, so the image lacks \(sp.keysLeftOut.count == 1 ? "it" : "them"): export the profile as it is now to carry \(sp.keysLeftOut.count == 1 ? "it" : "them").")
        }
        if !sp.linked.isEmpty {
            let shown = sp.linked.prefix(3).map { "\($0.label) points to \(tilde($0.target))" }.joined(separator: ", ")
            out.append("\(n(sp.linked.count, "link", "links")) left out, never followed: \(shown)" + (sp.linked.count > 3 ? ", …" : ""))
        }
        out += sp.outside.prefix(3).map { $0 }
        if sp.outside.count > 3 { out.append("…and \(sp.outside.count - 3) more outside the folder, not carried") }
        if sp.leftOutBuild > 0 { out.append("\(sp.leftOutBuild) version-history and build leftovers (.git, node_modules, .DS_Store …) left out") }
        // the walk's cut units, hard links and sign-in names: each said for what it is
        let cutSuffix = " (\(Setup.cutWords))"
        let whole = sp.leftOutNames.filter { $0.hasSuffix(cutSuffix) }.map { String($0.dropLast(cutSuffix.count)) }
        let hard = sp.leftOutNames.filter { $0.hasSuffix(Setup.hardLinkWords) }.map { String($0.dropLast(Setup.hardLinkWords.count)) }
        let signIn = sp.leftOutNames.filter { !$0.hasSuffix(cutSuffix) && !$0.hasSuffix(Setup.hardLinkWords) && $0 != Setup.settingsTooBig }
        if sp.leftOutNames.contains(Setup.settingsTooBig) { out.append("settings.json is over 8 MB: left out, with the scripts its hooks run (an import refuses one that big)") }
        if !signIn.isEmpty { out.append("\(n(signIn.count, "file", "files")) with a sign-in name left out: \(signIn.prefix(2).joined(separator: ", "))") }
        if !whole.isEmpty {
            let what = whole.allSatisfy { $0.hasPrefix("skills/") } ? n(whole.count, "skill", "skills") : n(whole.count, "skill or folder", "skills or folders")
            out.append("\(what) left out whole: too many files or folders nested too deep (\(whole.prefix(2).joined(separator: ", "))\(whole.count > 2 ? ", …" : ""))")
        }
        if !hard.isEmpty { out.append("\(n(hard.count, "file", "files")) left out: \(hard.count == 1 ? "a hard link" : "hard links") (\(hard.prefix(2).joined(separator: ", "))\(hard.count > 2 ? ", …" : ""))") }
        return out
    }

    /// The MCP settings row: the window's claude_desktop_config.json (without its sidebar part) and, for a zip, the line that says it
    /// needs the encrypted disk image.
    static func mcpWords(_ pv: SessionsExport.Preview?, image: Bool) -> (value: String, note: String?) {
        guard let p = pv else { return ("counting…", nil) }
        if p.windowLeftOut { return ("left out: the window is open", nil) }
        let c = p.config
        if !c.present {
            if let why = c.leftOut { return ("claude_desktop_config.json left out (\(why))", nil) }
            return (c.fromBackup ? "none: backups don't keep the window's MCP settings; export the profile as it is now to carry them" : "none", nil)
        }
        let names = c.servers.prefix(4).joined(separator: ", ") + (c.servers.count > 4 ? ", …" : "")
        if image {
            let servers = c.servers.isEmpty ? "no MCP servers" : n(c.servers.count, "MCP server", "MCP servers") + " (" + names + ")"
            return ("\(servers) and the window's other settings: in the encrypted disk image", nil)
        }
        let which = c.servers.isEmpty ? "the window's settings" : "\(n(c.servers.count, "server", "servers")): \(names), and the window's other settings"
        return ("left out of a zip", "A zip leaves out the window's MCP settings (\(which)): they can hold keys no scan can find. Choose the encrypted disk image to carry them.")
    }

    /// The image's MCP settings are scrubbed like the window's other files.
    /// (Information, not a warning: the preview can't tell whether the scrub will change anything in them.)
    static let fingerprintNote = "Addresses and account ids cl_audit knows are replaced by fingerprints in these settings, as everywhere in an export. A server that uses one needs it put back by hand after the import."
    static func mcpInfo(_ pv: SessionsExport.Preview?, image: Bool) -> String? {
        guard image, let p = pv, !p.windowLeftOut, p.config.present else { return nil }
        return fingerprintNote
    }

    /// The Claude window row's line about the scheduled tasks: they travel with their prompts and come back paused.
    static func tasksNote(_ pv: SessionsExport.Preview?) -> String? {
        guard let p = pv, !p.windowLeftOut, p.tasks > 0 else { return nil }
        let with = min(p.tasksWithPrompt, p.tasks), without = p.tasks - with
        let tasks = n(p.tasks, "scheduled task", "scheduled tasks")
        let head = without == 0 ? "\(tasks) with \(p.tasks == 1 ? "its prompt" : "their prompts")"
            : "\(tasks), \(with) with \(with == 1 ? "its" : "their") prompt (\(without == 1 ? "one" : "those") without it can't be imported)"
        return head + ". An import adds them only if you pick Add them, and they come paused."
    }

    /// The "cl_audit's profiles" row: each exported profile's record (name, look, Dock place, accounts) and cl_audit's General and backup
    /// settings. They name addresses and accounts, so only the encrypted disk image carries them.
    static func profilesWords(count: Int, names: [String], on: Bool, image: Bool) -> (value: String, note: String?) {
        if !on { return ("left out", nil) }
        if !image { return ("left out of a zip", "A zip leaves out cl_audit's profiles and settings (names, accounts and their addresses): choose the encrypted disk image to carry them.") }
        let list = names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : "")
        return ("\(n(count, "profile", "profiles")) (\(list)): accounts, looks, Dock places, and cl_audit's General and backup settings. Carried in the encrypted disk image only.", nil)
    }

    /// The Move row: what a move carries and why only the encrypted image can.
    static func moveWords(_ on: Bool) -> String {
        on ? "On: your accounts keep their real identifiers and email addresses, so the new Mac can put each Code-tab entry and scheduled task back under the right account. That is why a move is always a password-protected disk image, never a plain zip."
           : "Not a move: accounts appear only as fingerprints."
    }

    /// Under the Move row while it is on: sign-ins never travel.
    static let signInsLine = "Sign-ins don't travel. On the new Mac you sign in again to each account (Add account)."

    /// "5 sessions and 1 skill hold keys: 3 GitHub tokens, 1 private key": the sessions and the setup units (a skill, CLAUDE.md …) together.
    static func foundWords(_ pv: SessionsExport.Preview?) -> String {
        guard let p = pv else { return "scanning the transcripts…" }
        if p.keyed == 0 { return "None found in the transcripts" + (p.setup.isEmpty ? "" : " or the setup") }
        var merged = p.keyKinds
        for (k, v) in p.setup.keyKinds { merged[k, default: 0] += v }
        let kinds = merged.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.words)" }.joined(separator: ", ")
        var things: [String] = []
        if p.keyedSessions > 0 { things.append(n(p.keyedSessions, "session", "sessions")) }
        if !p.setup.keyedUnits.isEmpty { things.append(Setup.words(Setup.Counts(p.setup.keyedUnits))) }
        let total = p.keyedSessions + p.setup.keyedUnits.count
        if things.isEmpty { return "\(n(p.keyedFiles, "other file holds", "other files hold")) keys" + (kinds.isEmpty ? "" : ": " + kinds) }
        var s = things.joined(separator: " and ") + (total == 1 ? " holds" : " hold") + " keys"
        if !kinds.isEmpty { s += ": " + kinds }
        if p.keyedFiles > 0 { s += " · \(n(p.keyedFiles, "other file", "other files")) too" }
        return s
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
            Text(runner.move ? "Move to another Mac" : runner.source == .all ? "Export all profiles' sessions" : "Export \(name)'s sessions").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            topBar
            SettingsColumns(width: width, groups: [[AnyView(whatCard), AnyView(keysCard)], [AnyView(previewCard), AnyView(fileCard)]])
        }
        .task(id: entry.id) { if runner.previews == nil, runner.phase == .preview { runner.refresh() } }
        .onDisappear { runner.leave() }
    }

    // MARK: the line at the top

    private var topBar: some View {
        let t = topLine
        let display = DisplayWindow(text: t.text, dim: DisplayWindow.narrowed(t.dim, width: width), tone: t.tone, height: 24, size: 10)
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
        case .preview where !runner.move:
            Button("Move to another Mac") { runner.movePreset() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
        default: EmptyView()
        }
    }

    // MARK: What

    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// A move's Code row: the projects, and a warning for each one with work only on this Mac.
    @ViewBuilder private var codeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = runner.code {
                let warn = CodeChecklist.warnings(c)
                value(CodeChecklist.summary(c))
                ForEach(Array(warn.prefix(12).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 11)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                if warn.count > 12 { Text("…and \(warn.count - 12) more.").font(.system(size: 10.5)).foregroundStyle(face.muted) }
                if c.git != nil {
                    Text("Only the folders are listed: no remote, branch or counts. Check each one yourself before you move.").font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                value(runner.codeCounting || runner.previews == nil ? "reading…" : "–")
            }
        }
    }

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
        SCard(title: "What", info: "An export holds the same things as a backup (the Claude window's Code-tab entries and scheduled tasks, its sidebar records, Claude Code's transcripts and its setup: CLAUDE.md, skills, agents …, and, in an encrypted disk image, the window's MCP settings), from a copy made now or from a backup you choose. Never a sign-in, settings.local.json, a switch's receipt, an address or an account id: accounts appear only as a fingerprint of their id.") {
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
            SRow(label: "Move", info: "Move to another Mac: everything a new Mac needs in one encrypted disk image: every profile's sessions, Claude Code's setup, the window's MCP settings and scheduled tasks, and cl_audit's own profiles and settings. A move keeps the real account ids and addresses (no fingerprints), because the Claude window files its Code-tab list and scheduled tasks by account: the new Mac puts them back where the window looks once you sign in there. That is why a move is only ever the encrypted image. Sign-ins never travel: you sign in to each account on the new Mac.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    value(ExportWords.moveWords(runner.move))
                    if runner.move {
                        Text(ExportWords.signInsLine).font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        if !runner.presetChanged.isEmpty {
                            Text("The Move preset set " + runner.presetChanged.joined(separator: " and ") + ". Your Keys found choice is unchanged.")
                                .font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Menu {
                        Button("Move to another Mac") { runner.movePreset() }
                        Button("Not a move") { runner.move = false }
                    } label: { MenuWell(text: runner.move ? "Move to another Mac" : "Not a move", fill: true) }
                    .faceMenuFill().disabled(runner.phase != .preview)
                }
            }
            if runner.move {
                SRow(label: "Code", info: "A move carries the sessions, not the code they ran in. For each project folder of the sessions, cl_audit reads with read-only git (never a fetch, nothing written): where it can be cloned from (any user name, password or token taken out of the address), the branch, the last commit, and how many commits aren't pushed and files aren't committed. That list goes into the encrypted disk image only, and the new Mac's Import page shows it with the commands to copy. Push and commit first: a clone won't have what is only on this Mac.", stacked: true) {
                    codeRow
                }
                SideExportRow(preview: runner.side, kinds: runner.sideKinds, counting: runner.sideCounting,
                              rewind: runner.phase == .preview ? { runner.rewind = $0 } : nil)
            }
            SRow(label: "Claude Code", stacked: true) {
                VStack(alignment: .leading, spacing: 4) {
                    value(pv.map { "\(n($0.sessions, "session", "sessions")), with their sub-agent files · \(SessionsBackup.sizeWords($0.transcriptBytes))" } ?? "counting…")
                    if let p = pv, p.markersLeftOut(runner.keys) > 0 {
                        let k = p.markersLeftOut(runner.keys)
                        Text("\(k) leftover \(k == 1 ? "marker" : "markers") left out (Claude Code's retention markers whose session isn't in the file).").font(.system(size: 10.5)).foregroundStyle(face.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            SRow(label: "Claude window", stacked: true) {
                VStack(alignment: .leading, spacing: 4) {
                    value(pv.map { $0.windowLeftOut ? "left out: the window is open" : "\(n($0.entries, "Code-tab entry", "Code-tab entries")), \(n($0.tasks, "scheduled task", "scheduled tasks"))" } ?? "counting…")
                    if pv?.windowLeftOut == true, runner.source == .now {
                        Text("\(name)'s window is open: close it first, or the Code-tab list and sidebar records are left out.").font(.system(size: 10.5)).foregroundStyle(face.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let t = ExportWords.tasksNote(pv) {
                        Text(t).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SRow(label: "MCP settings", info: "The Claude window's claude_desktop_config.json without its sidebar part: its MCP servers (what each runs, with their env values, headers and arguments) and the window's other settings. Those can hold tokens no scan recognises, so only the encrypted disk image carries them; a zip leaves them out. Importing leaves them out unless you add them, and adds them only where the profile has no claude_desktop_config.json yet.", stacked: true) {
                let w = ExportWords.mcpWords(pv, image: runner.usesImage)
                VStack(alignment: .leading, spacing: 4) {
                    value(w.value)
                    if let note = w.note {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !runner.move, let info = ExportWords.mcpInfo(pv, image: runner.usesImage) {         // (a move scrubs nothing)
                        Text(info).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !runner.usesImage, let p = pv, p.connections > 0 || p.unreadable > 0 {
                let settings = p.connections > 0 ? "Connection settings in \(n(p.connections, "Code-tab entry", "Code-tab entries")) need the encrypted disk image: left out of a zip." : ""
                let unread = p.unreadable > 0 ? "\(n(p.unreadable, "Code-tab file", "Code-tab files")) it can't read \(p.unreadable == 1 ? "is" : "are") left out of a zip too." : ""
                SRowLine(text: [settings, unread].filter { !$0.isEmpty }.joined(separator: " "), color: face.caution)
            }
            SRow(label: "Claude Code setup", info: "Claude Code's own setup, from \(tilde(entry.configDir)): CLAUDE.md and the .md files it includes (its @ lines), skills, agents, commands, output styles, keybindings, settings.json (with the scripts its hooks and status line point to) and the plugin list, so a move to another Mac brings them. Never the plugins themselves, settings.local.json or a sign-in. A link is never followed: a skill that is one, or holds one, is left out and listed. settings.json, its scripts and the plugin marketplaces can hold tokens no scan recognises, so only the encrypted disk image carries them; a zip leaves them out. Importing leaves them out unless you add them.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    value(setupWords)
                    if let sp = pv?.setup, !sp.isEmpty || !sp.linked.isEmpty {
                        Menu {
                            Button("Include them") { runner.setup = true }
                            Button("Leave them out") { runner.setup = false }
                        } label: { MenuWell(text: runner.setup ? "Include them" : "Leave them out", fill: true) }
                        .faceMenuFill().disabled(runner.phase != .preview)
                    }
                    ForEach(Array(setupNotes.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SRow(label: "cl_audit's profiles", info: "cl_audit's own record of each profile exported: its name, label and look, how it behaves, its place in the order (which the Dock group follows), its Claude Code and window folders, and its accounts with the one in use; and cl_audit's General and backup settings. They name your accounts and their addresses, so only the encrypted disk image carries them. An import makes the profiles that aren't on that Mac and never changes one that is; each made profile needs its sign-ins there, and its Dock icon is a step after the import.", stacked: true) {
                let names = runner.exportedEntries().map(\.name)
                let w = ExportWords.profilesWords(count: names.count, names: names, on: runner.profiles, image: runner.usesImage)
                VStack(alignment: .leading, spacing: 6) {
                    value(w.value)
                    Menu {
                        Button("Include them") { runner.profiles = true }
                        Button("Leave them out") { runner.profiles = false }
                    } label: { MenuWell(text: runner.profiles ? "Include them" : "Leave them out", fill: true) }
                    .faceMenuFill().disabled(runner.phase != .preview)
                    if let note = w.note {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SRow(label: "Cowork", stacked: true) { value("left out") }
        }
    }

    // MARK: Claude Code setup

    /// "CLAUDE.md, 23 skills, 4 agents, 6 commands" (what goes in: a zip leaves out settings.json, its scripts and the marketplaces).
    private var setupWords: String { ExportWords.setupWords(pv, setup: runner.setup, image: runner.usesImage) }
    private var setupNotes: [String] { ExportWords.setupNotes(pv, setup: runner.setup, image: runner.usesImage) }

    // MARK: Keys found

    private var foundWords: String { ExportWords.foundWords(pv) }

    private var keysCard: some View {
        let found = pv?.keyed ?? 0
        return SCard(title: "Keys found", info: "The transcripts are searched for GitHub tokens, AWS access keys, private keys, and Anthropic, OpenAI, Slack, Google, Stripe and npm keys. A session whose files hold one is left out, or, if you say so, kept in an encrypted disk image that needs a password. The keys themselves are never shown or written anywhere.") {
            SRow(label: "Found", first: true, stacked: true) { value(foundWords, color: found > 0 ? face.caution : nil) }
            // a move's side files (prompt history, pasted text, plans, task lists, trust, Rewind): their hits, under the same choice
            let sideHits = runner.move ? (runner.side?.hits ?? []) : []
            if !sideHits.isEmpty {
                SRow(label: "In side files", stacked: true) {
                    value(sideHits.prefix(6).map { "\($0.what): \($0.kinds.map(\.words).joined(separator: ", "))" }.joined(separator: "; ")
                          + (runner.keys == .leaveOut ? ". Each line or file that holds one is left out." : ". Kept, in the encrypted disk image."), color: face.caution)
                }
            }
            if found > 0 || !sideHits.isEmpty {
                SRow(label: "Those \(found + sideHits.count)") {
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
                        Button("None: a zip") { runner.container = .zip }.disabled(runner.imageNeeded || runner.move)
                        Button("An encrypted disk image") { runner.container = .image }
                    } label: { MenuWell(text: runner.usesImage ? "An encrypted disk image" : "None: a zip", fill: true) }
                    .faceMenuFill().disabled(runner.phase != .preview || runner.imageNeeded || runner.move)
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
            if runner.move { SRowLine(text: "A move is always the encrypted disk image, because it holds your accounts' real identifiers and addresses.") }
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
        // nothing but the setup goes: the key says so (not "0 entries")
        if sessions == 0, p.entries == 0, runner.setup, !p.setup.isEmpty { return "Export the setup · ≈ \(SessionsBackup.sizeWords(p.setup.bytes))" }
        let what = sessions > 0 ? "\(sessions) \(sessions == 1 ? "session" : "sessions")" : "\(p.entries) \(p.entries == 1 ? "entry" : "entries")"
        // (a move's side files are in the file too: their bytes count)
        let side = runner.move ? (runner.side?.bytes ?? 0) : 0
        return "Export \(what) · ≈ \(SessionsBackup.sizeWords(p.bytesIn(runner.keys) + side))"
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
            SRowLine(text: runner.move
                     ? "One encrypted disk image (AES-256), made with macOS's own hdiutil; Finder asks for the password. Your accounts' real identifiers and addresses are inside it, protected by the password. No sign-in or token is ever put in."
                     : runner.usesImage
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
