// SessionsExport: a profile's sessions as one file, for another Mac or for keeping (Settings ▸ a profile ▸ Sessions ▸
// Export…; the page is ExportPage.swift). The file holds the backup format (SessionsBackup.swift) of each profile exported,
// made from a fresh backup or a chosen one, so Import (SessionsImport.swift) restores it by the same rules as Restore.
//
//   <folder named for the export>/
//     export.json                      what it is: format, version, when, the profiles in it, the size
//     profiles/p1/backup.json          a backup's manifest, ids replaced by fingerprints, no absolute path
//     profiles/p1/window/<fp>/<fp>/…   the Code-tab entries and scheduled tasks
//     profiles/p1/sidebar/…            the sidebar records (epitaxyPrefs only)
//     profiles/p1/records/profile.json the profile's name and fingerprints
//     profiles/p1/transcripts/…        Claude Code's transcripts
//
// What is never in it: a sign-in (nothing a backup excludes: .claude.json, credentials, Keychain, OAuth, auth.json), the
// MCP settings, settings.json, a switch's receipt, or an address or an id of any account cl_audit knows. Those appear as a
// fingerprint: "fp-" and 8 hex characters of an HMAC under a key made for the export alone. Every file of the profile's
// structure is checked at the end for the known ids and addresses (every profile's accounts, the window's account and
// organisation folders); a hit stops the export. Any other id and any other address is content (a stranger's address in a
// title) and passes, as it does in a transcript, which is the user's own words and is copied as it is. A zip also leaves
// out each Code-tab entry's remoteMcpServersConfig and sessionSettings (connection settings and environment values the key
// scan can't recognise); the encrypted disk image keeps them.
//
// Transcripts are scanned for keys (GitHub tokens, AWS access keys, private keys, Anthropic and OpenAI API keys, Slack,
// Google, Stripe and npm tokens): a session whose files hold one is left out, or, if the user says so, kept in an
// encrypted disk image. A transcript a running Claude Code session holds, or that doesn't end on a full line, is copied
// up to its last full line. The file is made with macOS's own ditto (a zip) or hdiutil (AES-256, the password passed on
// stdin, never in an argument, never stored or logged).

import CryptoKit
import Foundation

struct ArchiveError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

// MARK: - fingerprints

/// An id or an address as the export writes it: `fp-` and 8 hex characters of an HMAC-SHA256 under a key that is random for
/// each export and never written anywhere. So the same account is the same fingerprint everywhere in one file, and nobody can
/// confirm a guessed address or id by hashing it (an unkeyed SHA-256 of an address would be that guess's check).
struct Fingerprint {
    private let key = SymmetricKey(size: .bits256)

    func of(_ id: String) -> String {
        "fp-" + HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ s: String) -> Bool {
        s.utf8.count == 11 && s.hasPrefix("fp-") && s.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }
}

/// Tells this Mac from another in an export: a random id made the first time and kept with cl_audit's preferences, not
/// derived from the Mac's name or anything else of it.
enum InstallID {
    static let key = "installID"
    static var current: String {
        if let s = BackupPrefs.store.string(forKey: key), s.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil { return s }
        let s = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        BackupPrefs.store.set(s, forKey: key)
        return s
    }
}

// MARK: - running macOS's own tools

enum Tool {
    struct Output {
        var status: Int32
        var out: String
        var err: String
        var cancelled: Bool
    }

    /// The tools running now (ditto, hdiutil): cl_audit quitting stops them (SIGTERM) so none goes on writing without it.
    private static let runningLock = NSLock()
    nonisolated(unsafe) private static var running = Set<pid_t>()

    static func killAll() {
        runningLock.lock(); let pids = running; runningLock.unlock()
        for p in pids { kill(p, SIGTERM) }
    }

    /// Runs a tool with a plain environment. `stdin` is written and closed (a password goes this way, never as an
    /// argument). `poll` is asked every 0.2 s and returns true to stop the tool; so does `cancel`. What the tool printed
    /// is capped, and `secret` is taken out of it before it is returned. nil: it couldn't start.
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil, secret: String? = nil,
                    cancel: () -> Bool = { false }, poll: () -> Bool = { false }) -> Output? {
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        if let t = ProcessInfo.processInfo.environment["TMPDIR"] { env["TMPDIR"] = t }
        if let h = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] { env["CFFIXED_USER_HOME"] = h }
        env["HOME"] = NSHomeDirectory()
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        if stdin == nil { p.standardInput = FileHandle.nullDevice } else { p.standardInput = inPipe }
        final class Box: @unchecked Sendable { var data = Data(); let lock = NSLock() }
        let outBox = Box(), errBox = Box(), group = DispatchGroup()
        do { try p.run() } catch { return nil }
        runningLock.lock(); running.insert(p.processIdentifier); runningLock.unlock()
        defer { runningLock.lock(); running.remove(p.processIdentifier); runningLock.unlock() }
        for (pipe, box) in [(outPipe, outBox), (errPipe, errBox)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    box.lock.lock(); if box.data.count < 1 << 20 { box.data.append(d) }; box.lock.unlock()
                }
                group.leave()
            }
        }
        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }
        var cancelled = false
        while p.isRunning {
            if cancel() || poll() { cancelled = true; p.terminate(); break }
            usleep(200_000)
        }
        p.waitUntilExit()
        group.wait()
        func text(_ b: Box) -> String {
            var s = String(decoding: b.data, as: UTF8.self)
            if let secret, !secret.isEmpty { s = s.replacingOccurrences(of: secret, with: "…") }
            return s
        }
        return Output(status: p.terminationStatus, out: text(outBox), err: text(errBox), cancelled: cancelled)
    }
}

// MARK: - keys in transcripts

enum Secret: String, CaseIterable, Codable {
    case github, aws, privateKey, anthropic, openai, slack, google, stripe, npm, supabase, gitlab, huggingface, jwt

    /// "GitHub tokens", "private keys": what a count of them is called.
    var words: String {
        switch self {
        case .github: return "GitHub tokens"
        case .aws: return "AWS access keys"
        case .privateKey: return "private keys"
        case .anthropic: return "Anthropic API keys"
        case .openai: return "OpenAI API keys"
        case .slack: return "Slack tokens"
        case .google: return "Google API keys"
        case .stripe: return "Stripe keys"
        case .npm: return "npm tokens"
        case .supabase: return "Supabase tokens"
        case .gitlab: return "GitLab tokens"
        case .huggingface: return "Hugging Face tokens"
        case .jwt: return "JWT tokens"
        }
    }
}

enum SecretScan {
    private struct Pattern {
        let kind: Secret
        let prefix: [UInt8]
        /// Given the bytes and the index right after the prefix: whether what follows is the rest of a key.
        let accept: (UnsafeBufferPointer<UInt8>, Int) -> Bool
    }

    private static func alnum(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private static func upperDigit(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) }

    /// Whether at least `n` bytes from `i` on satisfy `ok` (the run may go on after them).
    private static func run(_ b: UnsafeBufferPointer<UInt8>, _ i: Int, _ n: Int, _ ok: (UInt8) -> Bool) -> Bool {
        guard i + n <= b.count else { return false }
        for k in i..<(i + n) where !ok(b[k]) { return false }
        return true
    }

    private static let patterns: [Pattern] = {
        var out: [Pattern] = []
        for p in ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"] {
            out.append(Pattern(kind: .github, prefix: Array(p.utf8)) { b, i in run(b, i, 36, alnum) })
        }
        out.append(Pattern(kind: .github, prefix: Array("github_pat_".utf8)) { b, i in run(b, i, 22) { alnum($0) || $0 == 0x5F } })
        for p in ["AKIA", "ASIA"] {
            out.append(Pattern(kind: .aws, prefix: Array(p.utf8)) { b, i in
                run(b, i, 16, upperDigit) && (i + 16 >= b.count || !alnum(b[i + 16]))
            })
        }
        out.append(Pattern(kind: .privateKey, prefix: Array("-----BEGIN ".utf8)) { b, i in
            // "-----BEGIN RSA PRIVATE KEY-----", "-----BEGIN OPENSSH PRIVATE KEY-----", "-----BEGIN PGP PRIVATE KEY BLOCK-----"
            let end = min(b.count, i + 48)
            guard end > i else { return false }
            let tail = Array(b[i..<end])
            for needle in ["PRIVATE KEY-----", "PRIVATE KEY BLOCK-----"] {
                if memmem(tail, tail.count, Array(needle.utf8), needle.utf8.count) != nil { return true }
            }
            return false
        })
        out.append(Pattern(kind: .anthropic, prefix: Array("sk-ant-".utf8)) { b, i in run(b, i, 20) { alnum($0) || $0 == 0x5F || $0 == 0x2D } })
        out.append(Pattern(kind: .openai, prefix: Array("sk-".utf8)) { b, i in
            // not an Anthropic key, and long enough with a digit in it: "task-fix-the-login-page-for-users" is not a key
            if i + 4 <= b.count, b[i] == 0x61, b[i + 1] == 0x6E, b[i + 2] == 0x74, b[i + 3] == 0x2D { return false }
            guard run(b, i, 40, { alnum($0) || $0 == 0x5F || $0 == 0x2D }) else { return false }
            return (i..<(i + 40)).contains { b[$0] >= 0x30 && b[$0] <= 0x39 }
        })
        for p in ["xoxb-", "xoxa-", "xoxp-", "xoxr-", "xoxs-"] {
            out.append(Pattern(kind: .slack, prefix: Array(p.utf8)) { b, i in run(b, i, 10) { alnum($0) || $0 == 0x2D } })
        }
        out.append(Pattern(kind: .google, prefix: Array("AIza".utf8)) { b, i in run(b, i, 35) { alnum($0) || $0 == 0x5F || $0 == 0x2D } })
        for p in ["sk_live_", "rk_live_"] {
            out.append(Pattern(kind: .stripe, prefix: Array(p.utf8)) { b, i in run(b, i, 16, alnum) })
        }
        out.append(Pattern(kind: .npm, prefix: Array("npm_".utf8)) { b, i in run(b, i, 36, alnum) })
        out.append(Pattern(kind: .supabase, prefix: Array("sbp_".utf8)) { b, i in run(b, i, 30, alnum) })
        out.append(Pattern(kind: .gitlab, prefix: Array("glpat-".utf8)) { b, i in run(b, i, 20) { alnum($0) || $0 == 0x5F || $0 == 0x2D } })
        out.append(Pattern(kind: .huggingface, prefix: Array("hf_".utf8)) { b, i in run(b, i, 30, alnum) })
        // Slack's refresh tokens: "xoxe-…" and "xoxe.xoxp-…"
        out.append(Pattern(kind: .slack, prefix: Array("xoxe-".utf8)) { b, i in run(b, i, 10) { alnum($0) || $0 == 0x2D } })
        out.append(Pattern(kind: .slack, prefix: Array("xoxe.xox".utf8)) { b, i in run(b, i, 10) { alnum($0) || $0 == 0x2D || $0 == 0x2E } })
        // a JWT: three base64url parts, the first two starting "eyJ" ({" in base64), the signature at least 20 long
        out.append(Pattern(kind: .jwt, prefix: Array("eyJ".utf8)) { b, i in
            func b64(_ c: UInt8) -> Bool { alnum(c) || c == 0x5F || c == 0x2D }
            func runLen(_ from: Int) -> Int { var k = from; while k < b.count, b64(b[k]) { k += 1 }; return k - from }
            let h = runLen(i)
            guard h >= 10, i + h < b.count, b[i + h] == 0x2E, i + h + 4 <= b.count else { return false }
            let p = i + h + 1
            guard b[p] == 0x65, b[p + 1] == 0x79, b[p + 2] == 0x4A else { return false }            // "eyJ"
            let l = runLen(p + 3)
            guard l >= 10, p + 3 + l < b.count, b[p + 3 + l] == 0x2E else { return false }
            return runLen(p + 3 + l + 1) >= 20
        })
        return out
    }()

    /// Where a word starts: after a space, a quote, a colon, a bracket… but not after a letter, a digit, "_" or "-". In JSONL a
    /// newline is the two bytes `\n` (and a tab `\t`): the letter after the backslash is an escape, not part of a word, so a key
    /// right after it starts one.
    private static func wordStart(_ b: UnsafeBufferPointer<UInt8>, _ at: Int) -> Bool {
        let before: UInt8 = at > 0 ? b[at - 1] : 0x20
        if !(alnum(before) || before == 0x5F || before == 0x2D) { return true }
        if at >= 2, b[at - 2] == 0x5C, [0x6E, 0x74, 0x72, 0x62, 0x66].contains(before) { return true }       // \n \t \r \b \f
        return false
    }

    /// The longest a key's decisive part is: what one chunk carries over into the next, so a key cut by a chunk's end is
    /// still seen whole.
    private static let carry = 4096        // (a JWT can be a few thousand characters: its decisive part must lie within one buffer)
    private static let chunk = 4 << 20

    /// The kinds of key in these bytes.
    /// The patterns by their first byte: one memchr pass per distinct first byte (about nine), not one memmem pass per
    /// pattern (about thirty), and at each hit only the patterns that start with that byte are tried.
    private static let buckets: [(first: UInt8, pats: [Pattern])] = {
        var out: [(first: UInt8, pats: [Pattern])] = []
        for p in patterns {
            if let i = out.firstIndex(where: { $0.first == p.prefix[0] }) { out[i].pats.append(p) } else { out.append((p.prefix[0], [p])) }
        }
        return out
    }()

    static func scan(_ b: UnsafeBufferPointer<UInt8>, into found: inout Set<Secret>) {
        guard let base = b.baseAddress, b.count > 0 else { return }
        for bucket in buckets where bucket.pats.contains(where: { !found.contains($0.kind) }) {
            var from = 0
            while from < b.count {
                guard let hit = memchr(base + from, Int32(bucket.first), b.count - from) else { break }
                let at = UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                // a key starts where a word does: "task-…" or "mask_…" holding the same letters is not one
                if wordStart(b, at) {
                    for pat in bucket.pats where !found.contains(pat.kind) && at + pat.prefix.count <= b.count && memcmp(base + at, pat.prefix, pat.prefix.count) == 0
                        && pat.accept(b, at + pat.prefix.count) { found.insert(pat.kind) }
                }
                from = at + 1
            }
        }
    }

    static func scan(_ data: Data) -> Set<Secret> {
        var found = Set<Secret>()
        data.withUnsafeBytes { raw in scan(raw.bindMemory(to: UInt8.self), into: &found) }
        return found
    }

    /// The kinds of key in a file, read in chunks without following a link. nil: it couldn't be read, or `cancel` said stop.
    static func scan(path: String, cancel: () -> Bool = { false }, progress: ((Int64) -> Void)? = nil) -> Set<Secret>? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int64(st.st_size)
        var buf = [UInt8](repeating: 0, count: carry + chunk)
        var found = Set<Secret>()
        var have = 0
        var off: Int64 = 0
        while off < size {
            if cancel() { return nil }
            let want = Int(min(Int64(chunk), size - off))
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + have, want, off_t(off)) }
            if n < 0 { return nil }
            if n == 0 { break }
            let total = have + n
            buf.withUnsafeBufferPointer { scan(UnsafeBufferPointer(rebasing: $0[0..<total]), into: &found) }
            off += Int64(n)
            progress?(Int64(n))
            let keep = min(carry, total)
            if keep > 0 { buf.withUnsafeMutableBytes { _ = memmove($0.baseAddress!, $0.baseAddress! + total - keep, keep) } }
            have = keep
        }
        return found
    }
}

// MARK: - the format

struct ExportManifest: Codable, Equatable {
    static let format = "cl_audit-export"
    struct Part: Codable, Equatable {
        var dir: String                     // "p1": the folder under profiles/
        var name: String                    // the profile's name
        var profile: String                 // its id
        var sessions: Int                   // transcripts
        var entries: Int                    // the window's Code-tab entries
        var tasks: Int
        var bytes: Int64
    }
    var format: String = ExportManifest.format
    var version = 1
    var created: Date
    var app: String                         // cl_audit's version
    var machine: String                     // InstallID: a random id of this cl_audit install (another Mac or this one, nothing else)
    var container: String                   // "zip" or "image"
    var keys: String                        // "left out" or "kept"
    var keysLeftOut: Int
    var keysKept: Int
    var parts: [Part]
    var bytes: Int64
}

// MARK: - preferences (the last export, the last folder)

enum ExportPrefs {
    static func last(profile: String) -> (date: Date, bytes: Int64)? {
        guard let s = BackupPrefs.store.string(forKey: "exportLast.\(profile)") else { return nil }
        let p = s.split(separator: "|")
        guard p.count == 2, let t = Double(p[0]), let b = Int64(p[1]) else { return nil }
        return (Date(timeIntervalSince1970: t), b)
    }

    static func remember(profile: String, date: Date, bytes: Int64) {
        BackupPrefs.store.set("\(Int(date.timeIntervalSince1970))|\(bytes)", forKey: "exportLast.\(profile)")
    }

    static var folder: String? {
        get { BackupPrefs.store.string(forKey: "exportFolder") }
        set { BackupPrefs.store.set(newValue, forKey: "exportFolder") }
    }

    /// "Never exported. A file for another Mac or for keeping." / "Last exported 5 Nov · 5.5 GB"
    static func words(profile: String, now: Date = Date()) -> String {
        guard let l = last(profile: profile) else { return "Never exported. A file for another Mac or for keeping." }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.component(.year, from: l.date) == Calendar.current.component(.year, from: now) ? "d MMM" : "d MMM yyyy"
        return "Last exported " + SessionsBackup.tight(f.string(from: l.date)) + " · " + SessionsBackup.sizeWords(l.bytes)
    }
}

// MARK: - the identities an export must not carry

/// Every account id, organisation id and address cl_audit knows on this Mac (all profiles', not only the ones exported):
/// the only things the leak check refuses. Anything else in an entry (other ids, a stranger's address) is content, as it is
/// in a transcript. All lowercase.
struct Identities: Equatable {
    var ids = Set<String>()
    var emails = Set<String>()

    mutating func add(id: String?) {
        guard let s = id?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), s.count >= 4 else { return }
        ids.insert(s)
    }
    mutating func add(email: String?) {
        guard let s = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), s.contains("@") else { return }
        emails.insert(s)
    }
    mutating func add(seat: Seat?) {
        guard let seat else { return }
        add(id: seat.account); add(id: seat.organization); add(email: seat.email); add(email: seat.was)
    }
    mutating func formUnion(_ o: Identities) { ids.formUnion(o.ids); emails.formUnion(o.emails) }

    /// The account and organisation folders a Claude window's Code tab has filed entries under: their names are ids.
    mutating func add(windowDir dataDir: String) {
        guard !dataDir.isEmpty else { return }
        let fm = FileManager.default
        let root = (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions")
        for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where AccountDiscovery.isUUID(a) {
            add(id: a)
            for o in (try? fm.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(a))) ?? [] where AccountDiscovery.isUUID(o) { add(id: o) }
        }
    }

    /// The account, organisation and address in one .claude.json (or a `.claude.json.backup*` of it): ids and an address only,
    /// never a token, and every record (not one per account, not only those with an address).
    mutating func add(claudeJSON path: String) {
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let o = j["oauthAccount"] as? [String: Any] else { return }
        add(id: o["accountUuid"] as? String); add(id: o["organizationUuid"] as? String); add(email: o["emailAddress"] as? String)
    }

    /// A Claude Code folder's .claude.json and the backups kept beside it (and, for the usual folder, in ~/.claude/backups).
    mutating func add(configDir dir: String) {
        guard !dir.isEmpty else { return }
        let json = Account.claudeJSON(configDir: dir)
        add(claudeJSON: json)
        let fm = FileManager.default
        for folder in [(json as NSString).deletingLastPathComponent, (NSHomeDirectory() as NSString).appendingPathComponent(".claude/backups")] {
            for n in ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted() where n.hasPrefix(".claude.json.backup") {
                add(claudeJSON: (folder as NSString).appendingPathComponent(n))
            }
        }
    }

    /// One profile: its seats (in use and standby), what Claude Code recorded in each of its folders' .claude.json and their
    /// backups, and its window's folder names.
    mutating func add(source s: SessionsBackup.Source) {
        if let e = s.entry {
            add(seat: e.seat)
            for q in e.standby { add(seat: q.seat); add(email: q.email) }
            for dir in [e.configDir, e.keptFolder].compactMap({ $0 }) + e.standby.compactMap(\.configDir) { add(configDir: dir) }
        }
        add(configDir: s.codeDir)
        add(windowDir: s.dataDir)
    }

    /// Every profile in cl_audit's list, and every Claude Code folder on this Mac with its backups.
    static func of(accounts: [AccountEntry]) -> Identities {
        var k = Identities()
        for e in accounts { k.add(source: SessionsBackup.Source(e)) }
        for c in Detect.configFolders() { k.add(configDir: c.path) }
        k.add(configDir: "~/.claude")
        return k
    }
}

/// An export's own scrubbing of the identities (case-insensitive, whole file, outside transcripts): each becomes its keyed
/// fingerprint. JSON is rewritten string by string on the decoded text, in keys and values (so an address written with
/// `@` or `\/` is found too) and nothing else in the file is touched; a file that isn't JSON is done as plain text.
struct Scrubber {
    private let ids: [String]
    private let emails: [String]
    private let fp: Fingerprint
    private let shortest: Int

    init(_ known: Identities, fp: Fingerprint) {
        ids = known.ids.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
        emails = known.emails.sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }      // longest first: "jbob@x" before "bob@x"
        self.fp = fp
        shortest = (ids + emails).map(\.utf8.count).min() ?? Int.max
    }

    /// A name that goes in a file or folder name or a manifest: also an address as `plainFileName` writes it ("bob-example.com").
    func name(_ s: String) -> String {
        var t = text(s)
        for e in emails {
            let plain = SessionsExport.plainFileName(e)
            if t.range(of: plain, options: Self.how) != nil { t = t.replacingOccurrences(of: plain, with: fp.of(e), options: Self.how) }
        }
        return t
    }

    /// Case-insensitive and LITERAL: compared by scalars, so a name followed by a combining mark or a joiner (bob@x.com + U+0301)
    /// is still found (a whole-character comparison would take the mark as part of the last character and miss it).
    static let how: String.CompareOptions = [.caseInsensitive, .literal]

    func text(_ s: String) -> String {
        guard s.utf8.count >= shortest else { return s }
        var t = s
        for id in ids where t.range(of: id, options: Self.how) != nil { t = t.replacingOccurrences(of: id, with: fp.of(id), options: Self.how) }
        for e in emails where t.range(of: e, options: Self.how) != nil { t = t.replacingOccurrences(of: e, with: fp.of(e), options: Self.how) }
        return t
    }

    func data(_ d: Data) -> Data {
        json(d) ?? Data(text(String(decoding: d, as: UTF8.self)).utf8)
    }

    /// nil: not JSON this can walk.
    private func json(_ d: Data) -> Data? {
        guard (try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) != nil else { return nil }
        let b = [UInt8](d)
        var out = [UInt8]()
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            guard b[i] == 0x22 else { out.append(b[i]); i += 1; continue }
            var j = i + 1, esc = false
            while j < b.count, b[j] != 0x22 { if b[j] == 0x5C { esc = true; j += 1 }; j += 1 }
            guard j < b.count else { return nil }
            let body = b[(i + 1)..<j]
            if !esc {
                let s = String(decoding: body, as: UTF8.self), t = text(s)
                out.append(0x22); out.append(contentsOf: t == s ? Array(body) : Array(t.utf8)); out.append(0x22)
            } else {
                var wrapped: [UInt8] = [0x5B]
                wrapped += b[i...j]
                wrapped.append(0x5D)
                guard let s = ((try? JSONSerialization.jsonObject(with: Data(wrapped))) as? [String])?.first else { return nil }
                let t = text(s)
                if t == s { out.append(contentsOf: b[i...j]) }
                else {
                    guard let e = try? JSONSerialization.data(withJSONObject: [t], options: [.withoutEscapingSlashes]) else { return nil }
                    out.append(contentsOf: e.dropFirst().dropLast())
                }
            }
            i = j + 1
        }
        return Data(out)
    }
}

/// The two fields of a Code-tab entry a zip leaves out: they can hold connection settings and environment values that
/// the key scan has no way to recognise. The encrypted disk image keeps them.
enum EntryConnections {
    static let fields: Set<String> = ["remoteMcpServersConfig", "sessionSettings"]

    /// `data`: the entry without the two fields, every other byte as it was. `held`: how many of the two held something
    /// (not null, {}, [], "" or false). nil: it can't be done safely (not a UTF-8 JSON object, or the result isn't JSON): a zip
    /// leaves such an entry out.
    static func without(_ d: Data) -> (data: Data, held: Int)? {
        let b = [UInt8](d)
        guard let members = top(b) else { return nil }
        if members.isEmpty { return (d, 0) }
        let drop = members.filter { fields.contains($0.key) }
        if drop.isEmpty { return (d, 0) }
        let held = drop.filter { m in
            let v = String(decoding: b[m.value..<m.end], as: UTF8.self).filter { !$0.isWhitespace }
            return !["null", "{}", "[]", "\"\"", "false"].contains(v)
        }.count
        let kept = members.filter { !fields.contains($0.key) }
        var out = Array(b[0..<members[0].start])
        let sep: [UInt8] = members.count >= 2 ? Array(b[members[0].end..<members[1].start]) : [0x2C]
        for (n, m) in kept.enumerated() { if n > 0 { out += sep }; out += b[m.start..<m.end] }
        out += b[members[members.count - 1].end...]
        let r = Data(out)
        guard (try? JSONSerialization.jsonObject(with: r)) is [String: Any] else { return nil }
        return (r, held)
    }

    /// The members of the top-level object: each one's key, where it starts, where its value starts and where it ends.
    static func top(_ b: [UInt8]) -> [(key: String, start: Int, value: Int, end: Int)]? {
        guard (try? JSONSerialization.jsonObject(with: Data(b))) is [String: Any] else { return nil }      // valid, so what follows can't run off the end
        var i = 0
        func ws() { while i < b.count, [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 } }
        func string() -> Bool {
            var j = i + 1
            while j < b.count { if b[j] == 0x5C { j += 2; continue }; if b[j] == 0x22 { i = j + 1; return true }; j += 1 }
            return false
        }
        func value() -> Bool {
            guard i < b.count else { return false }
            if b[i] == 0x22 { return string() }
            if b[i] == 0x7B || b[i] == 0x5B {
                var depth = 0
                while i < b.count {
                    if b[i] == 0x22 { guard string() else { return false }; continue }
                    if b[i] == 0x7B || b[i] == 0x5B { depth += 1 }
                    if b[i] == 0x7D || b[i] == 0x5D { depth -= 1; if depth == 0 { i += 1; return true } }
                    i += 1
                }
                return false
            }
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
            return true
        }
        var out: [(key: String, start: Int, value: Int, end: Int)] = []
        ws()
        guard i < b.count, b[i] == 0x7B else { return nil }        // (UTF-8 only: a UTF-16 file, or one with a byte-order mark, is not read)
        i += 1                                         // the {
        while true {
            ws()
            guard i < b.count else { return nil }
            if b[i] == 0x7D { break }
            if !out.isEmpty { guard b[i] == 0x2C else { return nil }; i += 1; ws() }
            let start = i
            guard i < b.count, b[i] == 0x22, string() else { return nil }
            var wrapped: [UInt8] = [0x5B]
            wrapped += b[start..<i]
            wrapped.append(0x5D)
            guard let key = ((try? JSONSerialization.jsonObject(with: Data(wrapped))) as? [String])?.first else { return nil }
            ws()
            guard i < b.count, b[i] == 0x3A else { return nil }
            i += 1; ws()
            let v = i
            guard value() else { return nil }
            out.append((key, start, v, i))
        }
        return out
    }
}

// MARK: - the engine

enum SessionsExport {
    enum Keys { case leaveOut, keep }

    /// One profile to export: from where it is now (`source`), or from a backup of it.
    struct Part {
        var profile: String
        var name: String
        var source: SessionsBackup.Source?
        var backup: SessionsRestore.Backup?
        var emails: [String] = []           // addresses of its accounts: taken out of everything that is written
        var windowOpen = false              // its Claude window is open: the Code-tab list is left out of a fresh copy
        var windowClosed: () -> Bool = { true }
    }

    /// A session (a transcript with its folder) or a lone file of a project: what is left out together.
    struct Unit: Hashable {
        var project: String
        var id: String
        var isSession: Bool
    }

    static func unit(of rel: String) -> Unit? {
        let c = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard c.count >= 3, c[0] == "transcripts" else { return nil }
        // a project's memory files are not a session's: each one stands alone
        if c.count >= 4, c[2] == "memory" { return Unit(project: c[1], id: c[2...].joined(separator: "/"), isSession: false) }
        if c.count == 3 {
            if c[2].hasSuffix(".jsonl") { return Unit(project: c[1], id: String(c[2].dropLast(".jsonl".count)).lowercased(), isSession: true) }
            return Unit(project: c[1], id: c[2], isSession: false)
        }
        return Unit(project: c[1], id: c[2].lowercased(), isSession: true)
    }

    /// The session id in a retention marker's file name: "<id>.desktop-released.json" (lowercased), else nil.
    static func markerID(_ leaf: String) -> String? {
        let suffix = ".desktop-released.json"
        guard leaf.count > suffix.count, leaf.lowercased().hasSuffix(suffix) else { return nil }
        let id = String(leaf.dropLast(suffix.count)).lowercased()
        return id.contains("/") ? nil : id
    }

    /// A retention marker of Claude Code's directly in a project's folder: "transcripts/<project>/<session>.desktop-released.json".
    static func marker(of rel: String) -> (project: String, id: String)? {
        let c = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard c.count == 3, c[0] == "transcripts", let id = markerID(c[2]) else { return nil }
        return (c[1], id)
    }

    /// A transcript a running Claude Code session holds, or changed in the last two minutes.
    static func inUse(unit u: Unit, held: Set<String>, mtime: Date?, now: Date) -> Bool {
        guard u.isSession else { return false }
        return held.contains(u.id) || (mtime.map { now.timeIntervalSince($0) < SessionsRestore.recent } ?? false)
    }

    // MARK: the preview (read-only)

    struct Preview: Equatable {
        struct Project: Equatable {
            var name: String                // "~/projects/app"
            var sessions = 0
            var bytes: Int64 = 0
            var inUse = 0
            var keyed = 0                   // with keys
        }
        var profile: String
        var name: String
        var sessions = 0                    // transcripts (sessions) in the source
        var transcriptBytes: Int64 = 0
        var entries = 0                     // the window's Code-tab entries
        var tasks = 0
        var windowBytes: Int64 = 0
        var windowLeftOut = false           // its window is open
        var keyedSessions = 0
        var keyedBytes: Int64 = 0
        var keyedFiles = 0                  // lone files with keys (a window entry, a project's other files)
        var connections = 0                 // entries holding connection settings (a zip leaves them out)
        var unreadable = 0                  // entries a zip leaves out because they aren't UTF-8 JSON objects it can read
        var markersOrphan = 0               // retention markers with no transcript beside them: left out
        var markersKeyed = 0                // retention markers of a session that holds keys: left out with it unless keys are kept
        /// The retention markers an export with this choice leaves out.
        func markersLeftOut(_ keys: Keys) -> Int { markersOrphan + (keys == .leaveOut ? markersKeyed : 0) }
        var keyKinds: [Secret: Int] = [:]   // sessions that hold each kind
        var inUse = 0
        var projects: [Project] = []

        var keyed: Int { keyedSessions + keyedFiles }
        /// The sessions an export of these would hold.
        func sessionsIn(_ keys: Keys) -> Int { keys == .leaveOut ? sessions - keyedSessions : sessions }
        func bytesIn(_ keys: Keys) -> Int64 { transcriptBytes + windowBytes - (keys == .leaveOut ? keyedBytes : 0) }
    }

    /// A file of the source: where it is in a backup's layout, where it is now, how long.
    struct FileRef {
        var role: SessionsBackup.Item.Role
        var rel: String
        var src: String
        var bytes: Int64
    }

    static func files(of part: Part) -> (files: [FileRef], counts: SessionsBackup.Counts) {
        if let s = part.source {
            let inv = SessionsBackup.inventory(s, window: !part.windowOpen, transcripts: true)
            return (inv.files.map { FileRef(role: $0.role, rel: $0.rel, src: $0.src, bytes: $0.bytes) }, inv.counts)
        }
        guard let b = part.backup, let m = SessionsBackup.load(profile: b.profile, id: b.id, place: b.place) else { return ([], SessionsBackup.Counts()) }
        let list = m.items.filter { $0.role == .window || $0.role == .transcript }
            .map { FileRef(role: $0.role, rel: $0.path, src: b.dir.appendingPathComponent($0.path).path, bytes: $0.bytes) }
        return (list, m.counts)
    }

    /// Counts what an export would hold and scans the transcripts (and the window's entries) for keys. Nothing is written.
    /// nil: stopped. `progress` is told bytes as they are scanned.
    static func preview(_ part: Part, now: Date = Date(), cancel: () -> Bool = { false }, progress: ((Int64) -> Void)? = nil) -> Preview? {
        var pv = Preview(profile: part.profile, name: part.name)
        let (list, counts) = files(of: part)
        pv.entries = counts.sessions; pv.tasks = counts.tasks
        pv.windowLeftOut = part.windowOpen && part.source != nil
        let held = part.source != nil ? (SessionsRestore.runningSessions() ?? []) : []
        var unitKinds: [Unit: Set<Secret>] = [:]
        var unitBytes: [Unit: Int64] = [:]
        var unitUse: [Unit: Bool] = [:]
        var unitFiles: [Unit: String] = [:]
        var markerList: [(project: String, id: String)] = []
        for f in list {
            if cancel() { return nil }
            if f.role == .window {
                pv.windowBytes += f.bytes
                let leaf = (f.rel as NSString).lastPathComponent
                // an entry as a zip will hold it: without its two fields (counted), and not at all when it can't be read (counted apart)
                if leaf.hasPrefix("local_"), f.bytes < 64 << 20, let d = FileManager.default.contents(atPath: f.src) {
                    guard let w = EntryConnections.without(d) else { pv.unreadable += 1; continue }
                    if w.held > 0 { pv.connections += 1 }
                    progress?(Int64(d.count))
                    if !SecretScan.scan(w.data).isEmpty { pv.keyedFiles += 1; pv.keyedBytes += f.bytes }
                    continue
                }
                if leaf == "scheduled-tasks.json", f.bytes < 64 << 20, let d = FileManager.default.contents(atPath: f.src), EntryConnections.top([UInt8](d)) == nil {
                    pv.unreadable += 1; continue                            // a task file a zip can't read is left out too
                }
                if leaf.hasPrefix("local_") || leaf == "scheduled-tasks.json" {
                    guard let kinds = SecretScan.scan(path: f.src, cancel: cancel, progress: progress) else { if cancel() { return nil }; continue }
                    if !kinds.isEmpty { pv.keyedFiles += 1; pv.keyedBytes += f.bytes }
                }
                continue
            }
            if f.role == .transcript, let mk = marker(of: f.rel) { markerList.append(mk); continue }       // counted with its session, below
            guard f.role == .transcript, let u = unit(of: f.rel) else { continue }
            guard let kinds = SecretScan.scan(path: f.src, cancel: cancel, progress: progress) else { if cancel() { return nil }; continue }
            unitKinds[u, default: []].formUnion(kinds)
            unitBytes[u, default: 0] += f.bytes
            if u.isSession, f.rel.split(separator: "/").count == 3 {
                var st = stat()
                let m = lstat(f.src, &st) == 0 ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : nil
                unitUse[u] = part.source != nil && inUse(unit: u, held: held, mtime: m, now: now)
                if unitFiles[u] == nil { unitFiles[u] = f.src }
            }
            pv.transcriptBytes += f.bytes
        }
        for mk in markerList {
            let u = Unit(project: mk.project, id: mk.id, isSession: true)
            if unitFiles[u] == nil { pv.markersOrphan += 1 }          // (unitFiles: the sessions that have a transcript of their own)
            else if !(unitKinds[u] ?? []).isEmpty { pv.markersKeyed += 1 }
        }
        var byProject: [String: Preview.Project] = [:]
        var sampleFor: [String: String] = [:]
        for (u, bytes) in unitBytes {
            let kinds = unitKinds[u] ?? []
            var p = byProject[u.project] ?? Preview.Project(name: u.project)
            if u.isSession {
                pv.sessions += 1; p.sessions += 1; p.bytes += bytes
                if unitUse[u] == true { pv.inUse += 1; p.inUse += 1 }
                if let s = unitFiles[u], sampleFor[u.project] == nil { sampleFor[u.project] = s }
            } else { p.bytes += bytes }
            if !kinds.isEmpty {
                if u.isSession { pv.keyedSessions += 1; p.keyed += 1 } else { pv.keyedFiles += 1 }
                pv.keyedBytes += bytes
                for k in kinds { pv.keyKinds[k, default: 0] += 1 }
            }
            byProject[u.project] = p
        }
        pv.projects = byProject.map { key, value in
            var p = value
            p.name = projectWords(key, sample: sampleFor[key])
            return p
        }.sorted { $0.sessions != $1.sessions ? $0.sessions > $1.sessions : $0.name < $1.name }
        return pv
    }

    /// "~/projects/app" for a project folder of Claude Code's (its name is the path with / and . turned into -): the folder
    /// the sessions ran in when a transcript says so, else the name read back as a path.
    static func projectWords(_ folder: String, sample: String?) -> String {
        if let s = sample, let cwd = cwd(inTranscript: s) { return tilde(cwd) }
        let guess = folder.hasPrefix("-") ? "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/") : folder
        return tilde(guess)
    }

    /// The folder a transcript's first lines say it ran in.
    static func cwd(inTranscript path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        let n = pread(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        guard let re = try? NSRegularExpression(pattern: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        guard let v = try? JSONDecoder().decode(String.self, from: Data(("\"" + text[r] + "\"").utf8)), v.hasPrefix("/") else { return nil }
        return v
    }

    // MARK: making the file

    struct PartOutcome: Equatable {
        var name: String
        var sessions = 0
        var entries = 0
        var tasks = 0
        var bytes: Int64 = 0
        var keysLeftOut = 0                 // sessions left out for the keys in them
        var keysKept = 0
        var cut = 0                         // transcripts copied up to their last full line
        var connectionsLeftOut = 0          // Code-tab entries whose connection settings a zip leaves out
        var unreadableLeftOut = 0           // Code-tab entries a zip leaves out because it can't tell what they hold
        var markersLeftOut = 0              // retention markers whose transcript isn't in the file (missing, or left out for keys)
    }

    struct Job {
        var parts: [Part]
        var keys: Keys
        var password: String? = nil         // an encrypted disk image when set, else a zip
        var destination: URL                // the file to make (its extension is already .zip or .dmg)
        var rootName: String                // the folder inside, named for the export
        var place: URL = BackupPrefs.placeURL
        var now = Date()
        /// Every identity cl_audit knows (all profiles', not only the ones exported): scrubbed wherever it is found, and the
        /// only things the leak check refuses. What the parts themselves name (their addresses, backups, window folders) is added.
        var known = Identities()
    }

    struct Outcome: Equatable {
        var file: URL
        var bytes: Int64
        var parts: [PartOutcome]
        var sessions: Int { parts.reduce(0) { $0 + $1.sessions } }
        var keysLeftOut: Int { parts.reduce(0) { $0 + $1.keysLeftOut } }
        var keysKept: Int { parts.reduce(0) { $0 + $1.keysKept } }
        var cut: Int { parts.reduce(0) { $0 + $1.cut } }
        var connectionsLeftOut: Int { parts.reduce(0) { $0 + $1.connectionsLeftOut } }
        var unreadableLeftOut: Int { parts.reduce(0) { $0 + $1.unreadableLeftOut } }
        var markersLeftOut: Int { parts.reduce(0) { $0 + $1.markersLeftOut } }
    }

    /// "cl_audit Main 2026-11-05"
    static func rootName(for names: [String], now: Date = Date()) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        let what = names.count == 1 ? (names[0].hasPrefix("Claude ") ? String(names[0].dropFirst(7)) : names[0]) : "all profiles"
        return plainFileName("cl_audit \(what) \(f.string(from: now))")
    }

    /// A name for a file: letters, digits, spaces and - _ . only.
    static func plainFileName(_ s: String) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_."))
        var out = String(String.UnicodeScalarView(s.unicodeScalars.map { ok.contains($0) ? $0 : "-" }))
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "cl_audit export" : String(out.prefix(120))
    }

    /// Makes the file. `progress` is told what it is doing and how far (0...1); `cancel` stops it between files and kills
    /// the tool. Throws, with nothing left behind, when it can't be made whole.
    static func run(_ job: Job, cancel: @escaping () -> Bool = { false }, progress: ((String, Double) -> Void)? = nil) throws -> Outcome {
        let fm = FileManager.default
        guard !job.parts.isEmpty else { throw ArchiveError("Nothing to export.") }
        let ext = job.password == nil ? "zip" : "dmg"
        guard job.destination.pathExtension.lowercased() == ext else { throw ArchiveError("The file should be named .\(ext).") }
        if let pw = job.password, pw.count < 8 { throw ArchiveError("The password needs at least 8 characters.") }
        guard SessionsRestore.plainName(job.rootName), !job.rootName.hasPrefix(".") else { throw ArchiveError("The export's name isn't a plain one.") }
        let destDir = job.destination.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destDir.path, isDirectory: &isDir), isDir.boolValue, access(destDir.path, W_OK) == 0 else {
            throw ArchiveError("The folder \(tilde(destDir.path)) can't be written.")
        }
        var st = stat()
        if lstat(job.destination.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw ArchiveError("\(job.destination.lastPathComponent) is there and isn't a plain file; nothing is written over it.")
        }
        let sources = job.parts.compactMap(\.source)
        if let why = SessionsBackup.placeProblem(job.place, for: sources) { throw ArchiveError(why) }
        // the file must not land inside what is being copied from
        for s in sources {
            var from = [(s.codeDir as NSString).appendingPathComponent("projects")]
            if !s.dataDir.isEmpty { from.append(s.dataDir) }
            // (a folder that holds them, like the home folder, is fine: only a file made inside them would be copied into itself)
            let here = FolderKey.canonical(destDir.path)
            if from.contains(where: { let f = FolderKey.canonical($0); return here == f || here.hasPrefix(f + "/") }) {
                throw ArchiveError("The file would be made inside the sessions it copies; choose another folder.")
            }
        }

        let tag = UUID().uuidString.prefix(8).lowercased()
        let work = job.place.appendingPathComponent(".export-\(tag)")
        do { try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ArchiveError("The backups folder \(tilde(job.place.path)) can't be written.") }
        // who it belongs to: a later launch sweeps it if this process is gone. A folder that can't be claimed isn't used.
        guard SessionsImport.claim(work) else {
            SessionsImport.discard(work)
            throw ArchiveError("cl_audit couldn't mark its work folder in \(tilde(job.place.path)) (the disk may be full or can't be written), so nothing was exported.")
        }
        SessionsImport.register(work)
        // (a work folder that couldn't be removed is no longer this run's either: unregistered, so a later launch's sweep takes it)
        defer { SessionsImport.discard(work); SessionsImport.unregister(work) }
        let fp = Fingerprint()                             // this export's own random key: nothing else can reproduce its fingerprints
        // every identity there is to know, from the start: a part's entries may name another profile's account
        var known = job.known
        for p in job.parts { for e in p.emails { known.add(email: e) }; if let s = p.source { known.add(source: s) } }
        // the names that go in the file (the folder inside, the profiles' names) are scrubbed too: a profile can be named for its address
        let names = Scrubber(known, fp: fp)
        let rootName = names.name(job.rootName)
        let root = work.appendingPathComponent("out").appendingPathComponent(rootName)
        guard (try? fm.createDirectory(at: root.appendingPathComponent("profiles"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else {
            throw ArchiveError("The backups folder \(tilde(job.place.path)) can't be written.")
        }

        let held = job.parts.contains { $0.source != nil } ? (SessionsRestore.runningSessions() ?? []) : []
        var outcomes: [PartOutcome] = []
        var manifestParts: [ExportManifest.Part] = []
        var rawIDs = Set<String>()
        var emails: [String] = []
        for (i, part) in job.parts.enumerated() {
            if cancel() { throw ArchiveError("Stopped.") }
            let label = job.parts.count > 1 ? "\(part.name): " : ""
            // the copy to export from: a backup made now (under the lock, in the export's own hidden place), or the chosen one
            var backup = part.backup
            if backup == nil, let src = part.source {
                progress?("\(label)copying the sessions", 0)
                let lock: SwitchEngine.Lock
                do { lock = try SwitchEngine.Lock.take() } catch { throw ArchiveError("\(error)") }
                defer { lock.release() }
                let m: SessionsBackup.Manifest
                do { m = try SessionsBackup.make(src, kind: .manual, window: !part.windowOpen, transcripts: true, place: work.appendingPathComponent("backups"), now: job.now) }
                catch { throw ArchiveError("\(error)") }
                if !part.windowOpen, !part.windowClosed() { throw ArchiveError("\(part.name)'s Claude window opened during the export; try again.") }
                backup = SessionsRestore.Backup(profile: src.profile, id: m.id, place: work.appendingPathComponent("backups"))
            }
            guard let b = backup else { throw ArchiveError("Nothing to export from.") }
            let dir = "p\(i + 1)"
            let out = root.appendingPathComponent("profiles/\(dir)")
            let (po, ids) = try buildPart(b, part: part, fp: fp, into: out, keys: job.keys, zip: job.password == nil, known: known, held: held, live: part.source != nil, now: job.now, cancel: cancel,
                                          progress: { f in progress?("\(label)writing the files", (Double(i) + f) / Double(job.parts.count)) })
            outcomes.append(po)
            rawIDs.formUnion(ids)
            emails += part.emails
            manifestParts.append(ExportManifest.Part(dir: dir, name: names.name(part.name), profile: part.profile, sessions: po.sessions, entries: po.entries, tasks: po.tasks, bytes: po.bytes))
        }
        let total = outcomes.reduce(Int64(0)) { $0 + $1.bytes }
        let em = ExportManifest(created: job.now, app: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
                                machine: InstallID.current, container: job.password == nil ? "zip" : "image",
                                keys: job.keys == .leaveOut ? "left out" : "kept",
                                keysLeftOut: outcomes.reduce(0) { $0 + $1.keysLeftOut }, keysKept: outcomes.reduce(0) { $0 + $1.keysKept },
                                parts: manifestParts, bytes: total)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try enc.encode(em), to: root.appendingPathComponent("export.json"))

        // the structure carries no known id and no known address: checked on what is about to be packed
        if let leak = leak(in: root, ids: rawIDs.union(known.ids), emails: emails + Array(known.emails)) { throw ArchiveError("The export would have held \(leak); nothing was made.") }

        // free room for the file: about the size of what is in it
        var fs = statfs()
        if statfs(destDir.path, &fs) == 0, Int64(fs.f_bavail) * Int64(fs.f_bsize) < total + total / 10 + (64 << 20) {
            throw ArchiveError("\(tilde(destDir.path)) doesn't have room for the file (\(SessionsBackup.sizeWords(total)) needed).")
        }
        if cancel() { throw ArchiveError("Stopped.") }
        // (an image's temp name ends in .dmg itself: hdiutil adds that to any name without it, and the file it made would then
        // not be the one removed here)
        let tmp = destDir.appendingPathComponent(".\(job.destination.lastPathComponent).partial-\(tag)" + (job.password == nil ? "" : ".dmg"))
        defer { try? fm.removeItem(at: tmp) }
        progress?(job.password == nil ? "making the zip" : "making the encrypted disk image", 0)
        let t0 = Date()
        let watch: () -> Bool = {
            var s = stat()
            if lstat(tmp.path, &s) == 0 { progress?(job.password == nil ? "making the zip" : "making the encrypted disk image", min(0.99, Double(s.st_size) / Double(max(total, 1)))) }
            return false
        }
        if let pw = job.password {
            // hdiutil reads the password from stdin: it is never an argument, and nothing here keeps it
            // (the folder that holds the export's folder: the image's top then has that one folder, as the zip does)
            let args = ["create", "-srcfolder", root.deletingLastPathComponent().path, "-volname", String(rootName.prefix(27)), "-fs", "APFS", "-format", "UDZO",
                        "-encryption", "AES-256", "-stdinpass", "-quiet", tmp.path]
            // (composed form, so the same password typed on another Mac or keyboard opens it)
            let npw = pw.precomposedStringWithCanonicalMapping
            guard let r = Tool.run("/usr/bin/hdiutil", args, stdin: Data(npw.utf8), secret: npw, cancel: cancel, poll: watch) else { throw ArchiveError("hdiutil couldn't start.") }
            if r.cancelled { throw ArchiveError("Stopped.") }
            guard r.status == 0 else { throw ArchiveError("The disk image couldn't be made (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))).") }
        } else {
            let args = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", "--keepParent", root.path, tmp.path]
            guard let r = Tool.run("/usr/bin/ditto", args, cancel: cancel, poll: watch) else { throw ArchiveError("ditto couldn't start.") }
            if r.cancelled { throw ArchiveError("Stopped.") }
            guard r.status == 0 else { throw ArchiveError("The zip couldn't be made (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))).") }
        }
        _ = t0
        var made = stat()
        guard lstat(tmp.path, &made) == 0, (made.st_mode & S_IFMT) == S_IFREG, made.st_size > 0 else { throw ArchiveError("The file wasn't made.") }
        chmod(tmp.path, 0o600)
        // the Save panel has asked about a file that is there: it is replaced, in one step
        guard rename(tmp.path, job.destination.path) == 0 else { throw ArchiveError("The file couldn't be put at \(tilde(job.destination.path)).") }
        progress?("done", 1)
        return Outcome(file: job.destination, bytes: Int64(made.st_size), parts: outcomes)
    }

    private static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .withoutOverwriting) } catch { throw ArchiveError("couldn't write \(url.lastPathComponent)") }
        chmod(url.path, 0o600)
    }

    // MARK: one profile's part

    /// Builds `out` (a backup's layout) from the backup `b`: ids and addresses replaced, keys decided, the in-use cut.
    /// Returns what it holds and the raw ids it replaced.
    private static func buildPart(_ b: SessionsRestore.Backup, part: Part, fp: Fingerprint, into out: URL, keys: Keys, zip: Bool, known: Identities, held: Set<String>, live: Bool, now: Date,
                                  cancel: () -> Bool, progress: @escaping (Double) -> Void) throws -> (PartOutcome, Set<String>) {
        let fm = FileManager.default
        guard let m = SessionsBackup.load(profile: b.profile, id: b.id, place: b.place) else { throw ArchiveError("The backup isn't there any more.") }
        guard m.version == 1 else { throw ArchiveError("That backup is from a newer cl_audit.") }
        try fm.createDirectory(at: out, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var po = PartOutcome(name: part.name)

        // the ids in this part: the accounts the backup names, the folders of the window, the profile's record, the sidebar's scopes
        var ids = Set<String>()
        for a in m.accounts { ids.insert(a.account.lowercased()); ids.insert(a.organization.lowercased()) }
        for it in m.items where it.role == .window {
            if let c = SessionsRestore.components(it.path), c.count == 4 { ids.insert(c[1].lowercased()); ids.insert(c[2].lowercased()) }
        }
        func recordData(_ rel: String) -> Data? {
            guard let c = SessionsRestore.components(rel), let r = SessionsRestore.Reader(path: b.dir.path), let f = r.file(c) else { return nil }
            defer { close(f.fd) }
            return SessionsRestore.read(f.fd, size: f.st.st_size)
        }
        if let d = recordData("records/profile.json"), let rec = try? JSONDecoder().decode(SessionsBackup.ProfileRecord.self, from: d) {
            if let s = rec.seat { ids.insert(s.account.lowercased()); ids.insert(s.organization.lowercased()) }
            for s in rec.standby { if let q = s.seat { ids.insert(q.account.lowercased()); ids.insert(q.organization.lowercased()) } }
        }
        var sidebarText: String?
        if let d = recordData("sidebar/epitaxyPrefs.json") {
            sidebarText = String(decoding: d, as: UTF8.self)
            // a scope key is "<account>/<organisation>"
            if let re = try? NSRegularExpression(pattern: "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})"),
               let t = sidebarText {
                for mt in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                    for g in 1...2 { if let r = Range(mt.range(at: g), in: t) { ids.insert(String(t[r]).lowercased()) } }
                }
            }
        }
        // what is replaced: this part's own ids and addresses, and every other identity cl_audit knows
        var ident = known
        for id in ids where !id.isEmpty { ident.ids.insert(id) }
        for e in part.emails where !e.isEmpty { ident.emails.insert(e.lowercased()) }
        let ids2 = ident.ids
        let scrubber = Scrubber(ident, fp: fp)
        func map(_ s: String) -> String { ids2.contains(s.lowercased()) ? fp.of(s.lowercased()) : s }

        guard let reader = SessionsRestore.Reader(path: b.dir.path) else { throw ArchiveError("The backup's folder isn't a plain folder.") }
        var made = Set<String>()
        func create(_ rel: String) throws -> String {
            let path = (out.path as NSString).appendingPathComponent(rel)
            let dir = (path as NSString).deletingLastPathComponent
            if made.insert(dir).inserted {
                do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { throw ArchiveError("couldn't write in the export's folder") }
            }
            return path
        }
        var items: [SessionsBackup.Item] = []
        var counts = SessionsBackup.Counts()
        var cloned = 0
        var leftOut = m.leftOut
        var seatsOut: [SeatID] = []
        var keyedUnits = Set<Unit>()
        var unitKinds: [Unit: Set<Secret>] = [:]

        // 1. the window's files, scrubbed
        var windowFiles: [(SessionsBackup.Item, [String])] = []
        var codeFiles: [(SessionsBackup.Item, [String])] = []
        for it in m.items {
            guard let c = SessionsRestore.components(it.path) else { throw ArchiveError("The backup names a path that isn't a plain one.") }
            switch it.role {
            case .window: if c.count == 4, c[0] == "window" { windowFiles.append((it, c)) }
            case .transcript: if c.count >= 3, c[0] == "transcripts" { codeFiles.append((it, c)) }
            default: break
            }
        }
        var seen = Set<SeatID>()
        for (_, c) in windowFiles {
            if cancel() { throw ArchiveError("Stopped.") }
            let name = c[3]
            if name.hasPrefix("deleted_") || SessionsBackup.isSignIn(name) { continue }
            guard name.hasPrefix("local_") || name == "scheduled-tasks.json" else { continue }
            guard let f = reader.file(c), let raw = SessionsRestore.read(f.fd, size: f.st.st_size) else { leftOut += 1; continue }
            close(f.fd)
            var body = raw
            if zip, name.hasPrefix("local_") {
                // a zip leaves out an entry's connection settings (the encrypted image keeps them); the keys are looked for in what stays
                if let r = EntryConnections.without(raw) {
                    body = r.data
                    if r.held > 0 { po.connectionsLeftOut += 1 }
                } else {
                    po.unreadableLeftOut += 1; leftOut += 1; continue       // an entry this can't read (UTF-16, a byte-order mark, not an object): it can't be vouched for
                }
            } else if zip, name == "scheduled-tasks.json", EntryConnections.top([UInt8](raw)) == nil {
                po.unreadableLeftOut += 1; leftOut += 1; continue           // the same for a task file it can't read
            }
            if !SecretScan.scan(body).isEmpty {
                if keys == .leaveOut { po.keysLeftOut += 1; continue }
                po.keysKept += 1
            }
            let data = scrubber.data(body)
            let fa = fp.of(c[1].lowercased()), fo = fp.of(c[2].lowercased())
            let rel = "window/\(fa)/\(fo)/\(name)"
            try write(data, to: URL(fileURLWithPath: create(rel)))
            items.append(SessionsBackup.Item(role: .window, original: rel, path: rel, bytes: Int64(data.count)))
            cloned += 1
            if seen.insert(SeatID(account: fa, organization: fo)).inserted { seatsOut.append(SeatID(account: fa, organization: fo)) }
            if name.hasPrefix("local_"), name.hasSuffix(".json") {
                po.entries += 1; counts.sessions += 1
                if !SidebarPlan.flag("isArchived", in: raw) { counts.sidebar += 1 }
            } else if name == "scheduled-tasks.json", let j = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                let n = (j["scheduledTasks"] as? [Any])?.count ?? 0
                po.tasks += n; counts.tasks += n
            }
        }
        // 2. the sidebar records and the profile's record
        var hasSidebar = false
        if !windowFiles.isEmpty || m.items.contains(where: { $0.role == .sidebar }), let t = sidebarText {
            let data = scrubber.data(Data(t.utf8))
            if keys == .leaveOut, !SecretScan.scan(data).isEmpty {
                po.keysLeftOut += 1
            } else {
                try write(data, to: URL(fileURLWithPath: create("sidebar/epitaxyPrefs.json")))
                items.append(SessionsBackup.Item(role: .sidebar, original: "sidebar/epitaxyPrefs.json", path: "sidebar/epitaxyPrefs.json", bytes: Int64(data.count),
                                                 part: "preferences.epitaxyPrefs"))
                hasSidebar = true
            }
        }
        if let d = recordData("records/profile.json"), let rec = try? JSONDecoder().decode(SessionsBackup.ProfileRecord.self, from: d) {
            var r = rec
            r.id = "profile"
            r.name = scrubber.name(rec.name)
            r.seat = rec.seat.map { SeatID(account: map($0.account), organization: map($0.organization)) }
            r.standby = rec.standby.enumerated().map { i, s in
                SessionsBackup.ProfileRecord.Standby(id: "standby-\(i + 1)", seat: s.seat.map { SeatID(account: map($0.account), organization: map($0.organization)) })
            }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(r) {
                try write(data, to: URL(fileURLWithPath: create("records/profile.json")))
                items.append(SessionsBackup.Item(role: .record, original: "records/profile.json", path: "records/profile.json", bytes: Int64(data.count)))
            }
        }

        // 3. the transcripts: keys decided per session, then copied (the in-use cut up to a full line)
        var unitMembers: [Unit: [(SessionsBackup.Item, [String])]] = [:]
        var markers: [(SessionsBackup.Item, [String])] = []
        var exportedSessions = Set<String>()                          // "<project>/<session>" of every transcript put in the file (by its source name)
        for (it, c) in codeFiles {
            if SessionsBackup.isSignIn((c.last ?? "")) { continue }
            if marker(of: it.path) != nil { markers.append((it, c)); continue }       // decided with its session, below
            if let u = unit(of: it.path) { unitMembers[u, default: []].append((it, c)) }
        }
        var scanned: Int64 = 0
        let totalBytes = max(1, codeFiles.reduce(Int64(0)) { $0 + $1.0.bytes })
        for (u, members) in unitMembers.sorted(by: { ($0.key.project, $0.key.id) < ($1.key.project, $1.key.id) }) {
            if cancel() { throw ArchiveError("Stopped.") }
            var kinds = Set<Secret>()
            for (it, _) in members {
                let path = b.dir.appendingPathComponent(it.path).path
                guard let k = SecretScan.scan(path: path, cancel: cancel, progress: { n in scanned += n; progress(Double(scanned) / Double(totalBytes) * 0.5) }) else {
                    if cancel() { throw ArchiveError("Stopped.") }
                    throw ArchiveError("A transcript couldn't be read to check it for keys (\((it.path as NSString).lastPathComponent)); nothing was made.")
                }
                kinds.formUnion(k)
            }
            if !kinds.isEmpty {
                unitKinds[u] = kinds
                if keys == .leaveOut { keyedUnits.insert(u); if u.isSession { po.keysLeftOut += 1 }; leftOut += members.count; continue }
                if u.isSession { po.keysKept += 1 }
            }
            var counted = false
            for (it, _) in members {
                let src = b.dir.appendingPathComponent(it.path).path
                // the name it gets in the file: a known account id or address in a path (a tool result named for it, a project
                // folder named for an address) becomes its fingerprint, so the file's own names carry nothing known either
                let rel = scrubber.name(it.path)
                let dst = try create(rel)
                var bytes = it.bytes
                if rel.hasSuffix(".jsonl"), !endsOnLine(src) {
                    // a session still writing: up to its last full line
                    switch copyThroughLastLine(src, dst) {
                    case .some(let n) where n > 0: bytes = n; po.cut += 1
                    default: leftOut += 1; continue
                    }
                } else {
                    switch SessionsBackup.copyOne(src, dst, single: true) {
                    case .cloned, .copied: break
                    case .gone: leftOut += 1; continue
                    case .failed(let why): throw ArchiveError("couldn't copy \((src as NSString).lastPathComponent) (\(why))")
                    }
                }
                items.append(SessionsBackup.Item(role: .transcript, original: rel, path: rel, bytes: bytes))
                cloned += 1; po.bytes += bytes
                let parts = it.path.split(separator: "/").map(String.init)
                if parts.count == 3, parts[2].hasSuffix(".jsonl") { exportedSessions.insert(parts[1] + "/" + String(parts[2].dropLast(".jsonl".count)).lowercased()) }
                if u.isSession, !counted, rel.split(separator: "/").count == 3 { po.sessions += 1; counts.transcripts += 1; counted = true }
            }
        }
        // 3b. Claude Code's retention markers (<session>.desktop-released.json): each travels with its exported transcript and
        // is otherwise left out and counted, never refused (a marker can outlive its transcript)
        for (it, c) in markers {
            if cancel() { throw ArchiveError("Stopped.") }
            guard let mk = marker(of: it.path), exportedSessions.contains(mk.project + "/" + mk.id) else { po.markersLeftOut += 1; leftOut += 1; continue }
            guard let f = reader.file(c), f.st.st_size <= 1 << 20, let raw = SessionsRestore.read(f.fd, size: f.st.st_size) else { po.markersLeftOut += 1; leftOut += 1; continue }
            close(f.fd)
            if !SecretScan.scan(raw).isEmpty, keys == .leaveOut { po.markersLeftOut += 1; leftOut += 1; continue }
            let data = scrubber.data(raw)
            let mrel = scrubber.name(it.path)
            try write(data, to: URL(fileURLWithPath: create(mrel)))
            items.append(SessionsBackup.Item(role: .transcript, original: mrel, path: mrel, bytes: Int64(data.count)))
            cloned += 1; po.bytes += Int64(data.count)
        }

        // 4. the manifest of this part
        let windowBytes = items.filter { $0.role == .window }.reduce(Int64(0)) { $0 + $1.bytes }
        po.bytes += windowBytes + items.filter { $0.role == .sidebar || $0.role == .record }.reduce(Int64(0)) { $0 + $1.bytes }
        let mm = SessionsBackup.Manifest(id: m.id, profile: part.profile, kind: .manual, created: m.created, seconds: 0,
                                         accounts: seatsOut.sorted { ($0.account, $0.organization) < ($1.account, $1.organization) }, counts: counts,
                                         window: !items.filter { $0.role == .window }.isEmpty || hasSidebar, transcripts: m.transcripts,
                                         bytes: items.reduce(0) { $0 + $1.bytes }, cloned: cloned, copied: 0, copiedBytes: 0, leftOut: leftOut,
                                         dataDir: "", codeDir: "", items: items)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try write(try enc.encode(mm), to: URL(fileURLWithPath: create("backup.json")))
        progress(1)
        return (po, ids2)
    }

    /// Whether the file's last byte is a newline (or it is empty).
    static func endsOnLine(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return true }
        var c: UInt8 = 0
        return pread(fd, &c, 1, st.st_size - 1) == 1 && c == 0x0A
    }

    /// A copy of a file up to and including its last newline, made new (never over a file). Returns its length; nil: none
    /// could be made, or the file has no complete line yet (0).
    static func copyThroughLastLine(_ src: String, _ dst: String) -> Int64? {
        let fd = open(src, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { return nil }
        let size = Int64(st.st_size)
        // the last newline, looking back from the end
        var end: Int64 = 0
        var pos = size
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        search: while pos > 0 {
            let n = Int(min(Int64(buf.count), pos))
            pos -= Int64(n)
            guard pread(fd, &buf, n, off_t(pos)) == n else { return nil }
            for i in stride(from: n - 1, through: 0, by: -1) where buf[i] == 0x0A { end = pos + Int64(i) + 1; break search }
        }
        guard end > 0 else { return 0 }
        let out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { return nil }
        defer { close(out) }
        var big = [UInt8](repeating: 0, count: 1 << 20)
        var off: Int64 = 0
        while off < end {
            let want = Int(min(Int64(big.count), end - off))
            let n = pread(fd, &big, want, off_t(off))
            guard n > 0 else { unlink(dst); return nil }
            var done = 0
            while done < n {
                let w = big.withUnsafeBytes { Darwin.write(out, $0.baseAddress! + done, n - done) }
                guard w > 0 else { unlink(dst); return nil }
                done += w
            }
            off += Int64(n)
        }
        var times = [st.st_atimespec, st.st_mtimespec]
        futimens(out, &times)
        return end
    }

    /// The first thing in a file under `root` (other than transcripts) that a made export must not hold, else nil: an id or an
    /// address cl_audit knows (`ids`, `emails`: every profile's accounts and the window's folder names; the scrub replaced
    /// them, so any left is a bug), or a private key. Any other id, and any other address, is content, as in a transcript.
    /// A name is looked for as written, with the text's own line breaks and spaces taken out (one broken across lines), and, in
    /// JSON, in each decoded key and string (one written with `@` or `\/`).
    /// It stops the export with a message; nothing is stripped silently.
    static func leak(in root: URL, ids: Set<String>, emails: [String]) -> String? {
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: root.path) else { return nil }
        var files: [String] = []
        var inTranscripts: [String] = []                              // their contents are the user's words; their NAMES are looked at
        for case let rel as String in walk { if rel.contains("transcripts/") { inTranscripts.append(rel) } else { files.append(rel) } }
        let wantedIDs = ids.map { $0.lowercased() }.filter { !$0.isEmpty }
        let wantedMails = emails.map { $0.lowercased() }.filter { !$0.isEmpty }
        func joined(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isWhitespace })) }
        /// by scalars (literal), not by characters: a combining mark or joiner right after a name doesn't hide it
        func has(_ t: String, _ n: String) -> Bool { (t as NSString).range(of: n, options: .literal).location != NSNotFound }
        /// "an account id" / "an address" when the text holds one of the known, else nil
        func held(_ s: String) -> String? {
            let low = s.lowercased()
            for pass in 0..<2 {
                let t = pass == 0 ? low : joined(low)
                if wantedIDs.contains(where: { has(t, $0) }) { return "an account id" }
                if wantedMails.contains(where: { has(t, $0) }) { return "an address" }
            }
            return nil
        }
        // the folder the archive holds everything in: its name can carry an address as a file name writes it ("bob-example.com")
        let topLow = root.lastPathComponent.lowercased()
        if wantedIDs.contains(where: { has(topLow, $0) }) { return "an account id in the name of the export's folder" }
        if wantedMails.contains(where: { has(topLow, $0) || has(topLow, plainFileName($0).lowercased()) }) { return "an address in the name of the export's folder" }
        for rel in inTranscripts {
            let low = rel.lowercased()
            if wantedIDs.contains(where: { has(low, $0) }) { return "an account id in the name of \((rel as NSString).lastPathComponent)" }
            if wantedMails.contains(where: { has(low, $0) || has(low, plainFileName($0).lowercased()) }) { return "an address in the name of \((rel as NSString).lastPathComponent)" }
        }
        for rel in files {
            let path = (root.path as NSString).appendingPathComponent(rel)
            let name = (rel as NSString).lastPathComponent
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            // a file too big to look through can't be vouched for: refused, not skipped
            guard st.st_size < 64 << 20, let d = fm.contents(atPath: path) else { return "\(name), which is too big (or unreadable) to be checked" }
            if let what = held(rel) { return "\(what) in the name of \(name)" }
            let text = String(decoding: d, as: UTF8.self)
            if let what = held(text) { return "\(what) in \(name)" }
            if text.lowercased().contains("-----begin ") && text.lowercased().contains("private key") { return "a private key in \(name)" }
            if let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) {
                var found: String?
                func visit(_ v: Any) {
                    if found != nil { return }
                    if let o = v as? [String: Any] {
                        for (k, x) in o { if let what = held(k) { found = what; return }; visit(x) }
                    } else if let a = v as? [Any] {
                        for x in a { visit(x) }
                    } else if let s = v as? String, let what = held(s) { found = what }
                }
                visit(j)
                if let what = found { return "\(what) (written in a form the scrub didn't take out) in \(name)" }
            } else if let what = held(unescaped(text)) {
                // not JSON the parser takes (an unpaired surrogate, say): the escapes are read here by hand
                return "\(what) (written in a form the scrub didn't take out) in \(name)"
            }
        }
        return nil
    }

    /// A text with its JSON escapes read: `\uXXXX` (a surrogate pair as one character, an unpaired one as nothing), `\/`, `\n` and the like.
    static func unescaped(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= u.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 { guard let h = Character(u[at + k]).hexDigitValue else { return nil }; v = v * 16 + UInt32(h) }
            return v
        }
        while i < u.count {
            guard u[i] == "\\", i + 1 < u.count else { out.append(u[i]); i += 1; continue }
            let c = u[i + 1]
            switch c {
            case "u":
                guard let v = hex4(i + 2) else { out.append(u[i]); i += 1; continue }
                i += 6
                if (0xD800...0xDBFF).contains(v), i + 6 <= u.count, u[i] == "\\", u[i + 1] == "u", let lo = hex4(i + 2), (0xDC00...0xDFFF).contains(lo) {
                    i += 6
                    if let sc = Unicode.Scalar(0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)) { out.append(sc) }
                } else if let sc = Unicode.Scalar(v) { out.append(sc) }          // (an unpaired surrogate is none)
            case "n", "t", "r", "b", "f": out.append(" "); i += 2
            case "/", "\"", "\\": out.append(c); i += 2
            default: out.append(u[i]); i += 1
            }
        }
        return String(out)
    }
}
