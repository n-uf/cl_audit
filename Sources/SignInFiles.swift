// SignInFiles: the files that say which account is signed in, watched, so a sign-in changed in Terminal, an editor or the
// Claude app is followed within a second (the 3-second look stays as the backstop). Claude Code rewrites a folder's
// .claude.json by renaming a new file over it, and the Claude app its config.json the same way, so the folder each sits in
// is watched (a vnode source on the directory: a rename into it is a write to it), never the file's contents. Changes
// come in bursts: one call per second at most.

import Foundation

final class SignInFiles {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let onChange: () -> Void
    private var pending = false

    init(onChange: @escaping () -> Void) { self.onChange = onChange }

    deinit { sources.values.forEach { $0.cancel() } }

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
    func watch(_ accounts: [AccountEntry]) {
        let want = Set(Self.folders(accounts))
        for (p, s) in sources where !want.contains(p) { s.cancel(); sources[p] = nil }
        for p in want where sources[p] == nil {
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in self?.changed() }
            s.setCancelHandler { close(fd) }
            s.resume()
            sources[p] = s
        }
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
