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

    /// The same seat (the ids; not the email or when it was linked).
    func same(_ o: Seat?) -> Bool { o.map { account == $0.account && organization == $0.organization } ?? false }
}

struct Account {
    let label: String
    let name: String
    let configDir: String          // expanded
    let isDefaultDir: Bool         // plain ~/.claude, used without CLAUDE_CONFIG_DIR
    let claudeUserDataDir: String? // separate desktop window's data folder (expanded); nil = standard window

    init(_ e: AccountEntry) {
        label = e.label.isEmpty ? String(e.name.uppercased().prefix(6)) : e.label
        name = e.name
        configDir = expand(e.configDir.isEmpty ? "~/.claude" : e.configDir)
        isDefaultDir = configDir == expand("~/.claude")
        claudeUserDataDir = e.desktop == .separate && !e.desktopDataDir.isEmpty ? expand(e.desktopDataDir) : nil
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

    /// The seat Claude Code says the folder is signed in to now (its .claude.json), or nil when it isn't.
    static func signedInSeat(configDir: String) -> Seat? {
        let dir = expand(configDir)
        let file = dir == expand("~/.claude") ? expand("~/.claude.json")
                                              : (dir as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any],
              let account = oauth["accountUuid"] as? String, !account.isEmpty else { return nil }
        return Seat(account: account, organization: oauth["organizationUuid"] as? String, email: oauth["emailAddress"] as? String)
    }

    static func expectedEmail(configDir: String) -> String? {
        let dir = expand(configDir)
        let file = dir == expand("~/.claude") ? expand("~/.claude.json")
                                              : (dir as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: file),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = j["oauthAccount"] as? [String: Any] else { return nil }
        return oauth["emailAddress"] as? String
    }

    /// The claude.ai account id Claude Code recorded for the folder (to compare with the desktop app's).
    static func expectedAccountUuid(configDir: String) -> String? {
        let dir = expand(configDir)
        let file = dir == expand("~/.claude") ? expand("~/.claude.json")
                                              : (dir as NSString).appendingPathComponent(".claude.json")
        guard let data = FileManager.default.contents(atPath: file),
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
}

enum FetchState: Equatable {
    case idle, ok, noLogin, expired, denied, rateLimited, failed(String)

    var menuText: String? {
        switch self {
        case .idle, .ok: return nil
        case .noLogin: return "No Claude Code login for this profile"
        case .expired: return "Login expired: use Claude Code once to renew it"
        case .denied: return "Keychain access was not allowed"
        case .rateLimited: return "Usage service busy, retrying later"
        case .failed(let why): return "Couldn't update: \(why)"
        }
    }
}

enum Login {
    case token(String, expiresAt: Date?, plan: String?)
    case notFound, denied

    /// Reads the login with Apple's `security` tool, the same way Claude Code reads it. Claude Code
    /// stores the item through that tool, so the item already trusts it: no prompt, and no new
    /// Keychain permission for this app. (Reading it through the Keychain API needs "Always Allow",
    /// which is lost every time Claude Code re-saves a renewed login, so macOS kept asking.)
    static func read(_ account: Account) -> Login {
        for service in account.keychainServices {
            for user in [NSUserName() as String?, nil] {
                var args = ["find-generic-password", "-s", service, "-w"]
                if let user { args += ["-a", user] }
                let (status, out) = security(args)
                if status == 44 { continue }              // no such item
                if status != 0 { return .denied }
                guard let data = decode(out),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let oauth = json["claudeAiOauth"] as? [String: Any],
                      let token = oauth["accessToken"] as? String, !token.isEmpty
                else { return .notFound }
                let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
                return .token(token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
            }
        }
        return .notFound
    }

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
        return (u.fiveHour == nil && u.weekly == nil) ? nil : u
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
