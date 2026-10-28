// Cleanup: the cl_audit agent's automatic clean-up, at login, after every saved change and every 6 hours, whether or
// not the cl_audit window is open.
//
// It removes only what is provably cl_audit's: Dock icon apps in /Applications or ~/Applications (a bundle id under
// local.usage-n-uf. and a profile id in Info.plist) that no profile wants, second copies of a profile's app, the files
// macOS keeps under such an id in ~/Library (six places), saved usage of unknown profiles, Dock pins and recent-app
// entries of apps that are gone (one Dock change, only when there is one), and old Terminal scripts it wrote.
// Never: Claude Code folders, Claude window data folders, Keychain items, or anything without cl_audit's id. Dock
// icon apps of profiles with Usage in the Dock off are removed by the opening rules (Rules.swift), which also keep
// their Dock place. Fail safe: with the profiles file missing or unreadable nothing is removed, and an app installed
// or renamed in the last minute is left alone.

import AppKit

/// The clean-up, for General settings: when it last ran, and the last run that removed something.
struct CleanupRecord: Codable {
    var at: Date
    var removedAt: Date?
    var removed: [String]
}

enum Cleanup {
    static var recordURL: URL { Store.folder.appendingPathComponent("cleanup.json") }
    private static let queue = DispatchQueue(label: "local.usage-n-uf.cleanup", qos: .utility)

    static func lastRecord() -> CleanupRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(CleanupRecord.self, from: data)
    }

    /// Runs the sweep in the background (one at a time).
    static func runSoon(_ reason: String) { queue.async { _ = run(reason) } }

    /// The sweep. Blocks; call off the main thread. Returns what it removed, in words. `dry`: only says what it
    /// would remove (--cleanup --dry-run).
    @discardableResult
    static func run(_ reason: String, dry: Bool = false) -> [String] {
        guard Store.exists, let accounts = Store.loadChecked() else {
            agentLog.log("clean-up (\(reason, privacy: .public)): skipped, the profiles file is missing or can't be read")
            return []
        }
        let fm = FileManager.default
        var removed: [String] = []
        let ids = Set(accounts.map(\.id))
        let wanted = Dictionary(accounts.map { ($0.id, Installer.appURL($0).standardizedFileURL) }, uniquingKeysWith: { a, _ in a })
        func recent(_ u: URL) -> Bool {
            let d = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
            return d.map { Date().timeIntervalSince($0) < 60 } ?? true
        }

        // 1. Dock icon apps no profile wants, and second copies of a profile's app
        for (url, id) in Installer.installed() where !recent(url) {
            let name = url.deletingPathExtension().lastPathComponent
            if !ids.contains(id) {
                if !dry {
                    quit(url)
                    try? fm.removeItem(at: url)
                    Installer.run(AccountRemoval.lsregister, ["-u", url.path])
                    AccountRemoval.purgeFiles(id)
                }
                removed.append("\(name): the Dock icon app of a removed profile")
            } else if let w = wanted[id], w != url.standardizedFileURL, fm.fileExists(atPath: w.path), !recent(w) {
                if !dry {
                    quit(url)                 // only this copy (the profile's own app shares its bundle id)
                    try? fm.removeItem(at: url)
                    Installer.run(AccountRemoval.lsregister, ["-u", url.path])
                }
                removed.append("\(name): a second copy of a profile's Dock icon app")
            }
        }
        // 2. files macOS keeps for ids with no profile and no app (six places in ~/Library)
        let live = ids.union(Installer.installed().map(\.id))
        for id in AccountRemoval.orphanIDs(keeping: live) {
            if !dry { AccountRemoval.purgeFiles(id) }
            removed.append("files macOS kept for \(Installer.managerID).\(id)")
        }
        // 3. saved usage of unknown profiles
        for f in (try? fm.contentsOfDirectory(at: Store.statusFolder, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" && !ids.contains(f.deletingPathExtension().lastPathComponent) {
            if !dry { try? fm.removeItem(at: f) }
            removed.append("saved usage of \(f.deletingPathExtension().lastPathComponent)")
        }
        // 4. Dock pins and recent-app entries of Dock icon apps that are gone: one Dock change, only when there is one
        let stale = { (t: [String: Any]) -> Bool in
            DockManager.filePath(t).map { DockManager.isIconAppPath(URL(fileURLWithPath: $0)) && !fm.fileExists(atPath: $0) } ?? false
        }
        let now = DockWriter.backend.read()
        let n = now.pinned.filter(stale).count + now.recent.filter(stale).count
        if n > 0 && !dry {
            DockWriter.updateNow("clean-up: \(n) Dock entr\(n == 1 ? "y" : "ies") of apps that are gone") { l in
                l.pinned.removeAll(where: stale)
                l.recent.removeAll(where: stale)
            }
        }
        if n > 0 { removed.append("\(n) Dock entr\(n == 1 ? "y" : "ies") of apps that are gone") }
        // 5. Terminal scripts it wrote (sign-in, open in Terminal), older than a day
        let tmp = fm.temporaryDirectory
        for f in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.lastPathComponent.hasPrefix("usage-n-uf-") && f.pathExtension == "command" {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(d) > 86400 { if !dry { try? fm.removeItem(at: f) }; removed.append("old Terminal script \(f.lastPathComponent)") }
        }

        if dry { return removed }
        removed.forEach { agentLog.log("clean-up (\(reason, privacy: .public)): removed \($0, privacy: .public)") }
        if removed.isEmpty { agentLog.log("clean-up (\(reason, privacy: .public)): nothing to remove") }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970; enc.outputFormatting = [.sortedKeys]
        // a run with nothing to do keeps the last one that removed something
        let last = lastRecord()
        let record = removed.isEmpty ? CleanupRecord(at: Date(), removedAt: last?.removedAt, removed: last?.removed ?? [])
                                     : CleanupRecord(at: Date(), removedAt: Date(), removed: removed)
        if let data = try? enc.encode(record) { try? data.write(to: recordURL, options: .atomic) }
        return removed
    }

    /// Quits the app at exactly this place (not other copies with its bundle id), without its Claude window.
    private static func quit(_ url: URL) {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        guard !apps.isEmpty else { return }
        if let id = Installer.info(url)?["UsageAccountID"] as? String {
            DistributedNotificationCenter.default().postNotificationName(Installer.quietQuitNote, object: id, userInfo: nil, deliverImmediately: true)
            Thread.sleep(forTimeInterval: 0.3)
        }
        apps.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        apps.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// "Cleaned up 2 leftovers · Thu 09:00", or "Nothing to clean up · 11:38", for General settings, on one line
    /// ("2 removed · Thu 09:00", "All clean · Thu 09:00" when short). Within a week of a run that removed something:
    /// that run; otherwise when it last checked.
    static func summary(_ r: CleanupRecord?, short: Bool = false, now: Date = Date()) -> String {
        guard let r else { return "Not run yet" }
        if let at = r.removedAt, !r.removed.isEmpty, now.timeIntervalSince(at) < 7 * 86400 {
            let n = r.removed.count
            return (short ? "\(n) removed" : "Cleaned up \(n) leftover\(n == 1 ? "" : "s")") + " · \(when(at, now: now))"
        }
        return (short ? "All clean" : "Nothing to clean up") + " · \(when(r.at, now: now))"
    }

    /// A fixed, short time, as on the at-limit box (TimeWords.when).
    static func when(_ d: Date, now: Date = Date()) -> String { TimeWords.when(d, now: now) }
}
