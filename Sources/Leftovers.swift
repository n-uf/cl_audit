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
    /// One folder offered: its path as recorded, the name of the Keychain item that holds its sign-in, and what is in it.
    struct Folder: Equatable, Identifiable {
        let path: String
        let keychainItem: String
        var inside = Inside()
        var id: String { path }
        /// A folder that holds sessions is never offered for the Trash: they may be someone's work.
        var trashable: Bool { inside.sessions == 0 }
    }

    /// What a folder holds, counted from its names only (nothing is opened): Claude Code's sessions (its projects'
    /// transcripts), its settings.json and CLAUDE.md, and whatever else is at its top.
    struct Inside: Equatable {
        var sessions = 0
        var settings = false
        var claudeMD = false
        var other = 0

        static func of(_ path: String, fm: FileManager = .default) -> Inside {
            let dir = expand(path)
            var i = Inside()
            let projects = (dir as NSString).appendingPathComponent("projects")
            for p in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
                i.sessions += ((try? fm.contentsOfDirectory(atPath: (projects as NSString).appendingPathComponent(p))) ?? []).filter { $0.hasSuffix(".jsonl") }.count
            }
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
                switch n {
                case "settings.json": i.settings = true
                case "CLAUDE.md": i.claudeMD = true
                case "projects", ".claude.json", ".DS_Store": break
                default: i.other += 1
                }
            }
            return i
        }

        /// "its sign-in record, settings.json, CLAUDE.md and 3 other items", in plain words.
        var words: String {
            func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
            var parts = ["its sign-in record"]
            if sessions > 0 { parts.append(n(sessions, "session", "sessions")) }
            if settings { parts.append("settings.json") }
            if claudeMD { parts.append("CLAUDE.md") }
            if other > 0 { parts.append(n(other, "other item", "other items")) }
            return parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
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
        e.leftoverFolders.filter { offerable($0, among: accounts) }.map { Folder(path: $0, keychainItem: keychainItem($0), inside: Inside.of($0)) }
    }

    /// The card's line for one.
    static func line(_ f: Folder) -> String {
        let p = tilde(expand(f.path))
        if !f.trashable {
            return "\(p): made by an earlier cl_audit for one of this profile's sign-ins. It holds \(f.inside.sessions == 1 ? "1 session" : "\(f.inside.sessions) sessions"), so it isn't offered for the Trash: open it in Finder to look first."
        }
        return "\(p): made by an earlier cl_audit for one of this profile's sign-ins. Nothing uses it now."
    }

    /// The question before Move to Trash.
    static func question(_ f: Folder) -> (title: String, detail: String) {
        ("Move \(tilde(expand(f.path))) to the Trash?",
         "In it: \(f.inside.words). Everything in it goes with it; you can put it back from the Trash. Its sign-in stays in your Keychain as “\(f.keychainItem)”: delete that in Keychain Access if you no longer need it. cl_audit doesn't touch it.")
    }

    /// The check's seam: moves a folder to the Trash (recoverable).
    nonisolated(unsafe) static var toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Moves the folder to the Trash, checked again first (it may have changed since it was listed). Why not, or nil.
    static func trash(_ f: Folder, among accounts: [AccountEntry]) -> String? {
        guard offerable(f.path, among: accounts) else { return "\(tilde(expand(f.path))) isn't there as a plain folder any more, or a profile uses it now." }
        let now = Inside.of(f.path)
        guard now.sessions == 0 else { return "\(tilde(expand(f.path))) holds sessions now, so it stays: open it in Finder to look." }
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
