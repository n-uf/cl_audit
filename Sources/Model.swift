// Model: which account an icon shows, how its Claude Code login is found, and the usage numbers.
//
// Numbers come from Anthropic's usage endpoint, called with the account's existing Claude Code
// login, read-only from the Keychain. The login is never refreshed, written, logged or sent
// anywhere else. If the login is expired the icon greys out until Claude Code renews it.
// The status line file (<config dir>/usage.json) is used as a fallback when the call fails, only while it is fresh.

import AppKit
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

// MARK: - Account

// (Seat and its one comparison are ProfileCore's: Core/Identity.swift)

struct Account {
    let label: String
    let name: String
    let configDir: String          // expanded
    let isDefaultDir: Bool         // plain ~/.claude, used without CLAUDE_CONFIG_DIR
    let claudeUserDataDir: String? // separate desktop window's data folder (expanded); nil = standard window
    let hasWindow: Bool            // the profile has a Claude window (off: nothing opens one)

    init(_ e: AccountEntry) {
        label = e.label.isEmpty ? String(e.name.uppercased().prefix(6)) : e.label
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

    /// Claude Code names the Keychain item after the config folder: the plain name for the
    /// default folder, otherwise the name plus the first 8 hex chars of SHA-256 of the path.
    var keychainServices: [String] {
        let base = "Claude Code-credentials"
        if isDefaultDir { return [base] }
        return [configDir, configDir + "/"].map { base + "-" + Self.sha8($0) }
    }

    /// The account Claude Code says this folder is logged in to (oauthAccount in its .claude.json).
    /// The default folder keeps that file in the home folder, not inside ~/.claude.
    func expectedEmail() -> String? { Self.expectedEmail(configDir: configDir) }

    /// The file where Claude Code records which account a folder is signed in to: the default folder keeps it in the
    /// home folder (~/.claude.json), any other inside the folder.
    static func claudeJSON(configDir: String) -> String {
        let dir = expand(configDir)
        return isDefault(configDir: dir) ? expand("~/.claude.json") : (dir as NSString).appendingPathComponent(".claude.json")
    }

    /// The seat Claude Code says the folder is signed in to now (its .claude.json), or nil when it isn't.
    static func signedInSeat(configDir: String) -> Seat? {
        guard let oauth = oauthAccount(configDir: configDir),
              let account = oauth["accountUuid"] as? String, !account.isEmpty else { return nil }
        return Seat(account: account, organization: oauth["organizationUuid"] as? String, email: oauth["emailAddress"] as? String)
    }

    /// The folder's .claude.json oauthAccount block: bounded, never blocking (a FIFO or a link to /dev/zero returns at
    /// once), parsed again only when the file changed (SafeRead).
    static func oauthAccount(configDir: String) -> [String: Any]? { SafeRead.oauthAccount(claudeJSON(configDir: configDir)) }

    /// The folder's .claude.json is too large to read (SafeRead.claudeJSONMax): its account isn't known, which the screens
    /// say as such, never as "signed out".
    static func recordTooLarge(configDir: String) -> Bool { SafeRead.tooLarge(claudeJSON(configDir: configDir), max: SafeRead.claudeJSONMax) }

    static func expectedEmail(configDir: String) -> String? {
        oauthAccount(configDir: configDir)?["emailAddress"] as? String
    }

    /// Claude's own name for the folder's plan ("Ultra"), as Claude Code recorded it (oauthAccount.planDisplayName in
    /// .claude.json), or nil. The sign-in's subscriptionType can be coarser: an Ultra account's says "max".
    static func planName(configDir: String) -> String? {
        guard let oauth = oauthAccount(configDir: configDir),
              let name = oauth["planDisplayName"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    /// The plan as words: Claude's own name as it is ("Ultra"), the sign-in's lower-case one capitalised ("Max").
    static func planWords(_ plan: String) -> String { plan == plan.lowercased() ? plan.capitalized : plan }

    /// The claude.ai account id Claude Code recorded for the folder (to compare with the desktop app's).
    static func expectedAccountUuid(configDir: String) -> String? {
        guard let oauth = oauthAccount(configDir: configDir) else { return nil }
        return oauth["accountUuid"] as? String
    }

    static func sha8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

// MARK: - Usage data

// (Usage, Freshness, ScopedLimit, AtLimit and Credits are ProfileCore's: Core/Limits.swift)

extension Usage {
    /// The numbers a saved record carries (the agent's status/<id>.json), for the screens that draw a Usage: nil when it
    /// has none. The record is the one answer: the menu bar, the Dock icon and quick chat all take their numbers from it.
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

enum FetchState: Equatable {
    case idle, ok, noLogin, expired, denied, unreadable, rateLimited, failed(String)

    /// Said when a refused read is the problem (the Settings row, the menus, the saved status).
    static let deniedWords = "Signed in, but cl_audit can't read this sign-in yet: allow cl_audit Agent when macOS asks (Always Allow), then Refresh now."
    /// Said when the Keychain item is there but isn't a sign-in in the form cl_audit knows.
    static let unreadableWords = "Signed in, but the sign-in isn't in a form cl_audit knows: Refresh now, or sign in again from Terminal."

    var menuText: String? {
        switch self {
        case .idle, .ok: return nil
        case .noLogin: return "No Claude Code sign-in for this profile"
        case .expired: return "Login expired: Log in…, or use Claude Code once to renew it"
        case .denied: return Self.deniedWords
        case .unreadable: return Self.unreadableWords
        case .rateLimited: return "Usage service busy, retrying later"
        case .failed(let why): return "Couldn't update: \(why)"
        }
    }
}

// (Login's cases and Login.parse are ProfileCore's: Core/Parsing.swift. Reading the Keychain item stays here.)
extension Login {
    /// Reads the login with Apple's `security` tool, the same way Claude Code reads it. Claude Code
    /// stores the item through that tool, so the item already trusts it: no prompt, and no new
    /// Keychain permission for this app. (Reading it through the Keychain API needs "Always Allow",
    /// which is lost every time Claude Code re-saves a renewed login, so macOS kept asking.)
    ///
    /// Four outcomes, each with its own words: a token; no item at all (`.notFound`); an item that was refused or timed
    /// out (`.denied`); an item whose text isn't the expected shape (`.unreadable`).
    static func read(_ account: Account) -> Login {
        for service in account.keychainServices {
            for user in [NSUserName() as String?, nil] {
                var args = ["find-generic-password", "-s", service, "-w"]
                if let user { args += ["-a", user] }
                let (status, out) = runSecurity(args)
                if status == 44 { continue }              // no such item
                if status != 0 { return .denied }
                return parse(out)
            }
        }
        return .notFound
    }

    /// The check's seam: what runs `security` (arguments in, exit status and output out).
    nonisolated(unsafe) static var runSecurity: ([String]) -> (Int32, Data) = { security($0) }

    /// Runs /usr/bin/security; the output stays in memory and is never logged.
    private static func security(_ args: [String]) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, Data()) }
        // a locked Keychain can keep it waiting; after 30 s it's stopped (the read counts as refused)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitQuietly()
        return (p.terminationStatus, data)
    }
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
