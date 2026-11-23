// ClaudeAuth · the one folder reader: a folder's .claude.json, read for the account in it (oauthAccount's named fields
// only), bounded, and parsed again only when the file's stamp moved. Claude Code rewrites the file often (every session
// writes it) and it can be several MB, so each look is one stat and a parse only after a write. The reader is a value
// the app owns (one per app, shared by its parts); the kit keeps no global state.

import Foundation
import ProfileCore

/// Reads folders' records. Safe from any thread; a parse runs on the caller's thread (off the main thread for a large file).
public final class FolderRecordReader: @unchecked Sendable {
    /// One look at a record.
    public struct Look: Equatable {
        /// The account the record names now (guessed); nil when it names nobody, isn't there or can't be read.
        public var account: SignedInAccount?
        /// The record's stamp the account was read at.
        public var stamp: RecordStamp
        /// How many times the record has named someone else since this reader first parsed it: another account or seat
        /// (`.different`), or someone after nobody and nobody after someone. A rewrite for the same seat, or a seat that
        /// was only not known before, isn't a change. Every caller keeps the last generation it saw and compares: each
        /// one sees each change, whoever's look parsed it.
        public var generation: Int
        /// This look's own parse found the change (`generation` moved on it): for a single caller only.
        public var changed: Bool
    }

    private let parse: (String) -> [String: Any]?
    private let stampOf: (String) -> RecordStamp
    private var cache: [String: (stamp: RecordStamp, account: SignedInAccount?, generation: Int)] = [:]
    private let lock = NSLock()

    /// `parse` reads a record file's oauthAccount block (bounded, never blocking on a FIFO: RecordFile's by default);
    /// `stamp` is the file's stamp now (RecordStamp.of). Both are parameters for the checks.
    public init(parse: @escaping (String) -> [String: Any]? = { RecordFile.oauthAccount($0) },
                stamp: @escaping (String) -> RecordStamp = { RecordStamp.of($0) }) {
        self.parse = parse; self.stampOf = stamp
    }

    /// The folder's record now.
    public func look(_ folder: AuthFolder) -> Look { look(path: folder.recordPath) }

    /// The record at `path` now: from the last parse while its stamp is the same, else parsed again. A parse that a
    /// write overtook (the stamp moved while it read) is returned but never kept, so the next look parses again.
    public func look(path: String) -> Look {
        let before = stampOf(path)
        lock.lock()
        if let hit = cache[path], hit.stamp == before {
            lock.unlock(); return Look(account: hit.account, stamp: before, generation: hit.generation, changed: false)
        }
        lock.unlock()
        // no file: nothing parsed, and nothing kept unless a parse came before (then it is gone: signed out if it named
        // someone), so a file that appears later is its first parse
        guard before != .none else {
            lock.lock(); defer { lock.unlock() }
            guard let last = cache[path] else { return Look(account: nil, stamp: .none, generation: 0, changed: false) }
            return keep(path, stamp: .none, account: nil, after: last)
        }
        let account = SignedInAccount.record(parse(path))
        guard stampOf(path) == before else {
            lock.lock(); let g = cache[path]?.generation ?? 0; lock.unlock()
            return Look(account: account, stamp: before, generation: g, changed: false)
        }
        lock.lock(); defer { lock.unlock() }
        // another thread may have parsed the same file meanwhile: the change is counted by whichever kept it first
        if let hit = cache[path], hit.stamp == before {
            return Look(account: hit.account, stamp: before, generation: hit.generation, changed: false)
        }
        guard let last = cache[path] else {
            cache[path] = (before, account, 0)
            return Look(account: account, stamp: before, generation: 0, changed: false)
        }
        return keep(path, stamp: before, account: account, after: last)
    }

    /// Keeps a parse (the lock held), counting a change against the last one.
    private func keep(_ path: String, stamp: RecordStamp, account: SignedInAccount?,
                      after last: (stamp: RecordStamp, account: SignedInAccount?, generation: Int)) -> Look {
        let changed = Self.someoneElse(last.account, account)
        let g = last.generation + (changed ? 1 : 0)
        cache[path] = (stamp, account, g)
        return Look(account: account, stamp: stamp, generation: g, changed: changed)
    }

    /// Forgets a record (a folder no longer followed); its next look is a first parse again, at generation 0.
    public func forget(path: String) { lock.lock(); cache[path] = nil; lock.unlock() }

    /// The record names someone else: another account or seat by the one comparison, or someone after nobody, nobody
    /// after someone. A seat that was only not known before (an organisation gained or lost) is the same account.
    public static func someoneElse(_ a: SignedInAccount?, _ b: SignedInAccount?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (let a?, let b?): return a.match(b) == .different
        default: return true
        }
    }
}
