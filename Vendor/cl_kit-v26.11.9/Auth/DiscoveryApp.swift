// ClaudeAuth · finding accounts, the sources that read sessions and chats: OPTIONS, cl_audit's. The desktop app's session
// folders (it opens the desktop app's agent session records) and the account ids Claude Code's transcripts name (IT READS
// CHATS). An app that stays incognito (cl_quick) builds ClaudeAuth without this file, as it builds it without
// Keychain.swift (scripts/modules.sh, `kit_build OUT no-keychain`): it ships no chat reader at all. The nokeychain suite
// checks that the library it builds holds neither.

import Foundation
import ProfileCore

extension AccountSources {
    /// One agent session record is opened at most this large (cl_audit's bound for such a record).
    public static let agentRecordMax = 1 << 20

    // MARK: the desktop app's sessions

    /// APP SESSIONS (an option; it opens the desktop app's agent session records): the account/organisation pairs under a
    /// desktop app's data folder, with when a session was last written under each.
    /// - claude-code-sessions/<account>/<org>/: its local_<UUID>.json entries' names and dates only, none opened;
    /// - local-agent-mode-sessions/<account>/<org>/: its records' dates, and the address the first of them that names one
    ///   says: at most `records` opened, each at most `max` bytes, and none for an account in `knownAccounts` (the ids, any
    ///   case, of accounts whose address the caller knows already: their records are never opened).
    /// Each folder on the way a real folder, the session root too, and each file a real file: a link is never followed. Both
    /// names UUID-shaped. `limit`: at most that many names looked at in each folder.
    public static func appSessions(dataDir: String, records: Int = 50, max: Int = agentRecordMax, knownAccounts: Set<String> = [],
                                   limit: Int? = nil) -> [FoundAccount] {
        let known = Set(knownAccounts.map(AccountID.normal))
        var out: [FoundAccount] = []
        for (kind, agent) in [("claude-code-sessions", false), ("local-agent-mode-sessions", true)] {
            let root = (dataDir as NSString).appendingPathComponent(kind)
            guard isRealFolder(root) else { continue }
            for a in names(root, limit: limit) where isUUID(a) {
                let adir = (root as NSString).appendingPathComponent(a)
                guard isRealFolder(adir) else { continue }
                for o in names(adir, limit: limit) where isUUID(o) {
                    let odir = (adir as NSString).appendingPathComponent(o)
                    guard isRealFolder(odir) else { continue }
                    let files = names(odir, limit: limit).filter { agent ? $0.hasSuffix(".json") : isEntryName($0) }
                        .filter { isRealFile((odir as NSString).appendingPathComponent($0)) }
                    let dates = files.compactMap { modified((odir as NSString).appendingPathComponent($0)) }
                    var email: String?
                    if agent, !known.contains(AccountID.normal(a)) {
                        for f in files.prefix(Swift.max(0, records)) {
                            guard let d = RecordFile.read((odir as NSString).appendingPathComponent(f), max: Swift.max(0, max)),
                                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                                  let e = j["emailAddress"] as? String, !e.isEmpty else { continue }
                            email = e
                            break
                        }
                    }
                    if let f = FoundAccount(accountID: a, organizationID: o, email: email, lastUsed: dates.max(),
                                            source: agent ? .appAgentSessions : .appSessions, path: odir) { out.append(f) }
                }
            }
        }
        return out
    }

    /// A desktop app's Code session entry's name: local_<UUID>.json (any case).
    public static func isEntryName(_ n: String) -> Bool {
        n.hasPrefix("local_") && n.hasSuffix(".json") && isUUID(String(n.dropFirst("local_".count).dropLast(".json".count)))
    }

    // MARK: transcripts

    /// TRANSCRIPTS (an option; IT READS CHATS): the account ids a Claude Code folder's transcripts name
    /// ("accountUuid":"<uuid>"), from the first `head` bytes of each <folder>/projects/<project>/*.jsonl, at most `cap` of
    /// them, newest first. Each project folder and transcript a real one (a link is never followed out of the folder). Ids
    /// alone (no organisation), one sighting per id, in the order found.
    public static func transcriptAccounts(folder: AuthFolder, cap: Int = 400, head: Int = 64 << 10) -> [FoundAccount] {
        let projects = (folder.path as NSString).appendingPathComponent("projects")
        guard isRealFolder(projects) else { return [] }
        var files: [(String, Date)] = []
        for p in list(projects) {
            let dir = (projects as NSString).appendingPathComponent(p)
            guard isRealFolder(dir) else { continue }
            for n in list(dir) where n.hasSuffix(".jsonl") {
                let f = (dir as NSString).appendingPathComponent(n)
                // a real file only (never a link, a FIFO or a device)
                if let t = modified(f) { files.append((f, t)) }
            }
        }
        let re = try! NSRegularExpression(pattern: #""accountUuid"\s*:\s*"([0-9a-fA-F-]{36})""#)
        var out: [FoundAccount] = []
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(Swift.max(0, cap)) {
            guard let d = RecordFile.head(f, bytes: head) else { continue }
            let s = String(decoding: d, as: UTF8.self)
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s), isUUID(String(s[r])) else { continue }
                let a = AccountID.normal(String(s[r]))
                if !out.contains(where: { $0.accountID == a }), let found = FoundAccount(accountID: a, source: .transcript, path: f) {
                    out.append(found)
                }
            }
        }
        return out
    }
}
