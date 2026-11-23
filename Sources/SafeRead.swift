// SafeRead: the one way cl_audit reads Claude Code's and the Claude app's own files (the agent sessions' records, transcripts,
// a session's registration; .claude.json's account record is ClaudeFiles'): bounded and never blocking. A FIFO, a device or a link
// to /dev/zero named like one of those files returns at once with nothing, and nothing past `max` bytes is ever read, so
// no file on disk can freeze the agent, the accounts' discovery or a switch.
//
// Reads follow links (a profile's folder, or ~/.claude.json, may be a link to the real one: A's rule, "reads follow
// links"), but what is read must be a regular file. Launching and creating keep refusing links (FolderGuard).

import Foundation

enum SafeRead {
    /// The cap for a whole JSON file of Claude's (a backup's record, scheduled-tasks.json, the window's config): a larger one
    /// isn't read at all.
    static let jsonMax = 32 << 20
    /// The cap for a small record (a session's registration, an agent session's record, usage.json).
    static let recordMax = 1 << 20
    /// The cap for one of the window's session entries (it carries the account's connector list).
    static let entryMax = 8 << 20

    /// The file is a regular file larger than `max` (by its size alone; nothing is read).
    static func tooLarge(_ path: String, max: Int) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && Int(st.st_size) > max
    }

    struct Read {
        var data: Data
        var size: Int                   // the file's whole size
    }

    /// Up to `max` bytes of a regular file, from its start (or its end), opened non-blocking. nil when it isn't there,
    /// isn't a regular file (a FIFO, a device, a folder) or can't be read.
    static func read(_ path: String, max: Int, fromEnd: Bool = false, whole: Bool = false) -> Read? {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size), n = min(size, max)
        if whole && size > max { return nil }                 // never half of one: and never read just to throw it away
        var buf = Data(count: n)
        let got = n == 0 ? 0 : buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, n, off_t(fromEnd ? size - n : 0)) }
        guard got == n else { return nil }
        return Read(data: buf, size: size)
    }

    /// A whole file of at most `max` bytes: nil when it's larger (never half of one), or not a regular file.
    static func whole(_ path: String, max: Int = jsonMax) -> Data? {
        guard let r = read(path, max: max, whole: true), r.data.count == r.size else { return nil }
        return r.data
    }

    /// A whole JSON object file of at most `max` bytes, or nil.
    static func jsonObject(_ path: String, max: Int = jsonMax) -> [String: Any]? {
        whole(path, max: max).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A regular file read from start to end in pieces of at most `chunk` bytes, for a reader that looks at every byte once (the
    /// secret scan): each piece is handed to `body` behind the last `carry` bytes of what came before, so what a piece's end cuts
    /// is seen whole, with how many bytes are new. Opened non-blocking and never through a link (unless `followsLink`); memory is
    /// `carry + chunk`, whatever the file's size. `go` is asked before each read: false stops it. False when it isn't a regular
    /// file, can't be read, or was stopped; true once the end is reached.
    static func chunks(_ path: String, chunk: Int, carry: Int, followsLink: Bool = false, go: () -> Bool = { true },
                       _ body: (_ bytes: UnsafeBufferPointer<UInt8>, _ fresh: Int) -> Void) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | (followsLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        let size = Int64(st.st_size)
        var buf = [UInt8](repeating: 0, count: carry + chunk)
        var have = 0
        var off: Int64 = 0
        while off < size {
            if !go() { return false }
            let want = Int(min(Int64(chunk), size - off))
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + have, want, off_t(off)) }
            if n < 0 { return false }
            if n == 0 { break }
            let total = have + n
            buf.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[0..<total]), n) }
            off += Int64(n)
            let keep = min(carry, total)
            if keep > 0 { buf.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + total - keep, keep) } }
            have = keep
        }
        return true
    }
}
