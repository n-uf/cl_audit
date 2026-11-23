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

    /// The same folder, or one inside the other ("/" holds every folder).
    static func overlaps(_ a: String, _ b: String) -> Bool {
        let x = canonical(a), y = canonical(b)
        return x == y || x == "/" || y == "/" || x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
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

    /// Another profile that has an account too (`seatSharers`): as its account in use (or, not linked yet, its folder
    /// signed in to it), or on its standby list.
    struct SeatOwner {
        var profile: AccountEntry
        var standby: Bool
    }

    /// Shared seats (operator, 2026-11-22): one account (a seat: account id and organisation) may be in use or standing by
    /// in several profiles; each shows that seat's numbers. Only the same seat twice in one profile is refused, and nothing
    /// a person picks can add one (a profile's accounts come from its own sign-ins and what is found for it): noteAccounts
    /// takes an account off the profile's own standby list as it comes into use, AccountList.adding never adds one a
    /// profile has, and StandbyTidy keeps one entry per seat (an account and organisation).
    /// The other profiles (than `id`) that have this account, in the profiles file's order, each once: in use (else, not
    /// linked yet, its folder signed in to it) or standing by. Compared by the one owner rule (ProfileCore's
    /// AccountIdentity.sameAccount: the ids when both have one, any case; else the address and organisation; one known by
    /// its address only by the address). An address alone (typed) also matches a profile whose account in use has no
    /// address recorded, or that isn't linked yet, by the address its folder's .claude.json names (`recordEmail`, through
    /// ClaudeFiles; also a record with no account id), as the address check always did. Never a refusal: what a page says
    /// of them is `sharedNote`.
    static func seatSharers(_ who: AccountIdentity?, among accounts: [AccountEntry], except id: String? = nil,
                            signedIn: (String) -> Seat? = Account.signedInSeat,
                            recordEmail: (String) -> String? = { Account.expectedEmail(configDir: $0) }) -> [SeatOwner] {
        guard let who else { return [] }
        return accounts.filter { $0.id != id }.compactMap { e -> SeatOwner? in
            if e.seat.map({ who.sameAccount(AccountIdentity($0)) }) == true { return SeatOwner(profile: e, standby: false) }
            if e.seat == nil, signedIn(e.configDir).map({ who.sameAccount(AccountIdentity($0)) }) == true { return SeatOwner(profile: e, standby: false) }
            if who.addressOnly, (e.seat?.email ?? "").isEmpty, who.sameAccount(.address(recordEmail(e.configDir))) { return SeatOwner(profile: e, standby: false) }
            if e.standby.contains(where: { who.sameAccount($0.identity) }) { return SeatOwner(profile: e, standby: true) }
            return nil
        }
    }

    /// The same for a folder's sign-in.
    static func seatSharers(_ seat: Seat?, among accounts: [AccountEntry], except id: String? = nil,
                            signedIn: (String) -> Seat? = Account.signedInSeat) -> [SeatOwner] {
        seatSharers(seat.map { AccountIdentity($0) }, among: accounts, except: id, signedIn: signedIn)
    }

    /// The one amber note a shared account gets wherever it is picked, signed in or shown (never red, never a block), one
    /// thought per line: in use in another profile, "This account is also in use in “Main”.\nBoth profiles show the same
    /// numbers." (several: "All of these profiles show the same numbers."); else on standby there, "This account also
    /// stands by in “Main”.". No address in it: the field or row above shows the address, or its stand-in. nil: no other
    /// profile has it.
    static func sharedNote(_ owners: [SeatOwner]) -> String? {
        let inUse = owners.filter { !$0.standby }, standby = owners.filter(\.standby)
        if !inUse.isEmpty {
            return "This account is also in use in \(names(inUse))." + "\n"
                + (inUse.count == 1 ? "Both profiles show the same numbers." : "All of these profiles show the same numbers.")
        }
        if !standby.isEmpty { return "This account also stands by in \(names(standby))." }
        return nil
    }

    /// “Main”, or “Main” and one other profile, “Main” and 2 other profiles: the first profile's name as the setting names
    /// it (AddressSettings.words: a name that is an address is hidden like one), the rest counted.
    static func names(_ owners: [SeatOwner]) -> String {
        guard let first = owners.first else { return "" }
        let more = owners.count - 1
        return "“\(AddressSettings.words(first.profile.name))”"
            + (more == 0 ? "" : more == 1 ? " and one other profile" : " and \(more) other profiles")
    }


    /// cl_quick's noteAccount, for every profile: the account Claude Code in a profile's folder is signed in to is the
    /// one it works on, whoever signed it in (the Switch page, `claude auth login` in Terminal, another app on the same
    /// folder). When it changes, the profile follows by itself: the new account is in use, the one before joins its
    /// standby accounts (its plan, when it left and its last week remembered, never its sign-in), and nothing else
    /// moves. Shared seats (operator, 2026-11-22): an account may be in use in several profiles, so
    /// - an account another profile works on (its account in use) is taken here too: both show its numbers (the agent
    ///   reads a shared seat once, SharedReads);
    /// - an account on another profile's standby list comes here and leaves that list, with a note on both profiles
    ///   (ProfileCore's StandbyTidy keeps no other profile's account in use on a standby list: Vendor's rule);
    /// - the account it was on stays on any other profile's standby list too (one account may stand by in several).
    /// A folder signed out changes nothing (the account stays the profile's; it signs in again). Every "the same account"
    /// here is the one owner rule (Seat.sameAccount, `isThat`): ids in any case. `status`: the numbers of the account a
    /// profile was on, as last saved (only its own).
    static func noteAccounts(_ accounts: [AccountEntry], signedIn: (String) -> Seat? = { Account.signedInSeat(configDir: $0) },
                             status: (AccountEntry) -> StatusRecord? = { Store.lastStatus(of: $0) },
                             now: Date = Date()) -> [AccountEntry] {
        var out = accounts
        for i in out.indices {
            guard var s = signedIn(out[i].configDir) else { continue }
            let old = out[i].seat
            if let old, s.sameAccount(old) { continue }
            // (another profile works on it too: taken all the same, a shared seat)
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
            // the account it was on stands by: never a sign-in, only what's known of it. Once here (never twice in one
            // profile); another profile's entry for it stays (one account may stand by in several profiles).
            if let old {
                let st = status(accounts[i])
                let oldSeat = Seat(account: old.account, organization: old.organization, email: old.email)
                out[i].standby.removeAll { Self.isThat(oldSeat, $0) }
                out[i].standby.append(StandbyAccount(email: old.email ?? "", seat: oldSeat,
                                                     addedAt: now, plan: st?.plan, lastInUse: now, lastWeek: st?.weekly, lastWeekResets: st?.weeklyResets))
            }
        }
        return out
    }

    /// A standby entry for the account signed in, by the one owner rule: by its seat, or, for one remembered by its address
    /// only (from an older build's Another address…, not signed in yet), by the address (cl_quick's placeholder rule).
    static func isThat(_ s: Seat, _ q: StandbyAccount) -> Bool { AccountIdentity(s).sameAccount(q.identity) }

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
    let folder: String          // data folder (desktop) or Claude Code folder (sessions), with ~; or unknownFolder
    /// A process whose facts, or how it was started, couldn't be read (`Processes.Entry.hidden`): it may be Claude Code or
    /// any other program, on unknownFolder.
    var hidden = false

    /// A Claude Code whose folder couldn't be told (how it was started, or its environment, couldn't be read), or a Claude app
    /// whose arguments couldn't be: it may use any folder, so every folder's check counts it (AccountRemoval.runsUsing).
    static let unknownFolder = "unknown"

    /// Its line in Remove's and Uninstall's "Close Claude first" box.
    var words: String {
        if hidden { return "A process cl_audit can't read (it may be Claude Code)" }
        return (kind == .desktop ? "Claude window" : kind == .codeTab ? "Code tab session" : "Terminal session (type /exit)") + " · " + folder
    }
}

enum ClaudeRuns {
    /// Quits the Claude desktop apps (their Code-tab sessions end with them).
    static func quitDesktopApps() { ClaudeWindow.quitAll() }
}

/// A delete's or set-up's click-time look (Remove, Uninstall, New profile): one at a time, and called off by Cancel, Esc or
/// leaving the page. Its answer acts only while this gate still holds that very look, so a look that lands after a cancel,
/// or a second click's, never deletes or makes a folder.
final class ClickGate: ObservableObject {
    @Published private(set) var token: UUID?

    /// A look is under way (the click's button is disabled meanwhile).
    var busy: Bool { token != nil }

    /// Calls the look under way off: when it lands, its answer does nothing.
    func cancel() { if token != nil { token = nil } }

    /// Starts a look made now through `monitor`; `act` gets its answer (nil: couldn't check) only if this gate still holds
    /// that look when it lands. False, with nothing started, while one is under way already.
    @discardableResult
    func look(_ monitor: RunsMonitor, then act: @escaping ([ClaudeRun]?) -> Void) -> Bool {
        guard token == nil else { return false }
        let t = UUID()
        token = t
        monitor.refresh { [weak self] fresh in
            guard let self, self.token == t else { return }
            self.token = nil
            act(fresh)
        }
        return true
    }
}

/// Watches what's running every 2 s while the new-account page, Remove or Uninstall is open. `checked`: the last look read
/// which Claude runs. `failed`: it couldn't (the process table couldn't be read): `runs` is then empty and nothing may take
/// that for "none runs"; each page refuses to delete or set up a folder and says `failedWords`.
final class RunsMonitor: ObservableObject {
    @Published private(set) var runs: [ClaudeRun] = []
    @Published private(set) var checked = false
    @Published private(set) var failed = false
    private var timer: Timer?
    /// This user's Claude Code folders (the profiles'), for another user's `claude` (Processes.codeRunList).
    private var folders: [String] = []

    static let failedWords = "cl_audit couldn't check which Claude is running"

    func start(folders: [String] = []) {
        self.folders = folders
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Offscreen renders: what counts as running, instead of this Mac's real Claude processes.
    static var preview: [ClaudeRun]? = nil

    /// The look started last: an older look's answer, landing after it, is dropped (`apply`), so a stale "none runs" never
    /// overwrites a newer "couldn't check".
    private var generation = 0

    /// A new look's number (the newest from now on).
    func begin() -> Int { generation += 1; return generation }

    /// Looks again, off the main thread. `done`, on the main thread, gets this look's own answer (nil: couldn't check): what a
    /// delete or set-up decides on when it is clicked, never a look up to 2 s old.
    func refresh(_ done: (([ClaudeRun]?) -> Void)? = nil) {
        let folders = self.folders, g = begin()
        DispatchQueue.global(qos: done == nil ? .utility : .userInitiated).async {
            let r = Self.preview ?? Processes.claudeRuns(folders: folders)
            DispatchQueue.main.async { self.apply(r, generation: g); done?(r) }
        }
    }

    /// One look's answer: nil (it couldn't be checked) leaves nothing listed and `checked` false. With `generation`, only the
    /// newest look's answer is taken.
    func apply(_ r: [ClaudeRun]?, generation g: Int? = nil) {
        if let g, g != generation { return }
        guard let r else {
            if !runs.isEmpty { runs = [] }
            checked = false; failed = true
            return
        }
        if r != runs { runs = r }
        checked = true; failed = false
    }
}
