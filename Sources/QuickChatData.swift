// QuickChatData: everything the quick chat keeps on this Mac, and its removal (Settings ▸ General ▸ Quick chat).
//
//   - its chats: Claude Code sessions, which Claude Code keeps in each profile's own folder under
//     projects/<quick chat's work folder, every non-letter-or-digit a "-">/ (and deletes after 30 days by default);
//   - its work folders, one per profile, and its settings: usage-n-uf/quick-chat/.
//
// Remove quick chat data… moves all of it to the Trash (so it can still be brought back from there): first the chat
// closes and its claude ends, then only folders whose names are exactly quick chat's own are taken. Nothing else of a
// profile's is touched. The chats are left out of a profile's session counts and backups unless Counting says so.

import AppKit

enum QuickChatData {
    /// Posted (distributed) just before the data goes, so the agent closes the chat and its claude.
    static let removing = Notification.Name("local.usage-n-uf.quick-chat-removing")

    /// The name Claude Code gives the folder of every quick chat work folder's sessions starts with this, then "-<id>".
    static var projectPrefix: String { QuickChatCommand.projectKey(QuickChatSettings.folder.path) + "-" }

    /// A folder directly under a profile's projects/ that holds quick chats.
    static func isQuickChatProject(_ name: String) -> Bool { name.hasPrefix(projectPrefix) }

    /// A path inside a profile's projects/ ("<project>/<session>.jsonl") that is a quick chat's, and quick chats aren't
    /// counted in the profile's sessions and backups (Counting off).
    static func leftOut(_ rel: String, counted: Bool = QuickChatSettings.load().counted) -> Bool {
        guard !counted, let first = rel.split(separator: "/").first else { return false }
        return isQuickChatProject(String(first))
    }

    /// One profile's quick chats: the folder Claude Code keeps them in, how many, and their size.
    struct Chats: Equatable {
        var profile: String
        var name: String
        var folder: URL
        var count: Int
        var bytes: Int64
    }

    static func chats(_ e: AccountEntry) -> Chats {
        let projects = URL(fileURLWithPath: Account(e).configDir).appendingPathComponent("projects")
        let folder = projects.appendingPathComponent(QuickChatCommand.projectKey(QuickChatSettings.workFolder(e.id)))
        var count = 0, bytes: Int64 = 0
        if let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in walk {
                guard let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
                bytes += Int64(v.fileSize ?? 0)
                if f.pathExtension == "jsonl", f.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { count += 1 }
            }
        }
        return Chats(profile: e.id, name: e.name, folder: folder, count: count, bytes: bytes)
    }

    /// The size of usage-n-uf/quick-chat/ (work folders and settings).
    static func ownBytes() -> Int64 {
        var bytes: Int64 = 0
        if let walk = FileManager.default.enumerator(at: QuickChatSettings.folder, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in walk { bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return bytes
    }

    /// Moves the quick chats of every profile, its work folders and its settings to the Trash. Returns what couldn't be
    /// moved, in words (empty: all of it went). Call off the main thread.
    static func remove(_ entries: [AccountEntry]) -> [String] {
        DistributedNotificationCenter.default().postNotificationName(removing, object: nil, userInfo: nil, deliverImmediately: true)
        Thread.sleep(forTimeInterval: 1)             // the agent closes the chat and ends its claude
        let fm = FileManager.default
        var failed: [String] = []
        func trash(_ url: URL) {
            guard fm.fileExists(atPath: url.path) else { return }
            do { try fm.trashItem(at: url, resultingItemURL: nil) } catch { failed.append(tilde(url.path)) }
        }
        for e in entries {
            let c = chats(e)
            // only a folder named exactly as quick chat's, directly in the profile's projects/
            let projects = URL(fileURLWithPath: Account(e).configDir).appendingPathComponent("projects").standardizedFileURL
            guard isQuickChatProject(c.folder.lastPathComponent),
                  c.folder.deletingLastPathComponent().standardizedFileURL == projects else { continue }
            trash(c.folder)
        }
        trash(QuickChatSettings.folder)
        // the settings are gone: the agent reads the defaults again (the shortcut off)
        DistributedNotificationCenter.default().postNotificationName(QuickChatSettings.changed, object: nil, userInfo: nil, deliverImmediately: true)
        return failed
    }
}
