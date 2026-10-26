// DockWriter: the one way cl_audit, its Dock icon apps and their helper processes change the Dock's lists.
//
// The Dock keeps its lists in memory and saves them as it quits, so a list written while it runs can be lost
// when it restarts (several writes within seconds made that happen). Every change therefore goes through here:
// one writer at a time (a lock file shared by all cl_audit processes), the lists read fresh, the change applied,
// the Dock restarted and waited for, and the change applied again to what the Dock kept. When the Dock lost it,
// it is written again (three tries at most). Changes say what the lists should become ("pin X", "drop Y"), so
// applying one again to a list that already has it changes nothing.

import AppKit

enum DockWriter {
    /// The Dock's two lists of apps: pinned (persistent-apps) and recently used (recent-apps).
    struct Lists {
        var pinned: [[String: Any]]
        var recent: [[String: Any]]
        func same(_ o: Lists) -> Bool { (pinned as NSArray).isEqual(o.pinned) && (recent as NSArray).isEqual(o.recent) }
    }

    /// Where the lists live and how the Dock is restarted (the real Dock, or a stand-in for tests).
    struct Backend {
        var read: () -> Lists
        var write: (Lists) -> Void
        /// Restarts the Dock and returns once the new one has started and settled.
        var restart: () -> Void
    }

    static var backend = Backend.dock
    static var lockURL = Store.folder.appendingPathComponent("dock.lock")
    /// Command-line runs (--sync, --pin) end right after their work, so they change the Dock before returning.
    static var inline = false

    private static let queue = DispatchQueue(label: "local.usage-n-uf.dock-writer", qos: .utility)

    /// Changes the Dock's lists in the background (inline for command-line runs). `done` gets whether the Dock
    /// ended up as asked; it's called on the main thread.
    static func update(_ what: String, _ change: @escaping (inout Lists) -> Void, done: ((Bool) -> Void)? = nil) {
        if inline { let ok = updateNow(what, change); done?(ok); return }
        queue.async {
            let ok = updateNow(what, change)
            if let done { DispatchQueue.main.async { done(ok) } }
        }
    }

    /// The same, waiting for it (off the main thread, or in a helper process).
    @discardableResult
    static func updateNow(_ what: String, _ change: (inout Lists) -> Void, tries: Int = 3) -> Bool {
        let lock = Lock(lockURL)
        defer { lock.release() }
        var wrote = 0
        for _ in 1...tries {
            let now = backend.read()
            var next = now
            change(&next)
            if next.same(now) {
                if wrote > 0 { dockLog.log("\(what, privacy: .public): kept by the Dock after \(wrote) write(s)") }
                return true
            }
            if wrote > 0 { dockLog.log("\(what, privacy: .public): the Dock lost the change, writing again") }
            dockLog.log("\(what, privacy: .public): writing \(next.pinned.count) pins, restarting the Dock")
            backend.write(next)
            backend.restart()
            wrote += 1
        }
        // the last restart: did it keep it?
        var check = backend.read()
        let before = check
        change(&check)
        let ok = check.same(before)
        dockLog.log("\(what, privacy: .public): \(ok ? "kept" : "still not kept", privacy: .public) after \(wrote) write(s)")
        return ok
    }

    /// An exclusive lock on a file, held by one process (and thread) at a time; waits up to a minute for it.
    private final class Lock {
        private var fd: Int32 = -1
        init(_ url: URL) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fd = Darwin.open(url.path, O_RDWR | O_CREAT, 0o600)
            guard fd >= 0 else { return }
            let deadline = Date().addingTimeInterval(60)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        }
        func release() { if fd >= 0 { flock(fd, LOCK_UN); Darwin.close(fd); fd = -1 } }
    }
}

extension DockWriter.Backend {
    /// The real Dock.
    static let dock = DockWriter.Backend(
        read: {
            let d = "com.apple.dock" as CFString
            CFPreferencesAppSynchronize(d)
            return DockWriter.Lists(
                pinned: CFPreferencesCopyAppValue("persistent-apps" as CFString, d) as? [[String: Any]] ?? [],
                recent: CFPreferencesCopyAppValue("recent-apps" as CFString, d) as? [[String: Any]] ?? [])
        },
        write: { l in
            let d = "com.apple.dock" as CFString
            CFPreferencesSetAppValue("persistent-apps" as CFString, l.pinned as CFArray, d)
            CFPreferencesSetAppValue("recent-apps" as CFString, l.recent as CFArray, d)
            CFPreferencesAppSynchronize(d)
        },
        restart: {
            let old = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            Installer.run("/usr/bin/killall", ["Dock"])
            // the new Dock: started (another process id) and given a moment to read and settle its lists
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                if let a = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
                   a.processIdentifier != old, a.isFinishedLaunching { break }
            }
            Thread.sleep(forTimeInterval: 2)
        })
}
