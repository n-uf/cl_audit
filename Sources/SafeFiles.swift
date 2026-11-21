// SafeFiles: the few ways a flow writes its own files safely, in one place: create-only writes, a journal, the receipts' store
// and the one lock the flows take. Foundation and Darwin only, and generic: no app type, path, folder name or wording of an app
// is in here. Callers pass every folder, file name and temp name (and the clock, where one is used).
//
// Nothing here makes a folder that it isn't asked for: ReceiptStore makes a receipt's own folder (and the one folder named
// with it) under the root it is given, Journal none (its store makes its folder), FlowLock the folders of the two lock files.

import Foundation

enum SafeFiles {
    /// A plain file read whole under a cap, never through a link and never blocking: nil when it isn't there, is a link, isn't a
    /// regular file, is larger than `max` or can't be read whole. `followsLink`: a link named by `path` itself is followed (the
    /// file it reaches must still be a regular one), for a file another program keeps that may be a link to the real one.
    static func readPlain(_ path: String, max: Int, followsLink: Bool = false) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | (followsLink ? 0 : O_NOFOLLOW))
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size >= 0, st.st_size <= off_t(max) else { return nil }
        var d = Data(count: Int(st.st_size))
        let n = d.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(st.st_size), 0) }
        return n == Int(st.st_size) ? d : nil
    }
}

// MARK: create-only writes

/// New files that never land over a name that is there and never go through a link: made with O_CREAT | O_EXCL | O_NOFOLLOW,
/// owner only unless a mode is given, and (for a whole file) written under a private temp name first, then hard-linked into place.
enum CreateOnly {
    /// A call that failed, with its errno.
    struct Failure: Error, Equatable, CustomStringConvertible {
        let code: Int32
        var description: String { String(cString: strerror(code)) }
    }

    /// What placing a file under its name did.
    enum Placed: Equatable {
        case created
        case exists                         // the name was taken (EEXIST): nothing was put there
        case failed(Failure)
    }

    /// A new file opened for writing (and reading, when `readable`): -1 with errno set when the name is there, is a link, or the
    /// file can't be made. `dir`: a folder's descriptor, or AT_FDCWD with a path.
    static func open(_ name: String, in dir: Int32 = AT_FDCWD, mode: mode_t = 0o600, readable: Bool = false) -> Int32 {
        openat(dir, name, (readable ? O_RDWR : O_WRONLY) | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
    }

    /// All of `data` in one write; true when it went whole (no data: nothing to write).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.isEmpty || data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) == data.count }
    }

    /// `from` renamed to `to` only while nothing is at `to` (RENAME_EXCL): a file or folder put in place, never over another.
    static func rename(_ from: String, to: String) -> Bool {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
    }

    /// A private temp file (made by `open`, so never over anything), written through `fd`, then placed under its real name with a
    /// hard link (`place`), so the real name is never written over either. `discard()` closes it and takes the temp name away: call
    /// it in every case (a placed file keeps its real name).
    final class Temp {
        let fd: Int32
        let dir: Int32
        let name: String
        private var isOpen = true

        /// `name`: the temp name, in `dir` (a folder's descriptor, or AT_FDCWD with a path).
        init(_ name: String, in dir: Int32 = AT_FDCWD, mode: mode_t = 0o600) throws {
            let fd = CreateOnly.open(name, in: dir, mode: mode)
            guard fd >= 0 else { throw Failure(code: errno) }
            self.fd = fd
            self.dir = dir
            self.name = name
        }

        func close() {
            if isOpen { Darwin.close(fd); isOpen = false }
        }

        /// Closed, then linked into place as `final` (in the same folder).
        func place(as final: String) -> Placed {
            close()
            if linkat(dir, name, dir, final, 0) == 0 { return .created }
            return errno == EEXIST ? .exists : .failed(Failure(code: errno))
        }

        func discard() {
            close()
            unlinkat(dir, name, 0)
        }
    }

    /// What `write` did.
    enum Wrote: Equatable {
        case created
        case exists                         // the name was taken: nothing was put there
        case notMade(Failure)               // the temp file couldn't be made
        case notWhole                       // the data couldn't be written whole
        case failed(Failure)                // the link into place failed otherwise
    }

    /// `data` as a new file `final` in `dir`: written whole under `temp` (flushed when `sync`), then linked into place. The temp
    /// name goes in every case.
    static func write(_ data: Data, as final: String, in dir: Int32 = AT_FDCWD, temp: String, mode: mode_t = 0o600, sync: Bool) -> Wrote {
        let t: Temp
        do { t = try Temp(temp, in: dir, mode: mode) } catch { return .notMade(error as? Failure ?? Failure(code: EIO)) }
        defer { t.discard() }
        let ok = writeAll(t.fd, data)
        if ok && sync { fsync(t.fd) }
        guard ok else { return .notWhole }
        switch t.place(as: final) {
        case .created: return .created
        case .exists: return .exists
        case .failed(let f): return .failed(f)
        }
    }

    /// Takes away the temp files a writer left in a folder (`dir`, its descriptor; `names`, what it holds) whose names start with
    /// `prefix` and end with `suffix`: plain files only, through the descriptor.
    static func sweep(_ dir: Int32, names: [String], prefix: String, suffix: String = ".tmp") {
        for n in names where n.hasPrefix(prefix) && n.hasSuffix(suffix) {
            var st = stat()
            if fstatat(dir, n, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG { unlinkat(dir, n, 0) }
        }
    }
}

// MARK: the journal

/// A flow's journal: one JSON line appended per event, written down before the step it names (flushed to disk when `sync`), and
/// read back in order. A line cut short by a crash is skipped. Never through a link; owner only.
final class Journal<Event: Codable> {
    let fd: Int32

    init?(_ url: URL) {
        let f = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard f >= 0 else { return nil }
        fd = f
    }

    deinit { close(fd) }

    func add(_ e: Event, sync: Bool) {
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if sync { fsync(fd) }
    }

    /// The events, in order; nil when there is no journal.
    static func events(_ url: URL) -> [Event]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(Event.self, from: Data($0.utf8)) }
    }
}

// MARK: receipts

/// A receipt a store keeps: its id names its file (or folder), and lists go newest first by when it started.
protocol StoredReceipt: Codable {
    var id: String { get }
    var started: Date { get }
}

/// The order receipts were made in, finer than their dates: a receipt's `started` is saved to the whole second (ISO 8601, the
/// format older versions read), so two started in one second would tie. A store writes one more key into a receipt the first
/// time it saves it, `firstSavedNs`: the wall clock in nanoseconds since 1970, strictly increasing within this process (one
/// more than the last one given when the clock hasn't moved past it), so another process's receipts fall in by the clock.
/// Later saves carry it over from the file; older versions ignore it (JSONDecoder skips keys it doesn't know).
enum ReceiptOrder {
    static let key = "firstSavedNs"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: Int64 = 0

    /// The next value: now, or one more than the last one given.
    static func next() -> Int64 {
        let now = Int64(clamping: clock_gettime_nsec_np(CLOCK_REALTIME))
        lock.lock(); defer { lock.unlock() }
        last = max(now, last + 1)
        return last
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let firstSaved = Key(stringValue: ReceiptOrder.key)!
    }
}

/// The receipts of one kind, under `root`: each in a folder of its own (`<root>/<id>/<file>`, with the flow's other files beside
/// it) or flat (`<root>/<id>.json`). Saved whole as pretty-printed JSON with sorted keys and ISO 8601 dates, replaced atomically
/// (the format every receipt has always had: old receipts load, and these load in older versions), plus the key `firstSavedNs`
/// (ReceiptOrder) on a receipt this version first saved.
struct ReceiptStore<R: StoredReceipt> {
    enum Layout: Equatable {
        case folders(file: String)
        case flat
    }

    let root: URL
    var layout: Layout
    /// A folder made inside a receipt's own folder whenever it is saved (made with it), or nil.
    var inner: String? = nil
    /// false: "/" is written as it is (JSONEncoder's .withoutEscapingSlashes).
    var escapeSlashes = true
    /// The file's mode, set after each save (nil: as the atomic write leaves it).
    var fileMode: mode_t? = nil
    /// Read under this cap, never through a link (nil: read as it is).
    var readCap: Int? = nil
    /// Which ids may be read (a name in the root that isn't one is never a receipt).
    var validID: (String) -> Bool = { _ in true }
    /// A receipt read must carry the id it was read by.
    var idMustMatch = false
    /// The journal beside the receipt, in its folder (`.folders` only).
    var journalFile: String? = nil

    /// The receipt's own folder (`.flat`: the root).
    func folder(_ id: String) -> URL {
        switch layout {
        case .folders: return root.appendingPathComponent(id)
        case .flat: return root
        }
    }

    func url(_ id: String) -> URL {
        switch layout {
        case .folders(let file): return root.appendingPathComponent(id).appendingPathComponent(file)
        case .flat: return root.appendingPathComponent("\(id).json")
        }
    }

    /// A receipt with its place in the order receipts were made: `firstSaved` is its `firstSavedNs` (ReceiptOrder), nil on one
    /// an older version wrote (or saved again: it drops the key).
    struct Ordered {
        let receipt: R
        let firstSaved: Int64?
    }

    /// Newest first: by `started`, then (two in one second) by `firstSaved`, one without it before every one with it, then by id.
    static func newestFirst(_ a: Ordered, _ b: Ordered) -> Bool {
        if a.receipt.started != b.receipt.started { return a.receipt.started > b.receipt.started }
        let x = a.firstSaved ?? 0, y = b.firstSaved ?? 0
        if x != y { return x > y }
        return a.receipt.id > b.receipt.id
    }

    /// The receipt's own keys, then `firstSavedNs` beside them (none: the receipt's keys only).
    private struct Saved: Encodable {
        let receipt: R
        let firstSaved: Int64?
        func encode(to encoder: Encoder) throws {
            try receipt.encode(to: encoder)
            guard let firstSaved else { return }
            var c = encoder.container(keyedBy: ReceiptOrder.Key.self)
            try c.encode(firstSaved, forKey: .firstSaved)
        }
    }

    private struct Read: Decodable {
        let ordered: Ordered
        init(from decoder: Decoder) throws {
            let r = try R(from: decoder)
            // (a value that isn't a whole number counts as none: the receipt still reads)
            let first = try? decoder.container(keyedBy: ReceiptOrder.Key.self).decodeIfPresent(Int64.self, forKey: .firstSaved)
            ordered = Ordered(receipt: r, firstSaved: first ?? nil)
        }
    }

    /// A receipt as it is saved (`firstSaved`: with that `firstSavedNs`; nil: in the format older versions wrote, byte for byte).
    func encoded(_ r: R, firstSaved: Int64? = nil) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = escapeSlashes ? [.prettyPrinted, .sortedKeys] : [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(Saved(receipt: r, firstSaved: firstSaved))
    }

    /// Saves a receipt whole. The first save of an id (no file there yet) gives it its `firstSavedNs`; a later one carries over
    /// what the file has (none on one an older version wrote: it stays as that version left it).
    func save(_ r: R) throws {
        let dir = folder(r.id)
        try FileManager.default.createDirectory(at: inner.map { dir.appendingPathComponent($0) } ?? dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let u = url(r.id)
        var st = stat()
        let first = lstat(u.path, &st) == 0 ? read(u).flatMap(decoded)?.firstSaved : ReceiptOrder.next()
        try encoded(r, firstSaved: first).write(to: u, options: .atomic)
        if let fileMode { chmod(u.path, fileMode) }
    }

    private func read(_ u: URL) -> Data? {
        readCap.map { SafeFiles.readPlain(u.path, max: $0) } ?? (try? Data(contentsOf: u))
    }

    private func decoded(_ data: Data) -> Ordered? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode(Read.self, from: data))?.ordered
    }

    func load(_ id: String) -> R? { loadOrdered(id)?.receipt }

    /// A receipt with its place in the order receipts were made.
    func loadOrdered(_ id: String) -> Ordered? {
        guard validID(id), let o = read(url(id)).flatMap(decoded), !idMustMatch || o.receipt.id == id else { return nil }
        return o
    }

    /// The ids in the root that `include` takes (default: `validID`). `.flat`: the files' ids, in the order of their names.
    func ids(_ include: ((String) -> Bool)? = nil) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        switch layout {
        case .folders: return names.filter(include ?? validID)
        case .flat: return names.filter { $0.hasSuffix(".json") }.sorted().map { String($0.dropLast(".json".count)) }.filter(include ?? validID)
        }
    }

    /// The receipts `include` takes (default: every valid one), newest first (`newestFirst`: two started in one second in the
    /// order they were made).
    func list(_ include: ((String) -> Bool)? = nil) -> [R] {
        ids(include).compactMap(loadOrdered).sorted(by: Self.newestFirst).map(\.receipt)
    }

    /// The journal beside a receipt, opened to append (its folder made first).
    func journal<E: Codable>(_ id: String, of: E.Type) -> Journal<E>? {
        guard let journalFile else { return nil }
        try? FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return Journal<E>(folder(id).appendingPathComponent(journalFile))
    }

    /// The events of a receipt's journal, in order (none when there is no journal).
    func events<E: Codable>(_ id: String, of: E.Type) -> [E] {
        guard let journalFile else { return [] }
        return Journal<E>.events(folder(id).appendingPathComponent(journalFile)) ?? []
    }
}

// MARK: the one lock

/// One flow at a time: a lock file of the app's own (an fcntl lock through lockf) and, when given, another tool's lock file (a
/// flock, the way /usr/bin/lockf and perl's flock take it, made with its folder when missing so that tool finds it held), both
/// taken without waiting and held until `release`. File locks hold against other processes; the flag here holds within this one.
final class FlowLock {
    enum Busy: Error, Equatable {
        case held                           // another flow holds it (in this process or another)
        case unopenable                     // the lock file can't be opened
        case otherHeld                      // the other tool holds its lock
        case otherUnopenable                // the other tool's lock file can't be opened
    }

    let path: String
    let other: String?
    private let inProcess = NSLock()
    private var held = false

    init(path: String, other: String? = nil) {
        self.path = path
        self.other = other
    }

    struct Held {
        let fd: Int32
        let otherFD: Int32?
        let lock: FlowLock

        func release() {
            if let otherFD { flock(otherFD, LOCK_UN); close(otherFD) }
            lockf(fd, F_ULOCK, 0); close(fd)
            lock.inProcess.lock(); lock.held = false; lock.inProcess.unlock()
        }
    }

    /// Takes both locks, or throws `Busy` (or the error of making the lock file's folder).
    func take() throws -> Held {
        inProcess.lock()
        defer { inProcess.unlock() }
        guard !held else { throw Busy.held }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw Busy.unopenable }
        guard lockf(fd, F_TLOCK, 0) == 0 else { close(fd); throw Busy.held }
        var t: Int32?
        if let other {
            try? FileManager.default.createDirectory(atPath: (other as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let o = open(other, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard o >= 0 else { lockf(fd, F_ULOCK, 0); close(fd); throw Busy.otherUnopenable }
            guard flock(o, LOCK_EX | LOCK_NB) == 0 else {
                close(o); lockf(fd, F_ULOCK, 0); close(fd)
                throw Busy.otherHeld
            }
            t = o
        }
        held = true
        return Held(fd: fd, otherFD: t, lock: self)
    }
}
