// Folder rules shared by the new-account page and Settings: one account per Claude Code folder and per
// desktop window, what kind of folder a path is, and which Claude apps and Claude Code sessions are
// running (setting up an account wants them closed).

import AppKit
import ProfileCore

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
    /// The other account whose Claude Code folder is this one, contains it or sits inside it. (A profile has exactly one
    /// folder; the folders older versions made for its accounts are left over, no profile's.)
    static func configOwner(_ path: String, among accounts: [AccountEntry], except id: String? = nil) -> AccountEntry? {
        guard !path.isEmpty else { return nil }
        return accounts.first { $0.id != id && !$0.configDir.isEmpty && FolderKey.overlaps($0.configDir, path) }
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

    /// cl_quick's noteAccount, for every profile: the account Claude Code in a profile's folder is signed in to is the
    /// one it works on, whoever signed it in (the Switch page, `claude auth login` in Terminal, another app on the same
    /// folder). When it changes, the profile follows by itself: the new account is in use, the one before joins its
    /// standby accounts (its plan, when it left and its last week remembered, never its sign-in), and nothing else
    /// moves. One account, one profile:
    /// - an account another profile works on (its account in use) is refused: the profile stays as it is, and its numbers
    ///   wait (Reader.swift: the resolver's clash) until its folder is on an account of its own again;
    /// - an account on another profile's standby list moves here: it leaves that list, with a note on both profiles;
    /// - a profile not linked yet takes the account only when no earlier profile not linked yet is signed in to it too.
    /// A folder signed out changes nothing (the account stays the profile's; it signs in again). `status`: the numbers of
    /// the account a profile was on, as last saved (only its own).
    static func noteAccounts(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = { Account.signedInSeat(configDir: $0) },
                             status: (AccountEntry) -> IconStatus? = { Store.lastStatus(of: $0) },
                             now: Date = Date()) -> [AccountEntry] {
        var out = accounts
        for i in out.indices {
            guard var s = signedIn(out[i].configDir) else { continue }
            let old = out[i].seat
            if let old, s.same(old) { continue }
            // another profile works on it: refused
            if out.indices.contains(where: { $0 != i && out[$0].seat.map { s.same($0) } == true }) { continue }
            if old == nil, out.indices.contains(where: { $0 < i && out[$0].seat == nil && s.same(signedIn(out[$0].configDir)) }) { continue }
            // on another profile's standby list: it comes here, said on both
            let email = s.email ?? ""
            for j in out.indices where j != i && out[j].standby.contains(where: { Self.isThat(s, $0) }) {
                out[j].standby.removeAll { Self.isThat(s, $0) }
                out[j].accountNote = AccountNote(kind: .left, email: email, profile: out[i].name, at: now)
                out[i].accountNote = AccountNote(kind: .came, email: email, profile: out[j].name, at: now)
            }
            // it leaves its own standby list
            out[i].standby.removeAll { Self.isThat(s, $0) }
            s.linkedAt = now
            s.was = old?.email
            out[i].seat = s
            // the account it was on stands by: never a sign-in, only what's known of it. One account is on one standby
            // list only: a stale entry for it on another profile's list goes (this profile just had it in use).
            if let old {
                let st = status(accounts[i])
                let oldSeat = Seat(account: old.account, organization: old.organization, email: old.email)
                for j in out.indices where j != i && out[j].standby.contains(where: { Self.isThat(oldSeat, $0) }) {
                    out[j].standby.removeAll { Self.isThat(oldSeat, $0) }
                    out[j].accountNote = AccountNote(kind: .standsBy, email: old.email ?? "", profile: out[i].name, at: now)
                }
                out[i].standby.removeAll { Self.isThat(oldSeat, $0) }
                out[i].standby.append(StandbyAccount(email: old.email ?? "", seat: oldSeat,
                                                     addedAt: now, plan: st?.plan, lastInUse: now, lastWeek: st?.weekly, lastWeekResets: st?.weeklyResets))
            }
        }
        return out
    }

    /// A standby entry for the account signed in: by its seat, or, for one remembered by its address only (from an older
    /// build's Another address…, not signed in yet), by the address (cl_quick's placeholder rule).
    static func isThat(_ s: Seat, _ q: StandbyAccount) -> Bool {
        if let seat = q.seat { return s.same(seat) }
        return s.email.map { $0.lowercased() == q.email.lowercased() } ?? false
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
    /// Quits the Claude desktop apps (their Code-tab sessions end with them).
    static func quitDesktopApps() {
        Processes.claudeApps().forEach { $0.terminate() }
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
            let r = Self.preview ?? Processes.claudeRuns()
            DispatchQueue.main.async {
                if r != self.runs { self.runs = r }
                self.checked = true
            }
        }
    }
}
