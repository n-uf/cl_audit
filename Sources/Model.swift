// Model: which account an icon shows, how its Claude Code login is found, and the usage numbers.
//
// Numbers come from Anthropic's usage endpoint, called with the account's existing Claude Code
// login, read-only from the Keychain. The login is never refreshed, written, logged or sent
// anywhere else. If the login is expired the icon greys out until Claude Code renews it.
// The status line file (<config dir>/usage.json) is used as a fallback when the call fails.

import AppKit
import CryptoKit
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

/// A Claude account seat: an account in an organisation. Usage limits belong to it, so a personal plan and a team
/// seat on the same email are two seats. Every set-up profile is linked to exactly one, and no two profiles share one.
struct Seat: Codable, Equatable, Hashable {
    var account: String            // Claude's accountUuid
    var organization: String?      // its organizationUuid (nil when Claude recorded none)
    var email: String?             // shown only; checks compare the ids
    var linkedAt: Date?
    var was: String?               // the email of the seat it replaced, when the profile was linked to another account

    /// The same seat (the ids; not the email or when it was linked).
    func same(_ o: Seat?) -> Bool { o.map { account == $0.account && organization == $0.organization } ?? false }
}

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
        guard let data = FileManager.default.contents(atPath: claudeJSON(configDir: configDir)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any],
              let account = oauth["accountUuid"] as? String, !account.isEmpty else { return nil }
        return Seat(account: account, organization: oauth["organizationUuid"] as? String, email: oauth["emailAddress"] as? String)
    }

    static func expectedEmail(configDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: claudeJSON(configDir: configDir)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["emailAddress"] as? String
    }

    /// Claude's own name for the folder's plan ("Ultra"), as Claude Code recorded it (oauthAccount.planDisplayName in
    /// .claude.json), or nil. The sign-in's subscriptionType can be coarser: an Ultra account's says "max".
    static func planName(configDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: claudeJSON(configDir: configDir)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any],
              let name = oauth["planDisplayName"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }

    /// The plan as words: Claude's own name as it is ("Ultra"), the sign-in's lower-case one capitalised ("Max").
    static func planWords(_ plan: String) -> String { plan == plan.lowercased() ? plan.capitalized : plan }

    /// The claude.ai account id Claude Code recorded for the folder (to compare with the desktop app's).
    static func expectedAccountUuid(configDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: claudeJSON(configDir: configDir)),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["accountUuid"] as? String
    }

    static func sha8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }
}

// MARK: - Usage data

struct Usage {
    var fiveHour: Double?
    var fiveHourResets: Date?
    var weekly: Double?
    var weeklyResets: Date?
    var fetchedAt: Date
    var source: String
    var scoped: [ScopedLimit] = []       // weekly limits of one model (Fable on Max, Ultra, premium seats), beside the two
    var credits: Credits? = nil          // usage credits (Credits.swift)
    var noFiveHour = false               // the plan has no 5-hour limit (Ultra): only the week counts
}

/// A weekly limit of its own for one model: "Fable" may use up to a share of the week. Full, it holds back only that
/// model; the profile can still work with the others, so it never takes the full-limit box or the countdown face.
struct ScopedLimit: Codable, Equatable {
    var name: String                     // "Fable"
    var percent: Double?
    var resets: Date?

    /// Alert marks and the limit row's id: "mfable".
    var key: String { "m" + name.lowercased().filter { $0.isLetter || $0.isNumber } }
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
        case .noLogin: return "No Claude Code login for this profile"
        case .expired: return "Login expired: use Claude Code once to renew it"
        case .denied: return Self.deniedWords
        case .unreadable: return Self.unreadableWords
        case .rateLimited: return "Usage service busy, retrying later"
        case .failed(let why): return "Couldn't update: \(why)"
        }
    }
}

enum Login {
    case token(String, expiresAt: Date?, plan: String?)
    /// No Keychain item for the folder (`security` said "not found" for every account name tried).
    case notFound
    /// The read was refused or timed out (a locked Keychain, "Don't Allow", a prompt nobody answered).
    case denied
    /// An item is there and was read, but its text isn't a sign-in in a form cl_audit knows (not JSON, or JSON without
    /// claudeAiOauth.accessToken). Nothing of its content is kept or shown: only that it was there.
    case unreadable

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

    /// What `security -w` printed for an item that was read: the token, or `.unreadable`. Never logs or keeps the text.
    static func parse(_ out: Data) -> Login {
        guard let data = decode(out),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return .unreadable }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return .token(token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
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

    /// `security -w` prints the stored text, or hex when it isn't plain text.
    private static func decode(_ raw: Data) -> Data? {
        guard let text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.hasPrefix("{") { return Data(text.utf8) }
        guard text.count % 2 == 0, text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            guard let b = UInt8(text[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        return Data(bytes)
    }
}

enum UsageParser {
    static func date(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let x = n.doubleValue
            return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
        }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func percent(_ w: [String: Any]) -> Double? {
        for key in ["utilization", "used_percentage", "percent"] {
            if let n = w[key] as? NSNumber { return n.doubleValue }
        }
        return nil
    }

    /// Accepts {five_hour:{utilization,resets_at}, seven_day:{…}} and a {limits:[{type,percent,resets_at}]} variant.
    static func fromAPI(_ data: Data) -> Usage? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var u = Usage(fetchedAt: Date(), source: "Anthropic")
        if let w = j["five_hour"] as? [String: Any] { u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"]) }
        if let w = j["seven_day"] as? [String: Any] { u.weekly = percent(w); u.weeklyResets = date(w["resets_at"]) }
        if u.fiveHour == nil, u.weekly == nil, let limits = j["limits"] as? [[String: Any]] {
            for w in limits {
                let kind = ((w["type"] ?? w["name"] ?? w["window"]) as? String ?? "").lowercased()
                if kind.contains("five") || kind.contains("5h") || kind.contains("session") {
                    u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"])
                } else if kind.contains("seven") || kind.contains("week") {
                    u.weekly = percent(w); u.weeklyResets = date(w["resets_at"])
                }
            }
        }
        guard u.fiveHour != nil || u.weekly != nil else { return nil }
        u.scoped = scoped(j)
        u.credits = Credits.parse(j)
        u.noFiveHour = noFiveHour(j)
        return u
    }

    /// The plan has no 5-hour limit at all (Ultra): no five_hour window and no "session" kind in limits[]. A plan
    /// that has one but no session open (Max) still lists the session limit, so it isn't taken for this.
    static func noFiveHour(_ j: [String: Any]) -> Bool {
        guard j["five_hour"] as? [String: Any] == nil, let limits = j["limits"] as? [[String: Any]], !limits.isEmpty
        else { return false }
        return !limits.contains { ($0["kind"] as? String) == "session" || ($0["group"] as? String) == "session" }
    }

    /// The model limits in limits[]: {kind: "weekly_scoped", percent, resets_at, scope: {model: {display_name}}}.
    static func scoped(_ j: [String: Any]) -> [ScopedLimit] {
        guard let limits = j["limits"] as? [[String: Any]] else { return [] }
        return limits.compactMap { w in
            guard (w["kind"] as? String) == "weekly_scoped",
                  let model = (w["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String) ?? (model["id"] as? String), !name.isEmpty
            else { return nil }
            return ScopedLimit(name: name, percent: percent(w), resets: date(w["resets_at"]))
        }
    }

    /// First e-mail address anywhere in the profile reply (it sits under account.email_address / email).
    static func email(_ data: Data) -> String? {
        func find(_ v: Any) -> String? {
            if let d = v as? [String: Any] {
                for (k, x) in d where k.lowercased().contains("email") { if let s = x as? String, s.contains("@") { return s } }
                for (_, x) in d { if let s = find(x) { return s } }
            } else if let a = v as? [Any] {
                for x in a { if let s = find(x) { return s } }
            }
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)).flatMap(find)
    }

    /// The file the status line script writes: {five_hour:{used_percentage,resets_at}, seven_day:{…}, updated_at}.
    static func fromStatusLine(_ account: Account) -> Usage? {
        let url = URL(fileURLWithPath: account.configDir).appendingPathComponent("usage.json")
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updated = date(j["updated_at"]) else { return nil }
        var u = Usage(fetchedAt: updated, source: "Claude Code status line")
        if let w = j["five_hour"] as? [String: Any] { u.fiveHour = percent(w); u.fiveHourResets = date(w["resets_at"]) }
        if let w = j["seven_day"] as? [String: Any] { u.weekly = percent(w); u.weeklyResets = date(w["resets_at"]) }
        return (u.fiveHour == nil && u.weekly == nil) ? nil : u
    }
}


extension Process {
    /// Waits for the process to end without running the run loop. `waitUntilExit` runs it, and on the main
    /// thread that can redraw a SwiftUI window in the middle of an update, which crashes.
    func waitQuietly() { while isRunning { usleep(5_000) } }
}
