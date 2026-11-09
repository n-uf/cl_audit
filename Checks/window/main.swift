// Window checks for cl_audit: the Claude window's own settings and scheduled tasks travel with Export, Import, Backup and Restore
// (format version 3). Sources/SessionsBackup.swift (the config item, a backup's scheduled tasks' prompts), SessionsExport.swift (a zip
// leaves the config out, an image carries it scrubbed), SessionsImport.swift (what a file may hold), SessionsRestoreWindow.swift (the
// plans: MCP settings create-only for the whole file, an import's tasks paused, create-only per file, with their prompts and sessions),
// WindowRows.swift and the Export page's words.
//
// Part 1 works on real files in a throwaway home: a profile with a window (Code-tab entries, a task file, claude_desktop_config.json
// with MCP servers) and a Claude Code folder (transcripts, the tasks' prompts); exports to a zip and an encrypted image; imports into a
// profile with nothing and into one that has its own; Undo; a restore from this Mac's own backup; doctored images (a config that is
// huge, not JSON, a link, a folder; a crafted task; a prompt without its task; formats). Part 2 reads the rows' words.
// Runs only with CFFIXED_USER_HOME = .../Checks/.work/window/home (Checks/run.sh sets and guards it). Fake data only: example.com
// addresses, zero-pattern ids, made-up servers and values. Nothing here opens an app, the Dock or Terminal; the images are made and
// opened with hdiutil in the throwaway folder.

import AppKit
import Foundation

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/window/home") else { print("refusing: HOME is \(home)"); exit(2) }
BackupPrefs.store = MemoryPrefs()          // never the real ~/Library/Preferences
let fm = FileManager.default
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}

func sid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func write(_ path: String, _ text: String) {
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: path, contents: Data(text.utf8))
}
func read(_ path: String) -> String? { fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }
func files(_ dir: String) -> [String] {
    var out: [String] = []
    if let e = fm.enumerator(atPath: dir) { for case let r as String in e { var isDir: ObjCBool = false; if fm.fileExists(atPath: dir + "/" + r, isDirectory: &isDir), !isDir.boolValue { out.append(r) } } }
    return out.sorted()
}
/// Every file's path and bytes under a folder, as one string: equal means unchanged.
func tree(_ dir: String) -> String { files(dir).map { "\($0)=\(SwitchEngine.sha(fm.contents(atPath: dir + "/" + $0) ?? Data()))" }.joined(separator: "\n") }
func json(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
func resetRestores() { try? fm.removeItem(at: SessionsRestore.root); try? fm.removeItem(at: SwitchEngine.root) }
func mode(_ path: String) -> Int { var s = stat(); lstat(path, &s); return Int(s.st_mode & 0o7777) }
func same(_ a: [String: Any], _ b: [String: Any]) -> Bool { (a as NSDictionary).isEqual(to: b) }

// the made-up values a zip must never hold (no key shape: only "the image carries it" protects them)
let envValue = "env-value-not-a-real-secret-w0"
let headerValue = "header-value-not-a-real-secret-w0"
let settingsEnvValue = "settings-env-not-a-real-secret-w0"
/// Whether any file under a folder holds these bytes.
func holds(_ dir: String, _ s: String) -> [String] { files(dir).filter { (fm.contents(atPath: dir + "/" + $0) ?? Data()).range(of: Data(s.utf8)) != nil } }

MainActor.assumeIsolated {
    resetRestores(); SessionsRestore.runningSessions = { [] }
    let w = home + "/w"
    try? fm.removeItem(atPath: w)
    try! fm.createDirectory(atPath: w, withIntermediateDirectories: true)
    let place = URL(fileURLWithPath: w + "/place"), out = w + "/out"
    try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    BackupPrefs.shared.place = place.path
    let pw = "w-test-password-not-secret"

    // ---- the source profile: its window (account sid(1) / organisation sid(2)) and its Claude Code folder
    let seatA = SeatID(account: sid(1), organization: sid(2))
    let dataA = w + "/Claude-a", codeA = w + "/.claude-a"
    let scopeA = "\(dataA)/claude-code-sessions/\(sid(1))/\(sid(2))"
    let config: [String: Any] = [
        "mcpServers": ["github": ["command": "npx", "args": ["-y", "@example/server-github"], "env": ["GITHUB_TOKEN": envValue]],
                       "remote": ["url": "https://mcp.example.com/sse", "headers": ["Authorization": "Bearer \(headerValue)"]]],
        "globalShortcut": "Alt+Space",
        "preferences": ["epitaxyPrefs": ["scopes": ["\(sid(1))/\(sid(2))": ["groups": []]]], "menuBarEnabled": true]]
    func plantA() {
        try? fm.removeItem(atPath: dataA); try? fm.removeItem(atPath: codeA)
        try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dataA + "/claude_desktop_config.json").createDirs())
        write("\(scopeA)/local_\(sid(10)).json", #"{"sessionId":"local_\#(sid(10))","cliSessionId":"\#(sid(110))","title":"ordinary","cwd":"/w/project","isArchived":false}"#)
        write("\(scopeA)/local_\(sid(11)).json", #"{"sessionId":"local_\#(sid(11))","cliSessionId":"\#(sid(111))","title":"digest run","cwd":"/w/project","scheduledTaskId":"nightly-digest","isArchived":false}"#)
        let tasks: [[String: Any]] = [
            ["id": "nightly-digest", "displayName": "Nightly digest", "cronExpression": "0 3 * * *", "enabled": true, "filePath": codeA + "/scheduled-tasks/nightly-digest/SKILL.md",
             "cwd": "/w/project", "createdAt": 1_700_000_000_000, "permissionMode": "default", "lastRunAt": 1_700_000_100_000],
            ["id": "weekly-report", "displayName": "Weekly report", "cronExpression": "0 9 * * 1", "enabled": false, "filePath": codeA + "/scheduled-tasks/weekly-report/SKILL.md",
             "cwd": "/w/project", "createdAt": 1_700_000_000_000],
            ["id": "elsewhere-task", "displayName": "Elsewhere", "cronExpression": "0 1 * * *", "enabled": true, "filePath": w + "/somewhere/prompt.md", "createdAt": 1],
            ["id": "Bad Id", "displayName": "Bad id", "cronExpression": "0 1 * * *", "enabled": true, "createdAt": 1]]
        try! JSONSerialization.data(withJSONObject: ["scheduledTasks": tasks], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: scopeA + "/scheduled-tasks.json"))
        write("\(codeA)/scheduled-tasks/nightly-digest/SKILL.md", "---\nname: nightly-digest\n---\nSummarise yesterday's commits.\n")
        write("\(codeA)/scheduled-tasks/weekly-report/SKILL.md", "---\nname: weekly-report\n---\nWrite the weekly report.\n")
        write("\(codeA)/scheduled-tasks/elsewhere-task/SKILL.md", "elsewhere prompt\n")
        write("\(codeA)/scheduled-tasks/orphan-prompt/SKILL.md", "a prompt no task names\n")
        write("\(codeA)/scheduled-tasks/nightly-digest/notes.txt", "not the prompt: never carried\n")
        write("\(codeA)/CLAUDE.md", "# rules\n")
        write("\(codeA)/settings.json", #"{"env":{"DEPLOY_TOKEN":"\#(settingsEnvValue)","REGION":"eu-west-1"},"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}"#)
        write("\(codeA)/projects/-w-project/\(sid(110)).jsonl", #"{"type":"user","cwd":"/w/project","text":"hello"}"# + "\n")
        write("\(codeA)/projects/-w-project/\(sid(111)).jsonl", #"{"type":"user","cwd":"/w/project","text":"digest"}"# + "\n")
        for f in files("\(codeA)/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: "\(codeA)/projects/\(f)") }
    }
    plantA()
    let srcA = SessionsBackup.Source(profile: "a", dataDir: dataA, codeDir: codeA)

    // ---- what a backup takes
    if case .data(let d) = SessionsBackup.windowConfig(dataDir: dataA), let j = json(d) {
        check(j["mcpServers"] != nil && j["globalShortcut"] as? String == "Alt+Space" && (j["preferences"] as? [String: Any])?["epitaxyPrefs"] == nil && (j["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == true,
              "config: the window's file is taken whole but for its sidebar part (preferences.epitaxyPrefs)")
    } else { check(false, "config: the window's file is read") }
    // a name that would fake another line (a newline) or turn a line around (a bidi mark) is shown as one plain line
    let faked = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": ["echo\ncalendar: python3 cal.py": ["command": "e\u{202E}cho\u{2028}x"]]]))
    check(faked.count == 1 && faked[0].name == "echocalendar: python3 cal.py" && faked[0].runs.hasPrefix("echox") && !faked[0].runs.unicodeScalars.contains { $0.value == 0x202E },
          "config: server names and commands are one plain line each: no newline, no bidi mark, no line separator: \(faked)")
    check(SessionsRestore.taskName(["displayName": "Nightly\u{2067} digest\n"], id: "x") == "Nightly digest", "tasks: a task's name the same")
    check(SessionsBackup.mcpServers(fm.contents(atPath: dataA + "/claude_desktop_config.json")!).map { "\($0.name)=\($0.runs)" } == ["github=npx", "remote=a remote server"],
          "config: each MCP server by name and what it runs: its command, or a remote server (never an argument, env value, header or URL)")
    let found = Setup.scan(codeDir: codeA, home: home)
    let prompts = found.files.filter { $0.unit.kind == .task }.map(\.rel).sorted()
    check(prompts == ["scheduled-tasks/elsewhere-task/SKILL.md", "scheduled-tasks/nightly-digest/SKILL.md", "scheduled-tasks/orphan-prompt/SKILL.md", "scheduled-tasks/weekly-report/SKILL.md"],
          "scan: each task's prompt (scheduled-tasks/<id>/SKILL.md), nothing else of that folder: \(prompts)")
    check(Setup.pathProblem(["scheduled-tasks", "x", "SKILL.md"]) == nil && Setup.pathProblem(["scheduled-tasks", "x", "notes.txt"]) != nil && Setup.pathProblem(["scheduled-tasks", "Bad Id", "SKILL.md"]) != nil
          && Setup.pathProblem(["scheduled-tasks", "..", "SKILL.md"]) != nil && Setup.pathProblem(["Scheduled-Tasks", "x", "SKILL.md"]) != nil && Setup.pathProblem(["scheduled-tasks", "x.md"]) != nil,
          "names: only scheduled-tasks/<id>/SKILL.md, the id as the window keeps one; another file, another case or a bad id is refused")
    let bA = try! SessionsBackup.make(srcA, kind: .manual, place: place)
    let bAdir = SessionsBackup.folder(profile: "a", place: place).appendingPathComponent(bA.id).path
    check(bA.version == 3 && !bA.items.contains { $0.role == .config } && bA.configLeftOut == nil && !fm.fileExists(atPath: bAdir + "/config")
          && bA.items.filter { $0.role == .setup && $0.path.hasPrefix("setup/scheduled-tasks/") }.count == 4,
          "backup (plain): format 3, the 4 prompts, and no claude_desktop_config.json (only the encrypted export carries it)")
    check(holds(bAdir, envValue).isEmpty && holds(bAdir, headerValue).isEmpty && holds(bAdir, "mcpServers").isEmpty && !SessionsBackup.summary(bA).contains("MCP"),
          "backup (plain): no MCP env value, header or server list in any of its files: \(holds(bAdir, envValue))")
    let bAsettings = json(fm.contents(atPath: bAdir + "/setup/settings.json"))
    let bAitem = bA.items.first { $0.path == "setup/settings.json" }
    check(bA.envBlanked == true && (bAsettings?["env"] as? [String: String]) == ["DEPLOY_TOKEN": "", "REGION": ""] && bAsettings?["model"] as? String == "opus"
          && holds(bAdir, settingsEnvValue).isEmpty && bAitem?.sha == SwitchEngine.sha(fm.contents(atPath: bAdir + "/setup/settings.json") ?? Data())
          && bAitem?.bytes == Int64(fm.contents(atPath: bAdir + "/setup/settings.json")?.count ?? -1),
          "backup (plain): settings.json keeps its env names with blank values, the rest as parsed; the value's bytes are nowhere in it; the item's hash and size are the blanked file's")
    // a settings.json that isn't a JSON object is never copied raw: left out of the backup (with the scripts its hooks would run), and listed
    do {
        let cU = w + "/.claude-u"
        try? fm.removeItem(atPath: cU)
        write(cU + "/settings.json", #"{"env":{"X":"\#(settingsEnvValue)"},, not json"#); write(cU + "/CLAUDE.md", "rules\n")
        let bU = try! SessionsBackup.make(SessionsBackup.Source(profile: "u", dataDir: "", codeDir: cU), kind: .manual, window: false, place: place)
        let dirU = SessionsBackup.folder(profile: "u", place: place).appendingPathComponent(bU.id).path
        check(!bU.items.contains { $0.path == "setup/settings.json" } && bU.setupLeftOut?.contains(Setup.settingsUnreadable) == true && bU.items.contains { $0.path == "setup/CLAUDE.md" }
              && holds(dirU, settingsEnvValue).isEmpty, "backup (plain): a settings.json that isn't a JSON object is left out and listed, never copied raw: \(bU.setupLeftOut ?? [])")
        try? fm.removeItem(atPath: cU)
    }

    // ---- Export: the preview and the page's words
    let part = SessionsExport.Part(profile: "a", name: "A", source: srcA, emails: ["ultra-1@example.com"])
    let pv = SessionsExport.preview(part)!
    check(pv.config.present && pv.config.servers == ["github", "remote"] && pv.tasks == 4 && pv.setup.taskPrompts == 4 && !pv.setup.units.contains { $0.kind == .task },
          "preview: the config with 2 MCP servers; 4 tasks with 4 prompts, which aren't in the setup row's units")
    let zw = ExportWords.mcpWords(pv, image: false), iw = ExportWords.mcpWords(pv, image: true)
    check(zw.value == "left out of a zip" && zw.note?.hasPrefix("2 MCP servers (github, remote) and the window's other settings can hold tokens") == true && iw.value == "2 MCP servers (github, remote) and the window's other settings: in the encrypted disk image" && iw.note == nil,
          "export page: a zip says the MCP settings need the image; the image carries them: \(zw.value) / \(iw.value)")
    check(ExportWords.tasksNote(pv) == "4 scheduled tasks with their prompts: an import adds them only if you pick Add them, and paused", "export page: the tasks travel with their prompts and come back paused: \(ExportWords.tasksNote(pv) ?? "none")")

    // ---- Export: a zip
    let zipURL = URL(fileURLWithPath: out + "/A.zip")
    var zo: SessionsExport.Outcome?
    do { zo = try SessionsExport.run(SessionsExport.Job(parts: [part], keys: .leaveOut, destination: zipURL, rootName: "a-export", place: place)) } catch { check(false, "export (zip): \(error)") }
    check(zo != nil && zo!.configLeftOut && !zo!.configCarried && zo!.taskPrompts == 3, "export (zip): made; the MCP settings left out; 3 prompts go with their tasks (the orphan doesn't)")
    guard zo != nil, let oz = try? SessionsImport.open(zipURL, password: nil, place: place) else { print("(zip export failed; stopping)"); return }
    let mz = oz.parts[0].manifest
    check(oz.export.version == 3 && mz.version == 3 && !mz.items.contains { $0.role == .config } && mz.configLeftOut == "needs the encrypted disk image", "export (zip): format 3, no config item, and why it isn't there")
    check(Set(mz.items.filter { $0.role == .setup && $0.path.hasPrefix("setup/scheduled-tasks/") }.map(\.path)) == ["setup/scheduled-tasks/nightly-digest/SKILL.md", "setup/scheduled-tasks/weekly-report/SKILL.md", "setup/scheduled-tasks/elsewhere-task/SKILL.md"]
          && mz.setupLeftOut?.contains("scheduled task orphan-prompt's prompt (left out with its task)") == true, "export (zip): the tasks' prompts are in; a prompt no task names is left out and said")
    var zipHits: [String] = []
    for f in files(oz.tree.path) where (read(oz.tree.path + "/" + f) ?? "").contains(envValue) || (read(oz.tree.path + "/" + f) ?? "").contains(headerValue) || (read(oz.tree.path + "/" + f) ?? "").contains("mcpServers") { zipHits.append(f) }
    check(zipHits.isEmpty && fm.contents(atPath: zipURL.path)!.range(of: Data(envValue.utf8)) == nil && holds(oz.tree.path, settingsEnvValue).isEmpty,
          "export (zip): no MCP env value, header or server list anywhere in it, and no settings.json env value: \(zipHits)")
    // an export without the setup row still carries the prompts with their tasks
    let nz = URL(fileURLWithPath: out + "/A-nosetup.zip")
    if (try? SessionsExport.run(SessionsExport.Job(parts: [part], keys: .leaveOut, setup: false, destination: nz, rootName: "a-nosetup", place: place))) != nil, let o = try? SessionsImport.open(nz, password: nil, place: place) {
        let rels = o.parts[0].manifest.items.filter { $0.role == .setup }.map(\.path)
        check(rels.count == 3 && rels.allSatisfy { $0.hasPrefix("setup/scheduled-tasks/") }, "export (setup left out): only the tasks' prompts are in it, with their tasks: \(rels)")
        SessionsImport.discard(o.work)
    } else { check(false, "export (setup left out): made and opens") }

    // ---- Export: an encrypted image
    let dmgURL = URL(fileURLWithPath: out + "/A.dmg")
    var io: SessionsExport.Outcome?
    do { io = try SessionsExport.run(SessionsExport.Job(parts: [part], keys: .leaveOut, password: pw, destination: dmgURL, rootName: "a-image", place: place)) } catch { check(false, "export (image): \(error)") }
    check(io?.configCarried == true && io?.configLeftOut == false, "export (image): the MCP settings are carried")
    var oiMaybe: SessionsImport.Opened?
    if io != nil { do { oiMaybe = try SessionsImport.open(dmgURL, password: pw, place: place) } catch { check(false, "import (image): opens: \(error)") } }
    guard let oi = oiMaybe else { print("(image export failed; stopping)"); return }
    let imgConfig = json(fm.contents(atPath: oi.tree.path + "/profiles/p1/config/claude_desktop_config.json"))
    check(((imgConfig?["mcpServers"] as? [String: Any])?["github"] as? [String: Any]).flatMap { ($0["env"] as? [String: Any])?["GITHUB_TOKEN"] as? String } == envValue
          && (imgConfig?["preferences"] as? [String: Any])?["epitaxyPrefs"] == nil && oi.parts[0].manifest.items.first { $0.role == .config }?.original == "config/claude_desktop_config.json",
          "export (image): claude_desktop_config.json is in it whole, env values too, but not the sidebar part, and no path of this Mac")
    check(!(read(oi.tree.path + "/profiles/p1/config/claude_desktop_config.json") ?? sid(1)).contains(sid(1)), "export (image): a known account id in the config is its fingerprint (the leak check reads the file)")

    // ---- Import (image) into a profile that has nothing: left out by default
    let seatB = SeatID(account: sid(3), organization: sid(4))
    func target(_ name: String) -> (SessionsRestore.Target, data: String, code: String) {
        let d = w + "/Claude-\(name)", c = w + "/.claude-\(name)"
        try? fm.removeItem(atPath: d); try? fm.removeItem(atPath: c)
        try! fm.createDirectory(atPath: "\(d)/claude-code-sessions/\(seatB.account)/\(seatB.organization)", withIntermediateDirectories: true)
        try! fm.createDirectory(atPath: c + "/projects", withIntermediateDirectories: true)
        return (SessionsRestore.Target(profile: name, dataDir: d, codeDir: c, inUse: seatB), d, c)
    }
    let (tB, dB, cB) = target("b")
    let beforeB = tree(dB) + "\n" + tree(cB)
    let stB = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "b")
    check(!holds(stB.backup.dir.path + "/setup", settingsEnvValue).isEmpty && !holds(stB.backup.dir.path + "/config", envValue).isEmpty
          && SessionsBackup.load(profile: "b", id: stB.id, place: stB.stage)?.envBlanked == nil,
          "import (image): the staged backup keeps the image's settings.json env values and its MCP settings as they came (the only way to restore an image)")
    let p0 = SessionsRestore.plan(tB, stB.backup)
    check(p0.refusal == nil && p0.config.present && p0.config.leftOut && p0.config.status == .new && p0.configPieces.isEmpty && p0.config.servers.map(\.name) == ["github", "remote"],
          "import: the MCP settings are listed (2 servers) and left out by default: \(p0.refusal ?? "ok")")
    check(p0.taskPlan.present && p0.taskPlan.leftOut && p0.tasks.isEmpty && p0.taskPrompts.isEmpty && p0.taskPlan.coming.map(\.id) == ["nightly-digest", "weekly-report"],
          "import: the tasks are listed and left out by default; 2 can come: \(p0.taskPlan.coming.map(\.id))")
    check(p0.taskPlan.tasks.first { $0.id == "elsewhere-task" }?.why == "it names a prompt file somewhere else" && p0.taskPlan.tasks.first { $0.id == "Bad Id" }?.why == "its id isn't one the Claude window keeps",
          "import: a task whose filePath points elsewhere, and one with an id the window drops, are listed, never written")
    check(p0.taskSessions.count == 1 && p0.taskSessions[0].hasPrefix("Nightly digest") && !p0.entries.contains { $0.leaf == "local_\(sid(11)).json" } && !p0.transcripts.contains { $0.leaf == "\(sid(111)).jsonl" }
          && p0.entries.contains { $0.leaf == "local_\(sid(10)).json" }, "import: with the tasks left out, the session the task ran stays out, with its transcript, as before")
    let p1 = SessionsRestore.plan(tB, stB.backup, addConfig: true, addTasks: true)
    check(p1.configPieces.count == 1 && p1.tasks.count == 1 && p1.tasks[0].data != nil && p1.taskPrompts.count == 2 && p1.taskSessions.isEmpty
          && p1.entries.contains { $0.leaf == "local_\(sid(11)).json" } && p1.transcripts.contains { $0.leaf == "\(sid(111)).jsonl" },
          "import: Add them: the config, the task file and 2 prompts; the session the task ran now comes with it")
    let bB = try! SessionsImport.commit(stB)
    let rB = try! SessionsRestore.run(tB, bB, addConfig: true, addTasks: true, windowClosed: { true })
    let srcTasks = SessionsRestore.taskList(fm.contents(atPath: scopeA + "/scheduled-tasks.json")!)
    let gotTasks = SessionsRestore.taskList(fm.contents(atPath: "\(dB)/claude-code-sessions/\(sid(3))/\(sid(4))/scheduled-tasks.json") ?? Data())
    check(gotTasks.map { $0["id"] as? String ?? "" } == ["nightly-digest", "weekly-report"] && gotTasks.allSatisfy { $0["enabled"] as? Bool == false },
          "import: the task file is written with the 2 tasks, each enabled: false")
    check(gotTasks.allSatisfy { g in
        var s = srcTasks.first { $0["id"] as? String == g["id"] as? String } ?? [:]; s["enabled"] = false
        return same(s, g)
    }, "import: nothing else of a task changed (every other key and value as in the file)")
    check(read("\(cB)/scheduled-tasks/nightly-digest/SKILL.md") == read("\(codeA)/scheduled-tasks/nightly-digest/SKILL.md") && read("\(cB)/scheduled-tasks/weekly-report/SKILL.md") != nil
          && !fm.fileExists(atPath: "\(cB)/scheduled-tasks/elsewhere-task") && !fm.fileExists(atPath: "\(cB)/scheduled-tasks/nightly-digest/notes.txt") && mode("\(cB)/scheduled-tasks/nightly-digest/SKILL.md") == 0o600,
          "import: each added task's prompt is where the window looks for it, byte for byte, 0600; nothing for a task that isn't added")
    let gotConfig = fm.contents(atPath: dB + "/claude_desktop_config.json")
    check(gotConfig != nil && gotConfig == fm.contents(atPath: bB.dir.appendingPathComponent("config/claude_desktop_config.json").path) && mode(dB + "/claude_desktop_config.json") == 0o600,
          "import: claude_desktop_config.json is written whole, where the profile had none, 0600")
    check(rB.configAdded && rB.tasksAdded == ["Nightly digest", "Weekly report"] && fm.fileExists(atPath: "\(dB)/claude-code-sessions/\(sid(3))/\(sid(4))/local_\(sid(11)).json"),
          "import: the receipt says the MCP settings and the 2 tasks (paused) were added; the task's session came in with it")
    let uB = try! SessionsRestore.undo(rB.id, windowClosed: { true })
    check(uB.undone != nil && tree(dB) + "\n" + tree(cB) == beforeB && !fm.fileExists(atPath: cB + "/scheduled-tasks"), "import: Undo takes back exactly what was added (the config, the task file, the prompts and their folders)")

    // ---- Import into a profile that has its own: what is here stays, byte for byte; the missing servers and tasks are listed
    let (tC, dC, cC) = target("c")
    write(dC + "/claude_desktop_config.json", #"{"mcpServers":{"mine":{"command":"my-server"},"github":{"command":"other"}}}"#)
    let scopeC = "\(dC)/claude-code-sessions/\(sid(3))/\(sid(4))"
    write(scopeC + "/scheduled-tasks.json", #"{"scheduledTasks":[{"id":"weekly-report","displayName":"Weekly report","enabled":true}]}"#)
    write(cC + "/scheduled-tasks/nightly-digest/SKILL.md", "my own nightly prompt\n")
    let beforeC = tree(dC) + "\n" + tree(cC)
    let stC = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "c")
    let pC = SessionsRestore.plan(tC, stC.backup, addConfig: true, addTasks: true)
    check(pC.config.status == .here && pC.configPieces.isEmpty && pC.config.lacking == ["remote"] && WindowWords.lacking(pC.config)?.hasPrefix("1 server of the file that isn't here: remote.") == true,
          "import: a claude_desktop_config.json here stays; the server it lacks (remote) is listed, nothing merged: \(pC.config.lacking)")
    check(pC.taskPlan.status == .here && pC.tasks.isEmpty && pC.taskPrompts.isEmpty && pC.taskPlan.lacking.contains("Nightly digest") && !pC.taskPlan.lacking.contains("Weekly report")
          && pC.taskSessions.count == 1, "import: a task file here stays; the tasks it lacks are listed; the task's session stays out: \(pC.taskPlan.lacking)")
    let bC = try! SessionsImport.commit(stC)
    let rC = try! SessionsRestore.run(tC, bC, addConfig: true, addTasks: true, windowClosed: { true })
    let afterC = tree(dC) + "\n" + tree(cC)
    check(beforeC.split(separator: "\n").allSatisfy { afterC.contains($0) } && read(dC + "/claude_desktop_config.json") == #"{"mcpServers":{"mine":{"command":"my-server"},"github":{"command":"other"}}}"#
          && !rC.configAdded && rC.tasksAdded.isEmpty, "import: the config, the task file and the prompt here are byte-identical; nothing of the three was added")
    _ = try? SessionsRestore.undo(rC.id, windowClosed: { true })
    // a different prompt here for a task (no task file here): that task isn't written; the other one is
    let (tD, dD, cD) = target("d")
    write(cD + "/scheduled-tasks/nightly-digest/SKILL.md", "my own nightly prompt\n")
    let stD = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "d")
    let pD = SessionsRestore.plan(tD, stD.backup, addTasks: true)
    check(pD.taskPlan.tasks.first { $0.id == "nightly-digest" }?.why == "a different prompt for it is here" && pD.taskPlan.coming.map(\.id) == ["weekly-report"] && pD.taskPrompts.count == 1
          && pD.taskSessions.count == 1, "import: a task whose prompt here differs isn't written (nor its session); the other comes: \(pD.taskPlan.coming.map(\.id))")
    let bD = try! SessionsImport.commit(stD)
    _ = try! SessionsRestore.run(tD, bD, addTasks: true, windowClosed: { true })
    check(read(cD + "/scheduled-tasks/nightly-digest/SKILL.md") == "my own nightly prompt\n" && SessionsRestore.taskList(fm.contents(atPath: "\(dD)/claude-code-sessions/\(sid(3))/\(sid(4))/scheduled-tasks.json") ?? Data()).map { $0["id"] as? String ?? "" } == ["weekly-report"],
          "import: the prompt here is untouched; the task file holds only the task that came")
    // no account linked yet: the tasks can't be added, and say why
    let (tE0, _, _) = target("e")
    let tE = SessionsRestore.Target(profile: "e", dataDir: tE0.dataDir, codeDir: tE0.codeDir, inUse: nil)
    let stE = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "e")
    let pE = SessionsRestore.plan(tE, stE.backup, addTasks: true)
    check(pE.taskPlan.status == .blocked("the profile isn't linked to an account yet") && pE.tasks.isEmpty, "import: a profile without an account in use gets no task file, and the row says why")

    // ---- Import (zip): no MCP settings in it (the row says why); the tasks come all the same
    let (tF, dF, cF) = target("f")
    let stF = try! SessionsImport.materialize(oz, part: oz.parts[0], target: "f")
    let pF = SessionsRestore.plan(tF, stF.backup, addConfig: true, addTasks: true)
    check(!pF.config.present && pF.config.leftOutAtSource == "needs the encrypted disk image" && pF.configPieces.isEmpty && WindowWords.configValue(pF.config, name: "F", imported: true) == "not in the file: needs the encrypted disk image"
          && pF.tasks.count == 1 && pF.taskPrompts.count == 2, "import (zip): no MCP settings (and why), the tasks with their prompts")
    let bF = try! SessionsImport.commit(stF)
    _ = try! SessionsRestore.run(tF, bF, addConfig: true, addTasks: true, windowClosed: { true })
    check(!fm.fileExists(atPath: dF + "/claude_desktop_config.json") && fm.fileExists(atPath: cF + "/scheduled-tasks/weekly-report/SKILL.md"), "import (zip): nothing of the config written; the tasks' prompts are")
    SessionsImport.discard(oz.work)

    // ---- Restore from this Mac's own backup: today's rule (the account in use's file, only when none is here, as it was), the prompts too
    let tA = SessionsRestore.Target(profile: "a", dataDir: dataA, codeDir: codeA, inUse: seatA)
    let bkA = SessionsRestore.Backup(profile: "a", id: bA.id, place: place)
    let origTasks = fm.contents(atPath: scopeA + "/scheduled-tasks.json")
    try? fm.removeItem(atPath: scopeA + "/scheduled-tasks.json"); try? fm.removeItem(atPath: codeA + "/scheduled-tasks/weekly-report"); try? fm.removeItem(atPath: dataA + "/claude_desktop_config.json")
    try? fm.removeItem(atPath: codeA + "/settings.json")
    let pr = SessionsRestore.plan(tA, bkA, addConfig: true)
    check(pr.tasks.count == 1 && pr.tasks[0].data == nil && pr.taskPrompts.map(\.dirs) == [["scheduled-tasks", "weekly-report"]] && !pr.config.present && pr.config.leftOutAtSource == nil
          && pr.configPieces.isEmpty && !pr.taskPlan.imported,
          "restore: the missing task file comes back as it was, with the missing prompt; this Mac's own backup has no MCP settings, so no MCP row and nothing to add")
    let pr2 = SessionsRestore.plan(tA, bkA, addSetup: true)
    check(pr2.setup.envBlanked && pr2.setupPieces.contains { $0.rel == ["setup", "settings.json"] } && SetupRow.envBlankedWords.hasPrefix("Env values aren't kept in backups"),
          "restore: a settings.json that is missing comes back (Add them), and the row says its env values aren't kept in backups")
    let rrA = try! SessionsRestore.run(tA, bkA, addSetup: true, windowClosed: { true })
    check(fm.contents(atPath: scopeA + "/scheduled-tasks.json") == origTasks && SessionsRestore.taskList(origTasks!).first?["enabled"] as? Bool == true && fm.fileExists(atPath: codeA + "/scheduled-tasks/weekly-report/SKILL.md")
          && !fm.fileExists(atPath: dataA + "/claude_desktop_config.json") && rrA.tasksAdded.isEmpty && !rrA.configAdded,
          "restore: the task file is back byte for byte (not paused: this Mac's own tasks), the prompt too; no MCP settings")
    check((json(fm.contents(atPath: codeA + "/settings.json"))?["env"] as? [String: String]) == ["DEPLOY_TOKEN": "", "REGION": ""], "restore: settings.json comes back with its env names, blank")
    _ = try! SessionsRestore.undo(rrA.id, windowClosed: { true })
    check(!fm.fileExists(atPath: scopeA + "/scheduled-tasks.json") && !fm.fileExists(atPath: codeA + "/settings.json") && !fm.fileExists(atPath: codeA + "/scheduled-tasks/weekly-report"), "restore: Undo takes them back")
    plantA()
    // a settings.json that is here stays, also when the backup's is the blanked one
    let pr3 = SessionsRestore.plan(tA, bkA, addSetup: true)
    check(pr3.setup.entries.first { $0.unit.kind == .settings }?.status == .different && !pr3.setupPieces.contains { $0.rel == ["setup", "settings.json"] } && pr3.setup.settingsDiffer.contains("env.DEPLOY_TOKEN"),
          "restore: the settings.json here (with its values) stays; the backup's blank names show as a difference, never written over it")

    // ---- an export from a plain backup: the image carries the blank settings.json, the page says so; no MCP settings in it
    let bpart0 = SessionsExport.Part(profile: "a", name: "A", backup: bkA)
    let bpv0 = SessionsExport.preview(bpart0)!
    check(bpv0.setup.envBlanked && ExportWords.setupNotes(bpv0, setup: true, image: true).contains { $0.hasPrefix("settings.json comes with its env values blank") }
          && !ExportWords.setupNotes(bpv0, setup: true, image: false).contains { $0.contains("env values blank") } && !bpv0.config.present,
          "export (from a plain backup): the page says settings.json comes with blank env values (image); no MCP settings to carry")
    let fromBk = URL(fileURLWithPath: out + "/A-from-backup.dmg")
    if (try? SessionsExport.run(SessionsExport.Job(parts: [bpart0], keys: .leaveOut, password: pw, destination: fromBk, rootName: "a-from-backup", place: place))) != nil,
       let ob = try? SessionsImport.open(fromBk, password: pw, place: place) {
        check((json(fm.contents(atPath: ob.tree.path + "/profiles/p1/setup/settings.json"))?["env"] as? [String: String]) == ["DEPLOY_TOKEN": "", "REGION": ""]
              && holds(ob.tree.path, settingsEnvValue).isEmpty && !files(ob.tree.path).contains { $0.contains("config/") } && ob.parts[0].manifest.envBlanked == true,
              "export (image from a plain backup): the blank settings.json, no env value and no MCP settings in it")
        SessionsImport.discard(ob.work)
    } else { check(false, "export (image from a plain backup): made and opens") }

    // ---- an export never makes a file its own import refuses: a config over 8 MB (or a link, or not JSON) is left out at the source
    let big: [String: Any] = ["mcpServers": ["x": ["command": "x"]], "pad": String(repeating: "a", count: (8 << 20) + 16)]
    try! JSONSerialization.data(withJSONObject: big).write(to: URL(fileURLWithPath: dataA + "/claude_desktop_config.json"))
    let bpv = SessionsExport.preview(part)!
    check(!bpv.config.present && bpv.config.leftOut == "it is over 8 MB" && ExportWords.mcpWords(bpv, image: true).value == "claude_desktop_config.json left out (it is over 8 MB)",
          "export: a claude_desktop_config.json over 8 MB is left out at the source, and the page says so: \(ExportWords.mcpWords(bpv, image: true).value)")
    let bigURL = URL(fileURLWithPath: out + "/A-big.dmg")
    if (try? SessionsExport.run(SessionsExport.Job(parts: [part], keys: .leaveOut, password: pw, destination: bigURL, rootName: "a-big", place: place))) != nil {
        let o = try? SessionsImport.open(bigURL, password: pw, place: place)
        check(o != nil && o?.parts[0].manifest.items.contains { $0.role == .config } == false && o?.parts[0].manifest.configLeftOut == "it is over 8 MB", "export (image): made without it, and its own import opens it")
        if let o { SessionsImport.discard(o.work) }
    } else { check(false, "export (image) with a config over 8 MB at the source: made") }
    write(dataA + "/claude_desktop_config.json", "not json {")
    check(SessionsBackup.windowConfig(dataDir: dataA) == .leftOut("it isn't a JSON object"), "export: a config that isn't a JSON object is left out")
    try? fm.removeItem(atPath: dataA + "/claude_desktop_config.json"); write(w + "/elsewhere-config.json", #"{"mcpServers":{}}"#)
    symlink(w + "/elsewhere-config.json", dataA + "/claude_desktop_config.json")
    check(SessionsBackup.windowConfig(dataDir: dataA) == .leftOut("it is a link"), "export: a config that is a link is never followed")
    plantA()

    // ---- doctored images
    func doctored(_ name: String, zip: Bool = false, edit: (inout SessionsBackup.Manifest, inout ExportManifest, URL) throws -> Void) -> String {
        let work = w + "/doctor-\(name)"
        try? fm.removeItem(atPath: work); try! fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        _ = Tool.run("/usr/bin/ditto", [oi.tree.path, work + "/" + oi.tree.lastPathComponent])
        let root = URL(fileURLWithPath: work + "/" + oi.tree.lastPathComponent)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var m = try dec.decode(SessionsBackup.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("profiles/p1/backup.json")))
            var ex = try dec.decode(ExportManifest.self, from: Data(contentsOf: root.appendingPathComponent("export.json")))
            try edit(&m, &ex, root.appendingPathComponent("profiles/p1"))
            m.bytes = m.items.reduce(0) { $0 + $1.bytes }
            try enc.encode(m).write(to: root.appendingPathComponent("profiles/p1/backup.json"))
            ex.parts[0].bytes = m.bytes; ex.bytes = m.bytes
            if zip { ex.container = "zip" }
            try enc.encode(ex).write(to: root.appendingPathComponent("export.json"))
        } catch { return "doctoring failed: \(error)" }
        let file = URL(fileURLWithPath: out + "/\(name).\(zip ? "zip" : "dmg")")
        try? fm.removeItem(at: file)
        let r = zip ? Tool.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", root.path, file.path])
                    : Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", work, "-volname", "doctored", "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", file.path], stdin: Data(pw.utf8), secret: pw)
        guard r?.status == 0 else { return "file not made: \(r?.err ?? "")" }
        do { let x = try SessionsImport.open(file, password: zip ? nil : pw, place: place); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    func setConfig(_ m: inout SessionsBackup.Manifest, _ p: URL, _ data: Data) throws {
        try data.write(to: p.appendingPathComponent("config/claude_desktop_config.json"))
        if let i = m.items.firstIndex(where: { $0.role == .config }) { m.items[i].bytes = Int64(data.count) }
    }
    check(doctored("w-ok") { _, _, _ in } == "OPENED", "(an untouched copy of the image opens)")
    let huge = doctored("w-huge-config") { m, _, p in try setConfig(&m, p, Data(("{\"pad\":\"" + String(repeating: "a", count: (8 << 20) + 16) + "\"}").utf8)) }
    check(huge.contains("over 8 MB"), "hostile (image): a claude_desktop_config.json over 8 MB is refused whole, never read: \(huge.prefix(90))")
    let notJSON = doctored("w-config-not-json") { m, _, p in try setConfig(&m, p, Data("not json at all".utf8)) }
    check(notJSON.contains("isn't a JSON object"), "hostile (image): a config that isn't a JSON object is refused whole: \(notJSON.prefix(90))")
    let arrayJSON = doctored("w-config-array") { m, _, p in try setConfig(&m, p, Data("[1,2,3]".utf8)) }
    check(arrayJSON.contains("isn't a JSON object"), "hostile (image): a config that is JSON but not an object is refused whole: \(arrayJSON.prefix(90))")
    let linked = doctored("w-config-link") { m, _, p in
        let c = p.appendingPathComponent("config/claude_desktop_config.json")
        try fm.removeItem(at: c); symlink("/etc/hosts", c.path)
    }
    check(linked != "OPENED" && linked.contains("link"), "hostile (image): a config that is a link is refused whole, never followed: \(linked.prefix(90))")
    let folder = doctored("w-config-folder") { m, _, p in
        let c = p.appendingPathComponent("config/claude_desktop_config.json")
        try fm.removeItem(at: c); try fm.createDirectory(at: c, withIntermediateDirectories: true); try Data("x".utf8).write(to: c.appendingPathComponent("inside.json"))
    }
    check(folder != "OPENED", "hostile (image): a folder where the config should be is refused whole: \(folder.prefix(90))")
    let elsewhere = doctored("w-config-elsewhere") { m, _, p in
        try fm.moveItem(at: p.appendingPathComponent("config/claude_desktop_config.json"), to: p.appendingPathComponent("config/settings.json"))
        if let i = m.items.firstIndex(where: { $0.role == .config }) { m.items[i].path = "config/settings.json" }
    }
    check(elsewhere.contains("in a place an export doesn't keep it"), "hostile (image): a config under another name or place is refused whole: \(elsewhere.prefix(90))")
    let inZip = doctored("w-config-in-zip", zip: true) { _, _, _ in }
    check(inZip.contains("A zip carries no MCP settings"), "hostile (zip): a zip that holds the config is refused whole: \(inZip.prefix(90))")
    let v2config = doctored("w-v2-with-config") { m, ex, _ in m.version = 2; ex.version = 2 }
    check(v2config.contains("in a place an export doesn't keep it") || v2config.contains("doesn't carry"), "format: a version 2 file can't hold the config or a task's prompt (they came with 3): refused: \(v2config.prefix(90))")
    let v2 = doctored("w-v2") { m, ex, p in
        m.version = 2; ex.version = 2
        for it in m.items where it.role == .config || it.path.hasPrefix("setup/scheduled-tasks/") { try fm.removeItem(at: p.appendingPathComponent(it.path)) }
        m.items.removeAll { $0.role == .config || $0.path.hasPrefix("setup/scheduled-tasks/") }
        try fm.removeItem(at: p.appendingPathComponent("config")); try fm.removeItem(at: p.appendingPathComponent("setup/scheduled-tasks"))
    }
    check(v2 == "OPENED", "format: a version 2 file (setup, no window settings) is read: \(v2.prefix(90))")
    let v4 = doctored("w-v4") { m, ex, _ in m.version = 4; ex.version = 4 }
    check(v4.contains("newer cl_audit"), "format: a version 4 file is refused with the newer-cl_audit words: \(v4.prefix(90))")
    let orphan = doctored("w-prompt-without-task") { m, _, p in
        let data = Data("a prompt no task names\n".utf8)
        try fm.createDirectory(at: p.appendingPathComponent("setup/scheduled-tasks/orphan-prompt"), withIntermediateDirectories: true)
        try data.write(to: p.appendingPathComponent("setup/scheduled-tasks/orphan-prompt/SKILL.md"))
        m.items.append(SessionsBackup.Item(role: .setup, original: "setup/scheduled-tasks/orphan-prompt/SKILL.md", path: "setup/scheduled-tasks/orphan-prompt/SKILL.md", bytes: Int64(data.count), sha: SwitchEngine.sha(data)))
    }
    check(orphan.contains("without its task"), "hostile (image): a task's prompt whose task isn't in the file is refused whole: \(orphan.prefix(90))")
    let notesFile = doctored("w-task-other-file") { m, _, p in
        let data = Data("#!/bin/sh\n".utf8)
        try data.write(to: p.appendingPathComponent("setup/scheduled-tasks/nightly-digest/watching.js"))
        m.items.append(SessionsBackup.Item(role: .setup, original: "setup/scheduled-tasks/nightly-digest/watching.js", path: "setup/scheduled-tasks/nightly-digest/watching.js", bytes: Int64(data.count), sha: SwitchEngine.sha(data)))
    }
    check(notesFile.contains("doesn't carry"), "hostile (image): another file in a task's folder (watching.js) is refused whole: \(notesFile.prefix(90))")
    let execPrompt = doctored("w-task-exec") { m, _, _ in
        if let i = m.items.firstIndex(where: { $0.path == "setup/scheduled-tasks/nightly-digest/SKILL.md" }) { m.items[i].exec = true }
    }
    check(execPrompt.contains("executable"), "hostile (image): a task's prompt marked executable is refused whole: \(execPrompt.prefix(90))")
    // a crafted task: an id that climbs out, a filePath outside, a task that isn't an object: opens (the file's tasks are only data),
    // and none of them is ever written; nothing lands outside the profile's folders
    let craftedName = "w-crafted-tasks"
    let crafted = doctored(craftedName) { m, _, p in
        guard let it = m.items.first(where: { $0.role == .window && $0.path.hasSuffix("/scheduled-tasks.json") }) else { return }
        let f = p.appendingPathComponent(it.path)
        var j = json(try Data(contentsOf: f)) ?? [:]
        var list = (j["scheduledTasks"] as? [Any]) ?? []
        list.append(["id": "../../escape", "displayName": "Climb", "enabled": true])
        list.append(["id": "outside-path", "displayName": "Outside", "enabled": true, "filePath": "/private/tmp/w-escape/SKILL.md"])
        list.append("not an object")
        list.append(["displayName": "No id", "enabled": true])
        j["scheduledTasks"] = list
        let data = try JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: f)
        if let i = m.items.firstIndex(where: { $0.path == it.path }) { m.items[i].bytes = Int64(data.count) }
    }
    check(crafted == "OPENED", "hostile (image): crafted tasks in the task file are only data: the file opens (\(crafted.prefix(80)))")
    if crafted == "OPENED", let oc = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(craftedName).dmg"), password: pw, place: place) {
        let (tG, dG, cG) = target("g")
        let stG = try! SessionsImport.materialize(oc, part: oc.parts[0], target: "g")
        let pG = SessionsRestore.plan(tG, stG.backup, addTasks: true)
        check(pG.taskPlan.tasks.first { $0.id.contains("escape") }?.why == "its id isn't one the Claude window keeps" && pG.taskPlan.tasks.first { $0.id == "outside-path" }?.why != nil
              && pG.taskPlan.coming.map(\.id) == ["nightly-digest", "weekly-report"], "hostile: a climbing id and a filePath outside are listed and not added: \(pG.taskPlan.tasks.map { "\($0.id):\($0.why ?? "ok")" })")
        let bG = try! SessionsImport.commit(stG)
        _ = try? SessionsRestore.run(tG, bG, addTasks: true, windowClosed: { true })
        let written = SessionsRestore.taskList(fm.contents(atPath: "\(dG)/claude-code-sessions/\(sid(3))/\(sid(4))/scheduled-tasks.json") ?? Data()).map { $0["id"] as? String ?? "" }
        check(written == ["nightly-digest", "weekly-report"] && !fm.fileExists(atPath: "/private/tmp/w-escape") && !fm.fileExists(atPath: w + "/escape") && files(cG).allSatisfy { !$0.contains("escape") },
              "hostile: only the 2 proper tasks are written; nothing outside the profile's folders: \(written)")
        SessionsImport.discard(oc.work)
    }

    // a crafted config that carries the sidebar part (its folder permission modes among it): "Add them" never brings that part in
    let sidebarName = "w-config-with-sidebar"
    let withSidebar = doctored(sidebarName) { m, _, p in
        let j: [String: Any] = ["mcpServers": ["x": ["command": "x"]],
                                "preferences": ["epitaxyPrefs": ["epitaxy-folder-permission-mode-v2.\(sid(3))": ["/w/project": "bypassPermissions"]], "menuBarEnabled": true]]
        try setConfig(&m, p, try JSONSerialization.data(withJSONObject: j))
    }
    if withSidebar == "OPENED", let os = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(sidebarName).dmg"), password: pw, place: place) {
        let (tS, dS, _) = target("s")
        let stS = try! SessionsImport.materialize(os, part: os.parts[0], target: "s")
        let bS = try! SessionsImport.commit(stS)
        _ = try? SessionsRestore.run(tS, bS, addConfig: true, windowClosed: { true })
        let got = json(fm.contents(atPath: dS + "/claude_desktop_config.json"))
        check(got?["mcpServers"] != nil && (got?["preferences"] as? [String: Any])?["epitaxyPrefs"] == nil && (got?["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == true
              && !(read(dS + "/claude_desktop_config.json") ?? "permission-mode").contains("permission-mode"),
              "hostile (image): a config carrying the sidebar part (folder permission modes) is written without it; the rest comes")
        SessionsImport.discard(os.work)
    } else { check(false, "hostile (image): the config with a sidebar part opens: \(withSidebar.prefix(80))") }

    // ---- the older rules refuse version 3: 26.11.7 reads `version == 1`, 26.11.8 `<= 2`; and a reader without the config role can't decode it
    let v3 = oi.parts[0].manifest.version
    check(v3 == 3 && !(v3 == 1) && !(v3 <= 2), "format: this build writes 3, which 26.11.7's guard (== 1) and 26.11.8's (<= 2) refuse")
    enum OldRole: String, Codable { case window, sidebar, record, transcript, setup }
    struct OldItem: Codable { var role: OldRole; var path: String }
    struct OldManifest: Codable { var version: Int; var items: [OldItem] }
    check((try? JSONDecoder().decode(OldManifest.self, from: fm.contents(atPath: oi.tree.path + "/profiles/p1/backup.json")!)) == nil,
          "format: a backup.json with the config item can't even be decoded by a reader that doesn't know the role (26.11.8's), so it never reads it half")
    SessionsImport.discard(oi.work)
    try? fm.removeItem(atPath: w)
    resetRestores()
}

// ================================================================== part 2: the rows' words
MainActor.assumeIsolated {
    var cp = SessionsRestore.ConfigPlan()
    cp.present = true; cp.servers = [.init(name: "github", runs: "npx"), .init(name: "remote", runs: "a remote server")]
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "claude_desktop_config.json with 2 MCP servers: left out", "rows: MCP left out by default: \(WindowWords.configValue(cp, name: "Work", imported: true))")
    cp.leftOut = false
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "claude_desktop_config.json with 2 MCP servers: added" && WindowWords.configDone(cp, added: true, undone: false, name: "Work", imported: true) == "added: claude_desktop_config.json with 2 MCP servers",
          "rows: MCP added, and the done line")
    cp.status = .here; cp.lacking = ["remote"]
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "not added: Work's claude_desktop_config.json stays as it is"
          && WindowWords.configDone(cp, added: false, undone: false, name: "Work", imported: true) == "not added: Work's claude_desktop_config.json stays as it is",
          "rows: a file here stays; the done line says why it wasn't added: \(WindowWords.configDone(cp, added: false, undone: false, name: "Work", imported: true))")
    check(WindowWords.configDone(cp, added: true, undone: true, name: "Work", imported: true) == "claude_desktop_config.json with 2 MCP servers: was added, and taken away again", "rows: after Undo")
    check(WindowWords.serversKey(cp, imported: true) == ("What the file's servers would run (not added: your claude_desktop_config.json stays)", "Hide (not added: your claude_desktop_config.json stays)"),
          "rows: with a file here, both keys of the servers' list keep the not-added caveat")
    cp.status = .blocked("the profile has no Claude window folder")
    check(WindowWords.serversKey(cp, imported: true).hide == "Hide (not added: it can't be added here)", "rows: …and when it can't be added")
    cp.status = .new
    check(WindowWords.serversKey(cp, imported: true) == ("What each server runs", "Hide what they run"), "rows: a file that is added: plain keys")
    check(WindowWords.tasksKey(1, imported: true) == "Show the tasks (1 can't come)" && WindowWords.tasksKey(1, imported: false) == "Show the tasks (1 without the backup's prompt)" && WindowWords.tasksKey(0, imported: false) == "Show the tasks",
          "rows: the tasks' key: an import's can't come; a restore's all come back, some without the backup's prompt")
    var tp = SessionsRestore.TaskPlan()
    tp.present = true; tp.imported = true
    tp.tasks = [.init(id: "a", name: "Nightly digest", why: nil), .init(id: "b", name: "Bad", why: "its prompt isn't in the file")]
    check(WindowWords.tasksValue(tp, imported: true) == "1 task: left out", "rows: tasks left out by default: \(WindowWords.tasksValue(tp, imported: true))")
    tp.leftOut = false
    check(WindowWords.tasksValue(tp, imported: true) == "1 task: added, paused" && WindowWords.taskLines(tp) == ["Nightly digest", "Bad: not added, its prompt isn't in the file"], "rows: tasks added, paused; the list says which can't come and why")
    check(WindowWords.turnOn("the usual Claude app") == "Paused, so nothing runs twice: turn each on with its own switch in the scheduled tasks of the usual Claude app. cl_audit never changes a task after this.",
          "rows: where to turn them on")
    check(WindowWords.tasksDone(["Nightly digest"], undone: false, leftOut: false) == "added, paused: Nightly digest" && WindowWords.tasksDone([], undone: false, leftOut: true) == "none added (left out)"
          && WindowWords.tasksDone(["Nightly digest", "Weekly"], undone: true, leftOut: false) == "2 tasks were added, paused, and taken away again", "rows: the done and undone lines")
    tp.status = .here; tp.lacking = ["Nightly digest"]
    check(WindowWords.tasksValue(tp, imported: true) == "not added: the task file here stays as it is" && WindowWords.taskLines(tp).last == "Not in the task file here (it stays): Nightly digest", "rows: a task file here stays; the tasks it lacks are listed")
    var rp = SessionsRestore.TaskPlan(); rp.present = true; rp.writes = true; rp.prompts = 1; rp.leftOut = false
    check(WindowWords.tasksValue(rp, imported: false) == "the task file comes back as it was, with 1 prompt", "rows: a restore puts its own task file back as it was")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

extension URL {
    /// The URL, after its folder is made.
    func createDirs() -> URL { try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true); return self }
}
