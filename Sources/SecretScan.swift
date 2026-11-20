// SecretScan: the engines' one secret scan, the only place the shapes of keys and tokens live. App-neutral: Foundation only, no
// page, no profile, no account; a file is read through SafeRead (bounded, non-blocking, never through a link), in pieces, so a
// file of any size is looked through in the same small memory.
//
// Its users: an export (each session's files, the setup and window files it carries, a move's side files, the retention markers),
// the export's preview (what would be left out), the export's last look over what it made (privateKeyMention: no private key in
// any file but a transcript), Claude Code's setup (SessionsSetup: settings values, MCP env), the side files (SessionsSide), the
// checklist (CodeChecklist), and Checks' own scan of the repository (Checks/tools/secretscan, which runs this code as it is).
//
// What it finds is a kind (Secret), never the key: nothing found is kept, logged or shown. A key starts where a word does (a
// letter, digit, "_" or "-" right before it means it is part of something else), and each kind has its own rest: a length, an
// alphabet, a digit somewhere (OpenAI), three dotted parts (a JWT). The word list of personal and business words is not here:
// it is the checks' own, kept outside the repository.

import Foundation

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

    /// The kinds of key in a file, read in chunks without following a link (SafeRead.chunks). nil: it couldn't be read, or
    /// `cancel` said stop.
    static func scan(path: String, cancel: () -> Bool = { false }, progress: ((Int64) -> Void)? = nil) -> Set<Secret>? {
        var found = Set<Secret>()
        let read = SafeRead.chunks(path, chunk: chunk, carry: carry, go: { !cancel() }) { b, fresh in
            scan(b, into: &found)
            progress?(Int64(fresh))
        }
        return read ? found : nil
    }

    /// The export's last look over a file it made (anything but a transcript): a private key's armour, however it is spelled or
    /// spaced. Wider than the `.privateKey` shape on purpose: "-----begin " and "private key" anywhere in the text (any case) are
    /// enough, so a key the scrub or a hand edit bent out of shape still stops the export.
    static func privateKeyMention(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.contains("-----begin ") && low.contains("private key")
    }
}
