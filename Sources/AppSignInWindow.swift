// AppSignInWindow: AppSignIn for a profile's own Claude window. Its data folder, its launch and whether it is the only Claude
// app running come from the app (the running apps through Processes); the files are read by AppSignIn.

import AppKit
import ProfileCore

extension AppSignIn {
    /// `current(for:)` kept a few seconds per profile (the log grows all the time; a screen asks on every tick), and read
    /// again at once when the data folder's config.json changes or the window starts or quits.
    private static var memo: [String: (key: String, at: Date, login: Login)] = [:]
    private static let memoLock = NSLock()

    static func cached(for e: AccountEntry, now: Date = Date()) -> Login {
        let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
        let cfg = (try? FileManager.default.attributesOfItem(atPath: (dir as NSString).appendingPathComponent("config.json")))?[.modificationDate] as? Date
        let running = Processes.claudeApps().filter { !$0.isTerminated }
            .map { "\($0.processIdentifier)" }.sorted().joined(separator: ",")
        let key = "\(e.claudeWindow)|\(dir)|\(cfg?.timeIntervalSince1970 ?? 0)|\(running)"
        memoLock.lock()
        let hit = memo[e.id]
        memoLock.unlock()
        if let h = hit, h.key == key, now.timeIntervalSince(h.at) < 10 { return h.login }
        let l = current(for: e)
        memoLock.lock(); memo[e.id] = (key, now, l); memoLock.unlock()
        return l
    }

    /// The profile's own window: its data folder, launch and whether it is the only Claude app running.
    static func current(for e: AccountEntry) -> Login {
        guard e.claudeWindow else { return .unknown }
        let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
        guard !dir.isEmpty else { return .unknown }
        let apps = Processes.claudeApps().filter { !$0.isTerminated }
        let mine = apps.first { Launcher.isWindow(of: Account(e), $0) }
        return current(dataDir: dir, launched: mine?.launchDate, onlyApp: apps.count == 1 && mine != nil)
    }
}
