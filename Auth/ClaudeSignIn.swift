// ClaudeAuth · the sign-in: Claude Code's own `claude auth login` for a profile's ONE folder, opened in a Terminal window,
// followed until it ends one way or another, and its window closed after it. The person signs in in the browser; nothing
// here sees a password or a token.
//
// Built on ClaudeAuth's own parts: the hardened script (SignInScript, Authenticator.startSignIn), the folder's cleaned
// environment (AuthFolder), the record's watch (SignInChangeWatch, RecordStamp), the one answer (FolderSignIn.answer) and the
// matching rule (SignedInAccount.match), the guard (AuthTools.mayLaunch), and Runs' process table (ProcessTable). The app's
// own verified word is a parameter (`Confirm`): cl_audit's Keychain read and Anthropic's reply, cl_quick's short `claude` and
// its `initialize` account. Until that word comes, the folder's record is only a guess.
//
// The rules:
// - One profile, one folder: nothing here makes, moves or redirects a Claude Code folder, and nothing is written into one.
//   A folder the guard refuses (isReady, cl_audit's FolderGuard) starts nothing.
// - One sign-in window per app: starting a sign-in ends the app's earlier one, window and all (also one an earlier run of
//   the app left: its script's pid is in the app's own work folder). Except a window whose shell outlives the wait (it
//   ignores the ask to end): that one is kept as it is, with its profile, and the start is refused (`windowStillOpen`).
// - Two guards against two sign-ins on one folder: any `claude auth login` running on the folder, whoever started it (the
//   process table: its CLAUDE_CONFIG_DIR where the kernel gives its environment, and the ClaudeSignIn script it runs under;
//   one whose folder can't be told counts too, see `isLogin`), and a lock every app takes (`flock` on
//   ~/Library/Caches/n-uf/signin-<8 hex of the folder's real path's SHA-256>.lock), which closes the race between two apps
//   starting at once.
// - The account: the record is a guess until the app's word confirms it. A login still running is never ended on a guess
//   or on two sources that disagree; once it ended, the word is asked again a few times, and a sign-in it never confirms
//   ends `unverified`, never `signedIn`.
// - The window closes on a sign-in, a wrong account, a stop and a timeout. One that was declined or failed stays open to be
//   read, until Return, the next start or a stop.
// - The window: a Terminal settings file (`.terminal`: the command, run inside the login shell with `exec`, and "close if the
//   shell exited cleanly"), opened like any document, which needs no permission to control Terminal. `.scripted` (Terminal's
//   AppleScript, which asks for that permission) is there for a Mac where the settings file doesn't work.
// - Terminal keeps the profile of every settings file it opens in its preferences ("Window Settings"), named after the
//   FILE's base name ("<title> sign-in", then "<title> sign-in 1", 2…), never the plist's `name`. One leftover per sign-in,
//   each with a dead command. `TerminalProfiles` removes the ones whose command runs in this app's own work folder (nothing
//   else can match), never a profile Terminal names as its default or startup one: at every start, and after the window
//   is gone at every end.
//
// No app's screens, words or global state: the folder, the account wanted, the tools, the verified word, the app's work
// folder and the window's title are parameters. One queue for every sign-in of the process (the verified word is asked off
// it, so a stop never waits for it); the callbacks come on the main queue.

import Foundation
import ProfileCore
import Runs

public final class ClaudeSignIn {
    public enum State: Equatable {
        /// The guards passed; the script and the window are being made.
        case opening
        /// Terminal has the sign-in: the person finishes it in the browser.
        case waitingForBrowser
    }

    public enum Failure: Equatable {
        /// The folder isn't there as a plain folder, or the app's guard said no: nothing started, nothing made.
        case folderNotReady
        /// Another sign-in (this app's or another's) holds the folder's sign-in lock.
        case locked
        /// A `claude auth login` already runs on the folder, whoever started it.
        case alreadySigningIn
        /// The app's earlier sign-in window (of any folder: one window per app) is still open: its shell outlived the ask to
        /// end. Nothing started; the window is left as it is.
        case windowStillOpen
        /// The running processes couldn't be read (or one that may be Claude Code couldn't be): nothing started.
        case processesUnreadable
        /// The script or the window couldn't be written or opened, or the script never started (`startGrace`).
        case notOpened
        /// Claude Code's login ended without a sign-in (its exit status).
        case loginFailed(status: Int32)
        /// The login ended well, but the folder names nobody.
        case noAccount
        /// The window was closed before the login ended.
        case windowClosed
    }

    public enum Outcome: Equatable {
        /// The folder is signed in to the account wanted (or to someone, when none was), as the app's word confirmed it.
        case signedIn(SignedInAccount)
        /// Another account signed in (the browser was signed in as someone else), by SignedInAccount.match, as the app's word
        /// confirmed it.
        case wrongAccount(signedIn: SignedInAccount, wanted: SignedInAccount)
        /// The login ended well, but the app's word never confirmed which account it is (it didn't answer, it named another
        /// one than the record, or it named no id where the account wanted is known by its id and the record doesn't agree).
        /// The account is the best guess (the word's, else the record's). Never taken for the account wanted.
        case unverified(SignedInAccount)
        /// The person declined in the browser (Claude Code said so in the window).
        case declined
        case failed(Failure)
        /// `stop()`, or another sign-in of the app started.
        case stopped
        /// Nothing came within the timeout.
        case timedOut
    }

    /// The app's verified word on the folder's account now, or nil when it can't tell. Blocks; called on a queue of its own,
    /// never the sign-in's. cl_audit: its Keychain read and Anthropic's reply (`server`); cl_quick: a short `claude` on the
    /// folder and its `initialize` account (`process`).
    public typealias Confirm = (AuthFolder) -> SignedInAccount?

    /// How the window is opened.
    public enum Window: Equatable {
        /// A Terminal settings file, opened like a document (no permission to control Terminal asked).
        case settingsFile
        /// Terminal's AppleScript: asks for permission to control Terminal the first time.
        case scripted
    }

    /// Where every app takes the folder's sign-in lock.
    public static var sharedLocks: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/n-uf", isDirectory: true)
    }

    public let folder: AuthFolder
    public let wanted: SignedInAccount?
    public let timeout: TimeInterval

    private let auth: Authenticator
    private let claude: String
    private let confirm: Confirm
    private let window: Window
    private let title: String
    private let shown: String?
    private let locks: URL
    private let poll: TimeInterval
    private let work: URL
    private let startGrace: TimeInterval
    private let terminalProfiles: TerminalProfiles
    private let lateSweep: TimeInterval

    // the sign-in's files, all in the app's own work folder (owner only). The script is named after the folder's lock key:
    // its shell's command line then says which folder its `claude auth login` signs in, to any app (`isLogin`).
    var scriptURL: URL { work.appendingPathComponent("sign-in-\(Self.lockKey(folder)).command") }
    /// The settings file is named after the app ("<title> sign-in.terminal"): Terminal keeps the profile under the file's
    /// name, so a leftover is recognisable in its list.
    var settingsURL: URL { work.appendingPathComponent(profileName + ".terminal") }
    var pidURL: URL { work.appendingPathComponent("sign-in.pid") }
    var statusURL: URL { work.appendingPathComponent("sign-in.status") }
    var declinedURL: URL { work.appendingPathComponent("sign-in.declined") }
    var lockURL: URL { locks.appendingPathComponent("signin-\(Self.lockKey(folder)).lock") }

    /// `folder`: the profile's one folder (made by the app beforehand when it is new). `wanted`: the account it should end on
    /// (by id, or by address and organisation), nil for a brand-new folder. `claude`: Claude Code's program. `work`: the app's
    /// own folder for the sign-in's files (never the Claude Code folder). `title`: the window's name. `shown`: the folder as
    /// the script's first line names it. `startGrace`: how long the script may take to start once the window was asked for
    /// (then `failed(.notOpened)`). `title`: the app's name; the window's settings file (and so Terminal's profile) is
    /// "<title> sign-in". `terminalProfiles`: how Terminal's kept profiles are looked at and removed (the real preferences
    /// unless an app or a check gives its own); `lateSweep`: how long after a sign-in ended its profiles are swept once more,
    /// for a window that closed itself after it. `locks`, `poll` (how often the folder is looked at) and `confirmTries` (how
    /// often the word is asked after the login ended) are parameters for the checks.
    public init(folder: AuthFolder, wanted: SignedInAccount?, timeout: TimeInterval = 600, tools: AuthTools, claude: String,
                confirm: @escaping Confirm, work: URL, window: Window = .settingsFile, title: String = "Claude Code",
                shown: String? = nil, startGrace: TimeInterval = 25, terminalProfiles: TerminalProfiles = .system,
                lateSweep: TimeInterval = 6, locks: URL = ClaudeSignIn.sharedLocks, poll: TimeInterval = 2, confirmTries: Int = 3) {
        self.folder = folder; self.wanted = wanted; self.timeout = timeout
        self.claude = claude; self.confirm = confirm; self.work = work; self.window = window; self.title = title
        self.shown = shown; self.startGrace = startGrace; self.locks = locks; self.poll = poll; self.confirmTries = confirmTries
        self.terminalProfiles = terminalProfiles; self.lateSweep = lateSweep
        auth = Authenticator(folder, tools: tools)
    }

    // MARK: the one sign-in of the app

    /// Every sign-in's work, one at a time.
    private static let queue = DispatchQueue(label: "n-uf.claude-auth.sign-in")
    /// The app's sign-in now (or the last one, while its window stays open to be read).
    private static var current: ClaudeSignIn?

    private enum Phase { case idle, running, ended }
    private var phase = Phase.idle
    private var onState: (State) -> Void = { _ in }
    private var onEnd: (Outcome) -> Void = { _ in }
    private var timer: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var started = Date()
    private var watch = SignInChangeWatch()
    private var startAccount: SignedInAccount?
    private var windowID: String?
    /// Whether this sign-in got as far as making its own script (the pid file in the work folder is then its window's).
    private var ownsScript = false
    private let confirmTries: Int
    /// The verified word: being asked (on its own queue), how often after the login ended, and the generation a late answer
    /// is checked against (it moves on every ask and at the end, so an answer for an older ask or a finished sign-in is
    /// dropped).
    private var asking = false
    private var askedAfterEnd = 0
    private var generation = 0
    private static let confirmQueue = DispatchQueue(label: "n-uf.claude-auth.sign-in.confirm", attributes: .concurrent)

    /// Starts it: the app's earlier sign-in ends, the guards are asked, the window opens, and the folder is looked at every
    /// `poll` seconds. `onState` and `onEnd` come on the main queue; `onEnd` once.
    public func start(onState: @escaping (State) -> Void = { _ in }, onEnd: @escaping (Outcome) -> Void) {
        Self.queue.async { self.begin(onState, onEnd) }
    }

    /// Ends it: the `claude auth login` in its window and the window. After a declined or failed sign-in, closes the window
    /// left open to be read. Nothing when it never started.
    public func stop() { Self.queue.async { self.end(.stopped) } }

    /// `stop()`, done before it returns: for an app that is quitting (its main queue won't run `onEnd`). Blocks for as long
    /// as ending the login takes (a few seconds at most); never waits for the verified word.
    public func stopNow() { Self.queue.sync { self.end(.stopped) } }

    private func end(_ outcome: Outcome) {
        switch phase {
        case .idle: return
        case .running: finish(outcome)
        case .ended:                                                       // a window left open to be read
            endScript(shell: true)
            if !windowIsOpen { sweepProfiles(late: true) }                 // swept only once it is gone (a shell that outlived the wait keeps its profile)
        }
    }

    private func begin(_ onState: @escaping (State) -> Void, _ onEnd: @escaping (Outcome) -> Void) {
        guard phase == .idle else { return }
        phase = .running
        self.onState = onState; self.onEnd = onEnd
        // one window per app: the earlier sign-in ends, and whatever an earlier run of the app left in its work folder
        var ended = false                                                  // the earlier sign-in of this work folder already ended its script
        if let earlier = Self.current, earlier !== self { earlier.end(.stopped); ended = earlier.work.standardizedFileURL.path == work.standardizedFileURL.path }
        Self.current = self
        if !ended { endScript(shell: true) }
        // a shell that outlived the wait (it ignored the TERM) is a window still open: its pid file stays its only handle (no
        // sweep, no second window: one per app), and nothing is started on top of it
        if Self.scriptRuns(in: work) { return finish(.failed(.windowStillOpen)) }
        sweepProfiles()                                                    // what earlier runs left in Terminal's preferences
        guard auth.tools.mayLaunch("login", folder) else { return finish(.failed(.folderNotReady)) }
        guard takeLock() else { return finish(.failed(.locked)) }
        switch loginRuns() {
        case nil: return finish(.failed(.processesUnreadable))
        case true?: return finish(.failed(.alreadySigningIn))
        case false?: break
        }
        emit(.opening)
        guard makeWork() else { return finish(.failed(.notOpened)) }
        for u in [statusURL, declinedURL, pidURL, settingsURL, scriptURL] { try? FileManager.default.removeItem(at: u) }
        started = Date()
        ownsScript = true                                                  // from here the script, its window and the pid file are this sign-in's
        _ = watch.look(stamp: auth.recordStamp()) { auth.record() }
        startAccount = watch.seen
        var tools = auth.tools
        tools.openTerminal = { [self] in openWindow($0) }
        let watched = SignInScript.Watch(pid: pidURL, status: statusURL, declined: declinedURL)
        switch Authenticator(folder, tools: tools).startSignIn(claude: claude, email: wanted?.email, script: scriptURL,
                                                               removesItself: true, shown: shown, watch: watched) {
        case .done: break
        case .folderNotReady: return finish(.failed(.folderNotReady))
        case .otherAccount, .failed: return finish(.failed(.notOpened))
        }
        emit(.waitingForBrowser)
        let t = DispatchSource.makeTimerSource(queue: Self.queue)
        t.schedule(deadline: .now() + poll, repeating: poll)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: following it

    private func tick() {
        guard phase == .running else { return }
        if Date().timeIntervalSince(started) >= timeout { return finish(.timedOut) }
        if FileManager.default.fileExists(atPath: declinedURL.path) { return finish(.declined) }
        let status = loginStatus()
        if let s = status, s != 0 { return finish(.failed(.loginFailed(status: s))) }
        // the script never started (Terminal didn't open it): it won't now either (finish removes it)
        if !FileManager.default.fileExists(atPath: pidURL.path), status == nil, Date().timeIntervalSince(started) >= startGrace {
            return finish(.failed(.notOpened))
        }
        let changed = watch.look(stamp: auth.recordStamp()) { auth.record() } || (startAccount == nil && watch.seen != nil)
        if status == 0 || changed { return ask() }
        // the window closed while the login ran (Terminal hung its shell up: it ended cleanly, before writing a status)
        if let pid = scriptPid(), !ProcessTable.runs(pid), loginStatus() == nil, !FileManager.default.fileExists(atPath: declinedURL.path) {
            finish(.failed(.windowClosed))
        }
    }

    /// Asks the app's word, on its own queue (a stop or the next start never waits for it); its answer comes back here.
    private func ask() {
        guard !asking else { return }
        asking = true
        generation += 1
        let g = generation, confirm = self.confirm, folder = self.folder
        Self.confirmQueue.async { [weak self] in
            let word = confirm(folder)
            Self.queue.async { self?.answered(word, generation: g) }
        }
    }

    /// The word came: the folder's account now, by the word over the record, against the account wanted.
    private func answered(_ word: SignedInAccount?, generation g: Int) {
        guard phase == .running, g == generation else { return }
        asking = false
        let loginEnded = loginStatus() == 0
        let record = auth.record()
        let answer = FolderSignIn.answer(record: record, verified: word)
        let judged = Self.judge(answer, wanted: wanted, record: record)
        guard loginEnded else {
            // a login still running is never ended on a guess, nor on two sources that disagree (Claude Code writes the
            // record before its sign-in): only on the word and the record agreeing on another account than the one wanted
            if case .wrong(let a) = judged, answer.verdict == .verified, answer.record != nil, let wanted {
                finish(.wrongAccount(signedIn: a, wanted: wanted))
            }
            return
        }
        askedAfterEnd += 1
        switch judged {
        case .match(let a): finish(.signedIn(a))
        case .wrong(let a): finish(.wrongAccount(signedIn: a, wanted: wanted!))
        case .unsure(let a):
            if askedAfterEnd < confirmTries { return ask() }              // the word, or the record, may still catch up
            if let a { finish(.unverified(a)) } else { finish(.failed(.noAccount)) }
        }
    }

    enum Judged: Equatable {
        /// The word confirms the account wanted (or someone, when none was wanted).
        case match(SignedInAccount)
        /// The word confirms another account.
        case wrong(SignedInAccount)
        /// Not confirmed: no word, the word and the record disagree, or the account wanted is known by its id and neither
        /// the word nor a record agreeing with it names one. The best guess, if any.
        case unsure(SignedInAccount?)
    }

    /// One answer judged against the account wanted. An account wanted with no organisation named (an app that keeps
    /// accounts by their id or address only) is compared without the organisation: none named there isn't "no organisation".
    /// An account wanted by its id is compared by ids only: a word that names no id (a running claude's) takes the record's,
    /// and only when the record is the same seat or address as the word.
    static func judge(_ answer: FolderSignIn, wanted: SignedInAccount?, record: SignedInAccount?) -> Judged {
        guard answer.verdict == .verified, var account = answer.account else { return .unsure(answer.account ?? record) }
        guard let wanted else { return .match(account) }
        if wanted.organizationID == nil && wanted.organizationName == nil { account.organizationID = nil; account.organizationName = nil }
        if wanted.accountID != nil && account.accountID == nil {
            guard let r = record, r.accountID != nil, r.match(answer.account!) != .different else { return .unsure(answer.account) }
            account.accountID = r.accountID
            if account.organizationID == nil && (wanted.organizationID != nil) { account.organizationID = r.organizationID }
        }
        var signedIn = answer.account!
        if signedIn.accountID == nil { signedIn.accountID = account.accountID }
        return account.match(wanted) != .different ? .match(signedIn) : .wrong(signedIn)
    }

    private func finish(_ outcome: Outcome) {
        guard phase == .running else { return }
        phase = .ended
        generation += 1                                                    // a word still on its way is dropped
        timer?.cancel(); timer = nil
        // a start refused before it made its own script has no window to end: the pid file is an earlier window's, whose
        // shell and login are none of its business (a later stop ends that window: `end` on the sign-in that has it)
        if ownsScript {
            switch outcome {
            case .signedIn, .wrongAccount, .unverified, .stopped, .timedOut: endScript(shell: true)
            // left open to be read: only the login ends (one still waiting after a decline), the script then holds its window
            case .declined, .failed: endScript(shell: false)
            }
        }
        releaseLock()
        for u in [statusURL, declinedURL, settingsURL, scriptURL] { try? FileManager.default.removeItem(at: u) }
        // Terminal's kept profile goes once the window is gone; a window left open to be read keeps it until it is closed
        // (a stop, the next start)
        if !windowIsOpen { sweepProfiles(late: true) }
        let done = onEnd
        DispatchQueue.main.async { done(outcome) }
    }

    private func emit(_ s: State) {
        let f = onState
        DispatchQueue.main.async { f(s) }
    }

    /// The login's exit status, once its script wrote it.
    private func loginStatus() -> Int32? {
        (try? String(contentsOf: statusURL, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    // MARK: the guards

    /// The lock's name: the first 8 hex characters of the SHA-256 of the folder's real path (links resolved).
    public static func lockKey(_ folder: AuthFolder) -> String {
        AuthFolder.sha8(URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().path)
    }

    private func takeLock() -> Bool {
        guard (try? FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)) != nil else { return false }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        lockFD = fd
        return true
    }

    private func releaseLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1
    }

    /// A `claude auth login` running on this folder, whoever started it, or one whose folder can't be told (refused rather
    /// than guessed); nil when the processes can't be read.
    func loginRuns() -> Bool? {
        guard let all = ProcessTable.settledTable(), !all.contains(where: \.hidden) else { return nil }
        let me = getuid()
        return all.contains { $0.uid == me && isLogin($0, in: all) != false }
    }

    /// Whether a process is Claude Code's `claude auth login` on this folder: true, false (not a login, or another folder's),
    /// or nil (a login whose folder can't be told: refused like one on this folder). Two signals, failing closed:
    /// - its CLAUDE_CONFIG_DIR, where the kernel gives the process's environment (it does for Claude Code's own program; it
    ///   doesn't for Apple's platform binaries, such as a shell a stand-in runs in): unset is the default folder, an absolute
    ///   path is compared as a folder, anything else (empty, relative, ~) can't be told;
    /// - the ClaudeSignIn script it runs under (`sign-in-<lock key>.command`, any app's), among its parents.
    /// Either one naming this folder is enough; neither one at all, or an environment that can't be told, is nil.
    func isLogin(_ e: ProcessTable.Entry, in table: [ProcessTable.Entry]) -> Bool? {
        guard let l = e.launch, ProcessTable.isClaudeCode(l),
              zip(l.args, l.args.dropFirst()).contains(where: { $0 == "auth" && $1 == "login" }) else { return false }
        let here = AuthFolder.canonical(folder.path, home: folder.home)
        var byEnvironment: Bool?, undecidable = false
        if l.environmentRead {
            if let dir = l.configDir {
                if dir.hasPrefix("/") { byEnvironment = AuthFolder.canonical(dir, home: folder.home) == here } else { undecidable = true }
            } else {
                byEnvironment = AuthFolder.canonical(folder.home + "/.claude", home: folder.home) == here
            }
        }
        let byScript = scriptFolder(above: e, in: table)
        if byEnvironment == true || byScript == true { return true }
        if undecidable { return nil }
        if byEnvironment == false || byScript == false { return false }
        return nil
    }

    /// The ClaudeSignIn script a process runs under (its parents, a few up): true when it is this folder's, false another
    /// folder's, nil when there is none.
    private func scriptFolder(above e: ProcessTable.Entry, in table: [ProcessTable.Entry]) -> Bool? {
        var parent = e.ppid, hops = 0
        while let p = parent, p > 1, hops < 4, let up = table.first(where: { $0.pid == p }) {
            for a in up.launch?.args ?? [] {
                let name = (a as NSString).lastPathComponent
                guard name.hasPrefix("sign-in-"), name.hasSuffix(".command"), name.count == "sign-in-".count + 8 + ".command".count else { continue }
                return name == scriptURL.lastPathComponent
            }
            parent = up.ppid; hops += 1
        }
        return nil
    }

    /// A shell running one of this app's sign-in scripts (any folder's).
    private func isOwnScript(_ l: ProcessTable.Launch) -> Bool {
        l.args.contains { $0.hasPrefix(work.path + "/sign-in-") && $0.hasSuffix(".command") }
    }

    // MARK: the window

    /// The work folder: made owner only, or one already there made owner only; never a link.
    private func makeWork() -> Bool {
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])) != nil else { return false }
        var st = stat()
        guard lstat(work.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        return (st.st_mode & 0o777) == 0o700 || chmod(work.path, 0o700) == 0
    }

    /// What the window runs: the script, in place of the login shell Terminal starts (so its clean end is the shell's).
    var command: String { "exec " + SignInScript.q(scriptURL.path) }

    /// The settings file's base name, "<title> sign-in". Terminal names the profile it keeps after the FILE's base name (not
    /// the plist's `name`), adding " 1", " 2"… to a name it already holds.
    public var profileName: String { title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + " sign-in" }

    /// The Terminal settings file: the command run inside the login shell, and the window closed when the shell exits cleanly
    /// (Terminal's `shellExitAction` 1, "Close if the shell exited cleanly"; `RunCommandAsShell` false is "Run inside shell").
    /// Terminal opens the command this file holds each time (a profile it kept from an earlier file never runs an older
    /// command), and keeps the profile in its preferences: `sweepProfiles` removes it.
    func settings() -> Data? {
        let plist: [String: Any] = ["type": "Window Settings", "name": profileName, "ProfileCurrentVersion": 2.09,
                                    "CommandString": command, "RunCommandAsShell": false, "shellExitAction": 1]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// The AppleScript of the `.scripted` window: it opens the command in a new window and says that window's id.
    var openScript: String {
        let c = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"Terminal\"\nset t to do script \"\(c)\"\nreturn id of (first window whose tabs contains t)\nend tell"
    }

    static func closeScript(_ id: String) -> String {
        "tell application \"Terminal\" to close (every window whose id is \(Int(id) ?? -1))"
    }

    private func openWindow(_ script: URL) -> Bool {
        switch window {
        case .settingsFile:
            guard let data = settings(), SignInScript.write(data, to: settingsURL) else { return false }
            return auth.tools.openTerminal(settingsURL)
        case .scripted:
            guard let r = Runner.run(Program("/usr/bin/osascript", ["-e", openScript], timeout: 30, keepOutput: true)), r.ok else { return false }
            windowID = String(decoding: r.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return true
        }
    }

    // MARK: ending it

    /// The script's shell, from the pid it wrote: only while that pid still runs this script.
    private func scriptPid() -> pid_t? {
        guard let s = try? String(contentsOf: pidURL, encoding: .utf8), let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid
    }

    /// Ends the login running in the script's window (and what it started), and the script itself when `shell`: asked first
    /// (SIGTERM; the script ends cleanly and its window closes), killed after 3 seconds (never the script's shell, whose
    /// unclean end would leave its window open). Only processes of this app's own script, found by the pid it wrote and
    /// checked by its command line; nothing else is signalled.
    private func endScript(shell: Bool) {
        guard let pid = scriptPid() else { return }
        guard let l = ProcessTable.launch(of: pid), isOwnScript(l), ProcessTable.runs(pid) else {
            try? FileManager.default.removeItem(at: pidURL)
            closeWindow()
            return
        }
        let under = Self.descendants(of: pid, in: ProcessTable.table() ?? [])
        if shell { kill(pid, SIGTERM) }
        for p in under { kill(p, SIGTERM) }
        let gone = { under.allSatisfy { !ProcessTable.runs($0) } && (!shell || !ProcessTable.runs(pid)) }
        let until = Date().addingTimeInterval(3)
        while !gone() && Date() < until { usleep(20_000) }
        if !gone() {
            for p in under where ProcessTable.runs(p) { kill(p, SIGKILL) }
            let more = Date().addingTimeInterval(1)
            while !gone() && Date() < more { usleep(20_000) }
        }
        if shell, !ProcessTable.runs(pid) {
            try? FileManager.default.removeItem(at: pidURL)
            closeWindow()
        }
    }

    /// Terminal's kept profiles whose command runs in this app's work folder go (`TerminalProfiles`). `late`: once more after
    /// `lateSweep` seconds, for a window that closed itself after the script ended (not while the app's next sign-in runs: its
    /// profile is in use). Only for the settings-file window: `.scripted` leaves no profile.
    private func sweepProfiles(late: Bool = false) {
        guard window == .settingsFile else { return }
        let work = self.work.path, profiles = terminalProfiles
        profiles.remove(commandsRunningIn: work)
        guard late, lateSweep > 0 else { return }
        Self.queue.asyncAfter(deadline: .now() + lateSweep) {
            if Self.current?.windowIsOpen == true { return }
            profiles.remove(commandsRunningIn: work)
        }
    }

    /// Sweeps Terminal's kept profiles of the sign-ins in `work`, with no sign-in of the caller's in hand: for an app that is
    /// starting (what earlier runs left) or quitting (a declined or failed window left open and closed by hand since, which
    /// no later sign-in would sweep). Nothing while a sign-in of this process runs or its window is still open, nor while a
    /// script of `work` runs from an earlier run of the app (that window's profile is in use). Blocks on the sign-in queue
    /// (an app calls it off the main thread at its start). It doesn't know which window kind the app's sign-ins use: an app
    /// whose sign-ins are `.scripted` leaves no profile, so there is nothing for it to find (the instance's sweep says so
    /// itself and does nothing for that window).
    public static func sweep(work: URL, terminalProfiles: TerminalProfiles = .system) {
        queue.sync {
            if current?.windowIsOpen == true || scriptRuns(in: work) { return }
            terminalProfiles.remove(commandsRunningIn: work.path)
        }
    }

    /// A sign-in script of `work` (any app run's, any folder's) still runs: the pid in the work folder's `sign-in.pid` is
    /// alive and its command line names `<work>/sign-in-<key>.command`. Its window is open and its profile in use. The one
    /// test for a window no sign-in of this process holds (at start-up, or an earlier run's).
    private static func scriptRuns(in work: URL) -> Bool {
        guard let s = try? String(contentsOf: work.appendingPathComponent("sign-in.pid"), encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0, ProcessTable.runs(pid),
              let l = ProcessTable.launch(of: pid) else { return false }
        return l.args.contains { $0.hasPrefix(work.path + "/sign-in-") && $0.hasSuffix(".command") }
    }

    /// The sign-in is under way, or its script still runs in a window left open to be read: its profile is in use.
    private var windowIsOpen: Bool { phase == .running || (scriptPid().map { ProcessTable.runs($0) } ?? false) }

    /// The `.scripted` window, once its shell has ended (a settings-file window closes by itself).
    private func closeWindow() {
        guard window == .scripted, let id = windowID else { return }
        windowID = nil
        _ = Runner.run(Program("/usr/bin/osascript", ["-e", Self.closeScript(id)], timeout: 30))
    }

    /// Every process under `pid` in the table, by their parents.
    static func descendants(of pid: pid_t, in table: [ProcessTable.Entry]) -> [pid_t] {
        var out: [pid_t] = [], next = [pid]
        while let p = next.popLast() {
            for e in table where e.ppid == p && e.pid != p && !out.contains(e.pid) { out.append(e.pid); next.append(e.pid) }
        }
        return out
    }
}

/// Terminal's kept window profiles, in its preferences (`com.apple.Terminal`: "Window Settings", a dictionary of profiles by
/// name; "Default Window Settings" and "Startup Window Settings" name the profiles Terminal opens by default and at launch).
/// Terminal keeps the profile of every settings file it opens, under the file's base name, with the file's command: one
/// leftover per sign-in. `remove(commandsRunningIn:)` takes out the ones whose command runs in a folder only the app's
/// sign-ins use, and nothing else. Read and write are the only parts that touch the preferences, so an app or a check can
/// hand in its own (a check must never write this Mac's Terminal preferences).
public struct TerminalProfiles {
    /// The profiles by name, and the names Terminal's default and startup settings point at; nil when unreadable.
    public var read: () -> (profiles: [String: Any], inUse: Set<String>)?
    /// Sets "Window Settings" to these profiles.
    public var write: ([String: Any]) -> Void

    public init(read: @escaping () -> (profiles: [String: Any], inUse: Set<String>)?, write: @escaping ([String: Any]) -> Void) {
        self.read = read; self.write = write
    }

    /// Whether a profile's `CommandString` is exactly what `ClaudeSignIn.command` writes for a script in `folder`:
    /// `exec ` + the quoted path `<folder>/sign-in-<8 hex>.command`, nothing before or after it (so a command that merely
    /// mentions the folder, or runs something else in it, never matches).
    static func isSignInCommand(_ command: String, in folder: String) -> Bool {
        let head = "exec " + String(SignInScript.q(folder + "/sign-in-").dropLast()), tail = ".command'"
        guard command.hasPrefix(head), command.hasSuffix(tail), command.count == head.count + 8 + tail.count else { return false }
        return command.dropFirst(head.count).prefix(8).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// Removes every profile whose `CommandString` is the sign-in script of `folder` (`isSignInCommand`; an earlier run's
    /// leftovers have the same shape), unless Terminal's default or startup profile is that one. A folder that isn't absolute
    /// or has fewer than 3 path components is refused (nothing removed). The profiles are read again just before the write
    /// and only the chosen names whose command still matches are taken out of that fresh copy (Terminal writes its own
    /// preferences too). Nothing is written when none matches. Returns the names removed.
    @discardableResult
    public func remove(commandsRunningIn folder: String) -> [String] {
        guard folder.hasPrefix("/"), folder.split(separator: "/").count >= 3, let now = read() else { return [] }
        func matches(_ profile: Any?) -> Bool {
            guard let command = (profile as? [String: Any])?["CommandString"] as? String else { return false }
            return Self.isSignInCommand(command, in: folder)
        }
        let chosen = now.profiles.filter { !now.inUse.contains($0.key) && matches($0.value) }.map(\.key)
        guard !chosen.isEmpty, let fresh = read() else { return [] }
        let gone = chosen.filter { !fresh.inUse.contains($0) && matches(fresh.profiles[$0]) }.sorted()
        guard !gone.isEmpty else { return [] }
        var kept = fresh.profiles
        for name in gone { kept[name] = nil }
        write(kept)
        return gone
    }

    /// The real preferences, through the preferences system (never the file).
    public static let system = TerminalProfiles(
        read: {
            guard let d = UserDefaults(suiteName: "com.apple.Terminal"), let all = d.dictionary(forKey: "Window Settings") else { return nil }
            let inUse = ["Default Window Settings", "Startup Window Settings"].compactMap { d.string(forKey: $0) }
            return (all, Set(inUse))
        },
        write: { UserDefaults(suiteName: "com.apple.Terminal")?.set($0, forKey: "Window Settings") })
}
