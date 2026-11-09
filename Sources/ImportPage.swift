// ImportPage: Settings ▸ a profile ▸ Sessions ▸ Import… An export (SessionsExport.swift) read back in, as a restore
// (SessionsImport.swift checks and unpacks it; SessionsRestore.swift writes). The page is a sibling of the Restore page:
//
//   Choose       no file yet: Choose… (an Open panel for a .zip or .dmg), Into
//   Password     an encrypted disk image asks for its password (typed into a secure field, handed to hdiutil on stdin)
//   Reading      the file is checked and unpacked (nothing is written into a profile)
//   Refused      the whole import is refused, and says why: nothing written
//   Preview      nothing written yet · nothing is ever overwritten: From, What happens, Stays as it is; "Close and import N"
//   then         the Restore page's own steps take over (Importing ●, Imported, Undo this import)
//
// The file is unpacked as a backup of the target profile first (kind "imported", in General ▸ Backups' place), then
// restored from: the same rules as Restore, the same receipt, the same Undo.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImportWords {
    /// "25 sessions · 12 entries", "1 session", "12 entries": a zero part is left out; nil when both are zero.
    static func counts(sessions: Int, entries: Int) -> String? {
        var parts: [String] = []
        if sessions > 0 { parts.append("\(sessions) \(sessions == 1 ? "session" : "sessions")") }
        if entries > 0 { parts.append("\(entries) \(entries == 1 ? "entry" : "entries")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Sidebar card's words for an import: the groups it will create are named (plain names only: letters, digits,
    /// spaces and a few marks, at most 40 characters; the file's own are cleaned before they get here).
    static func arrangement(_ p: SidebarPlan?, hasEntries: Bool) -> String {
        guard let p, !p.isEmpty else {
            return hasEntries ? "Nothing to arrange: none of the imported sessions sat in a group or was pinned" : "Nothing to arrange: no session comes in"
        }
        var what: [String] = []
        if p.filed > 0 {
            let names = p.groups.filter { !$0.sessions.isEmpty }.map { "“\($0.name)”" }.joined(separator: ", ")
            what.append("\(p.filed) \(p.filed == 1 ? "session goes" : "sessions go") in the \(p.groups.count == 1 ? "group" : "groups") the import creates: \(names)")
        }
        if !p.pinned.isEmpty { what.append("\(p.pinned.count) \(p.pinned.count == 1 ? "session is" : "sessions are") pinned") }
        return "From the file's sidebar records: \(what.joined(separator: "; ")). One Return in the helper session."
    }
}

/// After an import took (or Undo put back) cl_audit's settings: the window's own copies read them again, so the page shows them at once.
/// Only cl_audit's own preferences (a check keeps its settings in memory, and nothing here runs then).
enum MoveLive {
    static func reload() {
        guard let d = SessionsMove.prefs as? UserDefaults, d === UserDefaults.standard else { return }
        FacePrefs.shared.face = Face(rawValue: d.string(forKey: "face") ?? "") ?? .std
        if d.object(forKey: Privacy.key) != nil, d.bool(forKey: Privacy.key) != Privacy.shared.show { Privacy.shared.set(show: d.bool(forKey: Privacy.key)) }
        let dash = DashboardPrefs.shared
        dash.cardStyle = PanelDesign(rawValue: d.string(forKey: "dashboardCardStyle") ?? "") ?? .segments
        dash.range = StatsRange(rawValue: d.string(forKey: "dashboardRange") ?? "") ?? .week
        dash.showHeatmap = d.object(forKey: "dashboardShowHeatmap") as? Bool ?? true
        dash.showTokens = d.object(forKey: "dashboardShowTokens") as? Bool ?? true
        dash.showShares = d.object(forKey: "dashboardShowShares") as? Bool ?? true
        if dash.history != (d.object(forKey: DashboardPrefs.historyKey) as? Bool ?? true) { dash.history = d.object(forKey: DashboardPrefs.historyKey) as? Bool ?? true }
        let icon = AppIconPrefs.shared
        icon.style = AppIconStyle(rawValue: d.string(forKey: "appIconStyle") ?? "") ?? .standard
        icon.look = PanelLook(plate: PanelPlate(rawValue: d.string(forKey: "appIconPanelPlate") ?? "") ?? .grey, display: PanelDisplay(rawValue: d.string(forKey: "appIconPanelDisplay") ?? "") ?? .cyan,
                              keys: PanelKeys(rawValue: d.string(forKey: "appIconPanelKeys") ?? "") ?? .classic, slot: PanelSlot(rawValue: d.string(forKey: "appIconPanelSlot") ?? "") ?? .lit)
        BackupPrefs.shared.reload()
    }
}

final class ImportRunner: ObservableObject {
    enum Phase: Equatable {
        case choose
        case password(String?)                  // asks for the image's password (and why again)
        case opening(String)
        case refused(String)
        case ready
        case running(RestoreKey)                // closed and importing: the Restore page's steps
    }

    let profile: String
    private weak var model: SettingsModel?
    @Published private(set) var phase: Phase = .choose
    @Published private(set) var file: URL?
    @Published var password = ""
    @Published private(set) var into: String
    @Published private(set) var partIndex = 0
    @Published private(set) var opened: SessionsImport.Opened?
    @Published private(set) var staged: SessionsImport.Staged?
    /// Counts the staged backup against the target (a RestoreRunner that is only looked at; it never starts).
    @Published private(set) var counting: RestoreRunner?
    @Published private(set) var note: String?
    @Published private(set) var addMemory = false
    @Published private(set) var addSetup = false
    @Published private(set) var addConfig = false
    @Published private(set) var addTasks = false
    /// cl_audit's own profiles and settings in the file (SessionsMove.swift): what making them would do here; nil: none in the file.
    @Published private(set) var movePlan: SessionsMove.Plan?
    /// The profiles that aren't here are made (the default: nothing that is here changes, nothing runs, Undo takes them back) …
    @Published var makeProfiles = true
    /// … and this Mac's settings stay unless the person takes the file's.
    @Published var takeSettings = false
    /// What making them did (its receipt), for the page and the done page's steps.
    @Published private(set) var moved: SessionsMove.Receipt?
    @Published private(set) var moveNote: String?
    private var frozen = false
    private let lock = NSLock()
    private var cancelFlag = false
    private var generation = 0

    init(profile: String, model: SettingsModel) {
        self.profile = profile; into = profile; self.model = model
    }

    var intoEntry: AccountEntry? { model?.accounts.first { $0.id == into } }
    var profiles: [AccountEntry] { model?.accounts ?? [] }
    var isRunning: Bool { if case .running = phase { return true }; return false }
    var isOpening: Bool { if case .opening = phase { return true }; return false }

    /// "cl_audit Work 2026-10-30.zip · made on another Mac · 30 Oct 18:40"
    var fileWords: String? {
        guard let f = file else { return nil }
        guard let o = opened else { return f.lastPathComponent }
        return f.lastPathComponent + " · made " + (o.sameMac ? "on this Mac" : "on another Mac") + " · " + SessionsBackup.dateWords(o.export.created)
    }

    private func cancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelFlag }
    private func isCurrent(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == g }

    // MARK: choosing the file

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.zip, UTType(filenameExtension: "dmg") ?? .diskImage]
        p.canChooseDirectories = false; p.allowsMultipleSelection = false
        p.title = "Import sessions"; p.prompt = "Choose"
        if let last = ExportPrefs.folder, FileManager.default.fileExists(atPath: last) { p.directoryURL = URL(fileURLWithPath: last) }
        guard p.runModal() == .OK, let url = p.url else { return }
        setFile(url)
    }

    func setFile(_ url: URL) {
        discardWork()
        file = url; password = ""; note = nil
        if url.pathExtension.lowercased() == "dmg" { phase = .password(nil) } else { open() }
    }

    /// Reads, checks and unpacks the file; the first part is made a backup of the target and counted.
    func open() {
        guard let url = file else { return }
        let pw = password.isEmpty ? nil : password
        password = ""                                   // emptied the moment it is handed over
        lock.lock(); cancelFlag = false; generation += 1; let g = generation; lock.unlock()
        phase = .opening("reading the file")
        let target = into
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsImport.open(url, password: pw, cancel: { self?.cancelled() ?? true },
                                                          progress: { s in DispatchQueue.main.async { if self?.isOpening == true { self?.phase = .opening(s) } } }) }
            switch result {
            case .failure(let err):
                DispatchQueue.main.async { self?.failed("\(err)", g) }
            case .success(let o):
                // the part the target's name matches, else the first
                let idx = o.parts.firstIndex { $0.profile == target } ?? o.parts.firstIndex { $0.name == self?.intoEntry?.name } ?? 0
                DispatchQueue.main.async {
                    guard let self, self.isCurrent(g) else { SessionsImport.discard(o.work); return }
                    self.opened = o; self.partIndex = idx
                    // cl_audit's own profiles in the file (a move): what an import would make here. Into stays the person's choice (the page
                    // only suggests the part's own profile); a file whose accounts are fingerprints starts with its profiles left out
                    if let f = o.app {
                        let plan = SessionsMove.plan(f, accounts: self.profiles)
                        self.movePlan = plan
                        self.makeProfiles = !plan.fingerprinted
                    }
                    self.stage()
                }
            }
        }
    }

    private func failed(_ why: String, _ g: Int) {
        guard isCurrent(g) else { return }
        if why == "password needed" { phase = .password(nil); return }
        if why.contains("password isn't right") { phase = .password(why); return }
        if why == "Stopped." { phase = file?.pathExtension.lowercased() == "dmg" ? .password(nil) : .choose; file = nil; return }
        phase = .refused(why)
    }

    func cancelOpening() { lock.lock(); cancelFlag = true; lock.unlock() }

    // MARK: the staged backup, counted

    /// The opened file's chosen part becomes a backup of `into`, and is counted against it.
    private func stage() {
        guard let o = opened, partIndex < o.parts.count, let e = intoEntry else { return }
        phase = .opening("making it a backup of \(e.name)")
        let part = o.parts[partIndex], target = into
        lock.lock(); let g = generation; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsImport.materialize(o, part: part, target: target, cancel: { self?.cancelled() ?? true }) }
            DispatchQueue.main.async {
                guard let self, self.isCurrent(g) else { return }
                switch result {
                case .failure(let err): self.phase = .refused("\(err)")
                case .success(let s): self.staged = s; self.recount()
                }
            }
        }
    }

    private func recount() {
        // (only for the profile Into shows: while a retarget to another one runs, its own recount comes when it lands)
        guard let s = staged, s.target == into, let model else { return }
        let key = RestoreKey(profile: s.target, backup: s.id, place: s.stage.path, addMemory: addMemory, addSetup: addSetup, addConfig: addConfig, addTasks: addTasks)
        let r = RestoreRunner(key: key, model: model)
        counting = r
        phase = .ready
        r.refresh()
    }

    /// Memory files of a file from another Mac or profile: left out, or added (the preview is counted again).
    func setMemory(_ on: Bool) {
        guard on != addMemory else { return }
        addMemory = on
        recount()
    }

    /// Claude Code's setup in the file (CLAUDE.md, skills …): left out, or the missing ones added (the preview is counted again).
    func setSetup(_ on: Bool) {
        guard on != addSetup else { return }
        addSetup = on
        recount()
    }

    /// The window's MCP settings in the file: left out, or added where the profile has none (the preview is counted again).
    func setConfig(_ on: Bool) {
        guard on != addConfig else { return }
        addConfig = on
        recount()
    }

    /// The file's scheduled tasks: left out, or added paused (the preview is counted again).
    func setTasks(_ on: Bool) {
        guard on != addTasks else { return }
        addTasks = on
        recount()
    }

    /// Into another profile: the staged backup becomes that profile's.
    func setInto(_ id: String) {
        guard id != into else { return }
        into = id
        guard let s = staged else { return }
        counting = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsImport.retarget(s, to: id) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .failure(let err): self.phase = .refused("\(err)")
                case .success(let n): self.staged = n; self.recount()
                }
            }
        }
    }

    /// Another profile in the file (an export of all profiles).
    func setPart(_ i: Int) {
        guard let o = opened, i != partIndex, i < o.parts.count else { return }
        if let s = staged { try? FileManager.default.removeItem(at: s.stage.appendingPathComponent(s.target)) }
        staged = nil; counting = nil; partIndex = i
        lock.lock(); generation += 1; lock.unlock()           // what the old part's staging was still doing is no longer current
        stage()
    }

    // MARK: cl_audit's own profiles and settings (a move)

    /// Makes the profiles that aren't here (and takes the file's settings, when chosen): a step of its own, before the sessions, so the
    /// part's own profile is there to count them against. Writes only cl_audit's profiles file, the made profiles' empty folders and the
    /// settings; never the Dock, never an app, never a sign-in. Its receipt lets Undo take exactly that back.
    func applyMove() {
        guard !moveBusy, let o = opened, let plan = movePlan, !plan.isEmpty, moved == nil || moved?.undone != nil else { return }
        let create = makeProfiles, take = takeSettings
        var p = plan
        if !create { p.create = [] }
        guard !p.create.isEmpty || (take && !p.takeable.isEmpty) else { return }
        moveNote = nil
        moveBusy = true                                       // a second press while this runs does nothing: one run, one receipt
        let file = o.fileName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsMove.apply(p, takeSettings: take, file: file) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.moveBusy = false
                switch result {
                case .failure(let err): self.moveNote = "\(err)"
                case .success(let r):
                    self.moved = r
                    if !r.problems.isEmpty { self.moveNote = r.problems.prefix(3).joined(separator: " ") }
                    if !r.settings.isEmpty { MoveLive.reload() }
                    self.followMove()
                }
            }
        }
    }

    /// Undo for the profiles and settings: the profiles it made (unchanged since, their sessions' import undone first) and their empty
    /// folders go, the settings it took are put back.
    func undoMove() {
        guard !moveBusy, let r = moved, r.undone == nil else { return }
        moveNote = nil
        moveBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SessionsMove.undo(r.id) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.moveBusy = false
                switch result {
                case .failure(let err): self.moveNote = "\(err)"
                case .success(let u):
                    self.moved = u
                    if !u.left.isEmpty { self.moveNote = "Left as it is: " + u.left.prefix(3).joined(separator: "; ") + "." }
                    if !u.settings.isEmpty { MoveLive.reload() }
                    self.followMove()
                    // the profile it imported into was one it made, and is gone now: the page starts over
                    if self.intoEntry == nil { self.phase = .choose; self.into = self.profile; self.file = nil }
                }
            }
        }
    }

    /// The profiles file changed: the window's list takes it in and the plan is counted again. Into stays as the person chose it (unless
    /// that profile was taken back); the part's own profile is only suggested (`suggestedInto`).
    private func followMove() {
        model?.takeInOutsideChanges()
        guard let f = opened?.app else { return }
        movePlan = SessionsMove.plan(f, accounts: profiles)
        if !profiles.contains(where: { $0.id == into }) { setInto(profile) } else { recount() }
    }

    /// Make or take back is running: its key does nothing until it ends.
    @Published private(set) var moveBusy = false

    /// The file's own profile for the part chosen, when it is here and isn't Into: the page offers it ("Into Studio"), never sets it.
    var suggestedInto: AccountEntry? {
        guard let o = opened, partIndex < o.parts.count, let id = movePlan?.profile(forPart: o.parts[partIndex].dir), id != into else { return nil }
        return profiles.first { $0.id == id }
    }

    /// A move file whose profiles aren't made yet (and are to be): Close and import waits, or the part would go into a profile that isn't
    /// its own. Making them, or picking Leave them out, lets it go.
    var waitsForProfiles: Bool {
        guard let p = movePlan, !p.create.isEmpty, makeProfiles else { return false }
        return moved == nil || moved?.undone != nil
    }

    /// The made profiles (still made), for the done page.
    var madeProfiles: [SessionsMove.Made] { moved.map { r in r.undone == nil ? r.made.filter(\.written) : [] } ?? [] }

    func refresh() { counting?.refresh() }

    // MARK: Close and import

    var plan: SessionsRestore.Plan? { counting?.plan }
    var notYet: RestoreRunner.NotYet? { counting?.notYet }
    var sessionCount: Int { plan?.transcripts.count ?? 0 }
    var entryCount: Int { plan?.entries.count ?? 0 }
    /// "25 sessions · 12 entries" (the noun that is not zero): sessions and entries are never counted together as "sessions".
    var countWords: String? { ImportWords.counts(sessions: sessionCount, entries: entryCount) }
    var canImport: Bool {
        // (the staged backup, and the plan counted from it, must be for the profile Into shows: never the one before a retarget)
        guard phase == .ready, let s = staged, s.target == into, counting?.key.profile == into, let p = counting?.plan, p.refusal == nil, counting?.notYet == nil,
              !waitsForProfiles else { return false }
        return p.count > 0
    }

    /// The staged backup moves into the backups place and the Restore page's steps take over, starting at once.
    func commit() {
        guard canImport, let s = staged, let model else { return }
        do {
            let b = try SessionsImport.commit(s)
            let key = RestoreKey(profile: b.profile, backup: b.id, place: b.place.path, addMemory: addMemory, addSetup: addSetup, addConfig: addConfig, addTasks: addTasks)
            if let o = opened { SessionsImport.discard(o.work) }
            opened = nil; staged = nil; counting = nil
            phase = .running(key)
            model.restoring = key
            model.restoreRunner(key).importNow()
        } catch {
            note = "\(error)"
        }
    }

    // MARK: letting go

    private func discardWork() {
        if let o = opened { SessionsImport.discard(o.work) }
        opened = nil; staged = nil; counting = nil
        addMemory = false                               // "Add them" was a choice about that file; the next one starts with them left out
        addSetup = false
        addConfig = false; addTasks = false
        movePlan = nil; makeProfiles = true; takeSettings = false; moved = nil; moveNote = nil; moveBusy = false
    }

    /// cl_audit is quitting: the password goes and what is being opened is told to stop. Nothing is removed here (a big tree on the
    /// main thread would hold the quit): SessionsImport.shutDown takes the work folders away off the main thread, for two seconds
    /// at most, and the next launch's sweep takes what is left.
    func quit() {
        password = ""
        if isRunning { return }
        cancelOpening()
    }

    /// The page is left: what was unpacked for the preview goes (an import under way goes on).
    func leave() {
        password = ""                                   // no password stays in a runner that is kept for later
        if isRunning { return }
        cancelOpening()
        lock.lock(); generation += 1; lock.unlock()
        discardWork()
        if phase != .choose { phase = .choose }
        file = nil; note = nil
    }

    /// Renders only: the page as it looks at a step.
    func preview(_ p: Phase, file f: URL? = nil, opened o: SessionsImport.Opened? = nil, staged s: SessionsImport.Staged? = nil, counting c: RestoreRunner? = nil,
                 moved m: SessionsMove.Receipt? = nil) {
        if let m { moved = m }
        frozen = true
        phase = p; file = f ?? file; opened = o ?? opened; staged = s ?? staged; counting = c ?? counting
    }
}

// MARK: - What happens (the preview, and the same rows once it runs)

struct ImportHappens: View {
    let entry: AccountEntry
    @ObservedObject var runner: RestoreRunner
    /// Memory files of a file from elsewhere: nil on a page that only shows (the choice is made in the preview).
    var memory: ((Bool) -> Void)? = nil
    var addMemory = false
    /// Claude Code's setup in the file: the choice (nil on a page that only shows it).
    var setup: ((Bool) -> Void)? = nil
    /// The window's MCP settings and its scheduled tasks in the file: the choices (nil on a page that only shows them).
    var config: ((Bool) -> Void)? = nil
    var tasks: ((Bool) -> Void)? = nil
    @State private var showDiffer = false
    @State private var showTasks = false
    @State private var showMemory = false
    @Environment(\.face) private var face

    private var name: String { entry.name.isEmpty ? "this profile" : entry.name }
    private func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
    /// After an Undo the card tells what the import had added, not what it will do.
    private var undone: Bool { runner.phase == .undone }

    private func value(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(color ?? face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listKey(_ show: String, _ hide: String, _ on: Binding<Bool>) -> some View {
        Button(on.wrappedValue ? hide : show) { on.wrappedValue.toggle() }.buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize()
    }

    private func names(_ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(list.prefix(40).enumerated()), id: \.offset) { _, s in
                Text(RestorePage.shortName(s)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.muted)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            }
            if list.count > 40 { Text("…and \(list.count - 40) more").font(.system(size: 10.5)).foregroundStyle(face.muted) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(face.text.opacity(0.05)))
    }

    var body: some View {
        let r = runner.receipt
        let p = runner.plan
        SCard(title: undone ? "What the import had added" : "What happens", info: "Counted from the file against what is there now, by session id across every account folder of the window's Code-tab list (and transcripts by their path under \(entry.configDir)/projects). Import merges: it only adds what is missing, and nothing that is there is ever overwritten, deleted or moved. Sessions that a scheduled task ran come only with their task.") {
            if let why = p?.refusal {
                SRow(label: "Refused", first: true, stacked: true) { Text(why).font(.system(size: 12.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
            } else if let p {
                let differ = (r?.changed ?? p.changed) + p.partial
                SRow(label: "New", first: true, stacked: true) {
                    value(p.transcripts.isEmpty && p.entries.isEmpty
                          ? "none: everything in the file is here already"
                          : [p.transcripts.isEmpty ? nil : n(p.transcripts.count, "session", "sessions"),
                             p.files.isEmpty ? nil : n(p.files.count, "other file", "other files") + " with them",
                             p.entries.isEmpty ? nil : n(p.entries.count, "Code-tab entry", "Code-tab entries")]
                            .compactMap { $0 }.joined(separator: " · ") + (undone ? ": were added to \(name), and taken away again" : ": added to \(name)"))
                }
                SRow(label: "Already here", stacked: true) {
                    // (a zero part is left out; both zero says so once)
                    value(ImportWords.counts(sessions: p.backTranscripts, entries: p.backEntries).map { "\($0) with the same content (or longer here): skipped" } ?? "none")
                }
                SRow(label: "Grown on both sides", info: "There, and different from the file's copy: both grew on, or the file's is longer than the one here. \(name)'s copy stays, as it is; the file's copy is only listed (never overwritten, never completed).", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(differ.isEmpty ? "none" : "\(differ.count): \(name)'s copy stays, listed")
                        if !differ.isEmpty { listKey("Show the list", "Hide the list", $showDiffer); if showDiffer { names(differ) } }
                    }
                }
                SRow(label: "Code-tab entries", stacked: true) {
                    value(p.entries.isEmpty ? "none to add: the window stays as it is"
                          : undone ? "\(p.entries.count): were added to \(entry.windowDataWords) while it was closed, and taken away again"
                          : runner.phase == .done || runner.phase == .sidebar ? "\(p.entries.count): added to \(entry.windowDataWords) while it was closed"
                          : "\(p.entries.count): into \(entry.windowDataWords); \(entry.desktop == .standard ? "the usual Claude app" : "that window") closes and opens again")
                }
                if !undone, p.entries.isEmpty == false || p.taskSessions.isEmpty == false {
                    SRowLine(text: whereWords(p))
                }
                TasksRow(entry: entry, runner: runner, choose: tasks)
                SRow(label: "Scheduled tasks' sessions", info: "A session that a scheduled task ran (the entry's scheduledTaskId) comes in with its task when the task is added. When the task isn't added, the session is left out, with its transcript and the files in its folder, and the task's name is listed.", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(p.taskSessions.isEmpty ? "none left out"
                              : p.taskSessions.count == 1 ? "1 session: left out with its transcript (its task isn't added)"
                              : "\(p.taskSessions.count) sessions: left out with their transcripts (their tasks aren't added)")
                        if !p.taskSessions.isEmpty { listKey("Show the list", "Hide the list", $showTasks); if showTasks { names(p.taskSessions) } }
                    }
                }
                if !p.memoryFiles.isEmpty {
                    SRow(label: "Memory files", info: "Files a project keeps in its memory folder, which Claude Code loads into every session of that project. From any import file they are left out unless you add them (what a file says about where it came from can be forged, so it earns no trust); a file already there is never replaced either way.", stacked: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            value(addMemory ? "\(p.memoryFiles.count): added with the sessions" : "\(p.memoryFiles.count): left out")
                            if let memory {
                                Menu {
                                    Button("Leave them out") { memory(false) }
                                    Button("Add them") { memory(true) }
                                } label: { MenuWell(text: addMemory ? "Add them" : "Leave them out", fill: true) }
                                .faceMenuFill()
                            }
                            listKey("Show the list", "Hide the list", $showMemory); if showMemory { names(p.memoryFiles) }
                        }
                    }
                }
                SetupRow(entry: entry, runner: runner, imported: true, choose: setup)
                McpRow(entry: entry, runner: runner, imported: true, choose: config)
                SRow(label: "Folder not here", info: "Claude Code lists a session only where the folder it ran in exists. These are added anyway and show up once that folder is on this Mac.", stacked: true) {
                    value(runner.foldersMissing == 0 ? "none" : undone ? "\(runner.foldersMissing): were added, and taken away again" : "\(runner.foldersMissing): added, shown once that folder exists")
                }
                if !p.inUse.isEmpty {
                    SRow(label: "In use", stacked: true) { value("\(n(p.inUse.count, "transcript", "transcripts")) a running Claude Code session holds: left alone, listed") }
                }
                if !p.deletedSince.isEmpty {
                    SRow(label: "Deleted here", stacked: true) { value("\(p.deletedSince.count): the window deleted them here, so they stay deleted") }
                }
                if !undone && p.showsWouldDelete { SRow(label: "Would be deleted", info: p.retention.wouldDeleteInfo(file: tilde(CodeCleanup.file(entry.configDir)), comes: "comes in"), stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(p.wouldDeleteWords)
                        if p.canKeepLonger, runner.phase == .ready {
                            Button("Keep for 90 days") { runner.keepForDays(90) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                        }
                        if let f = runner.keepFailed { Text(f).font(.system(size: 10.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
                    }
                } }
                ForEach(Array(p.notes.enumerated()), id: \.offset) { _, s in SRowLine(text: s, color: face.caution) }
            } else {
                SRow(label: "What happens", first: true, stacked: true) { value("counting…") }
            }
        }
    }

    private func whereWords(_ p: SessionsRestore.Plan) -> String {
        let inUse = AccountNames.short(entry.seat?.email ?? "its account")
        if p.isMove {
            return "A move: each entry goes back into the folder of its own account, so it shows once you sign in there. "
                + (p.otherAccount > 0 ? "\(p.otherAccount) from an account \(name) doesn't have go into \(inUse)'s folder, written as a switch would place them." : "")
        }
        return "Entries go into \(entry.windowDataWords), in \(inUse)'s folder, where \(name) works now (open it from \(entry.desktop == .standard ? "the Dock or Applications" : "\(name)'s Dock icon")). The file's accounts are only fingerprints, so every entry is written as a switch would place it (the old account's error keys and Remote Control ids off)."
    }
}

// MARK: - the page

struct ImportPage: View {
    let entry: AccountEntry
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: ImportRunner
    var width: CGFloat = 980
    @Environment(\.face) private var face

    private var target: AccountEntry { runner.intoEntry ?? entry }
    private var name: String { target.name.isEmpty ? "this profile" : target.name }

    var body: some View {
        if case .running(let key) = runner.phase, let e = runner.intoEntry {
            VStack(alignment: .leading, spacing: 12) {
                RestorePage(entry: e, key: key, model: model, runner: model.restoreRunner(key), width: width)
                // a move: what is left to do on this Mac for each profile the import made (sign-ins, the Dock, the tasks)
                if !runner.madeProfiles.isEmpty { MoveSteps(model: model, runner: runner, width: width) }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(runner.opened?.move == true ? "Move from another Mac" : "Import into \(name)").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
                topBar
                // (a move: its card; once its profiles are made, what is left to do for them, at once, not only after the sessions)
                let steps: [AnyView] = runner.madeProfiles.isEmpty ? [] : [AnyView(MoveSteps(model: model, runner: runner, width: width))]
                let first: [AnyView] = runner.movePlan != nil || runner.moved != nil ? [AnyView(fromCard), AnyView(moveCard)] + steps + [AnyView(happensCard)] : [AnyView(fromCard), AnyView(happensCard)]
                SettingsColumns(width: width, groups: [first, [AnyView(staysCard), AnyView(sidebarCard), AnyView(footerCard)]])
            }
            .task(id: entry.id) { runner.refresh() }
            .onDisappear { runner.leave() }
        }
    }

    // MARK: the line at the top

    private var topBar: some View {
        let t = topLine
        return DisplayWindow(text: t.text, dim: DisplayWindow.narrowed(t.dim, width: width), tone: t.tone, height: 24, size: 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topLine: (text: String, dim: String?, tone: DisplayWindow.Tone) {
        switch runner.phase {
        case .choose: return ("Import", "· choose a file · nothing written", .normal)
        case .password(let why): return why == nil ? ("Password", "· an encrypted disk image · nothing written", .amber) : ("Password", "· not right · nothing written", .warn)
        case .opening(let s): return ("Reading ●", "· \(s) · nothing written into \(name)", .mint)
        case .refused: return ("Refused", "· nothing written", .warn)
        case .ready:
            if runner.plan?.refusal != nil { return ("Refused", "· nothing written", .warn) }
            if runner.notYet != nil { return ("Not yet", "· one thing first · nothing written", .amber) }
            return ("Preview", "· nothing written yet · nothing is ever overwritten", .normal)
        case .running: return ("Importing ●", nil, .mint)
        }
    }

    // MARK: From

    private func value(_ s: String, color: Color? = nil) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(color ?? face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fromCard: some View {
        SCard(title: "From", info: "An export made by Export… in Settings ▸ a profile ▸ Sessions: a .zip, or an encrypted .dmg that asks for its password. The file is treated as untrusted: it is read by its directory before anything is unpacked, unpacked into a private folder, and refused as a whole, with nothing written into a profile, if anything in it is not exactly what an export is (a link, a path outside its folder, a sign-in, a file its manifest doesn't name, a size that differs, a newer format).") {
            SRow(label: "File", first: true, stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    if let w = runner.fileWords { value(w) }
                    HStack(spacing: 8) {
                        Button(runner.file == nil ? "Choose…" : "Choose another…") { runner.chooseFile() }
                            .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(runner.isOpening)
                        if runner.isOpening { Button("Cancel") { runner.cancelOpening() }.buttonStyle(.pill(FaceTheme.ledRed, compact: true)).fixedSize() }
                    }
                }
            }
            if case .password(let why) = runner.phase {
                SRow(label: "Password", info: "Typed here, handed to macOS's hdiutil on its standard input, and never stored, shown again or logged.", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        WellSecure(placeholder: "The image's password", text: $runner.password)
                        if let why { Text(why).font(.system(size: 10.5)).foregroundStyle(face.danger) }
                        Button("Open the image") { runner.open() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize().disabled(runner.password.isEmpty)
                    }
                }
            }
            if case .refused(let why) = runner.phase {
                SRow(label: "Refused", stacked: true) { Text(why).font(.system(size: 12.5)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
                SRowLine(text: "Nothing was written into any profile, and nothing of the file is left unpacked. A file that isn't exactly an export is refused whole rather than guessed at.")
            }
            if let o = runner.opened, o.parts.count > 1 {
                SRow(label: "Profile in the file") {
                    Menu {
                        ForEach(o.parts.indices, id: \.self) { i in Button(o.parts[i].name) { runner.setPart(i) } }
                    } label: { MenuWell(text: o.parts[min(runner.partIndex, o.parts.count - 1)].name, fill: true) }
                    .faceMenuFill().disabled(runner.isOpening)
                }
            }
            SRow(label: "Into") {
                Menu {
                    ForEach(runner.profiles, id: \.id) { p in Button(p.name.isEmpty ? p.id : p.name) { runner.setInto(p.id) } }
                } label: { MenuWell(text: name, fill: true) }
                .faceMenuFill().disabled(runner.isOpening)
            }
            // a move: the part's own profile is offered, never chosen for the person
            if let s = runner.suggestedInto {
                VStack(alignment: .leading, spacing: 6) {
                    line("This part is \(s.name)'s in the file, and \(s.name) is here: its sessions belong there.")
                    Button("Into \(s.name)") { runner.setInto(s.id) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                }
                .padding(.vertical, 4)
            }
            SRowLine(text: "The file is unpacked as a backup of \(name) first, then restored from: the same rules as Restore.")
        }
    }

    // MARK: cl_audit's profiles and settings (a move)

    private func line(_ s: String, _ color: Color? = nil) -> some View {
        Text(s).font(.system(size: 10.5)).foregroundStyle(color ?? face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var moveCard: some View {
        SCard(title: "cl_audit's profiles", info: "The file holds cl_audit's own record of its profiles (name, look, Dock place, accounts and the one in use) and its General and backup settings. Import makes the profiles that aren't here and never changes one that is. A profile counts as already here when it has one of the file's accounts (or, for a file with no accounts, the same name). A made profile works in folders of its own, whatever the file says. It is made with its accounts, looks and settings, but not signed in: after the import, sign in to each account with Add account. No Dock icon yet: you put it in the Dock after the import. Nothing runs. Your settings stay unless you take the file's; a backups folder that isn't on this Mac is never taken. Take back the profiles it made undoes exactly what was made.") {
            if runner.opened?.move == true {
                SRowLine(text: "A move from another Mac: the file keeps the real accounts, so the entries and tasks go back under them.")
            }
            if let r = runner.moved, r.undone == nil {
                SRow(label: "Done", first: true, stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(MoveWords.done(r))
                        line("They aren't signed in and have no Dock icon yet: what to do next for each is listed below.")
                        Button("Take back the profiles it made") { runner.undoMove() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(runner.moveBusy)
                    }
                }
            } else if let p = runner.movePlan {
                SRow(label: "Profiles", first: true, stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(MoveWords.profiles(p))
                        if !p.create.isEmpty {
                            Menu {
                                Button("Make them") { runner.makeProfiles = true }
                                Button("Leave them out") { runner.makeProfiles = false }
                            } label: { MenuWell(text: runner.makeProfiles ? "Make them" : "Leave them out", fill: true) }
                            .faceMenuFill()
                        }
                        ForEach(Array(MoveWords.profileNotes(p).enumerated()), id: \.offset) { _, s in line(s) }
                    }
                }
                SRow(label: "Settings", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        value(MoveWords.settings(p, take: runner.takeSettings))
                        if !p.takeable.isEmpty {
                            Menu {
                                Button("Keep this Mac's") { runner.takeSettings = false }
                                Button("Take the file's") { runner.takeSettings = true }
                            } label: { MenuWell(text: runner.takeSettings ? "Take the file's" : "Keep this Mac's", fill: true) }
                            .faceMenuFill()
                        }
                        ForEach(Array(MoveWords.settingLines(p).prefix(20).enumerated()), id: \.offset) { _, s in line(s) }
                    }
                }
                if let key = MoveWords.key(p, take: runner.takeSettings, create: runner.makeProfiles) {
                    Button(key) { runner.applyMove() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                        .disabled(runner.moveBusy)
                    line("Do this first. Then the page offers the part's own profile for Into, and Close and import puts its sessions there.")
                }
            }
            if let n = runner.moveNote { SRowLine(text: n, color: face.caution) }
        }
    }

    // MARK: What happens, Stays as it is

    private var happensCard: some View {
        Group {
            if let c = runner.counting, runner.phase == .ready {
                ImportHappens(entry: target, runner: c, memory: { runner.setMemory($0) }, addMemory: runner.addMemory, setup: { runner.setSetup($0) },
                              config: { runner.setConfig($0) }, tasks: { runner.setTasks($0) })
            } else {
                SCard(title: "What happens", info: "Counted from the file against what is there now, once the file is read.") {
                    SRow(label: "Nothing yet", first: true, stacked: true) {
                        value({ switch runner.phase { case .opening: return "reading the file…"; case .refused: return "the file was refused"; default: return "choose a file first" } }())
                    }
                }
            }
        }
    }

    private var sidebarCard: some View {
        SCard(title: "Sidebar", info: "The window keeps its sidebar's groups, order and pins per account. The file has the records of the groups its sessions sat in; one Return in a helper session files the imported sessions in groups of those names and pins them again. A group name from a file is cleaned first (letters, digits, spaces and - _ . , ( ) & ' only, at most 40 characters), since it reaches that session's prompt.") {
            SRow(label: "Groups", first: true, stacked: true) {
                value(runner.counting.map { _ in ImportWords.arrangement(runner.plan?.sidebar, hasEntries: runner.entryCount > 0) } ?? "counting…")
            }
        }
    }

    private var staysCard: some View {
        let inUse = AccountNames.short(target.seat?.email ?? "its account")
        return SCard(title: "Stays as it is", info: "Import only adds what is missing. The account, the sign-ins and claude.ai are not part of it; a file that is here (MCP settings, settings.json, a task file) is never replaced or merged into.") {
            if runner.opened?.move == true {
                SRow(label: "Account", first: true) { rowValue("\(name) keeps the accounts it has; the import doesn't change them") }
                SRow(label: "Sign-ins") { rowValue("Never travel: sign in again on this Mac") }
            } else {
                SRow(label: "Account", first: true) { rowValue("\(name) stays on \(inUse): Switch back changes that") }
                SRow(label: "Sign-ins") { rowValue("Never in an export, never written") }
            }
            SRow(label: "MCP") { rowValue("Yours stay; the file's are added only if none is here and you pick Add them") }
            SRow(label: "settings.json") { rowValue("Yours stay; one is added only if none is here and you pick Add them") }
            SRow(label: "Scheduled tasks") { rowValue("A task file that is here stays as it is; the file's tasks come only if you pick Add them, paused") }
            SRow(label: "claude.ai") { rowValue("Chats and Projects") }
        }
    }

    private func rowValue(_ s: String) -> some View {
        Text(s).font(.system(size: 12.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cancel, Close and import

    private var importLabel: String {
        guard let p = runner.plan else { return "Close and import" }
        if p.refusal != nil { return "Refused" }
        if p.count == 0 { return "Nothing to import" }
        // the key says the larger part only; the other is a small line under it (a long key pushes its card out of its column)
        let what = runner.sessionCount > 0 ? ImportWords.counts(sessions: runner.sessionCount, entries: 0)
            : ImportWords.counts(sessions: 0, entries: runner.entryCount) ?? "\(p.count) \(p.count == 1 ? "file" : "files")"
        return (p.windowNeeded ? "Close and import " : "Import ") + (what ?? "")
    }

    /// "and 12 Code-tab entries", under the key when the import has both.
    private var importAlso: String? {
        guard runner.canImport, runner.sessionCount > 0, runner.entryCount > 0 else { return nil }
        return "and \(runner.entryCount) Code-tab \(runner.entryCount == 1 ? "entry" : "entries")"
    }

    private var footerCard: some View {
        SCard(title: runner.notYet != nil ? "First" : "Steps", info: "Import closes only the target profile's Claude window (about half a minute) when entries come in, adds what is missing with a receipt kept as it goes (Stop, keep what's back), opens the window again and arranges the sidebar with one Return, as Restore does. Undo last import, under the profile's Sessions, takes back exactly what it added.") {
            if let nyt = runner.notYet {
                HStack(alignment: .top, spacing: 10) {
                    ZStack {
                        Circle().stroke(FaceTheme.ledAmber, lineWidth: 1.2)
                        Text("1").font(.system(size: 11, weight: .semibold)).foregroundStyle(FaceTheme.ledAmber)
                    }
                    .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(nyt.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text).fixedSize(horizontal: false, vertical: true)
                        Text(nyt.words).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                        if let k = nyt.switchKey { Button("Open the switch") { model.showSwitch(k) }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize().padding(.top, 2) }
                    }
                }
                .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                stepRow(1, "\(target.windowWordsCap) closes", runner.plan?.windowNeeded == false ? "Nothing in the window comes in, so it needn't close." : "Only that window, about half a minute; your other Claude windows stay open.")
                stepRow(2, "What's listed is added", "Merged by the rules on the left; nothing overwritten.")
                stepRow(3, "The window opens; the sidebar, as before", "Press Return in the session that opens.")
            }
            if let note = runner.note { SRowLine(text: note, color: face.danger) }
            // a move whose profiles aren't made yet: the key waits, and says why
            if runner.waitsForProfiles, let p = runner.movePlan {
                SRowLine(text: "Make the profiles first: press \(MoveWords.key(p, take: runner.takeSettings, create: true) ?? "Make the profiles") (or pick Leave them out), or these sessions would go into \(name).",
                         color: face.caution)
            }
            // Cancel and the key on one line when they fit; else the key above Cancel (neither is ever cut off)
            let cancel = Button("Cancel") { model.selection = entry.id }.buttonStyle(.plain).foregroundStyle(face.muted)
            let key = Button(importLabel) { runner.commit() }.buttonStyle(.pill(FaceTheme.ledOn, compact: true)).disabled(!runner.canImport).fixedSize()
            // the small line "and 12 Code-tab entries" belongs to the key: right under it, on the key's trailing edge beside Cancel,
            // directly under it when the key sits above Cancel
            let also = importAlso.map { Text($0).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize() }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    cancel; Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 3) { key; also }
                }
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) { key; also }
                    cancel
                }
            }
            .padding(.top, 8)
            SRowLine(text: "Undo last import, under \(name)'s Sessions afterwards, removes exactly what it added.").padding(.top, 6)
        }
    }

    private func stepRow(_ i: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().stroke(face.muted.opacity(0.6), lineWidth: 1.2)
                Text("\(i)").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.muted)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(face.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - a move's done page: what is left to do on this Mac

/// Under the import's own steps, for each profile the import made: the accounts to sign in to (sign-ins never travel), its Dock icon
/// (a step the person takes: nothing put it in the Dock), and its scheduled tasks, which came paused.
struct MoveSteps: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: ImportRunner
    var width: CGFloat = 980
    @Environment(\.face) private var face

    /// How many tasks this import added to the profile (paused): only the profile it is importing into knows yet.
    private func tasks(_ id: String) -> Int {
        guard case .running(let key) = runner.phase, key.profile == id else { return 0 }
        return model.restoreRunner(key).receipt?.tasksAddedCount ?? 0
    }

    var body: some View {
        SCard(title: "On this Mac, next", info: "A profile made by the import is made with its accounts, looks and settings, but not signed in: sign in to each account with Settings ▸ the profile ▸ Claude Code ▸ Accounts ▸ Add account. No Dock icon yet: you put it in the Dock (Settings ▸ the profile ▸ Dock icon ▸ Usage in the Dock). Its scheduled tasks come paused: turn each on in its Claude window, under Scheduled tasks, once it is signed in. Its sessions: Settings ▸ the profile ▸ Sessions ▸ Import…, the same file.") {
            ForEach(Array(runner.madeProfiles.enumerated()), id: \.offset) { i, m in
                SRow(label: m.name, first: i == 0, stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(MoveWords.steps(m, tasks: tasks(m.id)).enumerated()), id: \.offset) { _, s in
                            Text(s).font(.system(size: 11.5)).foregroundStyle(face.soft).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if m.inDock, let e = model.accounts.first(where: { $0.id == m.id }), e.iconHidden {
                            Button("Put \(m.name) in the Dock") { model.setUsageInDock(m.id, true) }
                                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(model.dockRestarting != nil)
                        }
                    }
                }
            }
            // (before the sessions are imported, the profiles card above has the same key)
            if runner.isRunning {
                SRow(label: "Undo", stacked: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Undo this import (above) first; then this takes back the profiles it made, their empty folders and the settings it took.")
                            .font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Take back the profiles it made") { runner.undoMove() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(runner.moveBusy)
                        if let n = runner.moveNote { Text(n).font(.system(size: 10.5)).foregroundStyle(face.caution).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
    }
}
