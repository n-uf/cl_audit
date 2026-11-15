// Runs · the runner: one way to run a program and get its exit status and what it printed. The program runs in the
// temporary folder with no input and its errors dropped; past its timeout it is asked to end (SIGTERM), then killed
// (SIGKILL) if it hasn't within its grace, and waited for (never left running, never a thread held for good). What it prints
// is read while it runs (so a program that prints a lot never blocks on a full pipe), up to a cap.
//
// Runs sits below ClaudeAuth and the app's own process code, which both run through it; Foundation and Process only, no
// app's paths, words or global state, so another app can build it from source too. ProfileCore never depends on it.

import Foundation

/// A program to run.
public struct Program: Equatable {
    public var executable: String
    public var arguments: [String]
    /// nil: the caller's own environment.
    public var environment: [String: String]?
    /// Asked to end after this many seconds.
    public var timeout: TimeInterval
    /// Killed this many seconds after it was asked to end and hadn't.
    public var grace: TimeInterval
    /// Keep what it prints (up to `outputCap` bytes); false: dropped.
    public var keepOutput: Bool
    public var outputCap: Int
    /// After it ended, what it printed is read for at most this long more (a program it started may hold the output open).
    public var drain: TimeInterval

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil, timeout: TimeInterval,
                grace: TimeInterval = 5, keepOutput: Bool = false, outputCap: Int = 1 << 20, drain: TimeInterval = 1) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.timeout = timeout
        self.grace = grace; self.keepOutput = keepOutput; self.outputCap = outputCap; self.drain = drain
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
    /// All it printed was read (its output closed within the drain) and none of it was cut at the cap. Always true when the
    /// output isn't kept. A caller that needs the whole text (a sign-in read) refuses a result that isn't.
    public var complete: Bool

    public init(status: Int32, signaled: Bool = false, output: Data = Data(), complete: Bool = true) {
        self.status = status; self.signaled = signaled; self.output = output; self.complete = complete
    }

    /// Ended by itself with status 0.
    public var ok: Bool { status == 0 && !signaled }
}

public enum Runner {
    /// Runs `p` and returns how it ended; nil when it couldn't start or ran out of time (then it was stopped). Blocks: call
    /// off the main thread.
    public static func run(_ p: Program) -> Ran? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: p.executable)
        proc.arguments = p.arguments
        if let env = p.environment { proc.environment = env }
        proc.currentDirectoryURL = FileManager.default.temporaryDirectory
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = p.keepOutput ? Pipe() : nil
        proc.standardOutput = pipe ?? FileHandle.nullDevice
        final class Box: @unchecked Sendable { var data = Data(); var eof = false; var cut = false; let lock = NSLock() }
        let box = Box(), read = DispatchGroup(), cap = p.outputCap
        guard (try? proc.run()) != nil else { return nil }
        if let pipe {
            read.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                while true {
                    let d = h.availableData
                    box.lock.lock()
                    if d.isEmpty { box.eof = true; box.lock.unlock(); break }
                    if box.data.count + d.count > cap { box.cut = true }
                    if box.data.count < cap { box.data.append(d.prefix(cap - box.data.count)) }
                    box.lock.unlock()
                }
                read.leave()
            }
        }
        let deadline = Date().addingTimeInterval(p.timeout)
        while proc.isRunning && Date() < deadline { usleep(20_000) }
        if proc.isRunning { stop(proc, grace: p.grace); return nil }
        // (a reader still blocked after the drain, on a pipe a child of the program holds open, ends when that child does)
        if pipe != nil { _ = read.wait(timeout: .now() + p.drain) }
        box.lock.lock(); let out = box.data, complete = pipe == nil || (box.eof && !box.cut); box.lock.unlock()
        return Ran(status: proc.terminationStatus, signaled: proc.terminationReason == .uncaughtSignal, output: out, complete: complete)
    }

    /// Stops a running program: asked to end (SIGTERM), then, if it hasn't within `grace` seconds, killed (SIGKILL); then
    /// waited for, a second at most (a killed program is gone by then; one stuck in the kernel isn't waited on for good).
    public static func stop(_ p: Process, grace: TimeInterval) {
        guard p.isRunning else { return }
        p.terminate()
        let until = Date().addingTimeInterval(grace)
        while p.isRunning && Date() < until { usleep(5_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        let reaped = Date().addingTimeInterval(1)
        while p.isRunning && Date() < reaped { usleep(5_000) }
    }

    /// Waits for a program to end without running the run loop (`waitUntilExit` runs it, and on the main thread that can
    /// redraw a SwiftUI window in the middle of an update).
    public static func waitQuietly(_ p: Process) { while p.isRunning { usleep(5_000) } }
}
