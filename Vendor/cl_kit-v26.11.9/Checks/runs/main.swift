// Runs checks (Run/): compiled against Runs ONLY (Foundation). The programs run are harmless stand-ins (/bin/sh, /bin/sleep,
// /usr/bin/true, /usr/bin/false, /bin/echo): exit statuses, a program that couldn't start, the timeout (SIGTERM, then SIGKILL
// after the grace for one that ignores it), output read while it runs (more than a pipe holds), the cap, the drain after a
// program left a child holding its output, a crash told apart (signaled), and the cleaned environment; then a lint that
// Run/ stays Foundation only and shareable.
//
// Runs with HOME at Checks/.work/runs/home (Checks/run.sh sets and guards it).

import Foundation
@testable import Runs

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/runs/home") else { print("refusing: HOME is \(home)"); exit(2) }
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func took(_ f: () -> Void) -> TimeInterval { let t = Date(); f(); return Date().timeIntervalSince(t) }

// ============ 1. how a program ends ============
do {
    check(Runner.run(Program("/usr/bin/true", timeout: 5)) == Ran(status: 0) && Runner.run(Program("/usr/bin/true", timeout: 5))?.ok == true,
          "true: status 0, ok")
    let f = Runner.run(Program("/usr/bin/false", timeout: 5))
    check(f?.status == 1 && f?.ok == false && f?.signaled == false, "false: status 1")
    check(Runner.run(Program("/bin/sh", ["-c", "exit 44"], timeout: 5))?.status == 44, "a status as the program gave it (44)")
    check(Runner.run(Program(home + "/no-such-program", timeout: 5)) == nil, "a program that can't start: nil")
    let crash = Runner.run(Program("/bin/sh", ["-c", "kill -SEGV $$"], timeout: 5))
    check(crash?.signaled == true && crash?.status == SIGSEGV && crash?.ok == false, "ended by a signal of its own: signaled, the signal as status")
    let pwd = Runner.run(Program("/bin/pwd", ["-P"], timeout: 5, keepOutput: true)).map { String(decoding: $0.output, as: UTF8.self) }?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // (both sides as the kernel names them: realpath, since Foundation drops a leading /private when it resolves links)
    func real(_ p: String) -> String? { guard let c = realpath(p, nil) else { return nil }; defer { free(c) }; return String(cString: c) }
    let tmp = real(FileManager.default.temporaryDirectory.path)
    check(pwd != nil && pwd.flatMap(real) == tmp, "it runs in the temporary folder: \(pwd ?? "-") (\(tmp ?? "-"))")
}

// ============ 2. the timeout: SIGTERM, then SIGKILL after the grace ============
do {
    var r: Ran?? = .none
    let t1 = took { r = Runner.run(Program("/bin/sleep", ["5"], timeout: 0.5, grace: 0.5)) }
    check(r! == nil && t1 < 2.5, "past its timeout it is asked to end and nil comes back (\(String(format: "%.1f", t1)) s)")
    // one that ignores SIGTERM: killed after the grace, never waited on for good
    let t2 = took { r = Runner.run(Program("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 0.5, grace: 0.5)) }
    check(r! == nil && t2 < 3.5, "one that ignores SIGTERM: killed after the grace (\(String(format: "%.1f", t2)) s)")
    // stop() on its own
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "trap '' TERM; sleep 10"]
    try? p.run()
    usleep(200_000)
    let t3 = took { Runner.stop(p, grace: 0.3) }
    check(!p.isRunning && t3 < 2.5, "stop: SIGTERM, the grace, SIGKILL, reaped (\(String(format: "%.1f", t3)) s)")
    let done = Process()
    done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? done.run()
    Runner.waitQuietly(done)
    check(!done.isRunning && took { Runner.stop(done, grace: 5) } < 0.5, "stop on a program that already ended: nothing to wait for")
}

// ============ 3. output ============
do {
    let hi = Runner.run(Program("/bin/echo", ["hello"], timeout: 5, keepOutput: true))
    check(hi?.output == Data("hello\n".utf8), "what it printed")
    check(Runner.run(Program("/bin/echo", ["hello"], timeout: 5))?.output.isEmpty == true, "not kept unless asked")
    // more than a pipe holds (64 KB): read while it runs, so it never blocks on a full pipe
    var big: Ran?
    let t = took { big = Runner.run(Program("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x'"], timeout: 10, keepOutput: true)) }
    check(big?.ok == true && big?.output.count == 300_000 && big?.complete == true && t < 5,
          "300 KB of output: all of it, read whole, no stall (\(big?.output.count ?? -1) bytes)")
    let capped = Runner.run(Program("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' 'x'"], timeout: 10, keepOutput: true, outputCap: 1000))
    check(capped?.ok == true && capped?.output.count == 1000 && capped?.complete == false,
          "the cap: at most that many bytes kept, and the result says it isn't whole (\(capped?.output.count ?? -1))")
    check(hi?.complete == true && Runner.run(Program("/bin/echo", ["x"], timeout: 5))?.complete == true, "a whole read, or none kept: complete")
    // a child left holding the output open: read for the drain at most, then what was read
    var held: Ran?
    let t2 = took { held = Runner.run(Program("/bin/sh", ["-c", "echo hi; sleep 5 &"], timeout: 5, keepOutput: true, drain: 0.5)) }
    check(held?.ok == true && String(decoding: held?.output ?? Data(), as: UTF8.self).hasPrefix("hi") && held?.complete == false && t2 < 3,
          "a child holding the output open: the output so far after the drain, said not whole (\(String(format: "%.1f", t2)) s)")
    // output of a program that timed out isn't returned
    check(Runner.run(Program("/bin/sh", ["-c", "echo partial; sleep 5"], timeout: 0.5, grace: 0.2, keepOutput: true)) == nil,
          "timed out: nil, whatever it printed")
}

// ============ 4. the environment ============
do {
    var base = ["HOME": home, "PATH": "/usr/bin", "KEEP": "1", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere"]
    for k in ProviderEnvironment.variables { base[k] = "from-the-shell" }
    let env = ProviderEnvironment.cleaned(base)
    check(ProviderEnvironment.variables.allSatisfy { env[$0] == nil } && env["CLAUDE_CONFIG_DIR"] == nil, "no provider variable and no CLAUDE_CONFIG_DIR")
    check(env["KEEP"] == "1" && env["HOME"] == home && env["PATH"] == "/usr/bin", "the rest stays")
    check(Set(ProviderEnvironment.variables) == ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK",
                                                 "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"],
          "the list: a key, a token, another provider, a base URL, extra headers")
    // the environment given is the one the program gets (and nothing else)
    let seen = Runner.run(Program("/usr/bin/env", environment: ["ONLY": "this"], timeout: 5, keepOutput: true))
    let lines = String(decoding: seen?.output ?? Data(), as: UTF8.self).split(separator: "\n")
    check(lines.contains("ONLY=this") && !lines.contains { $0.hasPrefix("HOME=") || $0.hasPrefix("PATH=") },
          "the program gets the environment given, not the caller's: \(lines)")
}

// ============ 4b. the options the app's other launchers need ============
do {
    // the working folder: the temporary one, the caller's own, or one given
    func real(_ p: String) -> String? { guard let c = realpath(p, nil) else { return nil }; defer { free(c) }; return String(cString: c) }
    func pwd(_ f: Program.Folder) -> String? {
        Runner.run(Program("/bin/pwd", ["-P"], folder: f, timeout: 5, keepOutput: true))
            .map { String(decoding: $0.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    try? FileManager.default.createDirectory(atPath: home + "/work here", withIntermediateDirectories: true)
    check(pwd(.at(home + "/work here")).flatMap(real) == real(home + "/work here"), "a folder given: it runs there")
    check(pwd(.inherited).flatMap(real) == real(FileManager.default.currentDirectoryPath), "inherited: the caller's own folder")
    // input written, then closed
    let cat = Runner.run(Program("/bin/cat", input: Data("secret line\n".utf8), timeout: 5, keepOutput: true))
    check(cat?.ok == true && cat?.output == Data("secret line\n".utf8), "input is written and closed (cat ends)")
    let early = Runner.run(Program("/usr/bin/true", input: Data(repeating: 0x41, count: 1 << 20), timeout: 5))
    check(early?.ok == true, "a program that ends before reading its input: no SIGPIPE for the caller, its own status")
    var unread: Ran?? = .none
    let tu = took { unread = Runner.run(Program("/bin/sleep", ["5"], input: Data(repeating: 0x42, count: 1 << 20), timeout: 0.5, grace: 0.3)) }
    check(unread! == nil && tu < 2.5, "a big input it never reads: the timeout still stops it (\(String(format: "%.1f", tu)) s)")
    // errors kept apart from output
    let both = Runner.run(Program("/bin/sh", ["-c", "echo out; echo err >&2"], timeout: 5, keepOutput: true, keepErrors: true))
    check(both?.output == Data("out\n".utf8) && both?.errors == Data("err\n".utf8), "errors kept apart from the output")
    check(Runner.run(Program("/bin/sh", ["-c", "echo err >&2"], timeout: 5))?.errors.isEmpty == true, "errors dropped unless asked")
    // poll: asked right away and every so often; true stops it, and the result says so (its status as it ended)
    var asked = 0
    var stopped: Ran?
    let tp = took { stopped = Runner.run(Program("/bin/sleep", ["5"], timeout: .infinity, grace: 1), poll: { asked += 1; return asked >= 3 }, pollEvery: 0.1) }
    check(stopped?.stopped == true && stopped?.ok == false && stopped?.signaled == false && stopped?.status == SIGTERM && tp < 2,
          "poll true: stopped, said so, its status after SIGTERM (\(stopped.map { "\($0.status)" } ?? "nil"), \(String(format: "%.1f", tp)) s)")
    var neverAsked = 0
    _ = Runner.run(Program("/usr/bin/true", timeout: 5), poll: { neverAsked += 1; return false })
    check(neverAsked <= 1, "a quick program: polled at most once")
    // started: its pid, while it runs
    var seen: pid_t = 0, aliveThen = false
    _ = Runner.run(Program("/bin/sleep", ["0.3"], timeout: 5), started: { p in seen = p; aliveThen = kill(p, 0) == 0 })
    check(seen > 0 && aliveThen, "started: told its pid while it runs")
    // never killed: asked to end, given the grace, then left to end by itself (and nil, as a timeout)
    var tpid: pid_t = 0
    var left: Ran??
    let tk = took { left = Runner.run(Program("/bin/sh", ["-c", "trap '' TERM; sleep 3"], timeout: 0.3, grace: 0.2, killAfterGrace: false),
                                      started: { tpid = $0 }) }
    check(left! == nil && tk < 1.5 && kill(tpid, 0) == 0, "killAfterGrace false: SIGTERM only, the caller goes on, the program still runs")
    if tpid > 0 { kill(tpid, SIGKILL) }
    // an unlimited drain: the output read to its end
    let longDrain = Runner.run(Program("/bin/sh", ["-c", "echo a; (sleep 0.5; echo b) &"], timeout: 5, keepOutput: true, drain: .infinity))
    check(String(decoding: longDrain?.output ?? Data(), as: UTF8.self) == "a\nb\n" && longDrain?.complete == true,
          "drain .infinity: read until the output closes (a child's late line included)")
}

// ============ 4c. a running program (quick chat's kind): started, written to, read, ended ============
do {
    final class Seen: @unchecked Sendable { var out = Data(); var err = Data(); var ended = false; var exit: (Int32, Bool)?; let lock = NSLock() }
    func until(_ ok: () -> Bool, _ s: TimeInterval = 5) { let end = Date().addingTimeInterval(s); while !ok() && Date() < end { usleep(20_000) } }
    // an echo that keeps running: each line written comes back
    let s = Seen()
    let r = RunningProgram(Program("/bin/cat", timeout: .infinity))
    r.onOutput = { d in s.lock.lock(); if let d { s.out.append(d) } else { s.ended = true }; s.lock.unlock() }
    r.onExit = { st, sig in s.lock.lock(); s.exit = (st, sig); s.lock.unlock() }
    try? r.start()
    check(r.isRunning && r.pid > 0, "it runs")
    check(r.write(Data("one\n".utf8)) && r.write(Data("two\n".utf8)), "written to")
    until { s.lock.lock(); defer { s.lock.unlock() }; return s.out == Data("one\ntwo\n".utf8) }
    s.lock.lock(); let echoed = s.out; s.lock.unlock()
    check(echoed == Data("one\ntwo\n".utf8), "what it prints comes back, in order")
    r.stop(grace: 1)
    until { s.lock.lock(); defer { s.lock.unlock() }; return s.exit != nil }
    s.lock.lock(); let ex = s.exit, ended = s.ended; s.lock.unlock()
    check(ended && ex != nil && !r.isRunning, "stopped: its output ended, then its exit (\(ex.map { "\($0.0)" } ?? "none"))")
    check(!r.write(Data("three\n".utf8)), "a write after stop: false, never a crash")
    // its errors, apart
    let e = Seen()
    let er = RunningProgram(Program("/bin/sh", ["-c", "echo oops >&2; exit 3"], timeout: .infinity))
    er.onErrors = { d in e.lock.lock(); e.err.append(d); e.lock.unlock() }
    er.onExit = { st, sig in e.lock.lock(); e.exit = (st, sig); e.lock.unlock() }
    try? er.start()
    until { e.lock.lock(); defer { e.lock.unlock() }; return e.exit != nil }
    e.lock.lock(); let errText = e.err, eexit = e.exit; e.lock.unlock()
    check(errText == Data("oops\n".utf8) && eexit?.0 == 3 && eexit?.1 == false, "its errors come apart; its own exit status (3)")
    // one that ignores SIGTERM is killed after the grace; stop returns at once
    let k = Seen()
    let kr = RunningProgram(Program("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: .infinity))
    kr.onExit = { st, sig in k.lock.lock(); k.exit = (st, sig); k.lock.unlock() }
    try? kr.start()
    usleep(200_000)
    check(took { kr.stop(grace: 0.4) } < 0.2, "stop returns at once")
    until { k.lock.lock(); defer { k.lock.unlock() }; return k.exit != nil }
    k.lock.lock(); let kex = k.exit; k.lock.unlock()
    check(kex?.1 == true && kex?.0 == SIGKILL && !kr.isRunning, "one that ignores SIGTERM: killed after the grace (SIGKILL)")
    // a program that can't start
    let bad = RunningProgram(Program(home + "/no-such-program", timeout: .infinity))
    var threw = false
    do { try bad.start() } catch { threw = true }
    check(threw && !bad.isRunning && !bad.write(Data("x".utf8)), "one that can't start: start throws, writes fail")
    // closeInput: its input alone (cat ends at the end of its input), idempotent, no write after it, stop still safe
    let c = Seen()
    let cr = RunningProgram(Program("/bin/cat", timeout: .infinity))
    cr.onExit = { st, sig in c.lock.lock(); c.exit = (st, sig); c.lock.unlock() }
    var terminated: (Int32, Bool)?
    let tlock = NSLock()
    cr.onTermination = { st, sig in tlock.lock(); terminated = (st, sig); tlock.unlock() }
    try? cr.start()
    check(cr.write(Data("x\n".utf8)), "written to before its input closes")
    cr.closeInput(); cr.closeInput()
    check(!cr.write(Data("y\n".utf8)), "closeInput twice: no crash; a write after it: false")
    until { c.lock.lock(); defer { c.lock.unlock() }; return c.exit != nil }
    c.lock.lock(); let cex = c.exit; c.lock.unlock()
    tlock.lock(); let tex = terminated; tlock.unlock()
    check(cex?.0 == 0 && cex?.1 == false && tex?.0 == 0 && !cr.isRunning, "its input closed: it ended by itself (0), onTermination too")
    cr.stop(grace: 0.2)
    check(!cr.isRunning, "stop after it ended: nothing, no crash")
    // onTermination comes as the process ends, even while something it started holds its output open
    let held = RunningProgram(Program("/bin/sh", ["-c", "sleep 3 & exit 4"], timeout: .infinity))
    var heldEnd: (Int32, Bool)?, heldOutputEnded = false
    let hlock = NSLock()
    held.onTermination = { st, sig in hlock.lock(); heldEnd = (st, sig); hlock.unlock() }
    held.onOutput = { d in if d == nil { hlock.lock(); heldOutputEnded = true; hlock.unlock() } }
    try? held.start()
    until({ hlock.lock(); defer { hlock.unlock() }; return heldEnd != nil }, 2)
    hlock.lock(); let he = heldEnd, hoe = heldOutputEnded; hlock.unlock()
    check(he?.0 == 4 && !hoe, "onTermination: the process's end (4) before its output ends (a child still holds it)")
}

// ============ 4d. a process group of its own (ownGroup): stopped as a group, nothing of it outlives the run ============
do {
    /// Gone for good (a zombie still answers kill 0 until it is reaped: up to 2 s for launchd to reap an orphan).
    func gone(_ pid: pid_t) -> Bool {
        let until = Date().addingTimeInterval(2)
        while kill(pid, 0) == 0 && Date() < until { usleep(20_000) }
        return kill(pid, 0) != 0
    }
    func groupGone(_ pgid: pid_t) -> Bool {
        let until = Date().addingTimeInterval(2)
        while kill(-pgid, 0) == 0 && Date() < until { usleep(20_000) }
        return kill(-pgid, 0) != 0
    }
    func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
    // the same rules as any run: status, output, errors, input, folder, environment
    let r = Runner.run(Program("/bin/sh", ["-c", "read x; echo \"$x-$V\"; echo err >&2; exit 3"], environment: ["V": "v", "PATH": "/usr/bin:/bin"],
                               input: Data("in\n".utf8), timeout: 5, keepOutput: true, keepErrors: true, ownGroup: true))
    check(r?.status == 3 && text(r?.output ?? Data()) == "in-v\n" && text(r?.errors ?? Data()) == "err\n" && r?.signaled == false && r?.complete == true,
          "group: status, output, errors, input and environment as any run: \(String(describing: r))")
    check(Runner.run(Program(home + "/no-such-program", timeout: 5, ownGroup: true)) == nil, "group: a program that can't start: nil")
    let crash = Runner.run(Program("/bin/sh", ["-c", "kill -SEGV $$"], timeout: 5, ownGroup: true))
    check(crash?.signaled == true && crash?.status == SIGSEGV, "group: ended by a signal of its own: signaled, the signal as status")
    // its own group, the leader's pid its id
    var pgidSeen: pid_t = -2, leader: pid_t = -1
    _ = Runner.run(Program("/bin/sleep", ["0.3"], timeout: 5, ownGroup: true), started: { pid in leader = pid; pgidSeen = getpgid(pid) })
    check(leader > 0 && pgidSeen == leader && pgidSeen != getpgrp(), "group: it leads a group of its own, not the caller's (\(pgidSeen) / \(leader))")
    // nothing of the caller's descriptors leaks in
    let leak = open("/dev/null", O_RDONLY)
    // (its own output, fd 1, is seen there: the probe works; the caller's isn't)
    let fdr = Runner.run(Program("/bin/sh", ["-c", "[ -e /dev/fd/1 ] && ! [ -e /dev/fd/\(leak) ] && echo closed || echo open"], timeout: 5, keepOutput: true, ownGroup: true))
    close(leak)
    check(leak >= 0 && text(fdr?.output ?? Data()) == "closed\n", "group: a descriptor of the caller's is closed in it: \(text(fdr?.output ?? Data()))")
    // a child that ignores SIGTERM, with children of its own ignoring it too: past the timeout, SIGKILL to the whole group
    var p1: pid_t = -1
    var r1: Ran?? = .none
    // (a long-lived member that ignores SIGTERM too, `sleep 30`: the group stays until it really gets SIGKILL)
    let t1 = took { r1 = Runner.run(Program("/bin/sh", ["-c", "trap '' TERM; sleep 30 & while :; do sleep 0.1; done"], timeout: 0.5, grace: 0.5, ownGroup: true),
                                    started: { p1 = $0 }) }
    check(r1! == nil && t1 < 3.5 && gone(p1) && groupGone(p1), "group: one that ignores SIGTERM: the group killed after the grace, all of it gone (\(String(format: "%.1f", t1)) s)")
    // a grandchild holding the output: when the program ends, the rest of its group is killed, so the output closes at once
    var r2: Ran?? = .none
    let t2 = took { r2 = Runner.run(Program("/bin/sh", ["-c", "sleep 20 & echo $!"], timeout: 10, keepOutput: true, drain: .infinity, ownGroup: true)) }
    let grand = pid_t(text(r2??.output ?? Data()).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    check(r2??.ok == true && r2??.complete == true && grand > 0 && t2 < 3 && gone(grand),
          "group: a grandchild that held the output is killed when the program ends; the output whole, no wait (\(String(format: "%.1f", t2)) s)")
    // stopped mid-run by the caller's poll: the whole group, the result says stopped
    var p3: pid_t = -1
    var r3: Ran?? = .none
    let t0 = Date()
    let t3 = took { r3 = Runner.run(Program("/bin/sh", ["-c", "sleep 20 & echo $!; sleep 20"], timeout: 30, keepOutput: true, ownGroup: true),
                                    poll: { Date().timeIntervalSince(t0) > 1.0 }, pollEvery: 0.05, started: { p3 = $0 }) }
    let grand3 = pid_t(text(r3??.output ?? Data()).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    check(r3??.stopped == true && r3??.ok == false && t3 < 3 && grand3 > 0 && gone(grand3) && gone(p3) && groupGone(p3),
          "group: stopped mid-run, the whole group gone, the result says stopped (\(String(format: "%.1f", t3)) s, \(String(describing: r3)))")
    // killAfterGrace false: only asked to end, left to end by itself after the grace (then reaped off the caller's thread)
    var p4: pid_t = -1
    var r4: Ran?? = .none
    let t4 = took { r4 = Runner.run(Program("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 0.3, grace: 0.3, killAfterGrace: false, ownGroup: true),
                                    started: { p4 = $0 }) }
    let left = kill(p4, 0) == 0
    kill(-p4, SIGKILL)
    check(r4! == nil && t4 < 2 && left && gone(p4), "group: killAfterGrace false: asked to end only, left running after the grace (then cleaned up here)")
    // killGroupOnEnd false: a normal end leaves what it started running (an updater, say); a timeout still ends the group
    let r5 = Runner.run(Program("/bin/sh", ["-c", "sleep 20 >/dev/null 2>&1 & echo $!"], timeout: 10, keepOutput: true, ownGroup: true, killGroupOnEnd: false))
    let kept = pid_t(text(r5?.output ?? Data()).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    let stillThere = kept > 0 && kill(kept, 0) == 0
    if kept > 0 { kill(kept, SIGKILL) }
    check(r5?.ok == true && stillThere, "group: killGroupOnEnd false: a normal end leaves what it started running (pid \(kept))")
    var p6: pid_t = -1
    let r6 = Runner.run(Program("/bin/sh", ["-c", "sleep 20 & sleep 20"], timeout: 0.5, grace: 0.5, ownGroup: true, killGroupOnEnd: false), started: { p6 = $0 })
    check(r6 == nil && gone(p6) && groupGone(p6), "group: killGroupOnEnd false: a timeout still ends the whole group")
}

// ============ 4e. the claude finder: stand-in files in the throwaway home, every look a closure ============
do {
    let fm = FileManager.default
    func make(_ path: String, _ text: String = "#!/bin/sh\n", mode: Int = 0o755) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    }
    let places = ClaudeFinder.usualPlaces(home: home)
    check(places == ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.local/bin/claude", home + "/.claude/local/claude",
                     home + "/.npm-global/bin/claude", home + "/.bun/bin/claude"], "the usual places, in their fixed order")
    var asked: [String] = []
    func lookup(_ candidates: [String], shell: String? = nil, more: [String] = [], npm: String? = nil, app: String? = nil) -> ClaudeFinder.Lookup {
        ClaudeFinder.Lookup(candidates: { asked.append("candidates"); return candidates }, shell: { asked.append("shell"); return shell },
                            more: { asked.append("more"); return more }, npmPrefix: { asked.append("npm"); return npm },
                            appCopy: { asked.append("app"); return app })
    }
    let local = home + "/.local/bin/claude", bun = home + "/.bun/bin/claude"
    make(local); make(bun)
    check(ClaudeFinder.find(lookup: lookup([home + "/.npm-global/bin/claude", local, bun])) == ClaudeFound(path: local) && asked == ["candidates"],
          "the first usual place there wins; nothing else is asked")
    asked = []
    check(ClaudeFinder.find(quick: true, lookup: lookup([], shell: local, app: bun)) == nil && asked == ["candidates"],
          "quick: only the usual places (no program run), never the app's copy")
    asked = []
    make(home + "/shell-claude")
    check(ClaudeFinder.find(lookup: lookup([], shell: home + "/shell-claude", more: [bun])) == ClaudeFound(path: home + "/shell-claude")
          && asked == ["candidates", "shell"], "then what the login shell finds")
    let npmPrefix = home + "/npm-prefix"
    make(npmPrefix + "/bin/claude")
    check(ClaudeFinder.find(lookup: lookup([], shell: "claude: aliased", more: [home + "/nowhere"], npm: npmPrefix))
            == ClaudeFound(path: npmPrefix + "/bin/claude"), "then Volta and nvm, then npm's prefix (an alias from the shell says nothing)")
    check(ClaudeFinder.find(lookup: lookup([], app: bun)) == ClaudeFound(path: bun, fromApp: true), "last, the app's own copy, said so")
    make(home + "/not-runnable", mode: 0o644)
    try? fm.createDirectory(atPath: home + "/a-folder", withIntermediateDirectories: true)
    check(!ClaudeFinder.isExecutable(home + "/not-runnable") && !ClaudeFinder.isExecutable(home + "/a-folder")
          && !ClaudeFinder.isExecutable("relative/claude") && ClaudeFinder.find(lookup: lookup([home + "/not-runnable"])) == nil,
          "never a file that can't run, a folder, or a relative path")
    // nvm's node versions, newest first, by number
    for v in ["v9.11.2", "v22.1.0", "v18.20.4"] { try? fm.createDirectory(atPath: home + "/.nvm/versions/node/\(v)/bin", withIntermediateDirectories: true) }
    check(ClaudeFinder.nvmNodeBins(home: home).map { ($0 as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? "" }
            == ["v22.1.0", "v18.20.4", "v9.11.2"]
          && ClaudeFinder.morePlaces(home: home).first == home + "/.volta/bin/claude", "Volta first, then nvm's newest node first")
    // the app's copy: a Mach-O only, a finished download first, then the newest
    let support = home + "/Support"
    func copy(_ app: String, _ v: String, _ id: String, machO: Bool = true) -> String {
        let p = support + "/\(app)/claude-code/\(v)/\(id)/claude.app/Contents/MacOS/claude"
        try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: p, contents: machO ? Data([0xCF, 0xFA, 0xED, 0xFE, 0, 0]) : Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return p
    }
    let script = copy("Claude", "2.1.400", "s", machO: false)
    check(ClaudeFinder.appCopy(support: support) == nil && !ClaudeFinder.isMachO(script), "a script in the app's folder is never taken")
    let old = copy("Claude", "2.1.300", "a"), newest = copy("Claude", "2.1.320", "b")
    check(ClaudeFinder.appCopy(support: support) == newest, "the newest Mach-O copy")
    fm.createFile(atPath: (old as NSString).deletingLastPathComponent + "/../../../../a.verified", contents: Data())
    check(ClaudeFinder.appCopy(support: support) == old, "a finished download (.verified) before a newer unfinished one")
}

// ============ 4f. the one allow-list for a claude run ============
do {
    var base = ["HOME": home, "USER": "sample", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "HTTPS_PROXY": "http://proxy.example.test:8080",
                "PATH": "/usr/bin::/sbin", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere", "ANTHROPIC_MODEL": "set", "NODE_OPTIONS": "--require x",
                "OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector.example.test", "AWS_ACCESS_KEY_ID": "made-up", "SSH_AUTH_SOCK": "/tmp/s"]
    for k in ProviderEnvironment.variables { base[k] = "set-by-the-shell" }
    let env = ClaudeEnvironment.make(base, claude: "/opt/sample/bin/claude", configDir: home + "/.claude-work")
    check(ProviderEnvironment.variables.allSatisfy { env[$0] == nil }
          && ["ANTHROPIC_MODEL", "NODE_OPTIONS", "OTEL_EXPORTER_OTLP_ENDPOINT", "AWS_ACCESS_KEY_ID", "SSH_AUTH_SOCK"].allSatisfy { env[$0] == nil },
          "an allow-list: no key, token, provider, model override, Node options, telemetry export, cloud credential or agent socket")
    check(env["HOME"] == home && env["USER"] == "sample" && env["LANG"] == "en_US.UTF-8" && env["LC_ALL"] == "en_US.UTF-8"
          && env["HTTPS_PROXY"] == "http://proxy.example.test:8080", "who and where the user is, the language, the proxies")
    check(env["CLAUDE_CONFIG_DIR"] == home + "/.claude-work" && ClaudeEnvironment.make(base, configDir: nil)["CLAUDE_CONFIG_DIR"] == nil,
          "the folder given, never the shell's; the default folder leaves it unset")
    check(env["PATH"] == "/opt/sample/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin:/sbin"
          && ClaudeEnvironment.make([:], configDir: nil)["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
          "claude's own folder, then the install places, then the caller's PATH without empty entries")
    check(env["DISABLE_TELEMETRY"] == "1" && env["DISABLE_ERROR_REPORTING"] == "1" && env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1"
          && env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == nil
          && ClaudeEnvironment.make(base, configDir: nil, traceless: true)["CLAUDE_CODE_AGENTS_MD_ROWS_EVERY_PROCESS"] == "1",
          "non-essential traffic off; traceless only when asked")
    let mtls = ["CLAUDE_CODE_CERT_STORE", "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY", "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE"]
    var corporate = base
    for k in mtls { corporate[k] = "/etc/sample/" + k.lowercased() }
    check(mtls.allSatisfy { ClaudeEnvironment.make(corporate, configDir: nil)[$0] == "/etc/sample/" + $0.lowercased() },
          "a company's certificate store and client certificate (mTLS, a TLS-inspecting proxy) are passed")
    check(ClaudeEnvironment.make(["PATH": "bin:./x:/usr/sbin::"], claude: "/claude", configDir: nil)["PATH"]
            == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin"
          && ClaudeEnvironment.make([:], claude: "claude", configDir: nil)["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
          "PATH: absolute entries only (no relative or empty one), never \"/\" for a claude at the root, nor a relative claude's folder")
    check(ClaudeFinder.lookupEnvironment([:], path: "/opt/sample/bin")["PATH"] == "/opt/sample/bin:/usr/bin:/bin"
          && ClaudeFinder.lookupEnvironment(["PATH": "rel::/sbin"], path: "/opt/sample/bin")["PATH"] == "/opt/sample/bin:/usr/bin:/bin:/sbin"
          && ClaudeFinder.lookupEnvironment(["ANTHROPIC_API_KEY": "made-up"], path: nil)["ANTHROPIC_API_KEY"] == nil,
          "the finder's programs: no trailing \":\" without a PATH, absolute entries only, no provider variable")
    // a finder program's output is taken only whole: one cut at the cap (1 MB) is no answer
    check(ClaudeFinder.output("/bin/sh", ["-c", "echo /opt/sample/bin/claude"], environment: [:], timeout: 5) == "/opt/sample/bin/claude"
          && ClaudeFinder.output("/bin/sh", ["-c", "head -c 1200000 /dev/zero | tr '\\0' a"], environment: ["PATH": "/usr/bin:/bin"], timeout: 10) == nil,
          "the finder's output: taken when whole, never when cut at the cap")
}

// ============ 4g. the short ask, with a stand-in claude (a shell script that answers its control requests) ============
do {
    let fm = FileManager.default
    let work = home + "/ask-work"
    try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
    func standIn(_ name: String, _ body: String) -> String {
        let p = home + "/" + name
        fm.createFile(atPath: p, contents: Data(("#!/bin/sh\n" + body).utf8), attributes: [.posixPermissions: 0o755])
        return p
    }
    let initialize = #"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"account":{"email":"wu@example.com","organization":"Example Team","subscriptionType":"max"}}}}"#
    let usage = #"{"type":"control_response","response":{"subtype":"success","request_id":"ask-2","response":{"rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":142.5,"resets_at":"2026-11-12T18:00:00.123456Z","locked_reason":null},"seven_day":{"utilization":68,"resets_at":"2026-11-14T09:00:00Z","locked_reason":"weekly_limit"}}}}}"#
    // it answers each request on its own line, records its arguments and what it was sent, and never sees a model message
    let seen = home + "/ask-seen.txt"
    let answering = standIn("claude-answers", """
        printf '%s\\n' "$*" > '\(seen)'
        pwd >> '\(seen)'
        printf 'traceless=%s,%s\\n' "$CLAUDE_CODE_AGENTS_MD_ROWS_EVERY_PROCESS" "$CLAUDE_CODE_DISABLE_AUTO_MEMORY" >> '\(seen)'
        echo '{"type":"system","subtype":"init"}'
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> '\(seen)'
          case "$line" in
            *'"initialize"'*) printf '%s\\n' '\(initialize)' ;;
            *'"get_usage"'*) printf '%s\\n' '\(usage)' ;;
          esac
        done
        """)
    // (made without the traceless pair: the ask adds it itself)
    let env = ClaudeEnvironment.make(["HOME": home, "PATH": "/usr/bin:/bin"], claude: answering, configDir: home + "/.claude-work")
    let a = ClaudeAsk.ask(claude: answering, environment: env, folder: work, usage: true, timeout: 10)
    check(a.end == .answered && a.account == ["email": "wu@example.com", "organization": "Example Team"], "initialize's account: \(a)")
    check(a.initialize == ClaudeAsk.Initialize(account: ["email": "wu@example.com", "organization": "Example Team"], models: nil),
          "initialize as it came: an account without a model list")
    check(a.stop == .inputClosed && a.exitStatus == 0 && !a.signaled,
          "the stop: its input closed, it ended by itself with status 0 (no signal needed)")
    check(a.limits?.available == true && a.limits?.fiveHour?.used == 100 && a.limits?.fiveHour?.locked == false
          && a.limits?.fiveHour?.resets == ClaudeAsk.isoDate("2026-11-12T18:00:00Z")
          && a.limits?.week == ClaudeAsk.Window(used: 68, resets: ClaudeAsk.isoDate("2026-11-14T09:00:00Z"), locked: true),
          "get_usage: clamped to 100, any fraction of a second read, a lock seen")
    let sent = (try? String(contentsOfFile: seen, encoding: .utf8)) ?? ""
    check(sent.hasPrefix(ClaudeAsk.arguments.joined(separator: " ")) && sent.contains("--no-session-persistence")
          && sent.contains(#""subtype":"initialize""#) && sent.contains(#""subtype":"get_usage""#) && !sent.contains(#""type":"user""#),
          "the ask's arguments, the two control requests, and never a model message: \(sent)")
    check(sent.contains(work), "it runs in the folder given")
    check(sent.contains("traceless=1,1"), "always traceless, whatever the environment passed: no marker, no memory folder in the profile")
    let one = ClaudeAsk.ask(claude: answering, environment: env, folder: work, usage: false, timeout: 10)
    check(one.end == .answered && one.account?["email"] == "wu@example.com" && one.limits == nil
          && !((try? String(contentsOfFile: seen, encoding: .utf8)) ?? "").contains("get_usage"), "initialize only: no get_usage asked")
    // silent: the timeout ends it, and the process is gone
    let pidFile = home + "/ask-silent.pid"
    let silent = standIn("claude-silent", "echo $$ > '\(pidFile)'\nwhile IFS= read -r line; do :; done\nexec sleep 30\n")
    var t = Date()
    let s = ClaudeAsk.ask(claude: silent, environment: env, folder: work, usage: true, timeout: 1, grace: 0.5)
    check(s.end == .timedOut && s.account == nil && Date().timeIntervalSince(t) < 4, "nothing said: timed out at its limit")
    check(s.stop == .terminated && s.signaled && s.exitStatus == SIGTERM && s.initialize == nil,
          "...its input closed didn't end it (it sleeps on): SIGTERM did, said so")
    let spid = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
    var spidGone = false
    let until = Date().addingTimeInterval(3)
    while spid > 0 && !spidGone && Date() < until { spidGone = kill(spid, 0) != 0; if !spidGone { usleep(50_000) } }
    check(spid > 0 && spidGone, "...and the stand-in was stopped (\(spid))")
    // ends before answering; an error to get_usage; an initialize answer naming nobody
    t = Date()
    let quits = ClaudeAsk.ask(claude: standIn("claude-quits", "exit 3\n"), environment: env, folder: work, usage: true, timeout: 10)
    check(quits.end == .exited && quits.stop == .byItself && quits.exitStatus == 3 && !quits.signaled
          && Date().timeIntervalSince(t) < 5, "it ends before answering: exited by itself, at once, its status 3")
    // one that ignores SIGTERM (an ignored signal stays ignored across exec): killed after the second grace
    t = Date()
    let stubborn = ClaudeAsk.ask(claude: standIn("claude-stubborn", "trap '' TERM\nwhile IFS= read -r line; do :; done\nexec sleep 30\n"),
                                 environment: env, folder: work, usage: true, timeout: 1, grace: 0.5)
    check(stubborn.end == .timedOut && stubborn.stop == .killed && stubborn.signaled && stubborn.exitStatus == SIGKILL
          && Date().timeIntervalSince(t) < 6, "one that ignores SIGTERM: killed (SIGKILL), said so")
    // one that answers only as it ends (once its input closes): the ask timed out, but what it wrote then is read; every
    // answer asked for came, so it is answered (grace 2 and a wide bound: a busy machine is slow to run the stand-in)
    let late = standIn("claude-late", """
        while IFS= read -r line; do :; done
        printf '%s\\n' '\(initialize)'
        """)
    t = Date()
    let lateAnswer = ClaudeAsk.ask(claude: late, environment: env, folder: work, usage: false, timeout: 1, grace: 2)
    check(lateAnswer.end == .answered && [.inputClosed, .terminated].contains(lateAnswer.stop)
          && lateAnswer.account?["email"] == "wu@example.com" && Date().timeIntervalSince(t) < 8,
          "after a timeout the last output is read: a complete late answer is answered")
    let lateUsage = ClaudeAsk.ask(claude: late, environment: env, folder: work, usage: true, timeout: 1, grace: 2)
    check(lateUsage.end == .timedOut && lateUsage.account?["email"] == "wu@example.com" && lateUsage.limits == nil,
          "...but with get_usage still unanswered: timed out, the late account kept")
    // a last line with no newline after it, as the output ends: read too
    let unended = standIn("claude-unended", """
        IFS= read -r line
        printf '%s' '\(initialize)'
        """)
    let u = ClaudeAsk.ask(claude: unended, environment: env, folder: work, usage: false, timeout: 10, grace: 2)
    check(u.end == .answered && u.account?["email"] == "wu@example.com", "a last line with no newline, read as the output ends")
    let refusing = standIn("claude-refuses", """
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) echo '{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"models":[],"account":{}}}}' ;;
            *'"get_usage"'*) echo '{"type":"control_response","response":{"subtype":"error","request_id":"ask-2","error":"not allowed"}}' ;;
          esac
        done
        """)
    let r = ClaudeAsk.ask(claude: refusing, environment: env, folder: work, usage: true, timeout: 10)
    check(r.end == .answered && r.account == [:] && r.limits == nil && r.usageError == "not allowed",
          "a key or token names nobody (an empty account); get_usage said no: answered, its error kept")
    check(r.initialize == ClaudeAsk.Initialize(account: [:], models: []) && r.stop == .inputClosed,
          "initialize as it came: an empty account and an empty model list")
    check(ClaudeAsk.initializeAnswer(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"models":[{"value":"haiku","displayName":"Haiku"},{"value":"opus"},7]}}}"#.utf8))
            == ClaudeAsk.Initialize(account: nil, models: ["haiku", "opus"])
          && ClaudeAsk.initializeAnswer(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{}}}"#.utf8)) == nil
          && ClaudeAsk.initializeAnswer(Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"ask-1","error":"x"}}"#.utf8)) == nil
          && ClaudeAsk.initializeAnswer(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-2","response":{"account":{}}}}"#.utf8)) == nil,
          "initializeAnswer: models without an account (their values); nothing for an empty answer, an error, or another request")
    check(ClaudeAsk.ask(claude: home + "/no-such-claude", environment: env, folder: work, usage: true).stop == nil,
          "couldn't start: no stop to say")
    check(ClaudeAsk.ask(claude: home + "/no-such-claude", environment: env, folder: work, usage: true).end == .couldNotStart
          && ClaudeAsk.ask(claude: answering, environment: env, folder: home + "/no-such-folder", usage: true).end == .couldNotStart
          && !fm.fileExists(atPath: home + "/no-such-folder"), "no claude, or no folder (never made): couldn't start")
    check(ClaudeAsk.ask(claude: answering, environment: env, folder: answering, usage: true).end == .couldNotStart,
          "a file given as the folder: couldn't start")
    // the parse alone
    check(ClaudeAsk.event(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"account":{"email":" wu@example.com ","organization":""}}}}"#.utf8))
            == .account(["email": "wu@example.com"])
          && ClaudeAsk.event(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"qc-9","response":{}}}"#.utf8)) == .ignored
          && ClaudeAsk.event(Data("not json".utf8)) == .ignored
          && ClaudeAsk.limits(["rate_limits": NSNull()]).available == false,
          "the parse: an account trimmed, an empty organisation left out; another request's answer and other lines ignored")
    check(ClaudeAsk.event(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{}}}"#.utf8)) == .ignored
          && ClaudeAsk.event(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"models":[]}}}"#.utf8)) == .account([:])
          && ClaudeAsk.event(Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"ask-1","response":{"account":{"email":"wu@example.com"}}}}"#.utf8)) == .account(["email": "wu@example.com"]),
          "initialize with neither models nor an account: ignored (not \"names nobody\"); models alone: names nobody; an account alone counts")
    check(ClaudeAsk.isoDate("2026-11-12T18:00:00+01:00") != nil && ClaudeAsk.isoDate("2026-11-12T18:00:00.5Z") == ClaudeAsk.isoDate("2026-11-12T18:00:00Z")
          && ClaudeAsk.isoDate("soon") == nil, "ISO dates: an offset, a fraction dropped, words never")
    check(String(decoding: ClaudeAsk.controlLine(id: "ask-1", subtype: "initialize"), as: UTF8.self)
            == #"{"request":{"subtype":"initialize"},"request_id":"ask-1","type":"control_request"}"# + "\n", "one control request, one line")
}

// ============ 5. lint: Run/ stays Foundation only, starts processes only here, never logs ============
do {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = repo.appendingPathComponent("Run")
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".swift") }
    check(files.count >= 2, "Run/'s sources found: \(files)")
    for f in files {
        let s = (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? ""
        let imports = s.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
        check(Set(imports).isSubset(of: ["Foundation"]), "\(f): imports Foundation only: \(imports)")
        for bad in ["print(", "NSLog", "Logger(", "os_log", "UserDefaults", "AppKit", "cl_audit", "usage-n-uf"] {
            check(!s.contains(bad), "\(f): no logging, no app's name, paths or storage (\(bad))")
        }
    }
}

print("runs: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
