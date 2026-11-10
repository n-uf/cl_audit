// Move checks for cl_audit: a move to another Mac (format 4). Sources/SessionsMove.swift (cl_audit's own profiles and settings: made,
// read and cleaned, the plan, made with a receipt, Undo), SessionsExport.swift (the move keeps the real ids, only in an encrypted image;
// every other export fingerprints as before), SessionsImport.swift (cl_audit.json and a move's parts: what a file may hold),
// SessionsRestore.swift / SessionsRestoreWindow.swift (a move's entries and task files into their own account's folder), and the pages'
// words (ExportWords, MoveWords).
//
// Two throwaway homes: A (the old Mac) at Checks/.work/move/home, and B (the new Mac) at Checks/.work/move/b/home, a second run of this
// same program (MOVE_ROLE=b) that starts with nothing at all in it. A makes two profiles (fake accounts, sessions, setup, MCP settings,
// scheduled tasks) and exports them as a move; B imports the file: the profiles are made with their accounts and settings, nothing is
// signed in, the entries and tasks land in their real account folders (tasks paused), setup and MCP settings stay out until asked; a
// second import changes nothing; Undo takes back exactly what was added. Then the rest, in A: a move can't be a zip, other exports
// still fingerprint, hostile profiles files and doctored images, the formats.
// Nothing here opens an app, the Dock or Terminal: the Dock's writer and the Keychain's tool are replaced by stand-ins that count
// calls (each must stay at zero), and the profiles file's change is announced to nobody. Fake data only: example.com addresses,
// zero-pattern ids, made-up values.

import AppKit
import Foundation

setbuf(stdout, nil)
let role = ProcessInfo.processInfo.environment["MOVE_ROLE"] ?? "a"
let home = NSHomeDirectory()
guard (role == "a" && home.hasSuffix("/Checks/.work/move/home")) || (role == "b" && home.hasSuffix("/Checks/.work/move/b/home")) else {
    print("refusing: HOME is \(home) for role \(role)"); exit(2)
}
// the file goes between the two homes in Checks/.work/move/shared (made by role A)
let sharedDir = role == "a" ? (home as NSString).deletingLastPathComponent + "/shared" : ((home as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/shared"

// the seams: no real preferences, no Dock, no Keychain, nobody told about the profiles file
BackupPrefs.store = MemoryPrefs()
SessionsMove.prefs = MemoryPrefs()
Store.announce = {}
SettingsModel.applyInstalls = false
SettingsModel.followsDock = false
var dockCalls = 0, securityCalls = 0
DockWriter.backend = DockWriter.Backend(read: { dockCalls += 1; return DockWriter.Lists(pinned: [], recent: []) }, write: { _ in dockCalls += 1 }, restart: { dockCalls += 1 })
Login.runSecurity = { _ in securityCalls += 1; return (44, Data()) }
SessionsRestore.runningSessions = { [] }

let fm = FileManager.default
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (\(role), line \(line)): \(what)") }
}
func sid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func write(_ path: String, _ text: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8))
}
func files(_ dir: String) -> [String] {
    var out: [String] = []
    if let e = fm.enumerator(atPath: dir) { for case let r as String in e { var isDir: ObjCBool = false; if fm.fileExists(atPath: dir + "/" + r, isDirectory: &isDir), !isDir.boolValue { out.append(r) } } }
    return out.sorted()
}
func everything(_ dir: String) -> [String] { ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).sorted() }
func json(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
func holds(_ dir: String, _ s: String) -> [String] { files(dir).filter { (fm.contents(atPath: dir + "/" + $0) ?? Data()).range(of: Data(s.utf8)) != nil } }
/// Whether one file holds these bytes.
func has(_ path: String, _ s: String) -> Bool { (fm.contents(atPath: path) ?? Data()).range(of: Data(s.utf8)) != nil }

let pw = "move-test-password-not-secret"
let envValue = "mcp-env-not-a-real-secret-m0"
let settingsEnvValue = "settings-env-not-a-real-secret-m0"
let a1 = "move-1@example.com", a2 = "move-2@example.com", a3 = "move-3@example.com"
let moveFile = sharedDir + "/cl_audit all profiles move.dmg"

// ================================================================== role B: the new Mac
if role == "b" {
    MainActor.assumeIsolated {
        let place = BackupPrefs.placeURL
        check(!Store.exists && everything(home).isEmpty, "B: a fresh home, nothing in it: \(everything(home).prefix(5))")
        guard let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: place) else { check(false, "B: the move file opens"); return }
        check(o.move && o.app != nil && o.export.version == 4 && o.parts.count == 2 && o.parts.allSatisfy { $0.manifest.move == true && $0.manifest.version == 4 },
              "B: the file is a move of format 4, with cl_audit's profiles and two parts")
        let f = o.app!
        let plan = SessionsMove.plan(f, accounts: Store.load())
        check(plan.move && plan.create.map(\.name) == ["Work", "Home"] && plan.here.isEmpty && plan.notMade.isEmpty, "B: the plan makes Work and Home, in their order: \(plan.create.map(\.name))")
        let work = plan.create.first { $0.name == "Work" }, homeP = plan.create.first { $0.name == "Home" }
        check(work?.entry.seat?.account == sid(1) && work?.entry.seat?.organization == sid(2) && work?.entry.seat?.email == a1
              && work?.entry.standby.map { $0.seat?.account } == [sid(3)] && work?.entry.standby.first?.email == a2 && work?.entry.standby.first?.configDir == nil
              && work?.signIns == [a1, a2] && homeP?.signIns == [a3],
              "B: Work keeps its two accounts (the one in use first, the other standing by with no kept sign-in), Home its one; each listed to sign in")
        check(work?.entry.color == .teal && work?.entry.style == .rings && work?.entry.pollMinutes == 7 && work?.entry.notifyPercent == 80 && work?.entry.menuBar == true
              && work?.entry.configDir == "~/.claude-work" && work?.entry.desktop == .separate && work?.entry.desktopDataDir == "~/Library/Application Support/Claude-work",
              "B: Work's look, settings and folders come as they were")
        check(plan.create.allSatisfy { $0.entry.iconHidden } && work?.inDock == true && homeP?.inDock == false,
              "B: no Dock icon for a made profile (Usage in the Dock off); the done page knows Work had one")
        let diffs = Dictionary(uniqueKeysWithValues: plan.settings.map { ($0.key, $0) })
        check(diffs["face"]?.fileWords == "Silver" && diffs["face"]?.hereWords == "Std" && diffs[Privacy.key]?.fileWords == "hidden" && diffs[BackupPrefs.lastKey]?.file == "7"
              && diffs[BackupPrefs.placeKey]?.problem != nil && plan.settings.count == 4,
              "B: 4 settings differ (Face, Emails, Backups kept, Backups folder), the backups folder can't be taken (not on this Mac): \(plan.settings.map { "\($0.key)=\($0.file)" })")
        check(MoveWords.settingLines(plan).contains("Face: Std here, Silver in the file") && MoveWords.key(plan, take: true, create: true) == "Make 2 profiles and take 3 settings"
              && MoveWords.key(plan, take: false, create: true) == "Make 2 profiles",
              "B: the words: each difference with both values; the key: \(MoveWords.key(plan, take: true, create: true) ?? "none")")

        // nothing is written until the person does it
        check(!Store.exists && !fm.fileExists(atPath: expand("~/.claude-work")), "B: opening and planning write no profile and no folder")
        let r = try! SessionsMove.apply(plan, takeSettings: true, file: o.fileName)
        let after = Store.load()
        check(after.map(\.name) == ["Work", "Home"] && after.allSatisfy { $0.iconHidden } && after.first?.seat?.account == sid(1),
              "B: the two profiles are made in cl_audit's profiles file, in order, Usage in the Dock off: \(after.map(\.name))")
        check(fm.fileExists(atPath: expand("~/.claude-work")) && fm.fileExists(atPath: expand("~/Library/Application Support/Claude-work")) && fm.fileExists(atPath: expand("~/.claude-home"))
              && everything(expand("~/.claude-work")).isEmpty, "B: their folders are made, empty")
        check(SessionsMove.current(SessionsMove.known.first { $0.key == "face" }!) == "silver" && BackupPrefs.keepLast == 7 && (BackupPrefs.store.string(forKey: BackupPrefs.placeKey) ?? "") == "",
              "B: the file's settings are taken, but not a backups folder that isn't on this Mac")
        check(r.made.allSatisfy(\.written) && r.settings.count == 3 && SessionsMove.load(r.id)?.made.count == 2 && r.made.first { $0.name == "Work" }?.folders.isEmpty == false,
              "B: the receipt lists the profiles, the folders it made and the settings it took")

        // each part into its profile: the entries and tasks into their own account's folder; setup and MCP left out until asked
        var receipts: [String] = []
        for part in o.parts {
            guard let id = plan.profile(forPart: part.dir), let e = Store.load().first(where: { $0.id == id }) else { check(false, "B: part \(part.dir) has its profile"); continue }
            let st = try! SessionsImport.materialize(o, part: part, target: id)
            check(SessionsBackup.load(profile: id, id: st.id, place: st.stage)?.move == true, "B: \(e.name)'s staged backup stays a move")
            let t = SessionsRestore.Target(e)
            let pDefault = SessionsRestore.plan(t, st.backup)
            check(pDefault.isMove && pDefault.taskPlan.leftOut && pDefault.setup.leftOut && pDefault.tasks.isEmpty && pDefault.setupPieces.isEmpty && pDefault.configPieces.isEmpty,
                  "B: \(e.name): by default the tasks, setup and MCP settings stay out (Add them is the person's)")
            let b = try! SessionsImport.commit(st, place: place)
            let p = SessionsRestore.plan(t, b, addTasks: true)
            check(p.refusal == nil && p.entries.allSatisfy { !$0.rewrite } && p.ownFolders == p.entries.count, "B: \(e.name): every entry goes to its own account's folder, as it was")
            let rr = try! SessionsRestore.run(t, b, addTasks: true, windowClosed: { true })
            receipts.append(rr.id)
        }
        let wd = expand("~/Library/Application Support/Claude-work/claude-code-sessions"), hd = expand("~/Library/Application Support/Claude-home/claude-code-sessions")
        check(fm.fileExists(atPath: "\(wd)/\(sid(1))/\(sid(2))/local_\(sid(10)).json") && fm.fileExists(atPath: "\(wd)/\(sid(3))/\(sid(4))/local_\(sid(11)).json")
              && fm.fileExists(atPath: "\(hd)/\(sid(5))/\(sid(6))/local_\(sid(12)).json"),
              "B: Work's entries in the folders of its two accounts, Home's in its own: \(everything(wd))")
        let t1 = SessionsRestore.taskList(fm.contents(atPath: "\(wd)/\(sid(1))/\(sid(2))/scheduled-tasks.json") ?? Data())
        let t2 = SessionsRestore.taskList(fm.contents(atPath: "\(wd)/\(sid(3))/\(sid(4))/scheduled-tasks.json") ?? Data())
        check(t1.map { $0["id"] as? String } == ["nightly-digest"] && t2.map { $0["id"] as? String } == ["standby-report"] && (t1 + t2).allSatisfy { $0["enabled"] as? Bool == false }
              && fm.fileExists(atPath: expand("~/.claude-work/scheduled-tasks/nightly-digest/SKILL.md")),
              "B: each account's task file into its own folder, every task paused, with its prompt")
        check(fm.fileExists(atPath: expand("~/.claude-work/projects/-w-project/\(sid(110)).jsonl")) && !fm.fileExists(atPath: expand("~/.claude-work/CLAUDE.md"))
              && !fm.fileExists(atPath: expand("~/.claude-work/settings.json")) && !fm.fileExists(atPath: expand("~/Library/Application Support/Claude-work/claude_desktop_config.json")),
              "B: the transcripts are in; setup (CLAUDE.md, settings.json) and the MCP settings are not (left out by default)")
        // no sign-in anywhere, nothing of the Keychain, no Dock
        let signIns = everything(home).filter { let n = ($0 as NSString).lastPathComponent.lowercased(); return n.hasPrefix(".claude.json") || n.contains("credential") }
        // (the staged backup in cl_audit's own folder keeps the image's settings.json whole, as every import's does: that is how it can be
        // added later; nothing outside that folder holds its env value)
        check(signIns.isEmpty && securityCalls == 0 && dockCalls == 0 && holds(home, settingsEnvValue).filter { !$0.hasPrefix("Library/Application Support/usage-n-uf/") }.isEmpty,
              "B: no sign-in anywhere (no .claude.json, no credentials), the Keychain never asked, the Dock never written: \(signIns), \(securityCalls), \(dockCalls)")
        SessionsImport.discard(o.work)

        // a second import changes nothing
        let before2 = everything(home).filter { !$0.contains("usage-n-uf") }
        if let o2 = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: place) {
            let plan2 = SessionsMove.plan(o2.app!, accounts: Store.load())
            check(plan2.create.isEmpty && plan2.here.map(\.name) == ["Work", "Home"] && plan2.here.allSatisfy { $0.why == "the same account" } && plan2.settings.count == 1,
                  "B: a second import: both profiles are here already (by their account), only the backups folder still differs: \(plan2.settings.map(\.key))")
            for part in o2.parts {
                guard let id = plan2.profile(forPart: part.dir), let e = Store.load().first(where: { $0.id == id }) else { continue }
                let st = try! SessionsImport.materialize(o2, part: part, target: id)
                let p = SessionsRestore.plan(SessionsRestore.Target(e), st.backup, addTasks: true)
                check(p.count == 0 && p.backEntries > 0 && (!p.taskPlan.present || p.taskPlan.status == .here), "B: \(e.name): nothing to write the second time (entries back, task files here)")
            }
            SessionsImport.discard(o2.work)
        } else { check(false, "B: the move file opens a second time") }
        check(everything(home).filter { !$0.contains("usage-n-uf") } == before2, "B: …and nothing outside cl_audit's own folder changed")

        // Undo: the profiles stay while their sessions' import is in place; then everything goes, exactly
        let early = try! SessionsMove.undo(r.id)
        check(early.undone == nil && Store.load().count == 2 && early.left.contains { $0.contains("import is still in place") }, "B: Undo of the profiles waits for their sessions' import to be undone: \(early.left)")
        for id in receipts { _ = try! SessionsRestore.undo(id, windowClosed: { true }) }
        let u = try! SessionsMove.undo(r.id)
        check(u.undone != nil && Store.load().isEmpty && !fm.fileExists(atPath: expand("~/.claude-work")) && !fm.fileExists(atPath: expand("~/Library/Application Support/Claude-work"))
              && !fm.fileExists(atPath: expand("~/.claude-home")),
              "B: Undo takes back the profiles and the folders it made: \(Store.load().map(\.name)), left \(u.left)")
        check(SessionsMove.prefs.object(forKey: "face") == nil && BackupPrefs.store.object(forKey: BackupPrefs.lastKey) == nil,
              "B: …and the settings are as they were (nothing stored)")
        // (cl_audit's own folder, and the lock it shares with claude-transplant so one move of sessions runs at a time, stay)
        let leftOver = everything(home).filter { !$0.hasPrefix("Library/Application Support/usage-n-uf") && !$0.hasPrefix("Library/Application Support/claude-transplant") && $0 != "Library/Application Support" && $0 != "Library" }
        check(leftOver.isEmpty, "B: nothing outside cl_audit's own folder is left: \(leftOver.prefix(6))")

        // ---- the Import page's runner (round 1): Close and import waits for the profiles; Make runs once however often it is pressed;
        // Into stays the person's (the part's own profile is only offered); the steps are there as soon as the profiles are made
        func settle(_ secs: Double = 60, _ done: () -> Bool) { let end = Date().addingTimeInterval(secs); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }
        var laptop = AccountEntry(id: "laptop", name: "Laptop", label: "LAPTOP", configDir: "~/.claude-laptop")
        laptop.desktop = .separate; laptop.desktopDataDir = "~/Library/Application Support/Claude-laptop"; laptop.seat = Seat(account: sid(50), organization: sid(51), email: "laptop@example.com")
        try! Store.save([laptop])
        let model = SettingsModel()
        let ir = model.importRunner(for: "laptop")
        ir.setFile(URL(fileURLWithPath: moveFile)); ir.password = pw; ir.open()
        settle { ir.phase == .ready && ir.movePlan != nil && ir.counting?.plan != nil }
        check(ir.movePlan?.create.count == 2 && ir.makeProfiles && ir.waitsForProfiles && !ir.canImport && ir.into == "laptop",
              "page: a move file with profiles to make: Close and import waits; Into stays Laptop")
        ir.makeProfiles = false
        check(!ir.waitsForProfiles, "page: …Leave them out lets it go")
        ir.makeProfiles = true
        let before = SessionsMove.receipts().count
        ir.applyMove(); ir.applyMove()
        check(ir.moveBusy, "page: Make is busy while it runs")
        settle { ir.moved != nil && !ir.moveBusy && ir.counting?.plan != nil }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        check(SessionsMove.receipts().count == before + 1 && Store.load().count == 3, "page: pressed twice, made once: one receipt (\(SessionsMove.receipts().count - before))")
        check(!ir.waitsForProfiles && ir.into == "laptop" && ir.suggestedInto?.name == "Work" && ir.madeProfiles.count == 2,
              "page: after Make, Into is still Laptop, Work is offered, and the steps for both made profiles are there at once")
        // the retarget (round 2): while the staged backup is still Laptop's, Close and import is off; it comes back for Work once it lands
        ir.setInto("work")
        check(!ir.canImport && ir.into == "work", "page: right after Into changes, Close and import is off (the staged backup is still the old profile's)")
        settle { ir.staged?.target == "work" && ir.counting?.key.profile == "work" && ir.counting?.plan != nil }
        check(ir.canImport && ir.counting?.key.profile == "work", "page: …and on again once it is Work's, counted for Work")
        ir.setInto("laptop")
        settle { ir.staged?.target == "laptop" && ir.counting?.plan != nil }
        ir.undoMove()
        settle { ir.moved?.undone != nil }
        check(Store.load().map(\.id) == ["laptop"], "page: Take back the profiles it made")
        ir.leave()
    }
    print("checks: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

// ================================================================== role A: the old Mac, then the rest
MainActor.assumeIsolated {
    let place = BackupPrefs.placeURL
    try? fm.removeItem(atPath: sharedDir); try! fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
    let out = home + "/out"; try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)

    // ---- two profiles: Work (in use sid(1)/sid(2), standing by sid(3)/sid(4)) and Home (sid(5)/sid(6)), each with its own window
    var work = AccountEntry(id: "work", name: "Work", label: "WORK", configDir: "~/.claude-work")
    work.desktop = .separate; work.desktopDataDir = "~/Library/Application Support/Claude-work"
    work.seat = Seat(account: sid(1), organization: sid(2), email: a1)
    work.standby = [StandbyAccount(email: a2, seat: Seat(account: sid(3), organization: sid(4), email: a2), id: "s1")]
    work.color = .teal; work.style = .rings; work.pollMinutes = 7; work.notifyPercent = 80; work.menuBar = true
    var homeE = AccountEntry(id: "home", name: "Home", label: "HOME", configDir: "~/.claude-home")
    homeE.desktop = .separate; homeE.desktopDataDir = "~/Library/Application Support/Claude-home"
    homeE.seat = Seat(account: sid(5), organization: sid(6), email: a3); homeE.iconHidden = true
    try! Store.save([work, homeE])
    let wd = expand(work.desktopDataDir), hd = expand(homeE.desktopDataDir), wc = expand(work.configDir), hc = expand(homeE.configDir)
    let w1 = "\(wd)/claude-code-sessions/\(sid(1))/\(sid(2))", w2 = "\(wd)/claude-code-sessions/\(sid(3))/\(sid(4))", h1 = "\(hd)/claude-code-sessions/\(sid(5))/\(sid(6))"
    write("\(w1)/local_\(sid(10)).json", #"{"sessionId":"local_\#(sid(10))","cliSessionId":"\#(sid(110))","title":"work session","cwd":"/w/project","isArchived":false}"#)
    write("\(w2)/local_\(sid(11)).json", #"{"sessionId":"local_\#(sid(11))","cliSessionId":"\#(sid(111))","title":"standby session","cwd":"/w/project","isArchived":false}"#)
    write("\(h1)/local_\(sid(12)).json", #"{"sessionId":"local_\#(sid(12))","cliSessionId":"\#(sid(112))","title":"home session","cwd":"/w/home","isArchived":false}"#)
    let task1: [String: Any] = ["id": "nightly-digest", "displayName": "Nightly digest", "cronExpression": "0 3 * * *", "enabled": true, "filePath": wc + "/scheduled-tasks/nightly-digest/SKILL.md", "cwd": "/w/project", "createdAt": 1]
    let task2: [String: Any] = ["id": "standby-report", "displayName": "Standby report", "cronExpression": "0 9 * * 1", "enabled": true, "filePath": wc + "/scheduled-tasks/standby-report/SKILL.md", "cwd": "/w/project", "createdAt": 1]
    try! JSONSerialization.data(withJSONObject: ["scheduledTasks": [task1]]).write(to: URL(fileURLWithPath: w1 + "/scheduled-tasks.json"))
    try! JSONSerialization.data(withJSONObject: ["scheduledTasks": [task2]]).write(to: URL(fileURLWithPath: w2 + "/scheduled-tasks.json"))
    write("\(wc)/scheduled-tasks/nightly-digest/SKILL.md", "Summarise yesterday.\n"); write("\(wc)/scheduled-tasks/standby-report/SKILL.md", "Report.\n")
    write("\(wc)/CLAUDE.md", "# rules\n"); write("\(wc)/settings.json", #"{"env":{"TOKEN":"\#(settingsEnvValue)"},"model":"opus"}"#)
    try! JSONSerialization.data(withJSONObject: ["mcpServers": ["github": ["command": "npx", "env": ["GITHUB_TOKEN": envValue]]]]).write(to: URL(fileURLWithPath: wd + "/claude_desktop_config.json"))
    write("\(wc)/projects/-w-project/\(sid(110)).jsonl", #"{"type":"user","cwd":"/w/project","text":"hello \#(a1)"}"# + "\n")
    write("\(wc)/projects/-w-project/\(sid(111)).jsonl", #"{"type":"user","cwd":"/w/project","text":"standby"}"# + "\n")
    write("\(hc)/projects/-w-home/\(sid(112)).jsonl", #"{"type":"user","cwd":"/w/home","text":"home"}"# + "\n")
    for f in files(wc + "/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: wc + "/projects/" + f) }
    for f in files(hc + "/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: hc + "/projects/" + f) }
    // this Mac's settings: Silver, emails hidden, 7 backups kept, backups in a folder of the home
    SessionsMove.prefs.set("silver", forKey: "face"); SessionsMove.prefs.set(false, forKey: Privacy.key)
    BackupPrefs.store.set(7, forKey: BackupPrefs.lastKey)
    try! fm.createDirectory(atPath: home + "/MyBackups", withIntermediateDirectories: true)
    BackupPrefs.store.set("~/MyBackups", forKey: BackupPrefs.placeKey)
    let bplace = BackupPrefs.placeURL

    func part(_ e: AccountEntry) -> SessionsExport.Part {
        SessionsExport.Part(profile: e.id, name: e.name, source: SessionsBackup.Source(e), emails: ([e.seat?.email] + e.standby.map(\.email)).compactMap { $0 })
    }
    let all = Store.load()
    let profilesData = SessionsMove.make(all, parts: ["work": "p1", "home": "p2"], all: all, move: true)
    let pj = json(profilesData)
    check((pj?["profiles"] as? [[String: Any]])?.count == 2 && (pj?["general"] as? [String: Any])?["face"] as? String == "silver" && (pj?["backups"] as? [String: Any])?[BackupPrefs.lastKey] as? Int == 7,
          "make: cl_audit.json holds the two profiles and the settings")

    // ---- the move: an encrypted image only, the real ids kept
    var job = SessionsExport.Job(parts: [part(work), part(homeE)], keys: .keep, password: nil, destination: URL(fileURLWithPath: out + "/move.zip"), rootName: "move-zip", place: bplace)
    job.move = true; job.profiles = profilesData; job.known = Identities.of(accounts: all)
    do { _ = try SessionsExport.run(job); check(false, "a move as a zip is refused") }
    catch { check("\(error)".contains("never a zip") && !fm.fileExists(atPath: out + "/move.zip"), "export: a move is never a zip (refused in the engine): \(error)") }
    job.password = pw; job.destination = URL(fileURLWithPath: moveFile); job.rootName = "cl_audit all profiles move"
    var mo: SessionsExport.Outcome?
    do { mo = try SessionsExport.run(job) } catch { check(false, "export (move): \(error)") }
    check(mo?.move == true && mo?.profilesCarried == true && mo?.profilesLeftOut == false, "export (move): made, with cl_audit's profiles")
    if mo != nil, let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: bplace) {
        let t = o.tree.path
        check(o.export.version == 4 && o.export.move == true && o.export.profiles?.path == "cl_audit.json" && o.parts.allSatisfy { $0.manifest.version == 4 && $0.manifest.move == true },
              "export (move): format 4, a move, cl_audit.json named with its size and hash")
        check(fm.fileExists(atPath: "\(t)/profiles/p1/window/\(sid(1))/\(sid(2))/local_\(sid(10)).json") && fm.fileExists(atPath: "\(t)/profiles/p1/window/\(sid(3))/\(sid(4))/scheduled-tasks.json")
              && has("\(t)/cl_audit.json", a1) && has("\(t)/cl_audit.json", sid(3)),
              "export (move): the window folders are the real account ids; the addresses are in it (the image is the protection)")
        check(holds(t, "fp-").isEmpty && !holds(t, envValue).isEmpty,
              "export (move): no fingerprint anywhere; the MCP settings as they are (in the image)")
        let rec = json(fm.contents(atPath: "\(t)/profiles/p1/records/profile.json"))
        check((rec?["seat"] as? [String: Any])?["account"] as? String == sid(1), "export (move): the profile's record keeps its real account id")
        SessionsImport.discard(o.work)
    } else { check(false, "export (move): its own import opens it") }

    // ---- every other export: as before (fingerprints, the leak check), and cl_audit's profiles only in an image, fingerprinted
    var plainJob = SessionsExport.Job(parts: [part(work)], keys: .keep, password: pw, destination: URL(fileURLWithPath: out + "/plain.dmg"), rootName: "plain-image", place: bplace)
    plainJob.profiles = SessionsMove.make([work], parts: ["work": "p1"], all: all, move: false); plainJob.known = Identities.of(accounts: all)
    if let po = try? SessionsExport.run(plainJob), let o = try? SessionsImport.open(po.file, password: pw, place: bplace) {
        let t = o.tree.path
        let windowDirs = everything(t + "/profiles/p1/window").filter { !$0.contains("/") }
        check(o.export.move == nil && o.export.version == 4 && !windowDirs.isEmpty && windowDirs.allSatisfy { Fingerprint.isValid($0) } && !has(t + "/cl_audit.json", sid(1)) && !has(t + "/cl_audit.json", a1)
              && holds(t, a1).filter { !$0.contains("transcripts/") }.isEmpty && o.parts[0].manifest.move == nil,
              "export (not a move, image with profiles): format 4 for cl_audit.json, but window folders and cl_audit.json carry fingerprints only: \(windowDirs)")
        let f = o.app
        check(f?.fingerprinted == true && f?.profiles.first?.accounts.isEmpty == true && f?.profiles.first?.name == "Work",
              "import (not a move): the profiles come without accounts (fingerprints only)")
        let pl = SessionsMove.plan(f!, accounts: [])
        check(pl.create.first?.entry.seat == nil && MoveWords.profileNotes(pl).contains { $0.contains("only fingerprints") }, "import (not a move): …and the page says why")
        SessionsImport.discard(o.work)
    } else { check(false, "export (not a move, image with profiles): made and opens") }
    var zipJob = plainJob; zipJob.password = nil; zipJob.destination = URL(fileURLWithPath: out + "/plain.zip"); zipJob.rootName = "plain-zip"
    if let zo = try? SessionsExport.run(zipJob), let o = try? SessionsImport.open(zo.file, password: nil, place: bplace) {
        check(zo.profilesLeftOut && !zo.profilesCarried && o.export.profiles == nil && o.export.version <= 3 && !fm.fileExists(atPath: o.tree.path + "/cl_audit.json")
              && holds(o.tree.path, a1).filter { !$0.contains("transcripts/") }.isEmpty,
              "export (zip): cl_audit's profiles left out and said; the lowest version (\(o.export.version)); fingerprints as before")
        SessionsImport.discard(o.work)
    } else { check(false, "export (zip): made and opens") }
    check(ExportWords.profilesWords(count: 2, names: ["Work", "Home"], on: true, image: false).value == "left out of a zip"
          && ExportWords.profilesWords(count: 2, names: ["Work", "Home"], on: true, image: true).value.hasPrefix("2 profiles (Work, Home)"),
          "export page: the profiles row: left out of a zip, in the image")

    // ---- the new Mac: role B, in its own fresh home
    let bHome = (home as NSString).deletingLastPathComponent + "/b/home"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.environment = ["HOME": bHome, "CFFIXED_USER_HOME": bHome, "MOVE_ROLE": "b", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    if bHome.hasSuffix("/Checks/.work/move/b/home"), fm.fileExists(atPath: bHome), (try? p.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for l in text.split(separator: "\n") where l.hasPrefix("FAIL") { print(l) }
        if let last = text.split(separator: "\n").last(where: { $0.hasPrefix("checks: ") }) {
            let nums = last.split(separator: " ").compactMap { Int($0) }
            if nums.count == 2 { passed += nums[0]; failed += nums[1] }
            print("role B: \(last.dropFirst(8))")
        } else { check(false, "role B ran: \(text.suffix(400))") }
    } else { check(false, "role B starts in its own home \(bHome)") }

    // ---- hostile: cl_audit.json, read and cleaned (never trusted)
    func readJSON(_ o: Any) -> SessionsMove.File? { SessionsMove.read(try! JSONSerialization.data(withJSONObject: o)) }
    let base: [String: Any] = ["format": "cl_audit-profiles", "move": true]
    check(SessionsMove.read(Data("not json".utf8)) == nil && readJSON(["format": "something else"]) == nil && SessionsMove.read(Data((String(repeating: "[", count: 40) + String(repeating: "]", count: 40)).utf8)) == nil
          && SessionsMove.read(Data(("{\"format\":\"cl_audit-profiles\",\"pad\":\"" + String(repeating: "a", count: (1 << 20) + 1) + "\"}").utf8)) == nil,
          "hostile: not JSON, another format, nested 40 deep, over 1 MB: not read (the import refuses the file)")
    let odd = readJSON(base.merging(["profiles": [
        ["id": "../etc", "name": "Wo\u{202E}rk\nX", "label": "a/b", "place": 99999, "inDock": "yes", "configDir": "/etc", "window": "standard", "dataDir": "/System/x",
         "settings": ["style": "nope", "pollMinutes": 100000, "notify": "true", "color": 5, "menuBarLook": ["style": [1, 2]], "peekSeconds": 1e300],
         "accounts": [["account": "not-a-uuid", "organization": sid(2), "email": "x@example.com"], ["account": sid(7), "organization": sid(8), "email": "evil\u{2028}@example.com", "inUse": true]]],
        ["name": "a/b"], ["name": ""], ["name": 5], ["name": "Clean", "accounts": [["account": sid(7), "organization": sid(8)]]], "not an object"],
        "backups": [BackupPrefs.placeKey: "/System/Library", BackupPrefs.lastKey: 1_000_000, BackupPrefs.daysKey: "30"], "general": ["face": "bogus", Privacy.key: 1]], uniquingKeysWith: { $1 }))
    if let f = odd, let x = f.profiles.first {
        check(f.profiles.count == 2 && x.name == "WorkX" && x.id != "../etc" && SessionsMove.validID(x.id) && x.entry.configDir.hasPrefix("~/.claude-") && x.place == 999 && x.inDock == false,
              "hostile: a name with control and bidi characters is one plain line; a bad id, path and place are cleaned: \(x.name) \(x.id) \(x.entry.configDir) \(x.place)")
        check(x.entry.style == AccountEntry(id: "a", name: "a", label: "A", configDir: "x").style && x.entry.pollMinutes == 5 && x.entry.notify == true && x.entry.color == .orange,
              "hostile: settings of the wrong type or out of range fall back to the default")
        check(x.accounts.count == 1 && x.accounts[0].seat.account == sid(7) && x.accounts[0].email == nil && f.profiles[1].accounts.isEmpty
              && f.profiles[1].notes.contains { $0.contains("another profile of the file has too") },
              "hostile: an account id that isn't one is dropped, a bad address is dropped, one account isn't in two profiles")
        check(f.backups[BackupPrefs.placeKey] == "/System/Library" && f.backups[BackupPrefs.lastKey] == nil && f.backups[BackupPrefs.daysKey] == nil && f.general["face"] == nil && f.general[Privacy.key] == nil,
              "hostile: settings of the wrong type or range aren't read")
        check(SessionsMove.placeProblem("/System/Library")?.contains("system folder") == true && SessionsMove.placeProblem("~/nowhere-m0") != nil && SessionsMove.placeProblem("~/../..") != nil
              && SessionsMove.placeProblem("~/MyBackups") == nil && SessionsMove.placeProblem("~") != nil,
              "hostile: a backups place in a system folder, missing, outside the home or the home itself is never taken")
        let pl = SessionsMove.plan(f, accounts: Store.load())
        check(pl.settings.first { $0.key == BackupPrefs.placeKey }?.problem != nil && !pl.takeable.contains { $0.key == BackupPrefs.placeKey }, "hostile: …and the plan won't take it")
    } else { check(false, "hostile: an odd profiles file is read and cleaned") }
    let many = readJSON(base.merging(["profiles": (0..<100).map { ["name": "P\($0)", "accounts": (0..<30).map { k in ["account": sid(1000 + k), "organization": sid(2000 + k)] }] }], uniquingKeysWith: { $1 }))
    check(many?.profiles.count == SessionsMove.maxProfiles && many?.profiles.first?.accounts.count == SessionsMove.maxAccounts && many?.notes.isEmpty == false
          && many?.profiles.first?.notes.contains { $0.contains("more than 20 accounts") } == true,
          "hostile: 100 profiles with 30 accounts each: 64 read, 20 accounts in the first, said")

    // ---- recognising a profile that is here: by its account, then by its name; never a change to one that is here
    let mine = SessionsMove.read(profilesData)!
    var renamed = work; renamed.name = "Office"
    let byAccount = SessionsMove.plan(mine, accounts: [renamed])
    check(byAccount.here.first?.name == "Work" && byAccount.here.first?.here == "Office" && byAccount.create.map(\.name) == ["Home"], "recognise: a profile with one of its accounts is here (whatever its name)")
    var other = homeE; other.id = "elsewhere"; other.seat = Seat(account: sid(90), organization: sid(91), email: "other@example.com")
    let byName = SessionsMove.plan(mine, accounts: [other])
    check(byName.notMade.first?.name == "Home" && byName.notMade.first?.why.contains("already called") == true && byName.create.map(\.name) == ["Work"],
          "recognise: a profile with its name and other accounts isn't made (and isn't changed)")
    var sameID = homeE; sameID.name = "Laptop"; sameID.seat = Seat(account: sid(92), organization: sid(93), email: "l@example.com"); sameID.configDir = "~/.claude-laptop"; sameID.desktopDataDir = "~/Library/Application Support/Claude-laptop"
    let byID = SessionsMove.plan(mine, accounts: [sameID])
    check(byID.create.first { $0.name == "Home" }?.id != "home" && byID.create.count == 2, "recognise: an id that is taken here gets another one")
    var usesFolder = sameID; usesFolder.configDir = "~/.claude-work"; usesFolder.desktop = .standard; usesFolder.desktopDataDir = ""
    let byFolder = SessionsMove.plan(mine, accounts: [usesFolder])
    check(byFolder.create.first { $0.name == "Work" }?.entry.configDir == "~/.claude-work-2",
          "recognise: a folder another profile uses here: the made one gets its own: \(byFolder.create.map(\.entry.configDir))")

    // ---- a made profile never takes a folder from the file (round 1, M1): ~/.claude, the usual Claude app, ~/Documents, / and a linked
    // folder named by a crafted cl_audit.json all give way to its own folders; a folder of its own name that holds a sign-in or is a
    // link is skipped; one that is plain and empty is used, and said
    do {
        let live = expand("~/.claude"), docs = expand("~/Documents"), away = home + "/away-m1"
        write(live + "/.claude.json", #"{"oauthAccount":{"accountUuid":"\#(sid(60))"}}"#); write(live + "/projects/-x/keep.jsonl", "{}\n")
        write(docs + "/mine.txt", "mine\n"); try? fm.createDirectory(atPath: away, withIntermediateDirectories: true)
        write(expand("~/.claude-signed") + "/.claude.json", #"{"oauthAccount":{"accountUuid":"\#(sid(61))"}}"#)
        try? fm.removeItem(atPath: expand("~/.claude-linked")); symlink(away, expand("~/.claude-linked"))
        try? fm.createDirectory(atPath: expand("~/.claude-plain"), withIntermediateDirectories: true)
        let liveBefore = everything(live), docsBefore = everything(docs)
        func acct(_ n: Int) -> [[String: Any]] { [["account": sid(n), "organization": sid(n + 1), "email": "h\(n)@example.com", "inUse": true]] }
        let hostile = readJSON(base.merging(["profiles": [
            ["id": "evil", "name": "Evil", "configDir": "~/.claude", "window": "standard", "dataDir": "~/Library/Application Support/Claude", "accounts": acct(70)],
            ["id": "docs", "name": "Docs", "configDir": "~/Documents", "dataDir": "/", "accounts": acct(72)],
            ["id": "signed", "name": "Signed", "configDir": "~/.claude-signed", "accounts": acct(74)],
            ["id": "linked", "name": "Linked", "configDir": "~/.claude-linked", "accounts": acct(76)],
            ["id": "plain", "name": "Plain", "accounts": acct(78)]]], uniquingKeysWith: { $1 }))!
        let hp = SessionsMove.plan(hostile, accounts: Store.load())
        let dirs = Dictionary(uniqueKeysWithValues: hp.create.map { ($0.name, ($0.entry.configDir, $0.entry.desktop, $0.entry.desktopDataDir)) })
        check(dirs["Evil"]?.0 == "~/.claude-evil" && dirs["Evil"]?.1 == .separate && dirs["Evil"]?.2 == "~/Library/Application Support/Claude-evil"
              && dirs["Docs"]?.0 == "~/.claude-docs" && dirs["Docs"]?.2 == "~/Library/Application Support/Claude-docs",
              "M1: a file naming ~/.claude, the usual Claude app, ~/Documents or / gets its own folders: \(dirs)")
        check(dirs["Signed"]?.0 == "~/.claude-signed-2" && dirs["Linked"]?.0 == "~/.claude-linked-2" && dirs["Plain"]?.0 == "~/.claude-plain"
              && hp.create.first { $0.name == "Plain" }?.notes.contains { $0.contains("already on this Mac") } == true,
              "M1: a folder of its own name that holds a sign-in or is a link is skipped; a plain one is used and said: \(dirs)")
        let hr = try! SessionsMove.apply(hp, takeSettings: false, file: "hostile")
        let after = Store.load()
        check(Array(after.prefix(2).map(\.name)) == ["Work", "Home"] && after.count == 7 && !after.contains { Account.isDefault(configDir: $0.configDir) || $0.desktop == .standard },
              "S7: the made profiles come after the ones here, none on ~/.claude or the usual Claude app: \(after.map(\.name))")
        let newSignIns = everything(home).filter { ($0 as NSString).lastPathComponent == ".claude.json" }
        check(everything(live) == liveBefore && everything(docs) == docsBefore && everything(away).isEmpty && newSignIns.count == 2 && securityCalls == 0,
              "M1: nothing written in ~/.claude, ~/Documents or the linked folder's target, no new sign-in anywhere: \(newSignIns)")
        _ = try! SessionsMove.undo(hr.id)
        check(Store.load().map(\.name) == ["Work", "Home"] && fm.fileExists(atPath: expand("~/.claude-plain")) && !fm.fileExists(atPath: expand("~/.claude-evil")),
              "M1: Undo takes back the made ones and their folders; a folder that was there stays")
        try? fm.removeItem(atPath: expand("~/.claude-linked"))
        // the backups place, judged where it really is (round 1, S1)
        try? fm.createDirectory(atPath: home + "/.hidden-m1", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: home + "/Library/Backups-m1", withIntermediateDirectories: true)
        try? fm.removeItem(atPath: home + "/link-m1"); symlink("/private/tmp", home + "/link-m1")
        let disk = "/Volumes/Macintosh HD/private/tmp"           // (this Mac's own disk, reached through /Volumes)
        check(SessionsMove.placeProblem("~/.hidden-m1") != nil && SessionsMove.placeProblem("~/Library/Backups-m1") != nil && SessionsMove.placeProblem("~/link-m1") != nil
              && (!fm.fileExists(atPath: disk) || SessionsMove.placeProblem(disk) != nil),
              "S1: a hidden folder, one in ~/Library, a link out of the home and this Mac's own disk under /Volumes are never taken as the backups place")
        // fewer backups kept than here (round 1, S2)
        let fewer = readJSON(base.merging(["backups": [BackupPrefs.lastKey: 1, BackupPrefs.daysKey: 0]], uniquingKeysWith: { $1 }))!
        let fp = SessionsMove.plan(fewer, accounts: Store.load())
        check(MoveWords.settingLines(fp).contains { $0.hasPrefix("Minimum backups kept: 7 here, 1 in the file") && $0.contains("removes the older ones") }
              && MoveWords.settingLines(fp).contains { $0.hasPrefix("Days of backups kept") && $0.contains("removes the older ones") },
              "S2: taking fewer backups than here says what the next backup does: \(MoveWords.settingLines(fp))")
    }

    // ---- the last word under the profiles file's lock (round 2): a folder that became a link, or a window folder that got a sign-in,
    // between the plan and Make, refuses that profile; a backups place that went away isn't taken
    do {
        func acct(_ n: Int) -> [[String: Any]] { [["account": sid(n), "organization": sid(n + 1), "email": "r\(n)@example.com", "inUse": true]] }
        try? fm.createDirectory(atPath: home + "/Backups-r2", withIntermediateDirectories: true)
        let late = readJSON(base.merging(["profiles": [["id": "swap", "name": "Swap", "accounts": acct(80)], ["id": "winsign", "name": "Winsign", "accounts": acct(82)],
                                                       ["id": "fine", "name": "Fine", "accounts": acct(84)]],
                                          "backups": [BackupPrefs.placeKey: "~/Backups-r2"]], uniquingKeysWith: { $1 }))!
        let lp = SessionsMove.plan(late, accounts: Store.load())
        check(lp.create.count == 3 && lp.takeable.contains { $0.key == BackupPrefs.placeKey }, "r2: the plan makes three and would take the backups place")
        let away = home + "/away-r2"; try? fm.createDirectory(atPath: away, withIntermediateDirectories: true)
        symlink(away, expand("~/.claude-swap"))
        write(expand("~/Library/Application Support/Claude-winsign") + "/config.json", "{}")
        try? fm.removeItem(atPath: home + "/Backups-r2")
        let lr = try! SessionsMove.apply(lp, takeSettings: true, file: "late")
        check(lr.made.filter(\.written).map(\.name) == ["Fine"] && everything(away).isEmpty && lr.problems.contains { $0.contains("Swap") } && lr.problems.contains { $0.contains("Winsign") },
              "r2: a folder that turned into a link, and a window folder that got a sign-in, refuse their profile under the lock: \(lr.made.filter(\.written).map(\.name))")
        check(lr.settings.isEmpty && lr.problems.contains { $0.contains("backups folder") } && (BackupPrefs.store.string(forKey: BackupPrefs.placeKey) ?? "") == "~/MyBackups",
              "r2: a backups place that went away between the plan and Make isn't taken")
        check(SessionsMove.folderUsable("~/.claude-swap", signIn: ".claude.json") == false && SessionsMove.folderUsable("~/.claude-nothing-r2", signIn: ".claude.json"),
              "r2: a link is never usable; a folder that isn't there is")
        _ = try! SessionsMove.undo(lr.id)
        try? fm.removeItem(atPath: expand("~/.claude-swap")); try? fm.removeItem(atPath: expand("~/Library/Application Support/Claude-winsign"))
    }

    // ---- doctored images and zips
    guard let base0 = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: bplace) else { check(false, "(the move file opens for doctoring)"); return }
    func doctored(_ name: String, zip: Bool = false, edit: (URL, inout ExportManifest, inout [SessionsBackup.Manifest]) throws -> Void) -> String {
        let work = home + "/doctor-\(name)"
        try? fm.removeItem(atPath: work); try! fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        _ = Tool.run("/usr/bin/ditto", [base0.tree.path, work + "/" + base0.tree.lastPathComponent])
        let root = URL(fileURLWithPath: work + "/" + base0.tree.lastPathComponent)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var ex = try dec.decode(ExportManifest.self, from: Data(contentsOf: root.appendingPathComponent("export.json")))
            var ms = try ex.parts.map { try dec.decode(SessionsBackup.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("profiles/\($0.dir)/backup.json"))) }
            try edit(root, &ex, &ms)
            for (i, m) in ms.enumerated() {
                try enc.encode(m).write(to: root.appendingPathComponent("profiles/\(ex.parts[i].dir)/backup.json"))
                ex.parts[i].bytes = m.bytes
            }
            ex.bytes = ex.parts.reduce(0) { $0 + $1.bytes }
            if zip { ex.container = "zip" }
            try enc.encode(ex).write(to: root.appendingPathComponent("export.json"))
        } catch { return "doctoring failed: \(error)" }
        let file = URL(fileURLWithPath: out + "/\(name).\(zip ? "zip" : "dmg")")
        try? fm.removeItem(at: file)
        let vol = "move-\(name)-\(getpid())"
        var r: Tool.Output?
        for _ in 0..<2 {
            r = zip ? Tool.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", root.path, file.path])
                    : Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", work, "-volname", vol, "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", file.path], stdin: Data(pw.utf8), secret: pw)
            if r?.status == 0 { break }
            try? fm.removeItem(at: file)
        }
        guard r?.status == 0 else { return "file not made (status \(r.map { String($0.status) } ?? "none")): \(r?.err ?? "")" }
        do { let x = try SessionsImport.open(file, password: zip ? nil : pw, place: bplace); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    func setProfiles(_ root: URL, _ ex: inout ExportManifest, _ d: Data) throws {
        try d.write(to: root.appendingPathComponent("cl_audit.json"))
        ex.profiles = ExportManifest.AppFile(path: "cl_audit.json", bytes: Int64(d.count), sha: SwitchEngine.sha(d))
    }
    check(doctored("m-ok") { _, _, _ in } == "OPENED", "(an untouched copy of the move file opens)")
    let zipMove = doctored("m-zip", zip: true) { root, _, _ in try? fm.removeItem(at: root.appendingPathComponent("cl_audit.json")) }
    check(zipMove.contains("never a zip") || zipMove.contains("only ever in an encrypted disk image"), "hostile: a zip that claims to be a move is refused before anything is unpacked: \(zipMove.prefix(90))")
    let notJSON = doctored("m-profiles-not-json") { root, ex, _ in try setProfiles(root, &ex, Data("not json".utf8)) }
    check(notJSON.contains("can't be read"), "hostile: a cl_audit.json that isn't JSON refuses the whole file: \(notJSON.prefix(90))")
    let deep = doctored("m-profiles-deep") { root, ex, _ in try setProfiles(root, &ex, Data(("{\"format\":\"cl_audit-profiles\",\"move\":true,\"x\":" + String(repeating: "[", count: 30) + String(repeating: "]", count: 30) + "}").utf8)) }
    check(deep.contains("can't be read"), "hostile: a cl_audit.json nested too deep is refused: \(deep.prefix(90))")
    let huge = doctored("m-profiles-huge") { root, ex, _ in try setProfiles(root, &ex, Data(("{\"format\":\"cl_audit-profiles\",\"pad\":\"" + String(repeating: "a", count: (1 << 20) + 16) + "\"}").utf8)) }
    check(huge.contains("isn't one") || huge.contains("in a way an export doesn't"), "hostile: a cl_audit.json over 1 MB is refused, never read whole: \(huge.prefix(90))")
    let badSha = doctored("m-profiles-sha") { root, ex, _ in try Data("{}".utf8).write(to: root.appendingPathComponent("cl_audit.json")); ex.profiles?.bytes = 2 }
    check(badSha.contains("isn't what export.json says"), "hostile: a cl_audit.json that isn't what export.json's hash says is refused: \(badSha.prefix(90))")
    let oddOK = doctored("m-profiles-odd") { root, ex, _ in try setProfiles(root, &ex, try JSONSerialization.data(withJSONObject: base.merging(["profiles": [["name": "Odd\u{202E}", "place": -5, "accounts": [["account": "x", "organization": "y"]]]]], uniquingKeysWith: { $1 }))) }
    check(oddOK == "OPENED", "hostile: odd values in cl_audit.json are cleaned, the file opens: \(oddOK.prefix(90))")
    let notMove = doctored("m-not-move-claims") { root, ex, ms in ex.move = nil; try setProfiles(root, &ex, try JSONSerialization.data(withJSONObject: ["format": "cl_audit-profiles", "move": false])) }
    check(notMove.contains("don't agree") , "hostile: parts that keep the real ids in a file that isn't a move are refused: \(notMove.prefix(90))")
    let fpInMove = doctored("m-fingerprint-folder") { root, _, ms in
        guard let i = ms[0].items.firstIndex(where: { $0.role == .window }) else { return }
        let c = ms[0].items[i].path.split(separator: "/").map(String.init)
        let np = "window/fp-0000aaaa/fp-0000bbbb/\(c[3])"
        try fm.createDirectory(at: root.appendingPathComponent("profiles/p1/window/fp-0000aaaa/fp-0000bbbb"), withIntermediateDirectories: true)
        try fm.moveItem(at: root.appendingPathComponent("profiles/p1/\(ms[0].items[i].path)"), to: root.appendingPathComponent("profiles/p1/\(np)"))
        ms[0].items[i].path = np; ms[0].items[i].original = np
    }
    check(fpInMove.contains("in a place an export doesn't keep them") || fpInMove.contains("folder its manifests don't name"), "hostile: a move's part with a fingerprint folder is refused: \(fpInMove.prefix(90))")
    let oldMove = doctored("m-move-v3") { _, ex, ms in ex.version = 3; for i in ms.indices { ms[i].version = 3 } }
    check(oldMove.contains("older than") || oldMove.contains("format 4"), "hostile: a move in a format older than 4 is refused: \(oldMove.prefix(90))")
    let v5 = doctored("m-v5") { _, ex, ms in ex.version = 5; for i in ms.indices { ms[i].version = 5 } }
    check(v5.contains("newer cl_audit"), "format: a version 5 file is refused with the newer-cl_audit words")
    SessionsImport.discard(base0.work)

    // ---- the older readers: 26.11.9 reads `<= 3` and refuses 4 with its words; 1 to 3 are still read here (the setup and window suites
    // open version 1, 2 and 3 files); a reader without `move` would take the real ids for fingerprints, which its window-folder rule refuses
    let v4 = 4
    // (5 is an export.json with a move's code checklist, the resume suite's; a backup.json and a move's part stay at 4)
    check(!(v4 <= 3) && SessionsBackup.backupVersion == 4 && SessionsBackup.neededVersion([], move: true) == 4 && SessionsBackup.neededVersion([]) == 2,
          "format: a file with cl_audit's profiles or a move is version 4, which 26.11.9's guard (<= 3) refuses; everything else stays 2 or 3")
    check(!Fingerprint.isValid(sid(1)), "format: …and a move's real-id folder is never a fingerprint, so 26.11.9's own rule would refuse it too")

    // ---- the done page's steps and the rows' words
    let made = SessionsMove.Made(id: "work", name: "Work", part: "p1", entry: work, place: 0, signIns: [a1, a2], inDock: true)
    let steps = MoveWords.steps(made, tasks: 2)
    check(steps.count == 4 && steps[0].contains(a1) && steps[0].contains("Accounts ▸ Add account") && steps[1].hasPrefix("Put it in the Dock") && steps[1].contains("Dock icon ▸ Usage in the Dock")
          && steps[2].contains("paused") && steps[3].contains("Sessions ▸ Import…"),
          "words: the done page lists each account to sign in, the Dock step and the paused tasks: \(steps)")
    check(dockCalls == 0 && securityCalls == 0, "A: the Dock was never written, the Keychain never asked")
    try? fm.removeItem(atPath: out)
}
print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
