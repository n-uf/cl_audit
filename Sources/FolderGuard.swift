// FolderGuard: never a `claude` (or the Claude app with CLAUDE_CONFIG_DIR) for a Claude Code folder that isn't there.
// Claude Code would make the folder again, signed in, and a folder the person deleted would come back (2026-11-10: a deleted
// kept folder's sign-in was renewed after the folder was gone). Every launcher asks `mayLaunch` right before it starts
// anything: Renew sign-in, logout, quick chat, Terminal, the Claude window, a sign-in. Self-contained (the quick chat's own
// checks compile it with the engine alone).

import Foundation
import os

enum FolderGuard {
    private static let log = Logger(subsystem: "local.usage-n-uf", category: "agent")

    /// The default folder (~/.claude, used with CLAUDE_CONFIG_DIR unset) is always fine. Any other must be there as a plain
    /// folder, never a link. `creating`: a sign-in the person started for a new folder, which makes it (owner only) first.
    static func folderReady(_ configDir: String, creating: Bool = false) -> Bool {
        let p = (configDir as NSString).expandingTildeInPath
        let def = ("~/.claude" as NSString).expandingTildeInPath
        if URL(fileURLWithPath: p).standardizedFileURL.path == def { return true }
        var st = stat()
        if lstat(p, &st) == 0 { return (st.st_mode & S_IFMT) == S_IFDIR }
        guard creating else { return false }
        return (try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil
    }

    /// For reading only: the folder is there as a folder, a link to one included (a profile or kept folder may be a link
    /// to the real one). Launching and creating keep refusing links (`folderReady`).
    static func isFolder(_ configDir: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (configDir as NSString).expandingTildeInPath, isDirectory: &isDir) && isDir.boolValue
    }

    /// The check's seam: told of every launch the guard lets through ("renew", "logout", "login", …, and the folder); its
    /// answer decides whether the launch goes on (a check answers false: nothing starts).
    nonisolated(unsafe) static var launchSeam: ((_ what: String, _ configDir: String) -> Bool)?

    /// The guard, then the seam: true when the launch may go on.
    static func mayLaunch(_ what: String, _ configDir: String, creating: Bool = false) -> Bool {
        guard folderReady(configDir, creating: creating) else {
            log.log("not starting \(what, privacy: .public): its Claude Code folder isn't there")
            return false
        }
        if let seam = launchSeam { return seam(what, configDir) }
        return true
    }
}
