// Runs · a program in a process group of its own (`Program.ownGroup`): started with posix_spawn as the leader of a new group,
// its input, output and errors set up as the program asks and every other descriptor of the caller closed, so nothing of the
// caller's leaks into it. It is stopped as a group: SIGTERM to all of it, then SIGKILL to all of it after the grace. When the
// leader ends, whatever of its group is still running is killed before the leader is reaped (while it is unreaped its pid, the
// group's id, can't be given to anyone else, so the kill never reaches a stranger), unless it ended by itself and
// `killGroupOnEnd` is false (then only a timeout or a stop ends the group). A program that left something behind holding its
// output (a filter, a pager, a helper) then never keeps the caller waiting or outlives the run. Same rules as Runner.run
// otherwise: the timeout, the grace, the poll, the drain, the caps, `Ran` as it ended. A leader left to end by itself
// (`killAfterGrace` false, or stuck in the kernel) is dealt with the same way when it does end, off the caller's thread, with no
// thread held meanwhile (a process source).
//
// One rule for the whole process: nothing else may reap its children (no waitpid(-1), no SIGCHLD ignored), or a leader's pid could
// be given away while the group is still signalled by it. A leader found already reaped is taken as gone, its status unknown, and
// nothing is sent to its group.

import Foundation

extension Runner {
    static func runGroup(_ p: Program, poll: () -> Bool, pollEvery: TimeInterval, started: (pid_t) -> Void) -> Ran? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var childSides: [Int32] = [], ourSides: [Int32] = []
        func closeAll() { (childSides + ourSides).forEach { close($0) } }
        /// One of the program's standard descriptors: a pipe (our end returned) or /dev/null.
        func wire(_ fd: Int32, pipe wanted: Bool, reading: Bool) -> Int32? {
            guard wanted else {
                return posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", reading ? O_RDONLY : O_WRONLY, 0) == 0 ? -1 : nil
            }
            var f: [Int32] = [0, 0]
            guard pipe(&f) == 0 else { return nil }
            // close-on-exec in the caller: a program another thread starts meanwhile never gets an end of them (dup2 clears it
            // on the program's own 0, 1, 2)
            f.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
            let (theirs, ours) = reading ? (f[0], f[1]) : (f[1], f[0])
            childSides.append(theirs); ourSides.append(ours)
            return posix_spawn_file_actions_adddup2(&actions, theirs, fd) == 0 ? ours : nil
        }
        guard let inW = wire(0, pipe: p.input != nil, reading: true),
              let outR = wire(1, pipe: p.keepOutput, reading: false),
              let errR = wire(2, pipe: p.keepErrors, reading: false) else { closeAll(); return nil }
        if let dir = p.folderURL?.path, posix_spawn_file_actions_addchdir_np(&actions, dir) != 0 { closeAll(); return nil }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // a group of its own; only what the file actions set up is passed (CLOEXEC_DEFAULT); signals as a fresh program has them
        // (the caller may ignore SIGPIPE: the program doesn't), none blocked
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        let env = p.environment ?? ProcessInfo.processInfo.environment
        let argv: [UnsafeMutablePointer<CChar>?] = ([p.executable] + p.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        // a program that ends before reading its input must not take the caller with it
        if p.input != nil { signal(SIGPIPE, SIG_IGN) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, p.executable, &actions, &attr, argv, envp)
        childSides.forEach { close($0) }; childSides = []
        guard rc == 0 else { closeAll(); return nil }
        started(pid)

        let out = Capture(cap: p.outputCap), err = Capture(cap: p.outputCap), read = DispatchGroup()
        for (fd, box) in [(outR, out), (errR, err)] where fd >= 0 {
            read.enter()
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            DispatchQueue.global(qos: .utility).async { box.drain(h); read.leave() }
        }
        if inW >= 0, let data = p.input {
            let h = FileHandle(fileDescriptor: inW, closeOnDealloc: true)
            DispatchQueue.global(qos: .utility).async { try? h.write(contentsOf: data); try? h.close() }
        }

        let begun = Date(), deadline = begun.addingTimeInterval(p.timeout)
        var nextPoll = begun, stoppedByPoll = false                                  // asked first right away
        while !ended(pid) && Date() < deadline {
            if Date() >= nextPoll {
                if poll() { stoppedByPoll = !ended(pid); break }                     // (already ended by itself: not stopped)
                nextPoll = Date().addingTimeInterval(pollEvery)
            }
            usleep(Date().timeIntervalSince(begun) < 0.5 ? 5_000 : 20_000)
        }
        var status: Int32??
        if ended(pid) { status = finish(pid, killGroup: p.killGroupOnEnd) }          // ended by itself
        else {
            status = stopGroup(pid, grace: p.grace, kill: p.killAfterGrace)
            if !stoppedByPoll { return nil }                                          // its time ran out
            if status == nil { return Ran(status: -1, complete: outR < 0, stopped: true) }   // left to end by itself
        }
        // (SIGKILL has been sent to what was left of the group, unless it ended by itself with `killGroupOnEnd` false: what it
        // printed closes; anything still holding it is waited for the drain at most)
        if outR >= 0 || errR >= 0 {
            if p.drain.isInfinite { read.wait() } else { _ = read.wait(timeout: .now() + p.drain) }
        }
        let o = out.snapshot(), e = err.snapshot()
        // a leader someone else reaped: gone, how it ended unknown (never read as a clean exit)
        guard let s = status ?? nil else { return Ran(status: -1, output: o.data, errors: e.data, complete: false, stopped: stoppedByPoll) }
        let sig = s & 0x7f
        return Ran(status: sig == 0 ? (s >> 8) & 0xff : sig, signaled: sig != 0 && !stoppedByPoll,
                   output: o.data, errors: e.data, complete: outR < 0 || o.whole, stopped: stoppedByPoll)
    }

    /// The group's leader: still running, ended and not yet reaped (its pid still the group's), or gone (someone else reaped it).
    enum Leader { case running, ended, gone }
    static func leader(_ pid: pid_t) -> Leader {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid ? .ended : .running }
            if errno != EINTR { return .gone }                                        // ECHILD: not ours to wait for any more
        }
    }
    static func ended(_ pid: pid_t) -> Bool { leader(pid) != .running }

    /// The leader has ended: whatever of its group is left is killed (unless `killGroup` is false: a normal end that leaves it
    /// running), then the leader is reaped. Its raw wait status; nil when it was already gone (then nothing is sent: its pid may
    /// be someone else's).
    static func finish(_ pid: pid_t, killGroup: Bool = true) -> Int32? {
        guard leader(pid) == .ended else { return nil }
        if killGroup { kill(-pid, SIGKILL) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return nil }
        }
        return status
    }

    /// Stops the group: SIGTERM to all of it; after `grace`, SIGKILL to all of it (unless `kill` is false); the leader is waited
    /// for a second more. `.some(status)` when it ended (its raw wait status, nil if someone else reaped it); nil when it is
    /// still running (left to end by itself, or stuck in the kernel): then, when it does end, the rest of its group is killed and
    /// it is reaped, off the caller's thread, by a process source (no thread held meanwhile).
    static func stopGroup(_ pid: pid_t, grace: TimeInterval, kill doKill: Bool) -> Int32?? {
        kill(-pid, SIGTERM)
        let until = Date().addingTimeInterval(grace)
        while !ended(pid) && Date() < until { usleep(5_000) }
        if doKill, !ended(pid) {
            kill(-pid, SIGKILL)
            let reaped = Date().addingTimeInterval(1)
            while !ended(pid) && Date() < reaped { usleep(5_000) }
        }
        if ended(pid) { return .some(finish(pid)) }
        reapLater(pid)
        return nil
    }

    /// When a leader left running ends: the rest of its group killed, then reaped. Once, whichever notices first (the source's
    /// exit event, or a check right after it is set up, for a leader that ended in between).
    static func reapLater(_ pid: pid_t) {
        let once = Once()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        func done() {
            guard once.first() else { return }
            _ = finish(pid)
            src.setEventHandler(handler: nil)
            src.cancel()
        }
        src.setEventHandler { done() }
        src.resume()
        if ended(pid) { done() }
    }
}

/// True the first time only, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
