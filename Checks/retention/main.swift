// Retention checks for cl_audit: which transcripts Claude Code's own clean-up deletes (Sources/Retention.swift), what a
// restore or the default-profile move says about them, and the words. The rule is Claude Code's (2.1.248 and later, read from
// the installed 2.1.318): a session of the Claude window or Cowork is kept at any age, told by the transcript's own
// `entrypoint`, with the release markers, the hard cap desktopSessionCleanupPeriodDays and the organisation's managed settings.
// Runs only with CFFIXED_USER_HOME = .../Checks/.work/retention/home (Checks/run.sh sets and guards it). Fake data only:
// example.invalid addresses, zero uuids, sample names. Nothing here opens an app, the Dock or Terminal; the managed-settings
// sources are pointed at folders inside the throwaway home, so nothing under /Library is read or written.

import AppKit
import Foundation

var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}

let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/retention/home") else { print("refusing: HOME is \(home)"); exit(2) }
let fm = FileManager.default
func p(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }

// the organisation's sources: only inside the throwaway home
ManagedSettings.fileDir = p("managed/ClaudeCode")
ManagedSettings.mdmDir = p("managed/Managed Preferences")
ManagedSettings.mdmUser = "sample"
ManagedSettings.useServerCache = true

let now = Date()
let day = 86400.0
func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012x", n) }

func resetHome() {
    for n in (try? fm.contentsOfDirectory(atPath: home)) ?? [] { try? fm.removeItem(atPath: p(n)) }
    try? fm.createDirectory(atPath: p("Library/Application Support"), withIntermediateDirectories: true)
}
func put(_ rel: String, _ text: String, age: Double? = nil) {
    let path = p(rel)
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? text.write(toFile: path, atomically: true, encoding: .utf8)
    if let age { setAge(path, age) }
}
func setAge(_ path: String, _ days: Double) { try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-days * day)], ofItemAtPath: path) }

/// One transcript line: the entrypoint (nil: none) and a sample message.
func line(_ entry: String?, _ session: Int = 1, text: String = "sample message") -> String {
    let e = entry.map { "\"entrypoint\":\"\($0)\"," } ?? ""
    return "{\"type\":\"user\",\(e)\"sessionId\":\"\(uuid(session))\",\"message\":\"\(text)\"}\n"
}
/// A transcript in a project folder of a profile's Claude Code folder; returns its path.
@discardableResult
func transcript(_ code: String, _ id: Int, _ body: String, age: Double, project: String = "-sample") -> String {
    let rel = "\(code)/projects/\(project)/\(uuid(id)).jsonl"
    put(rel, body, age: age)
    return p(rel)
}
func marker(_ code: String, _ id: Int, _ body: String, age: Double, project: String = "-sample") {
    put("\(code)/projects/\(project)/\(uuid(id)).desktop-released.json", body, age: age)
}
func fate(_ path: String, _ r: Retention) -> Retention.Verdict? {
    Retention.Transcript.read(path: path).map { r.verdict($0, now: now) }
}
func settings(_ code: String, _ json: String) { put("\(code)/settings.json", json) }

let base = Retention(days: 30)                       // cleanupPeriodDays: 30, nothing else set

// ============ 1. the rule by the transcript's own entrypoint ============
do {
    resetHome()
    let c = ".claude-a"
    let term = line("cli"), win = line("claude-desktop")
    check(fate(transcript(c, 1, term + term, age: 40), base) == .delete, "a terminal session older than 30 days is deleted")
    check(fate(transcript(c, 2, term + term, age: 10), base) == .keep, "a terminal session of 10 days is kept")
    check(fate(transcript(c, 3, win + win, age: 400), base) == .keep, "a window session is kept at any age (400 days)")
    // started in the terminal, continued in the window, continued in the terminal again: it is a terminal session now
    check(fate(transcript(c, 4, term + win + term, age: 400), base) == .delete, "terminal, then window, then terminal: deleted (the last entrypoint is the terminal's)")
    check(fate(transcript(c, 5, win + term + term, age: 400), base) == .keep, "started in the window, continued in the terminal: kept (the first is the window's)")
    check(fate(transcript(c, 6, term + term + win, age: 400), base) == .keep, "continued last in the window: kept (the last is the window's)")
    check(fate(transcript(c, 7, line(nil) + line(nil), age: 400), base) == .delete, "no entrypoint at all: a terminal session, deleted")
    // Cowork and the other spellings; a different program is not the window
    for (i, e) in ["local-agent", "local_agent", "claude-desktop-3p", "claude-desktop"].enumerated() {
        check(fate(transcript(c, 10 + i, line(e), age: 400), base) == .keep, "entrypoint \(e): kept")
    }
    for (i, e) in ["claude-vscode", "sdk-cli", "Claude-Desktop", "claude-desktop ", "desktop", "cli"].enumerated() {
        check(fate(transcript(c, 20 + i, line(e) + line(e), age: 400), base) == .delete, "entrypoint '\(e)': not the window's, deleted")
    }
    // a desktop first line with no later lines (a one-line file) is kept
    check(fate(transcript(c, 30, win.trimmingCharacters(in: .newlines), age: 400), base) == .keep, "a desktop first line and nothing after it (no newline): kept")
    // lines without the key, or with it not as a string, are passed over
    let odd = "{\"entrypoint\":5}\n{\"entrypoint\":null}\nnot json \"entrypoint\":\"claude-desktop\"\n"
    check(fate(transcript(c, 31, odd, age: 400), base) == .delete, "an entrypoint that isn't a string, or in a line that isn't JSON: ignored")
    check(fate(transcript(c, 32, odd + win, age: 400), base) == .keep, "…and the next real line counts")
    // the Code tab's entries are not looked at: a window entry naming a terminal session changes nothing
    put("Library/Application Support/Claude/claude-code-sessions/\(uuid(90))/\(uuid(91))/local_\(uuid(33)).json",
        "{\"sessionId\":\"local_\(uuid(33))\",\"cliSessionId\":\"\(uuid(33))\"}")
    check(fate(transcript(c, 33, term + term, age: 400), base) == .delete, "a Code-tab entry naming the session does not make it the window's")
}

// ============ 2. a transcript larger than the 64 KB windows ============
do {
    resetHome()
    let c = ".claude-b"
    let term = line("cli"), win = line("claude-desktop")
    let filler = String(repeating: line(nil, text: String(repeating: "x", count: 900)), count: 80)       // ~ 75 KB
    check(filler.utf8.count > 65536, "the filler is larger than the 64 KB window (\(filler.utf8.count) bytes)")
    check(fate(transcript(c, 1, term + filler + win, age: 400), base) == .keep, "a big file: the window's entrypoint in the last 64 KB counts")
    check(fate(transcript(c, 2, win + filler + term, age: 400), base) == .keep, "a big file: the window's entrypoint in the first line counts")
    check(fate(transcript(c, 3, term + filler + win + filler + term, age: 400), base) == .delete,
          "a big file: a window line in the middle, past both 64 KB windows, doesn't count: deleted")
    check(fate(transcript(c, 4, term + win + filler + term, age: 400), base) == .delete, "the first entrypoint in the head is the terminal's: the window line after it is not the first")
    // the tail starts in the middle of a line: that cut line is dropped, never read as if whole
    let longWin = "{\"entrypoint\":\"claude-desktop\",\"pad\":\"\(String(repeating: "y", count: 70000))\"}\n"
    check(fate(transcript(c, 5, term + longWin + term, age: 400), base) == .delete, "a long line cut by the tail's start: the cut part is not read (the last whole line is the terminal's)")
    // a big file with nothing readable as a start (a long first line that has no entrypoint) and a desktop last line
    check(fate(transcript(c, 6, "{\"pad\":\"\(String(repeating: "z", count: 90000))\"}\n" + win, age: 400), base) == .keep, "a first line longer than 64 KB with no entrypoint: the tail's last line decides")
    // a 3 MB file is read in two small pieces, never whole
    let big = String(repeating: "a", count: 3_000_000)
    check(fate(transcript(c, 7, line("cli") + big + "\n" + line("claude-desktop"), age: 400), base) == .keep, "a 3 MB transcript: decided by its two ends")
}

// ============ 3. empty and unreadable files, folders beside a transcript ============
do {
    resetHome()
    let c = ".claude-c"
    let e = transcript(c, 1, "", age: 400)
    check(fate(e, base) == .keep, "an empty transcript with no folder beside it is kept")
    try? fm.createDirectory(atPath: p("\(c)/projects/-sample/\(uuid(2))"), withIntermediateDirectories: true)
    check(fate(transcript(c, 2, "", age: 400), base) == .delete, "an empty transcript with a folder of its name beside it is not set aside: deleted")
    let u = transcript(c, 3, line("claude-desktop"), age: 400)
    try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: u)
    check(fate(u, base) == nil, "an unreadable transcript isn't classified (left out of the counts, nothing is read)")
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u)
    // a link is never followed
    try? fm.createSymbolicLink(atPath: p("\(c)/projects/-sample/\(uuid(4)).jsonl"), withDestinationPath: u)
    check(fate(p("\(c)/projects/-sample/\(uuid(4)).jsonl"), base) == nil, "a transcript that is a link isn't read")
}

// ============ 4. release markers ============
do {
    resetHome()
    let c = ".claude-d"
    let win = line("claude-desktop"), term = line("cli")
    transcript(c, 1, win, age: 400); marker(c, 1, "{\"reason\":\"delete\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/\(uuid(1)).jsonl"), base) == .delete, "a window session with a delete marker: deleted at once")
    transcript(c, 2, win, age: 400); marker(c, 2, "{\"reason\":\"archive\"}", age: 5)
    check(fate(p("\(c)/projects/-sample/\(uuid(2)).jsonl"), base) == .keep, "an archive marker made 5 days ago: the grace, kept")
    transcript(c, 3, win, age: 400); marker(c, 3, "{\"reason\":\"archive\"}", age: 40)
    check(fate(p("\(c)/projects/-sample/\(uuid(3)).jsonl"), base) == .delete, "an archive marker older than 30 days: the grace is over, deleted")
    transcript(c, 4, term, age: 400); marker(c, 4, "{\"reason\":\"archive\"}", age: 5)
    check(fate(p("\(c)/projects/-sample/\(uuid(4)).jsonl"), base) == .keep, "the grace keeps a session whatever its entrypoint says")
    transcript(c, 5, win, age: 400); marker(c, 5, "{\"reason\":\"something else\"}", age: 400)
    check(fate(p("\(c)/projects/-sample/\(uuid(5)).jsonl"), base) == .keep, "an unknown reason: no effect, the window's session is kept")
    transcript(c, 6, win, age: 400); marker(c, 6, "{}", age: 400)
    check(fate(p("\(c)/projects/-sample/\(uuid(6)).jsonl"), base) == .keep, "a marker with no reason: no effect")
    transcript(c, 7, win, age: 400); marker(c, 7, "not json at all", age: 400)
    check(fate(p("\(c)/projects/-sample/\(uuid(7)).jsonl"), base) == .keep, "a marker that isn't JSON: no effect")
    transcript(c, 8, win, age: 400); marker(c, 8, "[\"delete\"]", age: 400)
    check(fate(p("\(c)/projects/-sample/\(uuid(8)).jsonl"), base) == .keep, "a marker that is an array, not an object: no effect")
    transcript(c, 9, win, age: 400); marker(c, 9, "{\"reason\":5}", age: 400)
    check(fate(p("\(c)/projects/-sample/\(uuid(9)).jsonl"), base) == .keep, "a reason that isn't a string: no effect")
    // a marker over 4096 bytes is not read
    transcript(c, 10, win, age: 400)
    marker(c, 10, "{\"reason\":\"delete\",\"pad\":\"\(String(repeating: "p", count: 5000))\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/\(uuid(10)).jsonl"), base) == .keep, "a marker larger than 4096 bytes is not read: no effect")
    // a huge marker (3 MB) likewise, without reading it
    transcript(c, 11, win, age: 400)
    marker(c, 11, "{\"reason\":\"delete\",\"pad\":\"\(String(repeating: "p", count: 3_000_000))\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/\(uuid(11)).jsonl"), base) == .keep, "a 3 MB marker: not read, no effect")
    // exactly 4096 bytes is read
    let body = "{\"reason\":\"delete\",\"pad\":\""
    let pad = String(repeating: "q", count: 4096 - body.utf8.count - 2) + "\"}"
    transcript(c, 12, win, age: 400); marker(c, 12, body + pad, age: 1)
    check((body + pad).utf8.count == 4096, "the marker is exactly 4096 bytes")
    check(fate(p("\(c)/projects/-sample/\(uuid(12)).jsonl"), base) == .delete, "a marker of exactly 4096 bytes is read: delete")
    // a marker that is a link, or a folder, is not followed
    transcript(c, 13, win, age: 400)
    put("elsewhere.json", "{\"reason\":\"delete\"}")
    try? fm.createSymbolicLink(atPath: p("\(c)/projects/-sample/\(uuid(13)).desktop-released.json"), withDestinationPath: p("elsewhere.json"))
    check(fate(p("\(c)/projects/-sample/\(uuid(13)).jsonl"), base) == .keep, "a marker that is a link is not followed: no effect")
    transcript(c, 14, win, age: 400)
    try? fm.createDirectory(atPath: p("\(c)/projects/-sample/\(uuid(14)).desktop-released.json"), withIntermediateDirectories: true)
    check(fate(p("\(c)/projects/-sample/\(uuid(14)).jsonl"), base) == .keep, "a marker that is a folder: no effect")
    // a marker doesn't matter until the transcript is a candidate
    transcript(c, 15, win, age: 5); marker(c, 15, "{\"reason\":\"delete\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/\(uuid(15)).jsonl"), base) == .keep, "a delete marker, but the transcript is 5 days old: not a candidate yet")
    // sub-agent files take the marker of the session they name
    put("\(c)/projects/-sample/agent-sample1.jsonl", "{\"entrypoint\":\"claude-desktop\",\"sessionId\":\"\(uuid(20))\"}\n", age: 400)
    check(fate(p("\(c)/projects/-sample/agent-sample1.jsonl"), base) == .keep, "an agent-*.jsonl of a window session: kept")
    marker(c, 20, "{\"reason\":\"delete\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/agent-sample1.jsonl"), base) == .delete, "…and deleted when the session it names was released")
    put("\(c)/projects/-sample/agent-sample2.jsonl", "{\"entrypoint\":\"claude-desktop\",\"sessionId\":\"../x\"}\n", age: 400)
    marker(c, 20, "{\"reason\":\"delete\"}", age: 1)
    check(fate(p("\(c)/projects/-sample/agent-sample2.jsonl"), base) == .keep, "a session id that isn't a plain name is not followed")
}

// ============ 5. the hard cap: desktopSessionCleanupPeriodDays ============
do {
    resetHome()
    let c = ".claude-e"
    let win = line("claude-desktop")
    func with(_ json: String) -> Retention { settings(c, json); return Retention.read(codeDir: p(c)) }
    var r = with("{}")
    check(r.days == 30 && r.desktopDays == nil && !r.managed && !r.managedError && r.skipped == nil, "nothing set: 30 days, no cap")
    r = with("{\"desktopSessionCleanupPeriodDays\":90}")
    check(r.desktopDays == 90, "the user's desktopSessionCleanupPeriodDays is read")
    check(fate(transcript(c, 1, win, age: 60), r) == .keep && fate(transcript(c, 2, win, age: 100), r) == .delete,
          "cap 90: a window session of 60 days is kept, of 100 days deleted")
    r = with("{\"cleanupPeriodDays\":120,\"desktopSessionCleanupPeriodDays\":90}")
    check(fate(transcript(c, 3, win, age: 100), r) == .keep && fate(transcript(c, 4, win, age: 130), r) == .delete,
          "cleanupPeriodDays 120 and cap 90: the longer applies (100 days kept, 130 deleted)")
    r = with("{\"desktopSessionCleanupPeriodDays\":10}")
    check(fate(transcript(c, 5, win, age: 35), r) == .delete && fate(transcript(c, 6, win, age: 25), r) == .keep,
          "a cap below cleanupPeriodDays has no effect on its own: the window's session goes after the 30 days")
    r = with("{\"desktopSessionCleanupPeriodDays\":0}")
    check(r.desktopDays == nil && fate(transcript(c, 7, win, age: 4000), r) == .keep, "0 is no cap")
    // the cap bounds the grace of an archive marker too
    r = with("{\"cleanupPeriodDays\":30,\"desktopSessionCleanupPeriodDays\":60}")
    transcript(c, 8, win, age: 100); marker(c, 8, "{\"reason\":\"archive\"}", age: 5)
    check(fate(p("\(c)/projects/-sample/\(uuid(8)).jsonl"), r) == .delete, "the cap is a hard cap: an archive grace doesn't keep a transcript past it")
    // wrong kinds of value in the user's OWN settings.json: not an exemption-ending error but a skipped clean-up (Claude Code
    // 2.1.318 doesn't clean up while a settings error and an explicitly set key meet). A skip never hides a risk: it is a note,
    // and the counts are as if the clean-up ran, with the invalid key taken as not set (no cap)
    for bad in ["\"90\"", "-1", "1.5", "true", "null", "9007199254740992", "1e300"] {
        r = with("{\"desktopSessionCleanupPeriodDays\":\(bad)}")
        check(r.skipped == .key("desktopSessionCleanupPeriodDays") && r.desktopDays == nil && !r.managedError && r.exempts && r.days == 30, "desktopSessionCleanupPeriodDays \(bad): Claude Code skips its clean-up (a note); counted with 30 days, no cap")
        check(fate(transcript(c, 70, win, age: 400), r) == .keep && fate(transcript(c, 71, line("cli"), age: 400), r) == .delete, "…a terminal session of 400 days is still counted as deleted, the window's kept (\(bad))")
    }
    check(r.keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use; ones from the Claude window it keeps (Claude Code 2.1.248 and later). Claude Code 2.1.318 skips its clean-up while desktopSessionCleanupPeriodDays in settings.json isn't a valid number; fix it and these would be deleted.", "Kept here: the rule, then the skip as a note: \(r.keptHereWords)")
    check(!r.keptHereWords.contains("doesn't delete any session"), "never 'doesn't delete any session'")
    check(r.keepForNote == nil && r.menuDays == 30, "Keep for: the menu shows 30 (cleanupPeriodDays is fine), no extra note")
    // huge numbers are valid to Claude Code (zod int(): any safe integer): no skip
    for big in ["1000000000", "9007199254740991", "9007199254740991.0"] {
        r = with("{\"desktopSessionCleanupPeriodDays\":\(big)}")
        let expected = big == "1000000000" ? 1_000_000_000 : 9007199254740991
        check(r.skipped == nil && r.desktopDays == expected && !r.keptHereWords.contains("skips"),
              "desktopSessionCleanupPeriodDays \(big): valid, no skip (cap \(r.desktopDays.map(String.init) ?? "none"))")
        check(fate(transcript(c, 71, line("cli"), age: 400), r) == .delete && fate(transcript(c, 70, win, age: 400), r) == .keep, "…terminal sessions are deleted after 30 days, window ones kept (\(big))")
    }
    r = with("{\"cleanupPeriodDays\":1000000000}")
    check(r.skipped == nil && r.days == 1_000_000_000 && r.problem == nil && fate(transcript(c, 8, line("cli"), age: 400), r) == .keep, "cleanupPeriodDays 1e9: valid, nothing old enough to delete")
    r = with("{\"cleanupPeriodDays\":9007199254740991}")
    check(r.skipped == nil && r.days == 9007199254740991, "cleanupPeriodDays 2^53-1: valid")
    check(r.keptHereWords.hasPrefix("Claude Code deletes terminal sessions 9007199254740991 days after"), "…and worded without a crash: \(r.keptHereWords)")
    check(CodeCleanup.whole(9007199254740991 as NSNumber) == 9007199254740991 && CodeCleanup.whole(9007199254740992.0 as NSNumber) == nil
          && CodeCleanup.whole(1e9 as NSNumber) == 1_000_000_000 && CodeCleanup.whole(30.0 as NSNumber) == 30, "whole(): up to 2^53-1, integral reals too")
    // 30.0 is a whole number to Claude Code (JSON.parse gives 30)
    r = with("{\"cleanupPeriodDays\":30.0,\"desktopSessionCleanupPeriodDays\":60.0}")
    check(r.days == 30 && r.desktopDays == 60 && r.skipped == nil, "30.0 and 60.0 are whole numbers: days 30, cap 60")
    r = with("{\"cleanupPeriodDays\":1e1}")
    check(r.days == 10 && r.skipped == nil, "1e1 is 10")
    // the days themselves
    r = with("{\"cleanupPeriodDays\":7}")
    check(r.days == 7 && fate(transcript(c, 10, line("cli"), age: 8), r) == .delete && fate(transcript(c, 11, line("cli"), age: 6), r) == .keep, "cleanupPeriodDays 7")
    for bad in ["0", "\"x\"", "2.5", "true", "9007199254740992"] {
        r = with("{\"cleanupPeriodDays\":\(bad)}")
        check(r.days == 30 && r.menuDays == nil && r.problem != nil && r.skipped == .key("cleanupPeriodDays") && fate(transcript(c, 12, line("cli"), age: 400), r) == .delete,
              "cleanupPeriodDays \(bad): skipped as a note; counted as not set (30 days: a 400-day terminal session is deleted), the Keep for menu shows unknown")
    }
    check(r.keptHereWords.hasSuffix("Claude Code 2.1.318 skips its clean-up while cleanupPeriodDays in settings.json isn't a valid number; fix it and these would be deleted."), "…worded: \(r.keptHereWords)")
    settings(c, "{ not json")
    r = Retention.read(codeDir: p(c))
    check(r.days == 30 && r.menuDays == nil && r.skipped == .unreadable && fate(transcript(c, 13, line("cli"), age: 400), r) == .delete, "a settings.json that isn't JSON: skipped as a note, counted with 30 days")
    check(r.keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use; ones from the Claude window it keeps (Claude Code 2.1.248 and later). Claude Code 2.1.318 skips its clean-up while settings.json can't be read; fix it and these would be deleted.", "…worded: \(r.keptHereWords)")
    // a settings.json over 2 MiB: can't be read (bounded), a note, counted with 30 days
    settings(c, "{\"cleanupPeriodDays\":4,\"pad\":\"\(String(repeating: "x", count: 3 * 1024 * 1024))\"}")
    r = Retention.read(codeDir: p(c))
    check(r.skipped == .unreadable && r.days == 30 && fate(transcript(c, 13, line("cli"), age: 400), r) == .delete, "a 3 MiB settings.json: not read whole, a note, counted with 30 days")
    // a settings.json the suite can't open (mode 000): can't be read, a note
    settings(c, "{\"cleanupPeriodDays\":4}")
    try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: p("\(c)/settings.json"))
    r = Retention.read(codeDir: p(c))
    check(r.skipped == .unreadable && r.days == 30, "a settings.json that can't be opened (mode 000): a note, counted with 30 days")
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p("\(c)/settings.json"))
    // a link to nowhere is no file to Claude Code (ENOENT): the defaults, no skip
    try? fm.removeItem(atPath: p("\(c)/settings.json"))
    try? fm.createSymbolicLink(atPath: p("\(c)/settings.json"), withDestinationPath: p("no-such-settings.json"))
    r = Retention.read(codeDir: p(c))
    check(r.skipped == nil && r.days == 30 && r.problem == nil && r.menuDays == 30 && r.desktopDays == nil, "settings.json that is a link to nowhere: no file, the defaults, no skip note")
    check(CodeCleanup.read(codeDir: p(c)).days == 30 && CodeCleanup.read(codeDir: p(c)).problem == nil, "…and Keep for reads 30, no problem")
    // a folder where settings.json should be: not a plain file, said as no file (no skip note)
    try? fm.removeItem(atPath: p("\(c)/settings.json"))
    try? fm.createDirectory(atPath: p("\(c)/settings.json"), withIntermediateDirectories: true)
    r = Retention.read(codeDir: p(c))
    check(r.skipped == nil && r.days == 30 && r.problem == nil, "settings.json that is a folder: no file, no skip note")
    try? fm.removeItem(atPath: p("\(c)/settings.json"))
    // a FIFO where settings.json should be: the read must return at once (O_NONBLOCK, plain files only), no skip note
    check(mkfifo(p("\(c)/settings.json"), 0o600) == 0, "a FIFO made in the throwaway home")
    let fifoDone = DispatchSemaphore(value: 0)
    var fifoRead: Retention?
    DispatchQueue.global().async { fifoRead = Retention.read(codeDir: p(c)); fifoDone.signal() }
    if fifoDone.wait(timeout: .now() + 10) == .timedOut {
        check(false, "settings.json that is a FIFO: the read blocked (10 s)")
        print("checks: \(passed) passed, \(failed) failed"); exit(1)          // the reader thread is stuck: stop here
    }
    check(fifoRead?.skipped == nil && fifoRead?.days == 30 && fifoRead?.problem == nil, "settings.json that is a FIFO: the read returns, no file, no skip note")
    check(fate(transcript(c, 13, line("cli"), age: 400), fifoRead ?? base) == .delete, "…and a 400-day terminal session is counted as deleted")
    try? fm.removeItem(atPath: p("\(c)/settings.json"))
    // a user's settings error with managed cleanupPeriodDays: Claude Code always runs it
    put("managed/ClaudeCode/managed-settings.json", "{\"cleanupPeriodDays\":20}")
    settings(c, "{\"desktopSessionCleanupPeriodDays\":\"x\"}")
    r = Retention.read(codeDir: p(c))
    check(r.skipped == nil && r.managed && fate(transcript(c, 14, win, age: 400), r) == .delete, "with managed cleanupPeriodDays the clean-up runs whatever settings.json holds")
    try? fm.removeItem(atPath: p("managed"))
    // a link to settings.json is followed (it is the user's own file)
    put("real-settings.json", "{\"desktopSessionCleanupPeriodDays\":45}")
    try? fm.removeItem(atPath: p("\(c)/settings.json"))
    try? fm.createSymbolicLink(atPath: p("\(c)/settings.json"), withDestinationPath: p("real-settings.json"))
    check(Retention.read(codeDir: p(c)).desktopDays == 45, "settings.json that is a link: read where it points")
}

// ============ 6. the organisation's managed settings, source by source ============
do {
    resetHome()
    let c = ".claude-f"
    let win = line("claude-desktop")
    let sCache = "\(c)/remote-settings.json"
    let fileA = "managed/ClaudeCode/managed-settings.json"
    func plist(_ user: String?, _ dict: [String: Any]) {
        let path = user.map { p("managed/Managed Preferences/\($0)/com.anthropic.claudecode.plist") } ?? p("managed/Managed Preferences/com.anthropic.claudecode.plist")
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)).write(to: URL(fileURLWithPath: path))
    }
    func clean() { for n in ["managed", c] { try? fm.removeItem(atPath: p(n)) }; try? fm.createDirectory(atPath: p(c), withIntermediateDirectories: true) }
    func r() -> Retention { Retention.read(codeDir: p(c)) }

    clean(); settings(c, "{\"cleanupPeriodDays\":365,\"desktopSessionCleanupPeriodDays\":500}")
    check(ManagedSettings.read(codeDir: p(c)) == nil && !r().managed && r().days == 365, "no managed source: the user's own settings stay")
    // each source alone
    put(sCache, "{\"cleanupPeriodDays\":10}")
    check(r().managed && r().days == 10 && r().source == .server, "server-managed cache (remote-settings.json): 10 days, managed")
    clean(); settings(c, "{\"cleanupPeriodDays\":365}"); plist("sample", ["cleanupPeriodDays": 11])
    check(r().managed && r().days == 11 && r().source == .mdm, "MDM, the user's managed preferences: 11 days")
    clean(); settings(c, "{\"cleanupPeriodDays\":365}"); plist(nil, ["cleanupPeriodDays": 12])
    check(r().days == 12 && r().source == .mdm, "MDM, the device-level managed preferences: 12 days")
    clean(); settings(c, "{\"cleanupPeriodDays\":365}"); plist("sample", ["cleanupPeriodDays": 11]); plist(nil, ["cleanupPeriodDays": 12])
    check(r().days == 11, "MDM: the user's preferences come before the device's")
    clean(); settings(c, "{\"cleanupPeriodDays\":365}"); put(fileA, "{\"cleanupPeriodDays\":13}")
    check(r().days == 13 && r().source == .file, "managed-settings.json: 13 days")
    // drop-ins: alphabetical, a later value replaces an earlier one
    clean(); put(fileA, "{\"cleanupPeriodDays\":3,\"desktopSessionCleanupPeriodDays\":400}")
    put("managed/ClaudeCode/managed-settings.d/20-b.json", "{\"cleanupPeriodDays\":9}")
    put("managed/ClaudeCode/managed-settings.d/10-a.json", "{\"cleanupPeriodDays\":5}")
    check(r().days == 9, "drop-ins: managed-settings.json 3, then 10-a 5, then 20-b 9: the last one, 9")
    put("managed/ClaudeCode/managed-settings.d/.hidden.json", "{\"cleanupPeriodDays\":1}")
    put("managed/ClaudeCode/managed-settings.d/30-c.txt", "{\"cleanupPeriodDays\":2}")
    check(r().days == 9, "a hidden drop-in and one that isn't .json are not read")
    clean(); put("managed/ClaudeCode/managed-settings.d/50-only.json", "{\"cleanupPeriodDays\":14}")
    check(r().days == 14, "drop-ins alone, with no managed-settings.json: read")
    // the order of the sources: the first one that holds anything wins, the rest are ignored
    clean(); settings(c, "{}")
    put(sCache, "{\"cleanupPeriodDays\":10}"); plist("sample", ["cleanupPeriodDays": 11]); put(fileA, "{\"cleanupPeriodDays\":13}")
    check(r().days == 10 && r().source == .server, "all three set: the server's wins")
    try? fm.removeItem(atPath: p(sCache))
    check(r().days == 11 && r().source == .mdm, "without the server's: MDM's wins over the files")
    put(sCache, "{\"model\":\"sample-model\"}")
    check(r().managed && r().days == 11 && r().source == .server, "the server source holds other settings only and wins them; cleanupPeriodDays from MDM (11) and the file (13) still counts: managed, the smallest, 11")
    try? fm.removeItem(atPath: p(sCache))
    plist("sample", ["somethingElse": "x"])
    check(r().managed && r().days == 13 && r().source == .mdm, "MDM holds other keys only and wins them; the file's cleanupPeriodDays (13) still counts")
    try? fm.removeItem(atPath: p("managed/Managed Preferences"))
    check(r().days == 13, "…and with it gone the file's value applies")
    // MUST 1: cleanupPeriodDays in ANY managed source ends the exemption, whichever source wins
    clean(); settings(c, "{}")
    put(sCache, "{\"permissions\":{\"allow\":[]}}"); put(fileA, "{\"cleanupPeriodDays\":30}")
    check(r().managed && r().days == 30 && r().source == .server && !r().exempts, "server {other key} + file {cleanupPeriodDays 30}: managed, 30 days, no exemption")
    check(fate(transcript(c, 40, win, age: 100), r()) == .delete, "…so an old window transcript is deleted")
    check(r().keptHereWords == "Your organisation's managed settings make Claude Code delete sessions 30 days after their last use.", "…and the card says so: \(r().keptHereWords)")
    // the smallest value any source holds, when the winner has none
    clean(); settings(c, "{}")
    plist("sample", ["somethingElse": "x"]); put(fileA, "{\"cleanupPeriodDays\":30}"); put("managed/ClaudeCode/managed-settings.d/10-a.json", "{\"cleanupPeriodDays\":15}")
    check(r().days == 15, "the file source's own composition (the drop-in replaces): 15")
    put(sCache, "{\"cleanupPeriodDays\":20}")
    check(r().days == 20 && r().source == .server, "the winner's own value is used when it has one (20, not the smaller 15)")
    // the cap from any source: the smallest positive, a 0 only when none caps
    clean(); settings(c, "{}")
    put(sCache, "{\"desktopSessionCleanupPeriodDays\":0}"); put(fileA, "{\"desktopSessionCleanupPeriodDays\":90}")
    check(r().desktopDays == 90, "managed caps 0 (server) and 90 (file): the cap 90 applies, a 0 only when no source caps")
    plist("sample", ["desktopSessionCleanupPeriodDays": 60])
    check(r().desktopDays == 60, "caps 0, 60 (MDM) and 90: the smallest, 60")
    put(sCache, "{\"desktopSessionCleanupPeriodDays\":0}"); try? fm.removeItem(atPath: p("managed/Managed Preferences")); try? fm.removeItem(atPath: p(fileA))
    check(r().desktopDays == nil && r().managed == false, "only a managed 0: no cap")
    // MUST 2: a managed document that is there but can't be used is a managed settings ERROR (the exemption ends); only a
    // missing file is "not there". The other sources are still read.
    clean(); settings(c, "{}")
    check(!r().managedError && r().exempts, "nothing managed, nothing wrong: the exemption is on")
    clean(); settings(c, "{}"); try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    check(!r().managedError, "a managed folder with no files in it: not there, no error")
    // a bad managed-settings.json (the user's settings.json holds neither key: Claude Code runs its clean-up, without the exemption)
    func badFile(_ what: String, _ make: () -> Void, at: Int = #line) {
        clean(); settings(c, "{}"); make()
        let rr = r()
        check(rr.managedError && !rr.exempts && rr.skipped == nil, "managed-settings.json \(what): a managed error, no exemption, the clean-up still runs", line: at)
        check(fate(transcript(c, 50, win, age: 400), rr) == .delete, "…so a window transcript of 400 days is deleted (\(what))", line: at)
        check(rr.keptHereWords == "Claude Code deletes sessions 30 days after their last use, the Claude window's too: there is an error in your organisation's managed settings.", "…and the card says so (\(what)): \(rr.keptHereWords)", line: at)
        // …also when the user's own settings.json sets a clean-up period (said as deleted: the safe side)
        settings(c, "{\"cleanupPeriodDays\":30}")
        let r2 = r()
        check(r2.managedError && r2.skipped == nil && fate(transcript(c, 51, win, age: 400), r2) == .delete,
              "…with cleanupPeriodDays in settings.json too (\(what))", line: at)
    }
    badFile("that is a folder") { try? fm.createDirectory(atPath: p(fileA), withIntermediateDirectories: true) }
    // a link to nowhere is a missing file to Claude Code (it only logs it): not an error
    clean(); settings(c, "{}")
    try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: p(fileA), withDestinationPath: p("no-such-file.json"))
    check(!r().managedError && r().exempts, "managed-settings.json that is a link to nowhere: not there, no error")
    badFile("over 2 MB") { put(fileA, "{\"cleanupPeriodDays\":4,\"pad\":\"\(String(repeating: "x", count: 3 * 1024 * 1024))\"}") }
    badFile("that is an array") { put(fileA, "[1,2,3]") }
    badFile("that isn't JSON") { put(fileA, "{ nope") }
    badFile("that the suite can't open (mode 000)") {
        put(fileA, "{\"cleanupPeriodDays\":4}")
        try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: p(fileA))
    }
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p(fileA))
    // a managed-settings.json that is a link to a good file IS followed (Claude Code follows it too)
    clean(); settings(c, "{}")
    put("elsewhere.json", "{\"cleanupPeriodDays\":4}")
    try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: p(fileA), withDestinationPath: p("elsewhere.json"))
    check(r().managed && r().days == 4 && !r().managedError, "managed-settings.json that is a link to a good file: read where it points")
    // the other sources, bad: an error too, and the sources that are fine are still read
    clean(); settings(c, "{}")
    put(sCache, "{ nope")
    check(r().managedError && !r().managed && r().skipped == nil && fate(transcript(c, 53, win, age: 400), r()) == .delete, "a server cache that isn't JSON: a managed error, no exemption")
    put(fileA, "{\"cleanupPeriodDays\":4}")
    check(r().managedError && r().managed && r().days == 4, "…and the file's own cleanupPeriodDays is still read (4)")
    clean(); settings(c, "{}")
    put(sCache, "{\"cleanupPeriodDays\":6,\"pad\":\"\(String(repeating: "x", count: 8 * 1024 * 1024))\"}")
    check(r().managedError && !r().managed, "a server cache over 8 MiB: a managed error")
    clean(); settings(c, "{}")
    put(sCache, "[]")
    check(r().managedError, "a server cache that is an array: a managed error")
    clean(); settings(c, "{}")
    try? fm.createDirectory(atPath: p("managed/Managed Preferences/sample/com.anthropic.claudecode.plist"), withIntermediateDirectories: true)
    check(r().managedError, "an MDM plist that is a folder: a managed error")
    clean(); settings(c, "{}")
    put("managed/Managed Preferences/com.anthropic.claudecode.plist", "this is not a property list")
    check(r().managedError, "an MDM plist that can't be read as a property list: a managed error")
    clean(); settings(c, "{}")
    put("managed/ClaudeCode/managed-settings.d/10-bad.json", "{ nope"); put("managed/ClaudeCode/managed-settings.d/20-good.json", "{\"cleanupPeriodDays\":9}")
    check(r().managedError && r().managed && r().days == 9 && !r().exempts, "a drop-in that isn't JSON: an error, and the good drop-in is still read")
    clean(); settings(c, "{}")
    put("managed/ClaudeCode/managed-settings.d/10-big.json", "{\"cleanupPeriodDays\":8,\"pad\":\"\(String(repeating: "x", count: 3 * 1024 * 1024))\"}")
    check(r().managedError && !r().managed, "an oversized drop-in: an error, its value isn't taken")
    clean(); settings(c, "{}")
    try? fm.createDirectory(atPath: p("managed/ClaudeCode/managed-settings.d"), withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: p("managed/ClaudeCode/managed-settings.d"))
    check(r().managedError && r().skipped == nil, "a drop-in folder that can't be listed (mode 000): an error")
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p("managed/ClaudeCode/managed-settings.d"))
    // a managed error with a settings.json that sets the cap, not the days: still skipped; with managed days: runs
    clean(); settings(c, "{\"desktopSessionCleanupPeriodDays\":90}"); put(sCache, "{ nope")
    check(r().skipped == nil && r().managedError && fate(transcript(c, 54, win, age: 400), r()) == .delete, "a managed error and desktopSessionCleanupPeriodDays in settings.json: said as deleted, no exemption (the safe side)")
    put(fileA, "{\"cleanupPeriodDays\":10}")
    check(r().skipped == nil && r().managed && fate(transcript(c, 55, win, age: 400), r()) == .delete, "…but with managed cleanupPeriodDays Claude Code always runs it")
    // values
    clean(); settings(c, "{\"desktopSessionCleanupPeriodDays\":120}")
    put(fileA, "{\"desktopSessionCleanupPeriodDays\":0}")
    check(!r().managed && r().desktopDays == nil, "a managed desktopSessionCleanupPeriodDays of 0 (no cap) beats the user's 120")
    put(fileA, "{\"desktopSessionCleanupPeriodDays\":50}")
    check(!r().managed && r().desktopDays == 50, "a managed cap of 50 beats the user's 120, and cleanupPeriodDays isn't managed")
    transcript(c, 1, win, age: 40)
    check(fate(p("\(c)/projects/-sample/\(uuid(1)).jsonl"), r()) == .keep && fate(transcript(c, 2, win, age: 60), r()) == .delete, "…the cap 50 applies to window sessions: 40 days kept, 60 deleted")
    // managed cleanupPeriodDays: no exemption at all, and the cap is ignored
    put(fileA, "{\"cleanupPeriodDays\":20,\"desktopSessionCleanupPeriodDays\":0}")
    check(r().managed && fate(transcript(c, 3, win, age: 25), r()) == .delete && fate(transcript(c, 4, win, age: 15), r()) == .keep,
          "managed cleanupPeriodDays 20: a window session is deleted after 20 days too")
    settings(c, "{}")
    put(fileA, "{\"cleanupPeriodDays\":\"seven\"}")
    check(!r().managed && r().managedError && r().days == 30 && fate(transcript(c, 5, win, age: 400), r()) == .delete,
          "a managed cleanupPeriodDays that isn't a number: a managed error, no exemption (the user's own days stay: 30)")
    put(fileA, "{\"desktopSessionCleanupPeriodDays\":\"x\"}")
    check(r().managedError && fate(transcript(c, 6, win, age: 400), r()) == .delete, "a managed cap that isn't a number: a managed error, no exemption")
    settings(c, "{\"desktopSessionCleanupPeriodDays\":120}")
    check(r().skipped == nil && r().managedError && fate(transcript(c, 8, win, age: 400), r()) == .delete, "…also with the key in settings.json (the safe side)")
    // a policy helper (policyHelper / policyHelpers) in any managed source may set cleanupPeriodDays unseen: no exemption,
    // no skip note, the window's sessions counted with the period settings.json gives
    for (what, make) in [("policyHelper in managed-settings.json", { put(fileA, "{\"policyHelper\":{\"path\":\"/usr/local/bin/sample-helper\"}}") }),
                         ("policyHelpers in the server cache", { put(sCache, "{\"policyHelpers\":{\"macos\":{\"path\":\"/usr/local/bin/sample-helper\"}}}") }),
                         ("policyHelper in a drop-in", { put("managed/ClaudeCode/managed-settings.d/10-a.json", "{\"policyHelper\":{\"path\":\"/usr/local/bin/sample-helper\"}}") }),
                         ("policyHelper in MDM", { plist("sample", ["policyHelper": ["path": "/usr/local/bin/sample-helper"]]) })] as [(String, () -> Void)] {
        clean(); settings(c, "{\"desktopSessionCleanupPeriodDays\":\"x\"}"); make()
        let rr = r()
        check(rr.helper && !rr.managed && !rr.exempts && rr.skipped == nil, "\(what): no exemption, no skip note (the user's invalid key notwithstanding)")
        check(fate(transcript(c, 60, win, age: 400), rr) == .delete && fate(transcript(c, 61, win, age: 20), rr) == .keep,
              "…a window transcript of 400 days is counted as deleted, one of 20 days kept (\(what))")
        check(!rr.keptHereWords.contains("skips") && rr.keptHereWords.contains("may set"), "…worded: \(rr.keptHereWords)")
    }
    clean(); settings(c, "{\"cleanupPeriodDays\":\"x\"}"); put(fileA, "{\"policyHelper\":{\"path\":\"/usr/local/bin/sample-helper\"}}")
    check(r().helper && r().skipped == nil && r().days == 30 && fate(transcript(c, 62, win, age: 40), r()) == .delete, "a helper and an invalid user cleanupPeriodDays: counted with 30 days, the window's too")
    clean(); settings(c, "{\"cleanupPeriodDays\":90}"); put(fileA, "{\"policyHelper\":{\"path\":\"/usr/local/bin/sample-helper\"}}")
    check(r().helper && r().days == 90 && fate(transcript(c, 63, win, age: 100), r()) == .delete && fate(transcript(c, 64, win, age: 60), r()) == .keep, "a helper and cleanupPeriodDays 90: every session counted after 90 days")
    clean(); settings(c, "{\"desktopSessionCleanupPeriodDays\":\"x\"}"); put(fileA, "{\"policyHelper\":null}")
    check(!r().helper && r().skipped == .key("desktopSessionCleanupPeriodDays") && r().exempts, "policyHelper: null names no helper (the skip note stays)")
    // a window session in a throwaway folder with nothing managed at all is kept again
    clean(); settings(c, "{}")
    check(fate(transcript(c, 7, win, age: 400), r()) == .keep, "back to no managed source: kept")
}

// ============ 7. the counts, Keep for 90 days, and the words ============
do {
    resetHome()
    let c = ".claude-g"
    let win = line("claude-desktop"), term = line("cli")
    func read(_ path: String) -> Retention.Transcript { Retention.Transcript.read(path: path)! }
    var r = base
    var t = Retention.Tally()
    for (id, body, age) in [(1, term, 40.0), (2, term, 100.0), (3, win, 400.0), (4, term, 5.0)] {
        t.add(read(transcript(c, id, body, age: age)), r, now: now)
    }
    check(t.old == 2 && t.oldWindow == 0 && t.oldSaved == 1 && t.unsure == 0, "terminal 40d and 100d are deleted; 90 days would save only the 40d one: \(t)")
    check(t.shows && t.canKeepLonger, "the row is there, and Keep for 90 days can help")
    check(t.words(r) == "2: Claude Code would delete them again. Keep for 90 days would save 1", "words: \(t.words(r))")
    // only ones 90 days can't save: no Keep for 90 days
    var t2 = Retention.Tally()
    t2.add(read(transcript(c, 5, term, age: 200)), r, now: now)
    check(t2.old == 1 && t2.oldSaved == 0 && !t2.canKeepLonger && t2.words(r) == "1: Claude Code would delete them again", "a 200-day terminal session: 90 days can't save it, no Keep for 90 days: \(t2.words(r))")
    // a released window session: counted, and not saved by 90 days
    transcript(c, 6, win, age: 100); marker(c, 6, "{\"reason\":\"delete\"}", age: 1)
    var t3 = Retention.Tally()
    t3.add(read(p("\(c)/projects/-sample/\(uuid(6)).jsonl")), r, now: now)
    check(t3.old == 1 && t3.oldWindow == 1 && t3.oldSaved == 0 && !t3.canKeepLonger, "a window session released with delete: deleted, of the Claude window, 90 days can't save it")
    check(t3.words(r) == "1: Claude Code would delete them again, 1 of them from the Claude window (deleted or archived there, or past its limit)", "words: \(t3.words(r))")
    // an error in the managed settings ends the exemption: the window's sessions are deleted for that reason
    var t3e = Retention.Tally()
    let rErr = Retention(days: 30, managedError: true)
    t3e.add(read(transcript(c, 11, win, age: 60)), rErr, now: now)
    check(t3e.old == 1 && t3e.oldWindow == 1 && t3e.words(rErr) == "1: Claude Code would delete them again, 1 of them from the Claude window (an error in your organisation's managed settings). Keep for 90 days would save it", "managed error words: \(t3e.words(rErr))")
    // a window session past the cap: 90 days would save it only when the cap is below 90
    r = Retention(days: 30, desktopDays: 45)
    var t4 = Retention.Tally()
    t4.add(read(transcript(c, 7, win, age: 60)), r, now: now)
    check(t4.old == 1 && t4.oldWindow == 1 && t4.oldSaved == 1 && t4.words(r).hasSuffix("Keep for 90 days would save it"), "a window session of 60 days past a cap of 45: deleted; 90 days would keep it")
    // already 90 days or more: never offered
    r = Retention(days: 90)
    var t5 = Retention.Tally()
    t5.add(read(transcript(c, 8, term, age: 200)), r, now: now)
    check(t5.old == 1 && !t5.canKeepLonger, "cleanupPeriodDays 90 already: nothing to offer")
    // managed: the organisation's number, no offer, and the words say so
    r = Retention(days: 10, managed: true)
    var t6 = Retention.Tally()
    t6.add(read(transcript(c, 9, win, age: 40)), r, now: now)
    check(t6.old == 1 && !t6.canKeepLonger && t6.words(r) == "1: Claude Code would delete them again. Your organisation's managed settings set that time", "managed: \(t6.words(r))")
    // a skipped clean-up is only a note: the row, its counts and Keep for 90 days stay as if it ran
    for skip in [Retention.Skip.key("desktopSessionCleanupPeriodDays"), .key("cleanupPeriodDays"), .unreadable] {
        var t6s = Retention.Tally()
        var rSkip = Retention(days: 30); rSkip.skipped = skip
        t6s.add(read(transcript(c, 12, term, age: 400)), rSkip, now: now)
        t6s.add(read(transcript(c, 13, term, age: 40)), rSkip, now: now)
        check(t6s.shows && t6s.old == 2 && t6s.oldSaved == 1 && t6s.canKeepLonger && t6s.words(rSkip) == "2: Claude Code would delete them again. Keep for 90 days would save 1",
              "a skipped clean-up (\(skip)): the row shows with its counts and Keep for 90 days: \(t6s.words(rSkip))")
        check(rSkip.wouldDeleteInfo(file: "~/.claude/settings.json", comes: "comes back").hasSuffix(rSkip.skipNote ?? "-"), "…its info ends with the skip note (\(skip))")
    }
    // a policy helper: the window's sessions are counted, with a reason
    var tH = Retention.Tally()
    var rH = Retention(days: 30); rH.helper = true
    tH.add(read(transcript(c, 14, win, age: 60)), rH, now: now)
    check(tH.old == 1 && tH.oldWindow == 1 && tH.words(rH) == "1: Claude Code would delete them again, 1 of them from the Claude window (your organisation's managed settings may set their period). Keep for 90 days would save it", "helper words: \(tH.words(rH))")
    // unknown days
    r = Retention(days: nil)
    var t7 = Retention.Tally()
    t7.add(read(transcript(c, 10, term, age: 400)), r, now: now)
    check(t7.old == 0 && t7.unsure == 1 && t7.shows && t7.words(r) == "1: can't tell, cleanupPeriodDays in settings.json can't be read", "unknown: \(t7.words(r))")
    // nothing to say: the row is not there
    let t8 = Retention.Tally()
    check(!t8.shows && t8.words(base) == "", "no transcript deleted, none unknown: no Would be deleted row")
}

// ============ 8. the words (the site's Settings page copies the Keep for info) ============
do {
    let file = "~/.claude/settings.json"
    check(Retention.keepForInfo(file: file) == "How long Claude Code keeps the sessions you ran in the terminal: cleanupPeriodDays in ~/.claude/settings.json (default 30), kept with every other setting in that file. Sessions started or last continued in the Claude window are kept at any age (Claude Code 2.1.248 and later), unless desktopSessionCleanupPeriodDays gives them a limit or you deleted or archived the session in the Claude window. Your organisation's managed settings (or an error in them), HIPAA and zero data retention make the period apply to them too; cl_audit can't tell whether HIPAA or zero data retention applies to your account. A longer time keeps the terminal sessions available to claude --resume and for backups; it can't bring back what is already deleted.",
          "the Keep for info")
    check(Retention(days: 30).keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use; ones from the Claude window it keeps (Claude Code 2.1.248 and later).", "Kept here, plain: \(Retention(days: 30).keptHereWords)")
    check(Retention(days: 30, desktopDays: 90).keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use and ones from the Claude window 90 days after.", "Kept here with a cap")
    check(Retention(days: 30, desktopDays: 10).keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use and ones from the Claude window 30 days after.", "Kept here with a cap under the days: the longer")
    check(Retention(days: 20, managed: true).keptHereWords == "Your organisation's managed settings make Claude Code delete sessions 20 days after their last use.", "Kept here, managed")
    check(Retention(days: 30, managedError: true).keptHereWords == "Claude Code deletes sessions 30 days after their last use, the Claude window's too: there is an error in your organisation's managed settings.", "Kept here, managed error")
    check(Retention(days: nil).keptHereWords == "How long Claude Code keeps sessions isn't known: cleanupPeriodDays in settings.json can't be read.", "Kept here, unknown")
    check(Retention(days: 30, skipped: .key("cleanupPeriodDays")).keptHereWords == "Claude Code deletes terminal sessions 30 days after their last use; ones from the Claude window it keeps (Claude Code 2.1.248 and later). Claude Code 2.1.318 skips its clean-up while cleanupPeriodDays in settings.json isn't a valid number; fix it and these would be deleted.", "Kept here, skipped (days key): the rule, then the note")
    check(Retention(days: 30, desktopDays: 90, skipped: .unreadable).keepForNote == "Sessions from the Claude window are deleted after 90 days, the longer of this and desktopSessionCleanupPeriodDays (90).", "a skip doesn't hide the Keep for note")
    check(Retention(days: 30, managedError: true, skipped: .key("cleanupPeriodDays")).wouldDeleteInfo(file: file, comes: "comes back").hasSuffix("(30 days here), the Claude window's too. A transcript comes back with its real age, so one older than that would be deleted again. Claude Code 2.1.318 skips its clean-up while cleanupPeriodDays in settings.json isn't a valid number; fix it and these would be deleted."), "a managed error and a skip: both said")
    var helperR = Retention(days: 30); helperR.helper = true
    check(helperR.keptHereWords == "Your organisation's managed settings may set how long Claude Code keeps sessions (a policy helper computes them), so cl_audit counts every session, the Claude window's too, as deleted 30 days after its last use.", "Kept here, a policy helper")
    check(helperR.keepForNote == "Your organisation's managed settings may set this for every session, the Claude window's too (a policy helper computes them); cl_audit counts with 30 days for all of them.", "the policy helper's Keep for note")
    check(helperR.wouldDeleteInfo(file: file, comes: "comes in") == "Your organisation's managed settings may set cleanupPeriodDays (a policy helper computes them), so every session older than 30 days is counted, the Claude window's too. A transcript comes in with its real age, so one older than that would be deleted again.", "the policy helper's Would be deleted info")
    check(Retention(days: 30).keepForNote == nil, "no note under Keep for when the window's sessions simply stay")
    check(Retention(days: 30, desktopDays: 90).keepForNote == "Sessions from the Claude window are deleted after 90 days, the longer of this and desktopSessionCleanupPeriodDays (90).", "the cap's note")
    check(Retention(days: 20, managed: true).keepForNote == "Your organisation's managed settings set 20 days for every session, the Claude window's too. Changing it here wouldn't change that.", "the managed note")
    check(Retention(days: 30, managedError: true).keepForNote == "An error in your organisation's managed settings makes Claude Code delete the Claude window's sessions after 30 days too, like the others.", "the managed-error note")
    let plain = Retention(days: 30).wouldDeleteInfo(file: file, comes: "comes back")
    check(plain == "Claude Code deletes the transcript of a session once it is older than cleanupPeriodDays (~/.claude/settings.json, 30 by default). A transcript comes back with its real age, so one older than that would be deleted again. Sessions started or last continued in the Claude window aren't counted: Claude Code keeps them at any age (2.1.248 and later), unless you deleted or archived the session in the Claude window (an archived one goes after a grace period). Your organisation's managed settings (or an error in them), HIPAA and zero data retention make the period apply to all of them; cl_audit can't see HIPAA or zero data retention. A project's own .claude/settings.json can also set a shorter period, which cl_audit can't see.", "Would be deleted info (plain): \(plain)")
    check(Retention(days: 30, desktopDays: 90).wouldDeleteInfo(file: file, comes: "comes in").contains("they count once they are older than 90 days"), "…with a cap")
    check(Retention(days: 20, managed: true).wouldDeleteInfo(file: file, comes: "comes in") == "Your organisation's managed settings set cleanupPeriodDays to 20 days for every session, the Claude window's too. A transcript comes in with its real age, so one older than that would be deleted again.", "…managed")
    check(Retention(days: 30, managedError: true).wouldDeleteInfo(file: file, comes: "comes back").hasPrefix("There is an error in your organisation's managed settings, so Claude Code deletes every session after cleanupPeriodDays (30 days here)"), "…managed error")
    check(Retention(days: 30).wouldDeleteInfo(file: file, comes: "moves", moving: true).contains("A transcript moves with its real age, so one older than that would be deleted once it is moved."), "…the move: no doubled phrase, no 'again'")
    check(Retention.keptHereInfo.hasSuffix("since Claude Code 2.1.248 that depends on where the session ran (see Keep for)."), "the Kept here info doesn't promise the window's sessions are kept")
}

// ============ 9. a restore plan, end to end (the backup's own transcripts and markers) ============
MainActor.assumeIsolated {
    resetHome()
    SessionsRestore.runningSessions = { [] }
    let code = p(".claude-rt")
    let place = URL(fileURLWithPath: p("rt-place"))
    let win = line("claude-desktop"), term = line("cli")
    // 1 terminal 40d (deleted, 90 days saves it), 2 terminal 100d (deleted, not saved), 3 window 400d (kept),
    // 4 window 400d with a delete marker (deleted), 5 window 400d with an archive marker made 2 days ago (kept), 6 terminal 5d (kept)
    transcript(".claude-rt", 1, term, age: 40); transcript(".claude-rt", 2, term, age: 100); transcript(".claude-rt", 3, win, age: 400)
    transcript(".claude-rt", 4, win, age: 400); marker(".claude-rt", 4, "{\"reason\":\"delete\"}", age: 1)
    transcript(".claude-rt", 5, win, age: 400); marker(".claude-rt", 5, "{\"reason\":\"archive\"}", age: 2)
    transcript(".claude-rt", 6, term, age: 5)
    // Cowork: 7 local-agent 400d (kept), 8 local_agent 400d with a delete marker (deleted), 9 claude-desktop-3p 400d (kept)
    transcript(".claude-rt", 7, line("local-agent"), age: 400)
    transcript(".claude-rt", 8, line("local_agent"), age: 400); marker(".claude-rt", 8, "{\"reason\":\"delete\"}", age: 1)
    transcript(".claude-rt", 9, line("claude-desktop-3p"), age: 400)
    let src = SessionsBackup.Source(profile: "rt", dataDir: "", codeDir: code)
    let m = try! SessionsBackup.make(src, kind: .manual, window: false, transcripts: true, place: place, now: now)
    try? fm.removeItem(atPath: code + "/projects")
    let tgt = SessionsRestore.Target(profile: "rt", dataDir: "", codeDir: code, inUse: nil)
    let backup = SessionsRestore.Backup(profile: "rt", id: m.id, place: place)
    let plan = SessionsRestore.plan(tgt, backup, now: now)
    check(plan.refusal == nil && plan.transcripts.count == 9, "plan: the nine missing transcripts are to be written (\(plan.transcripts.count), \(plan.refusal ?? "no refusal"))")
    check(plan.old == 4 && plan.tally.oldWindow == 2 && plan.tally.oldSaved == 1,
          "plan: Claude Code would delete 4 (terminal 40d and 100d, the two released window ones, one of them Cowork's); 90 days would save 1: \(plan.tally)")
    check(plan.days == 30 && plan.showsWouldDelete && plan.canKeepLonger, "plan: 30 days, the row shows, Keep for 90 days helps")
    check(plan.wouldDeleteWords == "4: Claude Code would delete them again, 2 of them from the Claude window (deleted or archived there, or past its limit). Keep for 90 days would save 1", "plan words: \(plan.wouldDeleteWords)")
    // a skipped clean-up (the user's settings.json) is only a note: the same row, counts and Keep for 90 days
    for (what, json, skip) in [("an invalid cap", "{\"desktopSessionCleanupPeriodDays\":\"x\"}", Retention.Skip.key("desktopSessionCleanupPeriodDays")),
                               ("an invalid cleanupPeriodDays", "{\"cleanupPeriodDays\":-3}", .key("cleanupPeriodDays")),
                               ("a settings.json that isn't JSON", "{ nope", .unreadable)] {
        put(".claude-rt/settings.json", json)
        let planK = SessionsRestore.plan(tgt, backup, now: now)
        check(planK.retention.skipped == skip && planK.old == 4 && planK.showsWouldDelete && planK.canKeepLonger && planK.wouldDeleteWords == plan.wouldDeleteWords,
              "plan with \(what): skipped as a note, the row shows the same counts and Keep for 90 days: \(planK.tally)")
        check(planK.retention.wouldDeleteInfo(file: "~/.claude-rt/settings.json", comes: "comes back").hasSuffix("fix it and these would be deleted."), "…the info ends with the note (\(what))")
    }
    try? fm.removeItem(atPath: code + "/settings.json")
    // with Keep for 90 days (settings.json) the 40-day one is no longer counted
    try? CodeCleanup.set(90, codeDir: code)
    let plan90 = SessionsRestore.plan(tgt, backup, now: now)
    check(plan90.old == 3 && !plan90.canKeepLonger, "plan after Keep for 90 days: 3 (the 100-day one and the two released window ones), no more offer: \(plan90.tally)")
    // a managed organisation number applies to every one of them
    try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    try? "{\"cleanupPeriodDays\":60}".write(toFile: p("managed/ClaudeCode/managed-settings.json"), atomically: true, encoding: .utf8)
    let planM = SessionsRestore.plan(tgt, backup, now: now)
    check(planM.retention.managed && planM.old == 7 && !planM.canKeepLonger, "plan, managed 60 days: terminal 100d and the six window and Cowork sessions of 400 days are older than 60 days, no exemption: \(planM.tally)")
    // managed settings holding only other keys, and cleanupPeriodDays in another source: still managed (MUST 1), through the plan
    try? fm.createDirectory(atPath: code, withIntermediateDirectories: true)
    try? "{\"permissions\":{\"allow\":[]}}".write(toFile: code + "/remote-settings.json", atomically: true, encoding: .utf8)
    let planS = SessionsRestore.plan(tgt, backup, now: now)
    check(planS.retention.managed && planS.retention.days == 60 && planS.old == 7, "plan: a server cache with other keys + the file's cleanupPeriodDays: managed, 60 days: \(planS.tally)")
    try? fm.removeItem(atPath: code + "/remote-settings.json")
    try? fm.removeItem(atPath: p("managed"))
    // nothing was written by planning
    check(!fm.fileExists(atPath: code + "/projects"), "plan: wrote nothing")
    // a marker already on disk decides (a restore never writes over it)
    try? fm.createDirectory(atPath: code + "/projects/-sample", withIntermediateDirectories: true)
    put(".claude-rt/projects/-sample/\(uuid(5)).desktop-released.json", "{\"reason\":\"delete\"}", age: 1)
    let planD = SessionsRestore.plan(tgt, backup, now: now)
    check(planD.old == plan90.old + 1 && plan90.old == 3, "plan: a delete marker already there for session 5 decides over the backup's archive one: \(planD.tally)")
}

// ============ 10. the default-profile move says the same ============
do {
    resetHome()
    let win = line("claude-desktop"), term = line("cli")
    transcript(".claude-old", 1, term, age: 40); transcript(".claude-old", 2, win, age: 400)
    transcript(".claude-old", 3, win, age: 400); marker(".claude-old", 3, "{\"reason\":\"delete\"}", age: 1)
    transcript(".claude-old", 4, term, age: 2)
    transcript(".claude", 4, term, age: 2)                  // the usual app's folder has this one already
    let pv = DefaultProfile.preview(oldDataDir: p("no-window"), usualDataDir: p("no-usual"), oldCodeDir: p(".claude-old"), codeDir: p(".claude"))
    check(pv.transcripts == 3 && pv.tally.old == 2 && pv.tally.oldWindow == 1, "move: 3 transcripts go (the 4th is there already); Claude Code would delete 2 again: \(pv.tally)")
    check(pv.tally.words(pv.retention, keepHint: false, moving: true) == "2 of them Claude Code would delete once they are in ~/.claude, 1 of them from the Claude window (deleted or archived there, or past its limit)", "move words: \(pv.tally.words(pv.retention, keepHint: false, moving: true))")
    // a marker already in the usual app's folder wins over the one beside the old transcript (NIT)
    put(".claude/projects/-sample/\(uuid(3)).desktop-released.json", "{\"reason\":\"archive\"}", age: 1)
    let pv2 = DefaultProfile.preview(oldDataDir: p("no-window"), usualDataDir: p("no-usual"), oldCodeDir: p(".claude-old"), codeDir: p(".claude"))
    check(pv2.tally.old == 1, "move: an archive marker (in its grace) already in ~/.claude/projects wins over the old folder's delete marker: \(pv2.tally)")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
