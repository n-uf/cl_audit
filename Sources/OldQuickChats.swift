// OldQuickChats: what cl_audit's own quick chat left behind, now that cl_quick is the one quick chat (ClQuick). Its work
// folders and settings (usage-n-uf/quick-chat/) and, in each profile's Claude Code folder, the projects/ folders its chats
// were kept in (named after a work folder: "<usage-n-uf/quick-chat as a project key>-<profile>"). Once, at the agent's first
// start of a build without the chat, the empty ones go to the Trash. Ones that hold chats stay until the person moves
// them to the Trash from Settings ▸ General ▸ Backups (one quiet line, with Show in Finder). Never deleted outright, and
// never through a link.

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

    /// A plain folder (never a link, never a file).
    private static func isFolder(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// The chats (Claude Code's .jsonl transcripts) inside a folder, not following links.
    static func chats(in url: URL) -> Int {
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsPackageDescendants]) else { return 0 }
        var n = 0
        for case let f as URL in walk where f.pathExtension == "jsonl" {
            if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { n += 1 }
        }
        return n
    }

    /// Whether a folder holds anything at all (a file anywhere inside).
    private static func holdsFiles(_ url: URL) -> Bool {
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let f as URL in walk where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return true }
        return false
    }

    /// The chat project folders in the profiles' Claude Code folders: directly in projects/, named as the quick chat's.
    static func projectFolders(_ entries: [AccountEntry]) -> [URL] {
        let prefix = projectKey(folder.path) + "-"
        var out: [URL] = []
        for e in entries {
            let projects = URL(fileURLWithPath: Account(e).configDir).appendingPathComponent("projects")
            guard isFolder(projects), let names = try? FileManager.default.contentsOfDirectory(atPath: projects.path) else { continue }
            for n in names where n.hasPrefix(prefix) {
                let u = projects.appendingPathComponent(n)
                if isFolder(u) { out.append(u) }
            }
        }
        return out
    }

    /// What is left: the folders that hold chats (and the quick chat's own folder while it holds anything but its settings
    /// and empty work folders), and how many chats there are.
    struct Left: Equatable {
        var folders: [URL] = []
        var chats = 0
        var isEmpty: Bool { folders.isEmpty }
    }

    static func left(_ entries: [AccountEntry]) -> Left {
        var out = Left()
        for u in projectFolders(entries) {
            let n = chats(in: u)
            if n > 0 { out.folders.append(u); out.chats += n }
        }
        if isFolder(folder), keptFiles(in: folder) { out.folders.append(folder) }
        return out
    }

    /// The quick chat's own folder holds more than its settings and empty work folders (files a chat's `claude` made there).
    private static func keptFiles(in url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return names.contains { n in
            let u = url.appendingPathComponent(n)
            return n != "settings.json" && n != ".DS_Store" && (isFolder(u) ? holdsFiles(u) : true)
        }
    }

    /// Once, at the agent's first start without the chat: the empty chat project folders, the empty work folders and the
    /// settings go to the Trash; anything that holds chats or files stays (Settings says so). Returns what went.
    @discardableResult
    static func tidyOnce(_ entries: [AccountEntry], defaults: UserDefaults) -> [URL] {
        guard !defaults.bool(forKey: tidiedKey) else { return [] }
        defaults.set(true, forKey: tidiedKey)
        return tidy(entries)
    }

    static func tidy(_ entries: [AccountEntry]) -> [URL] {
        var gone: [URL] = []
        func trash(_ u: URL) { if toTrash(u) { gone.append(u) } }
        for u in projectFolders(entries) where !holdsFiles(u) { trash(u) }
        if isFolder(folder) {
            if keptFiles(in: folder) {
                // keep the folder, but its settings and empty work folders go
                let settings = folder.appendingPathComponent("settings.json")
                if FileManager.default.fileExists(atPath: settings.path) { trash(settings) }
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
                    Text("Old quick chats from cl_audit: \(left.chats)").font(.system(size: 11)).foregroundStyle(face.muted)
                        .help("cl_audit's own quick chat is gone: cl_quick is the quick chat now. These are the chats it kept.")
                    Spacer(minLength: 6)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(left.folders) }
                    Button("Move to Trash…") { askTrash() }
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
        a.informativeText = "\(left.chats == 1 ? "1 chat" : "\(left.chats) chats") and the folders they were kept in. Nothing is deleted until you empty the Trash."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        left = OldQuickChats.trashAll(Store.load())
    }
}
