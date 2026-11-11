// SafeRead: the one way cl_audit reads Claude Code's and the Claude app's own files (.claude.json and its backups, the
// agent sessions' records, transcripts, a session's registration): bounded and never blocking. A FIFO, a device or a link
// to /dev/zero named like one of those files returns at once with nothing, and nothing past `max` bytes is ever read, so
// no file on disk can freeze the agent, the accounts' discovery or a switch.
//
// Reads follow links (a profile's folder, or ~/.claude.json, may be a link to the real one: A's rule, "reads follow
// links"), but what is read must be a regular file. Launching and creating keep refusing links (FolderGuard).

import Foundation

enum SafeRead {
    /// The cap for a whole .claude.json-type file: a larger one isn't read at all (as if it weren't there).
    static let jsonMax = 32 << 20
    /// The cap for a small record (a session's registration, an agent session's record, a session entry).
    static let recordMax = 1 << 20

    struct Read {
        var data: Data
        var size: Int                   // the file's whole size
        var modified: Date
        var inode: UInt64
    }

    /// Up to `max` bytes of a regular file, from its start (or its end), opened non-blocking. nil when it isn't there,
    /// isn't a regular file (a FIFO, a device, a folder) or can't be read.
    static func read(_ path: String, max: Int, fromEnd: Bool = false) -> Read? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size), n = min(size, max)
        var buf = Data(count: n)
        let got = n == 0 ? 0 : buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(fromEnd ? size - n : 0)) }
        guard got == n else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return Read(data: buf, size: size, modified: modified, inode: UInt64(st.st_ino))
    }

    /// A whole file of at most `max` bytes: nil when it's larger (never half of one), or not a regular file.
    static func whole(_ path: String, max: Int = jsonMax) -> Data? {
        guard let r = read(path, max: max), r.data.count == r.size else { return nil }
        return r.data
    }

    /// A whole JSON object file of at most `max` bytes, or nil.
    static func jsonObject(_ path: String, max: Int = jsonMax) -> [String: Any]? {
        whole(path, max: max).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The oauthAccount block of a .claude.json-type file, read again only when the file changed (by its size, date and
    /// inode): the files can be several MB and are asked about every few seconds. nil when there's none.
    static func oauthAccount(_ path: String) -> [String: Any]? {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let key = Stamp(size: Int64(st.st_size), sec: Int(st.st_mtimespec.tv_sec), nsec: Int(st.st_mtimespec.tv_nsec), inode: UInt64(st.st_ino))
        lock.lock()
        if let c = memo[path], c.stamp == key { lock.unlock(); return c.block }
        lock.unlock()
        let block = jsonObject(path)?["oauthAccount"] as? [String: Any]
        lock.lock(); memo[path] = (key, block); if memo.count > 256 { memo.removeAll() }; lock.unlock()
        return block
    }

    private struct Stamp: Equatable { var size: Int64; var sec: Int; var nsec: Int; var inode: UInt64 }
    nonisolated(unsafe) private static var memo: [String: (stamp: Stamp, block: [String: Any]?)] = [:]
    private static let lock = NSLock()
}
