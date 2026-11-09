// Setup checks for cl_audit: Claude Code's setup (CLAUDE.md and the .md files it includes, skills, agents, commands, output styles,
// keybindings, settings.json with the scripts its hooks point to, the plugin list) travels with Export, Import, Backup and Restore.
// Sources/SessionsSetup.swift (what is carried and how it is found), SessionsRestoreSetup.swift (the plan and the rules of an add),
// the Export, Import and Restore pages' setup rows, and the format (version 2 brought setup; this build writes 3 and reads 1 to 3).
//
// Part 1 works on real files: the scan (links, includes, build leftovers, sign-in names), an export to a zip and to an encrypted
// image, hostile files made from the good zip (mkhostile.py), an import and a restore into folders that already hold some of it,
// Undo. Part 2 drives the pages' runners (the Export page's row and menu, the Found line, the Import and Restore rows).
// Runs only with CFFIXED_USER_HOME = .../Checks/.work/setup/home (Checks/run.sh sets and guards it). Fake data only: example.com
// addresses, obviously fake keys (cut by an empty interpolation so no whole key is committed), made-up folders. Nothing here opens an
// app, the Dock or Terminal; the encrypted image is made and opened with hdiutil in the throwaway folder.

import AppKit
import Foundation

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/setup/home") else { print("refusing: HOME is \(home)"); exit(2) }
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
func files(_ dir: String) -> [String] {   // relative paths of regular files
    var out: [String] = []
    if let e = fm.enumerator(atPath: dir) { for case let r as String in e { var isDir: ObjCBool = false; if fm.fileExists(atPath: dir + "/" + r, isDirectory: &isDir), !isDir.boolValue { out.append(r) } } }
    return out.sorted()
}
func names(_ dir: String) -> [String] { (try? fm.contentsOfDirectory(atPath: dir)) ?? [] }
/// Every file's path and bytes under a folder, as one string: "unchanged" means equal.
func tree(_ dir: String) -> String {
    files(dir).map { r in "\(r)=\(SwitchEngine.sha(fm.contents(atPath: dir + "/" + r) ?? Data()))" }.joined(separator: "\n")
}
func eSh(_ exe: String, _ args: [String], stdin: Data? = nil) -> (status: Int32, out: String, err: String) {
    guard let r = Tool.run(exe, args, stdin: stdin) else { return (-1, "", "no start") }
    return (r.status, r.out, r.err)
}
func resetRestores() { try? fm.removeItem(at: SessionsRestore.root); try? fm.removeItem(at: SwitchEngine.root) }
func mode(_ path: String) -> Int { var s = stat(); lstat(path, &s); return Int(s.st_mode & 0o7777) }
let ghKey = "gh\("")p_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE0000"

// ================================================================== part 1: the files
MainActor.assumeIsolated {
    resetRestores(); SessionsRestore.runningSessions = { [] }
    let e2 = home + "/e2"
    try? fm.removeItem(atPath: e2)
    try! fm.createDirectory(atPath: e2, withIntermediateDirectories: true)
    let ecode = e2 + "/.claude-e2", out = e2 + "/out", elsewhere = e2 + "/elsewhere"
    let eplace = URL(fileURLWithPath: e2 + "/place")
    try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)
    BackupPrefs.shared.place = eplace.path

    func w(_ c: String, _ rel: String, _ text: String, exec: Bool = false) {
        write("\(c)/\(rel)", text)
        if exec { chmod("\(c)/\(rel)", 0o755) }
    }
    /// A made-up Claude Code folder with a setup in it (fake keys, example.com addresses only).
    func plant(_ c: String, links: Bool) {
        try? fm.removeItem(atPath: c)
        w(c, "CLAUDE.md", "# rules\nmail me@example.com anytime\n@docs/style.md\nsee @~/e2/out-of-folder/outside.md and @../escape.md\n```\n@docs/in-fence.md\n```\nand `@docs/inline.md` too\n")
        w(c, "docs/style.md", "style rules\n @deep.md\n"); w(c, "docs/deep.md", "deep rules\n")
        w(c, "docs/in-fence.md", "not included"); w(c, "docs/inline.md", "not included")
        w(c, "skills/alpha/SKILL.md", "---\nname: alpha\n---\nRun refs/notes.md then run.sh\n"); w(c, "skills/alpha/run.sh", "#!/bin/sh\necho alpha\n", exec: true)
        w(c, "skills/alpha/refs/notes.md", "notes"); w(c, "skills/alpha/auth.py", "print('auth helper')\n")
        w(c, "skills/alpha/token-counter.md", "counts tokens"); w(c, "skills/alpha/credentials-guide.md", "how to store credentials")
        w(c, "skills/alpha/.git/config", "[remote \"origin\"]\n url = https://user:token@example.com/x.git\n"); w(c, "skills/alpha/__pycache__/a.pyc", "x")
        w(c, "skills/alpha/.DS_Store", "x"); w(c, "skills/alpha/.credentials.json", "{\"t\":\"x\"}")
        w(c, "skills/keyed/SKILL.md", "keyed skill"); w(c, "skills/keyed/run.py", "TOKEN = '\(ghKey)'\n")
        w(c, "agents/helper.md", "helper agent"); w(c, "agents/team/two.md", "team two"); w(c, "commands/ship.md", "ship it")
        w(c, "output-styles/terse.md", "be terse"); w(c, "keybindings.json", "{\"bindings\":[]}")
        w(c, "settings.json", "{\"env\":{\"E2_FAKE_ENV\":\"not-a-real-secret\"},\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"\(c)/bin/guard.sh --strict\"}]}],\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(e2)/bin/outside.sh\"},{\"type\":\"command\",\"command\":\"/opt/none-e2/gone.sh\"}]}]},\"statusLine\":{\"type\":\"command\",\"command\":\"bash $HOME/e2/.claude-e2/bin/status.sh\"},\"permissions\":{\"allow\":[\"Bash(ls:*)\"]}}")
        w(c, "bin/guard.sh", "#!/bin/sh\nexit 0\n", exec: true); w(c, "bin/status.sh", "#!/bin/sh\necho ok\n", exec: true); w(c, "bin/unused.sh", "#!/bin/sh\n", exec: true)
        w(c, "plugins/installed_plugins.json", "{\"plugins\":{\"a@m\":{},\"b@m\":{}}}"); w(c, "plugins/known_marketplaces.json", "{\"m\":{\"url\":\"https://user:token@example.com/m.git\"}}")
        w(c, "plugins/cache/x/y.txt", "cache"); w(c, "settings.local.json", "{\"local\":true}"); w(c, ".claude.json", "{\"oauthAccount\":{}}")
        w(c, "projects/-p/\(sid(901)).jsonl", "{\"cwd\":\"/x\",\"text\":\"token \(ghKey)\"}\n"); w(c, "projects/-p/\(sid(902)).jsonl", "{\"cwd\":\"/x\",\"text\":\"also \(ghKey)\"}\n")
        for f in files("\(c)/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: "\(c)/projects/\(f)") }
        if links {
            try? fm.createDirectory(atPath: elsewhere + "/skills/foo", withIntermediateDirectories: true); write(elsewhere + "/skills/foo/SKILL.md", "foreign")
            write(elsewhere + "/refs/r.md", "r"); write(elsewhere + "/agents/x.md", "x")
            symlink(elsewhere + "/skills/foo", c + "/skills/linkedskill")
            w(c, "skills/haslink/SKILL.md", "has a link inside"); symlink(elsewhere + "/refs", c + "/skills/haslink/ref")
            symlink(elsewhere + "/agents/x.md", c + "/agents/linked.md")
        }
    }
    write(e2 + "/out-of-folder/outside.md", "outside include"); write(e2 + "/bin/outside.sh", "#!/bin/sh\n"); chmod(e2 + "/bin/outside.sh", 0o755)
    plant(ecode, links: true)

    // ---- a scheduled task's sessions are known by the real key, scheduledTaskId, exactly
    let tn = ["t1": "Nightly digest"]
    check(SessionsRestore.taskOrigin(Data(#"{"scheduledTaskId":"t1","title":"x"}"#.utf8), names: tn) == "Nightly digest" && SessionsRestore.taskOrigin(Data(#"{"scheduledTaskId":"t9"}"#.utf8), names: tn) == "t9"
          && SessionsRestore.taskOrigin(Data(#"{"myScheduledTaskName":"Guess","scheduledTask":"t1"}"#.utf8), names: tn) == nil && SessionsRestore.taskOrigin(Data(#"{"scheduledTaskId":""}"#.utf8), names: tn) == nil,
          "scheduled tasks: an entry's scheduledTaskId is looked up in the task file (displayName), else shown as the id; a key that merely looks like it is not one")

    // ---- the scan
    let found = Setup.scan(codeDir: ecode, home: home)
    let rels = Set(found.files.map(\.rel))
    let zipRels: Set<String> = ["CLAUDE.md", "docs/style.md", "docs/deep.md", "skills/alpha/SKILL.md", "skills/alpha/run.sh", "skills/alpha/refs/notes.md", "skills/alpha/auth.py",
                                "skills/alpha/token-counter.md", "skills/alpha/credentials-guide.md", "skills/keyed/SKILL.md", "skills/keyed/run.py", "agents/helper.md", "agents/team/two.md",
                                "commands/ship.md", "output-styles/terse.md", "keybindings.json", "plugins/installed_plugins.json"]
    let allRels = zipRels.union(["settings.json", "bin/guard.sh", "bin/status.sh", "plugins/known_marketplaces.json"])
    check(rels == allRels, "scan: CLAUDE.md and the .md files it includes (also from an included file), skills with their scripts, agents, commands, output styles, keybindings, settings.json, the scripts it points to and the plugin list: \(rels.symmetricDifference(allRels).sorted())")
    check(!rels.contains("docs/in-fence.md") && !rels.contains("docs/inline.md") && !rels.contains("bin/unused.sh") && !rels.contains("settings.local.json") && !rels.contains(".claude.json") && !rels.contains { $0.hasPrefix("plugins/cache") } && !rels.contains { $0.hasPrefix("projects") },
          "scan: an @ in a code fence or code span, a script nothing points to, settings.local.json, .claude.json, plugin caches and the transcripts are never carried")
    check(rels.contains("skills/alpha/auth.py") && rels.contains("skills/alpha/token-counter.md") && rels.contains("skills/alpha/credentials-guide.md") && found.leftOutNames == ["skills/alpha/.credentials.json"],
          "scan: auth.py, token-counter.md and credentials-guide.md are legitimate skill files; only the exact excluded name (.credentials.json) is left out: \(found.leftOutNames)")
    check(found.leftOutBuild >= 3 && !rels.contains { $0.contains(".git/") || $0.contains("__pycache__") || $0.hasSuffix(".DS_Store") }, "scan: .git, __pycache__ and .DS_Store inside a skill are left out and counted (\(found.leftOutBuild))")
    check(found.linked.map(\.label).sorted() == ["agent linked.md", "skill haslink (it holds a link)", "skill linkedskill"] && found.linked.allSatisfy { $0.target.hasPrefix(elsewhere) },
          "scan: a linked skill, a skill that holds a link anywhere (left out whole) and a linked agent are left out and listed with where they point: \(found.linked.map(\.label))")
    check(!rels.contains { $0.hasPrefix("skills/haslink") || $0.hasPrefix("skills/linkedskill") } && !rels.contains("agents/linked.md"), "scan: nothing of them is carried, nothing was followed")
    check(found.outside.contains { $0.hasPrefix("CLAUDE.md includes ~/e2/out-of-folder/outside.md: outside ") } && found.outside.contains { $0.contains("includes ../escape.md") } && found.outside.contains { $0.contains("hook script outside") && $0.contains("outside.sh") }
          && !found.outside.contains { $0.contains("gone.sh") }, "scan: an include and a hook script outside the folder are listed, not carried (a path that isn't there isn't listed): \(found.outside)")
    check(found.files.first { $0.rel == "skills/alpha/run.sh" }?.exec == true && found.files.first { $0.rel == "agents/helper.md" }?.exec == false && found.files.first { $0.rel == "bin/guard.sh" }?.exec == true, "scan: the owner-execute bit is read")
    // links in other places: CLAUDE.md, skills/, an included file
    let c2 = e2 + "/.claude-e2b", c3 = e2 + "/.claude-e2c"
    try? fm.createDirectory(atPath: c2, withIntermediateDirectories: true); write(elsewhere + "/CLAUDE.md", "foreign claude"); symlink(elsewhere + "/CLAUDE.md", c2 + "/CLAUDE.md")
    try? fm.createDirectory(atPath: elsewhere + "/skillsdir/s1", withIntermediateDirectories: true); write(elsewhere + "/skillsdir/s1/SKILL.md", "x"); symlink(elsewhere + "/skillsdir", c2 + "/skills")
    w(c3, "CLAUDE.md", "@linked-inc.md\n"); symlink(elsewhere + "/CLAUDE.md", c3 + "/linked-inc.md")
    let f2 = Setup.scan(codeDir: c2, home: home), f3 = Setup.scan(codeDir: c3, home: home)
    check(f2.files.isEmpty && f2.linked.map(\.label).sorted() == ["CLAUDE.md", "skills"] && f3.files.map(\.rel) == ["CLAUDE.md"] && f3.linked.first?.label == "included file linked-inc.md",
          "scan: a linked CLAUDE.md, a linked skills/ and a linked included file are left out and listed, never followed: \(f2.linked.map(\.label)) \(f3.linked.map(\.label))")
    check(Setup.pathProblem(["skills", "x", "settings.json"]) != nil && Setup.pathProblem(["settings.json"]) == nil && Setup.pathProblem(["settings.local.json"]) != nil && Setup.pathProblem([".claude.json"]) != nil
          && Setup.pathProblem(["skills", "a", "auth.py"]) == nil && Setup.pathProblem(["skills", "a", "credentials-guide.md"]) == nil && Setup.pathProblem(["plugins", "cache", "x"]) != nil
          && Setup.pathProblem(["projects", "a.md"]) != nil && Setup.pathProblem(["skills", "x.md"]) != nil && Setup.pathProblem(["skills", "a", ".git", "c"]) != nil,
          "names: only the exact excluded names and places are refused; sign-in-like words in a skill file's name are fine")
    // a name that folds to a place that is never carried (or a place that is) is the same place on this Mac's disks
    check(Setup.pathProblem(["Skills", "a", "x.md"]) != nil && Setup.pathProblem(["PLUGINS", "cache", "x.md"]) != nil && Setup.pathProblem(["Projects", "x.md"]) != nil && Setup.pathProblem(["Agents", "x.md"]) != nil
          && Setup.pathProblem(["skills", "a", "SKILL.md"]) == nil && Setup.pathProblem(["Notes.md"]) == nil,
          "names: Skills/, PLUGINS/, Projects/ and Agents/ are those places under another case, refused; a skill file's own capitals are fine")

    // ---- the preview (what the Export page says)
    let part = SessionsExport.Part(profile: "e2", name: "E2", source: SessionsBackup.Source(profile: "e2", dataDir: "", codeDir: ecode), emails: [])
    let pv = SessionsExport.preview(part)!
    check(pv.setup.units.count == 15 && pv.setup.keyedUnits == [Setup.Unit(kind: .skill, name: "keyed")] && pv.keyed == 3 && pv.keyedSessions == 2 && pv.setup.extra.hooks == 3 && pv.setup.extra.statusLine && pv.setup.extra.plugins == 2,
          "preview: \(pv.setup.units.count) units, 1 skill with a key, 2 sessions with keys (3 in all), 3 hooks, a status line, 2 plugins")
    let zipWords = ExportWords.setupWords(pv, setup: true, image: false), imgWords = ExportWords.setupWords(pv, setup: true, image: true)
    check(zipWords == "CLAUDE.md with 2 included files, 2 skills, 2 agents, 1 command, 1 output style, keybindings, 2 plugins to reinstall", "export row for a zip: \(zipWords)")
    check(imgWords == "CLAUDE.md with 2 included files, settings.json with 3 hooks and a status line, 2 scripts, 2 skills, 2 agents, 1 command, 1 output style, keybindings, 2 plugins to reinstall, the plugin marketplaces", "export row for an image: \(imgWords)")
    check(ExportWords.setupWords(pv, setup: false, image: true) == "left out" && ExportWords.setupNotes(pv, setup: true, image: false).first == "settings.json, the 2 scripts it runs and the plugin marketplaces need the encrypted disk image: left out of a zip"
          && ExportWords.setupNotes(pv, setup: true, image: true).allSatisfy { !$0.contains("need the encrypted") }, "export row: the menu's left out, and a zip says what only the image carries")
    check(ExportWords.foundWords(pv).hasPrefix("2 sessions and 1 skill hold keys: 3 GitHub tokens"), "Found line counts the skill with the sessions: \(ExportWords.foundWords(pv))")
    check(ExportWords.setupNotes(pv, setup: true, image: true).contains { $0.contains("3 links left out, never followed") && $0.contains("linkedskill points to") }, "export row: the linked skills are listed with where they point (this page only)")

    // ---- Export: a zip
    let zipURL = URL(fileURLWithPath: out + "/E2.zip")
    let zo = try? SessionsExport.run(SessionsExport.Job(parts: [part], keys: .leaveOut, destination: zipURL, rootName: "e2-export", place: eplace))
    check(zo != nil, "export: a zip with setup is made (an address in CLAUDE.md doesn't stop it)")
    guard let zo else { print("(export failed; stopping part 1)"); return }
    let op = try! SessionsImport.open(zipURL, password: nil, place: eplace)
    let m1 = op.parts[0].manifest
    let setupItems = m1.items.filter { $0.role == .setup }
    check(Set(setupItems.map { String($0.path.dropFirst(6)) }) == zipRels.subtracting(["skills/keyed/SKILL.md", "skills/keyed/run.py"]), "export (zip): the plain setup is in; the skill with a key, settings.json, the scripts and the marketplaces are not: \(Set(setupItems.map { String($0.path.dropFirst(6)) }).symmetricDifference(zipRels).sorted())")
    check(m1.version == 3 && op.export.version == 3 && setupItems.allSatisfy { $0.sha?.count == 64 && $0.original == $0.path }, "export: manifest version 3, a SHA-256 for every setup file, no absolute path")
    check(zo.setupKeysLeftOut == 1 && Set(zo.setupSensitiveLeftOut.map(\.kind)) == [.settings, .script, .marketplaces] && zo.setupSensitiveLeftOut.count == 4, "export (zip): 1 skill left out for its key; settings.json, 2 scripts and the marketplaces left out for the zip: \(zo.setupSensitiveLeftOut.map(\.name))")
    check(setupItems.first { $0.path == "setup/skills/alpha/run.sh" }?.exec == true && setupItems.filter { $0.exec == true }.map(\.path) == ["setup/skills/alpha/run.sh"], "export: the execute flag is recorded for the skill's script, for nothing else")
    var leaked: [String] = []
    for f in files(op.tree.path) { let t = read(op.tree.path + "/" + f) ?? ""; if t.contains(elsewhere) || t.contains(home) || t.contains(ghKey) { leaked.append(f) } }
    check(leaked.isEmpty, "export: no link target, no absolute path of this Mac, no key in the file (found in: \(leaked))")
    check(read(op.tree.path + "/profiles/p1/setup/CLAUDE.md")?.contains("me@example.com") == true && read(op.tree.path + "/profiles/p1/setup/skills/alpha/auth.py") == "print('auth helper')\n", "export: setup is carried as it is: the address in CLAUDE.md stays, no rewriting")
    check(!files(op.tree.path).contains { $0.contains(".git/") || $0.contains("__pycache__") || $0.contains(".DS_Store") || $0.contains(".credentials") }, "export: .git, __pycache__, .DS_Store and a sign-in name are not in the file")
    check(zo.sessions == 0 && zo.keysLeftOut == 2, "export: the 2 sessions with keys are left out as before")
    check(m1.setupLeftOut?.contains("skill linkedskill (a link)") == true && m1.setupLeftOut?.contains("skill keyed (held a key)") == true && m1.setupLeftOut?.contains("settings.json (needs the encrypted disk image)") == true && !(m1.setupLeftOut ?? []).contains { $0.contains(elsewhere) }, "export: the links are named in the manifest, not where they point")

    // ---- Export: an encrypted image with keys kept
    let dmgURL = URL(fileURLWithPath: out + "/E2.dmg"), pw = "e2-test-password-not-secret"
    let io = try? SessionsExport.run(SessionsExport.Job(parts: [part], keys: .keep, password: pw, destination: dmgURL, rootName: "e2-image", place: eplace))
    check(io != nil && io!.setupKeysKept == 1 && io!.setupSensitiveLeftOut.isEmpty && io!.keysKept == 2, "export (image): the skill with a key is kept, nothing left out for sensitivity, 2 sessions kept")
    let oi = try! SessionsImport.open(dmgURL, password: pw, place: eplace)
    let mi = oi.parts[0].manifest.items.filter { $0.role == .setup }
    check(Set(mi.map { String($0.path.dropFirst(6)) }) == allRels, "export (image): everything is carried, settings.json, the scripts and the marketplaces too")
    check(mi.filter { $0.exec == true }.map(\.path).sorted() == ["setup/bin/guard.sh", "setup/bin/status.sh", "setup/skills/alpha/run.sh"], "export (image): the execute flag of the scripts settings.json points to is carried")
    // (the leak check for everything that is not setup still runs: only profiles/pN/setup/ is exempt)
    check(read(oi.tree.path + "/export.json")?.contains("me@example.com") == false, "export: the structure files hold no address")

    // ---- a hook script inside a skill: the skill is as sensitive as the script (a zip leaves it out, the image carries it as the skill)
    do {
        let c4 = e2 + "/.claude-e2h"
        w(c4, "skills/guard/SKILL.md", "guard skill"); w(c4, "skills/guard/run.sh", "#!/bin/sh\nexport DEPLOY_TOKEN=a-value-no-key-scan-knows\n", exec: true)
        w(c4, "skills/plain/SKILL.md", "plain skill"); w(c4, "agents/helper.md", "helper agent")
        try? fm.createDirectory(atPath: elsewhere + "/skills/linkedg", withIntermediateDirectories: true); write(elsewhere + "/skills/linkedg/run.sh", "#!/bin/sh\n")
        symlink(elsewhere + "/skills/linkedg", c4 + "/skills/linkedg")
        w(c4, "settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(c4)/skills/guard/run.sh\"},{\"type\":\"command\",\"command\":\"\(c4)/skills/linkedg/run.sh\"}]}]}}")
        // a skill with a file nested deeper than the walk goes is left out whole, not carried in part
        w(c4, "skills/deep/SKILL.md", "deep skill"); w(c4, "skills/deep/a/b/c/d/e/f/g/h/x.md", "too deep")
        let fh = Setup.scan(codeDir: c4, home: home)
        let hrels = Set(fh.files.map(\.rel))
        check(hrels == ["skills/guard/SKILL.md", "skills/guard/run.sh", "skills/plain/SKILL.md", "agents/helper.md", "settings.json"],
              "scan: a skill that is a link adds nothing, not even the one script a hook names inside it; a skill the walk can't finish is left out whole: \(hrels.sorted())")
        check(fh.linked.map(\.label) == ["skill linkedg"] && fh.leftOutNames.contains { $0.hasPrefix("skills/deep") && $0.contains("left out whole") }, "scan: the linked skill and the cut one are listed: \(fh.linked.map(\.label)) \(fh.leftOutNames)")
        check(Setup.hookUnits(rels: Array(hrels), settings: fm.contents(atPath: c4 + "/settings.json")) == [Setup.Unit(kind: .skill, name: "guard")], "scan: the skill that holds a file a hook runs is found")
        let ppart = SessionsExport.Part(profile: "e2h", name: "E2h", source: SessionsBackup.Source(profile: "e2h", dataDir: "", codeDir: c4), emails: [])
        let ppv = SessionsExport.preview(ppart)!
        check(ppv.setup.hookUnits == [Setup.Unit(kind: .skill, name: "guard")] && ppv.setup.keyedUnits.isEmpty, "preview: the skill is marked as holding a hook's script, and is not key-scanned (the image's job)")
        check(ExportWords.setupWords(ppv, setup: true, image: false) == "1 skill, 1 agent" && ExportWords.setupWords(ppv, setup: true, image: true) == "settings.json with 2 hooks, 2 skills, 1 agent"
              && ExportWords.setupNotes(ppv, setup: true, image: false).first == "settings.json and 1 skill with a script its hooks run need the encrypted disk image: left out of a zip",
              "export row: a zip carries 1 skill and 1 agent; the skill with a script its hooks run needs the image: \(ExportWords.setupWords(ppv, setup: true, image: false)) / \(ExportWords.setupNotes(ppv, setup: true, image: false).first ?? "")")
        let hz = URL(fileURLWithPath: out + "/E2h.zip")
        let hzo = try? SessionsExport.run(SessionsExport.Job(parts: [ppart], keys: .leaveOut, destination: hz, rootName: "e2h-export", place: eplace))
        if let hzo, let hop = try? SessionsImport.open(hz, password: nil, place: eplace) {
            let got = Set(hop.parts[0].manifest.items.filter { $0.role == .setup }.map { String($0.path.dropFirst(6)) })
            check(got == ["skills/plain/SKILL.md", "agents/helper.md"] && hzo.setupSensitiveLeftOut.contains(Setup.Unit(kind: .skill, name: "guard")), "export (zip): the skill that holds a hook's script is left out with settings.json, nothing of it is in the file: \(got.sorted())")
            check(hop.parts[0].manifest.setupLeftOut?.contains("skill guard (needs the encrypted disk image)") == true, "export (zip): and it is named in the file as left out for the image: \(hop.parts[0].manifest.setupLeftOut ?? [])")
            check(!files(hop.tree.path).contains { $0.contains("guard") } && !(files(hop.tree.path).contains { (read(hop.tree.path + "/" + $0) ?? "").contains("a-value-no-key-scan-knows") }), "export (zip): the script's token is nowhere in the zip")
            // a zip carries no settings.json: what its hooks run isn't known to the import's backup (a zip made from it is then careful)
            let st = try? SessionsImport.materialize(hop, part: hop.parts[0], target: "e2hz")
            let sj = st.flatMap { read($0.backup.dir.appendingPathComponent("backup.json").path) } ?? "setupHookUnits"
            check(!sj.contains("setupHookUnits"), "import (zip): without settings.json its backup records no hook-held units (not known)")
            SessionsImport.discard(hop.work)
        } else { check(false, "export (zip): the skill-with-a-hook-script export is made and opens") }
        let hi = URL(fileURLWithPath: out + "/E2h.dmg")
        let hio = try? SessionsExport.run(SessionsExport.Job(parts: [ppart], keys: .leaveOut, password: pw, destination: hi, rootName: "e2h-image", place: eplace))
        if hio != nil, let hop = try? SessionsImport.open(hi, password: pw, place: eplace) {
            let items = hop.parts[0].manifest.items.filter { $0.role == .setup }
            check(Set(items.map { String($0.path.dropFirst(6)) }) == ["skills/guard/SKILL.md", "skills/guard/run.sh", "skills/plain/SKILL.md", "agents/helper.md", "settings.json"] && items.first { $0.path == "setup/skills/guard/run.sh" }?.exec == true,
                  "export (image): the skill comes whole, as the skill, its script executable per the record")
            // the import's own backup records the hook-held skill from the settings.json it carries, so a zip made from it later leaves it out too
            let st = try? SessionsImport.materialize(hop, part: hop.parts[0], target: "e2h")
            let sj = st.flatMap { read($0.backup.dir.appendingPathComponent("backup.json").path) } ?? ""
            check(sj.contains("\"setupHookUnits\"") && sj.contains("\"skill:guard\""), "import (image): its backup records the skill that holds a hook's script, worked out from the settings.json it carries")
            SessionsImport.discard(hop.work)
        } else { check(false, "export (image): the skill-with-a-hook-script image is made and opens") }
        try? fm.removeItem(atPath: c4)
    }

    // ---- settings.json that is a link (into a dotfiles folder): never carried, but what its hooks run is still known, so a skill that
    // holds its script stays out of a zip (from the folder and from a backup of it); one that can't be read keeps every unit with an
    // executable file out of a zip
    do {
        let c6 = e2 + "/.claude-e2l", dots = e2 + "/dotfiles"
        let token = "a-linked-hook-value-no-key-scan-knows"
        try? fm.removeItem(atPath: c6); try? fm.removeItem(atPath: dots)
        w(c6, "skills/guard/SKILL.md", "guard skill"); w(c6, "skills/guard/run.sh", "#!/bin/sh\nexport DEPLOY_TOKEN=\(token)\n", exec: true)
        w(c6, "skills/plain/SKILL.md", "plain skill"); w(c6, "skills/tool/SKILL.md", "tool skill"); w(c6, "skills/tool/bin/tool.sh", "#!/bin/sh\necho tool\n", exec: true)
        write(dots + "/settings.json", #"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"~/e2/.claude-e2l/skills/guard/run.sh"}]}]}}"#)
        symlink(dots + "/settings.json", c6 + "/settings.json")
        let guardU = Setup.Unit(kind: .skill, name: "guard"), toolU = Setup.Unit(kind: .skill, name: "tool")
        let fl = Setup.scan(codeDir: c6, home: home)
        check(!fl.files.contains { $0.rel == "settings.json" } && fl.linked.map(\.label) == ["settings.json"] && fl.hookUnits == [guardU],
              "scan (linked settings.json): not carried, listed as a link, and the skill its hook runs a file of is still known: \(fl.hookUnits.map { $0.map(\.name).sorted() } ?? ["unreadable"])")
        /// What an export holds: its setup paths, whether the needle's bytes are anywhere in it (every unpacked file, and the file itself), its left-out names.
        func opened(_ url: URL, _ password: String? = nil) -> (rels: Set<String>, hit: Bool, leftOut: [String], linkTarget: Bool)? {
            guard let o = try? SessionsImport.open(url, password: password, place: eplace) else { return nil }
            defer { SessionsImport.discard(o.work) }
            let rels = Set(o.parts[0].manifest.items.filter { $0.role == .setup }.map { String($0.path.dropFirst(6)) })
            let needle = Data(token.utf8), target = Data(dots.utf8)
            let all = files(o.tree.path).map { fm.contents(atPath: o.tree.path + "/" + $0) ?? Data() } + [fm.contents(atPath: url.path) ?? Data()]
            return (rels, all.contains { $0.range(of: needle) != nil }, o.parts[0].manifest.setupLeftOut ?? [], all.contains { $0.range(of: target) != nil })
        }
        let lpart = SessionsExport.Part(profile: "e2l", name: "E2l", source: SessionsBackup.Source(profile: "e2l", dataDir: "", codeDir: c6), emails: [])
        let lpv = SessionsExport.preview(lpart)!
        check(lpv.setup.hookUnits == [guardU] && !lpv.setup.hooksUnknown && ExportWords.setupWords(lpv, setup: true, image: false) == "2 skills" && lpv.setup.keyedUnits.isEmpty,
              "preview (linked settings.json): the skill that holds its hook's script is marked for the image, the other 2 go in a zip: \(ExportWords.setupWords(lpv, setup: true, image: false))")
        let lz = URL(fileURLWithPath: out + "/E2l.zip")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [lpart], keys: .leaveOut, destination: lz, rootName: "e2l-export", place: eplace))) != nil, let z = opened(lz) {
            check(z.rels == ["skills/plain/SKILL.md", "skills/tool/SKILL.md", "skills/tool/bin/tool.sh"] && !z.hit && z.leftOut.contains("skill guard (needs the encrypted disk image)") && !z.linkTarget,
                  "export (zip, linked settings.json): the skill that holds the hook's script is left out, its token's bytes are nowhere in the file, the link's target neither: \(z.rels.sorted()) \(z.leftOut)")
        } else { check(false, "export (zip, linked settings.json): made and opens") }
        let li = URL(fileURLWithPath: out + "/E2l.dmg")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [lpart], keys: .leaveOut, password: pw, destination: li, rootName: "e2l-image", place: eplace))) != nil, let o = opened(li, pw) {
            check(o.rels == ["skills/guard/SKILL.md", "skills/guard/run.sh", "skills/plain/SKILL.md", "skills/tool/SKILL.md", "skills/tool/bin/tool.sh"] && !o.linkTarget,
                  "export (image, linked settings.json): the image carries the skill whole; settings.json itself (a link) never, nor where it points: \(o.rels.sorted())")
        } else { check(false, "export (image, linked settings.json): made and opens") }
        // a backup made with the linked settings.json records the skill by name; an export from that backup leaves it out of a zip too
        let lb = try! SessionsBackup.make(SessionsBackup.Source(profile: "e2l", dataDir: "", codeDir: c6), kind: .manual, window: false, place: eplace)
        let lbPath = SessionsBackup.folder(profile: "e2l", place: eplace).appendingPathComponent("\(lb.id)/backup.json").path
        check(lb.setupHookUnits == ["skill:guard"] && !(read(lbPath) ?? dots).contains(dots), "backup (linked settings.json): the hook-held skill is recorded by name, never where the link points: \(lb.setupHookUnits ?? ["none"])")
        let bpart = SessionsExport.Part(profile: "e2l", name: "E2l", backup: SessionsRestore.Backup(profile: "e2l", id: lb.id, place: eplace))
        let bpv = SessionsExport.preview(bpart)!
        check(bpv.setup.hookUnits == [guardU] && !bpv.setup.hooksUnknown, "preview (from that backup): the same skill is marked for the image")
        let bz = URL(fileURLWithPath: out + "/E2l-backup.zip")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [bpart], keys: .leaveOut, destination: bz, rootName: "e2l-backup-export", place: eplace))) != nil, let z = opened(bz) {
            check(z.rels == ["skills/plain/SKILL.md", "skills/tool/SKILL.md", "skills/tool/bin/tool.sh"] && !z.hit, "export (zip from a backup made with a linked settings.json): the skill is left out, its token nowhere: \(z.rels.sorted())")
        } else { check(false, "export (zip from the backup): made and opens") }
        // a backup from before the names were recorded: not known, so every skill with an executable file stays out of a zip
        if var j = (try? JSONSerialization.jsonObject(with: fm.contents(atPath: lbPath) ?? Data())) as? [String: Any] {
            j.removeValue(forKey: "setupHookUnits")
            try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: lbPath))
        }
        let opv = SessionsExport.preview(bpart)!
        let oz = URL(fileURLWithPath: out + "/E2l-older.zip")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [bpart], keys: .leaveOut, destination: oz, rootName: "e2l-older-export", place: eplace))) != nil, let z = opened(oz) {
            check(opv.setup.hooksUnknown && opv.setup.hookUnits == [guardU, toolU] && z.rels == ["skills/plain/SKILL.md"] && !z.hit && z.leftOut.contains("skill tool (needs the encrypted disk image)"),
                  "export (zip from an older backup that didn't record them): both skills with an executable file are left out: \(z.rels.sorted()) \(z.leftOut)")
        } else { check(false, "export (zip from an older backup): made and opens") }
        // settings.json can't be read (a link to nowhere, a folder): every unit with an executable file stays out of a zip
        unlink(c6 + "/settings.json"); symlink(dots + "/gone.json", c6 + "/settings.json")
        check(Setup.scan(codeDir: c6, home: home).hookUnits == nil, "scan: a settings.json that links to nowhere can't be read: which units its hooks run is not known")
        let upv = SessionsExport.preview(lpart)!
        let uNote = ExportWords.setupNotes(upv, setup: true, image: false).first ?? ""
        check(upv.setup.hooksUnknown && upv.setup.hookUnits == [guardU, toolU] && ExportWords.setupWords(upv, setup: true, image: false) == "1 skill" && uNote.contains("2 skills with an executable file"),
              "preview (unreadable settings.json): both skills with an executable file are marked for the image, and the note says why: \(uNote)")
        let uz = URL(fileURLWithPath: out + "/E2l-unread.zip")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [lpart], keys: .leaveOut, destination: uz, rootName: "e2l-unread-export", place: eplace))) != nil, let z = opened(uz) {
            check(z.rels == ["skills/plain/SKILL.md"] && !z.hit && z.leftOut.contains("skill guard (needs the encrypted disk image)") && z.leftOut.contains("skill tool (needs the encrypted disk image)"),
                  "export (zip, unreadable settings.json): only the skill without an executable file is in it: \(z.rels.sorted())")
        } else { check(false, "export (zip, unreadable settings.json): made and opens") }
        unlink(c6 + "/settings.json"); try? fm.createDirectory(atPath: c6 + "/settings.json", withIntermediateDirectories: true)
        check(Setup.hookUnits(codeDir: c6, rels: ["skills/guard/run.sh"]) == nil && Setup.hookUnits(codeDir: e2 + "/no-such-folder", rels: []) == [],
              "settings.json that is a folder can't be read; no settings.json at all runs nothing")
        try? fm.removeItem(atPath: c6); try? fm.removeItem(atPath: dots)
    }

    // ---- an included file goes only with what includes it: a default zip (keys left out) of a CLAUDE.md with a key leaves its include
    // out too, and so does one reached only through a skill left out for its key; the file imports, never refused whole. An @../ back
    // into the folder (by its own name) is carried and accepted.
    do {
        let c7 = e2 + "/.claude-e2i"
        try? fm.removeItem(atPath: c7)
        w(c7, "CLAUDE.md", "# rules\nTOKEN \(ghKey)\n@rules/one.md\n"); w(c7, "rules/one.md", "one\n")
        let ipart = SessionsExport.Part(profile: "e2i", name: "E2i", source: SessionsBackup.Source(profile: "e2i", dataDir: "", codeDir: c7), emails: [])
        func zipped(_ name: String) -> (rels: Set<String>, leftOut: [String], refusal: String?) {
            let url = URL(fileURLWithPath: out + "/\(name).zip")
            try? fm.removeItem(at: url)
            do { _ = try SessionsExport.run(SessionsExport.Job(parts: [ipart], keys: .leaveOut, destination: url, rootName: name, place: eplace)) } catch { return ([], [], "export: \(error)") }
            do {
                let o = try SessionsImport.open(url, password: nil, place: eplace)
                defer { SessionsImport.discard(o.work) }
                return (Set(o.parts[0].manifest.items.filter { $0.role == .setup }.map { String($0.path.dropFirst(6)) }), o.parts[0].manifest.setupLeftOut ?? [], nil)
            } catch { return ([], [], "\(error)") }
        }
        let k1 = zipped("e2i-claude-key")
        check(k1.refusal == nil && k1.rels.isEmpty && k1.leftOut.contains("CLAUDE.md (held a key)") && k1.leftOut.contains("included file rules/one.md (left out with what includes it)"),
              "export (zip, keys left out): CLAUDE.md with a key and its include both stay out; the file imports: \(k1.refusal ?? "opened") \(k1.rels.sorted()) \(k1.leftOut)")
        w(c7, "CLAUDE.md", "# rules\n@skills/k/SKILL.md\n@../.claude-e2i/rules/up.md\n"); try? fm.removeItem(atPath: c7 + "/rules/one.md")
        w(c7, "skills/k/SKILL.md", "key \(ghKey)\n@../../docs/x.md\n"); w(c7, "docs/x.md", "x\n"); w(c7, "rules/up.md", "up\n")
        let k2 = zipped("e2i-skill-key")
        check(k2.refusal == nil && k2.rels == ["CLAUDE.md", "rules/up.md"] && k2.leftOut.contains("skill k (held a key)") && k2.leftOut.contains("included file docs/x.md (left out with what includes it)"),
              "export (zip): an include reached only through a skill left out for its key stays out; an @../ back into the folder by its name is carried and imports: \(k2.refusal ?? "opened") \(k2.rels.sorted()) \(k2.leftOut)")
        try? fm.removeItem(atPath: c7)
    }

    // ---- the leak check exempts the setup's own folder and nothing else
    do {
        let lroot = URL(fileURLWithPath: e2 + "/leakroot")
        try? fm.removeItem(at: lroot)
        write(lroot.path + "/profiles/p1/setup/CLAUDE.md", "mail ultra-1@example.com and 00000000-0000-4000-8000-000000000099")
        let known = ["00000000-0000-4000-8000-000000000099"], mails = ["ultra-1@example.com"]
        check(SessionsExport.leak(in: lroot, ids: Set(known), emails: mails) == nil, "leak: a known address and id inside profiles/p1/setup/ are the operator's own words: not looked at")
        write(lroot.path + "/profiles/p1/window/setup/x.json", "{\"t\":\"ultra-1@example.com\"}")
        check(SessionsExport.leak(in: lroot, ids: Set(known), emails: mails)?.contains("address") == true, "leak: a folder called setup anywhere else (under window/) is looked at like any file")
        try? fm.removeItem(atPath: lroot.path + "/profiles/p1/window")
        write(lroot.path + "/profiles/p1x/setup/x.md", "ultra-1@example.com")
        check(SessionsExport.leak(in: lroot, ids: Set(known), emails: mails)?.contains("address") == true, "leak: only profiles/pN/setup/ is exempt, not a look-alike folder")
        try? fm.removeItem(atPath: lroot.path + "/profiles/p1x")
        write(lroot.path + "/profiles/p1/records/setup.json", "{\"t\":\"ultra-1@example.com\"}")
        check(SessionsExport.leak(in: lroot, ids: Set(known), emails: mails)?.contains("address") == true, "leak: a record whose name has setup in it is looked at")
        try? fm.removeItem(at: lroot)
    }

    // ---- Import (zip): left out by default
    func target(_ name: String) -> (SessionsRestore.Target, String) { let d = e2 + "/\(name)"; try? fm.removeItem(atPath: d); try! fm.createDirectory(atPath: d, withIntermediateDirectories: true); return (SessionsRestore.Target(profile: name, dataDir: "", codeDir: d, inUse: nil), d) }
    let (t1, d1) = target("t1")
    let st1 = try! SessionsImport.materialize(op, part: op.parts[0], target: "t1")
    let p0 = SessionsRestore.plan(t1, st1.backup)
    check(p0.refusal == nil && p0.setup.present && p0.setup.leftOut && p0.setupPieces.isEmpty && p0.setup.entries.count == 10 && p0.count == 0, "import: the setup is left out by default (\(p0.setup.entries.count) units listed, nothing to write): \(p0.refusal ?? "ok")")
    check(files(d1).isEmpty && (try? SessionsRestore.run(t1, st1.backup, windowClosed: { true })) == nil, "import: and a run without 'Add them' writes nothing")
    let p1 = SessionsRestore.plan(t1, st1.backup, addSetup: true)
    check(p1.setupPieces.count == 17 - 2 + 0 && p1.setup.newEntries.count == 10 && p1.setup.execNames == ["skills/alpha/run.sh"], "import: 'Add them': \(p1.setupPieces.count) files in 10 new units, 1 script made executable: \(p1.setup.execNames)")
    let b1 = try! SessionsImport.commit(st1)
    let r1 = try! SessionsRestore.run(t1, b1, addSetup: true, windowClosed: { true })
    var same = true
    for rel in zipRels.subtracting(["skills/keyed/SKILL.md", "skills/keyed/run.py"]) where fm.contents(atPath: "\(d1)/\(rel)") != fm.contents(atPath: "\(ecode)/\(rel)") { same = false; print("   differs: \(rel)") }
    check(r1.finished != nil && same && files(d1).count == 15, "import: Add them wrote the 15 files of the 10 units, byte for byte: \(files(d1).count)")
    check(mode("\(d1)/skills/alpha/run.sh") == 0o700 && mode("\(d1)/skills/alpha/SKILL.md") == 0o600 && mode("\(d1)/agents/helper.md") == 0o600 && mode("\(d1)/CLAUDE.md") == 0o600 && mode("\(d1)/skills") == 0o700 && mode("\(d1)/skills/alpha") == 0o700,
          "import: files 0600, folders 0700, only the skill's script 0700 (owner only, never group or other, never setuid)")
    check(r1.setupAdded.count == 10 && r1.setupAdded.contains("skill alpha") && r1.setupAdded.contains("CLAUDE.md"), "import: the receipt names the units it added: \(r1.setupAdded.count)")
    let u1 = try! SessionsRestore.undo(r1.id, windowClosed: { true })
    check(u1.undone != nil && files(d1).isEmpty && !fm.fileExists(atPath: d1 + "/skills"), "import: Undo takes the setup back, the folders it made too")
    SessionsImport.discard(op.work)

    // ---- Import: what is here stays (Different here), a skill folder that exists gets nothing, an include only with a new CLAUDE.md
    let opZ = try! SessionsImport.open(zipURL, password: nil, place: eplace)
    let (t2, d2) = target("t2")
    write("\(d2)/skills/alpha/SKILL.md", "mine, different"); write("\(d2)/agents/helper.md", "helper agent"); write("\(d2)/CLAUDE.md", "my own CLAUDE.md")
    let before2 = tree(d2)
    let st2 = try! SessionsImport.materialize(opZ, part: opZ.parts[0], target: "t2")
    let p2 = SessionsRestore.plan(t2, st2.backup, addSetup: true)
    func status(_ p: SessionsRestore.Plan, _ k: Setup.Kind, _ n: String) -> SessionsRestore.SetupPlan.Status? { p.setup.entries.first { $0.unit == Setup.Unit(kind: k, name: n) }?.status }
    check(status(p2, .skill, "alpha") == .different && status(p2, .agent, "helper.md") == .same && status(p2, .claude, "CLAUDE.md") == .different && status(p2, .agent, "team/two.md") == .new && status(p2, .keybindings, "keybindings.json") == .new,
          "import: a skill that is here but differs: Different here; an agent with the same content: Already here; CLAUDE.md that is here: Different here; the rest New")
    let b2 = try! SessionsImport.commit(st2)
    _ = try! SessionsRestore.run(t2, b2, addSetup: true, windowClosed: { true })
    check(read("\(d2)/skills/alpha/SKILL.md") == "mine, different" && read("\(d2)/CLAUDE.md") == "my own CLAUDE.md" && !fm.fileExists(atPath: d2 + "/skills/alpha/run.sh") && !fm.fileExists(atPath: d2 + "/skills/alpha/refs"),
          "import: what is here is byte-identical, and nothing is written into a skill folder that exists")
    check(!fm.fileExists(atPath: d2 + "/docs") && fm.fileExists(atPath: d2 + "/agents/team/two.md") && fm.fileExists(atPath: d2 + "/keybindings.json") && fm.fileExists(atPath: d2 + "/commands/ship.md"), "import: the included files stay out when CLAUDE.md isn't added; the new units come in")
    check(tree(d2).split(separator: "\n").filter { before2.contains($0) }.count == before2.split(separator: "\n").count, "import: every file that was here is unchanged")
    SessionsImport.discard(opZ.work)

    // ---- Import: never through a link
    let opL = try! SessionsImport.open(zipURL, password: nil, place: eplace)
    let (t3, d3) = target("t3")
    try? fm.createDirectory(atPath: e2 + "/linked-skills", withIntermediateDirectories: true)
    symlink(e2 + "/linked-skills", d3 + "/skills")
    let st3 = try! SessionsImport.materialize(opL, part: opL.parts[0], target: "t3")
    let p3 = SessionsRestore.plan(t3, st3.backup, addSetup: true)
    check(p3.setup.notes.contains { $0.hasPrefix("skills here is a link to") && $0.hasSuffix("nothing added there") } && p3.setup.blocked.contains { $0.unit.name == "alpha" } && !p3.setupPieces.contains { $0.dirs.first == "skills" },
          "import: skills/ is a link here: nothing is added there, and the preview says so: \(p3.setup.notes)")
    let b3 = try! SessionsImport.commit(st3)
    _ = try! SessionsRestore.run(t3, b3, addSetup: true, windowClosed: { true })
    check(files(e2 + "/linked-skills").isEmpty && fm.fileExists(atPath: d3 + "/agents/helper.md"), "import: nothing was written through the link; the other units came in")
    SessionsImport.discard(opL.work)

    // ---- Import: a link on the way to an included file, a link in the middle of an agent's path, a file where a folder is expected
    let opP = try! SessionsImport.open(zipURL, password: nil, place: eplace)
    let (t7, d7) = target("t7")
    try? fm.createDirectory(atPath: e2 + "/linked-docs", withIntermediateDirectories: true); symlink(e2 + "/linked-docs", d7 + "/docs")
    try? fm.createDirectory(atPath: e2 + "/linked-team", withIntermediateDirectories: true); write(d7 + "/agents/x.md", "mine"); symlink(e2 + "/linked-team", d7 + "/agents/team")
    write(d7 + "/skills", "a file where the skills folder should be"); write(d7 + "/commands", "a file where the commands folder should be")
    let before7 = tree(d7)
    let st7 = try! SessionsImport.materialize(opP, part: opP.parts[0], target: "t7")
    let p7 = SessionsRestore.plan(t7, st7.backup, addSetup: true)
    check(p7.setup.blocked.contains { $0.unit.name == "docs/style.md" } && p7.setup.blocked.contains { $0.unit.name == "docs/deep.md" } && p7.setup.blocked.contains { $0.unit.name == "team/two.md" }
          && p7.setup.blocked.contains { $0.unit.name == "alpha" } && p7.setup.blocked.contains { $0.unit.name == "ship.md" } && !p7.setupPieces.contains { ["docs", "skills", "commands"].contains($0.dirs.first ?? "") || $0.dirs == ["agents", "team"] },
          "import: a link on the way (docs/, agents/team/) and a file where a folder is expected (skills, commands) block those units, each one by one: \(p7.setup.blocked.map(\.unit.name).sorted())")
    let b7 = try! SessionsImport.commit(st7)
    _ = try! SessionsRestore.run(t7, b7, addSetup: true, windowClosed: { true })
    check(files(e2 + "/linked-docs").isEmpty && files(e2 + "/linked-team").isEmpty && read(d7 + "/skills") == "a file where the skills folder should be" && read(d7 + "/commands") == "a file where the commands folder should be"
          && fm.fileExists(atPath: d7 + "/CLAUDE.md") && fm.fileExists(atPath: d7 + "/agents/helper.md") && read(d7 + "/agents/x.md") == "mine" && fm.fileExists(atPath: d7 + "/keybindings.json"),
          "import: nothing was written through a link or over a file; CLAUDE.md and the other units that were free came in")
    let after7 = tree(d7)
    check(before7.split(separator: "\n").allSatisfy { after7.contains($0) }, "import: every file that was here is unchanged")
    SessionsImport.discard(opP.work)

    // ---- Import (image): settings.json and its scripts
    let (t4, d4) = target("t4")
    let st4 = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "t4")
    let p4 = SessionsRestore.plan(t4, st4.backup, addSetup: true)
    check(p4.setup.newEntries.count == 15 && p4.setup.hooks.count == 4 && p4.setup.hooks.first?.contains("guard.sh") == true && p4.setup.missingPaths.count == 1 && p4.setup.missingPaths[0].contains("gone.sh") && p4.setup.execNames.sorted() == ["bin/guard.sh", "bin/status.sh", "skills/alpha/run.sh"],
          "import (image): settings.json with its 4 commands shown, one hook path that isn't here listed, 3 scripts made executable: \(p4.setup.hooks.count) \(p4.setup.missingPaths) \(p4.setup.execNames)")
    let b4 = try! SessionsImport.commit(st4)
    let r4 = try! SessionsRestore.run(t4, b4, addSetup: true, windowClosed: { true })
    check(mode("\(d4)/bin/guard.sh") == 0o700 && mode("\(d4)/bin/status.sh") == 0o700 && mode("\(d4)/settings.json") == 0o600 && read("\(d4)/settings.json") == read("\(ecode)/settings.json") && fm.fileExists(atPath: d4 + "/skills/keyed/run.py"),
          "import (image): settings.json and the scripts come in, the scripts 0700 because settings.json is added by this run")
    check(r4.problems.contains { $0.contains("gone.sh") && $0.contains("not here") }, "import: the receipt lists a hook that points where nothing is: \(r4.problems.filter { $0.contains("hook") })")
    _ = try! SessionsRestore.undo(r4.id, windowClosed: { true })
    check(files(d4).isEmpty, "import (image): Undo takes all of it back")
    // settings.json is here, different: stays byte-identical; the scripts then come in 0600 and are listed
    let (t5, d5) = target("t5")
    write("\(d5)/settings.json", "{\"env\":{\"OTHER\":\"x\"},\"model\":\"opus\"}")
    let st5 = try! SessionsImport.materialize(oi, part: oi.parts[0], target: "t5")
    let p5 = SessionsRestore.plan(t5, st5.backup, addSetup: true)
    check(status(p5, .settings, "settings.json") == .different && p5.setup.execManual == ["bin/guard.sh", "bin/status.sh"] && p5.setup.execNames == ["skills/alpha/run.sh"]
          && p5.setup.settingsDiffer.contains("env.E2_FAKE_ENV") && p5.setup.settingsDiffer.contains("hooks.PreToolUse") && p5.setup.settingsDiffer.contains("model") && !p5.setup.settingsDiffer.contains { $0.contains("not-a-real-secret") },
          "import (image): a settings.json that is here stays; the differing key names (never values) are listed; the scripts stay 0600 and are listed to make executable yourself: \(p5.setup.settingsDiffer)")
    let b5 = try! SessionsImport.commit(st5)
    _ = try! SessionsRestore.run(t5, b5, addSetup: true, windowClosed: { true })
    check(read("\(d5)/settings.json") == "{\"env\":{\"OTHER\":\"x\"},\"model\":\"opus\"}" && mode("\(d5)/bin/guard.sh") == 0o600 && mode("\(d5)/skills/alpha/run.sh") == 0o700, "import (image): the local settings.json is byte-identical; the scripts are 0600; the skill's script 0700")

    // ---- hostile manifests (zips made from the good one) and old and new formats
    let hostile = out + "/hostile"
    let mk = eSh("/usr/bin/python3", ["-I", "-B", home + "/../mkhostile.py", zipURL.path, hostile])
    check(mk.status == 0, "(setup variants made) \(mk.err.suffix(200))")
    func refusal(_ name: String) -> String {
        do { let x = try SessionsImport.open(URL(fileURLWithPath: "\(hostile)/\(name).zip"), password: nil, place: eplace); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    let bad: [(String, String)] = [
        // a place or a name an export doesn't carry
        ("e2-plugin-cache", "doesn't carry"), ("e2-projects", "doesn't carry"), ("e2-todos", "doesn't carry"), ("e2-dotfile", "doesn't carry"), ("e2-git", "doesn't carry"),
        ("e2-in-skills-root", "doesn't carry"), ("e2-too-deep", "too deep"), ("e2-v1-with-setup", "doesn't carry"), ("e2-not-setup-place", "doesn't carry"), ("e2-setup-in-window", "doesn't carry"),
        // a name that is never carried, at any depth
        ("e2-localjson", "sign-in name in its setup"), ("e2-nested-settings", "sign-in name in its setup"), ("e2-claude-json", "sign-in name in its setup"),
        ("e2-credentials", "sign-in name in its setup"), ("e2-claude-json-nested", "sign-in name in its setup"),
        // what only the image carries
        ("e2-zip-settings", "A zip carries no"), ("e2-zip-marketplaces", "A zip carries no"), ("e2-zip-script", "A zip carries no"),
        // the execute rule
        ("e2-exec-claude", "executable"), ("e2-exec-agent", "executable"), ("e2-exec-include", "executable"), ("e2-exec-command", "executable"), ("e2-exec-keybindings", "executable"), ("e2-exec-plugins", "executable"),
        // hashes and sizes
        ("e2-bad-sha", "isn't what backup.json says"), ("e2-altered", "isn't what backup.json says"), ("e2-no-sha", "no valid hash"), ("e2-short-sha", "no valid hash"), ("e2-upper-sha", "no valid hash"),
        ("e2-wrong-size", "isn't the size"), ("e2-wrong-total", "don't add up"),
        // formats
        ("e2-v4-export", "newer cl_audit"), ("e2-v4-backup", "newer cl_audit"),
        // paths
        ("e2-traversal", "isn't a plain one"), ("e2-traversal-deep", "isn't a plain one"), ("e2-empty-component", "isn't a plain one"), ("e2-absolute", "isn't a plain one"), ("e2-setup-dup-item", "isn't a plain one"),
        ("e2-backslash", ""), ("e2-dup-case", ""), ("e2-file-and-folder", ""),
        // another case of a place that is never carried, a "script" named like settings.json
        ("e2-case-skills", "doesn't carry"), ("e2-case-plugins", "doesn't carry"), ("e2-case-projects", "doesn't carry"), ("e2-case-settings", "doesn't carry"),
        ("e2-case-claude", ""), ("e2-case-keybindings", ""),
        // an include is only what the file's own CLAUDE.md names
        ("e2-include-leftover", "doesn't include"), ("e2-include-top-leftover", "doesn't include")]
    for (name, words) in bad {
        let before = names(eplace.path).filter { $0.hasPrefix(".import-") }
        let got = refusal(name)
        check(got != "OPENED" && (words.isEmpty || got.contains(words)) && names(eplace.path).filter { $0.hasPrefix(".import-") } == before, "hostile: \(name).zip is refused whole, nothing left (\(got.prefix(80)))")
    }
    check(refusal("e2-exec-skill-ok") == "OPENED", "hostile: (an execute flag on a skill's own file is allowed: opens)")
    check(refusal("e2-v2") == "OPENED", "format: an export of version 2 (setup, no window settings) still imports")
    var v1why = ""
    let v1: SessionsImport.Opened? = { do { return try SessionsImport.open(URL(fileURLWithPath: hostile + "/e2-v1.zip"), password: nil, place: eplace) } catch { v1why = "\(error)"; return nil } }()
    check(v1 != nil && v1!.export.version == 1 && v1!.parts[0].manifest.version == 1, "format: an export of version 1 (no setup in it) still imports (\(v1why))")
    if let v1 {
        let (t6, _) = target("t6")
        let st = try! SessionsImport.materialize(v1, part: v1.parts[0], target: "t6")
        let pv1 = SessionsRestore.plan(t6, st.backup)
        check(pv1.refusal == nil && !pv1.setup.present && SessionsBackup.load(profile: "t6", id: st.id, place: st.stage)?.version == 3, "format: …its plan says there is no setup in it, and what is staged is a version 3 backup")
        SessionsImport.discard(v1.work)
    }
    // the same name under another Unicode form: the target holds the skill as e + a combining mark, the file as one character
    if let uz = try? SessionsImport.open(URL(fileURLWithPath: hostile + "/e2-unicode-skill.zip"), password: nil, place: eplace) {
        let (tu, du) = target("tu")
        let nfd = "cafe\u{301}"
        write("\(du)/skills/\(nfd)/SKILL.md", "my cafe skill, different")
        let folds = fm.fileExists(atPath: "\(du)/skills/caf\u{e9}")            // does this disk treat the two as one name?
        let stu = try! SessionsImport.materialize(uz, part: uz.parts[0], target: "tu")
        let pu = SessionsRestore.plan(tu, stu.backup, addSetup: true)
        let bu = try! SessionsImport.commit(stu)
        _ = try! SessionsRestore.run(tu, bu, addSetup: true, windowClosed: { true })
        let sk = names("\(du)/skills")
        check(!folds || (status(pu, .skill, "caf\u{e9}") == .different && sk.filter { $0.precomposedStringWithCanonicalMapping == "caf\u{e9}" }.count == 1 && files("\(du)/skills/\(nfd)") == ["SKILL.md"]
                         && read("\(du)/skills/\(nfd)/SKILL.md") == "my cafe skill, different" && fm.fileExists(atPath: "\(du)/skills/alpha/SKILL.md")),
              "import: a skill under the same name in another Unicode form is the one that is here (this disk folds them: \(folds)): Different here, nothing added inside it, the other units came: \(sk)")
        SessionsImport.discard(uz.work)
    } else { check(false, "hostile: e2-unicode-skill.zip opens") }

    // ---- doctored images: a script without the settings.json that names it
    func doctored(_ name: String, edit: (inout SessionsBackup.Manifest, URL) throws -> Void) -> String {
        let work = e2 + "/doctor-\(name)"
        try? fm.removeItem(atPath: work); try! fm.createDirectory(atPath: work, withIntermediateDirectories: true)
        _ = eSh("/usr/bin/ditto", [oi.tree.path, work + "/" + oi.tree.lastPathComponent])
        let root = URL(fileURLWithPath: work + "/" + oi.tree.lastPathComponent)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var m = try dec.decode(SessionsBackup.Manifest.self, from: Data(contentsOf: root.appendingPathComponent("profiles/p1/backup.json")))
            try edit(&m, root.appendingPathComponent("profiles/p1"))
            m.bytes = m.items.reduce(0) { $0 + $1.bytes }
            try enc.encode(m).write(to: root.appendingPathComponent("profiles/p1/backup.json"))
            var ex = try dec.decode(ExportManifest.self, from: Data(contentsOf: root.appendingPathComponent("export.json")))
            ex.parts[0].bytes = m.bytes; ex.bytes = m.bytes
            try enc.encode(ex).write(to: root.appendingPathComponent("export.json"))
        } catch { return "doctoring failed: \(error)" }
        let img = URL(fileURLWithPath: out + "/\(name).dmg")
        try? fm.removeItem(at: img)
        let r = Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", work, "-volname", "doctored", "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", img.path], stdin: Data(pw.utf8), secret: pw)
        guard r?.status == 0 else { return "image not made: \(r?.err ?? "")" }
        do { let x = try SessionsImport.open(img, password: pw, place: eplace); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    let noSettings = doctored("e2-noset") { m, p in
        m.items.removeAll { $0.path == "setup/settings.json" }
        try fm.removeItem(at: p.appendingPathComponent("setup/settings.json"))
    }
    check(noSettings.contains("without the settings.json that points to it"), "hostile (image): scripts without their settings.json are refused whole: \(noSettings.prefix(90))")
    let unnamed = doctored("e2-unnamed") { m, p in
        let data = Data("#!/bin/sh\n".utf8)
        try fm.createDirectory(at: p.appendingPathComponent("setup/bin"), withIntermediateDirectories: true)
        try data.write(to: p.appendingPathComponent("setup/bin/unused.sh"))
        m.items.append(SessionsBackup.Item(role: .setup, original: "setup/bin/unused.sh", path: "setup/bin/unused.sh", bytes: Int64(data.count), sha: SwitchEngine.sha(data), exec: true))
    }
    check(unnamed.contains("no hook in settings.json points to"), "hostile (image): a script no hook names is refused whole: \(unnamed.prefix(90))")
    let okImage = doctored("e2-okimage") { _, _ in }
    check(okImage == "OPENED", "(the doctoring itself changes nothing that matters: an untouched copy still opens: \(okImage.prefix(80)))")
    // settings.json replaced and every script of the image dropped, then one file added as a script: what a hostile image could do
    func rewriteSettings(_ m: inout SessionsBackup.Manifest, _ p: URL, settings: String, script: (rel: String, exec: Bool)) throws {
        for it in m.items where it.role == .setup && Setup.unit(of: String(it.path.dropFirst(6))).kind == .script { try fm.removeItem(at: p.appendingPathComponent(it.path)) }
        m.items.removeAll { $0.role == .setup && Setup.unit(of: String($0.path.dropFirst(6))).kind == .script }
        let sdata = Data(settings.utf8)
        try sdata.write(to: p.appendingPathComponent("setup/settings.json"))
        if let i = m.items.firstIndex(where: { $0.path == "setup/settings.json" }) { m.items[i].bytes = Int64(sdata.count); m.items[i].sha = SwitchEngine.sha(sdata) }
        let data = Data("#!/bin/sh\n".utf8)
        let path = "setup/" + script.rel
        try fm.createDirectory(at: p.appendingPathComponent((path as NSString).deletingLastPathComponent), withIntermediateDirectories: true)
        try data.write(to: p.appendingPathComponent(path))
        m.items.append(SessionsBackup.Item(role: .setup, original: path, path: path, bytes: Int64(data.count), sha: SwitchEngine.sha(data), exec: script.exec))
    }
    // two units of one skill under different case in one image: on this disk they are one folder, the manifest's two paths can't both be there
    let twoCase = doctored("e2-two-case-skills") { m, p in
        let data = Data("second\n".utf8)
        try fm.createDirectory(at: p.appendingPathComponent("setup/skills/ALPHA"), withIntermediateDirectories: true)
        try data.write(to: p.appendingPathComponent("setup/skills/ALPHA/extra.md"))
        m.items.append(SessionsBackup.Item(role: .setup, original: "setup/skills/ALPHA/extra.md", path: "setup/skills/ALPHA/extra.md", bytes: Int64(data.count), sha: SwitchEngine.sha(data)))
    }
    check(twoCase != "OPENED", "hostile (image): a skill named twice under different case in one image is refused, never merged into one: \(twoCase.prefix(90))")
    let notACommand = doctored("e2-note-only") { m, p in try rewriteSettings(&m, p, settings: #"{"model":"x","note":"bin/run"}"#, script: ("bin/run", true)) }
    check(notACommand.contains("no hook in settings.json points to"), "hostile (image): a path that settings.json only mentions in a value that is no command is not a script: refused whole, nothing made executable: \(notACommand.prefix(90))")
    let keyScript = doctored("e2-keybindings-script") { m, p in
        // (the image's own keybindings.json goes first, so the other name doesn't collide with it: the place rule is what refuses it)
        m.items.removeAll { $0.path == "setup/keybindings.json" }; try fm.removeItem(at: p.appendingPathComponent("setup/keybindings.json"))
        try rewriteSettings(&m, p, settings: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/Keybindings.json"}]}]}}"#, script: ("Keybindings.json", true)) }
    check(keyScript.contains("doesn't carry"), "hostile (image): Keybindings.json as a script (the keybindings file under another case) is refused whole: \(keyScript.prefix(90))")
    let namedScript = doctored("e2-named-script") { m, p in try rewriteSettings(&m, p, settings: #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/bin/run --now"}]}]}}"#, script: ("bin/run", true)) }
    check(namedScript == "OPENED", "(the same doctoring with a hook that does run bin/run opens: \(namedScript.prefix(80)))")
    let mcpScript = doctored("e2-mcp-command-script") { m, p in try rewriteSettings(&m, p, settings: #"{"mcpServers":{"x":{"command":"bash ~/.claude/bin/run --now"}}}"#, script: ("bin/run", true)) }
    check(mcpScript.contains("no hook in settings.json points to"), "hostile (image): a script only an MCP server's command names is no hook script: refused whole, never made executable: \(mcpScript.prefix(90))")
    // a settings.json over 8 MB (and no script, so nothing else reads it before the import's own record of its hooks): refused whole,
    // never read into memory
    let hugeSettings = doctored("e2-huge-settings") { m, p in
        for it in m.items where it.role == .setup && Setup.unit(of: String(it.path.dropFirst(6))).kind == .script { try fm.removeItem(at: p.appendingPathComponent(it.path)) }
        m.items.removeAll { $0.role == .setup && Setup.unit(of: String($0.path.dropFirst(6))).kind == .script }
        let sdata = Data((#"{"model":"x","pad":""# + String(repeating: "a", count: (8 << 20) + 1024) + #""}"#).utf8)
        try sdata.write(to: p.appendingPathComponent("setup/settings.json"))
        if let i = m.items.firstIndex(where: { $0.path == "setup/settings.json" }) { m.items[i].bytes = Int64(sdata.count); m.items[i].sha = SwitchEngine.sha(sdata) }
    }
    check(hugeSettings.contains("over 8 MB"), "hostile (image): a settings.json over 8 MB is refused whole, not read: \(hugeSettings.prefix(90))")
    // the closure of includes and the paths a command names, directly
    do {
        let docs: [String: String] = ["CLAUDE.md": "# r\n @docs/a.md and @~/.claude-x/rules/x.md\n", "docs/a.md": " @b.md\n", "docs/b.md": "b", "rules/x.md": "x", "rules/y.md": "y", "z.md": "z"]
        let got = Setup.includeClosure(carried: Set(docs.keys)) { docs[$0].map { Data($0.utf8) } }
        check(got == ["docs/a.md", "docs/b.md", "rules/x.md"], "includes: the @ closure of CLAUDE.md (relative to the file that names it, a ~/ path by its tail); rules/y.md and z.md are not named: \(got.sorted())")
        var chain: [String: String] = ["CLAUDE.md": " @c1.md\n"]
        for k in 1...7 { chain["c\(k).md"] = k < 7 ? " @c\(k + 1).md\n" : "end" }
        let deep = Setup.includeClosure(carried: Set(chain.keys)) { chain[$0].map { Data($0.utf8) } }
        check(deep == ["c1.md", "c2.md", "c3.md", "c4.md", "c5.md"], "includes: followed as deep as the export follows them (5 files), no further: \(deep.sorted())")
        check(Setup.includeClosure(carried: ["docs/a.md"]) { _ in Data(" @docs/a.md".utf8) }.isEmpty, "includes: without a CLAUDE.md there are none")
        let up: [String: String] = ["CLAUDE.md": " @../.claude/rules/up.md\n @docs/a.md\n", "rules/up.md": "u", "docs/a.md": " @../../.claude/docs/b.md\n", "docs/b.md": "b", "rules/other.md": "o"]
        let ups = Setup.includeClosure(carried: Set(up.keys)) { up[$0].map { Data($0.utf8) } }
        check(ups == ["rules/up.md", "docs/a.md", "docs/b.md"], "includes: a relative @../ that leaves the folder and comes back in is matched by its tail, like ~/: \(ups.sorted())")
    }

    // ---- the Export page says what each left-out file is: a sign-in name, a skill cut whole, a hard link
    do {
        let c8 = e2 + "/.claude-e2n"
        try? fm.removeItem(atPath: c8)
        w(c8, "skills/s/SKILL.md", "s"); w(c8, "skills/s/.credentials.json", "{}")
        w(c8, "skills/deep/SKILL.md", "deep"); w(c8, "skills/deep/a/b/c/d/e/f/g/h/x.md", "too deep")
        w(c8, "skills/hl/SKILL.md", "hl"); w(c8, "skills/hl/data.txt", "shared"); link(c8 + "/skills/hl/data.txt", e2 + "/hl-other.txt")
        let npv = SessionsExport.preview(SessionsExport.Part(profile: "e2n", name: "E2n", source: SessionsBackup.Source(profile: "e2n", dataDir: "", codeDir: c8), emails: []))!
        let notes = ExportWords.setupNotes(npv, setup: true, image: false)
        check(notes.contains("1 file with a sign-in name left out: skills/s/.credentials.json") && notes.contains("1 skill left out whole: too many files or folders nested too deep (skills/deep)")
              && notes.contains("1 file left out: a hard link (skills/hl/data.txt)") && !notes.contains { $0.contains("sign-in name") && ($0.contains("deep") || $0.contains("hl/")) },
              "export row: a sign-in name, a skill cut whole and a hard link each said for what it is: \(notes)")
        try? fm.removeItem(atPath: c8); unlink(e2 + "/hl-other.txt")
    }

    // ---- an export never makes a file its own import refuses: a settings.json over 8 MB (which an import refuses) is left out at the
    // export, with the scripts its hooks run, and the Export page says so; the image made without it opens
    do {
        let c9 = e2 + "/.claude-e2big"
        try? fm.removeItem(atPath: c9)
        w(c9, "CLAUDE.md", "rules\n"); w(c9, "skills/g/SKILL.md", "g"); w(c9, "skills/g/run.sh", "#!/bin/sh\n", exec: true); w(c9, "bin/x.sh", "#!/bin/sh\n", exec: true)
        w(c9, "settings.json", #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(c9)/bin/x.sh"}]}]},"pad":""# + String(repeating: "a", count: (8 << 20) + 16) + #""}"#)
        let f9 = Setup.scan(codeDir: c9, home: home)
        check(!f9.files.contains { $0.rel == "settings.json" || $0.rel == "bin/x.sh" } && f9.leftOutNames.contains(Setup.settingsTooBig) && f9.hookUnits == nil,
              "scan: a settings.json over 8 MB is left out with its scripts (which units its hooks run isn't known): \(f9.files.map(\.rel).sorted())")
        let part9 = SessionsExport.Part(profile: "e2big", name: "E2big", source: SessionsBackup.Source(profile: "e2big", dataDir: "", codeDir: c9), emails: [])
        let pv9 = SessionsExport.preview(part9)!
        let notes9 = ExportWords.setupNotes(pv9, setup: true, image: true)
        check(notes9.contains("settings.json is over 8 MB: left out, with the scripts its hooks run (an import refuses one that big)") && !notes9.contains { $0.contains("sign-in name") },
              "export row: the page says settings.json is over 8 MB and left out (not as a sign-in name): \(notes9)")
        let big = URL(fileURLWithPath: out + "/E2big.dmg")
        if (try? SessionsExport.run(SessionsExport.Job(parts: [part9], keys: .leaveOut, password: pw, destination: big, rootName: "e2big-image", place: eplace))) != nil {
            do {
                let o = try SessionsImport.open(big, password: pw, place: eplace)
                let rels = Set(o.parts[0].manifest.items.filter { $0.role == .setup }.map { String($0.path.dropFirst(6)) })
                check(rels == ["CLAUDE.md", "skills/g/SKILL.md", "skills/g/run.sh"] && o.parts[0].manifest.setupLeftOut?.contains(Setup.settingsTooBig) == true,
                      "export (image): made without settings.json and its script, and its own import opens it: \(rels.sorted())")
                SessionsImport.discard(o.work)
            } catch { check(false, "export (image) with a settings.json over 8 MB at the source: its own import refuses it: \(error)") }
        } else { check(false, "export (image) with a settings.json over 8 MB at the source: made") }
        try? fm.removeItem(atPath: c9)
    }

    // ---- the setup row's words for scripts added without the execute bit, and the hooks key, true to settings.json's status here
    do {
        let settingsU = Setup.Unit(kind: .settings, name: "settings.json")
        func plan(_ s: SessionsRestore.SetupPlan.Status?, scripts: Int = 4) -> SessionsRestore.SetupPlan {
            var sp = SessionsRestore.SetupPlan()
            sp.execManual = (1...scripts).map { "bin/s\($0).sh" }
            if let s { sp.entries = [SessionsRestore.SetupPlan.Entry(unit: settingsU, status: s, files: 1, bytes: 10)] }
            return sp
        }
        check(SetupRow.execManualWords(plan(.same), imported: true) == "4 scripts added, not executable: your settings.json already calls them. Make them executable yourself (Terminal: chmod u+x) or their hooks fail."
              && SetupRow.execManualWords(plan(.same, scripts: 1), imported: true) == "1 script added, not executable: your settings.json already calls it. Make it executable yourself (Terminal: chmod u+x) or its hook fails.",
              "setup row: the same settings.json here already calls the scripts: said so, and how to make them executable: \(SetupRow.execManualWords(plan(.same), imported: true))")
        check(SetupRow.execManualWords(plan(.different), imported: true).hasPrefix("4 scripts added but not runnable: your settings.json here stays, so nothing calls them.")
              && SetupRow.execManualWords(plan(nil), imported: true).hasPrefix("4 scripts added but not runnable: the file has no settings.json, so nothing calls them.")
              && SetupRow.execManualWords(plan(nil), imported: false).contains("the backup has no settings.json"),
              "setup row: a different settings.json here stays; none in the file says that, not that one here stays: \(SetupRow.execManualWords(plan(nil), imported: true))")
        check(SetupRow.hooksKey(plan(.same), imported: true) == ("What its hooks run (the same settings.json is already here)", "Hide what they run")
              && SetupRow.hooksKey(plan(.different), imported: true) == ("What the file's hooks would run (not added: settings.json here stays)", "Hide (not added: settings.json here stays)")
              && SetupRow.hooksKey(plan(.new), imported: false) == ("What its hooks and status line run", "Hide what they run"),
              "setup row: the hooks key for the same settings.json here, a different one (the caveat stays while they show), and a new one")
        check(SetupRow.hooksKey(plan(.blocked("a link")), imported: true) == ("What the file's hooks would run (not added: settings.json can't be added here)", "Hide (not added: settings.json can't be added here)"),
              "setup row: the hooks key when settings.json can't be added here says that, not that one here stays: \(SetupRow.hooksKey(plan(.blocked("a link")), imported: true).show)")
    }

    // ---- the paths a command names, and the names refused under another case, directly
    do {
        let s = Data(#"{"note":"bin/run","hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash $HOME/.claude/bin/x.sh --flag"}]}]},"statusLine":{"type":"command","command":"~/.claude/bin/line.sh"}}"#.utf8)
        check(Setup.namedPaths(in: s, among: ["bin/run", "bin/x.sh", "bin/line.sh", "bin/other.sh"]) == ["bin/x.sh", "bin/line.sh"], "scripts: only a path a hook or status-line command names")
        // a `command` under another key (an MCP server's) is no hook's: not carried, not accepted, not shown as what the hooks run
        let mcp = Data(#"{"mcpServers":{"x":{"command":"~/.claude/bin/mcp.sh"}},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/bin/x.sh"}]}]},"statusLine":{"type":"command"}}"#.utf8)
        check(Setup.commands(inSettings: mcp) == ["~/.claude/bin/x.sh"] && Setup.namedPaths(in: mcp, among: ["bin/x.sh", "bin/mcp.sh"]) == ["bin/x.sh"],
              "scripts: hooks and the status line's command only; an MCP server's command and a status line without one are not scripts: \(Setup.commands(inSettings: mcp))")
        // a crafted settings.json naming 200,000 different paths in one hook: read in a moment (a list searched for each one would take minutes)
        let many = (0..<200_000).map { "/p/\($0)" }.joined(separator: " ")
        let big = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(many) /p/0"}]}]}}"#.utf8)
        let t0 = Date()
        let paths = Setup.commandPaths(inSettings: big, home: home)
        let took = Date().timeIntervalSince(t0)
        check(paths.count == 200_000 && paths.first == "/p/0" && took < 5, "scripts: 200,000 paths in one hook command are read once each, in order, quickly (\(paths.count) in \(String(format: "%.2f", took)) s)")
        let c5 = e2 + "/.claude-e2m"
        w(c5, "settings.json", #"{"mcpServers":{"x":{"command":"\#(c5)/bin/mcp.sh"}},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(c5)/bin/x.sh"}]}]}}"#)
        w(c5, "bin/x.sh", "#!/bin/sh\n", exec: true); w(c5, "bin/mcp.sh", "#!/bin/sh\n", exec: true)
        check(Set(Setup.scan(codeDir: c5, home: home).files.map(\.rel)) == ["settings.json", "bin/x.sh"], "scan: a script only an MCP server's command names is not carried with settings.json")
        try? fm.removeItem(atPath: c5)
        check(Setup.pathProblem(["claude.md"]) != nil && Setup.pathProblem(["Settings.json"]) != nil && Setup.pathProblem(["KEYBINDINGS.JSON"]) != nil && Setup.pathProblem(["CLAUDE.md"]) == nil && Setup.pathProblem(["keybindings.json"]) == nil && Setup.pathProblem(["notes.md"]) == nil,
              "names: claude.md, Settings.json and KEYBINDINGS.JSON are those files under another case, refused; the exact names are fine")
    }

    // ---- Backups carry setup (same rules), Restore leaves it out by default and puts back only what is missing
    let bm = try! SessionsBackup.make(SessionsBackup.Source(profile: "e2", dataDir: "", codeDir: ecode), kind: .manual, window: false, place: eplace)
    let bset = bm.items.filter { $0.role == .setup }
    check(bm.version == 3 && Set(bset.map { String($0.path.dropFirst(6)) }) == allRels && bset.allSatisfy { $0.sha?.count == 64 && $0.original.hasPrefix(ecode) },
          "backup: the same setup parts (links left out), each with its hash; a backup keeps where each file was: \(Set(bset.map { String($0.path.dropFirst(6)) }).symmetricDifference(allRels).sorted())")
    let bjson = read(SessionsBackup.folder(profile: "e2", place: eplace).appendingPathComponent("\(bm.id)/backup.json").path) ?? ""
    check(bm.setupLeftOut == ["agent linked.md (a link)", "skill haslink (it holds a link)", "skill linkedskill (a link)"] && !bjson.contains(elsewhere), "backup: links are named in the manifest, never where they point")
    let old = try! SessionsBackup.make(SessionsBackup.Source(profile: "e2", dataDir: "", codeDir: ecode), kind: .manual, window: false, setup: false, place: eplace)
    let pOld = SessionsRestore.plan(SessionsRestore.Target(profile: "e2", dataDir: "", codeDir: ecode, inUse: nil), SessionsRestore.Backup(profile: "e2", id: old.id, place: eplace))
    check(pOld.refusal == nil && !pOld.setup.present, "backup: one made without setup (an older backup) has none: its Restore row says it isn't in the backup")
    // delete a skill and an agent on purpose; the restore leaves them out unless asked, then puts back exactly those
    let te = SessionsRestore.Target(profile: "e2", dataDir: "", codeDir: ecode, inUse: nil)
    let bk = SessionsRestore.Backup(profile: "e2", id: bm.id, place: eplace)
    try? fm.removeItem(atPath: ecode + "/skills/alpha"); try? fm.removeItem(atPath: ecode + "/agents/helper.md")
    let pr0 = SessionsRestore.plan(te, bk), pr1 = SessionsRestore.plan(te, bk, addSetup: true)
    check(pr0.setup.leftOut && pr0.setupPieces.isEmpty && pr0.setup.newEntries.map(\.unit.name).sorted() == ["alpha", "helper.md"] && pr1.setupPieces.count == 7 && pr1.setup.entries(.same).count == pr1.setup.entries.count - 2,
          "restore: setup is left out by default; with 'Add them' only the 2 missing units come back (7 files); the rest is Already here: \(pr1.setupPieces.count)")
    let rr = try! SessionsRestore.run(te, bk, addSetup: true, windowClosed: { true })
    check(rr.finished != nil && read(ecode + "/agents/helper.md") == "helper agent" && mode(ecode + "/skills/alpha/run.sh") == 0o700 && read(ecode + "/skills/alpha/SKILL.md")?.hasPrefix("---") == true, "restore: the deleted skill and agent are back, the script executable as before")
    _ = try! SessionsRestore.undo(rr.id, windowClosed: { true })
    check(!fm.fileExists(atPath: ecode + "/skills/alpha") && !fm.fileExists(atPath: ecode + "/agents/helper.md") && fm.fileExists(atPath: ecode + "/agents/team/two.md"), "restore: Undo takes back exactly those")
    SessionsImport.discard(oi.work)
    try? fm.removeItem(atPath: e2)
    resetRestores()
}

// ================================================================== part 2: the pages' runners
// The Export page's "Claude Code setup" row and its menu, the Found line with setup units, the Import page's setup row (left out by
// default, Add them), the Restore page's setup row.
MainActor.assumeIsolated {
    SettingsModel.followsDock = false
    RunsMonitor.preview = []
    SessionsRestore.runningSessions = { [] }
    resetRestores()
    func settle(line: Int = #line, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(40)
        while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !done() { print("(timed out waiting at line \(line))") }
        return done()
    }
    func put(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
    }
    let eRoot = home + "/stage-e2"
    try? fm.removeItem(atPath: eRoot)
    try! fm.createDirectory(atPath: eRoot, withIntermediateDirectories: true)
    let placeS = URL(fileURLWithPath: eRoot + "/place")
    BackupPrefs.shared.place = placeS.path
    let sa = Seat(account: sid(1301), organization: sid(1302), email: "ultra-1@example.com")
    let sb = Seat(account: sid(1303), organization: sid(1304), email: "ultra-2@example.com")
    let wdS = eRoot + "/Claude-xa", cdS = eRoot + "/.claude-xa", wdT = eRoot + "/Claude-xb", cdT = eRoot + "/.claude-xb"
    put("\(cdS)/CLAUDE.md", "# rules\n @extra.md\n"); put("\(cdS)/extra.md", "extra")
    put("\(cdS)/skills/alpha/SKILL.md", "alpha"); put("\(cdS)/skills/alpha/run.sh", "#!/bin/sh\n"); chmod("\(cdS)/skills/alpha/run.sh", 0o755)
    put("\(cdS)/skills/keyed/SKILL.md", "keyed"); put("\(cdS)/skills/keyed/run.py", "K = '\(ghKey)'\n")
    put("\(cdS)/agents/helper.md", "helper"); put("\(cdS)/commands/ship.md", "ship")
    put("\(cdS)/settings.json", "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"\(cdS)/bin/stop.sh\"}]}]},\"statusLine\":{\"type\":\"command\",\"command\":\"\(cdS)/bin/line.sh\"}}")
    put("\(cdS)/bin/stop.sh", "#!/bin/sh\n"); put("\(cdS)/bin/line.sh", "#!/bin/sh\n")
    put("\(cdS)/projects/-p/\(sid(1311)).jsonl", "{\"type\":\"user\",\"cwd\":\"/x\",\"text\":\"k \(ghKey)\"}\n")
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86400)], ofItemAtPath: "\(cdS)/projects/-p/\(sid(1311)).jsonl")
    try! fm.createDirectory(atPath: "\(wdS)/claude-code-sessions/\(sa.account)/\(sa.organization!)", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: "\(wdT)/claude-code-sessions/\(sb.account)/\(sb.organization!)", withIntermediateDirectories: true)
    try! fm.createDirectory(atPath: cdT + "/projects", withIntermediateDirectories: true)
    var xa = AccountEntry(id: "xa", name: "Main", label: "MAIN", configDir: cdS); xa.seat = sa; xa.desktop = .separate; xa.desktopDataDir = wdS
    var xb = AccountEntry(id: "xb", name: "Work", label: "WORK", configDir: cdT); xb.seat = sb; xb.desktop = .separate; xb.desktopDataDir = wdT
    let m = SettingsModel()
    m.accounts = [xa, xb]
    m.selection = SettingsModel.dashboardID

    // ---- the Export page
    m.showExport("xa")
    let xr = m.exportRunner(for: "xa")
    xr.refresh()
    check(settle { xr.previews != nil }, "pages: the Export page counts, setup too")
    let pv = xr.total
    check(pv?.setup.units.count == 9 && pv?.setup.keyedUnits.map(\.name) == ["keyed"] && pv?.keyed == 2 && xr.setup, "pages: 9 setup units, 1 skill holds a key (2 things with keys with the session); the setup is included by default")
    check(ExportWords.setupWords(pv, setup: xr.setup, image: xr.usesImage) == "CLAUDE.md with 1 included file, 2 skills, 1 agent, 1 command", "pages: the row reads \"CLAUDE.md with 1 included file, 2 skills, 1 agent, 1 command\" for a zip: \(ExportWords.setupWords(pv, setup: xr.setup, image: xr.usesImage))")
    check(ExportWords.setupNotes(pv, setup: true, image: false) == ["settings.json and the 2 scripts it runs need the encrypted disk image: left out of a zip"], "pages: a zip says what only the image carries: \(ExportWords.setupNotes(pv, setup: true, image: false))")
    check(ExportWords.foundWords(pv).hasPrefix("1 session and 1 skill hold keys: 2 GitHub tokens"), "pages: the Found line counts the skill with the session: \(ExportWords.foundWords(pv))")
    xr.container = .image
    check(ExportWords.setupWords(pv, setup: true, image: xr.usesImage) == "CLAUDE.md with 1 included file, settings.json with 1 hook and a status line, 2 scripts, 2 skills, 1 agent, 1 command" && ExportWords.setupNotes(pv, setup: true, image: true).isEmpty,
          "pages: with the image it reads settings.json with 1 hook and a status line, 2 scripts too, and nothing is left out")
    xr.container = .zip
    xr.setup = false
    // (the one session holds a key and is left out with the setup: nothing is left to make a file of)
    check(ExportWords.setupWords(pv, setup: xr.setup, image: false) == "left out" && !xr.canExport, "pages: the menu's Leave them out: the row says left out, and with nothing else to export the key isn't pressable")
    xr.setup = true
    check(xr.canExport, "pages: with the setup in, the export key is ready")
    // a zip export, setup in; the file is the Import page's input
    let zipURL = URL(fileURLWithPath: eRoot + "/Main setup.zip")
    xr.run(to: zipURL)
    check(settle { if case .done = xr.phase { return true }; return false }, "pages: the zip is made")
    if case .done(let o) = xr.phase {
        check(Set(o.setupUnits.map(\.name)) == ["CLAUDE.md", "extra.md", "alpha", "helper.md", "ship.md"] && o.setupKeysLeftOut == 1 && o.setupSensitiveLeftOut.count == 3, "pages: the zip holds 5 setup units; the keyed skill and the 3 sensitive ones are out: \(o.setupUnits.map(\.name))")
    }

    // ---- the Import page: setup is left out until it is added
    m.showImport("xb")
    let ir = m.importRunner(for: "xb")
    ir.setFile(zipURL)
    check(settle { ir.phase == .ready && ir.plan != nil }, "pages: the zip is read and counted")
    let sp0 = ir.plan?.setup
    check(sp0?.present == true && sp0?.leftOut == true && ir.plan?.setupPieces.isEmpty == true && sp0?.entries.count == 5 && !ir.addSetup && !ir.canImport && ir.plan?.count == 0,
          "pages: the setup row: 5 units listed, left out by default, nothing to write (the key isn't pressable: nothing else to import)")
    check(Setup.words(sp0!.counts, extra: sp0!.extra) == "CLAUDE.md with 1 included file, 1 skill, 1 agent, 1 command", "pages: the row's words: \(Setup.words(sp0!.counts, extra: sp0!.extra))")
    ir.setSetup(true)
    check(settle { ir.plan?.setup.leftOut == false && (ir.plan?.setupPieces.count ?? 0) > 0 } && ir.addSetup && ir.canImport && ir.plan?.setupPieces.count == 6 && ir.plan?.setup.execNames == ["skills/alpha/run.sh"] && ir.plan?.setup.newEntries.count == 5,
          "pages: Add them: 6 files in 5 new units, 1 script made executable; the import key is ready")
    ir.setSetup(false)
    check(settle { ir.plan?.setup.leftOut == true } && !ir.addSetup && !ir.canImport, "pages: Leave them out again: back to nothing")
    ir.setSetup(true)
    _ = settle { ir.plan?.setup.leftOut == false }
    let beforeT = tree(cdT)
    ir.commit()
    guard case .running(let key) = ir.phase else { check(false, "pages: Close and import starts"); return }
    check(key.addSetup, "pages: the import's key carries the choice")
    let rr = m.restoreRunner(key)
    check(settle { rr.phase == .done } && rr.receipt?.setupAdded.count == 5 && fm.fileExists(atPath: cdT + "/skills/alpha/SKILL.md") && !fm.fileExists(atPath: cdT + "/skills/keyed"), "pages: it ran: 5 units added, the keyed skill was never in the file: \(rr.receipt?.setupAdded ?? [])")
    check(mode(cdT + "/skills/alpha/run.sh") == 0o700, "pages: the script is executable by its owner only")
    rr.undo()
    check(settle { rr.phase == .undone } && tree(cdT) == beforeT, "pages: Undo this import takes the setup back exactly")

    // ---- the Restore page: left out by default, Add them puts back only what is missing
    let bk = try! SessionsBackup.make(SessionsBackup.Source(xa), kind: .manual, window: false, place: placeS)
    try? fm.removeItem(atPath: cdS + "/skills/alpha"); try? fm.removeItem(atPath: cdS + "/agents/helper.md")
    let rk = RestoreKey(profile: "xa", backup: bk.id, place: placeS.path)
    let rs = m.restoreRunner(rk)
    rs.refresh()
    check(settle { rs.plan != nil }, "pages: the Restore page counts")
    check(rs.plan?.setup.present == true && rs.plan?.setup.leftOut == true && rs.plan?.setupPieces.isEmpty == true && rs.plan?.setup.newEntries.map(\.unit.name).sorted() == ["alpha", "helper.md"] && !rs.addSetup,
          "pages: the setup row is there, left out by default: the 2 units missing now are listed as New: \(rs.plan?.setup.newEntries.map(\.unit.name) ?? [])")
    rs.setSetup(true)
    check(settle { rs.plan?.setup.leftOut == false && rs.plan?.setupPieces.count == 3 } && rs.addSetup, "pages: Add them: only the 2 missing units come back (3 files)")
    // a backup without setup (an older one) says so
    let old = try! SessionsBackup.make(SessionsBackup.Source(xa), kind: .manual, window: false, setup: false, place: placeS, now: Date().addingTimeInterval(-60))
    let ro = m.restoreRunner(RestoreKey(profile: "xa", backup: old.id, place: placeS.path))
    ro.refresh()
    check(settle { ro.plan != nil } && ro.plan?.setup.present == false && ro.manifest?.version == 3, "pages: a backup made without setup: the row says it isn't in this backup")
    check(SetupRow.title(Setup.Unit(kind: .skill, name: "alpha")) == "skill alpha" && SetupRow.title(Setup.Unit(kind: .marketplaces, name: "x")) == "the plugin marketplaces", "pages: the list's unit names")
    resetRestores()
    try? fm.removeItem(atPath: eRoot)
    BackupPrefs.shared.place = ""
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
