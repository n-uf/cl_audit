// ClaudeSignIn's checks (Checks/run.sh claudesignin): ClaudeAuth's ClaudeSignIn (Auth/ClaudeSignIn.swift), compiled against
// ClaudeAuth, Runs and ProfileCore only (no app sources), ported from cl_quick's Checks/signin. No real Terminal: a stand-in
// opens the window's settings file and runs its command with /bin/sh, as Terminal's login shell would, with an input that
// stays open (a window nobody types in). No real `claude`: Checks/claudesignin/bin/claude is a stand-in `claude auth login`.
// No real Terminal preferences: every ClaudeSignIn here is handed an in-memory stand-in (run.sh lints that). No Keychain:
// the tools carry no stored sign-in reader. Folders, work folders and locks are under HOME (Checks/.work/claudesignin/home,
// which run.sh sets and guards); sample addresses (example.com) only; nothing is read from or written to this Mac's own
// folders, and only processes this run started are signalled, by their pids.

import Foundation
import ClaudeAuth
import Runs

setbuf(stdout, nil)
guard NSHomeDirectory().hasSuffix("/Checks/.work/claudesignin/home") else { print("refusing: HOME is \(NSHomeDirectory())"); exit(2) }

var failed = 0, passed = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1 } else { failed += 1; print("FAIL \(name) \(detail())") }
}
@discardableResult
func spin(until done: () -> Bool, max: TimeInterval = 15) -> Bool {
    let end = Date().addingTimeInterval(max)
    while !done(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    return done()
}
func spin(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

let env = ProcessInfo.processInfo.environment
let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("signin-work")   // under the guarded home only
let claude = env["CL_SIGNIN_CLAUDE"] ?? ""
let fm = FileManager.default
try? fm.removeItem(at: base)
try? fm.createDirectory(at: base, withIntermediateDirectories: true)
let home = base.appendingPathComponent("home")            // the folders' home: never this Mac's own
let zdot = base.appendingPathComponent("zdot")            // the login shell's own settings: none
let locks = base.appendingPathComponent("locks")
for d in [home, zdot] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
func pidAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

// ── the stand-in Terminal preferences ──────────────────────────────────────────────────────────────
/// What Terminal keeps in its preferences ("Window Settings", and the names its default and startup settings point at), in
/// memory: this Mac's Terminal preferences are never read or written. Like Terminal, `keep` stores the profile of a settings
/// file it opens under the FILE's base name (not the plist's `name`), " 1", " 2"… added to a name it already holds.
final class FakePrefs {
    private let lock = NSLock()
    private var profiles: [String: Any] = [:]
    private var inUse: Set<String> = []
    private(set) var reads = 0, writes = 0
    var readable = true

    var tool: TerminalProfiles {
        TerminalProfiles(read: { [self] in
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return readable ? (profiles, inUse) : nil
        }, write: { [self] in
            lock.lock(); defer { lock.unlock() }
            writes += 1
            profiles = $0
        })
    }
    func put(_ name: String, command: String, inUse use: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        profiles[name] = ["type": "Window Settings", "name": name, "CommandString": command]
        if use { inUse.insert(name) }
    }
    func keep(file: URL, plist: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        let base = file.deletingPathExtension().lastPathComponent
        var name = base, n = 0
        while profiles[name] != nil { n += 1; name = "\(base) \(n)" }
        profiles[name] = plist
    }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return profiles.keys.sorted() }
    func command(_ name: String) -> String? { lock.lock(); defer { lock.unlock() }; return (profiles[name] as? [String: Any])?["CommandString"] as? String }
    /// The profiles whose command runs in a work folder, but for the ones Terminal's default or startup settings name.
    func left(in work: URL) -> [String] {
        lock.lock(); let pinned = inUse; lock.unlock()
        return names.filter { !pinned.contains($0) && command($0)?.contains(work.path + "/") == true }
    }
    func reset() { lock.lock(); profiles = [:]; inUse = []; reads = 0; writes = 0; readable = true; lock.unlock() }
}
let prefs = FakePrefs()

// ── the stand-in Terminal ──────────────────────────────────────────────────────────────────────────
/// Opens a sign-in's window: reads the settings file Terminal would get and runs its command the way Terminal's login shell
/// runs a command inside it (`/bin/sh -c`); its input stays open, like a window nobody types in. The shell's exit status is
/// what Terminal would close the window on ("Close if the shell exited cleanly": 0). It keeps the profile in `prefs`, as
/// Terminal does.
final class FakeTerminal {
    private let lock = NSLock()
    private(set) var opened: [URL] = []
    private(set) var shells: [Process] = []
    private var inputs: [Pipe] = []
    var settings: [String: Any] = [:]
    let conf: URL
    /// Says it opened the file, but never runs it (a Terminal that never started the script).
    var neverStarts = false
    /// Runs this shell body in place of the script's command (it gets the script's path, so the shell's command line names it):
    /// a window whose shell the check shapes (one that ignores TERM). Nothing is passed to it but that path. Made when the
    /// window opens (the sign-in's own file names are known by then).
    var shellBody: (() -> String)?
    init(conf: URL) { self.conf = conf }

    func open(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        opened.append(url)
        if let d = try? Data(contentsOf: url), let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] {
            prefs.keep(file: url, plist: p)
        }
        if neverStarts { return true }
        guard let d = try? Data(contentsOf: url),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
              let cmd = p["CommandString"] as? String else { return false }
        settings = p
        let sh = Process(), input = Pipe()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let body = shellBody?() {
            // the command is "exec '<script>'": the script's path is what a window's shell carries in its command line
            let path = cmd.hasPrefix("exec '") && cmd.hasSuffix("'") ? String(cmd.dropFirst(6).dropLast()) : cmd
            sh.arguments = ["-c", body, "stand-in", path]
        } else {
            sh.arguments = ["-c", cmd]
        }
        sh.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path, "ZDOTDIR": zdot.path, "TERM": "dumb",
                          "CL_LOGIN_CONF": conf.path, "ANTHROPIC_API_KEY": "made-up-key"]
        sh.standardInput = input
        sh.standardOutput = FileHandle.nullDevice; sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return false }
        inputs.append(input); shells.append(sh)
        return true
    }
    var last: Process? { lock.lock(); defer { lock.unlock() }; return shells.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return opened.count }
}

// ── one case: a folder, its stand-in login's settings, a terminal, a sign-in ─────────────────────────
final class Case {
    let name: String
    let folder: URL
    let work: URL
    let conf: URL
    let terminal: FakeTerminal
    var outcome: ClaudeSignIn.Outcome?
    var states: [ClaudeSignIn.State] = []
    var signIn: ClaudeSignIn!

    init(_ name: String, login: [String: String], make: Bool = true) {
        self.name = name
        folder = home.appendingPathComponent(".claude-\(name)")
        work = base.appendingPathComponent("work")                       // one work folder: the app's own (one per app)
        conf = base.appendingPathComponent("conf-\(name)")
        terminal = FakeTerminal(conf: conf)
        if make { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try? login.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").appending("\n").write(to: conf, atomically: true, encoding: .utf8)
    }

    var authFolder: AuthFolder { AuthFolder(path: folder.path, isDefault: false, home: home.path) }

    func tools() -> AuthTools {
        var t = AuthTools.system
        t.run = { _ in fatalError("no claude run is asked in a sign-in") }
        t.openTerminal = { [terminal] in terminal.open($0) }
        t.environment = { ["PATH": "/usr/bin:/bin"] }
        return t
    }

    @discardableResult
    func start(wanted: SignedInAccount?, timeout: TimeInterval = 20, startGrace: TimeInterval = 10, lateSweep: TimeInterval = 0.3,
               processTable: (() -> [ProcessTable.Entry]?)? = nil,
               confirm: @escaping ClaudeSignIn.Confirm = { _ in nil }) -> ClaudeSignIn {
        signIn = ClaudeSignIn(folder: authFolder, wanted: wanted, timeout: timeout, tools: tools(), claude: claude, confirm: confirm,
                              work: work, title: "Sample app", startGrace: startGrace, terminalProfiles: prefs.tool, lateSweep: lateSweep,
                              locks: locks, poll: 0.2, processTable: processTable ?? { ProcessTable.settledTable() })
        signIn.start(onState: { [weak self] in self?.states.append($0) }, onEnd: { [weak self] in self?.outcome = $0 })
        return signIn
    }

    /// A stand-in word that answers only once the login has ended (the script wrote its status 0; up to 5 s, polled every 20 ms;
    /// the word is asked on its own queue): every ask it counts is then after the end, which is the asks the product counts.
    func afterEnd(_ answer: @escaping ClaudeSignIn.Confirm) -> ClaudeSignIn.Confirm {
        return { [self] folder in
            let status = signIn.statusURL
            let until = Date().addingTimeInterval(5)
            while Date() < until {
                if let s = try? String(contentsOf: status, encoding: .utf8), Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 { break }
                usleep(20_000)
            }
            return answer(folder)
        }
    }

    @discardableResult
    func waitEnd(_ max: TimeInterval = 15) -> ClaudeSignIn.Outcome? { spin(until: { outcome != nil }, max: max); return outcome }
    /// The stand-in login's pid, once it wrote it.
    var loginPid: pid_t { (try? String(contentsOf: URL(fileURLWithPath: conf.path + ".pid"), encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1 }
    func waitLogin() -> pid_t { spin(until: { pidAlive(loginPid) }, max: 10); return loginPid }
    /// The window's shell ended, and how: 0 is clean (Terminal closes the window).
    func shellEnded(_ max: TimeInterval = 8) -> Int32? {
        guard let s = terminal.last else { return nil }
        spin(until: { !s.isRunning }, max: max)
        return s.isRunning ? nil : s.terminationStatus
    }
    var shellRunning: Bool { terminal.last?.isRunning == true }
    /// Stops it, and waits for its window's shell to be gone before the next case starts: a stop that comes right after the
    /// window was asked for may come before the script wrote its pid (a slow Terminal, or a slow runner), and the sign-in
    /// ends that script once it shows only while it is still the app's last one. Left running, its login would be another
    /// case's leftover (one whose parent is gone, whose folder the process guard can't tell where the kernel gives no
    /// environment).
    func stopAndSettle() {
        signIn.stop(); waitEnd()
        _ = shellEnded(15)
    }
    func record(_ email: String, _ id: String, org: String = uuid(51), orgName: String = "Sample Org") {
        let j = #"{"oauthAccount":{"accountUuid":"\#(id)","emailAddress":"\#(email)","organizationUuid":"\#(org)","organizationName":"\#(orgName)"}}"#
        try? j.write(to: folder.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
    }
    func cleanUp() {
        if let s = terminal.last, s.isRunning { kill(s.processIdentifier, SIGKILL) }
        if pidAlive(loginPid) { kill(loginPid, SIGKILL) }
    }
}
/// A running claude's word, as SignedInAccount.process makes it from its `initialize` answer.
func said(_ email: String, _ org: String = "Sample Org") -> ClaudeSignIn.Confirm { { _ in SignedInAccount.process(["email": email, "organization": org]) } }
func wantedID(_ id: String) -> SignedInAccount { SignedInAccount(accountID: id, origin: .record) }

check("the stand-in claude is there", fm.isExecutableFile(atPath: claude), claude)

// ── the window: its settings file and its script ─────────────────────────────────────────────────────
do {
    // the app's work folder already there, open to others: it is made owner only
    try? fm.createDirectory(at: base.appendingPathComponent("work"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    let c = Case("window", login: ["login": "hang"])
    // Terminal's preferences hold what earlier sign-ins left (a stale command each), and profiles that aren't this app's
    let workPath = c.work.path
    prefs.reset()
    prefs.put("Sample app sign-in", command: "exec '\(workPath)/sign-in-aaaaaaaa.command'")
    prefs.put("Sample app sign-in 1", command: "exec '\(workPath)/sign-in-bbbbbbbb.command'")
    prefs.put("Basic", command: "/bin/zsh -l")
    prefs.put("Other app sign-in", command: "exec '\(base.path)/other-work/sign-in-cccccccc.command'")
    prefs.put("Lookalike", command: "exec '\(workPath)-2/sign-in-dddddddd.command'")
    prefs.put("Pinned", command: "exec '\(workPath)/sign-in-eeeeeeee.command'", inUse: true)
    let s = c.start(wanted: SignedInAccount(email: "o'neil@example.com", origin: .record))
    spin(until: { c.states.contains(.waitingForBrowser) })
    let p = c.terminal.settings
    check("profiles: the start swept the leftovers of earlier sign-ins (this app's work folder, never Terminal's default profile)",
          prefs.names == ["Basic", "Lookalike", "Other app sign-in", "Pinned", "Sample app sign-in"], "\(prefs.names)")
    check("profiles: …Terminal kept this sign-in's own profile, named after the settings file", prefs.command("Sample app sign-in")?.contains(workPath + "/sign-in-") == true
          && prefs.command("Sample app sign-in")?.contains("aaaaaaaa") == false, "\(String(describing: prefs.command("Sample app sign-in")))")
    check("window: a Terminal settings file is opened (no AppleScript)", c.terminal.opened.last?.pathExtension == "terminal", "\(c.terminal.opened)")
    check("window: the file is named after the app (\"<title> sign-in.terminal\")", c.terminal.opened.last?.lastPathComponent == "Sample app sign-in.terminal", "\(c.terminal.opened)")
    check("window: Window Settings, closed when the shell exits cleanly (shellExitAction 1), run inside the shell",
          p["type"] as? String == "Window Settings" && p["shellExitAction"] as? Int == 1 && p["RunCommandAsShell"] as? Bool == false, "\(p)")
    let script = c.work.appendingPathComponent("sign-in-\(ClaudeSignIn.lockKey(c.authFolder)).command")
    check("window: its command execs the script (named after the folder's lock key) in place of the login shell",
          p["CommandString"] as? String == "exec '\(script.path)'", "\(String(describing: p["CommandString"]))")
    let name = p["name"] as? String ?? ""
    check("window: the plist's name is the file's base name (Terminal names the profile after the file)",
          name == "Sample app sign-in" && name == s.profileName && c.terminal.opened.last?.deletingPathExtension().lastPathComponent == name, name)
    check("window: a title with a slash or colon makes a plain file name", ClaudeSignIn(folder: c.authFolder, wanted: nil, tools: c.tools(), claude: claude,
          confirm: { _ in nil }, work: c.work, title: "A/B: app", terminalProfiles: prefs.tool).profileName == "A-B- app sign-in")
    check("window: states opening, then waiting for the browser", c.states == [.opening, .waitingForBrowser], "\(c.states)")
    let login = c.waitLogin()
    let args = (try? String(contentsOfFile: c.conf.path + ".args", encoding: .utf8)) ?? ""
    check("script: claude auth login --claudeai --email, the address quoted", args.contains("ARG [auth]\nARG [login]\nARG [--claudeai]\nARG [--email]\nARG [o'neil@example.com]"), args)
    check("script: on this folder only, no key from the shell", args.contains("ENV CLAUDE_CONFIG_DIR=\(c.folder.path)") && args.contains("ENV KEY=<unset>"), args)
    check("script: it removed itself once started (it holds the address)", !fm.fileExists(atPath: script.path))
    let mode = ((try? fm.attributesOfItem(atPath: c.work.path))?[.posixPermissions] as? NSNumber)?.intValue
    check("work folder: one already there (0755) is made owner only", mode == 0o700, "\(String(describing: mode))")
    let lines = SignInScript.lines(claude: "/sample/claude", folder: c.authFolder, email: nil, removesItself: true,
                                   watch: .init(pid: URL(fileURLWithPath: "/w/p"), status: URL(fileURLWithPath: "/w/s"), declined: URL(fileURLWithPath: "/w/d")))
    check("script: ends cleanly when asked to (TERM, HUP)", lines.contains("trap 'exit 0' TERM HUP"))
    check("script: its pid first, the login's status after", lines.contains("print -r -- $$ > '/w/p'") && lines.contains("print -r -- $s > '/w/s'"))
    check("script: Claude Code's errors still reach the window, looked through for a refusal",
          lines.contains { $0.contains("2>&1 1>&3 3>&- | tee /dev/fd/4 | { grep -F -m 1 -e 'OAuth error: access_denied' >/dev/null && : > '/w/d'; cat >/dev/null; }") }
          && lines.contains("s=${pipestatus[1]}"))
    check("script: a login that didn't end well stays on screen until Return; then a clean end",
          lines.suffix(2) == ["if [ $s -ne 0 ]; then read -r; fi", "exit 0"])
    let folderFiles = (try? fm.contentsOfDirectory(atPath: c.folder.path)) ?? []
    check("nothing written into the Claude Code folder", folderFiles.isEmpty, "\(folderFiles)")
    s.stop()
    check("stop: the outcome is stopped", c.waitEnd() == .stopped, "\(String(describing: c.outcome))")
    check("stop: the claude auth login in the window is ended", spin(until: { !pidAlive(login) }, max: 5), "pid \(login)")
    check("stop: the window's shell ends cleanly (its window closes)", c.shellEnded() == 0)
    check("profiles: the stop took this sign-in's profile; the others stay (Terminal's default one too)",
          spin(until: { prefs.names == ["Basic", "Lookalike", "Other app sign-in", "Pinned"] }, max: 3), "\(prefs.names)")
    check("profiles: …nothing but those removals was written (one write at the start, one at the stop)", prefs.writes == 2, "\(prefs.writes)")
    let left = (try? fm.contentsOfDirectory(atPath: c.work.path)) ?? []
    check("stop: nothing left in the work folder", left.isEmpty, "\(left)")
    let lock = open(locks.appendingPathComponent("signin-\(AuthFolder.sha8(c.folder.resolvingSymlinksInPath().path)).lock").path, O_RDWR)
    check("stop: the folder's lock is free again", lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0)
    if lock >= 0 { close(lock) }
    c.cleanUp()
}

// the files' modes: the settings file is only read (0600), the script runs (0700); both owner only. A Terminal that never runs
// the script leaves it, so it can be looked at.
do {
    let c = Case("modes", login: ["login": "hang"])
    c.terminal.neverStarts = true
    c.start(wanted: wantedID(uuid(1)), startGrace: 20)
    spin(until: { c.states.contains(.waitingForBrowser) })
    func mode(_ u: URL) -> Int? { ((try? fm.attributesOfItem(atPath: u.path))?[.posixPermissions] as? NSNumber)?.intValue }
    let settings = c.work.appendingPathComponent("Sample app sign-in.terminal")
    let script = c.work.appendingPathComponent("sign-in-\(ClaudeSignIn.lockKey(c.authFolder)).command")
    check("files: the Terminal settings file is owner read and write only (0600; it isn't run)", mode(settings) == 0o600, "\(String(describing: mode(settings)))")
    check("files: …the script stays executable, owner only (0700)", mode(script) == 0o700, "\(String(describing: mode(script)))")
    c.signIn.stop(); c.waitEnd()
    c.cleanUp()
}

// ── each outcome ──────────────────────────────────────────────────────────────────────────────────────
do {
    let c = Case("verified", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    c.start(wanted: wantedID(uuid(1)), confirm: said("ann@example.com"))
    let o = c.waitEnd()
    if case .signedIn(let a)? = o {
        check("signed in: the account wanted by its id, verified by the app's word", a.accountID == uuid(1) && a.email == "ann@example.com"
              && a.source == .verified, "\(a)")
    } else { check("signed in (verified)", false, "\(String(describing: o))") }
    check("signed in: the window's shell ended cleanly by itself (its window closes)", c.shellEnded() == 0)
    check("signed in: Terminal's kept profile for it is gone", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
    c.cleanUp()
}
do {
    let c = Case("guessed", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51)])
    var asked = 0
    // the stand-in login writes the record and exits before the script writes the status: a tick in that gap asks the word
    // once before the end, which the product doesn't count, so the stand-in waits for the end before it answers
    c.start(wanted: SignedInAccount(email: "Ann@example.com", origin: .record), confirm: c.afterEnd { _ in asked += 1; return nil })
    if case .unverified(let a)? = c.waitEnd() {
        check("no word from the app: the record's guess ends unverified, never signed in", a.source == .guessed && a.accountID == uuid(1), "\(a)")
    } else { check("unverified (no word)", false, "\(String(describing: c.outcome))") }
    check("…after the word was asked again (3 times in all once the login ended)", asked == 3, "\(asked)")
    check("…and its window closed", c.shellEnded() == 0)
    c.cleanUp()
}
do {
    // an ask before the login ended (the record changed first) doesn't count against the 3 tries: 3 asks after the end, however
    // many came before. The stand-in login holds 1 s between writing the record and ending, so the early ask is surely before
    // the status exists (one ask, as the record changed once), and the counts are exact.
    let c = Case("early-ask", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "hold": "1"])
    let lock = NSLock()
    var before = 0, after = 0
    c.start(wanted: SignedInAccount(email: "Ann@example.com", origin: .record), confirm: { _ in
        let status = c.signIn.statusURL
        let ended = (try? String(contentsOf: status, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == 0
        lock.lock(); if ended { after += 1 } else { before += 1 }; lock.unlock()
        return nil
    })
    let o = c.waitEnd()
    lock.lock(); let (b, a) = (before, after); lock.unlock()
    // The asks before the end (a new folder's record turning up asks on every tick while the login is held, so several) are
    // well before the status and don't count: exactly 3 after it. An early ask counted toward the 3 leaves fewer after.
    check("no word: asks came before the login ended and they don't count: exactly 3 after it",
          { if case .unverified? = o { return true } else { return false } }() && b >= 1 && a == 3, "\(String(describing: o)) before \(b) after \(a)")
    c.cleanUp()
}
do {
    // the word disagrees with the record at first (the record a step behind), then agrees: confirmed after the retries
    let c = Case("catchup", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    var asked = 0
    c.start(wanted: wantedID(uuid(1)), confirm: { _ in asked += 1; return SignedInAccount.process(["email": asked < 3 ? "bob@example.com" : "ann@example.com", "organization": "Sample Org"]) })
    if case .signedIn(let a)? = c.waitEnd() { check("the word catching up with the record: signed in on the third ask", a.accountID == uuid(1) && asked == 3, "\(a) \(asked)") }
    else { check("catch-up", false, "\(String(describing: c.outcome)) \(asked)") }
    c.cleanUp()
}
do {
    // the word keeps naming another account than the record (stale): never a match, unverified
    let c = Case("stale", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    c.start(wanted: wantedID(uuid(1)), confirm: said("bob@example.com"))
    if case .unverified(let a)? = c.waitEnd() { check("the word and a stale record never agreeing: unverified, the word's account", a.email == "bob@example.com", "\(a)") }
    else { check("stale record", false, "\(String(describing: c.outcome))") }
    c.cleanUp()
}
do {
    // the same address in another organisation, the word without an id: the id wanted is compared with the record's only
    // when the record agrees with the word; here it doesn't (the record is the wanted seat's, the word another's)
    let c = Case("seat", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    c.start(wanted: SignedInAccount(accountID: uuid(1), email: "ann@example.com", origin: .record), confirm: said("ann@example.com", "Other Org"))
    if case .unverified? = c.waitEnd() { check("a same-address seat in another organisation, the record disagreeing: not taken for the one wanted", true) }
    else { check("same-address seat", false, "\(String(describing: c.outcome))") }
    c.cleanUp()
    // …and where the record agrees with the word (the other seat's own id), it is the wrong account
    let d = Case("seat2", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(9), "org": uuid(59), "orgName": "Other Org"])
    d.start(wanted: SignedInAccount(accountID: uuid(1), email: "ann@example.com", origin: .record), confirm: said("ann@example.com", "Other Org"))
    if case .wrongAccount(let a, _)? = d.waitEnd() { check("…the record agreeing names the other seat's id: wrong account", a.accountID == uuid(9), "\(a)") }
    else { check("same-address seat, record agreeing", false, "\(String(describing: d.outcome))") }
    d.cleanUp()
}
do {
    // the record changes while the login still runs, and the word disagrees: nothing ends it (its sign-in isn't written yet)
    let c = Case("running", login: ["login": "hang"])
    c.start(wanted: wantedID(uuid(1)), confirm: said("ann@example.com"))
    let login = c.waitLogin()
    c.record("bob@example.com", uuid(2))
    spin(2)
    check("a login still running is never ended on the word and the record disagreeing", c.outcome == nil && pidAlive(login), "\(String(describing: c.outcome))")
    c.signIn.stop(); c.waitEnd()
    c.cleanUp()
    // …but when the word and the record agree on another account, it ends at once: the wrong account
    let d = Case("running2", login: ["login": "hang"])
    d.start(wanted: wantedID(uuid(1)), confirm: said("bob@example.com"))
    let login2 = d.waitLogin()
    d.record("bob@example.com", uuid(2))
    if case .wrongAccount(let a, _)? = d.waitEnd() { check("…the word and the record agreeing on another account: wrong account early", a.accountID == uuid(2), "\(a)") }
    else { check("early wrong account", false, "\(String(describing: d.outcome))") }
    check("…and its login is ended", spin(until: { !pidAlive(login2) }, max: 5))
    d.cleanUp()
}
do {
    // the word blocks for long: Stop doesn't wait for it, and its late answer is dropped
    let c = Case("slowword", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    let gate = DispatchSemaphore(value: 0)
    c.start(wanted: wantedID(uuid(1)), confirm: { _ in _ = gate.wait(timeout: .now() + 20); return SignedInAccount.process(["email": "ann@example.com"]) })
    spin(until: { fm.fileExists(atPath: c.signIn.statusURL.path) }, max: 10)
    spin(0.5)
    let t = Date()
    c.signIn.stop()
    check("a word that blocks: Stop ends it at once (stopped)", c.waitEnd(5) == .stopped && Date().timeIntervalSince(t) < 4, "\(String(describing: c.outcome))")
    gate.signal(); spin(0.5)
    check("…and the word's late answer changes nothing", c.outcome == .stopped)
    c.cleanUp()
}
do {
    let c = Case("nostart", login: ["login": "hang"])
    c.terminal.neverStarts = true
    c.start(wanted: wantedID(uuid(1)), startGrace: 1)
    check("Terminal never started the script: failed, not opened", c.waitEnd() == .failed(.notOpened), "\(String(describing: c.outcome))")
    let left = ((try? fm.contentsOfDirectory(atPath: c.work.path)) ?? []).filter { $0.hasSuffix(".command") }
    check("…and its script is gone (a late Terminal finds nothing to run)", left.isEmpty, "\(left)")
    check("…and the profile Terminal kept for the window it never ran is gone too", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
}
do {
    let c = Case("quit", login: ["login": "hang"])
    c.start(wanted: wantedID(uuid(1)))
    let login = c.waitLogin()
    spin(until: { fm.fileExists(atPath: c.signIn.pidURL.path) }, max: 5)
    check("quit: Terminal holds the window's profile while it is open", prefs.left(in: c.work).count == 1, "\(prefs.names)")
    c.signIn.stopNow()
    check("quit mid-sign-in (stopNow): the login is ended before it returns", !pidAlive(login))
    check("quit: …and Terminal's kept profile is gone before it returns too", prefs.left(in: c.work).isEmpty, "\(prefs.names)")
    check("…and the window's shell ends cleanly", c.shellEnded(3) == 0)
    c.cleanUp()
}
do {
    let c = Case("again", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51)])
    c.record("ann@example.com", uuid(1))            // already on it: the record doesn't change, only the login's end says so
    c.start(wanted: wantedID(uuid(1)), confirm: said("ann@example.com"))
    // the record names no organisation by name, the running claude no ids: the same address, the record's id for the one wanted
    if case .signedIn(let a)? = c.waitEnd() { check("signed in again on the same account: the login's good end", a.email == "ann@example.com" && a.source == .verified, "\(a)") }
    else { check("signed in again", false, "\(String(describing: c.outcome))") }
    c.cleanUp()
}
do {
    let c = Case("new", login: ["login": "ok", "email": "new@example.com", "uuid": uuid(3), "org": uuid(51), "orgName": "Sample Org"])
    c.start(wanted: nil, confirm: said("new@example.com"))
    if case .signedIn(let a)? = c.waitEnd() { check("a brand-new folder (no account wanted): whoever signed in", a.email == "new@example.com" && a.accountID == uuid(3)) }
    else { check("new folder", false, "\(String(describing: c.outcome))") }
    c.cleanUp()
}
do {
    let c = Case("wrongid", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(2), "org": uuid(51), "orgName": "Sample Org"])
    c.start(wanted: wantedID(uuid(1)), confirm: said("ann@example.com"))
    if case .wrongAccount(let a, let w)? = c.waitEnd() {
        check("wrong account by id: another id signed in", a.accountID == uuid(2) && w.accountID == uuid(1), "\(a) \(w)")
    } else { check("wrong account by id", false, "\(String(describing: c.outcome))") }
    check("wrong account: the window's shell ended cleanly (its window closes)", c.shellEnded() == 0)
    check("wrong account: Terminal's kept profile is gone", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
    c.cleanUp()
}
do {
    let c = Case("wrongorg", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(4), "org": uuid(52), "orgName": "Other Org"])
    c.start(wanted: SignedInAccount(email: "ann@example.com", organizationName: "Sample Org", origin: .record), confirm: said("ann@example.com", "Other Org"))
    if case .wrongAccount(let a, _)? = c.waitEnd() {
        check("wrong account by address and organisation: the same address in another organisation", a.organizationName == "Other Org", "\(a)")
    } else { check("wrong account by organisation", false, "\(String(describing: c.outcome))") }
    c.cleanUp()
    let d = Case("rightorg", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(5), "org": uuid(51), "orgName": "Sample Org"])
    d.start(wanted: SignedInAccount(email: "ANN@example.com", organizationName: "sample org", origin: .record), confirm: said("ann@example.com", "Sample Org"))
    if case .signedIn? = d.waitEnd() { check("the same address and organisation (case doesn't count): signed in", true) }
    else { check("right organisation", false, "\(String(describing: d.outcome))") }
    d.cleanUp()
    let e = Case("wrongaddr", login: ["login": "ok", "email": "bob@example.com", "uuid": uuid(6), "org": uuid(51)])
    e.start(wanted: SignedInAccount(email: "ann@example.com", origin: .record), confirm: said("bob@example.com"))
    if case .wrongAccount(let a, _)? = e.waitEnd() { check("wrong account by address", a.email == "bob@example.com") }
    else { check("wrong address", false, "\(String(describing: e.outcome))") }
    e.cleanUp()
}
do {
    let c = Case("declined", login: ["login": "declined"])
    c.start(wanted: wantedID(uuid(1)))
    check("declined: Claude Code's refusal in the window is seen", c.waitEnd() == .declined, "\(String(describing: c.outcome))")
    spin(0.5)
    check("declined: the window stays open to be read", c.shellRunning)
    check("declined: …and its profile stays with it (nothing is taken from an open window)", prefs.left(in: c.work).count == 1, "\(prefs.names)")
    c.signIn.stop()
    check("declined: stop then closes it (a clean end)", c.shellEnded() == 0)
    check("declined: …and Terminal's kept profile goes with the closed window", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
    c.cleanUp()
}
do {
    let c = Case("declinedwait", login: ["login": "declinedwait"])
    c.start(wanted: wantedID(uuid(1)))
    let login = c.waitLogin()
    check("declined while the login still waits: declined at once", c.waitEnd() == .declined, "\(String(describing: c.outcome))")
    check("…the login left waiting is ended", spin(until: { !pidAlive(login) }, max: 5))
    spin(0.5)
    check("…and the window stays open to be read", c.shellRunning)
    c.cleanUp()
}
do {
    let c = Case("failed", login: ["login": "fail"])
    c.start(wanted: wantedID(uuid(1)))
    check("failed: the login's exit status", c.waitEnd() == .failed(.loginFailed(status: 2)), "\(String(describing: c.outcome))")
    spin(0.5)
    check("failed: the window stays open to be read", c.shellRunning)
    // the next start closes it
    let held = c.terminal.last!
    let n = Case("afterfail", login: ["login": "hang"])
    n.start(wanted: nil)
    spin(until: { !held.isRunning }, max: 8)
    check("failed: the next sign-in's start closes it (a clean end)", !held.isRunning && held.terminationStatus == 0)
    check("failed: …and its profile goes at that start (the next one's own is the only one left)",
          spin(until: { prefs.left(in: n.work).count == 1 }, max: 8) && prefs.names.contains("Sample app sign-in") && !prefs.names.contains("Sample app sign-in 1"), "\(prefs.names)")
    n.stopAndSettle()
    c.cleanUp(); n.cleanUp()
}
do {
    let c = Case("timeout", login: ["login": "hang"])
    c.start(wanted: wantedID(uuid(1)), timeout: 1.5)
    let login = c.waitLogin()
    check("timed out: nothing came within the timeout", c.waitEnd() == .timedOut, "\(String(describing: c.outcome))")
    check("timed out: the login is ended", spin(until: { !pidAlive(login) }, max: 5))
    check("timed out: the window's shell ended cleanly (its window closes)", c.shellEnded() == 0)
    check("timed out: Terminal's kept profile is gone", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
    c.cleanUp()
}
do {
    let c = Case("closed", login: ["login": "hang"])
    c.start(wanted: wantedID(uuid(1)))
    let login = c.waitLogin()
    spin(until: { fm.fileExists(atPath: c.signIn.pidURL.path) }, max: 5)
    // Terminal closing the window hangs up its whole session
    if let s = c.terminal.last { kill(s.processIdentifier, SIGHUP) }
    kill(login, SIGHUP)
    check("window closed while the login ran: failed, window closed", c.waitEnd() == .failed(.windowClosed), "\(String(describing: c.outcome))")
    check("…the hung-up login is gone, and no status was written", !pidAlive(login)
          && !fm.fileExists(atPath: c.signIn.statusURL.path))
    c.cleanUp()
}

// ── Terminal's kept profiles: when they are swept, and what is never touched ─────────────────────────────
do {
    // the tool alone: only the exact command a sign-in writes (exec + the quoted script of the folder); never the default or
    // startup profile; a command that merely mentions the folder stays; no write for nothing
    let t = FakePrefs()
    let dir = "/sample/app's/work", quoted = SignInScript.q(dir + "/sign-in-12345678.command")
    t.put("mine", command: "exec \(quoted)")
    t.put("mine upper", command: "exec " + SignInScript.q(dir + "/sign-in-ABCDEF01.command"))
    t.put("mine startup", command: "exec \(quoted)", inUse: true)
    t.put("plain", command: "exec \(dir)/sign-in-12345678.command")
    t.put("mentions", command: "cd \(SignInScript.q(dir + "/")); ls")
    t.put("mentions the script", command: "exec \(quoted); ls")
    t.put("a url", command: "open \(SignInScript.q("https://example.com" + dir + "/"))")
    t.put("short hex", command: "exec " + SignInScript.q(dir + "/sign-in-1234567.command"))
    t.put("not hex", command: "exec " + SignInScript.q(dir + "/sign-in-1234567g.command"))
    t.put("a subfolder", command: "exec " + SignInScript.q(dir + "/sub/sign-in-12345678.command"))
    t.put("other", command: "exec '/sample/other/sign-in-12345678.command'")
    t.put("sibling", command: "exec '\(dir)-2/sign-in-12345678.command'")
    t.put("no command", command: "")
    let gone = t.tool.remove(commandsRunningIn: dir)
    check("profiles tool: removes only the profiles whose command is the folder's sign-in script (quoted, an apostrophe in the folder, any hex case)",
          gone == ["mine", "mine upper"] && t.names == ["a url", "mentions", "mentions the script", "mine startup", "no command", "not hex", "other", "plain",
                                                       "short hex", "sibling", "a subfolder"].sorted(), "\(gone) \(t.names)")
    check("profiles tool: a profile that merely mentions the folder, or the plain form, is kept", t.names.contains("mentions") && t.names.contains("plain")
          && t.names.contains("mentions the script") && t.names.contains("a url"))
    check("profiles tool: a default or startup profile stays, though its command matches", t.names.contains("mine startup"))
    check("profiles tool: one write; a second run finds nothing and writes nothing", t.tool.remove(commandsRunningIn: dir).isEmpty && t.writes == 1, "\(t.writes)")
    check("profiles tool: an empty folder matches nothing", t.tool.remove(commandsRunningIn: "").isEmpty && t.writes == 1)
    // a folder that isn't absolute or is too short removes nothing, though a command has that very shape
    let w = FakePrefs()
    for f in ["/", "/sample", "/sample/work", "sample/app/work", "~/app/work"] {
        w.put("p" + f, command: "exec " + SignInScript.q(f + "/sign-in-12345678.command"))
        w.put("url" + f, command: "open https://example.com/x/")
    }
    let before = w.names
    check("profiles tool: \"/\", a short or a relative folder remove nothing and write nothing",
          ["/", "/sample", "/sample/work", "sample/app/work", "~/app/work"].allSatisfy { w.tool.remove(commandsRunningIn: $0).isEmpty }
          && w.writes == 0 && w.names == before, "\(w.writes)")
    check("profiles tool: three components is enough", w.tool.remove(commandsRunningIn: "/sample/app/work").isEmpty && w.writes == 0)
    t.readable = false
    check("profiles tool: preferences that can't be read: nothing removed, nothing written", t.tool.remove(commandsRunningIn: "/sample/app/work") == [] && t.writes == 1)
    // Terminal's own write between the read and ours is kept: the profiles are read again and only the chosen names go
    let racing = FakePrefs()
    racing.put("mine", command: "exec " + SignInScript.q("/sample/app/work/sign-in-12345678.command"))
    racing.put("changed", command: "exec " + SignInScript.q("/sample/app/work/sign-in-87654321.command"))
    var seen = 0, written: [String: Any] = [:]
    let inner = racing.tool
    let live = TerminalProfiles(read: {
        seen += 1
        let r = inner.read()
        if seen == 1 {                       // Terminal's own write, after our first read
            racing.put("new by Terminal", command: "/bin/zsh -l")
            racing.put("changed", command: "/bin/zsh -l")
        }
        return r
    }, write: { written = $0; inner.write($0) })
    let removed = live.remove(commandsRunningIn: "/sample/app/work")
    check("profiles tool: read again before the write: a profile Terminal changed is kept, one it added is in the copy written",
          removed == ["mine"] && Set(written.keys) == ["changed", "new by Terminal"] && seen == 2, "\(removed) \(written.keys.sorted()) \(seen)")
}
do {
    // a sign-in sweeps at its start and at each end; unreadable preferences never stop one
    prefs.reset()
    let c = Case("sweeps", login: ["login": "hang"])
    c.start(wanted: wantedID(uuid(1)), lateSweep: 2)          // the late sweep comes 2 s after the end: time to put the profile in first
    spin(until: { c.states.contains(.waitingForBrowser) })
    // the rest needs the window: a start that ended first says how (its outcome), not just that nothing was swept
    check("profiles: the sweeps' sign-in opened its window", c.states.contains(.waitingForBrowser) && c.terminal.count == 1,
          "\(c.states) \(String(describing: c.outcome)) opened \(c.terminal.count)")
    check("profiles: swept at the start", prefs.reads >= 1, "\(prefs.reads)")
    let atStart = prefs.writes
    // the window's script is under way (its login runs) before the stop: a stop while Terminal is still starting the script
    // is a case of its own (below), whose script is ended only once it shows, and with it the sweeps. And the earlier
    // sign-in's late sweep, which this start set off when it ended that one (0.3 s), has come and gone: on the same stand-in
    // it would otherwise be the second write counted below, in this sign-in's own late sweep's place.
    _ = c.waitLogin()
    spin(0.5)
    c.signIn.stop(); c.waitEnd()
    // the stop's own sweep took the profile Terminal kept for the window (a write); it has run by the time the outcome came
    check("profiles: swept at the end (stopped): the window's kept profile is taken at once", prefs.writes == atStart + 1 && prefs.left(in: c.work).isEmpty,
          "\(prefs.writes) \(atStart) \(prefs.names)")
    // a read can't tell the late sweep from the first one (a sweep that finds something reads twice), so a profile that only
    // turns up after the stop's sweep must go in the late one: one more write, nobody else sweeping
    prefs.put("Sample app sign-in late", command: "exec " + SignInScript.q(c.work.path + "/sign-in-12345678.command"))
    check("profiles: …and once more after the window had closed itself (the late sweep takes what came after the first)",
          spin(until: { prefs.writes == atStart + 2 }, max: 6) && prefs.left(in: c.work).isEmpty, "\(prefs.writes) \(atStart) \(prefs.names)")
    c.cleanUp()
    // a refused start (the folder isn't there) sweeps at its start and at its end too
    prefs.reset()
    let m = Case("sweeps-missing", login: ["login": "ok"], make: false)
    m.start(wanted: nil)
    check("profiles: a start that is refused is swept at its start and at its end", m.waitEnd() == .failed(.folderNotReady) && prefs.reads >= 2, "\(prefs.reads)")
    // unreadable preferences
    prefs.reset(); prefs.readable = false
    let u = Case("sweeps-unreadable", login: ["login": "ok", "email": "ann@example.com", "uuid": uuid(1), "org": uuid(51), "orgName": "Sample Org"])
    u.start(wanted: wantedID(uuid(1)), confirm: said("ann@example.com"))
    if case .signedIn? = u.waitEnd() { check("profiles: Terminal's preferences unreadable: the sign-in goes on, nothing written", prefs.writes == 0, "\(prefs.writes)") }
    else { check("profiles: unreadable preferences", false, "\(String(describing: u.outcome))") }
    u.cleanUp()
    prefs.reset()
}
/// A window whose shell has the script open at once but runs it only `delay` seconds later (a slow Terminal, or a runner slow
/// to start a login shell): removing the script file in that time doesn't keep it from running. The script's path stays in
/// the shell's command line, as a window's does.
func slowStart(_ delay: Double) -> String { "exec 9<\"$1\" || exit 1; sleep \(delay); exec /bin/zsh /dev/fd/9 \"$1\"" }
/// Waits for a slow-start window's shell to hold the script open (its `sleep` runs): on a busy Mac a stop could otherwise
/// remove the file first.
func waitHeld(_ c: Case) {
    let shellPid = c.terminal.last?.processIdentifier ?? -1
    spin(until: { ProcessTable.table()?.contains { $0.ppid == shellPid && $0.name == "sleep" } == true }, max: 5)
}
do {
    // a stop while Terminal is still starting the window's script (its pid not written yet): the stop ends nothing it can see,
    // but once the script shows it is ended, window and all (a clean end), its login with it, and its profile swept (late too:
    // a profile Terminal writes after the window closed goes)
    prefs.reset()
    let c = Case("late-start", login: ["login": "hang"])
    c.terminal.shellBody = { slowStart(1) }
    c.start(wanted: wantedID(uuid(1)), lateSweep: 2)
    spin(until: { c.states.contains(.waitingForBrowser) })
    waitHeld(c)
    c.signIn.stop()
    check("late start: stopped before the window's script ran", c.waitEnd() == .stopped && c.shellRunning && !pidAlive(c.loginPid),
          "\(String(describing: c.outcome)) \(c.shellRunning) \(c.loginPid)")
    check("late start: …the script, once it shows, is ended: its shell ends cleanly (its window closes)", c.shellEnded(12) == 0,
          "\(c.shellRunning) \(String(describing: c.terminal.last.map { $0.isRunning ? nil : $0.terminationStatus }))")
    // (the sign-in sees the shell gone on its own clock, a moment apart from this one's: it removes the pid file then)
    let pidFile = c.signIn.pidURL.path
    check("late start: …its login did run (it is ended once it runs), and none is left running, nor a pid file",
          c.loginPid > 0 && spin(until: { !pidAlive(c.loginPid) && !fm.fileExists(atPath: pidFile) }, max: 3),
          "login \(c.loginPid) alive \(pidAlive(c.loginPid)), pid file \(fm.fileExists(atPath: pidFile))")
    prefs.put("Sample app sign-in late", command: "exec " + SignInScript.q(c.work.path + "/sign-in-12345678.command"))
    check("late start: …and its profile is swept after it, late too", spin(until: { prefs.left(in: c.work).isEmpty }, max: 6), "\(prefs.names)")
    c.cleanUp()
    prefs.reset()
}
do {
    // the same, with the next sign-in started at once: the late script is still ended (its sign-in follows its own files after
    // it was superseded), and writes nothing of the next one's, which goes on
    prefs.reset()
    let a = Case("late-restart-a", login: ["login": "hang"])
    a.terminal.shellBody = { slowStart(1) }
    a.start(wanted: wantedID(uuid(1)), lateSweep: 2)
    spin(until: { a.states.contains(.waitingForBrowser) })
    waitHeld(a)
    a.signIn.stop()
    let b = Case("late-restart-b", login: ["login": "hang"])
    b.start(wanted: wantedID(uuid(2)))
    check("late restart: the first stopped, the next one waits for the browser", a.waitEnd() == .stopped
          && spin(until: { b.states.contains(.waitingForBrowser) || b.outcome != nil }) && b.outcome == nil, "\(String(describing: a.outcome)) \(String(describing: b.outcome))")
    let bLogin = b.waitLogin()
    check("late restart: …the first one's late script, once it shows, is ended cleanly; its login ran and is gone",
          a.shellEnded(12) == 0 && a.loginPid > 0 && spin(until: { !pidAlive(a.loginPid) }, max: 3),
          "\(a.shellRunning) login \(a.loginPid) alive \(pidAlive(a.loginPid))")
    spin(1)
    check("late restart: …and the next one goes on: its login runs, its pid file is its own window's, no outcome",
          b.outcome == nil && pidAlive(bLogin) && (try? String(contentsOf: b.signIn.pidURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
              == b.terminal.last.map { "\($0.processIdentifier)" } && a.signIn.pidURL != b.signIn.pidURL,
          "\(String(describing: b.outcome)) \(pidAlive(bLogin))")
    b.stopAndSettle()
    a.cleanUp(); b.cleanUp()
    prefs.reset()
}
do {
    // quitting (stopNow) while Terminal is still starting the window's script: it waits for the script (3 s at most) and ends
    // it before it returns
    let c = Case("late-quit", login: ["login": "hang"])
    c.terminal.shellBody = { slowStart(0.5) }                // 2.5 s of the 3 s left for the script and its login
    c.start(wanted: wantedID(uuid(1)))
    spin(until: { c.states.contains(.waitingForBrowser) })
    waitHeld(c)
    c.signIn.stopNow()
    check("late quit: stopNow ended the late script's login before it returned", c.loginPid > 0 && !pidAlive(c.loginPid),
          "login \(c.loginPid) alive \(pidAlive(c.loginPid))")
    check("late quit: …and its shell ends cleanly", c.shellEnded(3) == 0)
    c.waitEnd(); c.cleanUp()
}
do {
    // the static sweep's pid-file guard, alone (the only guard at start-up, when no sign-in of this run is `current`): a window
    // of an earlier run, its script's pid in a pid file of the work folder and the script in its command line, keeps its
    // profile. The work folder is one no sign-in of this run has used, so what the process's own last sign-in knows
    // about its window can't be what holds it. Its own Terminal-preferences stand-in: an earlier block's late sweep, on the
    // shared one, can't be counted as a read here.
    let mine = FakePrefs()
    let earlier = base.appendingPathComponent("earlier-run/work")
    try? fm.createDirectory(at: earlier, withIntermediateDirectories: true)
    let script = earlier.appendingPathComponent("sign-in-abcdef01.command").path
    func shell(_ named: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "trap 'exit 0' TERM HUP; while :; do sleep 0.1; done", "stand-in", named]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
        spin(until: { ProcessTable.launch(of: p.processIdentifier)?.args.contains(named) == true }, max: 3)
        return p
    }
    func names(_ p: Process) { try? "\(p.processIdentifier)\n".write(to: earlier.appendingPathComponent("sign-in-0000abcd.pid"), atomically: true, encoding: .utf8) }
    func put() { mine.reset(); mine.put("Sample app sign-in", command: "exec " + SignInScript.q(script)) }
    let standIn = mine.tool
    func sweep() { ClaudeSignIn.sweep(work: earlier, terminalProfiles: standIn) }
    let open = shell(script)
    names(open)
    put(); sweep()
    check("sweep: a script of the work folder still running from an earlier run keeps its profile (the pid file alone)",
          mine.names == ["Sample app sign-in"] && mine.reads == 0, "\(mine.names) \(mine.reads)")
    // …a pid that runs something else (the pid was reused) doesn't: the command line must name the script
    let other = shell("/not/the/work/sign-in-abcdef01.command")
    names(other); put(); sweep()
    check("sweep: a pid that runs something else holds nothing", mine.names.isEmpty, "\(mine.names)")
    // …and the window gone (its shell ended), the profile goes
    names(open); put()
    open.terminate(); open.waitUntilExit()
    sweep()
    check("sweep: the earlier run's window gone, its profile goes", mine.names.isEmpty, "\(mine.names)")
    other.terminate(); other.waitUntilExit()
}
/// A window's shell that ignores TERM (and the TERM its children get), ends cleanly on HUP (Terminal's hang-up), and has
/// declined its sign-in: the window stays open to be read, as a real declined one does.
func deafShell(_ c: Case) -> String {
    "trap '' TERM; trap 'exit 0' HUP; printf '%s\\n' $$ > '\(c.signIn.pidURL.path)'; : > '\(c.signIn.declinedURL.path)'; "
        + "while :; do (trap - TERM; exec sleep 0.1); done"
}
/// Waits for whatever the sign-in's queue still does (a stop's wait for the shell): the static sweep takes that queue, and
/// is handed a Terminal stand-in with nothing in it.
func settle(_ work: URL) { ClaudeSignIn.sweep(work: work, terminalProfiles: FakePrefs().tool) }
do {
    // stopping an ended window whose shell doesn't end when asked: the profile stays; once the shell dies, a stop takes it
    prefs.reset()
    let c = Case("deaf", login: ["login": "hang"])
    c.terminal.shellBody = { deafShell(c) }
    c.start(wanted: wantedID(uuid(1)))
    check("deaf shell: its sign-in is declined, the window left open to be read", c.waitEnd() == .declined && c.shellRunning, "\(String(describing: c.outcome))")
    c.signIn.stop()
    settle(c.work)                                       // the stop has waited out its 3 s (and the 1 s after the kill)
    check("deaf shell: stopped, the shell is still there (TERM ignored; it is never killed)", c.shellRunning)
    check("deaf shell: …and its profile stays with the window still open", prefs.left(in: c.work).count == 1, "\(prefs.names)")
    if let s = c.terminal.last { kill(s.processIdentifier, SIGHUP) }
    check("deaf shell: the hang-up ends it cleanly", c.shellEnded() == 0)
    c.signIn.stop()
    check("deaf shell: …and a stop once it is gone takes its profile", spin(until: { prefs.left(in: c.work).isEmpty }, max: 4), "\(prefs.names)")
    c.cleanUp()
}
do {
    // a new sign-in's start while the earlier window's shell outlives the start's wait (it ignores TERM): one window per app, so
    // the start is refused (already signing in), and the earlier window keeps its pid file (its only handle) and its profile
    // through every later sweep
    prefs.reset()
    let d = Case("deaf-earlier", login: ["login": "hang"])
    d.terminal.shellBody = { deafShell(d) }
    d.start(wanted: wantedID(uuid(1)))
    check("deaf shell: its sign-in is declined, the window left open", d.waitEnd() == .declined && d.shellRunning, "\(String(describing: d.outcome))")
    let pidFile = d.signIn.pidURL
    let pidBefore = try? String(contentsOf: pidFile, encoding: .utf8)
    let n = Case("deaf-next", login: ["login": "hang"])
    n.start(wanted: wantedID(uuid(1)))
    check("start: the earlier window's shell outlived the start's wait: refused, already signing in, no window of its own",
          n.waitEnd(25) == .failed(.windowStillOpen) && n.terminal.count == 0, "\(String(describing: n.outcome)) \(n.terminal.count)")
    check("start: …the earlier window's shell is still there, its pid file untouched and its profile kept",
          d.shellRunning && pidBefore != nil && (try? String(contentsOf: pidFile, encoding: .utf8)) == pidBefore && prefs.left(in: d.work).count == 1,
          "\(d.shellRunning) \(String(describing: pidBefore)) \(prefs.names)")
    // the refused start's own end, its stop, and the start-up or quit sweep: none takes an open window's profile
    n.signIn.stop()
    let tool = prefs.tool
    ClaudeSignIn.sweep(work: d.work, terminalProfiles: tool)                       // after the stop on the queue
    spin(0.5)
    check("start: …and the later sweeps (its end, its stop, the static one) leave it", d.shellRunning && prefs.left(in: d.work).count == 1, "\(d.shellRunning) \(prefs.names)")
    d.cleanUp(); n.cleanUp()
    // the killed shell is gone once it is reaped: until then `n`, the last sign-in, still sees a window open in the work folder
    check("deaf shell: killed and reaped", spin(until: { d.terminal.last.map { !$0.isRunning } ?? true }, max: 5))
    prefs.reset()
}
// (the start-up sweep that reads nothing before a work folder exists is the app's: Checks/signin stage G, SignInWindow.sweepNow)

// ── one sign-in per app, and the two guards ──────────────────────────────────────────────────────────
do {
    let a = Case("first", login: ["login": "hang"])
    a.start(wanted: wantedID(uuid(1)))
    let first = a.waitLogin()
    let b = Case("second", login: ["login": "ok", "email": "bob@example.com", "uuid": uuid(2), "org": uuid(51)])
    b.start(wanted: wantedID(uuid(2)), confirm: said("bob@example.com"))
    check("a second start ends the first: stopped", a.waitEnd() == .stopped, "\(String(describing: a.outcome))")
    check("…its login is ended", spin(until: { !pidAlive(first) }, max: 5))
    check("…its window's shell ended cleanly", a.shellEnded() == 0)
    if case .signedIn? = b.waitEnd() { check("…and the second goes on", true) } else { check("second goes on", false, "\(String(describing: b.outcome))") }
    a.cleanUp(); b.cleanUp()
}
/// A `claude auth login` on a folder that this app didn't start: another app's sign-in (its script, named after the folder's
/// lock key, runs the login), or a bare one (a terminal's). Ended by its pid (and its script's) afterwards.
func otherLogin(_ c: Case, viaScript: Bool) -> (shell: Process, login: pid_t) {
    let conf = c.conf.path + "-other"
    try? "login=hang\n".write(toFile: conf, atomically: true, encoding: .utf8)
    try? fm.removeItem(atPath: conf + ".pid")
    let p = Process()
    p.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": c.folder.path, "CL_LOGIN_CONF": conf, "HOME": home.path, "ZDOTDIR": zdot.path]
    if viaScript {
        let dir = base.appendingPathComponent("other-app")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("sign-in-\(ClaudeSignIn.lockKey(c.authFolder)).command")
        try? "#!/bin/zsh\n'\(claude)' auth login --claudeai\ns=$?\nexit $s\n".write(to: script, atomically: true, encoding: .utf8)
        p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = [script.path]
    } else {
        p.executableURL = URL(fileURLWithPath: claude); p.arguments = ["auth", "login", "--claudeai"]
    }
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run()
    spin(until: { fm.fileExists(atPath: conf + ".pid") }, max: 5)
    let pid = (try? String(contentsOfFile: conf + ".pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
    return (p, pid)
}
func endOther(_ o: (shell: Process, login: pid_t)) {
    if pidAlive(o.login) { kill(o.login, SIGTERM) }
    if o.shell.isRunning { kill(o.shell.processIdentifier, SIGTERM) }
    o.shell.waitUntilExit()
    spin(until: { !pidAlive(o.login) }, max: 3)
}
do {
    // another app's sign-in on the folder
    let c = Case("guard", login: ["login": "hang"])
    let other = otherLogin(c, viaScript: true)
    check("process guard: the other app's login runs", pidAlive(other.login))
    c.start(wanted: wantedID(uuid(1)))
    check("process guard: a claude auth login already on the folder (another app's): refused",
          c.waitEnd() == .failed(.alreadySigningIn), "\(String(describing: c.outcome))")
    check("process guard: no window opened", c.terminal.count == 0)
    // another folder's login doesn't count
    let d = Case("guard-other", login: ["login": "hang"])
    d.start(wanted: wantedID(uuid(1)))
    spin(until: { d.states.contains(.waitingForBrowser) || d.outcome != nil })
    check("process guard: another app's login on another folder doesn't refuse this one", d.outcome == nil && d.terminal.count == 1,
          "\(String(describing: d.outcome))")
    d.stopAndSettle()
    endOther(other)
    // a bare login whose environment the kernel doesn't give (and no ClaudeSignIn script above it): its folder can't be told, so
    // it refuses rather than guesses (any folder). Whether the kernel gives a platform binary's environment (/bin/bash, the
    // stand-in's shell) is a fact of the Mac and its OS (it doesn't on this one's, it does on GitHub's macOS 26 runner), so
    // it is said, not checked; the guard itself is checked on a table of our own, below, whatever this Mac gives.
    let bare = otherLogin(c, viaScript: false)
    let platformEnv = ProcessTable.launch(of: bare.login)?.environmentRead
    print("note: the kernel \(platformEnv == true ? "gives" : "does not give") a platform binary's (/bin/bash) environment on this Mac")
    if platformEnv == false {
        let e = Case("guard-bare", login: ["login": "hang"])
        e.start(wanted: wantedID(uuid(1)))
        check("process guard: a real login whose environment the kernel doesn't give: refused", e.waitEnd() == .failed(.alreadySigningIn), "\(String(describing: e.outcome))")
        e.cleanUp()
    }
    endOther(bare)
    c.cleanUp(); d.cleanUp()
}
do {
    // the login guard on a process table of our own: what a login whose environment can't be read looks like, on any Mac
    let me = getuid()
    func login(pid: pid_t, parent: pid_t = 1, readable: Bool, configDir: String? = nil) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, ppid: parent, uid: me, ruid: me, name: "claude", launch: ProcessTable.Launch(
            exe: "/sample/bin/claude", args: ["claude", "auth", "login", "--claudeai"], configDir: configDir, environmentRead: readable))
    }
    func shell(pid: pid_t, script: String) -> ProcessTable.Entry {
        ProcessTable.Entry(pid: pid, ppid: 1, uid: me, ruid: me, name: "zsh", launch: ProcessTable.Launch(
            exe: "/bin/zsh", args: ["/bin/zsh", script], configDir: nil, environmentRead: false))
    }
    func outcome(_ name: String, _ table: @escaping (Case) -> [ProcessTable.Entry]) -> ClaudeSignIn.Outcome? {
        let c = Case(name, login: ["login": "hang"])
        c.start(wanted: wantedID(uuid(1)), processTable: { table(c) })
        spin(until: { c.states.contains(.waitingForBrowser) || c.outcome != nil })
        let o = c.outcome
        if o == nil { c.stopAndSettle() }
        c.cleanUp()
        return o
    }
    check("process guard (table): a login whose environment can't be read and no script above it: refused (the folder can't be told)",
          outcome("tbl-bare") { _ in [login(pid: 424_242, readable: false)] } == .failed(.alreadySigningIn))
    check("process guard (table): …even under a shell that runs no sign-in script",
          outcome("tbl-shell") { _ in [shell(pid: 424_241, script: "/sample/other.sh"), login(pid: 424_242, parent: 424_241, readable: false)] } == .failed(.alreadySigningIn))
    check("process guard (table): …under another folder's sign-in script it is that folder's, and doesn't refuse this one",
          outcome("tbl-other") { _ in [shell(pid: 424_241, script: "/sample/work/sign-in-abcdef01.command"), login(pid: 424_242, parent: 424_241, readable: false)] } == nil)
    check("process guard (table): …under this folder's own sign-in script, it refuses",
          outcome("tbl-own") { c in [shell(pid: 424_241, script: "/sample/work/sign-in-\(ClaudeSignIn.lockKey(c.authFolder)).command"), login(pid: 424_242, parent: 424_241, readable: false)] } == .failed(.alreadySigningIn))
    check("process guard (table): a login whose environment is read and names another folder doesn't refuse this one",
          outcome("tbl-env-other") { _ in [login(pid: 424_242, readable: true, configDir: "/sample/elsewhere/.claude-x")] } == nil)
    check("process guard (table): …one that names this folder does",
          outcome("tbl-env-same") { c in [login(pid: 424_242, readable: true, configDir: c.folder.path)] } == .failed(.alreadySigningIn))
    check("process guard (table): …one whose environment is read but names no CLAUDE_CONFIG_DIR is the default folder's (not this one's)",
          outcome("tbl-env-unset") { _ in [login(pid: 424_242, readable: true)] } == nil)
    check("process guard (table): a table with a process that can't be read at all: the processes can't be told, nothing starts",
          outcome("tbl-hidden") { _ in [ProcessTable.Entry(pid: 424_243, uid: nil, ruid: nil, name: "", launch: nil, hidden: true)] } == .failed(.processesUnreadable))
    check("process guard (table): no login in the table: it starts", outcome("tbl-none") { _ in [] } == nil)
}
// the environment branch: an ad-hoc built stand-in `claude` (not a platform binary: the kernel gives its environment), started
// bare with CLAUDE_CONFIG_DIR as given
do {
    let adhoc = env["CL_SIGNIN_ADHOC"] ?? ""
    check("the ad-hoc stand-in claude is there", fm.isExecutableFile(atPath: adhoc), adhoc)
    func bareLogin(_ dir: String?) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adhoc); p.arguments = ["auth", "login", "--claudeai"]
        var e = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        if let dir { e["CLAUDE_CONFIG_DIR"] = dir }
        p.environment = e
        try? p.run()
        spin(until: { ProcessTable.launch(of: p.processIdentifier) != nil }, max: 3)
        return p
    }
    func attempt(_ name: String) -> ClaudeSignIn.Outcome? {
        let c = Case(name, login: ["login": "hang"])
        c.start(wanted: wantedID(uuid(1)))
        spin(until: { c.states.contains(.waitingForBrowser) || c.outcome != nil })
        let o = c.outcome
        if o == nil { c.stopAndSettle() }
        c.cleanUp()
        return o
    }
    let target = home.appendingPathComponent(".claude-env-same")
    let same = bareLogin(target.path)
    let l = ProcessTable.launch(of: same.processIdentifier)
    check("the ad-hoc stand-in's environment is read: its CLAUDE_CONFIG_DIR", l?.environmentRead == true && l?.configDir == target.path,
          "\(String(describing: l))")
    check("environment: a login on this folder (by its CLAUDE_CONFIG_DIR): refused", attempt("env-same") == .failed(.alreadySigningIn))
    check("environment: …another folder's isn't", attempt("env-other") == nil)
    same.terminate(); same.waitUntilExit()
    for (what, dir) in [("relative", "rel/.claude-x"), ("empty", ""), ("~-led", "~/.claude-env-same")] {
        let p = bareLogin(dir)
        check("environment: a CLAUDE_CONFIG_DIR that can't be told (\(what)): refused for any folder", attempt("env-\(what)") == .failed(.alreadySigningIn))
        p.terminate(); p.waitUntilExit()
    }
    let unset = bareLogin(nil)
    check("environment: CLAUDE_CONFIG_DIR unset is the default folder: another folder isn't refused", attempt("env-unset") == nil)
    unset.terminate(); unset.waitUntilExit()
}
do {
    let c = Case("lock", login: ["login": "hang"])
    let lockPath = locks.appendingPathComponent("signin-\(ClaudeSignIn.lockKey(c.authFolder)).lock").path
    try? fm.createDirectory(at: locks, withIntermediateDirectories: true)
    // the lock's name: 8 hex of the SHA-256 of the folder's real path, the same through a link to it
    try? fm.createSymbolicLink(at: home.appendingPathComponent("link-to-lock"), withDestinationURL: c.folder)
    let viaLink = AuthFolder(path: home.appendingPathComponent("link-to-lock").path, isDefault: false, home: home.path)
    check("lock: one name per real folder (a link to it has the same)", ClaudeSignIn.lockKey(viaLink) == ClaudeSignIn.lockKey(c.authFolder)
          && ClaudeSignIn.lockKey(c.authFolder) == AuthFolder.sha8(c.folder.resolvingSymlinksInPath().path) && ClaudeSignIn.lockKey(c.authFolder).count == 8)
    check("lock: under ~/Library/Caches/n-uf by default", ClaudeSignIn.sharedLocks.path.hasSuffix("/Library/Caches/n-uf"))
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)          // another app holds it
    check("lock: taken by the other app", fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
    c.start(wanted: wantedID(uuid(1)))
    check("lock: held elsewhere, the start is refused", c.waitEnd() == .failed(.locked), "\(String(describing: c.outcome))")
    check("lock: no window opened", c.terminal.count == 0)
    close(fd)
    c.cleanUp()
}
do {
    let c = Case("missing", login: ["login": "ok"], make: false)
    c.start(wanted: nil)
    check("a folder that isn't there: refused", c.waitEnd() == .failed(.folderNotReady), "\(String(describing: c.outcome))")
    check("…and never made", !fm.fileExists(atPath: c.folder.path))
    check("…no window", c.terminal.count == 0)
    let real = home.appendingPathComponent("real-folder")
    try? fm.createDirectory(at: real, withIntermediateDirectories: true)
    try? fm.removeItem(at: c.folder)
    try? fm.createSymbolicLink(at: c.folder, withDestinationURL: real)
    let l = Case("missing", login: ["login": "ok"], make: false)
    l.start(wanted: nil)
    check("a link to a folder: refused (never launched through)", l.waitEnd() == .failed(.folderNotReady), "\(String(describing: l.outcome))")
    var guarded = 0
    let g = Case("guarded", login: ["login": "ok"])
    var t = g.tools(); t.mayLaunch = { what, _ in guarded += what == "login" ? 1 : 0; return false }
    let s = ClaudeSignIn(folder: g.authFolder, wanted: nil, tools: t, claude: claude, confirm: { _ in nil }, work: g.work,
                         terminalProfiles: prefs.tool, lateSweep: 0.3, locks: locks, poll: 0.2)
    s.start { g.outcome = $0 }
    check("the app's guard says no (cl_audit's FolderGuard): refused", g.waitEnd() == .failed(.folderNotReady) && guarded == 1 && g.terminal.count == 0)
}

print(failed == 0 ? "claudesignin checks: \(passed)/\(passed) passed" : "claudesignin checks: \(failed) failed, \(passed) passed")
exit(failed == 0 ? 0 : 1)
