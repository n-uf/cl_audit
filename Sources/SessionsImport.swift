// SessionsImport: an export (SessionsExport.swift) read back in, as a restore. The file is treated as hostile from the first
// byte, and the whole import is refused, with nothing written into a profile, on anything that is not exactly what an export
// is:
//
//  1. a .zip is read by its central directory before anything is unpacked: every name must be a plain relative one (no
//     absolute path, no "..", no backslash, no NUL), in one top-level folder, no link or device or encrypted entry, no
//     two names that are one on this Mac's disks, and the sizes it declares must fit 2x what export.json says plus a
//     little, and an absolute ceiling (every number the file gives is checked before it is added or used). export.json is
//     read out of the zip itself and checked first (format, version, sizes); a newer format is refused.
//     Import does NOT unpack with ditto: ditto goes by the local headers and by the deflate stream (it takes the local
//     header's name, extracts entries only a local header names, ignores declared sizes, and reads the next local header
//     from wherever a deflate stream ends, so a record hidden in an entry's slack is written). cl_audit unpacks with its own
//     reader, and writes exactly what the directory names and it checked. Before that the zip is also proved to be exactly
//     its central directory: each local header has the central entry's name, method, flags and sizes, and the local records
//     (header, name, extra, data, descriptor) tile the file from byte 0 to the central directory with no gap, no overlap and
//     nothing hidden; only an end record (and the zip64 one, which the locator must point at) follows it. (Export still makes
//     its zip with `ditto -c -k`, so Finder opens it.)
//  2. it is unpacked into a fresh private folder (0700) under the backups place, by `ZipIndex.extract`: each entry stored or
//     deflate only, read from its checked place, inflated with zlib (raw inflate, in 64 KB steps; at the stream's end zlib says
//     how many input bytes are left, so slack is always seen) and required to end exactly at csize with no input left over, the output exactly usize (stopped the moment it would pass it), the CRC-32 the
//     directory's; written data-only (O_EXCL|O_NOFOLLOW, 0600, folders made one by one through descriptors), with a running
//     total of bytes written checked against the cap before every write and the volume's free space against a floor. A .dmg
//     must be an encrypted image (cl_audit makes no other); it is attached read-only, not
//     browsable, in a private mount point, with the password on stdin, checked to be mounted read-only, nosuid, nodev,
//     walked, copied out file by file as data only (no flags, ACLs, extended attributes or mode bits come along) and detached.
//  3. the unpacked tree is walked with lstat, never following a link: a folder or a plain file with one link is all there
//     may be, every name plain and none named like a sign-in, no file flag but "compressed", no ACL, no extended
//     attribute but the ones macOS adds on its own, no setuid/setgid/sticky bit, and the tree must be exactly export.json
//     and profiles/pN/ with each backup.json's items (file for file, byte for byte in size) and nothing else: an extra
//     file, a missing one, a link, a device, a second hard link, a sign-in name, a size that differs: refused.
//  4. the chosen profile's part is made a new backup of the target profile (kind "imported"), file by file through the
//     same copy rules as a backup (a clone or a copy from an open file, plain single-link files only, never over a file),
//     with the manifest rewritten (the target's id, no paths of the other Mac, accounts and counts rebuilt from what was
//     verified) and put in place whole. Then it is restored by SessionsRestore.run like any backup: create-only, window
//     closed, receipt, Undo. The restore clones from this backup; the backup's files are data only (0600, no flags,
//     ACL or extended attribute: step 3 refused them, and the image copy-out never takes them), so a clone carries none.

import Foundation
import zlib

// MARK: - reading a zip's central directory

struct ZipIndex {
    struct Entry {
        var name: String
        var method: UInt16
        var flags: UInt16
        var csize: UInt64
        var usize: UInt64
        var offset: UInt64
        var host: UInt8
        var attrs: UInt32
        var crc: UInt32 = 0
        var nameBytes: [UInt8] = []
        var mtime: Date? = nil              // the entry's modification time: the extended timestamp (UTC) if it has one, else DOS time
        var isDir: Bool { name.hasSuffix("/") }
    }
    var entries: [Entry]
    var size: Int64
    var cdOffset: UInt64 = 0                  // where the central directory starts (the local records end there)
    var cdEnd: UInt64 = 0                     // where it ends

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(le16(b, i)) | UInt32(le16(b, i + 2)) << 16 }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }

    /// A DOS date and time (local time, 2 s steps) as a Date; nil when it isn't a date.
    static func dosDate(date: UInt16, time: UInt16) -> Date? {
        var c = DateComponents()
        c.year = 1980 + Int(date >> 9); c.month = Int((date >> 5) & 0xF); c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11); c.minute = Int((time >> 5) & 0x3F); c.second = Int(time & 0x1F) * 2
        return Calendar.current.date(from: c)
    }

    /// The way a case-insensitive APFS tells two names apart: normalized (NFC), then case folded letter by letter ("A" and "a", and
    /// "σ" and "ς", are one), diacritics kept ("e" and "é" are two). A letter folds to the lower case of its upper case when each is
    /// one letter (that is what makes the final sigma one with the other); a letter whose upper case is several ("ß") only goes to lower
    /// case. Two names that fold alike are one name on this Mac (a few more than APFS joins are joined, which is the safe side).
    static func foldedKey(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for sc in name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil).unicodeScalars {
            let up = sc.properties.uppercaseMapping.unicodeScalars
            if up.count == 1, let u = up.first {
                let low = u.properties.lowercaseMapping.unicodeScalars
                if low.count == 1, let l = low.first { out.append(l); continue }
            }
            out.append(contentsOf: sc.properties.lowercaseMapping.unicodeScalars)
        }
        return String(out)
    }

    /// A time the file states, held to what a file's time can be: not before 1980 (the zip epoch) and not after `now`. (A hostile
    /// value in 2106 would make every imported file look recent: Undo would leave it as one a running session may hold.)
    static func clamped(_ d: Date?, now: Date) -> Date? {
        guard let d else { return nil }
        let lo = Date(timeIntervalSince1970: 315_532_800)
        return min(max(d, lo), now)
    }

    private static func bytes(_ fd: Int32, _ off: UInt64, _ n: Int) -> [UInt8]? {
        // (a number the file gives never reaches arithmetic that could trap: the end of the read must fit too)
        guard n >= 0, off <= UInt64(Int64.max) - UInt64(n) else { return nil }
        var b = [UInt8](repeating: 0, count: n)
        var done = 0
        while done < n {
            let r = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, n - done, off_t(off) + off_t(done)) }
            if r <= 0 { return nil }
            done += r
        }
        return b
    }

    /// The entries of the zip at `path`, or why it can't be read. Nothing is unpacked.
    static func read(path: String) throws -> ZipIndex {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError("The file can't be opened.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError("That isn't a plain file.") }
        let size = UInt64(st.st_size)
        guard size >= 22 else { throw ArchiveError("That isn't a zip file.") }
        let tailLen = Int(min(size, 65535 + 22 + 20))
        guard let tail = bytes(fd, size - UInt64(tailLen), tailLen) else { throw ArchiveError("The zip can't be read.") }
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06, i + 22 + Int(le16(tail, i + 20)) == tail.count { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ArchiveError("That isn't a zip file (no end record).") }
        guard le16(tail, eocd + 4) == 0, le16(tail, eocd + 6) == 0 else { throw ArchiveError("A zip in several parts isn't an export.") }
        var total = UInt64(le16(tail, eocd + 10))
        var cdSize = UInt64(le32(tail, eocd + 12))
        var cdOff = UInt64(le32(tail, eocd + 16))
        let raw32 = (count: total, size: cdSize, off: cdOff)                // what the 32-bit end record itself says
        let hasLocator = eocd >= 20 && tail[eocd - 20] == 0x50 && tail[eocd - 19] == 0x4B && tail[eocd - 18] == 0x06 && tail[eocd - 17] == 0x07
        let locatedAt: UInt64? = hasLocator ? le64(tail, eocd - 20 + 8) : nil
        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOff == 0xFFFF_FFFF {
            guard hasLocator else { throw ArchiveError("The zip's end record is damaged.") }
            let z64 = le64(tail, eocd - 20 + 8)
            guard z64 < size, let r = bytes(fd, z64, 56), r[0] == 0x50, r[1] == 0x4B, r[2] == 0x06, r[3] == 0x06 else { throw ArchiveError("The zip's end record is damaged.") }
            guard le32(r, 16) == 0, le32(r, 20) == 0 else { throw ArchiveError("A zip in several parts isn't an export.") }
            total = le64(r, 32); cdSize = le64(r, 40); cdOff = le64(r, 48)
        }
        guard total <= 1_000_000 else { throw ArchiveError("The zip holds too many entries to be an export.") }
        guard cdSize <= 512 << 20, cdOff <= size, cdOff + cdSize <= size else { throw ArchiveError("The zip's directory is damaged.") }
        guard let cd = bytes(fd, cdOff, Int(cdSize)) else { throw ArchiveError("The zip's directory can't be read.") }
        var out: [Entry] = []
        var p = 0
        let readAt = Date()
        while out.count < Int(total) {
            guard p + 46 <= cd.count, cd[p] == 0x50, cd[p + 1] == 0x4B, cd[p + 2] == 0x01, cd[p + 3] == 0x02 else { throw ArchiveError("The zip's directory is damaged.") }
            let made = le16(cd, p + 4), flags = le16(cd, p + 8), method = le16(cd, p + 10)
            var csize = UInt64(le32(cd, p + 20)), usize = UInt64(le32(cd, p + 24))
            let nl = Int(le16(cd, p + 28)), el = Int(le16(cd, p + 30)), cl = Int(le16(cd, p + 32))
            let attrs = le32(cd, p + 38)
            var off = UInt64(le32(cd, p + 42))
            guard p + 46 + nl + el + cl <= cd.count else { throw ArchiveError("The zip's directory is damaged.") }
            guard let name = String(bytes: cd[(p + 46)..<(p + 46 + nl)], encoding: .utf8) else { throw ArchiveError("The zip holds a name that isn't text.") }
            // the zip64 extra: the values that didn't fit, in order
            var q = p + 46 + nl
            let eend = q + el
            var utc: Date?
            while q + 4 <= eend {
                let id = le16(cd, q), len = Int(le16(cd, q + 2))
                guard q + 4 + len <= eend else { break }
                // the modification time, UTC: the extended timestamp (0x5455: a flags byte, bit 0 says the mtime is there) or the Info-ZIP
                // Unix extra that ditto writes (0x5855: atime, then mtime, 4 bytes each); either wins over DOS time (local time, no zone)
                if id == 0x5455, len >= 5, cd[q + 4] & 1 != 0 { utc = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: le32(cd, q + 5)))) }       // (signed, as Info-ZIP reads it)
                else if id == 0x5855, len >= 8, utc == nil { utc = Date(timeIntervalSince1970: TimeInterval(le32(cd, q + 8))) }
                if id == 1 {
                    var r = q + 4
                    func next() -> UInt64? { guard r + 8 <= q + 4 + len else { return nil }; defer { r += 8 }; return le64(cd, r) }
                    if usize == 0xFFFF_FFFF { usize = next() ?? usize }
                    if csize == 0xFFFF_FFFF { csize = next() ?? csize }
                    if off == 0xFFFF_FFFF { off = next() ?? off }
                }
                q += 4 + len
            }
            // sizes and offsets that no real file can have (zip64 lets a file say 2^64 - 1) are refused here, so no sum below can trap
            guard usize <= UInt64(Int64.max), csize <= UInt64(Int64.max), off <= UInt64(Int64.max) else {
                throw ArchiveError("The zip states a size or place no file can have; refused.")
            }
            guard off < cdOff else { throw ArchiveError("The zip's directory points at a record past the data; refused.") }
            out.append(Entry(name: name, method: method, flags: flags, csize: csize, usize: usize, offset: off, host: UInt8(made >> 8), attrs: attrs,
                             crc: le32(cd, p + 16), nameBytes: Array(cd[(p + 46)..<(p + 46 + nl)]),
                             mtime: clamped(utc ?? dosDate(date: le16(cd, p + 14), time: le16(cd, p + 12)), now: readAt)))
            p += 46 + nl + el + cl
        }
        guard p == cd.count else { throw ArchiveError("The zip's directory has something after its entries; refused.") }
        // only the end record (and zip64's) may follow the directory: nothing hidden after it
        let eocdAt = size - UInt64(tail.count - eocd)
        guard eocdAt >= cdOff + cdSize else { throw ArchiveError("The zip's directory runs into its end record; refused.") }
        let gap = eocdAt - (cdOff + cdSize)
        // between the directory and the end record there is nothing, or exactly the zip64 end record (56 bytes) and its locator
        // (20), and then the locator must point at that record, which must follow the directory at once
        if let z = locatedAt {
            guard gap == 56 + 20, z == cdOff + cdSize else { throw ArchiveError("The zip has something between its directory and its end record; refused.") }
            // what sits there must really be the zip64 end record (signature, its own length 44, no extra data), and say what the
            // 32-bit end record says (a number there is either "see zip64" or the same number)
            guard le32(tail, eocd - 20 + 4) == 0, le32(tail, eocd - 20 + 16) <= 1,                       // (the locator: the disk with the record is 0, one disk in all)
                  let r = bytes(fd, z, 56), r[0] == 0x50, r[1] == 0x4B, r[2] == 0x06, r[3] == 0x06, le64(r, 4) == 44, le32(r, 16) == 0, le32(r, 20) == 0,
                  le64(r, 24) == total, le64(r, 32) == total, le64(r, 40) == cdSize, le64(r, 48) == cdOff,
                  raw32.count == 0xFFFF || UInt64(raw32.count) == total,
                  raw32.size == 0xFFFF_FFFF || raw32.size == cdSize, raw32.off == 0xFFFF_FFFF || raw32.off == cdOff
            else { throw ArchiveError("The zip has something between its directory and its end record; refused.") }
        } else {
            guard gap == 0 else { throw ArchiveError("The zip has something between its directory and its end record; refused.") }
        }
        var idx = ZipIndex(entries: out, size: Int64(size))
        idx.cdOffset = cdOff; idx.cdEnd = cdOff + cdSize
        return idx
    }

    // MARK: the local records: the zip is exactly its central directory

    /// ditto unpacks by the local headers. So the local headers must be what the central directory says, and the records must
    /// tile the file from 0 to the directory: no gap and no overlap (nothing hidden between or before them), nothing but the
    /// end record after. Throws why not.
    func verifyLocals(path: String) throws {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError("The file can't be opened.") }
        defer { close(fd) }
        let bad = ArchiveError("The zip's records aren't what its directory says (a hidden or altered entry); refused.")
        var expected: UInt64 = 0
        for e in entries.sorted(by: { $0.offset < $1.offset }) {
            guard e.offset == expected, let h = ZipIndex.bytes(fd, e.offset, 30), h[0] == 0x50, h[1] == 0x4B, h[2] == 0x03, h[3] == 0x04 else { throw bad }
            let flags = ZipIndex.le16(h, 6), method = ZipIndex.le16(h, 8)
            let nl = Int(ZipIndex.le16(h, 26)), el = Int(ZipIndex.le16(h, 28))
            guard flags == e.flags, method == e.method, nl == e.nameBytes.count,
                  let rest = ZipIndex.bytes(fd, e.offset + 30, nl + el), Array(rest[0..<nl]) == e.nameBytes else { throw bad }
            // the local sizes (zip64's, if the local extra has them), unless a data descriptor carries them
            var lcrc = UInt64(ZipIndex.le32(h, 14)), lc = UInt64(ZipIndex.le32(h, 18)), lu = UInt64(ZipIndex.le32(h, 22))
            var localZip64 = false                       // the local header's own zip64 extra decides how wide a descriptor is
            do {
                var q = nl
                while q + 4 <= nl + el {
                    let id = ZipIndex.le16(rest, q), len = Int(ZipIndex.le16(rest, q + 2))
                    guard q + 4 + len <= nl + el else { break }
                    if id == 1 {
                        localZip64 = true
                        var r = q + 4
                        if lu == 0xFFFF_FFFF, r + 8 <= q + 4 + len { lu = ZipIndex.le64(rest, r); r += 8 }
                        if lc == 0xFFFF_FFFF, r + 8 <= q + 4 + len { lc = ZipIndex.le64(rest, r); r += 8 }
                    }
                    q += 4 + len
                }
            }
            let descriptor = flags & 0x8 != 0
            if !descriptor {
                guard lc == e.csize, lu == e.usize, lcrc == UInt64(e.crc) else { throw bad }
            } else {
                // with a descriptor the local header's sizes and CRC are 0 (not known yet) or already the right ones
                guard lc == 0 || lc == e.csize, lu == 0 || lu == e.usize, lcrc == 0 || lcrc == UInt64(e.crc) else { throw bad }
            }
            var end = e.offset
            for add in [UInt64(30), UInt64(nl), UInt64(el), e.csize] {
                let (s, o) = end.addingReportingOverflow(add)
                guard !o, s <= UInt64(size) else { throw bad }
                end = s
            }
            if descriptor {
                // [signature] crc, then the sizes as 4 bytes each, or 8 each when the entry is zip64
                guard let d = ZipIndex.bytes(fd, end, 4) else { throw bad }
                var at = end
                if ZipIndex.le32(d, 0) == 0x0807_4B50 { at += 4 }
                // (decided by the local header's zip64 extra, not by trying both widths)
                if localZip64 {
                    guard let a = ZipIndex.bytes(fd, at, 20), UInt64(ZipIndex.le32(a, 0)) == UInt64(e.crc), ZipIndex.le64(a, 4) == e.csize, ZipIndex.le64(a, 12) == e.usize else { throw bad }
                    at += 20
                } else {
                    guard let a = ZipIndex.bytes(fd, at, 12), UInt64(ZipIndex.le32(a, 0)) == UInt64(e.crc), UInt64(ZipIndex.le32(a, 4)) == e.csize, UInt64(ZipIndex.le32(a, 8)) == e.usize else { throw bad }
                    at += 12
                }
                end = at
            }
            expected = end
        }
        guard expected == cdOffset else { throw bad }
    }

    // MARK: unpacking: cl_audit's own checked reader, not ditto

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ crc: UInt32, _ p: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var c = ~crc
        crcTable.withUnsafeBufferPointer { t in for b in p { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) } }
        return ~c
    }

    /// What stops an unpacking: the file's own numbers (or a check) are wrong, the disk is filling, or it was stopped.
    enum Stop: Error { case refused(String), diskFull, stopped }

    /// Unpacks exactly what the central directory names, itself. (ditto reads the stream and takes the next local header from
    /// wherever a deflate stream ends, so a record hidden in an entry's slack gets written; this reader never looks past an
    /// entry's declared bytes.) For each entry in order: stored or deflate only; its data read from the checked place; deflate
    /// run through zlib's raw inflate in 64 KB steps and required to end exactly at csize (zlib says how much input is left after
    /// the stream's end, so slack is always seen);
    /// the output exactly usize, stopped the moment it would pass it; the CRC-32 equal to the directory's. A file is written
    /// data-only (O_CREAT|O_EXCL|O_NOFOLLOW, 0600, no attribute, flag or mode of the archive), every folder above it made one by
    /// one through descriptors opened O_NOFOLLOW|O_DIRECTORY (never a path walk through something that could be a link), the
    /// modification time set from the entry. A running total of bytes written is checked against `cap` before every write, and
    /// the volume's free space against `floor` (a second guard). Returns the total written. Throws `Stop`.
    func extract(archive path: String, into dest: URL, cap: Int64, floor: Int64, cancel: () -> Bool, inChunk: Int = 1 << 16, outChunk: Int = 1 << 18) throws -> Int64 {
        let afd = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard afd >= 0 else { throw Stop.refused("The file can't be opened.") }
        defer { close(afd) }
        let root = Darwin.open(dest.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw Stop.refused("The unpacking folder can't be opened.") }
        defer { close(root) }
        /// The folder at `comps` under the root, made as needed, a new descriptor each time (the caller closes it).
        func folder(_ comps: [String]) throws -> Int32 {
            var cur = dup(root)
            guard cur >= 0 else { throw Stop.refused("The unpacking folder can't be used.") }
            for c in comps {
                if mkdirat(cur, c, 0o700) != 0, errno != EEXIST { close(cur); throw Stop.refused("A folder of the zip couldn't be made.") }
                let n = openat(cur, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                close(cur)
                guard n >= 0 else { throw Stop.refused("The zip names a file where a folder goes (or a link); refused.") }
                cur = n
            }
            return cur
        }
        let inCap = max(1, inChunk), outCap = max(1, outChunk)         // (64 KB in, 256 KB out; a check passes small ones to meet every edge)
        let inBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: inCap), outBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: outCap)
        defer { inBuf.deallocate(); outBuf.deallocate() }
        var total: Int64 = 0, sinceRoom: Int64 = 0
        func alive() throws { if cancel() || SessionsImport.quitting { throw Stop.stopped } }
        func room() throws {
            try alive()
            // (if the disk can't be looked at any more, it is not unpacked on unguarded: it stops)
            guard let v = SessionsImport.volumeSpace(dest.path) else { throw Stop.refused("The disk can't be looked at any more, so the unpacking stopped; refused.") }
            if v.free < floor { throw Stop.diskFull }
        }
        for e in entries.sorted(by: { $0.offset < $1.offset }) {
            try room()
            let comps = (e.isDir ? String(e.name.dropLast()) : e.name).split(separator: "/").map(String.init)
            if e.isDir { close(try folder(comps)); continue }
            guard let leaf = comps.last, e.method == 0 || e.method == 8 else { throw Stop.refused("The zip uses a compression that an export doesn't; refused.") }
            // a deflate entry holds at least its end block; a stored one is as long as it is
            if e.method == 0, e.csize != e.usize { throw Stop.refused("A stored entry's two sizes differ; refused.") }
            if e.method == 8, e.csize == 0 { throw Stop.refused("A deflate entry holds no data; refused.") }
            guard let h = ZipIndex.bytes(afd, e.offset, 30), h[0] == 0x50, h[1] == 0x4B, h[2] == 0x03, h[3] == 0x04 else { throw Stop.refused("The zip is damaged.") }
            var start = e.offset
            for add in [UInt64(30), UInt64(ZipIndex.le16(h, 26)), UInt64(ZipIndex.le16(h, 28))] {
                let (s, o) = start.addingReportingOverflow(add); guard !o else { throw Stop.refused("The zip is damaged.") }; start = s
            }
            let (stop, over) = start.addingReportingOverflow(e.csize)
            guard !over, stop <= UInt64(size) else { throw Stop.refused("The zip is damaged.") }
            let pfd = try folder(Array(comps.dropLast()))
            defer { close(pfd) }
            let out = openat(pfd, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard out >= 0 else { throw Stop.refused("The zip names a file twice, or one that is there already; refused.") }
            var good = false
            defer { close(out); if !good { unlinkat(pfd, leaf, 0) } }

            var written: UInt64 = 0, crc: UInt32 = 0
            /// A piece of output: within the entry's own size and the total's cap, then written and counted.
            func emit(_ p: UnsafeBufferPointer<UInt8>) throws {
                if p.isEmpty { return }
                guard written + UInt64(p.count) <= e.usize else { throw Stop.refused("An entry unpacks to more than its directory says; refused.") }
                guard total + Int64(p.count) <= cap else { throw Stop.refused("The zip unpacks to more than it declared; refused.") }
                // (the volume is looked at per MB written and at every entry, not per piece: statfs per 256 KB piece was waste)
                sinceRoom += Int64(p.count)
                if sinceRoom >= 1 << 20 { sinceRoom = 0; try room() } else { try alive() }
                var done = 0
                while done < p.count {
                    let w = Darwin.write(out, p.baseAddress! + done, p.count - done)
                    if w < 0, errno == EINTR { continue }
                    // only a full disk says so; any other failure (EIO, a quota ...) is told as what it is
                    if w < 0, errno == ENOSPC { throw Stop.diskFull }
                    guard w > 0 else { throw Stop.refused("A file couldn't be written (\(w < 0 ? String(cString: strerror(errno)) : "no bytes taken")); nothing was kept.") }
                    done += w
                }
                crc = ZipIndex.crc32(crc, p)
                written += UInt64(p.count); total += Int64(p.count)
                SessionsImport.peakUsed = total
            }
            var pos = start, remaining = e.csize
            if e.method == 0 {
                while remaining > 0 {
                    let n = Int(min(UInt64(outCap), remaining))
                    guard pread(afd, outBuf, n, off_t(pos)) == n else { throw Stop.refused("The zip is damaged.") }
                    try emit(UnsafeBufferPointer(start: outBuf, count: n))
                    pos += UInt64(n); remaining -= UInt64(n)
                }
            } else {
                // zlib's raw inflate: its contract is exact. At Z_STREAM_END, avail_in is the number of input bytes AFTER the stream's end,
                // so bytes hidden in an entry's slack (a record, anything) are seen however well the data compresses. (Apple's Compression
                // reports the end without saying how much input it used, and with high-ratio data takes a whole chunk's slack unseen.)
                let zp = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)      // (on the heap: zlib checks that its state still belongs to this address)
                zp.initialize(to: z_stream())
                defer { zp.deallocate() }
                guard inflateInit2_(zp, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Stop.refused("The zip can't be unpacked here.") }
                defer { inflateEnd(zp) }
                var ended = false, outputPending = false
                while !ended {
                    try alive()
                    if zp.pointee.avail_in == 0 {
                        // the next chunk is read whenever the last one is used up and the entry has more, whether or not output is pending
                        // (a chunk can end on the very call that fills the output buffer; zlib still needs the next one to go on)
                        if remaining > 0 {
                            let n = Int(min(UInt64(inCap), remaining))
                            guard pread(afd, inBuf, n, off_t(pos)) == n else { throw Stop.refused("The zip is damaged.") }
                            zp.pointee.next_in = inBuf; zp.pointee.avail_in = uInt(n)
                            pos += UInt64(n); remaining -= UInt64(n)
                        } else if !outputPending {
                            throw Stop.refused("A deflate stream ends after its entry's bytes do (it is cut short); refused.")      // nothing more to give it, nothing more to take out
                        }
                    }
                    let inBefore = zp.pointee.avail_in
                    zp.pointee.next_out = outBuf; zp.pointee.avail_out = uInt(outCap)
                    let r = inflate(zp, Z_NO_FLUSH)
                    let produced = outCap - Int(zp.pointee.avail_out)
                    outputPending = zp.pointee.avail_out == 0
                    try emit(UnsafeBufferPointer(start: outBuf, count: produced))
                    switch r {
                    case Z_STREAM_END: ended = true
                    case Z_OK, Z_BUF_ERROR:
                        // nothing taken and nothing made: no progress; it would turn forever. With no input to give it, the stream was cut
                        // short; with input available, it is damaged.
                        if produced == 0, zp.pointee.avail_in == inBefore {
                            throw Stop.refused(inBefore == 0 ? "A deflate stream ends after its entry's bytes do (it is cut short); refused." : "A deflate stream is damaged; refused.")
                        }
                    default: throw Stop.refused("A deflate stream is damaged; refused.")      // Z_DATA_ERROR, Z_NEED_DICT, Z_MEM_ERROR ...
                    }
                }
                // it must end exactly where the directory says the entry's bytes end: no input left over (a record hidden there), none unread
                guard zp.pointee.avail_in == 0, remaining == 0 else { throw Stop.refused("A deflate stream ends before its entry's bytes do (something sits after it); refused.") }
            }
            guard written == e.usize else { throw Stop.refused("An entry unpacks to less than its directory says; refused.") }
            guard crc == e.crc else { throw Stop.refused("An entry's CRC isn't the one its directory states; refused.") }
            if let t = e.mtime {
                let ts = timespec(tv_sec: Int(t.timeIntervalSince1970), tv_nsec: 0)
                var times = [ts, ts]
                futimens(out, &times)
            }
            good = true
        }
        return total
    }

    /// Why this name can't be an entry of an export, or nil. Every part is a plain name; the path is relative.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty || name.contains("\0") || name.contains("\\") || name.hasPrefix("/") { return "a name that isn't a relative path" }
        let body = name.hasSuffix("/") ? String(name.dropLast()) : name
        let c = body.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if c.count > 16 { return "a path that is too deep" }
        // (a name a path API can't hold would unpack through descriptors and then strand its folder: the whole name stays short,
        // and every part is one a volume can store)
        if name.utf8.count > 512 || c.contains(where: { $0.utf8.count > 255 }) { return "a name that is too long" }
        for part in c where !SessionsRestore.plainName(part) { return "a name with \"..\" or an empty part" }
        return nil
    }

    /// The bytes of a small member, read out of the zip itself (stored or deflated), never more than `limit`.
    func read(_ e: Entry, path: String, limit: Int) throws -> Data {
        guard e.usize <= UInt64(limit), e.csize <= UInt64(limit) + 1024 else { throw ArchiveError("\(e.name) is bigger than it should be.") }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ArchiveError("The file can't be opened.") }
        defer { close(fd) }
        guard let h = ZipIndex.bytes(fd, e.offset, 30), h[0] == 0x50, h[1] == 0x4B, h[2] == 0x03, h[3] == 0x04 else { throw ArchiveError("The zip is damaged.") }
        var start = e.offset
        for add in [UInt64(30), UInt64(ZipIndex.le16(h, 26)), UInt64(ZipIndex.le16(h, 28))] {
            let (s, o) = start.addingReportingOverflow(add)
            guard !o else { throw ArchiveError("The zip is damaged.") }
            start = s
        }
        let (stop, over) = start.addingReportingOverflow(e.csize)
        guard !over, stop <= UInt64(size), let raw = ZipIndex.bytes(fd, start, Int(e.csize)) else { throw ArchiveError("The zip is damaged.") }
        if e.method == 0 {
            guard UInt64(raw.count) == e.usize else { throw ArchiveError("The zip is damaged.") }
            return Data(raw)
        }
        guard e.method == 8 else { throw ArchiveError("The zip uses a compression that an export doesn't.") }
        // zlib, in one go: the stream must end inside the entry's bytes with none left over, the output exactly usize, the CRC the directory's
        var dst = [UInt8](repeating: 0, count: Int(e.usize) + 1)             // (one byte of room, so an overrun shows)
        let zp = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        zp.initialize(to: z_stream())
        defer { zp.deallocate() }
        guard inflateInit2_(zp, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ArchiveError("The zip can't be unpacked here.") }
        defer { inflateEnd(zp) }
        let bad = ArchiveError("\(e.name) doesn't unpack to the size the zip says.")
        let (r, left, made): (Int32, UInt32, Int) = raw.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { out in
                zp.pointee.next_in = UnsafeMutablePointer(mutating: src.baseAddress); zp.pointee.avail_in = uInt(src.count)
                zp.pointee.next_out = out.baseAddress; zp.pointee.avail_out = uInt(out.count)
                let r = inflate(zp, Z_FINISH)
                return (r, zp.pointee.avail_in, out.count - Int(zp.pointee.avail_out))
            }
        }
        guard r == Z_STREAM_END, left == 0, UInt64(made) == e.usize else { throw bad }
        dst.removeLast()
        guard dst.withUnsafeBufferPointer({ ZipIndex.crc32(0, $0) }) == e.crc else { throw ArchiveError("\(e.name)'s CRC isn't the one the zip states.") }
        return Data(dst)
    }
}

// MARK: - the import

enum SessionsImport {
    /// More than this is never unpacked, whatever a file says.
    static let ceiling: Int64 = 128 << 30
    static let maxFiles = 1_000_000
    /// What a work folder carries to say who it belongs to (a pid and when that process started).
    static let ownerFile = ".owner"
    /// How many bytes the last zip's unpacking had written when it ended or was stopped (a check reads it: a bomb must stop
    /// at its declared size, so this stays small).
    nonisolated(unsafe) static var peakUsed: Int64 = 0

    /// The work folders (unpacking, exporting) of this process that exist now: cl_audit quitting takes them away, images
    /// detached, whatever page they belong to (SettingsModel.leaveArchiveWork, and applicationWillTerminate).
    private static let activeLock = NSLock()
    nonisolated(unsafe) private static var active = Set<URL>()
    /// Detaches an image (forced if it must be). A check's seam: it replaces this to leave a mount point in place.
    nonisolated(unsafe) static var detach: (URL) -> Void = { mnt in
        if Tool.run("/usr/bin/hdiutil", ["detach", mnt.path, "-quiet"])?.status != 0 { _ = Tool.run("/usr/bin/hdiutil", ["detach", mnt.path, "-force", "-quiet"]) }
    }
    static func register(_ work: URL) { activeLock.lock(); active.insert(work); activeLock.unlock() }
    static func unregister(_ work: URL) { activeLock.lock(); active.remove(work); activeLock.unlock() }
    /// Whether the folder with this stat is one of this process's work folders in use (by device and inode, so a different spelling of the
    /// same path can't hide it).
    static func inUse(_ st: stat) -> Bool {
        activeLock.lock(); let all = active; activeLock.unlock()
        for w in all {
            var s = stat()
            if lstat(w.path, &s) == 0, s.st_dev == st.st_dev, s.st_ino == st.st_ino { return true }
        }
        return false
    }

    /// cl_audit is quitting: the tools it runs are stopped, then every work folder it has goes (an attached image detached).
    static func shutDown() {
        quitting = true                                // the loops that unpack or copy stop at their next step
        Tool.killAll()
        usleep(100_000)
        activeLock.lock(); let all = active; activeLock.unlock()
        guard !all.isEmpty else { return }
        // a tree can be big: removed off this thread, and waited for two seconds at most (the next launch's sweep takes the rest)
        let g = DispatchGroup()
        for w in all { g.enter(); DispatchQueue.global(qos: .userInitiated).async { discard(w); g.leave() } }
        _ = g.wait(timeout: .now() + 2)
    }

    static func totalBytes(_ path: String) -> Int64 {
        var fs = statfs()
        return statfs(path, &fs) == 0 ? Int64(fs.f_blocks) * Int64(fs.f_bsize) : 0
    }

    /// cl_audit is quitting: loops that unpack or copy stop at their next step.
    nonisolated(unsafe) static var quitting = false
    /// A check's seam: what the volume says about its space (a disk that fills, a statfs that fails).
    nonisolated(unsafe) static var spaceSeam: ((String) -> (free: Int64, total: Int64)?)?

    /// What the volume under `path` has free, and its size; nil when that can't be told (then nothing is unpacked, and an
    /// unpacking that loses it stops: it never runs unguarded).
    static func volumeSpace(_ path: String) -> (free: Int64, total: Int64)? {
        if let s = spaceSeam { return s(path) }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return (Int64(fs.f_bavail) * Int64(fs.f_bsize), Int64(fs.f_blocks) * Int64(fs.f_bsize))
    }

    /// What an unpacking must leave free: from the disk's size only (never from what is free: that would refuse a big import
    /// on a big disk that has room): 2 GB or 1% of the volume, whichever is more, and never more than a quarter of it.
    static func unpackFloor(volumeBytes: Int64) -> Int64 { min(max(2 << 30, volumeBytes / 100), volumeBytes / 4) }

    /// Room to unpack `declared` bytes and still leave the floor.
    static func roomFor(declared: Int64, free: Int64, total: Int64) -> Bool { free > declared + unpackFloor(volumeBytes: total) }

    /// The most an unpacking may write in all: twice what export.json states and a little (that is `stated`), plus 8 KB an entry
    /// (the room a small file takes on disk).
    static func unpackCap(stated: Int64, entries: Int) -> Int64 { stated + Int64(entries) * 8192 }

    /// One profile in the file.
    struct PartInfo: Equatable {
        var dir: String
        var name: String
        var profile: String
        var manifest: SessionsBackup.Manifest
    }

    /// A file that was read, checked and unpacked, waiting under the hidden folder `work` for the page to go on.
    struct Opened {
        var file: URL
        var fileName: String
        var container: String               // "zip" or "image"
        var export: ExportManifest
        var work: URL                       // <backups place>/.import-<tag>
        var tree: URL                       // the unpacked, checked tree: work/x/<folder>
        var parts: [PartInfo]
        var sameMac: Bool
    }

    /// An unpacked part made a backup of the target, waiting in `work/stage` (not in the backups place yet).
    struct Staged: Equatable {
        var id: String
        var target: String
        var stage: URL                      // work/stage: a place whose <target>/<id> is the backup
        var backup: SessionsRestore.Backup { SessionsRestore.Backup(profile: target, id: id, place: stage) }
    }

    // MARK: opening

    /// Reads and unpacks `file`; throws why it is refused (nothing is then left behind). `progress` says what is going on.
    static func open(_ file: URL, password: String?, place: URL = BackupPrefs.placeURL, cancel: @escaping () -> Bool = { false },
                     progress: ((String) -> Void)? = nil) throws -> Opened {
        let fm = FileManager.default
        var st = stat()
        guard stat(file.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError("That isn't a plain file.") }
        let ext = file.pathExtension.lowercased()
        guard ext == "zip" || ext == "dmg" else { throw ArchiveError("An export is a .zip or a .dmg.") }
        let tag = UUID().uuidString.prefix(8).lowercased()
        let work = place.appendingPathComponent(".import-\(tag)")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ArchiveError("The backups folder \(tilde(place.path)) can't be written.") }
        // who it belongs to: a later launch sweeps it if this process is gone. A folder that can't be claimed isn't used.
        guard claim(work) else {
            discard(work)
            throw ArchiveError("cl_audit couldn't mark its work folder in \(tilde(place.path)) (the disk may be full or can't be written), so nothing was unpacked.")
        }
        register(work)
        var kept = false
        defer { if !kept { discard(work); unregister(work) } }
        let x = work.appendingPathComponent("x")
        guard mkdir(x.path, 0o700) == 0 else { throw ArchiveError("The backups folder \(tilde(place.path)) can't be written.") }

        let opened: Opened
        if ext == "zip" { opened = try openZip(file, work: work, x: x, cancel: cancel, progress: progress) }
        else { opened = try openImage(file, password: password, work: work, x: x, cancel: cancel, progress: progress) }
        kept = true
        return opened
    }


    /// export.json checked on its own: a newer format and nonsense are refused. Returns it and the size nothing may pass.
    static func checkExport(_ data: Data) throws -> (ExportManifest, Int64) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let em = try? dec.decode(ExportManifest.self, from: data), em.format == ExportManifest.format else { throw ArchiveError("That isn't a cl_audit export (export.json can't be read).") }
        guard em.version >= 1, em.version <= SessionsBackup.formatVersion else { throw ArchiveError("That export is from a newer cl_audit; nothing is imported from it.") }
        guard !em.parts.isEmpty, em.parts.count <= 64, em.bytes >= 0, em.bytes <= ceiling else { throw ArchiveError("export.json states sizes or profiles that can't be right.") }
        var seen = Set<String>(), sum: Int64 = 0
        for p in em.parts {
            guard p.dir.range(of: #"^p[0-9]{1,3}$"#, options: .regularExpression) != nil, seen.insert(p.dir).inserted, p.bytes >= 0, p.bytes <= ceiling,
                  SessionsBackup.validProfile(p.profile) else { throw ArchiveError("export.json names a profile folder that isn't a plain one.") }
            sum += p.bytes
        }
        guard sum == em.bytes else { throw ArchiveError("export.json's sizes don't add up.") }
        return (em, min(ceiling, em.bytes * 2 + (64 << 20)))
    }

    private static func openZip(_ file: URL, work: URL, x: URL, cancel: @escaping () -> Bool, progress: ((String) -> Void)?) throws -> Opened {
        progress?("Reading the zip's directory")
        let index = try ZipIndex.read(path: file.path)
        guard !index.entries.isEmpty else { throw ArchiveError("The zip is empty.") }
        // 1. every name, kind and size, before anything is unpacked
        var top: String?
        var names = Set<String>()
        var declared: UInt64 = 0
        for e in index.entries {
            if let why = ZipIndex.nameProblem(e.name) { throw ArchiveError("The zip holds \(why) (\(e.name.prefix(60))); refused.") }
            if e.flags & 0x1 != 0 || e.flags & 0x40 != 0 { throw ArchiveError("The zip holds an encrypted entry; an export's zip isn't encrypted. Refused.") }
            guard e.method == 0 || e.method == 8 else { throw ArchiveError("The zip uses a compression that an export doesn't; refused.") }
            do {
                // the Unix type bits, whatever the host byte says (nothing here creates a link, but a zip that claims one is not an export)
                let fmt = (e.attrs >> 16) & 0xF000
                if fmt == 0xA000 { throw ArchiveError("The zip holds a link (\(e.name.prefix(60))); refused.") }
                if fmt != 0, fmt != 0x8000, fmt != 0x4000 { throw ArchiveError("The zip holds something that is neither a file nor a folder (\(e.name.prefix(60))); refused.") }
                if fmt == 0x4000, !e.isDir { throw ArchiveError("The zip holds a folder named like a file; refused.") }
                if fmt == 0x8000, e.isDir { throw ArchiveError("The zip holds a file named like a folder; refused.") }
            }
            // a folder holds no data (its bytes would be counted nowhere and written nowhere)
            if e.isDir, e.csize != 0 || e.usize != 0 { throw ArchiveError("The zip holds a folder with data in it (\(e.name.prefix(60))); refused.") }
            let first = String(e.name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0])
            if let t = top, t != first { throw ArchiveError("The zip holds more than one top-level folder; an export has one. Refused.") }
            top = first
            let key = ZipIndex.foldedKey(e.isDir ? String(e.name.dropLast()) : e.name)
            guard names.insert(key).inserted else { throw ArchiveError("The zip names \(e.name.prefix(60)) twice (or two names that are one on this Mac); refused.") }
            // (checked before it is added: a zip64 size of 2^64 - 1 must not trap)
            if e.usize > UInt64(ceiling) - declared { throw ArchiveError("The zip declares more data than an import takes (\(SessionsBackup.sizeWords(ceiling))); refused.") }
            declared += e.usize
        }
        // ditto goes by the local headers: prove the zip is exactly what the directory says before it runs
        try index.verifyLocals(path: file.path)
        guard let root = top, root != "export.json" else { throw ArchiveError("The zip isn't laid out like an export; refused.") }
        guard let em = index.entries.first(where: { $0.name == "\(root)/export.json" }) else { throw ArchiveError("The zip has no export.json; that isn't an export.") }
        // 2. export.json, read out of the zip itself, before anything else
        let (export, stated) = try checkExport(try index.read(em, path: file.path, limit: 4 << 20))
        let cap = unpackCap(stated: stated, entries: index.entries.count)
        guard declared <= UInt64(cap) else {
            throw ArchiveError("The zip declares \(SessionsBackup.sizeWords(Int64(declared))) of data, more than twice the \(SessionsBackup.sizeWords(export.bytes)) its export.json states; refused.")
        }
        guard let vol = volumeSpace(work.path) else { throw ArchiveError("The disk the backups are on can't be looked at (its free space is unknown); nothing is unpacked.") }
        let floor = unpackFloor(volumeBytes: vol.total)
        guard roomFor(declared: Int64(declared), free: vol.free, total: vol.total) else {
            throw ArchiveError("The disk is nearly full: unpacking \(SessionsBackup.sizeWords(Int64(declared))) would leave less than \(SessionsBackup.sizeWords(floor)) free. Nothing was unpacked.")
        }
        // 3. unpacked by cl_audit's own checked reader (ditto goes by the stream, and writes a record hidden after a deflate
        // stream's end): exactly the entries the directory names, each checked as it is written. The bomb guard is exact: a
        // running total of bytes written, against the cap, before every write (an entry may not pass its own size either),
        // and the volume's free space against the floor at every step as a second guard.
        progress?("Unpacking")
        peakUsed = 0
        let tree = x.appendingPathComponent(root)
        do { _ = try index.extract(archive: file.path, into: x, cap: cap, floor: floor, cancel: cancel) }
        catch ZipIndex.Stop.refused(let why) { throw ArchiveError(why) }
        catch ZipIndex.Stop.diskFull { throw ArchiveError("The disk is nearly full; stopped, and nothing was kept.") }
        catch ZipIndex.Stop.stopped { throw ArchiveError("Stopped.") }
        // nothing may have landed beside the folder made for it
        guard ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter({ $0 != ownerFile }).sorted() == ["x"] else { throw ArchiveError("The unpacking wrote outside its folder; refused.") }
        let parts = try validate(tree: tree, export: export, limit: cap, container: "zip")
        return Opened(file: file, fileName: file.lastPathComponent, container: "zip", export: export, work: work, tree: tree, parts: parts,
                      sameMac: export.machine == InstallID.current)
    }

    private static func openImage(_ file: URL, password: String?, work: URL, x: URL, cancel: @escaping () -> Bool, progress: ((String) -> Void)?) throws -> Opened {
        progress?("Opening the disk image")
        guard let enc = Tool.run("/usr/bin/hdiutil", ["isencrypted", file.path]), enc.status == 0 else { throw ArchiveError("That isn't a disk image macOS can read.") }
        guard enc.out.contains("encrypted: YES") else { throw ArchiveError("That disk image isn't encrypted. cl_audit makes only encrypted ones, so it isn't an export; refused.") }
        guard let pw = password, !pw.isEmpty else { throw ArchiveError("password needed") }
        let mnt = work.appendingPathComponent("mnt")
        guard mkdir(mnt.path, 0o700) == 0 else { throw ArchiveError("The backups folder can't be written.") }
        // read-only, not shown in Finder, nothing checked or repaired, the password on stdin (macOS mounts it nosuid, nodev,
        // noowners)
        let args = ["attach", "-stdinpass", "-readonly", "-nobrowse", "-noverify", "-noautofsck", "-noautoopen", "-mountpoint", mnt.path, file.path]
        // (the password is taken in its composed form, so one typed on another keyboard or Mac is the same one)
        let npw = pw.precomposedStringWithCanonicalMapping
        guard let a = Tool.run("/usr/bin/hdiutil", args, stdin: Data(npw.utf8), secret: npw, cancel: cancel) else { throw ArchiveError("hdiutil couldn't start.") }
        if a.cancelled { throw ArchiveError("Stopped.") }
        guard a.status == 0 else {
            let why = a.err.lowercased()
            if why.contains("authentication") || why.contains("passphrase") || why.contains("password") { throw ArchiveError("That password isn't right.") }
            throw ArchiveError("The disk image couldn't be opened (\(a.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))).")
        }
        defer {
            detach(mnt)
        }
        // it must really be read-only, nosuid and nodev: what macOS was asked for is checked, not assumed
        var mfs = statfs()
        guard statfs(mnt.path, &mfs) == 0, mfs.f_flags & UInt32(MNT_RDONLY) != 0, mfs.f_flags & UInt32(MNT_NOSUID) != 0, mfs.f_flags & UInt32(MNT_NODEV) != 0 else {
            throw ArchiveError("The image wasn't mounted read-only with no setuid files or devices; refused.")
        }
        // the folder at the volume's top (hidden things macOS puts there are never looked into)
        let tops = ((try? FileManager.default.contentsOfDirectory(atPath: mnt.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard tops.count == 1, SessionsRestore.plainName(tops[0]) else { throw ArchiveError("The disk image isn't laid out like an export; refused.") }
        let rootName = tops[0]
        let mounted = mnt.appendingPathComponent(rootName)
        guard let exportData = try? readSmall(mounted.appendingPathComponent("export.json").path, limit: 4 << 20) else { throw ArchiveError("The image has no export.json; that isn't an export.") }
        let (export, cap) = try checkExport(exportData)
        guard let vol = volumeSpace(work.path) else { throw ArchiveError("The disk the backups are on can't be looked at (its free space is unknown); nothing is copied.") }
        guard roomFor(declared: export.bytes, free: vol.free, total: vol.total) else {
            throw ArchiveError("The disk is nearly full: copying \(SessionsBackup.sizeWords(export.bytes)) out would leave less than \(SessionsBackup.sizeWords(unpackFloor(volumeBytes: vol.total))) free. Nothing was copied.")
        }
        // checked where it is, then copied out file by file (plain files with one link only)
        _ = try validate(tree: mounted, export: export, limit: cap, container: "image", normalize: false)
        progress?("Copying the files out of the image")
        let tree = x.appendingPathComponent(rootName)
        try copyTree(from: mounted, to: tree, cancel: cancel)
        let parts = try validate(tree: tree, export: export, limit: cap, container: "image")
        return Opened(file: file, fileName: file.lastPathComponent, container: "image", export: export, work: work, tree: tree, parts: parts,
                      sameMac: export.machine == InstallID.current)
    }

    private static func readSmall(_ path: String, limit: Int) throws -> Data {
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveError("can't open") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1, st.st_size <= limit, let d = SessionsRestore.read(fd, size: st.st_size) else {
            throw ArchiveError("not a plain small file")
        }
        return d
    }

    /// Bytes of plain files under `path`, counted without following links; stops counting above `stopAbove`.
    static func treeBytes(_ path: String, stopAbove: Int64) -> Int64 {
        var total: Int64 = 0
        guard let walk = FileManager.default.enumerator(atPath: path) else { return 0 }
        for case let rel as String in walk {
            var st = stat()
            if lstat((path as NSString).appendingPathComponent(rel), &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { total += Int64(st.st_size) }
            if total > stopAbove { return total }
        }
        return total
    }

    // MARK: checking the unpacked tree

    private struct Found { var dirs = Set<String>(); var files: [String: Int64] = [:] }

    /// Walks `dir` with lstat: folders and plain single-link files only, plain names, none like a sign-in. Throws on the first
    /// thing that is not. `normalize` sets modes (0700 / 0600) on what is walked (it is ours).
    /// Extended attributes macOS puts on a new file by itself (what a file made here is found to carry): nothing else may come.
    static let allowedXattrs: Set<String> = ["com.apple.provenance"]

    /// Why this entry can't be taken: a file flag (uchg and the like would land immutable, and Undo and the sweep couldn't
    /// remove it), a setuid/setgid/sticky bit, an ACL or an extended attribute. nil: plain. Only "compressed" is harmless.
    static func attributeProblem(_ path: String, _ st: stat) -> String? {
        if st.st_flags & ~UInt32(UF_COMPRESSED) != 0 { return "a file flag" }
        if st.st_mode & 0o7000 != 0 { return "a setuid, setgid or sticky bit" }
        if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); return "an access control list" }
        let n = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if n < 0 { return "extended attributes that can't be read" }
        if n > 0 {
            var buf = [CChar](repeating: 0, count: n)
            let got = listxattr(path, &buf, n, XATTR_NOFOLLOW)
            if got < 0 { return "extended attributes that can't be read" }
            let names = buf.withUnsafeBufferPointer { p -> [String] in
                var out: [String] = [], cur: [UInt8] = []
                for c in p.prefix(got) { if c == 0 { out.append(String(decoding: cur, as: UTF8.self)); cur = [] } else { cur.append(UInt8(bitPattern: c)) } }
                return out
            }
            if names.contains(where: { !allowedXattrs.contains($0) }) { return "extended attributes" }
        }
        return nil
    }

    private static func walk(_ dir: URL, limit: Int64, normalize: Bool) throws -> Found {
        var f = Found()
        var total: Int64 = 0
        func visit(_ path: String, _ rel: String, _ depth: Int) throws {
            guard depth <= 16 else { throw ArchiveError("The export has folders nested too deep; refused.") }
            // a mode that can't be set is fatal: what can't be made private isn't taken
            if normalize, chmod(path, 0o700) != 0 { throw ArchiveError("A folder of the export couldn't be made private; refused.") }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: path) } catch { throw ArchiveError("A folder in the export can't be read; refused.") }
            for n in names.sorted() {
                guard SessionsRestore.plainName(n), n.utf8.count <= 255 else { throw ArchiveError("The export holds a name that isn't a plain one; refused.") }
                // Claude Code's setup (profiles/pN/setup/…) is the operator's own files: `auth.py`, `token-counter.md` and
                // `credentials-guide.md` are legitimate there, so only the exact excluded names are refused (.claude.json*, .credentials*,
                // settings.local.json, a settings.json that isn't the top one); everywhere else the sign-in-like rule stands
                let parent = rel.split(separator: "/")
                if parent.count >= 3, parent[0] == "profiles", parent[2] == "setup" {
                    if Setup.excludedName(n, top: parent.count == 3) { throw ArchiveError("The export holds a file with a sign-in name in its setup (\(n.prefix(40))). An export never does; refused.") }
                } else if SessionsBackup.isSignIn(n) { throw ArchiveError("The export holds something named like a sign-in (\(n.prefix(40))). An export never holds one; refused.") }
                let child = (path as NSString).appendingPathComponent(n)
                let r = rel.isEmpty ? n : rel + "/" + n
                var st = stat()
                guard lstat(child, &st) == 0 else { throw ArchiveError("A file in the export vanished; refused.") }
                if (st.st_mode & S_IFMT) == S_IFDIR || (st.st_mode & S_IFMT) == S_IFREG, let why = attributeProblem(child, st) {
                    throw ArchiveError("The export holds a file or folder with \(why) (\(n.prefix(40))); an export never does. Refused.")
                }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    f.dirs.insert(r)
                    try visit(child, r, depth + 1)
                case S_IFREG:
                    guard st.st_nlink == 1 else { throw ArchiveError("The export holds a file with another hard link (\(n.prefix(40))); refused.") }
                    let (t, over) = total.addingReportingOverflow(Int64(st.st_size))
                    guard !over, t <= limit, f.files.count < maxFiles else { throw ArchiveError("The export holds more than it declared; refused.") }
                    total = t
                    f.files[r] = Int64(st.st_size)
                    if normalize, chmod(child, 0o600) != 0 { throw ArchiveError("A file of the export couldn't be made private; refused.") }
                case S_IFLNK: throw ArchiveError("The export holds a link (\(n.prefix(40))); refused.")
                default: throw ArchiveError("The export holds something that is neither a file nor a folder (\(n.prefix(40))); refused.")
                }
            }
        }
        try visit(dir.path, "", 0)
        return f
    }

    /// The tree must be exactly an export: export.json and profiles/pN/ with each backup.json and the files it names.
    private static func validate(tree: URL, export: ExportManifest, limit: Int64, container: String, normalize: Bool = true) throws -> [PartInfo] {
        var rootStat = stat()
        guard lstat(tree.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) == S_IFDIR else { throw ArchiveError("The export's folder isn't a plain folder; refused.") }
        let found = try walk(tree, limit: limit, normalize: normalize)
        guard let ej = try? readSmall(tree.appendingPathComponent("export.json").path, limit: 4 << 20) else { throw ArchiveError("export.json isn't a plain file; refused.") }
        let (again, _) = try checkExport(ej)
        guard again == export else { throw ArchiveError("export.json changed while it was being read; refused.") }
        var expectedFiles: [String: Int64] = [:]
        var expectedDirs: Set<String> = ["profiles"]
        expectedFiles["export.json"] = Int64(ej.count)
        var parts: [PartInfo] = []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for p in export.parts {
            let base = "profiles/\(p.dir)"
            expectedDirs.insert(base)
            // (64 MB: what SessionsRestore reads a backup.json with, so one that is bigger is refused here rather than later)
            guard let size = found.files["\(base)/backup.json"], size <= 64 << 20,
                  let bj = try? readSmall(tree.appendingPathComponent("\(base)/backup.json").path, limit: 64 << 20),
                  let m = try? dec.decode(SessionsBackup.Manifest.self, from: bj) else { throw ArchiveError("A profile's backup.json is missing or can't be read; refused.") }
            guard m.version >= 1, m.version <= SessionsBackup.formatVersion else { throw ArchiveError("That export holds a backup from a newer cl_audit; nothing is imported from it.") }
            guard SessionsBackup.validID(m.id), SessionsBackup.validProfile(m.profile), m.items.count <= maxFiles else { throw ArchiveError("A profile's backup.json names things that aren't plain ones; refused.") }
            expectedFiles["\(base)/backup.json"] = size
            var seen = Set<String>(), sum: Int64 = 0
            var setupRels: [String] = []
            for it in m.items {
                guard let c = SessionsRestore.components(it.path), seen.insert(it.path).inserted else { throw ArchiveError("A backup.json names a path that isn't a plain one (\(it.path.prefix(60))); refused.") }
                switch it.role {
                case .window: guard c.count == 4, c[0] == "window", Fingerprint.isValid(c[1]), Fingerprint.isValid(c[2]) else { throw ArchiveError("A backup.json names a window file in a place an export doesn't keep them; refused.") }
                case .transcript: guard c.count >= 3, c[0] == "transcripts" else { throw ArchiveError("A backup.json names a transcript in a place an export doesn't keep them; refused.") }
                case .sidebar: guard c == ["sidebar", "epitaxyPrefs.json"] else { throw ArchiveError("A backup.json names a sidebar file in a place an export doesn't keep it; refused.") }
                case .record: guard c.count == 2, c[0] == "records" else { throw ArchiveError("A backup.json names a record in a place an export doesn't keep them; refused.") }
                case .setup:
                    // Claude Code's setup: only the places and names an export carries (SessionsSetup.swift), a SHA-256 for every file,
                    // the execute flag only on a skill's own files and on scripts, and the sensitive part only from an encrypted image
                    guard m.version >= 2, c.count >= 2, c[0] == "setup", Setup.pathProblem(Array(c.dropFirst())) == nil else {
                        throw ArchiveError("A backup.json names a setup file in a place, or with a name, an export doesn't carry (\(it.path.prefix(60))); refused.")
                    }
                    let rel = c.dropFirst().joined(separator: "/")
                    guard let h = it.sha, h.count == 64, h.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ArchiveError("A setup file has no valid hash in backup.json (\((c.last ?? "").prefix(40))); refused.") }
                    if it.exec == true, !Setup.execAllowed(rel) { throw ArchiveError("backup.json marks a file executable that is neither a skill's own file nor a script settings.json points to (\((c.last ?? "").prefix(40))); refused.") }
                    if Setup.sensitive(rel), container != "image" { throw ArchiveError("A zip carries no settings.json, hook scripts or plugin marketplaces (only the encrypted disk image does); refused.") }
                    setupRels.append(rel)
                }
                guard let real = found.files["\(base)/\(it.path)"] else { throw ArchiveError("A file backup.json names is missing (\((c.last ?? "").prefix(40))); refused.") }
                guard real == it.bytes, it.bytes >= 0 else { throw ArchiveError("A file's size isn't the size backup.json states (\((c.last ?? "").prefix(40))); refused.") }
                if it.role == .setup, Setup.sha(path: tree.appendingPathComponent("\(base)/\(it.path)").path) != it.sha {
                    throw ArchiveError("A setup file isn't what backup.json says it is (\((c.last ?? "").prefix(40))); refused.")
                }
                expectedFiles["\(base)/\(it.path)"] = real
                for k in 1..<c.count { expectedDirs.insert(base + "/" + c[0..<k].joined(separator: "/")) }
                let (s, over) = sum.addingReportingOverflow(it.bytes)
                guard !over else { throw ArchiveError("A profile's sizes don't add up; refused.") }
                sum = s
            }
            guard sum == p.bytes, sum == m.bytes else { throw ArchiveError("A profile's sizes don't add up; refused.") }
            // a script comes only with the settings.json whose own hook or status-line commands name it, and an included file only
            // with the CLAUDE.md that includes it (an `@` line, followed the way the export followed it): what is left over (a path no
            // command runs, an .md nothing includes) is not part of the setup, and is refused, never guessed at
            let scripts = setupRels.filter { Setup.unit(of: $0).kind == .script }
            if !scripts.isEmpty {
                guard setupRels.contains("settings.json"), let sd = try? readSmall(tree.appendingPathComponent("\(base)/setup/settings.json").path, limit: 8 << 20) else {
                    throw ArchiveError("A script is in the export without the settings.json that points to it; refused.")
                }
                let named = Setup.namedPaths(in: sd, among: scripts)
                if let bad = scripts.first(where: { !named.contains($0) }) { throw ArchiveError("A script no hook in settings.json points to (\(bad.prefix(50))); refused.") }
            }
            let includes = setupRels.filter { Setup.unit(of: $0).kind == .include }
            if !includes.isEmpty {
                let carried = Set(setupRels)
                let allowed = Setup.includeClosure(carried: carried) { rel in try? readSmall(tree.appendingPathComponent("\(base)/setup/\(rel)").path, limit: 4 << 20) }
                if let bad = includes.first(where: { !allowed.contains($0) }) { throw ArchiveError("A file CLAUDE.md in the export doesn't include (\(bad.prefix(50))); refused.") }
            }
            if m.setupLeftOut.map({ $0.count > 500 }) == true { throw ArchiveError("A profile's backup.json lists too many left-out setup names; refused.") }
            parts.append(PartInfo(dir: p.dir, name: p.name, profile: p.profile, manifest: m))
        }
        // nothing else: not a file, not a folder
        if let extra = found.files.keys.sorted().first(where: { expectedFiles[$0] == nil }) { throw ArchiveError("The export holds a file its manifests don't name (\((extra as NSString).lastPathComponent.prefix(40))); refused.") }
        if let extra = found.dirs.sorted().first(where: { !expectedDirs.contains($0) }) { throw ArchiveError("The export holds a folder its manifests don't name (\((extra as NSString).lastPathComponent.prefix(40))); refused.") }
        return parts
    }

    /// Copies a checked tree out of a mounted image: folders made new, files by the backup's copy rules.
    private static func copyTree(from: URL, to: URL, cancel: () -> Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let walk = fm.enumerator(atPath: from.path) else { throw ArchiveError("The image can't be read.") }
        for case let rel as String in walk {
            if cancel() || quitting { throw ArchiveError("Stopped.") }
            let src = (from.path as NSString).appendingPathComponent(rel), dst = (to.path as NSString).appendingPathComponent(rel)
            var st = stat()
            guard lstat(src, &st) == 0 else { throw ArchiveError("A file in the image vanished; refused.") }
            if (st.st_mode & S_IFMT) == S_IFDIR { guard mkdir(dst, 0o700) == 0 else { throw ArchiveError("Couldn't unpack the image.") }; continue }
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError("The image holds something that isn't a plain file; refused.") }
            try copyData(src, dst)
        }
    }

    /// A file as DATA ONLY, for what comes off a mounted image: made new (O_EXCL, 0600) and written from the opened source;
    /// no file flag, ACL, extended attribute or mode bit comes along (fcopyfile with COPYFILE_ALL and a clone would carry
    /// them). Then looked at again through its own descriptor: a flag, an ACL (a folder's inherited one) or an attribute on
    /// what landed refuses the import.
    static func copyData(_ src: String, _ dst: String) throws {
        let fd = Darwin.open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ArchiveError("A file in the image vanished; refused.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { throw ArchiveError("A file in the image isn't a plain file with one link; refused.") }
        let out = Darwin.open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw ArchiveError("Couldn't unpack the image.") }
        var ok = false
        defer { close(out); if !ok { unlink(dst) } }
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var off: off_t = 0
        while true {
            let n = pread(fd, &buf, buf.count, off)
            if n < 0 { throw ArchiveError("Couldn't unpack the image.") }
            if n == 0 { break }
            var done = 0
            while done < n {
                let w = buf.withUnsafeBytes { Darwin.write(out, $0.baseAddress! + done, n - done) }
                guard w > 0 else { throw ArchiveError("Couldn't unpack the image (the disk may be full).") }
                done += w
            }
            off += off_t(n)
        }
        guard fchmod(out, 0o600) == 0 else { throw ArchiveError("A file of the image couldn't be made private; refused.") }
        var times = [st.st_atimespec, st.st_mtimespec]
        futimens(out, &times)
        // what landed, through its own descriptor
        var landed = stat()
        guard fstat(out, &landed) == 0, landed.st_flags & ~UInt32(UF_COMPRESSED) == 0, landed.st_mode & 0o7777 == 0o600, landed.st_nlink == 1 else {
            throw ArchiveError("A file copied out of the image carries something it shouldn't; refused.")
        }
        if let acl = acl_get_fd_np(out, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw ArchiveError("A file copied out of the image has an access control list; refused.") }
        let xn = flistxattr(out, nil, 0, 0)
        if xn > 0 {
            var names = [CChar](repeating: 0, count: xn)
            let got = flistxattr(out, &names, xn, 0)
            let list = got < 0 ? ["?"] : String(decoding: names.prefix(got).map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "\0").map(String.init)
            if list.contains(where: { !allowedXattrs.contains($0) }) { throw ArchiveError("A file copied out of the image has extended attributes; refused.") }
        }
        ok = true
    }

    // MARK: making the backup of the target

    /// Makes the part a new backup of `target` in `work/stage`. Cloned or copied file by file; its backup.json is the part's
    /// with the target's id, this moment, kind imported, and no path of the other Mac.
    static func materialize(_ o: Opened, part: PartInfo, target: String, now: Date = Date(), cancel: () -> Bool = { false }) throws -> Staged {
        guard SessionsBackup.validProfile(target) else { throw ArchiveError("The profile's name isn't a plain one.") }
        let fm = FileManager.default
        let stage = o.work.appendingPathComponent("stage")
        let id = SessionsBackup.newID(now)
        let profileDir = stage.appendingPathComponent(target)
        let partial = profileDir.appendingPathComponent(".\(id).partial")
        let final = profileDir.appendingPathComponent(id)
        // never made again: if the work folder is gone (the page was left, cl_audit is quitting) this stops, it doesn't remake it
        var wst = stat()
        guard lstat(o.work.path, &wst) == 0, (wst.st_mode & S_IFMT) == S_IFDIR else { throw ArchiveError("Stopped.") }
        if mkdir(stage.path, 0o700) != 0, errno != EEXIST { throw ArchiveError(errno == ENOENT ? "Stopped." : "The backups folder can't be written.") }
        if mkdir(profileDir.path, 0o700) != 0, errno != EEXIST { throw ArchiveError(errno == ENOENT ? "Stopped." : "The backups folder can't be written.") }
        guard mkdir(partial.path, 0o700) == 0 else { throw ArchiveError(errno == ENOENT ? "Stopped." : "The backups folder can't be written.") }
        var done = false
        defer { if !done { try? fm.removeItem(at: partial) } }
        let from = o.tree.appendingPathComponent("profiles/\(part.dir)")
        var made = Set<String>()
        var cloned = 0, copied = 0, copiedBytes: Int64 = 0
        var items: [SessionsBackup.Item] = []
        var counts = SessionsBackup.Counts()
        var seats = Set<SeatID>()
        for it in part.manifest.items {
            if cancel() { throw ArchiveError("Stopped.") }
            let dst = (partial.path as NSString).appendingPathComponent(it.path)
            let dir = (dst as NSString).deletingLastPathComponent
            var pst = stat()
            guard lstat(partial.path, &pst) == 0 else { throw ArchiveError("Stopped.") }       // the work folder went (the page was left)
            if made.insert(dir).inserted {
                // folders below the backup's own only: never a parent above it (that would make the work folder again)
                var cur = partial.path
                for comp in dir.dropFirst(partial.path.count).split(separator: "/") {
                    cur += "/" + comp
                    if mkdir(cur, 0o700) != 0, errno != EEXIST { throw ArchiveError("Stopped.") }
                }
            }
            switch SessionsBackup.copyOne(from.appendingPathComponent(it.path).path, dst, single: true) {
            case .cloned: cloned += 1
            case .copied: copied += 1; copiedBytes += it.bytes
            case .gone: throw ArchiveError("A file of the export isn't a plain file with one link any more; refused.")
            case .failed(let why): throw ArchiveError("Couldn't copy \((it.path as NSString).lastPathComponent) (\(why)).")
            }
            // what landed is data only: no flag, ACL or attribute (the unpacked tree had none, and a clone or copy takes the
            // source's: so a restore that clones from this backup brings none either)
            var lst = stat()
            guard lstat(dst, &lst) == 0, attributeProblem(dst, lst) == nil, lst.st_mode & 0o7777 == 0o600 else {
                throw ArchiveError("A file of the export carries a flag, an ACL, an attribute or a mode an export doesn't; refused.")
            }
            var n = it
            n.original = it.path                                       // no path of the other Mac
            if n.role != .sidebar { n.part = nil } else if n.part != "preferences.epitaxyPrefs" { n.part = "preferences.epitaxyPrefs" }
            if n.role != .setup { n.sha = nil; n.exec = nil }          // (a hash and an execute flag mean something for setup only)
            items.append(n)
            // the counts are made from what was verified, not read from the file's own claim
            let c = it.path.split(separator: "/").map(String.init)
            let name = c.last ?? ""
            if it.role == .window, c.count == 4 {
                seats.insert(SeatID(account: c[1], organization: c[2]))
                if name.hasPrefix("local_"), name.hasSuffix(".json") {
                    counts.sessions += 1
                    if !SidebarPlan.flag("isArchived", in: FileManager.default.contents(atPath: dst) ?? Data()) { counts.sidebar += 1 }
                } else if name == "scheduled-tasks.json",
                          let d = FileManager.default.contents(atPath: dst), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    counts.tasks += (j["scheduledTasks"] as? [Any])?.count ?? 0
                }
            } else if it.role == .transcript, c.count == 3, name.hasSuffix(".jsonl") { counts.transcripts += 1 }
        }
        var m = part.manifest
        m.id = id; m.profile = target; m.kind = .imported(o.fileName); m.created = now; m.seconds = 0
        m.cloned = cloned; m.copied = copied; m.copiedBytes = copiedBytes
        m.dataDir = ""; m.codeDir = ""; m.items = items
        m.accounts = seats.sorted { ($0.account, $0.organization) < ($1.account, $1.organization) }   // fingerprints, rebuilt
        m.counts = counts
        m.bytes = items.reduce(0) { $0 + $1.bytes }
        m.window = items.contains { $0.role == .window || $0.role == .sidebar }
        m.transcripts = items.contains { $0.role == .transcript }
        m.leftOut = min(max(0, m.leftOut), maxFiles)
        m.version = SessionsBackup.formatVersion
        // (names of setup left out at the source: shown as text only, so cut to plain short ones)
        m.setupLeftOut = m.setupLeftOut.map { Array($0.prefix(200).map { String($0.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.prefix(100).map(Character.init)) }) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestPath = (partial.path as NSString).appendingPathComponent("backup.json")
        do { try enc.encode(m).write(to: URL(fileURLWithPath: manifestPath), options: .withoutOverwriting) }
        catch { throw ArchiveError("The backups folder can't be written.") }
        guard chmod(manifestPath, 0o600) == 0 else { throw ArchiveError("The backup's manifest couldn't be made private; refused.") }
        guard renamex_np(partial.path, final.path, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveError("Couldn't put the backup in place.") }
        done = true
        return Staged(id: id, target: target, stage: stage)
    }

    /// Another profile in the Into pop-up: the staged backup becomes the new target's (its folder and its backup.json).
    static func retarget(_ s: Staged, to target: String) throws -> Staged {
        guard SessionsBackup.validProfile(target) else { throw ArchiveError("The profile's name isn't a plain one.") }
        if target == s.target { return s }
        let fm = FileManager.default
        guard var m = SessionsBackup.load(profile: s.target, id: s.id, place: s.stage) else { throw ArchiveError("The unpacked backup isn't there any more.") }
        let to = s.stage.appendingPathComponent(target)
        if mkdir(to.path, 0o700) != 0, errno != EEXIST { throw ArchiveError(errno == ENOENT ? "Stopped." : "The backups folder can't be written.") }
        let src = s.stage.appendingPathComponent("\(s.target)/\(s.id)"), dst = to.appendingPathComponent(s.id)
        guard renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveError("Couldn't move the unpacked backup.") }
        m.profile = target
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let file = dst.appendingPathComponent("backup.json")
        let tmp = dst.appendingPathComponent(".backup.json.tmp")
        do {
            try enc.encode(m).write(to: tmp, options: .withoutOverwriting)
            guard chmod(tmp.path, 0o600) == 0 else { throw ArchiveError("Couldn't update the unpacked backup.") }
            guard rename(tmp.path, file.path) == 0 else { throw ArchiveError("Couldn't update the unpacked backup.") }
        } catch { try? fm.removeItem(at: tmp); throw ArchiveError("Couldn't update the unpacked backup.") }
        try? fm.removeItem(at: s.stage.appendingPathComponent(s.target))      // the old profile's (now empty) folder
        return Staged(id: s.id, target: target, stage: s.stage)
    }

    /// The staged backup moves into the backups place as a backup of its profile (a rename on the same disk; never over one).
    static func commit(_ s: Staged, place given: URL? = nil) throws -> SessionsRestore.Backup {
        let fm = FileManager.default
        // the place the work folder is in (General ▸ Backups may have been changed since the file was opened)
        let place = given ?? s.stage.deletingLastPathComponent().deletingLastPathComponent()
        let dir = SessionsBackup.folder(profile: s.target, place: place)
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ArchiveError("The backups folder \(tilde(place.path)) can't be written.") }
        let src = s.stage.appendingPathComponent("\(s.target)/\(s.id)"), dst = dir.appendingPathComponent(s.id)
        guard renamex_np(src.path, dst.path, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveError("Couldn't put the backup in the backups folder.") }
        return SessionsRestore.Backup(profile: s.target, id: s.id, place: place)
    }

    /// When a process started (seconds): with its pid, who a work folder belongs to (a pid alone can be reused).
    static func startTime(of pid: pid_t) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return Int(info.kp_proc.p_un.__p_starttime.tv_sec)
    }

    /// A check's seam: makes every claim fail, as a full or unwritable disk would. Only a test build (compiled with
    /// -D CL_AUDIT_TESTING) has it as a variable; in the shipped app it is the constant false.
    #if CL_AUDIT_TESTING
    nonisolated(unsafe) static var claimFails = false
    #else
    static let claimFails = false
    #endif

    /// Writes "<pid> <start>" in a work folder: a later launch knows whether its owner still runs. True only when the whole line
    /// was written and synced; a folder that couldn't be claimed isn't used (the caller removes it and stops).
    static func claim(_ work: URL) -> Bool {
        if claimFails { return false }
        let me = getpid()
        let text = "\(me) \(startTime(of: me) ?? 0)\n"
        let fd = Darwin.open(work.appendingPathComponent(ownerFile).path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        let n = strlen(text)
        let w = text.withCString { Darwin.write(fd, $0, n) }
        let synced = w == n && fsync(fd) == 0
        let closed = close(fd) == 0
        if !(synced && closed) { unlink(work.appendingPathComponent(ownerFile).path); return false }
        return true
    }

    /// Whether the process that made this work folder still runs: nil when it has no owner file (the 1-day rule then).
    static func ownerRuns(_ work: URL) -> Bool? {
        guard let t = try? String(contentsOf: work.appendingPathComponent(ownerFile), encoding: .utf8) else { return nil }
        let p = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[0] <= Int(Int32.max) else { return nil }
        let pid = pid_t(p[0])
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        // a start time of 0 (it could not be read when the folder was claimed) or one that can't be read now is unknown:
        // the folder is kept, not guessed at
        guard p[1] != 0, let now = startTime(of: pid) else { return true }
        return now == p[1]
    }

    /// Takes away a hidden work folder, never into a mounted image: an image still attached is detached (forced if it must),
    /// and if it is still there afterwards, nothing is removed and false says so. Every folder entered is on the work
    /// folder's own volume.
    @discardableResult
    static func discard(_ work: URL) -> Bool {
        var st = stat(), parent = stat()
        guard lstat(work.path, &st) == 0 else { unregister(work); return true }  // gone already
        guard (st.st_mode & S_IFMT) == S_IFDIR, lstat(work.deletingLastPathComponent().path, &parent) == 0, st.st_dev == parent.st_dev else { return false }
        let mnt = work.appendingPathComponent("mnt")
        var ms = stat()
        if lstat(mnt.path, &ms) == 0, ms.st_dev != st.st_dev {
            detach(mnt)
            guard lstat(mnt.path, &ms) == 0, ms.st_dev == st.st_dev else { return false }       // still a mount point: keep the folder
        }
        let removed = removeTree(work.path, dev: st.st_dev)
        if removed { unregister(work) }
        return removed
    }

    /// Removes a folder tree without ever entering another volume (a mount point is left, and false returned). Goes by descriptors
    /// (openat O_NOFOLLOW|O_DIRECTORY, unlinkat), never by a path string, so a tree deeper than PATH_MAX (a path API cannot name its
    /// leaves) is removed too; each folder entered is checked to be on `dev` (on the descriptor just opened). It holds ONE descriptor
    /// at a time, whatever the depth: going down it closes the parent, going back up it reopens the parent as ".." of the child and
    /// checks it is the same folder (device and inode), so neither a depth limit nor a descriptor limit can strand a tree. A folder
    /// the archive made unreadable is made readable only when opening it failed with EACCES. At the top, `.owner` is removed last
    /// (a folder that is half gone still says whose it is). A name already gone (another remover) counts as removed.
    static func removeTree(_ path: String, dev: dev_t) -> Bool {
        var fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_dev == dev else { close(fd); return false }
        fchmod(fd, 0o700)
        func names(_ d: Int32, top: Bool) -> [[CChar]]? {
            let again = dup(d)
            guard again >= 0, let dir = fdopendir(again) else { if again >= 0 { close(again) }; return nil }
            defer { closedir(dir) }
            var out: [[CChar]] = []                            // (raw bytes, never turned into text and back)
            while let e = readdir(dir) {
                let raw: [CChar] = withUnsafePointer(to: &e.pointee.d_name) { p in
                    p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { c in Array(UnsafeBufferPointer(start: c, count: strlen(c) + 1)) }
                }
                if raw == [46, 0] || raw == [46, 46, 0] { continue }
                out.append(raw)
            }
            // (removed from the end: at the top `.owner` goes to the front, so it is the last to go)
            if top, let i = out.firstIndex(of: Array(".owner".utf8CString)) { out.swapAt(0, i) }
            return out
        }
        guard let first = names(fd, top: true) else { close(fd); return false }
        var levels: [(pending: [[CChar]], ino: ino_t)] = [(first, st.st_ino)]
        var trail: [[CChar]] = []                              // the names descended through
        var ok = true
        while !levels.isEmpty {
            if let nm = levels[levels.count - 1].pending.popLast() {
                var ns = stat()
                guard nm.withUnsafeBufferPointer({ fstatat(fd, $0.baseAddress!, &ns, AT_SYMLINK_NOFOLLOW) }) == 0 else { continue }     // gone already
                if (ns.st_mode & S_IFMT) != S_IFDIR {
                    if levels.count == 1, !ok, nm == Array(ownerFile.utf8CString) { continue }      // something stayed: the folder keeps saying whose it is
                    if nm.withUnsafeBufferPointer({ unlinkat(fd, $0.baseAddress!, 0) }) != 0, errno != ENOENT { ok = false }
                    continue
                }
                guard ns.st_dev == dev else { ok = false; continue }
                func openChild() -> Int32 { nm.withUnsafeBufferPointer { openat(fd, $0.baseAddress!, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) } }
                var c = openChild()
                if c < 0, errno == EACCES {                    // (a folder the archive made unreadable is made readable first)
                    _ = nm.withUnsafeBufferPointer { fchmodat(fd, $0.baseAddress!, 0o700, AT_SYMLINK_NOFOLLOW) }
                    c = openChild()
                }
                if c < 0 { if errno != ENOENT { ok = false }; continue }
                var cs = stat()
                guard fstat(c, &cs) == 0, cs.st_dev == dev, let sub = names(c, top: false) else { close(c); ok = false; continue }
                fchmod(c, 0o700)
                close(fd); fd = c                              // down: the parent's descriptor is let go
                levels.append((sub, cs.st_ino)); trail.append(nm)
            } else {
                levels.removeLast()
                guard let nm = trail.popLast() else { break }   // the top is done
                // up: the parent is the child's ".."; it must be the very folder we came from
                let up = openat(fd, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                close(fd)
                var us = stat()
                guard up >= 0, fstat(up, &us) == 0, us.st_dev == dev, us.st_ino == levels[levels.count - 1].ino else { if up >= 0 { close(up) }; return false }
                fd = up
                if nm.withUnsafeBufferPointer({ unlinkat(fd, $0.baseAddress!, AT_REMOVEDIR) }) != 0, errno != ENOENT { ok = false }
            }
        }
        close(fd)
        return ok && (rmdir(path) == 0 || errno == ENOENT)
    }

    /// Hidden work folders (.import-…, .export-…) a run left: one whose owner (pid and start time in its owner file) no
    /// longer runs goes at once; one with no owner file goes at once if it holds anything (a half-removed one), else after a day. A live
    /// owner's is never touched.
    static func sweep(place: URL, now: Date = Date()) {
        let fm = FileManager.default
        for n in ((try? fm.contentsOfDirectory(atPath: place.path)) ?? []) where n.range(of: #"^\.(import|export)-[0-9a-f]{8}$"#, options: .regularExpression) != nil {
            let url = place.appendingPathComponent(n)
            var st = stat()
            guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            // a folder this process is using is never taken, whatever its `.owner` says (or lacks): the card's load sweeps in the same process
            if inUse(st) { continue }
            if let runs = ownerRuns(url) { if !runs { discard(url) }; continue }
            // No owner file. A running cl_audit's work folder always has its `.owner` (made the moment the folder is), so a folder
            // that holds anything but a lone `.owner` and has none is what a quit or a crash half removed (readdir can unlink the
            // `.owner` before `x/`): orphaned at once, not after a day counted from an mtime the unlink just bumped. An empty one
            // (or a lone unreadable `.owner`) may be one being made right now: the day rule.
            let inside = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ownerFile }
            if !inside.isEmpty { discard(url); continue }
            if now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))) > 86400 { discard(url) }
        }
    }

    // MARK: what the preview adds to the plan

    /// How many of the transcripts that would be added belong to a folder that isn't on this Mac (Claude Code lists a
    /// session only where its folder is): the sessions count, by the folder the transcript says it ran in.
    static func foldersMissing(_ p: SessionsRestore.Plan, backup: SessionsRestore.Backup) -> Int {
        var byProject: [String: (sample: String, sessions: Int)] = [:]
        for t in p.transcripts where t.rel.count == 3 {
            let project = t.rel[1]
            byProject[project] = (byProject[project]?.sample ?? backup.dir.appendingPathComponent(t.rel.joined(separator: "/")).path, (byProject[project]?.sessions ?? 0) + 1)
        }
        var missing = 0
        for (project, v) in byProject {
            let path: String
            if let cwd = SessionsExport.cwd(inTranscript: v.sample) { path = cwd }
            else { path = project.hasPrefix("-") ? "/" + project.dropFirst().replacingOccurrences(of: "-", with: "/") : project }
            var isDir: ObjCBool = false
            if !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue) { missing += v.sessions }
        }
        return missing
    }
}
