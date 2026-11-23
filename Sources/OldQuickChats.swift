// OldQuickChats: what cl_audit's own quick chat left behind, now that cl_quick is the one quick chat (ClQuick). Its work
// folders and settings (usage-n-uf/quick-chat/) and, in each profile's Claude Code folder, the projects/ folder its chats
// were kept in (Claude Code's name for that profile's work folder, usage-n-uf/quick-chat/<profile id>). Once, at the
// agent's first start of a build without the chat, the empty ones go to the Trash. Ones that hold anything stay until the
// person moves them to the Trash from Settings ▸ General ▸ Backups (one quiet line, with Show in Finder); their chats stay
// out of counts and backups meanwhile, as they always did. Never deleted outright, never through a link, and whatever
// can't be read is taken to hold something: it is left alone.

import AppKit
import SwiftUI

enum OldQuickChats {
    /// The quick chat's own folder: its work folders, one per profile, and its settings.json.
    static var folder: URL { Store.folder.appendingPathComponent("quick-chat") }
    static let tidiedKey = "oldQuickChatsTidied"

    /// How a folder goes to the Trash (never deleted outright). Checks give their own throwaway one, never the real Trash.
    nonisolated(unsafe) static var toTrash: (URL) -> Bool = { (try? FileManager.default.trashItem(at: $0, resultingItemURL: nil)) != nil }

    /// Claude Code's name for a project folder: every character but an ASCII letter or digit becomes "-".
    static func projectKey(_ path: String) -> String {
        String(path.utf16.map { u -> Character in
            guard u < 128, let s = Unicode.Scalar(u), s.properties.isAlphabetic || ("0"..."9").contains(s) else { return "-" }
            return Character(s)
        })
    }

    /// The exact name of the projects/ folder the old chat kept a profile's chats in.
    static func projectName(_ profileID: String) -> String { projectKey(folder.appendingPathComponent(profileID).path) }

    /// A path inside a profile's projects/ ("<project>" or "<project>/<file>") that is in its old chat folder: left out of
    /// counts and backups.
    static func isOldProject(_ rel: String, profile: String) -> Bool {
        (rel.split(separator: "/", maxSplits: 1).first).map(String.init) == projectName(profile)
    }

    private static func kind(_ url: URL) -> mode_t? {
        var st = stat()
        return lstat(url.path, &st) == 0 ? st.st_mode & S_IFMT : nil
    }
    private static func isFolder(_ url: URL) -> Bool { kind(url) == S_IFDIR }

    /// A folder holds something: any entry inside, at any depth, that isn't a folder (a file, a link, a pipe, a socket),
    /// `.DS_Store` aside. A folder that can't be read counts as holding something (it is left alone).
    static func holdsFiles(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        for n in names where n != ".DS_Store" {
            let u = url.appendingPathComponent(n)
            guard let k = kind(u) else { return true }
            if k != S_IFDIR || holdsFiles(u) { return true }
        }
        return false
    }

    /// The chats (Claude Code's .jsonl transcripts) inside a folder, for the line's count; links aren't followed.
    static func chats(in url: URL) -> Int {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return 0 }
        var n = 0
        for name in names {
            let u = url.appendingPathComponent(name)
            switch kind(u) {
            case S_IFDIR: n += chats(in: u)
            case S_IFREG: if u.pathExtension == "jsonl" { n += 1 }
            default: break
            }
        }
        return n
    }

    /// The old chat folders in the profiles' Claude Code folders: exactly each profile's name, directly in projects/.
    static func projectFolders(_ entries: [AccountEntry]) -> [URL] {
        entries.compactMap { e in
            let u = URL(fileURLWithPath: Account(e).configDir).appendingPathComponent("projects").appendingPathComponent(projectName(e.id))
            return isFolder(u) ? u : nil
        }
    }

    /// The quick chat's own folder holds more than a plain settings.json and empty work folders. Can't be read: it does.
    private static func keptFiles(in url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return true }
        for n in names where n != ".DS_Store" {
            let u = url.appendingPathComponent(n)
            guard let k = kind(u) else { return true }
            if n == "settings.json", k == S_IFREG { continue }
            if k != S_IFDIR || holdsFiles(u) { return true }
        }
        return false
    }

    /// What is left: the folders that hold anything, and how many chats are in them.
    struct Left: Equatable {
        var folders: [URL] = []
        var chats = 0
        var isEmpty: Bool { folders.isEmpty }
    }

    static func left(_ entries: [AccountEntry]) -> Left {
        var out = Left()
        for u in projectFolders(entries) where holdsFiles(u) { out.folders.append(u); out.chats += chats(in: u) }
        if isFolder(folder), keptFiles(in: folder) { out.folders.append(folder) }
        return out
    }

    /// Once, at the agent's first start without the chat (with the profiles known): the empty old chat folders, the empty
    /// work folders and a plain settings.json go to the Trash; anything that holds something stays (Settings says so).
    /// Returns what went.
    @discardableResult
    static func tidyOnce(_ entries: [AccountEntry], defaults: UserDefaults) -> [URL] {
        guard !defaults.bool(forKey: tidiedKey), !entries.isEmpty else { return [] }
        let gone = tidy(entries)
        defaults.set(true, forKey: tidiedKey)
        return gone
    }

    static func tidy(_ entries: [AccountEntry]) -> [URL] {
        var gone: [URL] = []
        func trash(_ u: URL) { if toTrash(u) { gone.append(u) } }
        for u in projectFolders(entries) where !holdsFiles(u) { trash(u) }
        if isFolder(folder) {
            if keptFiles(in: folder) {
                // the folder stays; a plain settings.json and the empty work folders go
                let settings = folder.appendingPathComponent("settings.json")
                if kind(settings) == S_IFREG { trash(settings) }
                for n in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
                    let u = folder.appendingPathComponent(n)
                    if isFolder(u), !holdsFiles(u) { trash(u) }
                }
            } else {
                trash(folder)
            }
        }
        return gone
    }

    /// Move to Trash…: every folder that's left, after the person said yes.
    static func trashAll(_ entries: [AccountEntry]) -> Left {
        for u in left(entries).folders { _ = toTrash(u) }
        _ = tidy(entries)
        return left(entries)
    }

    /// The line's words.
    static func lineWords(_ l: Left) -> String {
        switch l.chats {
        case 0: return "Old quick chat files from cl_audit are still here."
        case 1: return "1 old quick chat from cl_audit is still here."
        default: return "\(l.chats) old quick chats from cl_audit are still here."
        }
    }

    /// Move to Trash…'s question.
    static func trashWords(_ l: Left) -> String {
        switch l.chats {
        case 0: return "This moves the old quick chat folders to the Trash."
        case 1: return "This moves 1 chat and the folders they were kept in to the Trash.\nNothing is deleted until you empty the Trash."
        default: return "This moves \(l.chats) chats and the folders they were kept in to the Trash.\nNothing is deleted until you empty the Trash."
        }
    }
}

/// Settings ▸ General ▸ Backups: one quiet line while old quick chats from cl_audit are left, with Show in Finder and
/// Move to Trash…. Nothing when none are.
struct OldQuickChatsLine: View {
    @State private var left = OldQuickChats.Left()
    @Environment(\.face) private var face

    var body: some View {
        Group {
            if !left.isEmpty {
                HStack(spacing: 8) {
                    Text(OldQuickChats.lineWords(left)).font(.system(size: 11)).foregroundStyle(face.muted)
                        .help("cl_audit's own quick chat is gone.\ncl_quick is the quick chat now.\nThese are the chats the old one kept.")
                    Spacer(minLength: 6)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(left.folders) }
                    Button("Move to Trash") { askTrash() }
                }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true))
            }
        }
        .task { await look() }
    }

    private func look() async {
        let entries = Store.load()
        left = await Task.detached(priority: .utility) { OldQuickChats.left(entries) }.value
    }

    private func askTrash() {
        let a = NSAlert()
        a.messageText = "Move cl_audit's old quick chats to the Trash?"
        a.informativeText = OldQuickChats.trashWords(left)
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        left = OldQuickChats.trashAll(Store.load())
    }
}
