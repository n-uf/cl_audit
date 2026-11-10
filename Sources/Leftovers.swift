// Leftovers: the Claude Code folders cl_audit 26.11.13 and earlier made for a profile's accounts (each standby account's
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
        /// Only a folder known to hold no sessions is offered for the Trash: sessions may be someone's work, and a folder
        /// whose sessions couldn't be counted (or aren't counted yet) may hold some.
        var trashable: Bool { inside.counted && inside.known && inside.sessions == 0 }
    }

    /// What a folder holds, counted from its names only (nothing is opened, no link is followed): Claude Code's sessions
    /// (its projects' transcripts), its account record, settings.json and CLAUDE.md, and whatever else is at its top.
    struct Inside: Equatable {
        var sessions = 0
        var settings = false
        var claudeMD = false
        var other = 0
        var record = false              // .claude.json: the account record (the sign-in itself is in the Keychain)
        var projects: Int?              // the folders in `projects`; nil: no `projects`
        /// false: `projects` is there but couldn't be listed, is a link (never followed), or held too much to count.
        var known = true
        /// false: not counted yet (the card counts off the main thread: LeftoverCounts).
        var counted = true

        /// The most names read for one folder: a bigger one counts as "couldn't be counted".
        static let cap = 5000

        static func of(_ path: String, fm: FileManager = .default, cap: Int = Inside.cap) -> Inside {
            let dir = expand(path)
            var i = Inside()
            var read = 0
            func kind(_ p: String) -> mode_t? { var st = stat(); return lstat(p, &st) == 0 ? st.st_mode & S_IFMT : nil }
            let projects = (dir as NSString).appendingPathComponent("projects")
            if let k = kind(projects) {
                if k != S_IFDIR { i.known = false }                      // a link or a file: never followed
                else if let names = try? fm.contentsOfDirectory(atPath: projects) {
                    let folders = names.filter { $0 != ".DS_Store" }
                    i.projects = folders.count
                    for p in folders {
                        read += 1
                        if read > cap { i.known = false; break }
                        let sub = (projects as NSString).appendingPathComponent(p)
                        switch kind(sub) {
                        case S_IFLNK: i.known = false                     // a project that is a link: not looked into
                        case S_IFDIR:
                            guard let files = try? fm.contentsOfDirectory(atPath: sub) else { i.known = false; continue }
                            read += files.count
                            i.sessions += files.filter { $0.hasSuffix(".jsonl") }.count
                            if read > cap { i.known = false }
                        default: break
                        }
                        if read > cap { break }
                    }
                } else { i.known = false }                               // there, but can't be listed
            }
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).prefix(cap) {
                switch n {
                case "settings.json": i.settings = true
                case "CLAUDE.md": i.claudeMD = true
                case ".claude.json": i.record = true
                case "projects", ".DS_Store": break
                default: i.other += 1
                }
            }
            return i
        }

        /// "the account record (.claude.json), projects (2 sessions), settings.json and 3 other items", in plain words.
        var words: String {
            func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }
            var parts: [String] = []
            if record { parts.append("the account record (.claude.json)") }
            if !known { parts.append("projects (its sessions couldn't be counted)") }
            else if let p = projects { parts.append(sessions > 0 ? "projects (\(n(sessions, "session", "sessions")))"
                                                               : p == 0 ? "projects (empty)" : "projects (\(n(p, "folder", "folders")), no sessions)") }
            if settings { parts.append("settings.json") }
            if claudeMD { parts.append("CLAUDE.md") }
            if other > 0 { parts.append(n(other, "other item", "other items")) }
            if parts.isEmpty { return "nothing" }
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

    /// A profile's leftover folders worth offering now. `inside`: what each holds (nil: not counted yet); the card passes
    /// LeftoverCounts' cache, so nothing is counted on the main thread.
    static func offered(_ e: AccountEntry, among accounts: [AccountEntry], inside: (String) -> Inside? = { Inside.of($0) }) -> [Folder] {
        e.leftoverFolders.filter { offerable($0, among: accounts) }.map {
            Folder(path: $0, keychainItem: keychainItem($0), inside: inside($0) ?? Inside(counted: false))
        }
    }

    /// The card's line for one.
    static func line(_ f: Folder) -> String {
        let p = tilde(expand(f.path)) + ": made by an earlier cl_audit for one of this profile's accounts."
        if !f.inside.counted { return p + " Looking at what's in it…" }
        if !f.inside.known {
            return p + " Its sessions couldn't be counted (its projects folder can't be read, or is a link), so it isn't offered for the Trash: open it in Finder to look first."
        }
        if f.inside.sessions > 0 {
            return p + " It holds \(f.inside.sessions == 1 ? "1 session" : "\(f.inside.sessions) sessions"), so it isn't offered for the Trash: open it in Finder to look first."
        }
        return p + " Nothing uses it now."
    }

    /// The question before Move to Trash.
    static func question(_ f: Folder) -> (title: String, detail: String) {
        ("Move \(tilde(expand(f.path))) to the Trash?",
         "In it: \(f.inside.words). Everything in it goes with it; you can put it back from the Trash. The sign-in itself isn't in the folder: Claude Code keeps it in your Keychain as “\(f.keychainItem)”. Delete that in Keychain Access if you no longer need it; cl_audit doesn't touch it.")
    }

    /// The check's seam: moves a folder to the Trash (recoverable).
    nonisolated(unsafe) static var toTrash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }

    /// Moves the folder to the Trash, checked again first (it may have changed since it was listed). Why not, or nil.
    static func trash(_ f: Folder, among accounts: [AccountEntry]) -> String? {
        guard offerable(f.path, among: accounts) else { return "\(tilde(expand(f.path))) isn't there as a plain folder any more, or a profile uses it now." }
        let now = Inside.of(f.path)
        guard now.known else { return "\(tilde(expand(f.path)))'s sessions couldn't be counted, so it stays: open it in Finder to look." }
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

/// What each folder from before holds, counted off the main thread: once each time the Accounts card appears, and again
/// when the folder's or its projects folder's modification time changes (two lstat calls per folder on the card's tick;
/// nothing else runs on the main thread). Move to Trash counts again at the click (Leftovers.trash).
@MainActor final class LeftoverCounts: ObservableObject {
    static let shared = LeftoverCounts()

    /// The folder's and its projects folder's modification times (lstat: a link's own), -1 when not there.
    struct Stamp: Equatable, Hashable {
        var dir: Double
        var projects: Double
    }

    nonisolated static func stamp(_ path: String) -> Stamp {
        func m(_ p: String) -> Double {
            var st = stat()
            guard lstat(p, &st) == 0 else { return -1 }
            return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        }
        let dir = expand(path)
        return Stamp(dir: m(dir), projects: m((dir as NSString).appendingPathComponent("projects")))
    }

    @Published private(set) var counts: [String: (stamp: Stamp, inside: Leftovers.Inside)] = [:]
    private var running: Set<String> = []

    /// What a folder holds, if counted since it last changed.
    func inside(_ path: String) -> Leftovers.Inside? {
        guard let c = counts[path], c.stamp == Self.stamp(path) else { return nil }
        return c.inside
    }

    /// Counts the folders not counted since they last changed, each off the main thread.
    func refresh(_ paths: [String]) {
        for p in paths where inside(p) == nil && !running.contains(p) {
            running.insert(p)
            let s = Self.stamp(p)
            Task.detached(priority: .utility) {
                let i = Leftovers.Inside.of(p)
                await MainActor.run {
                    self.running.remove(p)
                    self.counts[p] = (s, i)
                }
            }
        }
    }

    /// The card appeared: count its folders again.
    func recount(_ paths: [String]) {
        for p in paths where !running.contains(p) { counts[p] = nil }
        refresh(paths)
    }

    /// Renders and checks only: counts now, on this thread.
    func countNow(_ paths: [String]) {
        for p in paths { counts[p] = (Self.stamp(p), Leftovers.Inside.of(p)) }
    }
}
