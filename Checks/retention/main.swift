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
    check(r.days == 30 && r.desktopDays == nil && !r.managed && !r.settingsError, "nothing set: 30 days, no cap")
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
    // wrong kinds of value: Claude Code reports a settings error and the exemption ends
    for bad in ["\"90\"", "-1", "1.5", "true", "null"] {
        r = with("{\"desktopSessionCleanupPeriodDays\":\(bad)}")
        check(r.settingsError && r.desktopDays == nil, "desktopSessionCleanupPeriodDays \(bad): a settings error")
        check(fate(transcript(c, 9, win, age: 400), r) == .delete, "…so a window session is deleted by cleanupPeriodDays like the others (\(bad))")
    }
    // the days themselves
    r = with("{\"cleanupPeriodDays\":7}")
    check(r.days == 7 && fate(transcript(c, 10, line("cli"), age: 8), r) == .delete && fate(transcript(c, 11, line("cli"), age: 6), r) == .keep, "cleanupPeriodDays 7")
    for bad in ["0", "\"x\"", "2.5", "true"] {
        r = with("{\"cleanupPeriodDays\":\(bad)}")
        check(r.days == nil && r.problem != nil && fate(transcript(c, 12, line("cli"), age: 400), r) == .unknown, "cleanupPeriodDays \(bad): not known, nothing is called deleted")
    }
    settings(c, "{ not json")
    r = Retention.read(codeDir: p(c))
    check(r.days == nil && fate(transcript(c, 13, line("cli"), age: 400), r) == .unknown, "a settings.json that isn't JSON: unknown")
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
    check(r().days == 30 && !r().managed && r().source == .server, "the server source holds other settings, not this one: it still wins, so cleanupPeriodDays isn't managed (30)")
    try? fm.removeItem(atPath: p(sCache))
    plist("sample", ["somethingElse": "x"])
    check(r().days == 30 && !r().managed, "MDM holds other keys only: it wins over the file (nothing managed for cleanup)")
    try? fm.removeItem(atPath: p("managed/Managed Preferences"))
    check(r().days == 13, "…and with it gone the file's value applies")
    // files that are not plain, or too big, or not objects, are ignored
    clean(); settings(c, "{}")
    try? fm.createDirectory(atPath: p(fileA), withIntermediateDirectories: true)
    check(!r().managed, "managed-settings.json that is a folder: ignored")
    try? fm.removeItem(atPath: p(fileA))
    put("elsewhere.json", "{\"cleanupPeriodDays\":4}")
    try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: p(fileA), withDestinationPath: p("elsewhere.json"))
    check(!r().managed, "managed-settings.json that is a link: not followed")
    try? fm.removeItem(atPath: p(fileA))
    put(fileA, "{\"cleanupPeriodDays\":4,\"pad\":\"\(String(repeating: "x", count: 2 * 1024 * 1024))\"}")
    check(!r().managed, "managed-settings.json over 2 MB: ignored")
    put(fileA, "[1,2,3]")
    check(!r().managed, "managed-settings.json that is an array: ignored")
    put(fileA, "{ nope")
    check(!r().managed, "managed-settings.json that isn't JSON: ignored")
    put(fileA, "{\"cleanupPeriodDays\":4}")
    put("managed/ClaudeCode/managed-settings.d/10-big.json", "{\"cleanupPeriodDays\":8,\"pad\":\"\(String(repeating: "x", count: 2 * 1024 * 1024))\"}")
    check(r().days == 4, "an oversized drop-in is skipped, the others still apply")
    try? fm.removeItem(atPath: p(sCache))
    put(sCache, "{\"cleanupPeriodDays\":6,\"pad\":\"\(String(repeating: "x", count: 8 * 1024 * 1024))\"}")
    check(r().days == 4 && r().source == .file, "a server cache over 8 MiB: ignored, the file source applies")
    try? fm.removeItem(atPath: p(sCache))
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
    put(fileA, "{\"cleanupPeriodDays\":\"seven\"}")
    check(!r().managed && r().settingsError && r().days == 30 && fate(transcript(c, 5, win, age: 400), r()) == .delete,
          "a managed cleanupPeriodDays that isn't a number: a settings error, no exemption (the user's own days stay: 30)")
    put(fileA, "{\"desktopSessionCleanupPeriodDays\":\"x\"}")
    check(r().settingsError && fate(transcript(c, 6, win, age: 400), r()) == .delete, "a managed cap that isn't a number: a settings error, no exemption")
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
    check(t.words(r) == "2: Claude Code would delete them again. Keep for 90 days would keep 1 of them", "words: \(t.words(r))")
    // only ones 90 days can't save: no Keep for 90 days
    var t2 = Retention.Tally()
    t2.add(read(transcript(c, 5, term, age: 200)), r, now: now)
    check(t2.old == 1 && t2.oldSaved == 0 && !t2.canKeepLonger && t2.words(r) == "1: Claude Code would delete them again", "a 200-day terminal session: 90 days can't save it, no Keep for 90 days: \(t2.words(r))")
    // a released window session: counted, and not saved by 90 days
    transcript(c, 6, win, age: 100); marker(c, 6, "{\"reason\":\"delete\"}", age: 1)
    var t3 = Retention.Tally()
    t3.add(read(p("\(c)/projects/-sample/\(uuid(6)).jsonl")), r, now: now)
    check(t3.old == 1 && t3.oldWindow == 1 && t3.oldSaved == 0 && !t3.canKeepLonger, "a window session released with delete: deleted, of the Claude window, 90 days can't save it")
    check(t3.words(r) == "1: Claude Code would delete them again (1 of the Claude window, released by it or past the limit set for those)", "words: \(t3.words(r))")
    // a window session past the cap: 90 days would save it only when the cap is below 90
    r = Retention(days: 30, desktopDays: 45)
    var t4 = Retention.Tally()
    t4.add(read(transcript(c, 7, win, age: 60)), r, now: now)
    check(t4.old == 1 && t4.oldWindow == 1 && t4.oldSaved == 1 && t4.words(r).hasSuffix("Keep for 90 days first"), "a window session of 60 days past a cap of 45: deleted; 90 days would keep it")
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
    // unknown days
    r = Retention(days: nil)
    var t7 = Retention.Tally()
    t7.add(read(transcript(c, 10, term, age: 400)), r, now: now)
    check(t7.old == 0 && t7.unsure == 1 && t7.shows && t7.words(r) == "1: not known, settings.json doesn't say how long Claude Code keeps them", "unknown: \(t7.words(r))")
    // nothing to say: the row is not there
    let t8 = Retention.Tally()
    check(!t8.shows && t8.words(base) == "", "no transcript deleted, none unknown: no Would be deleted row")
}

// ============ 8. the words (the site's Settings page copies the Keep for info) ============
do {
    let file = "~/.claude/settings.json"
    check(Retention.keepForInfo(file: file) == "How long Claude Code keeps the sessions you ran in the terminal: cleanupPeriodDays in ~/.claude/settings.json (default 30), kept with every other setting in that file. Sessions started or last continued in the Claude window are kept at any age (Claude Code 2.1.248 and later), unless desktopSessionCleanupPeriodDays gives them a limit or the window released the session. Your organisation's managed settings, HIPAA, zero data retention or an error in a settings file make the period apply to them too. A longer time keeps the terminal sessions available to claude --resume and for backups; it can't bring back what is already deleted.",
          "the Keep for info")
    check(Retention(days: 30).keptHereWords == "Claude Code deletes terminal sessions after 30 days; ones from the Claude window it keeps (Claude Code 2.1.248 and later).", "Kept here, plain: \(Retention(days: 30).keptHereWords)")
    check(Retention(days: 30, desktopDays: 90).keptHereWords == "Claude Code deletes terminal sessions after 30 days and ones from the Claude window after 90.", "Kept here with a cap")
    check(Retention(days: 30, desktopDays: 10).keptHereWords == "Claude Code deletes terminal sessions after 30 days and ones from the Claude window after 30.", "Kept here with a cap under the days: the longer")
    check(Retention(days: 20, managed: true).keptHereWords == "Your organisation's managed settings make Claude Code delete sessions after 20 days.", "Kept here, managed")
    check(Retention(days: 30, settingsError: true).keptHereWords == "Claude Code deletes sessions after 30 days, the Claude window's too, while a settings file has an error.", "Kept here, settings error")
    check(Retention(days: nil).keptHereWords == "How long Claude Code keeps sessions from the terminal isn't known (settings.json).", "Kept here, unknown")
    check(Retention(days: 30).keepForNote == nil, "no note under Keep for when the window's sessions simply stay")
    check(Retention(days: 30, desktopDays: 90).keepForNote == "Sessions from the Claude window are deleted after 90 days (desktopSessionCleanupPeriodDays is 90; the longer of it and this applies).", "the cap's note")
    check(Retention(days: 20, managed: true).keepForNote == "Your organisation's managed settings set 20 days for every session, the Claude window's too. Changing it here wouldn't change that.", "the managed note")
    check(Retention(days: 30, settingsError: true).keepForNote == "A settings file has an error, so Claude Code deletes the Claude window's sessions after 30 days too, like the others.", "the settings-error note")
    let plain = Retention(days: 30).wouldDeleteInfo(file: file, comes: "comes back")
    check(plain.contains("Claude Code deletes the transcript of a session once it is older than cleanupPeriodDays (~/.claude/settings.json, 30 by default)")
          && plain.contains("A transcript comes back with its real age") && plain.contains("2.1.248 and later")
          && plain.contains("or the window released the session") && plain.contains("zero data retention or a settings error"), "Would be deleted info (plain): \(plain)")
    check(Retention(days: 30, desktopDays: 90).wouldDeleteInfo(file: file, comes: "comes in").contains("they count once they are older than 90 days"), "…with a cap")
    check(Retention(days: 20, managed: true).wouldDeleteInfo(file: file, comes: "comes in") == "Your organisation's managed settings set cleanupPeriodDays to 20 days for every session, the Claude window's too. A transcript comes in with its real age, so one older than that would be deleted again.", "…managed")
    check(Retention(days: 30, settingsError: true).wouldDeleteInfo(file: file, comes: "comes back").hasPrefix("A settings file has an error, so Claude Code deletes every session after cleanupPeriodDays (30 days here)"), "…settings error")
    check(Retention.keptHereInfo.hasSuffix("sessions from the Claude window are kept at any age since Claude Code 2.1.248."), "the Kept here info names the version")
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
    let src = SessionsBackup.Source(profile: "rt", dataDir: "", codeDir: code)
    let m = try! SessionsBackup.make(src, kind: .manual, window: false, transcripts: true, place: place, now: now)
    try? fm.removeItem(atPath: code + "/projects")
    let tgt = SessionsRestore.Target(profile: "rt", dataDir: "", codeDir: code, inUse: nil)
    let backup = SessionsRestore.Backup(profile: "rt", id: m.id, place: place)
    let plan = SessionsRestore.plan(tgt, backup, now: now)
    check(plan.refusal == nil && plan.transcripts.count == 6, "plan: the six missing transcripts are to be written (\(plan.transcripts.count), \(plan.refusal ?? "no refusal"))")
    check(plan.old == 3 && plan.tally.oldWindow == 1 && plan.tally.oldSaved == 1, "plan: Claude Code would delete 3 (terminal 40d and 100d, the released window one); 90 days would save 1: \(plan.tally)")
    check(plan.days == 30 && plan.showsWouldDelete && plan.canKeepLonger, "plan: 30 days, the row shows, Keep for 90 days helps")
    check(plan.wouldDeleteWords == "3: Claude Code would delete them again (1 of the Claude window, released by it or past the limit set for those). Keep for 90 days would keep 1 of them", "plan words: \(plan.wouldDeleteWords)")
    // with Keep for 90 days (settings.json) the 40-day one is no longer counted
    try? CodeCleanup.set(90, codeDir: code)
    let plan90 = SessionsRestore.plan(tgt, backup, now: now)
    check(plan90.old == 2 && !plan90.canKeepLonger, "plan after Keep for 90 days: 2 (the 100-day one and the released window one), no more offer: \(plan90.tally)")
    // a managed organisation number applies to every one of them
    try? fm.createDirectory(atPath: p("managed/ClaudeCode"), withIntermediateDirectories: true)
    try? "{\"cleanupPeriodDays\":60}".write(toFile: p("managed/ClaudeCode/managed-settings.json"), atomically: true, encoding: .utf8)
    let planM = SessionsRestore.plan(tgt, backup, now: now)
    check(planM.retention.managed && planM.old == 4 && !planM.canKeepLonger, "plan, managed 60 days: terminal 100d and the three window sessions of 400 days are older than 60 days, no exemption: \(planM.tally)")
    try? fm.removeItem(atPath: p("managed"))
    // nothing was written by planning
    check(!fm.fileExists(atPath: code + "/projects"), "plan: wrote nothing")
    // a marker already on disk decides (a restore never writes over it)
    try? fm.createDirectory(atPath: code + "/projects/-sample", withIntermediateDirectories: true)
    put(".claude-rt/projects/-sample/\(uuid(5)).desktop-released.json", "{\"reason\":\"delete\"}", age: 1)
    let planD = SessionsRestore.plan(tgt, backup, now: now)
    check(planD.old == plan90.old + 1, "plan: a delete marker already there for session 5 decides over the backup's archive one: \(planD.tally)")
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
    check(pv.tally.words(pv.retention, keepHint: false) == "2: Claude Code would delete them again (1 of the Claude window, released by it or past the limit set for those)", "move words: \(pv.tally.words(pv.retention, keepHint: false))")
}

print("checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
