// SignInFiles: the files that say which account is signed in, watched, so a sign-in changed in Terminal, an editor or the
// Claude app is followed within a second (the 3-second look stays as the backstop). Claude Code rewrites a folder's
// .claude.json by renaming a new file over it, and the Claude app its config.json the same way, so the folder each sits in
// is watched (a vnode source on the directory: a rename into it is a write to it), never the file's contents. Changes
// come in bursts: one call per second at most.
// A watch is on the folder that was there when it was opened: a folder deleted or moved away (and maybe made again) is
// let go at once and opened again by its path, and a folder not there yet (Logs/Claude before the Claude app's first run, a
// profile's folder before its first sign-in) is looked for every `retryEvery` seconds until it is; one that comes (back)
// counts as a change.

import Foundation

final class SignInFiles {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let onChange: () -> Void
    private var pending = false
    /// The folders asked for (the last `watch`), opened or not yet.
    private var wanted: Set<String> = []
    private var retry: Timer?
    /// How often a folder not there (or let go) is looked for again.
    nonisolated(unsafe) static var retryEvery: TimeInterval = 5

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    deinit { retry?.invalidate(); sources.values.forEach { $0.cancel() } }

    /// The folders watched now (opened); the rest of `watch`'s are looked for again (checks).
    var watching: Set<String> { Set(sources.keys) }

    /// The folders to watch for these profiles: each Claude Code folder's .claude.json's folder (the home folder for
    /// ~/.claude) and each Claude window's data folder (its config.json).
    static func folders(_ accounts: [AccountEntry]) -> [String] {
        var out: [String] = []
        for e in accounts {
            out.append((Account.claudeJSON(configDir: e.configDir) as NSString).deletingLastPathComponent)
            if e.claudeWindow {
                let dir = e.desktop == .standard ? expand(FolderKey.standardDataDir) : (Account(e).claudeUserDataDir ?? "")
                if !dir.isEmpty { out.append(dir) }
            }
        }
        // the Claude app's logs (AppSignIn reads its account lines): a sign-in or sign-out in the app is followed too
        if accounts.contains(where: \.claudeWindow) { out.append(AppSignIn.logsDir.path) }
        var seen = Set<String>()
        return out.filter { seen.insert(FolderKey.canonical($0)).inserted }
    }

    /// Watches exactly these profiles' folders (call again when the profiles change). On the main thread.
    func watch(_ accounts: [AccountEntry]) { watch(folders: Self.folders(accounts)) }

    /// Watches exactly these folders (the profiles' through `watch(_:)`; checks give their own). On the main thread.
    func watch(folders: [String]) {
        wanted = Set(folders)
        for (p, s) in sources where !wanted.contains(p) { s.cancel(); sources[p] = nil }
        for p in wanted where sources[p] == nil { _ = open(p) }
        lookAgainWhileMissing()
    }

    /// Opens the watch on folder `p` as it is now; false when it isn't there (or can't be opened).
    private func open(_ p: String) -> Bool {
        let fd = Darwin.open(p, O_EVTONLY)
        guard fd >= 0 else { return false }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            // the folder itself deleted or moved away: this watch is on what was there, so let it go and open the path again
            if !s.data.isDisjoint(with: [.delete, .rename]) { self.lost(p, s) }
            self.changed()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        sources[p] = s
        return true
    }

    /// The watch on `p` saw its folder go: closed, and opened again by the path (at once when a folder is there again, else
    /// at the next look).
    private func lost(_ p: String, _ s: DispatchSourceFileSystemObject) {
        guard sources[p] === s else { return }
        s.cancel(); sources[p] = nil
        if wanted.contains(p) { _ = open(p) }
        lookAgainWhileMissing()
    }

    /// While a folder asked for isn't watched, it is looked for every `retryEvery` seconds; none missing, no timer.
    private func lookAgainWhileMissing() {
        guard wanted.contains(where: { sources[$0] == nil }) else { retry?.invalidate(); retry = nil; return }
        guard retry == nil else { return }
        retry = Timer.scheduledTimer(withTimeInterval: Self.retryEvery, repeats: true) { [weak self] _ in self?.lookAgain() }
    }

    /// One look for the folders not watched: one that is there now is watched, and counts as a change (its files may
    /// have been written meanwhile).
    func lookAgain() {
        var came = false
        for p in wanted where sources[p] == nil { if open(p) { came = true } }
        if came { changed() }
        lookAgainWhileMissing()
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.onChange()
        }
    }
}
