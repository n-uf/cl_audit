// Resume checks for cl_audit: a moved session resumes in the right folder (stage 1 of the move's resume work). Sources/SessionsRepoint.swift
// (Claude Code's folder name and its long-name hash, the sessions whose folder isn't here, a picked folder re-pointing the transcript, its
// folder, its lines' cwd and the Code-tab entry, Undo, the Sessions page's list later), CodeChecklist.swift (read-only git on the old
// Mac, credentials out of the remote, the file read back untrusted, the words and commands), SessionsExport/SessionsImport (code.json in a
// move's image only, format 5 and the lowest-version rule), ImportPage (a move's memory row starts on).
//
// Two throwaway homes like the move suite: A (the old Mac) at Checks/.work/resume/home and B (the new Mac) at Checks/.work/resume/b/home, a
// second run of this program (RESUME_ROLE=b). The sessions' folders are fake projects under Checks/.work/resume/code, the same absolute
// path for both homes: same/app stays, gone/app is taken away between A and B, old/garden-app is cloned to new/garden-app in B, and a
// long folder (over 200 characters) moves to another long one. Fake git repos only (git init there, a local bare repo as upstream; the
// remote address that holds a token is never fetched). Nothing opens an app, the Dock or Terminal; Claude Code and the Claude app never
// run: the Dock's writer and the Keychain's tool are stand-ins that count calls (both stay at zero).

import AppKit
import Foundation
import ProfileCore

setbuf(stdout, nil)
let role = ProcessInfo.processInfo.environment["RESUME_ROLE"] ?? "a"
let home = NSHomeDirectory()
guard (role == "a" && home.hasSuffix("/Checks/.work/resume/home")) || (role == "b" && home.hasSuffix("/Checks/.work/resume/b/home")) else {
    print("refusing: HOME is \(home) for role \(role)"); exit(2)
}
let work = role == "a" ? (home as NSString).deletingLastPathComponent : ((home as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
let sharedDir = work + "/shared"
let code = work + "/code"                         // the projects, at the same path for both homes

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
func read(_ path: String) -> String? { fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }
func files(_ dir: String) -> [String] {
    var out: [String] = []
    if let e = fm.enumerator(atPath: dir) { for case let r as String in e { var d: ObjCBool = false; if fm.fileExists(atPath: dir + "/" + r, isDirectory: &d), !d.boolValue { out.append(r) } } }
    return out.sorted()
}
func everything(_ dir: String) -> [String] { ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).sorted() }
func json(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
func mtime(_ p: String) -> Date? { (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date }
func settle(_ secs: Double = 60, _ done: () -> Bool) { let end = Date().addingTimeInterval(secs); while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) } }

let pw = "resume-test-password-not-secret"
let acct = sid(1), org = sid(2), email = "studio@example.com"
let moveFile = sharedDir + "/resume move.dmg"
// a token-shaped value, cut so no committed file holds a whole one
let tok = "ghp_" + "\("")" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"
/// Claude Code's folder name, reimplemented here independently for the short names: every character not [A-Za-z0-9] becomes "-".
func enc(_ p: String) -> String { String(p.utf16.map { u -> Character in ((u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)) ? Character(UnicodeScalar(u)!) : "-" }) }

let same = code + "/same/app", gone = code + "/gone/app", old = code + "/old/garden-app", new = code + "/new/garden-app"
let wt = old + "/.claude/worktrees/wt-forms"
let longA = code + "/long/" + String(repeating: "a", count: 120) + "/" + String(repeating: "b", count: 90) + "/project"
let longB = code + "/long2/" + String(repeating: "c", count: 120) + "/" + String(repeating: "d", count: 90) + "/project"
let S1 = sid(101), S2 = sid(102), S3 = sid(103), S4 = sid(104)

// the transcript of S3 (it ran in the worktree): lines with the old folder, a nested cwd, a cwd elsewhere, a line that isn't JSON,
// a cwd with ".." (never used), a subfolder of the project
func s3Lines(_ wtPath: String, _ proj: String) -> [String] {
    [#"{"type":"user","sessionId":"\#(S3)","cwd":"\#(wtPath)","gitBranch":"claude/wt-forms","uuid":"u1","message":{"role":"user","content":"fix the sign-up form"},"timestamp":"2026-11-01T10:00:00.000Z"}"#,
     #"{"type":"assistant","cwd":"\#(wtPath)","uuid":"u2","message":{"content":[{"type":"text","text":"ok, cwd is \#(wtPath)"}]},"nested":{"cwd":"\#(proj)"}}"#,
     #"{"type":"user", "cwd" : "\#(proj)/src","uuid":"u3"}"#,
     #"{"type":"system","cwd":"/elsewhere/other","uuid":"u4"}"#,
     "not json at all \(proj)",
     #"{"type":"user","cwd":"\#(proj)/../etc","uuid":"u5"}"#,
     #"{"type":"summary","summary":"no cwd here"}"#]
}

// ================================================================== role B: the new Mac
if role == "b" {
    MainActor.assumeIsolated {
        let place = BackupPrefs.placeURL
        check(!Store.exists, "B: a fresh home")
        guard let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: place) else { check(false, "B: the move file opens"); return }
        check(o.move && o.export.version == 5 && o.export.checklist?.path == "code.json" && o.checklist != nil && o.parts.allSatisfy { $0.manifest.version == 4 },
              "B: a move with its code checklist is format 5 (its parts stay 4): \(o.export.version)")
        // the checklist as the Import page shows it
        let cl = o.checklist!
        let garden = cl.projects.first { $0.path.hasSuffix("/old/garden-app") }
        check(garden?.git == true && garden?.remote == "https://example.com/sam/garden-app.git" && garden?.branch == "feature/forms" && garden?.unpushed == 2 && garden?.uncommitted == 0
              && garden?.head?.count ?? 0 >= 4, "B: garden-app: the remote without its user and token, the branch, 2 not pushed: \(String(describing: garden))")
        let lines = garden.map { CodeChecklist.lines($0, here: false) } ?? []
        check(lines.first?.hasPrefix("Clone https://example.com/sam/garden-app.git at ") == true && lines.contains { $0.contains("2 commits weren't pushed on the old Mac") },
              "B: the page's lines: where to clone it, what wasn't pushed: \(lines)")
        let cmds = garden.map { CodeChecklist.commands($0, here: false) } ?? []
        check(cmds.first?.hasPrefix("git clone -- https://example.com/sam/garden-app.git ") == true && cmds.last == "git checkout feature/forms" && !cmds.joined().contains(tok),
              "B: the commands as text: clone, cd, checkout: \(cmds)")
        check(garden?.worktrees?.first?.branch == "claude/wt-forms" && lines.contains { $0.hasPrefix("Worktree wt-forms on claude/wt-forms") }, "B: the worktree the session ran in is listed with its branch")

        // memory: a move's import starts with the memory row on; Make the profile first
        let plan = SessionsMove.plan(o.app!, accounts: Store.load())
        let mr = try! SessionsMove.apply(plan, takeSettings: false, file: o.fileName)
        let e = Store.load().first { $0.name == "Studio" }!
        let t = SessionsRestore.Target(e)
        check(mr.made.count == 1 && e.seat?.account == acct, "B: the profile is made (no sign-in)")
        let st = try! SessionsImport.materialize(o, part: o.parts[0], target: e.id)
        let b = try! SessionsImport.commit(st, place: place)
        SessionsImport.discard(o.work)
        let p = SessionsRestore.plan(t, b, addMemory: true)
        let away = SessionsRepoint.staged(p, backup: b)
        let byID = Dictionary(uniqueKeysWithValues: away.map { ($0.id, $0) })
        check(byID[S1]?.here == true && byID[S1]?.folder == same, "B (1): the same path: here, nothing to pick")
        check(byID[S2]?.here == false && byID[S2]?.folder == gone, "B (2): a folder that isn't on this Mac: listed")
        check(byID[S3]?.here == false && byID[S3]?.folder == old && byID[S3]?.worktree == wt && byID[S3]?.title == "Fix the sign-up form",
              "B (3): the moved project: listed by its project folder (the entry's originCwd), with its worktree and title")
        check(byID[S4]?.here == false && byID[S4]?.folder == longA, "B: the long folder: listed")
        let rr = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let proj = t.codeDir + "/projects"
        let s2Before = read(proj + "/" + enc(gone) + "/\(S2).jsonl")
        check(rr.finished != nil && s2Before != nil && fm.fileExists(atPath: proj + "/" + enc(wt) + "/\(S3).jsonl") && fm.fileExists(atPath: proj + "/" + enc(wt) + "/memory/MEMORY.md"),
              "B: the import puts the transcripts under their old names (and the memory, added)")
        check(SessionsRepoint.receipts().isEmpty, "B (2): nothing re-pointed before a folder is picked")

        // ---- (3) Pick re-points S3 into new/garden-app (cloned there; its worktree isn't)
        try! fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        let oldT = proj + "/" + enc(wt) + "/\(S3).jsonl"
        let oldText = read(oldT)!
        let oldSub = read(proj + "/" + enc(wt) + "/\(S3)/subagents/agent-a1.jsonl")!
        let oldTool = fm.contents(atPath: proj + "/" + enc(wt) + "/\(S3)/tool-results/toolu_01.txt")!
        let oldMtime = mtime(oldT)
        let entryPath = files(t.dataDir + "/claude-code-sessions").map { t.dataDir + "/claude-code-sessions/" + $0 }.first { read($0)?.contains(S3) == true }!
        let entryBefore = fm.contents(atPath: entryPath)!
        let s2Entry = files(t.dataDir + "/claude-code-sessions").map { t.dataDir + "/claude-code-sessions/" + $0 }.first { read($0)?.contains(S2) == true }!
        let s2EntryBefore = fm.contents(atPath: s2Entry)!
        let r = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S3, folder: new)], restore: rr.id, windowClosed: { true })
        let newDir = proj + "/" + enc(new)
        check(r.problems.isEmpty && r.sessions.count == 1, "B (3): re-pointed, no problem: \(r.problems)")
        check(fm.fileExists(atPath: newDir + "/\(S3).jsonl") && !fm.fileExists(atPath: oldT) && !fm.fileExists(atPath: proj + "/" + enc(wt) + "/\(S3)"),
              "B (3): the transcript and its folder are under the new folder's name, gone from the old one")
        let expected = s3Lines(new, new).enumerated().map { i, l -> String in
            // what the rewrite must give: each top-level cwd in the old folder (the worktree, not here: the picked folder; a subfolder: kept)
            let o = s3Lines(wt, old)[i]
            switch i {
            case 0, 1: return o.replacingOccurrences(of: #""cwd":"\#(wt)""#, with: #""cwd":"\#(new)""#)
            case 2: return o.replacingOccurrences(of: #""cwd" : "\#(old)/src""#, with: #""cwd" : "\#(new)/src""#)
            default: return o
            }
        }.joined(separator: "\n") + "\n"
        let newText = read(newDir + "/\(S3).jsonl")
        check(newText == expected, "B (3): every matching cwd rewritten and nothing else changed (byte for byte): the nested cwd, the text, a cwd elsewhere, the non-JSON line and the '..' one as they were")
        check(oldText != newText && r.sessions.first?.lines == 4, "B (3): 4 lines re-pointed (3 in the transcript, 1 in its subagent's): \(r.sessions.first?.lines ?? -1)")
        check(read(newDir + "/\(S3)/subagents/agent-a1.jsonl") == oldSub.replacingOccurrences(of: wt, with: new) && fm.contents(atPath: newDir + "/\(S3)/tool-results/toolu_01.txt") == oldTool,
              "B (3): its subagent's cwd rewritten; a tool result copied as it is")
        check(mtime(newDir + "/\(S3).jsonl") == oldMtime, "B (3): the new transcript keeps the old one's date (Claude Code's clean-up sees its real age)")
        check(read(newDir + "/memory/MEMORY.md") == "# garden notes\n" && fm.fileExists(atPath: proj + "/" + enc(wt) + "/memory/MEMORY.md"), "B (3): the project's memory copied to the new name (the old stays)")
        let ej = json(fm.contents(atPath: entryPath))
        check(ej?["cwd"] as? String == new && ej?["originCwd"] as? String == new && ej?["worktreePath"] == nil && ej?["worktreeName"] == nil && ej?["branch"] == nil
              && ej?["sourceBranch"] == nil && ej?["title"] as? String == "Fix the sign-up form" && ej?["model"] as? String == "opus",
              "B (3): the entry's cwd and originCwd are the picked folder; the missing worktree and its fields dropped; the rest kept")
        let entryExpected = #"{"sessionId":"local_\#(sid(13))","cliSessionId":"\#(S3)","title":"Fix the sign-up form","cwd":"\#(new)","originCwd":"\#(new)","model":"opus","isArchived":false}"#
        check(read(entryPath) == entryExpected, "B (3): the entry's other bytes as they were: \(read(entryPath) ?? "")")
        check(read(proj + "/" + enc(gone) + "/\(S2).jsonl") == s2Before && fm.contents(atPath: s2Entry) == s2EntryBefore, "B (2): the session whose folder wasn't picked: untouched")
        check(RepointWords.done(r.sessions[0]).contains("its worktree isn't on this Mac"), "B (3): the page says the worktree was dropped")

        // Undo: exactly back
        let u = try! SessionsRepoint.undo(r.id, windowClosed: { true })
        check(u.undone != nil && read(oldT) == oldText && mtime(oldT) == oldMtime && fm.contents(atPath: entryPath) == entryBefore
              && read(proj + "/" + enc(wt) + "/\(S3)/subagents/agent-a1.jsonl") == oldSub && !fm.fileExists(atPath: newDir),
              "B (3): Undo puts the old transcript, its folder and the entry back byte for byte, and the new folder goes: \(u.problems)")

        // ---- later, from the Sessions page: the imported sessions whose folder isn't here
        let later = SessionsRepoint.missing(t)
        check(Set(later.map(\.id)) == [S2, S3, S4], "later: the Sessions page lists S2, S3 and the long one (S1's folder is here): \(later.map { $0.id.suffix(3) })")
        // a long folder (over 200 characters): its name is cut and gets Claude Code's hash
        try! fm.createDirectory(atPath: longB, withIntermediateDirectories: true)
        let s4Path = proj + "/" + ProjectName.encoded(longA) + "/\(S4).jsonl"
        let s4Before = read(s4Path)
        let lr = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S4, folder: longB)], windowClosed: { true })
        /// The hash counted independently (Python: Java's hashCode over the UTF-16 units, 32 bits, absolute value, base 36).
        func pyHashOf(_ s: String) -> String {
            let py = Process(); py.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            py.arguments = ["-I", "-c", "import sys\ns=sys.argv[1]\nb=s.encode('utf-16-le','surrogatepass')\nh=0\nfor i in range(0,len(b),2):\n  c=b[i]|(b[i+1]<<8)\n  h=(h*31+c)&0xffffffff\nif h>=2**31: h-=2**32\nh=abs(h)\nd='0123456789abcdefghijklmnopqrstuvwxyz'\nout=''\nwhile True:\n  out=d[h%36]+out; h//=36\n  if h==0: break\nprint(out)", s]
            let pp = Pipe(); py.standardOutput = pp
            try? py.run(); py.waitUntilExit()
            return String(decoding: pp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pyHash = pyHashOf(longB)
        // Integer.MIN_VALUE (abs: 2147483648, as JavaScript's Math.abs gives), a negative hash, a surrogate pair (two units, two "-")
        check(ProjectName.hash("polygenelubricants") == "zik0zk" && pyHashOf("polygenelubricants") == "zik0zk", "names: the INT_MIN hash is 2147483648 in base 36")
        check(ProjectName.hash("/srv/code/plant-list") == pyHashOf("/srv/code/plant-list") && ProjectName.hash("/x/😀/y") == pyHashOf("/x/😀/y")
              && ProjectName.encoded("/x/😀/y") == "-x----y", "names: a negative hash and a surrogate pair against the independent count")
        let longName = String(enc(longB).prefix(200)) + "-" + pyHash
        check(longB.count > 200 && ProjectName.encoded(longB) == longName && ProjectName.hash(longB) == pyHash && !pyHash.isEmpty,
              "long: the name is the first 200 characters, '-' and the Java-style hash in base 36 (an independent count: \(pyHash))")
        check(lr.problems.isEmpty && fm.fileExists(atPath: proj + "/" + longName + "/\(S4).jsonl"), "long: re-pointed under the hashed name: \(lr.problems)")
        check(ProjectName.hash("") == "0" && ProjectName.hash("a") == "2p" && ProjectName.hash("/srv/code/garden-app") == "p6etl0"
              && ProjectName.encoded("/srv/code/garden-app") == "-srv-code-garden-app" && ProjectName.encoded("/a/é.b") == "-a---b",
              "names: known values (an accented letter is one unit, '-')")
        // S3 again, later, and the import's Undo takes the re-point back first
        let r2 = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S3, folder: new)], restore: rr.id, windowClosed: { true })
        check(r2.problems.isEmpty && SessionsRepoint.linked(restore: rr.id).count == 1 && SessionsRepoint.touchesWindow(restore: rr.id), "later: S3 re-pointed again, linked to the import")
        // the hostile and refused cases, before the import's Undo
        var refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: t.codeDir)], windowClosed: { true })
        check(refused.sessions.isEmpty && refused.problems.first?.contains("Claude's or cl_audit's own folder") == true, "refused: a picked folder that is the Claude Code folder: \(refused.problems)")
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: home + "/nowhere")], windowClosed: { true })
        check(refused.problems.first?.contains("isn't there") == true, "refused: a picked folder that isn't there")
        try! fm.createDirectory(atPath: code + "/gone2/app", withIntermediateDirectories: true)
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { false })
        check(refused.sessions.isEmpty && refused.problems.first?.contains("needs the Claude window closed") == true && read(proj + "/" + enc(gone) + "/\(S2).jsonl") == s2Before,
              "refused: the window open: nothing written for it")
        SessionsRestore.runningSessions = { [S2] }
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.problems.first?.contains("running Claude Code session") == true, "refused: a running session holds it")
        SessionsRestore.runningSessions = { nil }
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.problems.first?.contains("couldn't be checked") == true, "refused: when running sessions can't be told")
        SessionsRestore.runningSessions = { [] }
        // a link in its folder
        try! fm.createDirectory(atPath: proj + "/" + enc(gone) + "/\(S2)", withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: proj + "/" + enc(gone) + "/\(S2)/link", withDestinationPath: "/etc/hosts")
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.problems.first?.contains("holds a link") == true && !fm.fileExists(atPath: proj + "/" + enc(code + "/gone2/app")), "refused: its folder holds a link: nothing written")
        try! fm.removeItem(atPath: proj + "/" + enc(gone) + "/\(S2)")
        // the new name already holds that session
        write(proj + "/" + enc(code + "/gone2/app") + "/\(S2).jsonl", "{}\n")
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.problems.first?.contains("already has a session of that id") == true && read(proj + "/" + enc(code + "/gone2/app") + "/\(S2).jsonl") == "{}\n", "refused: never over a session that is there")
        try! fm.removeItem(atPath: proj + "/" + enc(code + "/gone2/app"))
        // links: a picked folder that is a link to Claude's own folder; the destination project folder a link; its session folder a link
        try? fm.createSymbolicLink(atPath: code + "/linkpick", withDestinationPath: t.codeDir)
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/linkpick")], windowClosed: { true })
        check(refused.sessions.isEmpty && refused.problems.first?.contains("Claude's or cl_audit's own folder") == true, "link: a picked link to Claude's own folder is refused: \(refused.problems)")
        let dest = proj + "/" + enc(code + "/gone2/app"), elsewhere = home + "/elsewhere"
        try! fm.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: dest, withDestinationPath: elsewhere)
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.sessions.isEmpty && refused.problems.first?.contains("is a link") == true && everything(elsewhere).isEmpty && read(proj + "/" + enc(gone) + "/\(S2).jsonl") == s2Before,
              "link: a destination project folder that is a link: refused, nothing written through it: \(refused.problems)")
        try! fm.removeItem(atPath: dest)
        try! fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        try! fm.createSymbolicLink(atPath: dest + "/\(S2)", withDestinationPath: elsewhere)
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.sessions.isEmpty && refused.problems.first?.contains("already has a session of that id") == true && everything(elsewhere).isEmpty,
              "link: a link where its session folder would go: refused, nothing written through it")
        try! fm.removeItem(atPath: dest)
        // an entry that isn't one
        let savedEntry = fm.contents(atPath: s2Entry)!
        try! Data("{ not json".utf8).write(to: URL(fileURLWithPath: s2Entry))
        refused = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        check(refused.problems.first?.contains("transcript doesn't name") == true || refused.problems.first?.contains("can't be read") == true || refused.sessions.count == 1,
              "hostile: an entry that isn't JSON is not read as one (the session goes without it, or is refused): \(refused.problems)")
        if let rid = refused.sessions.first.map({ _ in refused.id }) { _ = try? SessionsRepoint.undo(rid, windowClosed: { true }) }
        try! savedEntry.write(to: URL(fileURLWithPath: s2Entry))
        check(read(proj + "/" + enc(gone) + "/\(S2).jsonl") == s2Before, "hostile: …and after its Undo the transcript is where it was")

        // a session resumed since: Undo leaves it in its new folder and says so
        let rs = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: code + "/gone2/app")], windowClosed: { true })
        let s2New = proj + "/" + enc(code + "/gone2/app") + "/\(S2).jsonl"
        if let h = FileHandle(forWritingAtPath: s2New) { h.seekToEndOfFile(); h.write(Data((#"{"type":"user","cwd":"/later","text":"resumed"}"# + "\n").utf8)); h.closeFile() }
        let ru2 = try! SessionsRepoint.undo(rs.id, windowClosed: { true })
        check(rs.sessions.count == 1 && ru2.problems.contains { $0.contains("stays in its new folder") && $0.contains("changed since") } && fm.fileExists(atPath: s2New)
              && !fm.fileExists(atPath: proj + "/" + enc(gone) + "/\(S2).jsonl"), "resumed: Undo leaves a session resumed since where it is, and says so: \(ru2.problems)")
        // a crash midway: the receipt on disk says the last old file wasn't taken away yet and the run never finished; Undo still restores
        let rdir = SessionsRepoint.root.appendingPathComponent(lr.id).appendingPathComponent("receipt.json")
        if var j = json(fm.contents(atPath: rdir.path)), var steps = j["steps"] as? [[String: Any]], let k = steps.lastIndex(where: { $0["kind"] as? String == "parked" }) {
            steps[k]["done"] = false; j["steps"] = steps; j.removeValue(forKey: "finished")
            try! JSONSerialization.data(withJSONObject: j).write(to: rdir)
        }
        let cu = try! SessionsRepoint.undo(lr.id, windowClosed: { true })
        check(cu.undone != nil && read(s4Path) == s4Before && s4Before != nil && !fm.fileExists(atPath: proj + "/" + longName),
              "crash: Undo from a receipt cut short restores the old transcript byte for byte and takes the new one away: \(cu.problems)")
        // the import's Undo: the re-point first, then the import, exactly
        let ru = try! SessionsRestore.undo(rr.id, windowClosed: { true })
        check(ru.undone != nil && SessionsRepoint.linked(restore: rr.id).isEmpty && !fm.fileExists(atPath: newDir) && !fm.fileExists(atPath: oldT),
              "undo: the import's Undo takes back the re-point first, then what it added: \(ru.problems)")

        // ---- the Import page's runner: a move's memory row starts on, another file's off
        let model = SettingsModel()
        let ir = model.importRunner(for: e.id)
        ir.setFile(URL(fileURLWithPath: moveFile)); ir.password = pw; ir.open()
        settle { ir.phase == .ready && ir.counting?.plan != nil }
        check(ir.addMemory && ir.counting?.key.addMemory == true && ir.checklist != nil, "page: a move file: memory files start Add them; the checklist is there for the page")
        ir.leave()
        ir.setFile(URL(fileURLWithPath: sharedDir + "/plain.dmg")); ir.password = pw; ir.open()
        settle { ir.phase == .ready && ir.counting?.plan != nil }
        check(!ir.addMemory && ir.checklist == nil, "page: an image that isn't a move: memory files start left out; no checklist")
        ir.leave()
        check(dockCalls == 0 && securityCalls == 0, "B: no Dock write and no Keychain call anywhere")
    }
    print("checks: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

// ================================================================== role A: the old Mac
func git(_ dir: String, _ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir, "-c", "user.name=Sam", "-c", "user.email=sam@example.com", "-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + args
    p.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CEILING_DIRECTORIES": code]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

MainActor.assumeIsolated {
    try? fm.removeItem(atPath: sharedDir); try! fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: code)
    for d in [same, gone, old, wt, longA] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }

    // ---- fake git repos: same/app clean with an upstream; old/garden-app 2 commits not pushed, a remote address holding a user and token;
    // gone/app 3 files not committed, no upstream; the long folder isn't a git repo
    // (git must never climb out of the fake projects into the tree this suite sits in)
    CodeChecklist.extraEnv = ["GIT_CEILING_DIRECTORIES": code]
    let haveGit = CodeChecklist.gitPath() != nil
    check(haveGit, "git: the person's git is found (the Command Line Tools here)")
    func repo(_ dir: String, bare: String) {
        _ = git(code, ["init", "--bare", "-q", bare])
        _ = git(dir, ["init", "-q"]); write(dir + "/README.md", "# app\n"); _ = git(dir, ["add", "."]); _ = git(dir, ["commit", "-q", "-m", "first"])
        _ = git(dir, ["remote", "add", "local", bare]); _ = git(dir, ["push", "-q", "-u", "local", "HEAD"])
    }
    repo(same, bare: code + "/remotes/same.git")
    _ = git(same, ["remote", "add", "origin", "git@example.com:sam/same-app.git"])
    try? fm.removeItem(atPath: old + "/.claude")
    write(old + "/.gitignore", ".claude/\n")
    repo(old, bare: code + "/remotes/garden.git")
    _ = git(old, ["checkout", "-q", "-b", "feature/forms"]); _ = git(old, ["push", "-q", "-u", "local", "feature/forms"])
    write(old + "/a.txt", "1\n"); _ = git(old, ["add", "."]); _ = git(old, ["commit", "-q", "-m", "two"])
    write(old + "/b.txt", "2\n"); _ = git(old, ["add", "."]); _ = git(old, ["commit", "-q", "-m", "three"])
    _ = git(old, ["remote", "add", "origin", "https://sam:\(tok)@example.com/sam/garden-app.git?x=1"])
    // (the session's worktree folder: a real worktree, so its branch reads)
    _ = git(old, ["worktree", "add", "-q", "-b", "claude/wt-forms", wt])
    _ = git(gone, ["init", "-q"]); write(gone + "/x.txt", "x\n"); _ = git(gone, ["add", "."]); _ = git(gone, ["commit", "-q", "-m", "x"])
    write(gone + "/y.txt", "y\n"); write(gone + "/z.txt", "z\n"); write(gone + "/x.txt", "changed\n")
    let gitStatusBefore = git(old, ["status", "--porcelain"]).1
    let indexBefore = mtime(old + "/.git/index")

    // ---- the profile and its sessions
    var studio = AccountEntry(id: "studio", name: "Studio", label: "STUDIO", configDir: "~/.claude-studio")
    studio.desktop = .separate; studio.desktopDataDir = "~/Library/Application Support/Claude-studio"
    studio.seat = Seat(account: acct, organization: org, email: email)
    try! Store.save([studio])
    let cc = expand(studio.configDir), wd = expand(studio.desktopDataDir)
    let scope = "\(wd)/claude-code-sessions/\(acct)/\(org)"
    func session(_ id: String, _ cwd: String, entry: String?) {
        write("\(cc)/projects/\(enc(cwd))/\(id).jsonl", #"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","message":{"role":"user","content":"hello"}}"# + "\n")
        if let entry { write("\(scope)/\(entry)", "") }
    }
    session(S1, same, entry: nil)
    write("\(scope)/local_\(sid(11)).json", #"{"sessionId":"local_\#(sid(11))","cliSessionId":"\#(S1)","title":"Same place","cwd":"\#(same)","isArchived":false}"#)
    session(S2, gone, entry: nil)
    write("\(scope)/local_\(sid(12)).json", #"{"sessionId":"local_\#(sid(12))","cliSessionId":"\#(S2)","title":"Gone away","cwd":"\#(gone)","isArchived":false}"#)
    write("\(cc)/projects/\(enc(wt))/\(S3).jsonl", s3Lines(wt, old).joined(separator: "\n") + "\n")
    write("\(cc)/projects/\(enc(wt))/\(S3)/subagents/agent-a1.jsonl", #"{"type":"user","isSidechain":true,"cwd":"\#(wt)","message":{"content":"sub"}}"# + "\n")
    write("\(cc)/projects/\(enc(wt))/\(S3)/tool-results/toolu_01.txt", "output naming \(wt)\n")
    write("\(cc)/projects/\(enc(wt))/memory/MEMORY.md", "# garden notes\n")
    write("\(scope)/local_\(sid(13)).json", #"{"sessionId":"local_\#(sid(13))","cliSessionId":"\#(S3)","title":"Fix the sign-up form","cwd":"\#(wt)","originCwd":"\#(old)","worktreePath":"\#(wt)","worktreeName":"wt-forms","branch":"claude/wt-forms","sourceBranch":"feature/forms","model":"opus","isArchived":false}"#)
    // (over 200 characters: Claude Code's own shortened name, or the file name would be too long to make)
    write("\(cc)/projects/\(ProjectName.encoded(longA))/\(S4).jsonl", #"{"type":"user","sessionId":"\#(S4)","cwd":"\#(longA)","message":{"role":"user","content":"hello"}}"# + "\n")
    for f in files(cc + "/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: cc + "/projects/" + f) }

    // ---- the checklist, as the Export page reads it
    let folders = [same: 1, gone: 1, wt: 1, longA: 1]
    let cl = CodeChecklist.gather(folders, git: CodeChecklist.gitPath())
    check(cl.projects.count == 4 && cl.git == nil, "checklist: 4 projects (the worktree's session counts under its project): \(cl.projects.map(\.path))")
    let sp = cl.projects.first { $0.path == same }, gp = cl.projects.first { $0.path == gone }, op = cl.projects.first { $0.path == old }, lp = cl.projects.first { $0.path == longA }
    check(sp?.git == true && sp?.unpushed == 0 && sp?.uncommitted == 0 && sp?.branch == "main" && sp?.remote == "git@example.com:sam/same-app.git", "checklist: a clean repo, its ssh address kept as it is")
    check(op?.unpushed == 2 && op?.uncommitted == 0 && op?.branch == "feature/forms" && op?.remote == "https://example.com/sam/garden-app.git" && op?.sessions == 1,
          "checklist: 2 commits not pushed; the remote's user, token and query taken out: \(op?.remote ?? "nil")")
    check(op?.worktrees?.count == 1 && op?.worktrees?.first?.branch == "claude/wt-forms", "checklist: the worktree the session ran in, with its branch")
    check(gp?.git == true && gp?.uncommitted == 3 && gp?.unpushed == nil && gp?.upstream == false && gp?.unread == nil, "checklist: 3 files not committed; its branch isn't on a remote yet (read, not unread)")
    check(sp?.fullyRead == true && op?.fullyRead == true && sp?.upstream == true, "checklist: every field read for the repos with an upstream")
    check(lp?.git == false && lp?.note == "not a git repo", "checklist: a folder that isn't a git repo")
    let warn = CodeChecklist.warnings(cl)
    check(warn.contains("garden-app: 2 commits not pushed: push them before you move") && warn.contains { $0.hasPrefix("app: 3 files not committed") } && warn.contains { $0.contains("not a git repo") }
          && warn.contains("app: its branch main isn't on a remote yet: push it before you move"),
          "export page: the warnings: \(warn)")
    check(CodeChecklist.summary(cl).hasSuffix("things to fix first (the list goes in the image)"), "export page: the Code row says the list goes in the image: \(CodeChecklist.summary(cl))")
    let indexAfter = mtime(old + "/.git/index")
    check(indexAfter == indexBefore && git(old, ["status", "--porcelain"]).1 == gitStatusBefore, "git: reading wrote nothing into the repo (the index untouched)")
    let none = CodeChecklist.gather(folders, git: nil)
    check(none.git == "git isn't on the old Mac" && none.projects.allSatisfy { !$0.git && $0.remote == nil } && none.projects.count == 4, "checklist without git: the folders only, and it says so")
    check(CodeChecklist.summary(none) == "4 projects: not read, git isn't on this Mac (the list of folders goes in the image)" && !CodeChecklist.summary(none).contains("all pushed"),
          "export page without git: never 'all pushed and committed': \(CodeChecklist.summary(none))")
    // a clean, fully read list says so, and still that the list goes in the image
    let clean = CodeChecklist.gather([same: 1], git: CodeChecklist.gitPath())
    check(CodeChecklist.summary(clean) == "1 project, 1 in git: all pushed and committed (the list goes in the image)", "export page: all read, nothing to fix: \(CodeChecklist.summary(clean))")

    // ---- a repo whose own config runs a program: never status (the filter's marker never appears)
    let evil = code + "/evil/app", marker = code + "/FILTER_RAN"
    try! fm.createDirectory(atPath: evil, withIntermediateDirectories: true)
    _ = git(evil, ["init", "-q"]); write(evil + "/a.txt", "hi\n"); write(evil + "/.gitattributes", "a.txt filter=probe\n")
    _ = git(evil, ["add", "."]); _ = git(evil, ["commit", "-q", "-m", "one"])
    _ = git(evil, ["config", "filter.probe.clean", "sh -c 'touch \(marker); cat'"])
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: evil + "/a.txt")        // stat-dirty, as after a copy
    let ev = CodeChecklist.gather([evil: 1], git: CodeChecklist.gitPath()).projects.first
    check(!fm.fileExists(atPath: marker) && ev?.note == "not read: its git settings run programs" && ev?.unread?.contains(.uncommitted) == true && ev?.uncommitted == nil,
          "hostile config: a repo's own filter never runs (status skipped), and it is said: \(ev?.note ?? "nil")")
    let evw = CodeChecklist.warnings(CodeChecklist.File(created: Date(), git: nil, projects: ev.map { [$0] } ?? []))
    check(evw.contains { $0.contains("couldn't read the files not committed (its git settings run programs)") }, "hostile config: the page warns: \(evw)")
    _ = git(evil, ["config", "--unset", "filter.probe.clean"]); _ = git(evil, ["config", "include.path", "/srv/other.inc"])
    check(CodeChecklist.gather([evil: 1], git: CodeChecklist.gitPath()).projects.first?.note == "not read: its git settings run programs", "hostile config: an include counts too")
    // a filter in a worktree's own config (extensions.worktreeConfig on): the marker never appears either
    _ = git(evil, ["config", "--unset", "include.path"])
    _ = git(evil, ["config", "extensions.worktreeConfig", "true"])
    _ = git(evil, ["config", "--worktree", "filter.probe.clean", "sh -c 'touch \(marker); cat'"])
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_900)], ofItemAtPath: evil + "/a.txt")
    let wtc = CodeChecklist.gather([evil: 1], git: CodeChecklist.gitPath()).projects.first
    check(!fm.fileExists(atPath: marker) && wtc?.note == "not read: its git settings run programs" && wtc?.uncommitted == nil,
          "hostile config: a filter in config.worktree never runs (status skipped): \(wtc?.note ?? "nil")")
    // …and a repo with that extension on but nothing to run is read as usual
    _ = git(evil, ["config", "--worktree", "--unset", "filter.probe.clean"])
    let wtok = CodeChecklist.gather([evil: 1], git: CodeChecklist.gitPath()).projects.first
    check(!fm.fileExists(atPath: marker) && wtok?.note == nil && wtok?.uncommitted != nil, "hostile config: with nothing to run, the worktree config doesn't block the read")

    // ---- git that never answers, with a child holding the pipe: killed by group, the whole list within its budget
    let slow = code + "/fakegit/git", slowMark = code + "/SLOW_CHILD_RAN"
    write(slow, "#!/bin/sh\n( sleep 4; touch \(slowMark) ) &\nsleep 30\n")
    chmod(slow, 0o755)
    CodeChecklist.timeout = 1; CodeChecklist.budget = 1.5
    let t0 = Date()
    let slowList = CodeChecklist.gather([same: 1, longA: 1], git: slow)
    let took = Date().timeIntervalSince(t0)
    CodeChecklist.timeout = 10; CodeChecklist.budget = 60
    check(took < 8 && slowList.projects.count == 2 && slowList.projects.allSatisfy { !$0.git && ($0.note ?? "").hasPrefix("not read") },
          "timeout: git that hangs is stopped and nothing is taken for 'not a git repo' (\(String(format: "%.1f", took)) s): \(slowList.projects.map { $0.note ?? "" })")
    check(slowList.projects.contains { $0.note == "not read: out of time" }, "timeout: past the budget, the rest is 'not read: out of time'")
    check(CodeChecklist.gather([same: 1], git: slow, cancel: { true }).projects.first?.note == "not read: stopped", "cancel: the Export page's Stop stops the reading")
    Thread.sleep(forTimeInterval: 4.5)
    check(!fm.fileExists(atPath: slowMark), "timeout: the child that held the pipe was killed with its group (its marker never appears)")
    // credentials out of a remote's address
    let remotes: [(String, String?)] = [("https://user:\(tok)@git.example.com/o/r.git", "https://git.example.com/o/r.git"), ("https://\(tok)@git.example.com/o/r", "https://git.example.com/o/r"),
                                        ("git@example.com:o/r.git", "git@example.com:o/r.git"), ("ssh://git@host:22/o/r.git", "ssh://git@host:22/o/r.git"),
                                        ("ssh://u:pw@host/o/r", "ssh://host/o/r"), ("u:pw@host:o/r", "host:o/r"), ("/srv/git/bare.git", "/srv/git/bare.git"),
                                        ("https://git.example.com/o/\(tok).git", nil), ("https://host/o/r?token=abc#x", "https://host/o/r"), ("bad url with spaces", nil),
                                        ("https://ex.com/a\u{202E}b\n2nd", "https://ex.com/ab"),
                                        // round 1: a "/" in the password, a query or fragment right after the host, options and transports
                                        ("https://user:pa/ss@host/o/r", nil), ("https://host?token=x", "https://host"), ("https://abc@host#f", "https://host"),
                                        ("--upload-pack=curl${IFS}x|sh", nil), ("-oProxyCommand=x@host:r", nil), ("ext::sh%20-c%20x", nil), ("fd::7", nil), ("FD::7", nil),
                                        ("https://host:abc/o", nil), ("https://host:8443/o/r", "https://host:8443/o/r"), ("https://host/@scope/x", nil),
                                        ("ssh://git@host/o/r?x=1", "ssh://git@host/o/r"),
                                        // round 2: a "#" or "?" inside the password (split at the address's last "@" first), the scp form's last "@",
                                        // bracketed IPv6 hosts, a bare path with "#"
                                        ("https://user:1234#x@host/r", nil), ("https://user:1234?x@host/r", nil), ("user:p@ss@host:org/repo", "host:org/repo"),
                                        ("https://[::1]:8443/o/r", "https://[::1]:8443/o/r"), ("https://[2001:db8::1]/o/r", "https://[2001:db8::1]/o/r"),
                                        ("https://u:pw@[2001:db8::1]:22/o/r", "https://[2001:db8::1]:22/o/r"), ("https://[::1]x/o", nil), ("/srv/git/repo#1.git", "/srv/git/repo#1.git")]
    check(CodeChecklist.cleanedRemote("https://[::1]x/o").why == CodeChecklist.remoteUnreadable && CodeChecklist.cleanedRemote("https://user:1234#x@host/r").why == CodeChecklist.remoteLeftOut
          && CodeChecklist.cleanedRemote("bad url with spaces").why == CodeChecklist.remoteUnreadable, "remote: the reason a remote is left out is the true one (can't read it, or it may hold a key)")
    check(CodeChecklist.commands(CodeChecklist.Project(path: "~/code/x", git: true, remote: "https://host/o/r", branch: "main", sessions: 1), here: false).first
          == "git clone -- https://host/o/r ~/code/x", "commands: git clone -- <address> <path> (nothing in the address can be an option)")
    let leftOut = CodeChecklist.Project(path: "~/code/x", git: true, sessions: 1, note: CodeChecklist.remoteLeftOut)
    check(CodeChecklist.lines(leftOut, here: false).first?.contains("held something like a key, so it is left out") == true
          && CodeChecklist.warnings(CodeChecklist.File(created: Date(), git: nil, projects: [leftOut])).contains { $0.contains("held something like a key") },
          "a remote left out: the pages say why, not 'no remote'")
    for (raw, want) in remotes { check(CodeChecklist.strippedRemote(raw) == want, "remote: \(raw.prefix(30)) → \(CodeChecklist.strippedRemote(raw) ?? "nil")") }
    check(CodeChecklist.shellWord("~/code/my app") == "~/'code/my app'" && CodeChecklist.shellWord("it's") == #"'it'\''s'"# && CodeChecklist.shellWord("~/code/app") == "~/code/app",
          "commands: a path with a space or a quote is quoted, ~/ kept for the shell")

    // ---- the move, with the checklist; code.json only in the image
    let bplace = BackupPrefs.placeURL
    func part(_ e: AccountEntry) -> SessionsExport.Part { SessionsExport.Part(profile: e.id, name: e.name, source: SessionsBackup.Source(e), emails: [email]) }
    let all = Store.load()
    var job = SessionsExport.Job(parts: [part(studio)], keys: .keep, password: pw, destination: URL(fileURLWithPath: moveFile), rootName: "resume move", place: bplace)
    job.move = true; job.profiles = SessionsMove.make(all, parts: ["studio": "p1"], all: all, move: true); job.known = Identities.of(accounts: all)
    job.checklist = CodeChecklist.encode(cl)
    let mo = try? SessionsExport.run(job)
    check(mo?.checklistCarried == true, "export: the move carries the checklist")
    if let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: bplace) {
        check(o.export.version == 5 && fm.fileExists(atPath: o.tree.path + "/code.json") && o.checklist?.projects.count == 4 && !(read(o.tree.path + "/code.json") ?? "").contains(tok),
              "export: format 5, code.json in the image, no token in it")
        SessionsImport.discard(o.work)
    } else { check(false, "export: the move opens") }
    // the older rule (26.11.10/11 read up to 4): this file is refused, a move without the checklist isn't
    func olderReads(_ v: Int) -> Bool { v >= 1 && v <= 4 }
    check(!olderReads(5) && olderReads(4), "format: 26.11.11's rule (up to 4) refuses 5")
    var job4 = job; job4.checklist = nil; job4.destination = URL(fileURLWithPath: sharedDir + "/move4.dmg")
    if let o4 = (try? SessionsExport.run(job4)).flatMap({ try? SessionsImport.open($0.file, password: pw, place: bplace) }) {
        check(o4.export.version == 4 && o4.checklist == nil && !fm.fileExists(atPath: o4.tree.path + "/code.json"), "format: a move without the checklist stays 4 (the lowest that holds it)")
        SessionsImport.discard(o4.work)
    } else { check(false, "format: the move without a checklist opens") }
    var zipJob = job; zipJob.move = false; zipJob.profiles = nil; zipJob.password = nil; zipJob.destination = URL(fileURLWithPath: sharedDir + "/plain.zip"); zipJob.rootName = "plain zip"
    if let zo = try? SessionsExport.run(zipJob), let o = try? SessionsImport.open(zo.file, password: nil, place: bplace) {
        check(!zo.checklistCarried && o.export.checklist == nil && !fm.fileExists(atPath: o.tree.path + "/code.json") && o.export.version <= 3, "zip: no checklist in a zip, whatever is asked")
        SessionsImport.discard(o.work)
    } else { check(false, "zip: made and opens") }
    var plainJob = job; plainJob.move = false; plainJob.profiles = nil; plainJob.destination = URL(fileURLWithPath: sharedDir + "/plain.dmg"); plainJob.rootName = "plain image"
    if let po = try? SessionsExport.run(plainJob), let o = try? SessionsImport.open(po.file, password: pw, place: bplace) {
        check(!po.checklistCarried && o.export.checklist == nil && o.export.version <= 4, "image that isn't a move: no checklist")
        SessionsImport.discard(o.work)
    } else { check(false, "plain image: made and opens") }

    // ---- the checklist read back, untrusted
    func clData(_ projects: [[String: Any]], extra: [String: Any] = [:]) -> Data {
        var o: [String: Any] = ["format": "cl_audit-code", "version": 1, "created": "2026-11-09T10:00:00Z", "projects": projects]
        for (k, v) in extra { o[k] = v }
        return try! JSONSerialization.data(withJSONObject: o)
    }
    let odd = CodeChecklist.read(clData([["path": "~/code/app", "git": true, "remote": "https://u:\(tok)@example.com/a.git", "branch": "main; rm -rf ~", "head": "zz", "unpushed": "3", "uncommitted": -1, "sessions": true],
                                         ["path": "~/../../etc", "git": true], ["path": "/ok/\u{0007}bell"], ["path": 7], ["git": true],
                                         ["path": "~/code/ok", "git": true, "remote": "https://example.com/ok.git", "branch": "feature/x", "head": "abc1234", "unpushed": 1, "uncommitted": 0, "sessions": 2,
                                          "worktrees": [["path": "~/code/ok/.claude/worktrees/w", "branch": "w", "unpushed": 0], ["path": "../x"]]]]))
    check(odd?.projects.count == 2 && odd?.projects[0].remote == "https://example.com/a.git" && odd?.projects[0].branch == nil && odd?.projects[0].head == nil && odd?.projects[0].unpushed == nil
          && odd?.projects[0].uncommitted == nil && odd?.projects[0].sessions == 0 && odd?.projects[1].worktrees?.count == 1 && (odd?.notes?.count ?? 0) >= 5,
          "hostile checklist: odd types, a branch with shell words, a traversal and a control character dropped, the token taken out, each said: \(odd?.notes ?? [])")
    check(CodeChecklist.read(Data("[1,2]".utf8)) == nil && CodeChecklist.read(Data("{\"format\":\"other\"}".utf8)) == nil
          && CodeChecklist.read(Data(repeating: 0x20, count: CodeChecklist.maxBytes + 1)) == nil
          && CodeChecklist.read(Data((String(repeating: "[", count: 40) + String(repeating: "]", count: 40)).utf8)) == nil,
          "hostile checklist: not an object, another format, over 256 KB, too deep: not read")
    let many = CodeChecklist.read(clData(Array(repeating: ["path": "~/p", "git": false], count: 300)))
    check(many?.projects.count == CodeChecklist.maxProjects && many?.notes?.first?.contains("more than") == true, "hostile checklist: 300 projects capped at \(CodeChecklist.maxProjects), said")
    // doctored images: a checklist that isn't one refuses the file; one in a non-move refuses it; a wrong hash refuses it; export.json version 6 refused
    guard let base0 = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: bplace) else { check(false, "(the move opens for doctoring)"); return }
    func doctored(_ name: String, edit: (URL, inout ExportManifest) throws -> Void) -> String {
        let dir = home + "/doctor-\(name)"
        try? fm.removeItem(atPath: dir); try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Tool.run("/usr/bin/ditto", [base0.tree.path, dir + "/" + base0.tree.lastPathComponent])
        let root = URL(fileURLWithPath: dir + "/" + base0.tree.lastPathComponent)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let encd = JSONEncoder(); encd.dateEncodingStrategy = .iso8601; encd.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var ex = try dec.decode(ExportManifest.self, from: Data(contentsOf: root.appendingPathComponent("export.json")))
            try edit(root, &ex)
            try encd.encode(ex).write(to: root.appendingPathComponent("export.json"))
        } catch { return "doctoring failed: \(error)" }
        let file = URL(fileURLWithPath: home + "/\(name).dmg")
        try? fm.removeItem(at: file)
        let r = Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", dir, "-volname", "resume-\(name)-\(getpid())", "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", file.path], stdin: Data(pw.utf8), secret: pw)
        guard r?.status == 0 else { return "file not made: \(r?.err ?? "")" }
        do { let x = try SessionsImport.open(file, password: pw, place: bplace); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    func setCode(_ root: URL, _ ex: inout ExportManifest, _ d: Data) throws {
        try d.write(to: root.appendingPathComponent("code.json"))
        ex.checklist = ExportManifest.AppFile(path: "code.json", bytes: Int64(d.count), sha: SwitchEngine.sha(d))
    }
    let untouched = doctored("ok") { _, _ in }
    check(untouched == "OPENED", "(an untouched copy opens): \(untouched.prefix(160))")
    let notOne = doctored("code-not-json") { root, ex in try setCode(root, &ex, Data("[]".utf8)) }
    check(notOne.contains("code checklist") && notOne.contains("Refused"), "hostile image: code.json that isn't a checklist refuses the file: \(notOne.prefix(90))")
    let badHash = doctored("code-hash") { root, ex in try setCode(root, &ex, clData([])); ex.checklist?.sha = String(repeating: "0", count: 64) }
    check(badHash.contains("code.json is missing or isn't what export.json says"), "hostile image: a wrong hash refuses it: \(badHash.prefix(90))")
    let crafted = doctored("code-crafted") { root, ex in try setCode(root, &ex, clData([["path": "~/code/x", "git": true, "remote": "https://a:\(tok)@example.com/x.git", "unpushed": "many"]])) }
    check(crafted == "OPENED", "hostile image: a crafted but readable checklist opens (cleaned): \(crafted.prefix(90))")
    let notMove = doctored("code-not-move") { _, ex in ex.move = nil }
    check(notMove.contains("outside a move") || notMove.contains("don't agree"), "hostile image: a checklist in a file that isn't a move is refused: \(notMove.prefix(90))")
    let old4 = doctored("code-v4") { _, ex in ex.version = 4 }
    check(old4.contains("older than the one it came with"), "format: a checklist in a version-4 file is refused: \(old4.prefix(90))")
    // (6 is a move's side files now, read by this build: the newer format is 7)
    let v7 = doctored("v7") { _, ex in ex.version = 7 }
    check(v7.contains("newer cl_audit"), "format: version 7 is refused with the newer-cl_audit words")
    let unnamed = doctored("code-unnamed") { _, ex in ex.checklist = nil }
    check(unnamed != "OPENED", "hostile image: a code.json export.json doesn't name is refused (a file its manifest doesn't name): \(unnamed.prefix(90))")
    SessionsImport.discard(base0.work)

    // ---- the line rewrite on its own
    let m = SessionsRepoint.mapper(folder: "/o/p", picked: "/n/q", dropped: ["/o/p/.claude/worktrees/w"])
    func rw(_ s: String) -> String? { SessionsRepoint.rewrite(line: Array(s.utf8), map: m).map { String(decoding: $0, as: UTF8.self) } }
    check(rw(#"{"cwd":"/o/p"}"#) == #"{"cwd":"/n/q"}"# && rw(#"{"cwd":"/o/p/src","a":1}"#) == #"{"cwd":"/n/q/src","a":1}"# && rw(#"{"cwd":"/o/p/.claude/worktrees/w/x"}"#) == #"{"cwd":"/n/q"}"#,
          "rewrite: the folder, a subfolder (kept under the new one), a dropped worktree (the picked folder)")
    check(rw(#"{"cwd":"/o/pp"}"#) == nil && rw(#"{"x":{"cwd":"/o/p"}}"#) == nil && rw(#"{"cwd":5}"#) == nil && rw("[\"cwd\",\"/o/p\"]") == nil && rw(#"{"cwd":"/o/p/../x"}"#) == nil
          && rw("{\"cwd\":\"/o/p/\\u0007\"}") == nil && rw(#"{"cwd":"/o/p""#) == nil,
          "rewrite: a sibling folder, a nested cwd, a number, an array, '..', a control character, a cut-off line: left as they are")
    check(rw(#"{"cwd":"\/o\/p","cwd":"/o/p/a"}"#) == #"{"cwd":"/n/q","cwd":"/n/q/a"}"# && rw(#"{ "cwd" :"/o/p" , "b":"é"}"#) == #"{ "cwd" :"/n/q" , "b":"é"}"#,
          "rewrite: escaped slashes and a key twice both rewritten; the spacing and other bytes kept")
    let edited = SessionsRepoint.entryRepointed(Data(#"{"cwd":"/o/p","harnessCwd":"/o/p/h","worktreeLazy":{"path":"/o/p/l"},"title":"t"}"#.utf8), folder: "/o/p", picked: "/n/q", map: m, here: { $0 == "/n/q" })
    check(edited.map { String(decoding: $0.data, as: UTF8.self) } == #"{"cwd":"/n/q","title":"t"}"# && edited?.dropped == ["harnessCwd", "worktreeLazy"],
          "entry: a harnessCwd and a lazy worktree whose folders aren't here dropped (the window would spawn there): \(edited.map { String(decoding: $0.data, as: UTF8.self) } ?? "nil")")
    check(SessionsRepoint.entryRepointed(Data("{bad".utf8), folder: "/o/p", picked: "/n/q", map: m, here: { _ in true }) == nil, "entry: one that isn't JSON isn't edited")
    check(SessionsRepoint.clean("/a/b") && !SessionsRepoint.clean("a/b") && !SessionsRepoint.clean("/a/../b") && !SessionsRepoint.clean("/a//b") && !SessionsRepoint.clean("/a/\u{1B}b")
          && !SessionsRepoint.clean("/" + String(repeating: "x", count: 5000)), "paths: only clean absolute ones are used")
    check(SessionsRepoint.projectFolder(of: "/r/app/.claude/worktrees/w/src") == "/r/app" && SessionsRepoint.worktreeFolder(of: "/r/app/.claude/worktrees/w/src") == "/r/app/.claude/worktrees/w",
          "paths: a worktree's project folder")

    // ---- the new Mac: role B, in its own fresh home. gone/app goes away first; old/garden-app is "cloned" to new/garden-app there
    try? fm.removeItem(atPath: code + "/gone"); try? fm.removeItem(atPath: code + "/old"); try? fm.removeItem(atPath: code + "/long")
    let bHome = work + "/b/home"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.environment = ["HOME": bHome, "CFFIXED_USER_HOME": bHome, "RESUME_ROLE": "b", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    if bHome.hasSuffix("/Checks/.work/resume/b/home"), fm.fileExists(atPath: bHome), (try? p.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for l in text.split(separator: "\n") where l.hasPrefix("FAIL") { print(l) }
        if let last = text.split(separator: "\n").last(where: { $0.hasPrefix("checks: ") }) {
            let nums = last.split(separator: " ").compactMap { Int($0) }
            if nums.count == 2 { passed += nums[0]; failed += nums[1] }
            print("role B: \(last.dropFirst(8))")
        } else { check(false, "role B ran: \(text.suffix(600))") }
    } else { check(false, "role B starts in its own home \(bHome)") }
    check(dockCalls == 0 && securityCalls == 0, "A: no Dock write and no Keychain call")
}
print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
