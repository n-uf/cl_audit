// Leftovers: the Claude Code folders cl_audit 26.11.12 and earlier made for a profile's accounts (each standby account's
// own sign-in, ~/.claude-<name>, and the account in use's kept one). A profile is one folder now and its standby accounts
// are signed out, so those folders are no longer used. They are the person's: listed on the profile's Accounts card, each
// with Move to Trash… (recoverable from the Trash) and Keep it, never deleted silently.
//
// A folder's sign-in is in the Keychain, as Claude Code names it after the folder's path ("Claude Code-credentials-" and
// the first 8 hex characters of the path's SHA-256: Account.keychainServices, as Claude Code's program text has it).
// cl_audit never touches that item, never reads it and never signs the folder out: the alert names it so the person can
// delete it in Keychain Access if they like.

import AppKit

enum Leftovers {
    /// One folder offered: its path as recorded, and the name of the Keychain item that holds its sign-in.
    struct Folder: Equatable, Identifiable {
        let path: String
        let keychainItem: String
        var id: String { path }
    }

    /// The Keychain item Claude Code keeps a folder's sign-in in (named only; never read).
    static func keychainItem(_ path: String) -> String {
        Account(AccountEntry(id: "leftover", name: "", label: "", configDir: path)).keychainServices.first ?? "Claude Code-credentials"
    }

    /// Whether a path may be offered: only a folder named like the ones cl_audit made (`~/.claude-<name>`, directly in the
    /// home folder), still there, a plain folder (never a link or a file), never ~/.claude, and no profile's Claude Code
    /// folder or Claude window folder (nor inside or around one). A hand-edited list naming any other folder offers nothing.
    static func offerable(_ path: String, among accounts: [AccountEntry]) -> Bool {
        let p = expand(path)
        let name = (p as NSString).lastPathComponent
        guard !path.isEmpty, name.hasPrefix(".claude-"), name.count > ".claude-".count,
              (p as NSString).deletingLastPathComponent == NSHomeDirectory() else { return false }
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, !Account.isDefault(configDir: p) else { return false }
        if FolderRules.configOwner(p, among: accounts) != nil { return false }
        return !accounts.contains { a in
            [a.desktopDataDir, a.desktop == .standard ? FolderKey.standardDataDir : ""].contains { !$0.isEmpty && FolderKey.overlaps($0, p) }
        }
    }

    /// A profile's leftover folders worth offering now.
    static func offered(_ e: AccountEntry, among accounts: [AccountEntry]) -> [Folder] {
        e.leftoverFolders.filter { offerable($0, among: accounts) }.map { Folder(path: $0, keychainItem: keychainItem($0)) }
    }

    /// The card's line for one.
    static func line(_ f: Folder) -> String {
        "\(tilde(expand(f.path))): a folder an earlier cl_audit made for a sign-in of this profile's. It isn't used any more."
    }

    /// The question before Move to Trash.
    static func question(_ f: Folder) -> (title: String, detail: String) {
        ("Move \(tilde(expand(f.path))) to the Trash?",
         "Its sign-in stays in your Keychain as “\(f.keychainItem)”: delete that in Keychain Access if you no longer need it. cl_audit doesn't touch it. You can put the folder back from the Trash.")
    }

    /// The check's seam: moves a folder to the Trash (recoverable).
    nonisolated(unsafe) static var toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Moves the folder to the Trash, checked again first (it may have changed since it was listed). Why not, or nil.
    static func trash(_ f: Folder, among accounts: [AccountEntry]) -> String? {
        guard offerable(f.path, among: accounts) else { return "\(tilde(expand(f.path))) isn't there as a plain folder any more, or a profile uses it now." }
        do { try toTrash(URL(fileURLWithPath: expand(f.path))); return nil }
        catch { return "\(tilde(expand(f.path))) couldn't be moved to the Trash: \(error.localizedDescription)" }
    }

    /// The profile without that folder on its list (after Move to Trash or Keep it).
    static func dropping(_ path: String, from e: AccountEntry) -> AccountEntry {
        var out = e
        out.leftoverFolders.removeAll { FolderKey.canonical($0) == FolderKey.canonical(path) || $0 == path }
        return out
    }
}
