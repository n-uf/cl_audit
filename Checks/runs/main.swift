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
