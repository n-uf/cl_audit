// Runs · the runner: one way to run a program and get its exit status and what it printed. By default the program runs in
// the temporary folder with no input and its errors dropped; past its timeout it is asked to end (SIGTERM), then killed
// (SIGKILL) if it hasn't within its grace, and waited for (never left running, never a thread held for good). What it prints
// is read while it runs (so a program that prints a lot never blocks on a full pipe), up to a cap. A caller can keep its
// errors too, give it input, keep its own working folder, check every so often whether to stop it, and hear its pid as it
// starts. For a program that keeps running and is talked to, see RunningProgram (Running.swift).
//
// Runs sits below ClaudeAuth and the app's own process code, which both run through it; Foundation and Process only (and
// posix_spawn for a program in a group of its own, `ownGroup`: Group.swift), no
// app's paths or words, so another app can build it from source too. ProfileCore never depends on it. The one process-wide
// setting it touches: a run with input (and a RunningProgram) ignores SIGPIPE, for good, so a program that ends without
// reading never takes the caller with it.

import Foundation

/// A program to run.
public struct Program: Equatable {
    /// Where it runs.
    public enum Folder: Equatable {
        /// The temporary folder (nothing of the caller's folder for it to touch).
        case temporary
        /// The caller's own working folder.
        case inherited
        case at(String)
    }

    public var executable: String
    public var arguments: [String]
    /// nil: the caller's own environment.
    public var environment: [String: String]?
    public var folder: Folder
    /// Written to its input, which is then closed (a password goes this way, never as an argument); nil: no input.
    public var input: Data?
    /// Asked to end after this many seconds (`.infinity`: never).
    public var timeout: TimeInterval
    /// Killed this many seconds after it was asked to end and hadn't (`.infinity`: waited for, however long).
    public var grace: TimeInterval
    /// false: after the grace it is left to end by itself (never SIGKILL), and not waited for any more.
    public var killAfterGrace: Bool
    /// Keep what it prints (up to `outputCap` bytes); false: dropped.
    public var keepOutput: Bool
    /// Keep what it writes to its errors (up to `outputCap` bytes); false: dropped.
    public var keepErrors: Bool
    public var outputCap: Int
    /// After it ended, what it printed is read for at most this long more (a program it started may hold the output open;
    /// `.infinity`: until the output closes).
    public var drain: TimeInterval
    /// Runs in a process group of its own, with every other descriptor of the caller closed (Group.swift): stopped as a group
    /// (SIGTERM to all of it, SIGKILL to all of it after the grace), and whatever of the group is left when it ends is killed
    /// (unless `killGroupOnEnd` is false), so nothing it started (a filter, a pager, a helper) outlives it or keeps its output
    /// open. Opt-in; false: one process.
    public var ownGroup: Bool
    /// With `ownGroup`: whatever of the group is left when the program ends by itself is killed too (true), or left to run on
    /// (false: only a timeout or a stop ends the group; what it left running on a normal end, an updater say, finishes its work).
    public var killGroupOnEnd: Bool

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil, folder: Folder = .temporary,
                input: Data? = nil, timeout: TimeInterval, grace: TimeInterval = 5, killAfterGrace: Bool = true,
                keepOutput: Bool = false, keepErrors: Bool = false, outputCap: Int = 1 << 20, drain: TimeInterval = 1, ownGroup: Bool = false,
                killGroupOnEnd: Bool = true) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.folder = folder
        self.input = input; self.timeout = timeout; self.grace = grace; self.killAfterGrace = killAfterGrace
        self.keepOutput = keepOutput; self.keepErrors = keepErrors; self.outputCap = outputCap; self.drain = drain
        self.ownGroup = ownGroup; self.killGroupOnEnd = killGroupOnEnd
    }

    /// The working folder as a URL (nil: the caller's own).
    var folderURL: URL? {
        switch folder {
        case .temporary: return FileManager.default.temporaryDirectory
        case .inherited: return nil
        case .at(let p): return URL(fileURLWithPath: p)
        }
    }
}

/// How a program ended.
public struct Ran: Equatable {
    /// Its exit status, or the signal that ended it (`signaled`).
    public var status: Int32
    /// Ended by a signal it didn't get from the runner (it crashed, or something else stopped it).
    public var signaled: Bool
    /// What it printed (empty unless `keepOutput`).
    public var output: Data
    /// What it wrote to its errors (empty unless `keepErrors`).
    public var errors: Data
    /// All it printed was read (its output closed within the drain) and none of it was cut at the cap. Always true when the
    /// output isn't kept. A caller that needs the whole text (a sign-in read) refuses a result that isn't.
    public var complete: Bool
    /// The caller's poll asked it to stop, and it was stopped (`status` is then how it ended after that).
    public var stopped: Bool

    public init(status: Int32, signaled: Bool = false, output: Data = Data(), errors: Data = Data(), complete: Bool = true,
                stopped: Bool = false) {
        self.status = status; self.signaled = signaled; self.output = output; self.errors = errors; self.complete = complete
        self.stopped = stopped
    }

    /// Ended by itself with status 0.
    public var ok: Bool { status == 0 && !signaled && !stopped }
}

public enum Runner {
    /// Runs `p` and returns how it ended; nil when it couldn't start or ran out of time (then it was stopped). Blocks: call
    /// off the main thread. `poll`: asked every `pollEvery` seconds while it runs; true stops it (SIGTERM, the grace, …) and
    /// the result says `stopped`. `started`: told its pid as soon as it runs (a caller that can stop everything it started).
    public static func run(_ p: Program, poll: () -> Bool = { false }, pollEvery: TimeInterval = 0.2,
                           started: (pid_t) -> Void = { _ in }) -> Ran? {
        if p.ownGroup { return runGroup(p, poll: poll, pollEvery: pollEvery, started: started) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: p.executable)
        proc.arguments = p.arguments
        if let env = p.environment { proc.environment = env }
        if let dir = p.folderURL { proc.currentDirectoryURL = dir }
        let inPipe = p.input == nil ? nil : Pipe()
        proc.standardInput = inPipe ?? FileHandle.nullDevice
        let outPipe = p.keepOutput ? Pipe() : nil, errPipe = p.keepErrors ? Pipe() : nil
        proc.standardOutput = outPipe ?? FileHandle.nullDevice
        proc.standardError = errPipe ?? FileHandle.nullDevice
        let out = Capture(cap: p.outputCap), err = Capture(cap: p.outputCap), read = DispatchGroup()
        // a program that ends before reading its input must not take the caller with it
        if inPipe != nil { signal(SIGPIPE, SIG_IGN) }
        guard (try? proc.run()) != nil else { return nil }
        started(proc.processIdentifier)
        for (pipe, box) in [(outPipe, out), (errPipe, err)] {
            guard let pipe else { continue }
            read.enter()
            DispatchQueue.global(qos: .utility).async { box.drain(pipe.fileHandleForReading); read.leave() }
        }
        // the input on its own queue: a program that doesn't read it never holds up the timeout or the poll
        if let inPipe, let data = p.input {
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        let begun = Date(), deadline = begun.addingTimeInterval(p.timeout)
        var nextPoll = begun, stoppedByPoll = false                                  // asked first right away
        while proc.isRunning && Date() < deadline {
            if Date() >= nextPoll {
                if poll() { stoppedByPoll = proc.isRunning; break }                  // (already ended by itself: not stopped)
                nextPoll = Date().addingTimeInterval(pollEvery)
            }
            // its end noticed within 5 ms at first (a quick tool on the main thread), then every 20 ms
            usleep(Date().timeIntervalSince(begun) < 0.5 ? 5_000 : 20_000)
        }
        if proc.isRunning && !stoppedByPoll { stop(proc, grace: p.grace, kill: p.killAfterGrace); return nil }
        if stoppedByPoll {
            stop(proc, grace: p.grace, kill: p.killAfterGrace)
            // left to end by itself: nothing of its output is whole
            if proc.isRunning { return Ran(status: -1, complete: outPipe == nil, stopped: true) }
        }
        // (a reader still blocked after the drain, on a pipe a child of the program holds open, ends when that child does)
        if outPipe != nil || errPipe != nil {
            if p.drain.isInfinite { read.wait() } else { _ = read.wait(timeout: .now() + p.drain) }
        }
        let o = out.snapshot(), e = err.snapshot()
        return Ran(status: proc.terminationStatus, signaled: proc.terminationReason == .uncaughtSignal && !stoppedByPoll,
                   output: o.data, errors: e.data, complete: outPipe == nil || o.whole, stopped: stoppedByPoll)
    }

    /// Stops a running program: asked to end (SIGTERM), then, if it hasn't within `grace` seconds, killed (SIGKILL); then
    /// waited for, a second at most (a killed program is gone by then; one stuck in the kernel isn't waited on for good).
    /// `kill` false: only asked to end, and waited for the grace at most (`.infinity`: until it ends).
    public static func stop(_ p: Process, grace: TimeInterval, kill doKill: Bool = true) {
        guard p.isRunning else { return }
        p.terminate()
        let until = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < until { usleep(5_000) }
        guard doKill else { return }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        let reaped = Date().addingTimeInterval(1)
        while p.isRunning && Date() < reaped { usleep(5_000) }
    }

    /// Waits for a program to end without running the run loop (`waitUntilExit` runs it, and on the main thread that can
    /// redraw a SwiftUI window in the middle of an update).
    public static func waitQuietly(_ p: Process) { while p.isRunning { usleep(5_000) } }
}

/// What a program writes to one of its pipes, read while it runs, up to a cap.
final class Capture: @unchecked Sendable {
    private var data = Data(), eof = false, cut = false
    private let lock = NSLock(), cap: Int

    init(cap: Int) { self.cap = cap }

    /// Reads `h` to its end.
    func drain(_ h: FileHandle) {
        while true {
            let d = h.availableData
            lock.lock()
            if d.isEmpty { eof = true; lock.unlock(); return }
            if data.count + d.count > cap { cut = true }
            if data.count < cap { data.append(d.prefix(cap - data.count)) }
            lock.unlock()
        }
    }

    /// What was read so far, and whether it is all of it (its end reached, nothing cut).
    func snapshot() -> (data: Data, whole: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (data, eof && !cut)
    }
}
