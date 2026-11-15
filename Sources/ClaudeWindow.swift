// ClaudeWindow: the one place that finds, opens, quits and reopens a profile's Claude window (the Claude app started with the
// profile's own data folder, or the usual one). A window is found by its data folder (Launcher.isWindow: the --user-data-dir it
// was started with, read from the kernel); it is opened by Launcher.openClaude (which keeps a window a run holds closed); it is
// quit with Claude's own quit (it may ask about work under way), and a quit is confirmed by process identity, pid and start
// time, so a pid given to another process meanwhile never counts as the window still open, and a new instance of the same window
// never counts as closed.
//
// WindowHold is one flow's hold on a window (a switch, a restore, a re-point, the default-profile move): it marks the window
// (SwitchMarker: no opener starts it meanwhile, a second run on it is refused), closes it and watches it close (every half
// second, a stall after 45 s), and when the flow ends lets the mark go and reopens the window it closed (when the profile has its
// Claude window on). Cancelled while the window closes, it watches a minute more and reopens it if it does close then.
// Main thread only.

import AppKit

enum ClaudeWindow {
    /// One running instance of a window: its pid and when it started (a pid alone can be reused).
    struct Instance: Equatable { var pid: pid_t; var started: Int? }

    /// How windows are found, quit and opened (a check's seam; the real ones by default).
    struct Seams {
        var find: (Account) -> [Instance]
        var quit: (pid_t) -> Void
        var open: (Account, Bool) -> Void
        var isRunning: (Instance) -> Bool

        static let real = Seams(
            // (isTerminated is updated on the main thread only: the process table says whether it still runs, from any thread)
            find: { a in Processes.claudeWindows(of: a).filter { !$0.isTerminated && Processes.runs($0.processIdentifier) }
                        .map { Instance(pid: $0.processIdentifier, started: Processes.startTime(of: $0.processIdentifier)) } },
            quit: { pid in NSRunningApplication(processIdentifier: pid)?.terminate() },
            open: { a, activate in Launcher.openClaude(a, activate: activate) },
            isRunning: { i in Processes.runs(i.pid) && Processes.startTime(of: i.pid) == i.started })
    }
    nonisolated(unsafe) static var seams = Seams.real

    /// The window's instances now.
    static func instances(_ a: Account) -> [Instance] { seams.find(a) }
    static func isOpen(_ a: Account) -> Bool { !instances(a).isEmpty }

    /// Brings the window to the front, or starts it (behind the window in front with `activate` false).
    static func open(_ a: Account, activate: Bool = true) { seams.open(a, activate) }

    /// Asks the window to quit (Claude's own quit: it may ask about work under way), and doesn't wait. The instances asked.
    @discardableResult
    static func quit(_ a: Account) -> [Instance] {
        let asked = instances(a)
        asked.forEach { seams.quit($0.pid) }
        return asked
    }

    /// Asks every Claude window to quit, every profile's and the usual one (Claude's own quit), and doesn't wait.
    static func quitAll() { Processes.claudeApps().forEach { $0.terminate() } }

    /// Whether the instances asked to quit are gone (by pid and start time) and no instance of the window is there now.
    static func closed(_ asked: [Instance], _ a: Account) -> Bool {
        !asked.contains(where: seams.isRunning) && instances(a).isEmpty
    }

    /// A switch is settled (linked, undone or left as it is): the Claude window it closed opens again, when the profile has its
    /// Claude window on and nothing has opened it since. While a run still marks the window (the switch's own runner until it
    /// ends, an Undo until it lets go, another run such as a restore) it waits, every half second for ten minutes at most, and opens it once the
    /// mark is gone; never in its place (no jump to that run's page). Once per switch, whichever process gets there first (the
    /// app or the agent, SwitchEngine.claimReopen). `activate`: false in the agent. Set as SwitchEngine.settled by both.
    static func afterSwitch(_ r: SwitchReceipt, activate: Bool) {
        guard r.closedWindow == true else { return }
        let until = Date().addingTimeInterval(reopenWait)
        func attempt() {
            guard let e = Store.load().first(where: { $0.id == r.profile }), e.claudeWindow else { return }
            let a = Account(e)
            if SwitchMarker.blocks(a) {
                guard Date() < until else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + reopenEvery) { attempt() }
                return
            }
            guard !isOpen(a), SwitchEngine.claimReopen(r.id) else { return }
            open(a, activate: activate)
        }
        DispatchQueue.main.async { attempt() }
    }
    nonisolated(unsafe) static var reopenWait: TimeInterval = 600
    nonisolated(unsafe) static var reopenEvery: TimeInterval = 0.5

    /// Asks the window to quit and waits up to `seconds` for it to close; whether it did. Blocks: off the main thread only.
    static func quitAndWait(_ a: Account, seconds: TimeInterval) -> Bool {
        let asked = quit(a)
        let until = Date().addingTimeInterval(seconds)
        while !closed(asked, a) && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        return closed(asked, a)
    }
}

/// One flow's hold on a profile's Claude window: its mark, its close, and reopening what it closed. Main thread only.
final class WindowHold {
    let account: Account
    /// The profile has its Claude window on (a window it closed is reopened only then).
    let reopens: Bool
    let key: String
    let profile: String
    let run: String
    /// This hold asked the window to quit (it was open when the flow began).
    private(set) var closedByUs = false
    private var asked: [ClaudeWindow.Instance] = []
    private var timer: Timer?
    private var watch: Timer?
    /// How often the window is looked at while it closes, and how long until it counts as stalled (a check's seam).
    nonisolated(unsafe) static var every: TimeInterval = 0.5
    nonisolated(unsafe) static var stallAfter: TimeInterval = 45
    nonisolated(unsafe) static var lateCloseFor: TimeInterval = 60

    init(_ e: AccountEntry, profile: String, run: String) {
        account = Account(e); reopens = e.claudeWindow; key = Launcher.dataDirKey(of: account)
        self.profile = profile; self.run = run
    }

    deinit { timer?.invalidate(); watch?.invalidate() }

    /// The window has no instance now.
    var isClosed: Bool { !ClaudeWindow.isOpen(account) }

    /// Marks the window for this run; false when another run holds it.
    func claim() -> Bool { SwitchMarker.claim(key, profile: profile, standby: run) }
    /// Takes this run's mark off the window (only this run's).
    func release() { SwitchMarker.release(key, profile: profile, standby: run) }

    /// Asks the window to quit and watches it close: `closed` once every instance asked is gone and none is there (at once when
    /// it was already closed: then this hold didn't close it, unless `askedBefore`: an earlier try of the same flow asked it to
    /// quit and it closed by its own answer since); `stalled` after `stallAfter` seconds, the mark let go first.
    func close(askedBefore: Bool = false, closed: @escaping () -> Void, stalled: @escaping () -> Void) {
        stopWatching()
        if isClosed { closedByUs = askedBefore; closed(); return }
        closedByUs = true
        asked = ClaudeWindow.quit(account)
        let started = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if ClaudeWindow.closed(self.asked, self.account) { t.invalidate(); self.timer = nil; closed(); return }
            if Date().timeIntervalSince(started) > Self.stallAfter {
                t.invalidate(); self.timer = nil
                self.release()
                self.closedByUs = false                       // still open: nothing to reopen
                stalled()
            }
        }
    }

    /// Whether this hold is watching the window close.
    var isClosing: Bool { timer != nil }

    /// The flow ends (done, failed or stopped): the mark let go, then the window reopened when this hold closed it and the profile
    /// has its Claude window. Once: a second call reopens nothing.
    func finish() {
        timer?.invalidate(); timer = nil
        release()
        guard closedByUs else { return }
        closedByUs = false
        // (opened meanwhile, or another run's mark on it now: left as it is, never that run's page instead)
        if reopens, isClosed, !SwitchMarker.blocks(account) { ClaudeWindow.open(account) }
    }

    /// Cancelled while the window closes: the watch stops and the mark goes; the window was already asked to quit, so if it does
    /// close within `lateCloseFor` seconds it is opened again (unless `busy` says a new run took it meanwhile). Whether a late
    /// close is being watched for (the profile has its Claude window on).
    @discardableResult
    func cancelClosing(busy: @escaping () -> Bool = { false }, watched: (() -> Void)? = nil) -> Bool {
        timer?.invalidate(); timer = nil
        release()
        let was = closedByUs
        closedByUs = false
        guard was, reopens else { return false }
        let since = Date()
        stopWatching()
        // (the watch keeps this hold alive until it ends, at most `lateCloseFor`: its caller may have let go of it already)
        watch = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { t in
            let over: Bool = {
                guard !busy() else { return true }
                if self.isClosed {
                    if !SwitchMarker.blocks(self.account) { ClaudeWindow.open(self.account) }
                    return true
                }
                return Date().timeIntervalSince(since) > Self.lateCloseFor
            }()
            guard over else { return }
            t.invalidate()
            self.watch = nil
            watched?()
        }
        return true
    }

    /// Stops watching for a late close (a new run starts).
    func stopWatching() { watch?.invalidate(); watch = nil }
    var isWatching: Bool { watch != nil }
}
