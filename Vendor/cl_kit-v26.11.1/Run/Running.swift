// Runs · a running program: one that keeps running and is talked to (a chat's `claude`). Started once, written to, read as
// it writes (each chunk of its output and of its errors handed over in order, off the main thread), and told when it has
// ended. A program that dies never takes the caller with it: writes to a closed pipe fail quietly (SIGPIPE is ignored).
// Stopping it closes its input, asks it to end (SIGTERM) and kills it (SIGKILL) if it hasn't within the grace, without
// blocking the caller.

import Foundation

public final class RunningProgram {
    public let program: Program
    /// Each chunk of what it prints, in order, on a background queue; then once with nil at its end.
    public var onOutput: (Data?) -> Void = { _ in }
    /// Each chunk of what it writes to its errors, in order, on a background queue.
    public var onErrors: (Data) -> Void = { _ in }
    /// Its end, after its output ended (status, ended by a signal), on a background queue.
    public var onExit: (Int32, Bool) -> Void = { _, _ in }
    /// After its output ended, how long to wait for the rest of its errors before `onExit` (they come on their own pipe).
    public var errorsSettle: TimeInterval = 0.05

    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var stopping = false

    /// `program`'s executable, arguments, environment and folder are used (its input, timeout and caps aren't: it keeps
    /// running until it ends or is stopped).
    public init(_ program: Program) { self.program = program }

    public var isRunning: Bool { process.isRunning }
    public var pid: Int32 { process.processIdentifier }

    /// Starts it; throws when it can't start.
    public func start(outputQoS: DispatchQoS.QoSClass = .userInitiated) throws {
        signal(SIGPIPE, SIG_IGN)
        process.executableURL = URL(fileURLWithPath: program.executable)
        process.arguments = program.arguments
        if let env = program.environment { process.environment = env }
        if let dir = program.folderURL { process.currentDirectoryURL = dir }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let out = output.fileHandleForReading, err = errors.fileHandleForReading
        // its output to its end, then its exit; read with read(2), which reports a failed read as an error rather than raising
        DispatchQueue.global(qos: outputQoS).async { [self] in
            while let chunk = Self.read(out) { onOutput(chunk) }
            onOutput(nil)
            Runner.waitQuietly(process)
            usleep(useconds_t(min(max(0, errorsSettle), 5) * 1_000_000))   // the last of its errors (5 s at most)
            onExit(process.terminationStatus, process.terminationReason == .uncaughtSignal)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let chunk = Self.read(err) {
                guard let self else { return }
                self.onErrors(chunk)
            }
        }
    }

    /// What's there to read, as soon as some is; nil at the end or on an error.
    static func read(_ h: FileHandle) -> Data? {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(h.fileDescriptor, &buf, buf.count)
            if n > 0 { return Data(buf[0..<n]) }
            if n < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Writes to its input. False when it is gone or being stopped (the pipe is closed).
    @discardableResult
    public func write(_ data: Data) -> Bool {
        lock.lock(); let closed = stopping; lock.unlock()
        guard !closed, process.isRunning else { return false }
        do { try input.fileHandleForWriting.write(contentsOf: data); return true } catch { return false }
    }

    /// Ends it: closes its input, asks it to end (SIGTERM), and kills it (SIGKILL) if it is still running `grace` seconds
    /// later. Returns at once; the kill holds the process itself, so the caller may let go of this object right away.
    public func stop(grace: TimeInterval) {
        lock.lock(); let already = stopping; stopping = true; lock.unlock()
        guard !already, process.isRunning else { return }
        try? input.fileHandleForWriting.close()
        process.terminate()
        let p = process
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}
