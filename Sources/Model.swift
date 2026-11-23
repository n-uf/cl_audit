// Model: which account an icon shows, how its Claude Code login is found, and the usage numbers.
//
// Numbers come from Anthropic's usage endpoint, called with the account's existing Claude Code
// login, read-only from the Keychain. The login is never refreshed, written, logged or sent
// anywhere else. If the login is expired the icon greys out until Claude Code renews it.
// The status line file (<config dir>/usage.json) is used as a fallback when the call fails, only while it is fresh.

import AppKit
import ClaudeAuth
import CryptoKit
import ProfileCore
import Security
import ServiceManagement
import UserNotifications

func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

/// The same path with the home folder written as ~ (how paths are stored in the config file).
func tilde(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// A path as a sentence may say it: `tilde`, and the account and organisation folders under a window's sessions folder
/// (`claude-code-sessions/<account id>/<organisation id>`, the same in `local-agent-mode-sessions`) left out: they are ids of
/// the account, which nothing shown may hold while addresses are hidden. "…/claude-code-sessions/…/local_x.json".
func tildeNoIds(_ path: String) -> String {
    let kinds = ["claude-code-sessions", "local-agent-mode-sessions"]
    var out: [String] = []
    var kindAt = Int.max                              // where the last such folder is: the two folders after it hold the ids
    for (i, part) in tilde(path).split(separator: "/", omittingEmptySubsequences: false).map(String.init).enumerated() {
        if kinds.contains(part) { kindAt = i }
        if i > kindAt, i <= kindAt &+ 2, UUID(uuidString: part) != nil {
            if out.last != "…" { out.append("…") }    // each id folder is replaced on its own; two in a row read as one
        } else {
            out.append(part)
        }
    }
    return out.joined(separator: "/")
}

/// Words for what went wrong, for every note, problem, failure line, notification and log that comes from a file operation:
/// a thrown error as fixed words (never the system's own text, which names the path, and under a window's
/// claude-code-sessions that path holds the account's and organisation's ids), and any text that may hold such a path with the
/// folder named by its role. Whatever the "Show emails" setting says: the ids are never shown.
enum PlainWords {
    /// The role every folder under a window's sessions is named by.
    static let sessionsFolder = "the account's sessions folder"

    /// A thrown error in words that name no path. The system's errors (Cocoa, POSIX) say what happened from their code; cl_audit's
    /// own (SwitchError, BackupError, …) keep their own words, with any path under a sessions folder named by its role.
    static func why(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain {
            return reason(domain: ns.domain, code: ns.code, under: ns.userInfo[NSUnderlyingErrorKey] as? NSError)
        }
        // any other system error (an NSError of another domain, or one of Foundation's own, URLError say): its code only, never
        // its text, which can carry the path in its user info
        if type(of: error) is NSError.Type || String(reflecting: type(of: error)).hasPrefix("Foundation.") {
            return "the system couldn't do it (error \(ns.code))"
        }
        return noSessionPaths("\(error)")
    }

    /// The problems a receipt keeps, as one note: each said through `stored(_:)`, then joined.
    static func stored<S: Sequence>(_ problems: S) -> String where S.Element == String {
        problems.map { stored($0) }.joined(separator: " ")
    }

    /// One problem a receipt keeps, as it is shown. A receipt saved by an earlier build (26.11.86 and before) can hold a raw
    /// system error ("x.json didn't move: Error Domain=… UserInfo={NSFilePath=…/claude-code-sessions/<id>/<id>/…}") or a
    /// system sentence naming a folder by its id ("… in the folder “<id>”"): the raw error is said in fixed words, a path
    /// through a sessions folder by its role, a folder named by an id as "…". A problem this build wrote is said as it is.
    static func stored(_ line: String) -> String {
        var t = line
        if let r = t.range(of: "Error Domain=") {
            t = String(t[..<r.lowerBound]) + "the system couldn't do it" + (line.hasSuffix(".") ? "." : "")
        }
        t = noSessionPaths(t)
        let quotedID = #"[“"'‘][0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[”"'’]"#
        guard let re = try? NSRegularExpression(pattern: quotedID) else { return t }
        return re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "“…”")
    }

    /// `text` with every path that runs through a window's sessions folder (and what follows it: the ids) named by its role.
    static func noSessionPaths(_ text: String) -> String {
        guard text.contains("claude-code-sessions") || text.contains("local-agent-mode-sessions") else { return text }
        let pattern = #"[^\s"'“”‘’()<>]*(claude-code-sessions|local-agent-mode-sessions)[^\s"'“”‘’()<>]*"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return sessionsFolder }
        let whole = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: whole, withTemplate: NSRegularExpression.escapedTemplate(for: sessionsFolder))
    }

    /// A path a backup or an archive names (it holds the account's and organisation's ids as folder names): every id (a UUID, or
    /// its first 8 or more characters) as "…". For the words that quote what a file claims.
    static func noIds(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{1,4}){0,3}(?:-[0-9a-fA-F]{1,12})?") else { return "…" }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "…")
    }

    private static func reason(domain: String, code: Int, under: NSError?) -> String {
        let posix: Int32? = domain == NSPOSIXErrorDomain ? Int32(truncatingIfNeeded: code)
            : under.flatMap { $0.domain == NSPOSIXErrorDomain ? Int32(truncatingIfNeeded: $0.code) : nil }
        switch (domain == NSCocoaErrorDomain ? code : nil, posix) {
        case (257?, _), (513?, _), (_, EACCES?), (_, EPERM?): return "the system refused it (no permission)"
        case (4?, _), (260?, _), (_, ENOENT?): return "something it needed isn't there"
        case (516?, _), (_, EEXIST?), (_, ENOTEMPTY?): return "something is already there"
        case (640?, _), (_, ENOSPC?), (_, EDQUOT?): return "the disk is full"
        case (642?, _), (_, EROFS?): return "the volume is read-only"
        case (_, ENOTDIR?): return "a file is where a folder should be"
        case (_, EISDIR?): return "a folder is where a file should be"
        case (_, EBUSY?): return "it is in use"
        case (_, ELOOP?): return "a link is in the way"
        case (_, EXDEV?): return "it can't be moved to another volume"
        case (258?, _), (514?, _): return "a name it needed isn't valid"
        default: return "the system couldn't do it (error \(posix.map { Int($0) } ?? code))"
        }
    }
}

// MARK: - Account

// (Seat and its one comparison are ProfileCore's: Core/Identity.swift)

extension SignedInAccount {
    /// A seat as ClaudeAuth names an account (from a record: guessed). Its ids and address only.
    init(_ s: Seat) { self.init(accountID: s.account, email: s.email, organizationID: s.organization, origin: .record) }
}

struct Account {
    let label: String
    let name: String
    let configDir: String          // expanded
    let isDefaultDir: Bool         // plain ~/.claude, used without CLAUDE_CONFIG_DIR
    let claudeUserDataDir: String? // separate desktop window's data folder (expanded); nil = standard window
    let hasWindow: Bool            // the profile has a Claude window (off: nothing opens one)

    /// The profile's label as its icons show it: its own, else its name's first six letters. Reads nothing (the Dock tile
    /// plug-in draws with it; `init` looks at the folder too).
    static func label(_ e: AccountEntry) -> String { e.label.isEmpty ? String(e.name.uppercased().prefix(6)) : e.label }

    init(_ e: AccountEntry) {
        label = Self.label(e)
        name = e.name
        configDir = expand(e.configDir.isEmpty ? "~/.claude" : e.configDir)
        isDefaultDir = Self.isDefault(configDir: configDir)
        claudeUserDataDir = e.desktop == .separate && !e.desktopDataDir.isEmpty ? expand(e.desktopDataDir) : nil
        hasWindow = e.claudeWindow
    }

    /// The folder is Claude Code's default one (~/.claude, however it is spelled: a trailing slash, a link): used with
    /// CLAUDE_CONFIG_DIR unset. Claude Code takes the variable's being set at all for a custom folder, even when it
    /// names ~/.claude: its record then moves into the folder and its Keychain item gets a hash suffix.
    static func isDefault(configDir: String) -> Bool {
        FolderKey.canonical(configDir) == FolderKey.canonical("~/.claude")
    }

    /// The folder as ClaudeAuth (Auth/) knows it: the one place its sign-in is named and read.
    var authFolder: AuthFolder { AuthFolder(path: configDir, isDefault: isDefaultDir) }

    /// The one folder reader of Claude Code's account (ClaudeAuth's FolderRecordReader), one for the whole app: the account a
    /// folder's .claude.json names (a guess), signed in by an account id or an address (the kit's rule, A1). It parses through
    /// ClaudeFiles' own bounded, cached reader (never a FIFO, through a link named by the path) and only after a write; its
    /// `generation` counts each time the record names someone else (another account or seat, a sign-in, a sign-out).
    static let records = FolderRecordReader(parse: { ClaudeFiles.oauthBlock(at: $0) }, stamp: { Account.recordStamp($0) })

    /// The folder's record now, through the one folder reader: Claude Code's account as the file names it (guessed; the kit's
    /// FolderSignIn.answer puts a verified word over it) and the reader's generation.
    static func codeRecord(configDir: String) -> FolderRecordReader.Look { records.look(path: claudeJSON(configDir: configDir)) }

    /// A record's stamp for the one folder reader: through a link named by the path itself (~/.claude.json may be one, and the
    /// file behind it is what changes), with the status-change time in its date, so an edit in place that keeps the size and
    /// puts the date back still moves it (as ClaudeFiles' own cache key does).
    static func recordStamp(_ path: String) -> RecordStamp {
        var st = stat()
        guard stat(path, &st) == 0 else { return .none }
        func seconds(_ t: timespec) -> TimeInterval { TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9 }
        return RecordStamp(modified: Date(timeIntervalSince1970: max(seconds(st.st_mtimespec), seconds(st.st_ctimespec))),
                           size: UInt64(st.st_size), file: UInt64(st.st_ino))
    }

    /// Claude Code names the Keychain item after the config folder: the plain name for the
    /// default folder, otherwise the name plus the first 8 hex chars of SHA-256 of the path (AuthFolder.keychainItems).
    var keychainServices: [String] { authFolder.keychainItems }

    /// The account Claude Code says this folder is logged in to (oauthAccount in its .claude.json).
    /// The default folder keeps that file in the home folder, not inside ~/.claude.
    func expectedEmail() -> String? { Self.expectedEmail(configDir: configDir) }

    /// The file where Claude Code records which account a folder is signed in to: the default folder keeps it in the
    /// home folder (~/.claude.json), any other inside the folder.
    static func claudeJSON(configDir: String) -> String {
        let dir = expand(configDir)
        return ClaudeFiles.recordPath(folder: dir, isDefault: isDefault(configDir: dir))
    }

    /// The seat Claude Code says the folder is signed in to now (its .claude.json), or nil when it isn't.
    static func signedInSeat(configDir: String) -> Seat? { record(configDir: configDir)?.seat }

    /// The folder's record (ClaudeFiles: bounded, never blocking, parsed again only when the file changed).
    static func record(configDir: String) -> ClaudeFiles.Record? { ClaudeFiles.record(at: claudeJSON(configDir: configDir)) }

    /// The folder's .claude.json is too large to read (ClaudeFiles.recordMax): its account isn't known, which the screens
    /// say as such, never as "signed out".
    static func recordTooLarge(configDir: String) -> Bool { ClaudeFiles.tooLarge(claudeJSON(configDir: configDir)) }

    static func expectedEmail(configDir: String) -> String? { record(configDir: configDir)?.emailAddress }

    /// Claude's own name for the folder's plan ("Ultra"), as Claude Code recorded it (oauthAccount.planDisplayName in
    /// .claude.json), or nil. The sign-in's subscriptionType can be coarser: an Ultra account's says "max".
    static func planName(configDir: String) -> String? { record(configDir: configDir)?.plan }

    /// The plan as words: Claude's own name as it is ("Ultra"), the sign-in's lower-case one capitalised ("Max").
    static func planWords(_ plan: String) -> String { plan == plan.lowercased() ? plan.capitalized : plan }

    /// The claude.ai account id Claude Code recorded for the folder (to compare with the desktop app's).
    static func expectedAccountUuid(configDir: String) -> String? { record(configDir: configDir)?.accountUuid }

    static func sha8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

// MARK: - Usage data

// (Usage, Freshness, ScopedLimit, AtLimit and Credits are ProfileCore's: Core/Limits.swift)

extension Usage {
    /// The numbers a saved record carries (the agent's status/<id>.json), for the screens that draw a Usage: nil when it
    /// has none. The record is the one answer: the menu bar and the Dock icon take their numbers from it.
    static func of(_ s: IconStatus?) -> Usage? {
        guard let s, let at = s.updatedAt, s.fiveHour != nil || s.weekly != nil else { return nil }
        return Usage(fiveHour: s.fiveHour, fiveHourResets: s.fiveHourResets, weekly: s.weekly, weeklyResets: s.weeklyResets,
                     fetchedAt: at, source: s.source ?? "Anthropic", scoped: s.scoped ?? [], credits: s.credits,
                     noFiveHour: s.noFiveHour == true)
    }
}

extension ScopedLimit {
    /// Its row in the panels.
    var limit: Limit {
        Limit(id: key, title: "\(name) · week", name: name, p: percent, resets: resets, window: 7 * 86400)
    }
}

// (FetchState's cases are ProfileCore's: Core/Reading.swift. Its words are here.)
extension FetchState {
    /// Said when a refused read is the problem (the Settings row, the menus, the saved status).
    static let deniedWords = "Signed in, but cl_audit can't read this sign-in yet: allow cl_audit Agent when macOS asks (Always Allow), then Refresh now."
    /// Said when the Keychain item is there but isn't a sign-in in the form cl_audit knows.
    static let unreadableWords = "Signed in, but the sign-in isn't in a form cl_audit knows: Refresh now, or sign in again from Terminal."

    var menuText: String? {
        switch self {
        case .idle, .ok: return nil
        case .noLogin: return "No Claude Code sign-in for this profile"
        case .expired: return "Sign-in expired: Sign in…, or use Claude Code once to renew it"
        case .denied: return Self.deniedWords
        case .unreadable: return Self.unreadableWords
        case .rateLimited: return "Usage service busy, retrying later"
        case .failed(let why): return "Couldn't update: \(why)"
        }
    }
}

// (Login's cases and Login.parse are ProfileCore's: Core/Parsing.swift. Reading the Keychain item is ClaudeAuth's:
// Auth/Keychain.swift.)
extension Login {
    /// Reads the login with Apple's `security` tool, the same way Claude Code reads it (KeychainSignIn.read): a token;
    /// no item at all (`.notFound`); an item that was refused or timed out (`.denied`); an item whose text isn't the
    /// expected shape (`.unreadable`). Each with its own words.
    static func read(_ account: Account) -> Login {
        KeychainSignIn.read(account.authFolder, tool: { let r = runSecurity($0); return (r.0, r.1) })
    }

    /// The check's seam: what runs `security` (arguments in, exit status and output out).
    nonisolated(unsafe) static var runSecurity: ([String]) -> (Int32, Data) = { let r = KeychainSignIn.system($0); return (r.status, r.output) }
}

// (UsageParser's replies are ProfileCore's: Core/Parsing.swift. The status line file is read here.)
extension UsageParser {
    /// The file the status line script writes: {five_hour:{used_percentage,resets_at}, seven_day:{…}, updated_at}.
    /// Used only while it is fresh: written in the last 15 minutes (Freshness); otherwise it is ignored as if it weren't
    /// there (Claude Code writes it only while it runs, so an old one is old numbers). A limit whose reset has passed is
    /// left out (the week stays when the 5-hour reset just passed); nil when no limit is left.
    static func fromStatusLine(_ account: Account, now: Date = Date()) -> Usage? {
        let url = URL(fileURLWithPath: account.configDir).appendingPathComponent("usage.json")
        // bounded and never blocking (a FIFO named usage.json returns at once): this runs on the agent's main-thread tick
        guard let data = SafeRead.whole(url.path, max: SafeRead.recordMax),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = date(j["updated_at"]), Freshness.isFresh(updated, now: now) else { return nil }
        var u = Usage(fetchedAt: updated, source: "Claude Code status line")
        if let w = j["five_hour"] as? [String: Any] { u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"]) }
        if let w = j["seven_day"] as? [String: Any] { u.weekly = percent(w); u.weeklyResets = date(w["resets_at"]) }
        u = u.current(now: now)
        return (u.fiveHour == nil && u.weekly == nil) ? nil : u
    }
}


extension Process {
    /// Waits for the process to end without running the run loop. `waitUntilExit` runs it, and on the main
    /// thread that can redraw a SwiftUI window in the middle of an update, which crashes.
    func waitQuietly() { while isRunning { usleep(5_000) } }
}
