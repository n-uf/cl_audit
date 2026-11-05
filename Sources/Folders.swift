// Folder rules shared by the new-account page and Settings: one account per Claude Code folder and per
// desktop window, what kind of folder a path is, and which Claude apps and Claude Code sessions are
// running (setting up an account wants them closed).

import AppKit

// MARK: - Comparing folders

enum FolderKey {
    /// A folder as the file system sees it: ~ expanded, symbolic links resolved, no trailing slash, lower case
    /// (the Mac's disks ignore case by default), so two spellings of one folder compare equal.
    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: expand(path)).standardizedFileURL.resolvingSymlinksInPath()
        var p = url.path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }

    /// The same folder, or one inside the other.
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let x = canonical(a), y = canonical(b)
        return x == y || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }

    static let standardDataDir = "~/Library/Application Support/Claude"
}

// MARK: - Who uses what

enum FolderRules {
    /// The other account whose Claude Code folder is this one, contains it or sits inside it. A folder that keeps one
    /// of a profile's standby sign-ins (Accounts.swift) is that profile's too.
    static func configOwner(_ path: String, among accounts: [AccountEntry], except id: String? = nil) -> AccountEntry? {
        guard !path.isEmpty else { return nil }
        return accounts.first { $0.id != id && !$0.configDir.isEmpty && FolderKey.overlaps($0.configDir, path) }
            ?? accounts.first { a in a.id != id && a.standby.contains { s in s.configDir.map { !$0.isEmpty && FolderKey.overlaps($0, path) } ?? false } }
    }

    /// The desktop window an account opens, as one key: the standard window or its own window's folder.
    static func windowKey(_ mode: DesktopMode, _ dataDir: String) -> String? {
        switch mode {
        case .standard: return FolderKey.canonical(FolderKey.standardDataDir)
        case .separate: return dataDir.isEmpty ? nil : FolderKey.canonical(dataDir)
        }
    }

    /// The other account that already opens this desktop window.
    static func windowOwner(_ mode: DesktopMode, _ dataDir: String, among accounts: [AccountEntry], except id: String? = nil) -> AccountEntry? {
        guard let key = windowKey(mode, dataDir) else { return nil }
        return accounts.first { $0.id != id && windowKey($0.desktop, $0.desktopDataDir) == key }
    }

    /// The profile (other than `id`) that has this seat: linked to it, keeping it as a standby account, or, not linked
    /// yet, signed in to it. An account belongs to one profile.
    static func seatOwner(_ seat: Seat?, among accounts: [AccountEntry], except id: String? = nil,
                          signedIn: (String) -> Seat? = Account.signedInSeat) -> AccountEntry? {
        guard let seat else { return nil }
        return accounts.first { $0.id != id && $0.has(seat) }
            ?? accounts.first { $0.id != id && $0.seat == nil && seat.same(signedIn($0.configDir)) }
    }

    /// Profiles not linked yet get the seat their folder is signed in to now, unless an earlier profile has it
    /// (linked, or signed in to it and not linked yet). Linked profiles are left as they are.
    static func linkSeats(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = Account.signedInSeat,
                          now: Date = Date()) -> [AccountEntry] {
        var out = accounts
        for i in out.indices where out[i].seat == nil {
            guard var s = signedIn(out[i].configDir) else { continue }
            if out.indices.contains(where: { $0 != i && out[$0].has(s) }) { continue }
            if out.indices.contains(where: { $0 < i && out[$0].seat == nil && s.same(signedIn(out[$0].configDir)) }) { continue }
            s.linkedAt = now
            out[i].seat = s
        }
        return out
    }

    /// A standby account added by its address ("Sign in to another account…") gets its seat once its folder's sign-in
    /// names one, unless that account is already the profile's own or another profile's: then it stays without one and
    /// Accounts says so. One whose seat is known keeps it (a folder signed in to another account later only holds its
    /// numbers back, as for the account in use).
    static func linkStandbySeats(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = Account.signedInSeat) -> [AccountEntry] {
        var out = accounts
        for i in out.indices {
            for j in out[i].standby.indices where out[i].standby[j].seat == nil {
                guard let dir = out[i].standby[j].configDir, var s = signedIn(dir) else { continue }
                if out[i].has(s) || s.same(signedIn(out[i].configDir)) { continue }
                if out.indices.contains(where: { $0 != i && out[$0].has(s) }) { continue }
                s.linkedAt = Date()
                out[i].standby[j].seat = s
                if let e = s.email { out[i].standby[j].email = e }
            }
        }
        return out
    }

    /// The claude.ai account id the profile's Claude window last used (lastKnownAccountUuid in its data folder's
    /// config.json, while a sign-in is stored there), or nil. Only the id: nothing else from that file is read or kept.
    /// The usual Claude app is checked too.
    static func windowAccount(_ e: AccountEntry) -> String? {
        guard e.claudeWindow else { return nil }
        let dir = Account(e).claudeUserDataDir ?? expand(FolderKey.standardDataDir)
        guard let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent("config.json")),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              j.keys.contains(where: { $0.hasPrefix("oauth:tokenCache") }),
              let id = j["lastKnownAccountUuid"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// The profile's Claude window is signed in to another claude.ai account than its Claude Code folder (or, with
    /// none there, than the account the profile is linked to). Both moved to the same new account is the link's
    /// business ("Use this account"), not the window's.
    static func windowOnAnotherAccount(_ e: AccountEntry, signedIn: (String) -> Seat? = Account.signedInSeat,
                                       window: (AccountEntry) -> String? = windowAccount) -> Bool {
        guard let w = window(e), let mine = signedIn(e.configDir)?.account ?? e.seat?.account else { return false }
        return w != mine
    }

    /// A linked profile whose folder is now signed in to another seat (Claude Code was signed in to another account
    /// there): that seat, and the profile that already has it, if any (then linking to it is refused).
    struct SeatMove: Equatable {
        let to: Seat
        let owner: AccountEntry?
    }

    static func seatMove(_ e: AccountEntry, among accounts: [AccountEntry],
                         signedIn: (String) -> Seat? = Account.signedInSeat) -> SeatMove? {
        guard let linked = e.seat, let now = signedIn(e.configDir), !now.same(linked) else { return nil }
        return SeatMove(to: now, owner: seatOwner(now, among: accounts, except: e.id, signedIn: signedIn))
    }

    /// "Use this account": links the profile to the seat its folder is signed in to now. Everything else stays (name,
    /// look, Dock icon and its place, Claude window, settings). nil when there's nothing to link or another profile
    /// has that seat.
    static func relink(_ id: String, in accounts: [AccountEntry], signedIn: (String) -> Seat? = Account.signedInSeat,
                       now: Date = Date()) -> [AccountEntry]? {
        guard let i = accounts.firstIndex(where: { $0.id == id }),
              let move = seatMove(accounts[i], among: accounts, signedIn: signedIn), move.owner == nil else { return nil }
        var out = accounts, s = move.to
        s.linkedAt = now
        s.was = accounts[i].seat?.email
        out[i].seat = s
        return out
    }

    /// A profile that can't be linked because another profile has the seat its folder is signed in to.
    static func seatTaken(_ e: AccountEntry, among accounts: [AccountEntry],
                          signedIn: (String) -> Seat? = Account.signedInSeat) -> AccountEntry? {
        guard e.seat == nil, let s = signedIn(e.configDir) else { return nil }
        // the first profile signed in to it gets it: only later ones are the ones left out (a profile keeping it as a
        // standby account has it too)
        if let linked = accounts.first(where: { $0.id != e.id && $0.has(s) }) { return linked }
        guard let i = accounts.firstIndex(where: { $0.id == e.id }) else { return nil }
        return accounts[..<i].first { $0.seat == nil && s.same(signedIn($0.configDir)) }
    }

    /// Clashes between saved accounts, as one message for the Settings bar (nil when all is well).
    static func clash(in accounts: [AccountEntry]) -> String? {
        for (i, a) in accounts.enumerated() {
            for b in accounts[(i + 1)...] {
                if !a.configDir.isEmpty, !b.configDir.isEmpty, FolderKey.overlaps(a.configDir, b.configDir) {
                    return "“\(a.name)” and “\(b.name)” share the Claude Code folder \(tilde(expand(a.configDir))). Give one of them its own folder."
                }
                if let k = windowKey(a.desktop, a.desktopDataDir), k == windowKey(b.desktop, b.desktopDataDir) {
                    return "“\(a.name)” and “\(b.name)” open the same Claude window. Give one of them a separate window."
                }
            }
        }
        return nil
    }
}

// MARK: - What a folder is

enum FolderKind: Equatable {
    case missing                     // nothing there yet (a new folder)
    case empty                       // an empty folder
    case claudeCode(email: String?)  // Claude Code settings, maybe signed in
    case other                       // something else: refused

    static func of(_ path: String) -> FolderKind {
        let dir = expand(path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue else { return .other }
        // A folder macOS won't let the app read (privacy-protected, like ~/Documents) isn't treated as empty.
        guard let all = try? fm.contentsOfDirectory(atPath: dir) else { return .other }
        let names = all.filter { $0 != ".DS_Store" }
        if names.isEmpty { return .empty }
        let marks: Set<String> = [".claude.json", "settings.json", "projects", "todos", "statsig", "shell-snapshots", "CLAUDE.md"]
        let isClaude = FolderKey.canonical(dir) == FolderKey.canonical("~/.claude") || names.contains { marks.contains($0) }
        return isClaude ? .claudeCode(email: Account.expectedEmail(configDir: path)) : .other
    }

    /// When Claude Code last used the folder (its newest session or settings file), for "last used 3 weeks ago".
    static func lastUsed(_ path: String) -> Date? {
        let dir = expand(path)
        let candidates = ["projects", ".claude.json", "settings.json", "history.jsonl"].map { (dir as NSString).appendingPathComponent($0) }
        return candidates.compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max()
    }
}

// MARK: - What's running

/// A Claude desktop app or Claude Code session that is running now.
struct ClaudeRun: Identifiable, Equatable {
    enum Kind: Equatable { case desktop, codeTab, terminal }
    let id: pid_t
    let kind: Kind
    let folder: String          // data folder (desktop) or Claude Code folder (sessions), with ~
}

enum ClaudeRuns {
    /// Every Claude desktop app and Claude Code session of this user. Reads each session's environment only
    /// for CLAUDE_CONFIG_DIR (which folder it uses); nothing else from it is kept. Call off the main thread.
    static func scan() -> [ClaudeRun] {
        var runs: [ClaudeRun] = []
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID) {
            let dir = Launcher.arguments(of: app.processIdentifier).first { $0.hasPrefix("--user-data-dir=") }
            let folder = dir.map { tilde(String($0.dropFirst("--user-data-dir=".count))) } ?? FolderKey.standardDataDir
            runs.append(ClaudeRun(id: app.processIdentifier, kind: .desktop, folder: folder))
        }
        for pid in pids(named: "claude") {
            let path = run("/bin/ps", ["-o", "comm=", "-p", "\(pid)"])
            let kind: ClaudeRun.Kind = path.contains("/Library/Application Support/Claude") ? .codeTab : .terminal
            runs.append(ClaudeRun(id: pid, kind: kind, folder: configDir(of: pid)))
        }
        return runs
    }

    /// Quits the Claude desktop apps (their Code-tab sessions end with them).
    static func quitDesktopApps() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID).forEach { $0.terminate() }
    }

    private static func pids(named name: String) -> [pid_t] {
        run("/usr/bin/pgrep", ["-x", "-U", "\(getuid())", name]).split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The session's CLAUDE_CONFIG_DIR, or ~/.claude when it isn't set.
    private static func configDir(of pid: pid_t) -> String {
        let env = run("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", "\(pid)"])
        for part in env.split(separator: " ") where part.hasPrefix("CLAUDE_CONFIG_DIR=") {
            return tilde(String(part.dropFirst("CLAUDE_CONFIG_DIR=".count)))
        }
        return "~/.claude"
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitQuietly()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Watches what's running every 2 s while the new-account page is open.
final class RunsMonitor: ObservableObject {
    @Published private(set) var runs: [ClaudeRun] = []
    @Published private(set) var checked = false
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Offscreen renders: what counts as running, instead of this Mac's real Claude processes.
    static var preview: [ClaudeRun]? = nil

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let r = Self.preview ?? ClaudeRuns.scan()
            DispatchQueue.main.async {
                if r != self.runs { self.runs = r }
                self.checked = true
            }
        }
    }
}
