// Side-file checks for cl_audit: a moved session's side files come along (stage 2 of the move's resume work). Sources/SessionsSide.swift
// (what is gathered from Claude Code's folder, the key scan, the caps, side.json read back untrusted), SessionsSideApply.swift (the import
// writing task lists, plans, pasted texts, Rewind's backups create-only, history lines appended under Claude Code's lock with their project
// re-pointed, a folder's trust spliced into .claude.json byte for byte, the sessions waiting for their folder, Undo), SessionsRepoint.swift
// (Rewind's paths re-pointed by a Pick), SessionsExport/SessionsImport (side.json and side/ in a move's image only, format 6 and the
// lowest-version rule, doctored images refused).
//
// Two throwaway homes like the resume suite: A (the old Mac) at Checks/.work/sidefiles/home and B (the new Mac) at
// Checks/.work/sidefiles/b/home, a second run of this program (SIDE_ROLE=b). The sessions' folders are fake projects under
// Checks/.work/sidefiles/code at the same path for both homes: same/app stays, old/garden-app is cloned to new/garden-app in B. Nothing
// opens an app, the Dock or Terminal; Claude Code and the Claude app never run (a "running Claude Code" is the check's own stand-in); the
// Dock's writer and the Keychain's tool are stand-ins that count calls (both stay at zero).

import AppKit
import Foundation
import ProfileCore

setbuf(stdout, nil)
let role = ProcessInfo.processInfo.environment["SIDE_ROLE"] ?? "a"
let home = NSHomeDirectory()
guard (role == "a" && home.hasSuffix("/Checks/.work/sidefiles/home")) || (role == "b" && home.hasSuffix("/Checks/.work/sidefiles/b/home")) else {
    print("refusing: HOME is \(home) for role \(role)"); exit(2)
}
let work = role == "a" ? (home as NSString).deletingLastPathComponent : ((home as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
let sharedDir = work + "/shared"
let code = work + "/code"

BackupPrefs.store = MemoryPrefs()
SessionsMove.prefs = MemoryPrefs()
Store.announce = {}
SettingsModel.applyInstalls = false
SettingsModel.followsDock = false
var dockCalls = 0, securityCalls = 0
DockWriter.backend = DockWriter.Backend(read: { dockCalls += 1; return DockWriter.Lists(pinned: [], recent: []) }, write: { _ in dockCalls += 1 }, restart: { dockCalls += 1 })
Login.runSecurity = { _ in securityCalls += 1; return (44, Data()) }
SessionsRestore.runningSessions = { [] }
// (never the real process list: a "running Claude Code" is this check's own stand-in)
var codeRuns = false
SideFiles.codeRunning = { _ in codeRuns }

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
func json(_ d: Data?) -> [String: Any]? { d.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
func enc(_ p: String) -> String { String(p.utf16.map { u -> Character in ((u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122)) ? Character(UnicodeScalar(u)!) : "-" }) }

let pw = "sidefiles-test-password-not-secret"
let acct = sid(1), org = sid(2), email = "studio@example.com"
let moveFile = sharedDir + "/side move.dmg", rewindFile = sharedDir + "/side move rewind.dmg"
let tok = "ghp_" + "\("")" + "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"      // cut, so no committed file holds a whole one
let same = code + "/same/app", old = code + "/old/garden-app", new = code + "/new/garden-app"
let S1 = sid(101), S2 = sid(102), S9 = sid(109)
let slug = "sorted-brewing-kettle"
let pasteText = "a long pasted stack trace\nline 2\n"
let pasteHash = SideFiles.pasteHash(Data(pasteText.utf8))
let fh1 = "0123456789abcdef@v1", fh2 = "0123456789abcdef@v2"

/// The history lines of the old Mac, as Claude Code writes them (one JSON object a line).
func hline(_ display: String, _ project: String, _ session: String, ts: Int, paste: String? = nil) -> String {
    let pc = paste.map { #"{"1":{"id":1,"type":"text","contentHash":"\#($0)"}}"# } ?? "{}"
    return #"{"display":"\#(display)","pastedContents":\#(pc),"timestamp":\#(ts),"project":"\#(project)","sessionId":"\#(session)"}"#
}
/// S2's transcript: a slug, Rewind's snapshot (a relative and an absolute tracked file, each with its folder's real path) and a delta.
func s2Lines(_ proj: String) -> [String] {
    [#"{"type":"user","sessionId":"\#(S2)","cwd":"\#(proj)","slug":"\#(slug)","uuid":"u1","message":{"role":"user","content":"fix the sign-up form"}}"#,
     #"{"type":"file-history-snapshot","messageId":"m1","snapshot":{"messageId":"m1","trackedFileBackups":{"src/form.ts":{"backupFileName":"\#(fh1)","version":1,"backupTime":"2026-11-01T10:00:00.000Z","realParentDir":"\#(proj)/src"},"\#(proj)/lib/x.ts":{"backupFileName":"\#(fh2)","version":2,"backupTime":"2026-11-01T10:00:00.000Z","realParentDir":"\#(proj)/lib"}},"timestamp":"2026-11-01T10:00:00.000Z"},"isSnapshotUpdate":false}"#,
     #"{"type":"file-history-delta","messageId":"m2","snapshotMessageId":"m1","trackingPath":"\#(proj)/lib/x.ts","backup":{"backupFileName":"\#(fh2)","version":2,"backupTime":"2026-11-01T10:00:00.000Z","realParentDir":"\#(proj)/lib"},"timestamp":"2026-11-01T10:00:01.000Z"}"#,
     #"{"type":"assistant","cwd":"\#(proj)","uuid":"u2","message":{"content":[{"type":"text","text":"done in \#(proj)"}]}}"#]
}
let configA = #"{"numStartups": 7, "oauthAccount": {"accountUuid": "\#(acct)", "emailAddress": "\#(email)"}, "projects": {"\#(old)": {"allowedTools": ["Bash(npm test)", "Edit"], "hasTrustDialogAccepted": true, "mcpServers": {"db": {"command": "pg-mcp"}}, "lastCost": 1.25}, "\#(same)": {"allowedTools": [], "hasTrustDialogAccepted": true}, "\#(code)": {"hasTrustDialogAccepted": true}, "/elsewhere": {"hasTrustDialogAccepted": true}}}"#

// ================================================================== role B: the new Mac
if role == "b" {
    MainActor.assumeIsolated {
        let place = BackupPrefs.placeURL
        guard let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: place) else { check(false, "B: the move file opens"); return }
        check(o.move && o.export.version == 6 && o.side?.parts.count == 1, "B: a move with side files is format 6: \(o.export.version)")
        let plan0 = SessionsMove.plan(o.app!, accounts: Store.load())
        _ = try! SessionsMove.apply(plan0, takeSettings: false, file: o.fileName)
        let e = Store.load().first { $0.name == "Studio" }!
        let t = SessionsRestore.Target(e)
        let cc = t.codeDir
        try! fm.createDirectory(atPath: cc, withIntermediateDirectories: true)
        let st = try! SessionsImport.materialize(o, part: o.parts[0], target: e.id)
        let b = try! SessionsImport.commit(st, place: place)
        SessionsImport.discard(o.work)
        let manifest = SessionsBackup.load(profile: b.profile, id: b.id, place: b.place)
        check(fm.fileExists(atPath: b.dir.path + "/side/side.json") && manifest?.items.contains { $0.path.hasPrefix("side/") } == false,
              "B: the side files are kept with the imported backup (side/), outside its manifest (an export of it never carries them)")
        guard let stash = SideFiles.stashed(b) else { check(false, "B: the stash reads back"); return }
        let plan = SideFiles.plan(stash)
        check(plan.taskLists == 1 && plan.taskFiles == 3 && plan.plans == 1 && plan.historyLines == 4 && plan.pastes == 1 && plan.trust == 2 && plan.rewindFiles == 0 && plan.rewindOnOldMac > 0,
              "B: the Import page's rows: 1 task list (3 files), 1 plan, 4 history lines, 1 pasted text, trust for 2 folders, Rewind not in the file (its size on the old Mac said): \(plan)")
        check(plan.hits.contains { $0.what.contains("prompt history") && !$0.kept }, "B: the key found in a history line on the old Mac is listed (left out)")
        let kinds = SideFiles.importKinds(plan)
        check(kinds.tasks && kinds.plans && kinds.history && kinds.trust && !kinds.mcp && !kinds.rewind, "B: a move's import starts with every kind on, the MCP servers off")

        // this Mac's own files: a .claude.json with other projects, an account block and an entry already for same/app; a history.jsonl
        let configB = #"{"numStartups": 2, "oauthAccount": {"accountUuid": "\#(acct)", "emailAddress": "\#(email)"}, "projects": {"\#(same)": {"allowedTools": ["Read"], "hasTrustDialogAccepted": false}, "/srv/other-project": {"hasTrustDialogAccepted": true}}, "theme": "dark"}"#
        write(cc + "/.claude.json", configB)
        let histB = hline("an earlier prompt here", "/srv/other-project", sid(200), ts: 1) + "\n"
        write(cc + "/history.jsonl", histB)
        try! fm.createDirectory(atPath: new, withIntermediateDirectories: true)

        // the import, then S2's pick, then the side files (the order RestoreRunner runs them in)
        let rr = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let rp = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: new)], restore: rr.id, windowClosed: { true })
        check(rr.finished != nil && rp.sessions.count == 1, "B: imported, S2 pointed at new/garden-app: \(rp.problems)")
        var folders: [String: SideFiles.Folder] = [:]
        for d in rp.sessions { folders[d.session] = (d.from, d.to) }
        guard let r = (try? SideFiles.apply(t, b, kinds: kinds, restore: rr.id, folders: folders, windowClosed: { true })) ?? nil else { check(false, "B: the side files are written"); return }
        check(r.written.tasks == 3 && r.written.plans == 1 && r.written.pastes == 1 && r.written.historyLines == 4 && r.written.trust == 1 && r.written.rewind == 0,
              "B: written: 3 task files, 1 plan, 1 pasted text, 4 history lines, trust for 1 folder: \(r.written) \(r.problems)")
        check(read(cc + "/tasks/\(S2)/1.json")?.contains("Fix the form") == true && fm.fileExists(atPath: cc + "/tasks/\(S2)/.highwatermark") && !fm.fileExists(atPath: cc + "/tasks/\(S2)/.lock"),
              "B: the task list under tasks/<id>/ (not its lock file)")
        check(read(cc + "/plans/\(slug).md") == "# Plan\nfix the form\n", "B: the plan under plans/<slug>.md")
        check(read(cc + "/paste-cache/\(pasteHash).txt") == pasteText, "B: the pasted text under paste-cache/<hash>.txt")
        let pasteAge = (try? fm.attributesOfItem(atPath: cc + "/paste-cache/\(pasteHash).txt"))?[.modificationDate] as? Date
        check(pasteAge.map { Date().timeIntervalSince($0) < 600 } == true, "B: a written file has the time now (Claude Code's clean-up goes by age)")
        // history.jsonl: what was there stays byte for byte; the session's lines come after, each pointed at its folder here
        let hist = read(cc + "/history.jsonl") ?? ""
        let added = hist.hasPrefix(histB) ? String(hist.dropFirst(histB.count)) : ""
        let addedLines = added.split(separator: "\n").map(String.init)
        check(hist.hasPrefix(histB) && addedLines.count == 4, "B: history.jsonl: its own lines untouched, 4 lines added at the end: \(addedLines.count)")
        check(addedLines.filter { $0.contains(S2) }.allSatisfy { $0.contains(#""project":"\#(new)""#) } && addedLines.filter { $0.contains(S1) }.allSatisfy { $0.contains(#""project":"\#(same)""#) },
              "B: each added line's project is the session's folder here (S2: new/garden-app; S1: same/app, as it was)")
        check(addedLines.first { $0.contains("stack trace please") } == hline("stack trace please", old, S2, ts: 1_762_000_002, paste: pasteHash).replacingOccurrences(of: #""project":"\#(old)""#, with: #""project":"\#(new)""#),
              "B: an added line is byte for byte the old one but its project")
        check(!hist.contains(S9) && !hist.contains(tok), "B: no line of another session, no line that held a key")
        check(!fm.fileExists(atPath: cc + "/history.jsonl.lock") && !fm.fileExists(atPath: cc + "/.claude.json.lock"), "B: Claude Code's lock folders are let go")
        // .claude.json: byte for byte as it was, but the one key added; same/app's own entry kept
        let cfg = read(cc + "/.claude.json") ?? ""
        let cj = json(Data(cfg.utf8))
        let projects = cj?["projects"] as? [String: Any]
        let newEntry = projects?[new] as? [String: Any]
        check(newEntry?["hasTrustDialogAccepted"] as? Bool == true && (newEntry?["allowedTools"] as? [String]) == ["Bash(npm test)", "Edit"] && (newEntry?["mcpServers"] as? [String: Any])?.isEmpty == true
              && newEntry?["lastCost"] == nil, "B: new/garden-app is trusted with its allowed tools; its MCP servers left out; nothing else of the old entry: \(String(describing: newEntry))")
        check((projects?[same] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == false && r.problems.contains { $0.contains("already has its own trust") },
              "B: an entry already there for that folder wins, and that is said")
        check(projects?[code] == nil && projects?["/elsewhere"] == nil, "B: trust kept for a folder above the project (and another project) isn't carried")
        let value = r.steps.first { $0.kind == .trust }?.value ?? "?"
        let anchor = #""/srv/other-project": {"hasTrustDialogAccepted": true}"#
        check(cfg == configB.replacingOccurrences(of: anchor, with: anchor + #", "\#(new)": "# + value),
              "B: .claude.json is byte for byte as it was but the one key added after the last project (other projects, the account block, key order kept): \(cfg.prefix(300))")
        let unsplice = SideFiles.unspliced(Array(cfg.utf8), key: new, value: value)
        check(unsplice.map { String(decoding: $0, as: UTF8.self) } == configB, "B: taking the key out again gives the old file byte for byte")
        // no copy of .claude.json anywhere in cl_audit's folder (only the key and the entry written are kept); an old one is swept
        func copies() -> [String] { files(Store.folder.path).filter { read(Store.folder.path + "/" + $0)?.contains("oauthAccount") == true } }
        check(copies().isEmpty && r.steps.first { $0.kind == .trust }?.saved == nil, "B: no copy of .claude.json anywhere in cl_audit's folder after the import: \(copies())")
        write(SideFiles.root.path + "/\(r.id)/saved/claude-json-9.copy", configB)
        SideFiles.sweepConfigCopies()
        check(copies().isEmpty, "B: a copy the first build kept is swept")
        // the same again (a second Restore, an import again): no prompt doubled, nothing written twice
        let again = try! SideFiles.apply(t, b, kinds: kinds, restore: rr.id, folders: folders, windowClosed: { true })!
        check(again.written.historyLines == 0 && again.written.there >= 4 && read(cc + "/history.jsonl") == hist && read(cc + "/.claude.json") == cfg && again.written.trust == 0,
              "B: applied again: no prompt added twice, no file or trust written again: \(again.written)")
        check(SideWords.after(r.written.taskLists, "task list", "task lists") == "1\u{00A0}task list added" && r.written.taskLists == 1
              && SideWords.after(2, "typed prompt", "typed prompts", waiting: 2) == "2\u{00A0}typed prompts added · 2 wait for a folder you pick",
              "B: after the import, a row says what was added and what waits: \(SideWords.after(r.written.taskLists, "task list", "task lists"))")
        // Rewind's paths in the re-pointed transcript
        let t2 = read(cc + "/projects/\(enc(new))/\(S2).jsonl") ?? ""
        let snap = t2.split(separator: "\n").first { $0.contains("file-history-snapshot") }.map(String.init) ?? ""
        let delta = t2.split(separator: "\n").first { $0.contains("file-history-delta") }.map(String.init) ?? ""
        check(snap.contains(#""src/form.ts":{"#) && snap.contains(#""\#(new)/lib/x.ts":{"#) && snap.contains(#""realParentDir":"\#(new)/src""#) && snap.contains(#""realParentDir":"\#(new)/lib""#)
              && !snap.contains(old), "B: a Pick re-points Rewind's snapshot: the absolute tracked file and each folder's real path; the relative one as it was")
        check(snap == s2Lines(old)[1].replacingOccurrences(of: old, with: new), "B: …every other byte of the snapshot line as it was")
        check(delta == s2Lines(old)[2].replacingOccurrences(of: old, with: new), "B: Rewind's delta line: its trackingPath and realParentDir re-pointed, the rest as it was")
        // never carried
        check(!fm.fileExists(atPath: cc + "/session-env") && !fm.fileExists(atPath: cc + "/image-cache") && !fm.fileExists(atPath: cc + "/shell-snapshots") && !fm.fileExists(atPath: cc + "/debug")
              && !fm.fileExists(atPath: cc + "/todos") && !fm.fileExists(atPath: cc + "/file-history"), "B: no session env, image cache, shell snapshots, debug files, old todos; no Rewind (left out of the file)")

        // ---- Undo of the import takes the side files back first, exactly
        let u = try! SessionsRestore.undo(rr.id, windowClosed: { true })
        let su = SideFiles.load(r.id)
        check(u.undone != nil && su?.undone != nil && su?.left.isEmpty == true, "B: the import's Undo takes the side files back: \(su?.left ?? [])")
        check(read(cc + "/history.jsonl") == histB && read(cc + "/.claude.json") == configB, "B: history.jsonl and .claude.json are byte for byte as they were")
        check(!fm.fileExists(atPath: cc + "/tasks/\(S2)") && !fm.fileExists(atPath: cc + "/plans/\(slug).md") && !fm.fileExists(atPath: cc + "/paste-cache/\(pasteHash).txt"),
              "B: the task list, the plan and the pasted text go (and the folders it made)")

        // ---- a Restore of the imported backup brings them as the import did; this time S2 isn't picked: it waits, then is picked later
        try? fm.removeItem(atPath: new)
        let rr2 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let r2 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr2.id, windowClosed: { true })!
        check(r2.written.tasks == 3 && r2.written.historyLines == 2 && r2.waiting.count == 1 && r2.waiting.first?.session == S2 && r2.waiting.first?.historyLines == 2,
              "B: a Restore of the imported backup writes them too; S2's folder isn't here, so its 2 history lines and trust wait (S1's 2 lines written): \(r2.written) \(r2.waiting.map(\.session))")
        check(json(fm.contents(atPath: cc + "/.claude.json")).flatMap { ($0["projects"] as? [String: Any])?[new] } == nil, "B: no trust written for a folder that isn't on this Mac")
        check(SideWords.written(r2).replacingOccurrences(of: "\u{00A0}", with: " ").contains("1 session waits for its folder"), "B: the page says what waits: \(SideWords.written(r2))")
        // the Sessions page's Pick, later (the code cloned first): its history and trust are written then, into the import's receipt
        try! fm.createDirectory(atPath: new, withIntermediateDirectories: true)
        codeRuns = true
        let blocked = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: new)], windowClosed: { true })
        check(blocked.problems.contains { $0.contains("Claude Code is running for this profile") && $0.contains("Undo this Pick") } && SideFiles.load(r2.id)?.waiting.count == 1 && !(read(cc + "/history.jsonl") ?? "").contains(new),
              "B: with Claude Code running for this profile, nothing shared is written (said), and S2 keeps waiting: \(blocked.problems)")
        _ = try! SessionsRepoint.undo(blocked.id, windowClosed: { true })
        codeRuns = false
        let later = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: new)], windowClosed: { true })
        let r2b = SideFiles.load(r2.id)
        let hist2 = read(cc + "/history.jsonl") ?? ""
        check(later.sessions.count == 1 && SideFiles.waiting(profile: e.id).isEmpty && r2b?.waiting.first?.pick == later.id && hist2.components(separatedBy: #""project":"\#(new)""#).count - 1 == 2
              && (json(fm.contents(atPath: cc + "/.claude.json"))?["projects"] as? [String: Any])?[new] != nil && later.sessions[0].sideWritten == true,
              "B: picked later from Sessions: S2's 2 history lines (project new/garden-app) and its trust are written then: \(later.problems)")
        // that Pick's Undo takes back what it wrote (S1's lines from the import stay), and S2 waits for its folder again
        _ = try! SessionsRepoint.undo(later.id, windowClosed: { true })
        let afterPickUndo = read(cc + "/history.jsonl") ?? ""
        check(!afterPickUndo.contains(#""project":"\#(new)""#) && afterPickUndo.contains(S1) && read(cc + "/.claude.json") == configB && SideFiles.waiting(profile: e.id).map(\.session) == [S2],
              "B: the later Pick's Undo takes back the prompts and trust it added; the session waits again")
        // picked again, then the import's Undo takes it all back (the Pick's lines are in the import's receipt)
        let later2 = try! SessionsRepoint.apply(t, picks: [SessionsRepoint.Pick(session: S2, folder: new)], windowClosed: { true })
        check((read(cc + "/history.jsonl") ?? "").components(separatedBy: #""project":"\#(new)""#).count - 1 == 2, "B: picked again: its prompts are added again")
        _ = try! SessionsRepoint.undo(later2.id, windowClosed: { true })
        let u2 = try! SessionsRestore.undo(rr2.id, windowClosed: { true })
        check(u2.undone != nil && read(cc + "/history.jsonl") == histB && read(cc + "/.claude.json") == configB, "B: the Pick's Undo, then the import's: both files byte for byte as they were")

        // ---- refusals: a link, Claude Code's lock held, a running Claude Code, a pasted text already there with other bytes, a line changed since
        let rr3 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        try! fm.removeItem(atPath: cc + "/.claude.json")
        write(home + "/elsewhere.json", configB)
        try! fm.createSymbolicLink(atPath: cc + "/.claude.json", withDestinationPath: home + "/elsewhere.json")
        try! fm.createDirectory(atPath: cc + "/history.jsonl.lock", withIntermediateDirectories: false)
        write(cc + "/paste-cache/\(pasteHash).txt", "other text under that name\n")
        let r3 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr3.id, folders: [S2: (old, new)], windowClosed: { true })!
        check(r3.written.trust == 0 && r3.problems.contains { $0.contains("settings file for this profile is a link") } && read(home + "/elsewhere.json") == configB,
              "B: .claude.json that is a link: never written through: \(r3.problems)")
        check(r3.written.historyLines == 0 && r3.problems.contains { $0.contains("prompt history file is locked") } && read(cc + "/history.jsonl") == histB,
              "B: Claude Code's lock folder held: no line added, said")
        check(read(cc + "/paste-cache/\(pasteHash).txt") == "other text under that name\n" && r3.problems.contains { $0.contains("other content") },
              "B: a pasted text already there with other bytes is left as it is, said")
        rmdir(cc + "/history.jsonl.lock")
        try! fm.removeItem(atPath: cc + "/.claude.json"); write(cc + "/.claude.json", configB)
        _ = try! SessionsRestore.undo(rr3.id, windowClosed: { true })
        try? fm.removeItem(atPath: cc + "/paste-cache/\(pasteHash).txt")
        // history.jsonl as a link: refused
        try! fm.moveItem(atPath: cc + "/history.jsonl", toPath: home + "/hist-real.jsonl")
        try! fm.createSymbolicLink(atPath: cc + "/history.jsonl", withDestinationPath: home + "/hist-real.jsonl")
        let rr4 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let r4 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr4.id, folders: [S2: (old, new)], windowClosed: { false })!
        check(r4.written.historyLines == 0 && r4.written.trust == 0 && r4.problems.contains { $0.contains("window is open") }, "B: the window open: no history or trust written, said: \(r4.problems)")
        _ = try! SessionsRestore.undo(rr4.id, windowClosed: { true })
        let rr5 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let r5 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr5.id, folders: [S2: (old, new)], windowClosed: { true })!
        check(r5.written.historyLines == 0 && r5.problems.contains { $0.contains("prompt history file is a link") } && read(home + "/hist-real.jsonl") == histB,
              "B: history.jsonl that is a link: never appended through: \(r5.problems)")
        try! fm.removeItem(atPath: cc + "/history.jsonl"); try! fm.moveItem(atPath: home + "/hist-real.jsonl", toPath: cc + "/history.jsonl")
        _ = try! SessionsRestore.undo(rr5.id, windowClosed: { true })
        // Undo leaves what changed since: a history line edited, the trust entry changed by Claude Code
        let rr6 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let r6 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr6.id, folders: [S2: (old, new)], windowClosed: { true })!
        check(r6.written.historyLines == 4 && r6.written.trust == 1, "B: (written again for the Undo check)")
        var h6 = read(cc + "/history.jsonl")!
        h6 = h6.replacingOccurrences(of: "stack trace please", with: "stack trace please!")
        try! Data(h6.utf8).write(to: URL(fileURLWithPath: cc + "/history.jsonl"))
        var c6 = read(cc + "/.claude.json")!
        c6 = c6.replacingOccurrences(of: #""hasClaudeMdExternalIncludesWarningShown":false"#, with: #""hasClaudeMdExternalIncludesWarningShown":false,"lastCost":0.5"#)
        try! Data(c6.utf8).write(to: URL(fileURLWithPath: cc + "/.claude.json"))
        _ = try! SessionsRestore.undo(rr6.id, windowClosed: { true })
        let s6 = SideFiles.load(r6.id)
        let h6b = read(cc + "/history.jsonl") ?? ""
        check(s6?.undone != nil && h6b.hasPrefix(histB) && h6b.contains("stack trace please!") && h6b.split(separator: "\n").count == 2 && read(cc + "/.claude.json") == c6
              && s6?.left.count == 2, "B: Undo takes out only the lines still as written (the edited one stays) and leaves a changed trust entry; both said: \(s6?.left ?? [])")
        write(cc + "/history.jsonl", histB); write(cc + "/.claude.json", configB)

        // ---- the file with Rewind on: its backups land under file-history/<id>/ with their modes
        guard let ow = try? SessionsImport.open(URL(fileURLWithPath: rewindFile), password: pw, place: place) else { check(false, "B: the Rewind file opens"); return }
        let stw = try! SessionsImport.materialize(ow, part: ow.parts[0], target: e.id)
        let bw = try! SessionsImport.commit(stw, place: place)
        SessionsImport.discard(ow.work)
        let pw0 = SideFiles.stashed(bw).map(SideFiles.plan)
        check(pw0?.rewindFiles == 2 && SideFiles.importKinds(pw0!).rewind, "B: a file with Rewind: its row is on with 2 backups: \(String(describing: pw0?.rewindFiles))")
        // (this time .claude.json has no projects of its own: the folder at the same path gets its trust too, and the MCP servers are added)
        let configC = #"{"oauthAccount": {"accountUuid": "\#(acct)"}, "projects": {}}"#
        write(cc + "/.claude.json", configC)
        let rrw = try! SessionsRestore.run(t, bw, addMemory: true, windowClosed: { true })
        var kw = SideFiles.importKinds(pw0!); kw.mcp = true
        let rw = try! SideFiles.apply(t, bw, kinds: kw, restore: rrw.id, folders: [S2: (old, new)], windowClosed: { true })!
        var mst = stat()
        check(rw.written.rewind == 2 && read(cc + "/file-history/\(S2)/\(fh1)") == "export const form = 1\n" && lstat(cc + "/file-history/\(S2)/\(fh2)", &mst) == 0 && mst.st_mode & 0o777 == 0o644,
              "B: Rewind's backups under file-history/<id>/, the mode kept (Rewind restores a file with it): \(rw.written)")
        let pc = json(fm.contents(atPath: cc + "/.claude.json"))?["projects"] as? [String: Any]
        check(rw.written.trust == 2 && rw.written.mcp == 1 && (pc?[same] as? [String: Any])?["hasTrustDialogAccepted"] as? Bool == true
              && ((pc?[new] as? [String: Any])?["mcpServers"] as? [String: Any])?["db"] != nil, "B: the folder at the same path is trusted as on the old Mac; with Add them, the project's MCP servers come with its trust: \(rw.written)")
        _ = try! SessionsRestore.undo(rrw.id, windowClosed: { true })
        check(!fm.fileExists(atPath: cc + "/file-history/\(S2)/\(fh1)") && read(cc + "/.claude.json") == configC, "B: Undo takes Rewind's backups and both keys back")
        // ---- a Claude Code process that can't be read counts as running; Claude Code's lock held too long; trust for ~ refused
        let rr7 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        SideFiles.codeRunning = { _ in nil }
        let r7 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr7.id, folders: [S2: (old, new)], windowClosed: { true })!
        check(r7.written.historyLines == 0 && r7.written.trust == 0 && r7.problems.contains { $0.contains("couldn't be told whether Claude Code is running") } && read(cc + "/history.jsonl") == histB,
              "B: whether Claude Code runs can't be told (a process that can't be read): nothing shared written, said: \(r7.problems)")
        SideFiles.codeRunning = { _ in codeRuns }
        _ = try! SessionsRestore.undo(rr7.id, windowClosed: { true })
        let rr8 = try! SessionsRestore.run(t, b, addMemory: true, windowClosed: { true })
        let before8 = read(cc + "/.claude.json")
        SideFiles.lockBudget = -1
        let r8 = try! SideFiles.apply(t, b, kinds: kinds, restore: rr8.id, folders: [S2: (old, new)], windowClosed: { true })!
        SideFiles.lockBudget = 4
        check(r8.written.trust == 0 && r8.problems.contains { $0.contains("took too long") } && read(cc + "/.claude.json") == before8 && !fm.fileExists(atPath: cc + "/.claude.json.lock"),
              "B: Claude Code's settings lock held past its budget: the trust isn't written, said, the lock let go: \(r8.problems)")
        _ = try! SessionsRestore.undo(rr8.id, windowClosed: { true })
        let homeTrust = SideFiles.Trust(session: S2, key: home, trusted: true, allowedTools: ["Bash"])
        if case .refused(let why) = SideFiles.trustEntry(homeTrust, (home, home), mcp: false, label: "x") { check(why.contains("home folder"), "B: trust for ~ refused, said: \(why)") }
        else { check(false, "B: trust for the home folder is refused") }
        check(SideFiles.broad("/") && SideFiles.broad("/Users") && SideFiles.broad(home) && SideFiles.broad((home as NSString).deletingLastPathComponent) && !SideFiles.broad(home + "/code") && !SideFiles.broad(new),
              "B: never trust /, /Users, the home folder or above it; a project folder is fine")
        // ---- when the import can't be undone any more (30 days on): the stash goes with its receipt
        let stashDir = b.dir.appendingPathComponent("side").path
        check(fm.fileExists(atPath: stashDir), "B: (the stash is there before)")
        SessionsRestore.prune(profile: e.id, now: Date().addingTimeInterval(40 * 86400))
        check(!fm.fileExists(atPath: stashDir) && SideFiles.receipts().filter { $0.restore == rr.id }.isEmpty && SessionsBackup.load(profile: b.profile, id: b.id, place: b.place) != nil,
              "B: once the import can't be undone, its side files kept with the backup go (the backup stays), and its receipts with them")
        check(dockCalls == 0 && securityCalls == 0, "B: no Dock write and no Keychain call")
    }
    print("checks: \(passed) passed, \(failed) failed")
    exit(failed == 0 ? 0 : 1)
}

// ================================================================== role A: the old Mac
MainActor.assumeIsolated {
    try? fm.removeItem(atPath: sharedDir); try! fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
    try? fm.removeItem(atPath: code)
    for d in [same, old] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    var studio = AccountEntry(id: "studio", name: "Studio", label: "STUDIO", configDir: "~/.claude-studio")
    studio.desktop = .separate; studio.desktopDataDir = "~/Library/Application Support/Claude-studio"
    studio.seat = Seat(account: acct, organization: org, email: email)
    try! Store.save([studio])
    let cc = expand(studio.configDir), wd = expand(studio.desktopDataDir)
    let scope = "\(wd)/claude-code-sessions/\(acct)/\(org)"
    write("\(cc)/projects/\(enc(same))/\(S1).jsonl", #"{"type":"user","sessionId":"\#(S1)","cwd":"\#(same)","message":{"role":"user","content":"hello"}}"# + "\n")
    write("\(scope)/local_\(sid(11)).json", #"{"sessionId":"local_\#(sid(11))","cliSessionId":"\#(S1)","title":"Same place","cwd":"\#(same)","isArchived":false}"#)
    write("\(cc)/projects/\(enc(old))/\(S2).jsonl", s2Lines(old).joined(separator: "\n") + "\n")
    write("\(scope)/local_\(sid(12)).json", #"{"sessionId":"local_\#(sid(12))","cliSessionId":"\#(S2)","title":"Fix the sign-up form","cwd":"\#(old)","originCwd":"\#(old)","isArchived":false}"#)
    for f in files(cc + "/projects") { try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: cc + "/projects/" + f) }
    // the side files
    write("\(cc)/tasks/\(S2)/1.json", #"{"id":"1","subject":"Fix the form","description":"","status":"in_progress","blocks":[],"blockedBy":[]}"#)
    write("\(cc)/tasks/\(S2)/2.json", #"{"id":"2","subject":"Add a test","description":"","status":"pending","blocks":[],"blockedBy":[]}"#)
    write("\(cc)/tasks/\(S2)/.highwatermark", "2")
    write("\(cc)/tasks/\(S2)/.lock", "")
    write("\(cc)/tasks/\(S2)/notes.txt", "not a task file")
    write("\(cc)/plans/\(slug).md", "# Plan\nfix the form\n")
    write("\(cc)/plans/other-plan.md", "# another session's plan\n")
    let histA = [hline("hello", same, S1, ts: 1_762_000_000), hline("fix the sign-up form", old, S2, ts: 1_762_000_001),
                 hline("another session", old, S9, ts: 1_762_000_003),
                 hline("stack trace please", old, S2, ts: 1_762_000_002, paste: pasteHash),
                 hline("my token is \(tok)", old, S2, ts: 1_762_000_004), "not json at all", hline("again", same, S1, ts: 1_762_000_005)]
    write("\(cc)/history.jsonl", histA.joined(separator: "\n") + "\n")
    write("\(cc)/paste-cache/\(pasteHash).txt", pasteText)
    write("\(cc)/paste-cache/ffffffffffffffff.txt", "a paste no carried line names\n")
    write("\(cc)/file-history/\(S2)/\(fh1)", "export const form = 1\n")
    write("\(cc)/file-history/\(S2)/\(fh2)", "export const x = 2\n")
    chmod("\(cc)/file-history/\(S2)/\(fh2)", 0o644)
    write("\(cc)/file-history/\(S2)/not-a-backup", "x")
    write("\(cc)/.claude.json", configA)
    for (d, f) in [("session-env/\(S2)", "SessionStart-hook-0.sh"), ("image-cache/\(S2)", "1.png"), ("shell-snapshots", "snapshot-zsh-1.sh"), ("debug", "\(S2).txt"), ("todos", "\(S2)-agent-\(S2).json")] {
        write("\(cc)/\(d)/\(f)", "export SECRET_HOOK_VALUE=never-carried\n")
    }

    // ---- the preview, as the Export page counts it
    let refs = SideFiles.sessions(codeDir: cc)
    check(refs.count == 2 && refs.contains { $0.id == S2 && $0.cwd == old }, "preview: the profile's 2 sessions with their folders")
    let pv = SideFiles.gather(codeDir: cc, sessions: refs, kinds: .movePreset, keys: .leaveOut, dir: "p1", out: nil)!.preview
    check(pv.taskLists == 1 && pv.plans == 1 && pv.historyLines == 4 && pv.pastes == 1 && pv.trust == 2 && pv.mcpServers == 1 && pv.rewindFiles == 2 && !pv.rewindCarried,
          "preview: 1 task list, 1 plan, 4 history lines (the key line left out), 1 pasted text, trust for 2 folders (1 MCP server), Rewind 2 backups left out: \(pv)")
    check(pv.hits.count == 1 && pv.hits[0].what.contains("prompt history") && pv.hits[0].kinds == [.github] && !pv.hits[0].kept, "preview: the key in a history line is listed: \(pv.hits)")
    func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{00A0}", with: " ") }
    check(plain(SideWords.carried(pv, kinds: .movePreset)) == "1 task list · 1 plan · 4 typed prompts (1 pasted text) · trust and allowed tools for 2 folders (1 MCP server)", "export page: \(SideWords.carried(pv, kinds: .movePreset))")
    check(plain(SideWords.rewind(pv, on: false)).hasPrefix("left out: 2 backups, "), "export page: Rewind's row says its size, off: \(SideWords.rewind(pv, on: false))")
    let pvKeep = SideFiles.gather(codeDir: cc, sessions: refs, kinds: .movePreset, keys: .keep, dir: "p1", out: nil)!.preview
    check(pvKeep.historyLines == 5 && pvKeep.hits.first?.kept == true, "preview: keys kept: the line with the key goes in (the image only)")
    // caps on their own: a history line over 1 MB, a plan over 4 MB
    let big = home + "/caps"
    write(big + "/history.jsonl", hline(String(repeating: "x", count: SideFiles.maxHistoryLine + 10), old, S2, ts: 9) + "\n" + hline("small", old, S2, ts: 10) + "\n")
    let capped = SideFiles.historyLines(big + "/history.jsonl", sessions: [S2])
    check(capped?.long == 1 && capped?.lines[S2]?.count == 1, "caps: a history line over 1 MB is left out and counted")
    write(big + "/projects/-x/\(S2).jsonl", s2Lines(old)[0] + "\n")
    write(big + "/plans/\(slug).md", String(repeating: "p", count: SideFiles.maxPlan + 1))
    let capPart = SideFiles.gather(codeDir: big, sessions: [SideFiles.SessionRef(id: S2, cwd: old, transcript: big + "/projects/-x/\(S2).jsonl")], kinds: .movePreset, keys: .leaveOut, dir: "p1", out: nil)!
    check(capPart.part.sessions.first?.plan == nil && capPart.part.leftOut.contains { $0.contains("over 4 MB") } && capPart.part.leftOut.contains { $0.contains("over 1 MB") },
          "caps: a plan over 4 MB is left out, and each cap hit is said: \(capPart.part.leftOut)")

    // ---- a plain backup never holds any of it
    let m = try! SessionsBackup.make(SessionsBackup.Source(studio), kind: .manual, window: true, transcripts: true, setup: true, place: BackupPrefs.placeURL)
    check(!m.items.contains { ["tasks/", "plans/", "history", "paste-cache", "file-history", ".claude.json", "side"].contains(where: $0.path.contains) && !$0.path.hasPrefix("transcripts/") }
          && !fm.fileExists(atPath: SessionsBackup.folder(profile: "studio", place: BackupPrefs.placeURL).appendingPathComponent(m.id).appendingPathComponent("side").path),
          "a plain backup never holds a task list, plan, history, paste, Rewind backup, .claude.json or side files")

    // ---- the move, with side files; Rewind off, then on
    let bplace = BackupPrefs.placeURL
    let all = Store.load()
    var job = SessionsExport.Job(parts: [SessionsExport.Part(profile: studio.id, name: studio.name, source: SessionsBackup.Source(studio), emails: [email])], keys: .leaveOut, password: pw,
                                 destination: URL(fileURLWithPath: moveFile), rootName: "side move", place: bplace)
    job.move = true; job.profiles = SessionsMove.make(all, parts: ["studio": "p1"], all: all, move: true); job.known = Identities.of(accounts: all)
    job.side = .movePreset
    let mo = try? SessionsExport.run(job)
    check(mo?.side?.historyLines == 4 && mo?.side?.hits.count == 1, "export: the move carries the side files, the key's line left out and listed: \(String(describing: mo?.side?.hits))")
    guard let o = try? SessionsImport.open(URL(fileURLWithPath: moveFile), password: pw, place: bplace) else { check(false, "export: the move opens"); return }
    let tree = o.tree.path
    let sideText = files(tree + "/side").compactMap { read(tree + "/side/" + $0) }.joined(separator: "\n") + (read(tree + "/side.json") ?? "")
    check(o.export.version == 6 && o.export.side?.path == "side.json" && o.side?.parts.first?.sessions.count == 2, "export: format 6, side.json in the image")
    check(!sideText.contains(tok) && !sideText.contains("SECRET_HOOK_VALUE") && !sideText.contains("another session") && !sideText.contains("other-plan") && !sideText.contains("a paste no carried line names")
          && !sideText.contains("not a task file") && sideText.contains("pg-mcp"), "export: no key line, no session env / image cache / snapshots / debug / todos, no other session's line, plan or paste; the MCP servers ride along in side.json")
    check(!sideText.contains("\"lastCost\"") && !sideText.contains("oauthAccount") && !sideText.contains(email), "export: from .claude.json only the trust fields (and the MCP servers apart): no account block, no other field")
    check(o.side?.parts.first?.sessions.first { $0.id == S2 }?.rewind.isEmpty == true && (o.side?.parts.first?.sessions.first { $0.id == S2 }?.rewindBytes ?? 0) > 0, "export: Rewind left out (its size noted)")
    check(!files(tree).contains { ($0 as NSString).lastPathComponent.lowercased().hasPrefix(".claude.json") }, "export: nothing named like .claude.json in the image")
    var jobR = job; jobR.side = { var k = SideFiles.Kinds.movePreset; k.rewind = true; return k }(); jobR.destination = URL(fileURLWithPath: rewindFile); jobR.rootName = "side move rewind"
    let mr = try? SessionsExport.run(jobR)
    check(mr?.side?.rewindCarried == true, "export: Rewind on: its backups go in")
    // the lowest-version rule: without side files a move stays 5 (with a checklist) or 4
    var job4 = job; job4.side = nil; job4.destination = URL(fileURLWithPath: sharedDir + "/noside.dmg"); job4.rootName = "no side"
    if let o4 = (try? SessionsExport.run(job4)).flatMap({ try? SessionsImport.open($0.file, password: pw, place: bplace) }) {
        check(o4.export.version == 4 && o4.side == nil && !fm.fileExists(atPath: o4.tree.path + "/side.json"), "format: a move without side files stays 4")
        SessionsImport.discard(o4.work)
    } else { check(false, "format: the move without side files opens") }
    func olderReads(_ v: Int) -> Bool { v >= 1 && v <= 5 }
    check(!olderReads(6) && olderReads(5), "format: 26.11.12's rule (up to 5) refuses 6")
    var zipJob = job; zipJob.move = false; zipJob.profiles = nil; zipJob.password = nil; zipJob.destination = URL(fileURLWithPath: sharedDir + "/plain.zip"); zipJob.rootName = "plain zip"
    if let zo = try? SessionsExport.run(zipJob), let oz = try? SessionsImport.open(zo.file, password: nil, place: bplace) {
        check(zo.side == nil && oz.export.side == nil && !fm.fileExists(atPath: oz.tree.path + "/side") && oz.export.version <= 3, "zip: no side files in a zip, whatever is asked")
        SessionsImport.discard(oz.work)
    } else { check(false, "zip: made and opens") }
    var plainJob = job; plainJob.move = false; plainJob.profiles = nil; plainJob.destination = URL(fileURLWithPath: sharedDir + "/plain.dmg"); plainJob.rootName = "plain image"
    if let po = try? SessionsExport.run(plainJob), let op = try? SessionsImport.open(po.file, password: pw, place: bplace) {
        check(po.side == nil && op.export.side == nil, "an image that isn't a move: no side files")
        SessionsImport.discard(op.work)
    } else { check(false, "plain image: made and opens") }

    // ---- side.json read back untrusted
    func manifest(_ s: [[String: Any]], trust: [[String: Any]] = [], dir: String = "p1") -> Data {
        // (every field the format has, so only what each case changes is odd)
        let sd: [String: Any] = ["tasks": [Any](), "pastes": [Any](), "rewind": [Any](), "historyLines": 0, "rewindFiles": 0, "rewindBytes": 0]
        let td: [String: Any] = ["trusted": false, "allowedTools": [String](), "mcpServers": [String]()]
        let ss = s.map { sd.merging($0) { _, b in b } }, ts = trust.map { td.merging($0) { _, b in b } }
        return try! JSONSerialization.data(withJSONObject: ["version": 1, "parts": [["dir": dir, "sessions": ss, "trust": ts, "leftOut": [String](), "hits": [Any]()]]])
    }
    let sha0 = String(repeating: "a", count: 64)
    func item(_ name: String, _ file: String, bytes: Int = 4) -> [String: Any] { ["name": name, "file": file, "bytes": bytes, "sha": sha0] }
    let hostile = SideFiles.read(manifest([
        ["id": S2, "cwd": old, "plan": item("../../etc/passwd", "side/p1/1"), "tasks": [item("../x.json", "side/p1/2"), item("1.json", "side/p1/3")],
         "pastes": [item("../../x", "side/p1/4"), item("ABCDEF", "side/p1/5")], "rewind": [item("x@v1", "side/p1/6"), item(fh1, "side/p1/7", bytes: 1 << 40)], "historyLines": 99999],
        ["id": "../../evil", "cwd": old], ["id": S1, "cwd": "relative/path"], ["id": S9, "cwd": old, "tasks": [item("1.json", "../outside")]]],
        trust: [["session": S2, "key": "/", "trusted": true], ["session": S9, "key": old, "trusted": true, "allowedTools": ["Bash\u{7}"], "mcp": "{\"other\":1}"], ["session": sid(555), "key": old]]),
        parts: ["p1"])
    let hp = hostile?.parts.first
    check(hp?.sessions.map(\.id) == [S2, S9] && hp?.sessions[0].plan == nil && hp?.sessions[0].tasks.map(\.name) == ["1.json"] && hp?.sessions[0].pastes.isEmpty == true
          && hp?.sessions[0].rewind.isEmpty == true && hp?.sessions[0].historyLines == SideFiles.maxHistoryLines && hp?.sessions[1].tasks.isEmpty == true,
          "hostile side.json: a traversal in a slug, a task name, a paste hash and a session id, a bad hash, a backup over its cap, a relative cwd, a file outside side/: dropped")
    check(hp?.trust.count == 1 && hp?.trust[0].session == S9 && hp?.trust[0].allowedTools.isEmpty == true && hp?.trust[0].mcp == nil && hp?.leftOut.last?.contains("didn't look like Claude Code's") == true,
          "hostile side.json: trust for '/', for a session it doesn't carry and odd MCP fields dropped, a control character in a tool cleaned; said: \(hp?.leftOut ?? [])")
    check(SideFiles.read(Data("[]".utf8), parts: ["p1"]) == nil && SideFiles.read(Data(repeating: 0x20, count: SideFiles.maxManifest + 1), parts: ["p1"]) == nil
          && SideFiles.read(manifest([], dir: "p9"), parts: ["p1"])?.parts.isEmpty == true, "hostile side.json: not one, over 8 MB, a part the file doesn't have")
    // a history line naming another session, in a session's own lines: dropped on import
    let mixed = Data((hline("mine", old, S2, ts: 1) + "\n" + hline("not mine", old, S9, ts: 2) + "\n" + "[1]\n" + #"{"sessionId":"\#(S2)"}"# + "\n").utf8)
    let hl = SideFiles.historyLines(mixed, session: S2, project: { _ in new })
    check(hl.lines.count == 1 && hl.dropped == 3 && String(decoding: hl.lines[0], as: UTF8.self) == hline("mine", new, S2, ts: 1), "hostile history: a line of another session, one that isn't an object and one without its text are dropped")
    // a crafted Rewind mode (M1): bounded, never converted as it is (that trapped)
    check(SideFiles.cleanMode(70000) == 0o600 && SideFiles.cleanMode(-1) == 0o600 && SideFiles.cleanMode(Int.max) == 0o600 && SideFiles.cleanMode(0o644) == 0o644 && SideFiles.cleanMode(0o4755) == 0o755,
          "hostile mode: 70000, -1 and Int.max become 0600; setuid dropped")
    let modes = SideFiles.read(manifest([["id": S2, "cwd": old, "rewind": [["name": fh1, "file": "side/p1/1", "bytes": 4, "sha": sha0, "mode": 70000],
                                                                        ["name": fh2, "file": "side/p1/2", "bytes": 4, "sha": sha0, "mode": -5]]]]), parts: ["p1"])
    check(modes?.parts.first?.sessions.first?.rewind.map(\.mode) == [0o600, 0o600], "hostile side.json: a Rewind mode out of range is read as 0600")
    // a number JSON can't hold (M2): -1e999 is read as -inf, which the serializer would abort on; 1e999 doesn't read at all
    let inf = home + "/inf"
    write(inf + "/projects/-x/\(S2).jsonl", s2Lines(old)[0] + "\n")
    let ref = [SideFiles.SessionRef(id: S2, cwd: old, transcript: inf + "/projects/-x/\(S2).jsonl")]
    write(inf + "/.claude.json", #"{"projects": {"\#(old)": {"hasTrustDialogAccepted": true, "allowedTools": ["Edit"], "mcpServers": {"db": {"timeout": -1e999}}}}}"#)
    let gi = SideFiles.gather(codeDir: inf, sessions: ref, kinds: .movePreset, keys: .leaveOut, dir: "p1", out: nil)!
    check(gi.part.trust.count == 1 && gi.part.trust[0].trusted && gi.part.trust[0].mcp == nil, "-1e999 in .claude.json's MCP servers (Export): the folder's trust carried, its MCP servers left out, no abort")
    write(inf + "/.claude.json", #"{"projects": {"\#(old)": {"hasTrustDialogAccepted": true, "mcpServers": {"db": {"timeout": 1e999}}}}}"#)
    let gi2 = SideFiles.gather(codeDir: inf, sessions: ref, kinds: .movePreset, keys: .leaveOut, dir: "p1", out: nil)!
    check(gi2.part.trust.isEmpty && gi2.preview.configNote != nil, "1e999 in .claude.json (Export): the file isn't read, said: \(gi2.preview.configNote ?? "")")
    let infSide = SideFiles.read(manifest([["id": S2, "cwd": old]], trust: [["session": S2, "key": old, "trusted": true, "mcp": #"{"mcpServers":{"a":{"x":-1e999}}}"#]]), parts: ["p1"])
    check(infSide?.parts.first?.trust.first?.mcp == nil, "-1e999 in side.json's MCP servers (Import): dropped when read")
    var crafted = SideFiles.Trust(session: S2, key: old, trusted: true)
    crafted.mcp = #"{"mcpServers":{"a":{"x":-1e999}}}"#
    check(SideFiles.entryJSON(crafted, mcp: true) == nil, "-1e999 reaching the writer with MCP on: refused, no abort")
    if case .refused(let why) = SideFiles.trustEntry(crafted, (old, old), mcp: true, label: "“x”") { check(why.contains("can't be written"), "…and said: \(why)") } else { check(false, "-1e999: the entry is refused with a line") }
    // whether a process is Claude Code for a folder (the process list itself is never read here)
    let want = FolderKey.canonical(cc), std = FolderKey.canonical(home + "/.claude")
    check(SideFiles.judge(name: "claude", exe: nil, args: [], configDir: nil, want: want, std: std) == nil
          && SideFiles.judge(name: "zsh", exe: nil, args: [], configDir: nil, want: want, std: std) == false,
          "process: one that looks like Claude Code but can't be read is unknown (counted as running); another isn't")
    check(SideFiles.judge(name: "Claude", exe: "/Applications/Claude.app/Contents/MacOS/Claude", args: [], configDir: nil, want: std, std: std) == false
          && SideFiles.judge(name: "claude", exe: home + "/Library/Application Support/Claude/claude-code/2.1.318/claude.app/Contents/MacOS/claude", args: ["claude"], configDir: cc, want: want, std: std) == true
          && SideFiles.judge(name: "2.1.318", exe: home + "/.local/share/claude/versions/2.1.318", args: ["2.1.318"], configDir: nil, want: std, std: std) == true
          && SideFiles.judge(name: "claude", exe: "/opt/homebrew/bin/claude", args: ["claude"], configDir: "/elsewhere", want: want, std: std) == false,
          "process: the Claude app itself isn't Claude Code; its own Claude Code run from a terminal is; a versions/ launch is; another folder's isn't")
    check(SideFiles.judge(name: "Claude", exe: "/Applications/Claude-Work.app/Contents/MacOS/Claude", args: [], configDir: nil, want: std, std: std) == false,
          "process: a profile's own window copy (Claude-Work.app) isn't Claude Code")

    // ---- round 2: retire keeps a session waiting with trust only; a doctored receipt's ".." removes nothing; the history lock's budget
    let place = BackupPrefs.placeURL
    let restoreID = SessionsRestore.receiptID(Date(), "studio")
    let sideID = SessionsRestore.receiptID(Date().addingTimeInterval(1), "studio") + "-side"
    var trustOnly = SideFiles.Receipt(id: sideID, profile: "studio", codeDir: cc, dataDir: wd, restore: restoreID, started: Date(), kinds: .movePreset)
    trustOnly.waiting = [SideFiles.Waiting(session: S2, title: nil, from: old, history: nil, historyLines: 0, trust: [SideFiles.Trust(session: S2, key: old, trusted: true)], why: "its folder isn't on this Mac yet")]
    try! SideFiles.save(trustOnly)
    SideFiles.retire(restore: restoreID, backup: SessionsRestore.Backup(profile: "studio", id: m.id, place: place))
    check(SideFiles.load(sideID)?.waiting.first?.trust.count == 1, "retire: a session waiting with trust only keeps its receipt and trust")
    let outside = place.deletingLastPathComponent().appendingPathComponent(m.id).appendingPathComponent("side").path
    try! fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
    SideFiles.retire(restore: restoreID, backup: SessionsRestore.Backup(profile: "..", id: m.id, place: place))
    SideFiles.retire(restore: restoreID, backup: SessionsRestore.Backup(profile: "studio", id: "../../x", place: place))
    SideFiles.retire(restore: "../" + restoreID, backup: SessionsRestore.Backup(profile: "studio", id: m.id, place: place))
    check(fm.fileExists(atPath: outside) && SideFiles.load(sideID) != nil, "retire: a doctored receipt (\"..\" in its profile, backup id or own id) removes nothing")
    try? fm.removeItem(atPath: (outside as NSString).deletingLastPathComponent)
    let hfile = home + "/hist-budget/history.jsonl"
    write(hfile, hline("one", old, S2, ts: 1) + "\n")
    SideFiles.lockBudget = -1
    let budgetErr: String = { do { try SideFiles.appendHistory(hfile, lines: [Data(hline("two", old, S2, ts: 2).utf8)]); return "appended" } catch { return "\(error)" } }()
    SideFiles.lockBudget = 4
    check(budgetErr.contains("took too long") && read(hfile) == hline("one", old, S2, ts: 1) + "\n" && !fm.fileExists(atPath: hfile + ".lock"),
          "history: past Claude Code's lock budget nothing is written, said, the lock let go: \(budgetErr)")
    var bigHist = Data(count: Int(SideFiles.maxHistoryCheck) + 10)
    bigHist[bigHist.count - 1] = 0x0A
    try! bigHist.write(to: URL(fileURLWithPath: hfile))
    let bigErr: String = { do { try SideFiles.appendHistory(hfile, lines: [Data(hline("two", old, S2, ts: 2).utf8)]); return "appended" } catch { return "\(error)" } }()
    check(bigErr.contains("can't be checked quickly") && (try? Data(contentsOf: URL(fileURLWithPath: hfile)).count) == bigHist.count, "history: over 64 MB it isn't checked under the lock, nothing is added, said")
    try? fm.removeItem(atPath: home + "/hist-budget")
    // .claude.json splicing on its own
    check(SideFiles.spliced(Array("{}".utf8), key: "/a", value: "{\"x\":1}") == .added(Data(#"{"projects": {"/a": {"x":1}}}"#.utf8)), "splice: a file with no projects gets one")
    check(SideFiles.spliced(Array(#"{"projects":{"/a":{}}}"#.utf8), key: "/a", value: "{}") == .there, "splice: a key that is there is never replaced")
    if case .unreadable = SideFiles.spliced(Array(#"{"projects":{},"projects":{}}"#.utf8), key: "/a", value: "{}") { check(true, "") } else { check(false, "splice: projects named twice is refused") }
    if case .unreadable = SideFiles.spliced(Array("not json".utf8), key: "/a", value: "{}") { check(true, "") } else { check(false, "splice: a file that isn't JSON is refused") }

    // ---- doctored images: refused
    func doctored(_ name: String, edit: (URL, inout ExportManifest) throws -> Void) -> String {
        let dir = home + "/doctor-\(name)"
        try? fm.removeItem(atPath: dir); try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Tool.run("/usr/bin/ditto", [o.tree.path, dir + "/" + o.tree.lastPathComponent])
        let root = URL(fileURLWithPath: dir + "/" + o.tree.lastPathComponent)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let encd = JSONEncoder(); encd.dateEncodingStrategy = .iso8601; encd.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var ex = try dec.decode(ExportManifest.self, from: Data(contentsOf: root.appendingPathComponent("export.json")))
            try edit(root, &ex)
            try encd.encode(ex).write(to: root.appendingPathComponent("export.json"))
        } catch { return "doctoring failed: \(error)" }
        let file = URL(fileURLWithPath: home + "/\(name).dmg")
        try? fm.removeItem(at: file)
        let r = Tool.run("/usr/bin/hdiutil", ["create", "-srcfolder", dir, "-volname", "side-\(name)-\(getpid())", "-fs", "APFS", "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-quiet", file.path], stdin: Data(pw.utf8), secret: pw)
        guard r?.status == 0 else { return "file not made: \(r?.err ?? "")" }
        do { let x = try SessionsImport.open(file, password: pw, place: bplace); SessionsImport.discard(x.work); return "OPENED" } catch { return "\(error)" }
    }
    /// side.json rewritten (its hash in export.json too)
    func setSide(_ root: URL, _ ex: inout ExportManifest, _ change: (inout [String: Any]) -> Void) throws {
        let url = root.appendingPathComponent("side.json")
        var j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        change(&j)
        let d = try JSONSerialization.data(withJSONObject: j)
        try d.write(to: url)
        ex.side = ExportManifest.AppFile(path: "side.json", bytes: Int64(d.count), sha: SwitchEngine.sha(d))
    }
    let untouched = doctored("ok") { _, _ in }
    check(untouched == "OPENED", "(an untouched copy opens): \(untouched.prefix(160))")
    let notOne = doctored("side-not-json") { root, ex in try Data("[]".utf8).write(to: root.appendingPathComponent("side.json")); ex.side?.bytes = 2; ex.side?.sha = SwitchEngine.sha(Data("[]".utf8)) }
    check(notOne.contains("side.json") && notOne.contains("refused"), "hostile image: side.json that isn't one refuses the file: \(notOne.prefix(100))")
    let traversal = doctored("side-slug") { root, ex in
        try setSide(root, &ex) { j in
            var parts = j["parts"] as! [[String: Any]]; var ss = parts[0]["sessions"] as! [[String: Any]]
            for i in ss.indices { if var p = ss[i]["plan"] as? [String: Any] { p["name"] = "../../../.ssh/config"; ss[i]["plan"] = p } }
            parts[0]["sessions"] = ss; j["parts"] = parts
        }
    }
    check(traversal != "OPENED" && traversal.contains("refused"), "hostile image: a traversal in a plan's slug refuses the file (its file then belongs to nothing): \(traversal.prefix(100))")
    let changed = doctored("side-bytes") { root, _ in
        let f = files(root.path + "/side/p1").first!
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: root.path + "/side/p1/" + f))
    }
    check(changed.contains("isn't what side.json says"), "hostile image: a side file that isn't what side.json says refuses the file: \(changed.prefix(100))")
    let extra = doctored("side-extra") { root, _ in try Data("x".utf8).write(to: root.appendingPathComponent("side/p1/999")) }
    check(extra.contains("don't name"), "hostile image: a file under side/ that side.json doesn't name refuses the file: \(extra.prefix(100))")
    let notMove = doctored("side-not-move") { _, ex in ex.move = nil }
    check(notMove.contains("outside a move") || notMove.contains("don't agree"), "hostile image: side files in a file that isn't a move: refused: \(notMove.prefix(100))")
    let v5 = doctored("side-v5") { _, ex in ex.version = 5 }
    check(v5.contains("older than the one they came with"), "format: side files in a version-5 file are refused: \(v5.prefix(100))")
    let sizes = doctored("side-sizes") { _, ex in ex.sideBytes = (ex.sideBytes ?? 0) + 1 }
    check(sizes.contains("don't add up") || sizes.contains("refused"), "hostile image: side files' stated size that doesn't add up: refused: \(sizes.prefix(100))")
    let huge = doctored("side-huge") { _, ex in ex.sideBytes = 1 << 62 }
    check(huge.contains("can't be right"), "hostile image: a huge stated size: refused: \(huge.prefix(100))")
    let v7 = doctored("v7") { _, ex in ex.version = 7 }
    check(v7.contains("newer cl_audit"), "format: version 7 is refused with the newer-cl_audit words")
    SessionsImport.discard(o.work)

    // ---- the new Mac: role B, in its own fresh home. old/garden-app is "cloned" to new/garden-app there
    try? fm.removeItem(atPath: code + "/old")
    let bHome = work + "/b/home"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.environment = ["HOME": bHome, "CFFIXED_USER_HOME": bHome, "SIDE_ROLE": "b", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory()]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    if bHome.hasSuffix("/Checks/.work/sidefiles/b/home"), fm.fileExists(atPath: bHome), (try? p.run()) != nil {
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
