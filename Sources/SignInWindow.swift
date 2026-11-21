// SignInWindow: cl_audit's one use of ClaudeAuth's ClaudeSignIn (Auth/ClaudeSignIn.swift): Claude Code's own `claude auth login`
// for a profile's ONE folder, opened in a Terminal window, followed until it ends one way or another, and its window closed
// after it. New profile's Sign in and Settings' sign-in keys (the clash's "back to the profile's own account", the plain
// sign-ins) go through it; the other sign-ins (first run, the default profile's offer, the switch, the menus) still use
// ClaudeCLI.openLogin.
//
// What this file adds to ClaudeSignIn, and nothing else:
// - cl_audit's own work folder (Application Support/usage-n-uf/sign-in: the script, its status files, Terminal's settings file
//   "cl_audit sign-in.terminal"), never a Claude Code folder, and its guard (FolderGuard, asked once, as openLogin does);
// - the app's verified word: the folder's sign-in read the way the agent reads it (ClaudeAuth's stored reader) and asked of
//   Anthropic's profile endpoint, the same call the agent makes for the numbers (UsageReader.request). Never a token out of
//   this file, nowhere logged;
// - the account wanted, with the organisation cl_audit knows (a seat of the profile with that address), else its address;
// - the outcomes in cl_audit's words (SignInSaid), which a page shows in place of its own: an unconfirmed sign-in is never
//   "signed in";
// - the sweep of Terminal's kept profiles at the app's start and quit (ClaudeSignIn.sweep), in this work folder only.
// One sign-in window per app: starting one ends the earlier (`replaced`). Only the settings app starts them (the agent and
// the Dock icons keep ClaudeCLI.openLogin's script), so the work folder has one owner.

import ClaudeAuth
import Foundation
import ProfileCore

enum SignInWindow {
    /// The window's title: Terminal's settings file (and the profile it keeps) is "cl_audit sign-in".
    static let title = "cl_audit"

    /// cl_audit's own folder for the sign-in's files (owner only, made by ClaudeSignIn).
    static var work: URL { Store.folder.appendingPathComponent("sign-in", isDirectory: true) }

    // MARK: the checks' seams

    struct Timing: Equatable {
        var timeout: TimeInterval = 600
        var poll: TimeInterval = 2
        var startGrace: TimeInterval = 25
        var lateSweep: TimeInterval = 6
    }
    nonisolated(unsafe) static var timing = Timing()
    /// Where the sign-in lock is taken (every app's: ~/Library/Caches/n-uf).
    nonisolated(unsafe) static var locks = ClaudeSignIn.sharedLocks
    /// Terminal's kept profiles: the real preferences, unless a check hands in its own. Never the real ones under a check's home
    /// (Checks/.work/…: cfprefsd writes the real file whatever CFFIXED_USER_HOME says), where it reads nothing and writes nothing.
    nonisolated(unsafe) static var terminalProfiles: TerminalProfiles =
        NSHomeDirectory().contains("/Checks/.work/") ? TerminalProfiles(read: { nil }, write: { _ in }) : .system
    /// Replaces the app's verified word (a check never asks the Keychain or Anthropic).
    nonisolated(unsafe) static var wordSeam: ClaudeSignIn.Confirm?

    // MARK: how a sign-in ended

    enum End: Equatable {
        /// The folder is signed in to the account wanted (or to whoever, when none was), confirmed by the app's word.
        case signedIn(SignedInAccount)
        /// It signed in, but the app's word never confirmed which account it is.
        case unverified(SignedInAccount)
        /// Another account signed in (the browser was signed in as someone else), confirmed.
        case wrongAccount(signedIn: SignedInAccount, wanted: SignedInAccount)
        case declined
        case failed(ClaudeSignIn.Failure)
        case timedOut
        /// The person's Cancel (or the page was left, the setup cancelled, cl_audit quitting): nothing to say.
        case cancelled
        /// Another sign-in of cl_audit started: one window per app.
        case replaced
        /// The folder to sign in couldn't be worked out from the profile picked (`folder(of:expecting:)`): nothing started.
        case refused

        init(_ o: ClaudeSignIn.Outcome, cancelled: Bool) {
            switch o {
            case .signedIn(let a): self = .signedIn(a)
            case .unverified(let a): self = .unverified(a)
            case .wrongAccount(let a, let w): self = .wrongAccount(signedIn: a, wanted: w)
            case .declined: self = .declined
            case .failed(let f): self = .failed(f)
            case .stopped: self = cancelled ? .cancelled : .replaced
            case .timedOut: self = .timedOut
            }
        }
    }

    // MARK: starting and stopping

    private final class Active {
        let folder: String
        let run: ClaudeSignIn
        var cancelled = false
        init(folder: String, run: ClaudeSignIn) { self.folder = folder; self.run = run }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: Active?

    /// The folder a sign-in is for: the picked profile's own, expanded, and nothing else. Pure. nil (refused) when the profile
    /// names no folder (an empty one would fall back to ~/.claude: never), or when `expecting` (the folder the call site
    /// itself holds for that profile: the draft's, the profile list's) is empty or isn't the same folder. The default
    /// folder comes out only for the profile whose own folder it is.
    static func folder(of picked: AccountEntry, expecting: String? = nil) -> String? {
        let own = picked.configDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !own.isEmpty else { return nil }
        let dir = expand(own)
        if let expected = expecting {
            let e = expected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e.isEmpty, FolderKey.canonical(e) == FolderKey.canonical(dir) else { return nil }
        }
        return dir
    }

    /// Claude Code's sign-in for the picked profile's folder in a Terminal window, followed to its end. The folder is
    /// `folder(of:expecting:)`: a profile with none, or one that isn't the call site's, starts nothing (`refused`), and the
    /// guard is never asked. `wanted`: the account it should end on (nil: whoever signs in). `creating`: only for a brand-new
    /// folder the person just chose (New profile), which the guard makes first (owner only); any other sign-in needs its
    /// folder there, and a folder the person deleted never comes back. `onState` and `onEnd` come on the main queue, `onEnd`
    /// once and always (a refused start ends `refused` or `failed`). Start from the main thread.
    static func start(_ claude: String, profile: AccountEntry, expecting: String?, wanted: SignedInAccount?, creating: Bool = false,
                      onState: @escaping (ClaudeSignIn.State) -> Void = { _ in }, onEnd: @escaping (End) -> Void) {
        let account = Account(profile)
        guard let dir = folder(of: profile, expecting: expecting), FolderKey.canonical(account.configDir) == FolderKey.canonical(dir) else {
            DispatchQueue.main.async { onEnd(.refused) }
            return
        }
        // the guard is asked once, here (a brand-new folder is made by it, never by ClaudeAuth); ClaudeAuth's own ask is then yes
        guard FolderGuard.mayLaunch("login", account.configDir, creating: creating) else {
            DispatchQueue.main.async { onEnd(.failed(.folderNotReady)) }
            return
        }
        var tools = ClaudeCLI.authTools
        tools.mayLaunch = { _, _ in true }
        tools.openTerminal = { ClaudeCLI.openTerminal($0) }
        let t = timing
        let run = ClaudeSignIn(folder: account.authFolder, wanted: wanted, timeout: t.timeout, tools: tools, claude: claude,
                               confirm: wordSeam ?? { word($0) }, work: work, title: title, shown: tilde(account.configDir),
                               startGrace: t.startGrace, terminalProfiles: terminalProfiles, lateSweep: t.lateSweep,
                               locks: locks, poll: t.poll)
        let mine = Active(folder: account.configDir, run: run)
        lock.lock(); active = mine; lock.unlock()
        run.start(onState: onState) { outcome in
            lock.lock(); if active === mine { active = nil }; let cancelled = mine.cancelled; lock.unlock()
            onEnd(End(outcome, cancelled: cancelled))
        }
    }

    /// Ends the app's sign-in on this folder (the login in its window, and the window), asking nothing: the person's Cancel.
    /// Nothing for another folder's sign-in.
    static func stop(folder configDir: String) {
        guard let a = take(configDir) else { return }
        a.run.stop()
    }

    /// The same, done before it returns (a few seconds at most; never waits for the verified word): for what removes the
    /// folder next (cancelling New profile) and for quitting. Never on the main thread's critical path but those.
    static func stopNow(folder configDir: String) {
        guard let a = take(configDir) else { return }
        a.run.stopNow()
    }

    /// cl_audit is quitting: the app's sign-in ends (window and login) and Terminal's kept profiles of cl_audit's sign-ins go.
    static func stopForQuit() {
        lock.lock(); let a = active; a?.cancelled = true; lock.unlock()
        a?.run.stopNow()
        sweepNow()
    }

    private static func take(_ configDir: String) -> Active? {
        lock.lock(); defer { lock.unlock() }
        guard let a = active, FolderKey.canonical(a.folder) == FolderKey.canonical(configDir) else { return nil }
        a.cancelled = true
        return a
    }

    /// The app is starting: Terminal's kept profiles of earlier sign-ins go (off the main thread). Nothing is read of
    /// Terminal's preferences for a Mac where cl_audit never opened a sign-in window (no work folder).
    static func sweepAtStart() {
        guard FileManager.default.fileExists(atPath: work.path) else { return }
        DispatchQueue.global(qos: .utility).async { sweepNow() }
    }

    static func sweepNow() {
        guard FileManager.default.fileExists(atPath: work.path) else { return }
        ClaudeSignIn.sweep(work: work, terminalProfiles: terminalProfiles)
    }

    // MARK: the account wanted

    /// The account a sign-in should end on, from an address: by the ids and organisation of the profile's seat that has this
    /// address (its account in use, or a standby one), else by the address alone. nil: no address, whoever signs in.
    /// An account wanted by its address alone is compared without an organisation (ClaudeSignIn.judge).
    static func wanted(for entry: AccountEntry, email: String?) -> SignedInAccount? {
        guard let email = email?.trimmingCharacters(in: .whitespaces), !email.isEmpty else { return nil }
        let seats = ([entry.seat] + entry.standby.map(\.seat)).compactMap { $0 }
        if let s = seats.first(where: { ($0.email ?? "").lowercased() == email.lowercased() }), !s.account.isEmpty {
            return SignedInAccount(accountID: s.account, email: s.email ?? email, organizationID: s.organization.flatMap { $0.isEmpty ? nil : $0 },
                                   origin: .record)
        }
        return SignedInAccount(email: email, origin: .record)
    }

    // MARK: the app's verified word

    /// The folder's account as Anthropic says it for the folder's own sign-in: the sign-in read as the agent reads it, then the
    /// profile endpoint the agent already asks (the usage numbers' owner). nil when the sign-in can't be read or Anthropic
    /// doesn't answer: the record then stays a guess (the sign-in ends unverified). Blocks (the sign-in's word runs on its own
    /// queue); the token goes to that one endpoint only.
    static func word(_ folder: AuthFolder) -> SignedInAccount? {
        guard case let .token(token, _, _)? = Authenticator(folder, tools: ClaudeCLI.authTools).readSignIn() else { return nil }
        final class Box: @unchecked Sendable { var account: SignedInAccount? }
        let box = Box(), done = DispatchSemaphore(value: 0), mutex = NSLock()
        URLSession.shared.dataTask(with: UsageReader.request("profile", token: token)) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                mutex.lock(); box.account = SignedInAccount.server(data); mutex.unlock()
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        mutex.lock(); defer { mutex.unlock() }
        return box.account
    }
}

/// How a sign-in ended, in cl_audit's words (the pages show this in place of their own lines). Fields, not text, so the
/// addresses are blurred as the page is drawn (Privacy.masked) and follow the Blur setting.
struct SignInSaid: Equatable {
    enum Kind: Equatable { case signedIn, unverified, wrongAccount, declined, failed, timedOut, replaced, refused }
    var kind: Kind
    var configDir: String
    /// The account that signed in (unverified, wrong account) and the one wanted.
    var address: String? = nil
    var wanted: String? = nil
    /// A wrong account that is another profile's: whose ("the account of “Work”", NewAccountSetup.ownerWords): refused.
    var owner: String? = nil
    var failure: ClaudeSignIn.Failure? = nil

    /// nil: nothing to say (the person's Cancel).
    /// `owner`: the name-words of the profile whose account signed in, when it isn't this profile's.
    init?(_ end: SignInWindow.End, configDir: String, owner: String? = nil) {
        self.configDir = configDir
        switch end {
        case .signedIn: kind = .signedIn
        case .unverified(let a): kind = .unverified; address = a.email
        case .wrongAccount(let a, let w): kind = .wrongAccount; address = a.email; wanted = w.email; self.owner = owner
        case .declined: kind = .declined
        case .failed(let f): kind = .failed; failure = f
        case .timedOut: kind = .timedOut
        case .replaced: kind = .replaced
        case .refused: kind = .refused
        case .cancelled: return nil
        }
    }

    /// The line. Never "Signed in." for an unconfirmed sign-in; no address is ever filled in by it.
    var text: String {
        let folder = tilde(configDir)
        func who(_ a: String?) -> String { a.map { Privacy.masked($0) } ?? "another account" }
        switch kind {
        case .signedIn: return "Signed in."
        case .unverified:
            return "The sign-in ended, but cl_audit couldn't confirm which account it is\(address.map { " (\(Privacy.masked($0)))" } ?? ""). Sign in again, or Refresh now."
        case .wrongAccount:
            if let owner { return "\(who(address)) is \(owner): one profile per account." }
            return "Signed in as \(who(address))\(wanted.map { ", not \(Privacy.masked($0))" } ?? ""): the browser's claude.ai account decided. Switch the account in the browser, then sign in again."
        case .declined: return "The sign-in was declined in the browser; nothing changed."
        case .timedOut: return "No sign-in came in 10 minutes; nothing changed."
        case .replaced: return "Another sign-in started, so this one ended; nothing changed."
        case .refused: return "cl_audit couldn't tell which folder this profile signs in to, so it didn't open a sign-in."
        case .failed:
            switch failure ?? .notOpened {
            case .folderNotReady: return ClaudeCLI.goneLine(configDir) ?? "\(folder) isn't there as a plain folder: nothing was signed in."
            case .locked: return "Another sign-in for \(folder) is starting. Wait a moment, then try again."
            case .alreadySigningIn: return "Claude Code's sign-in is already open for \(folder). Finish it, or close its Terminal window, then try again."
            case .processesUnreadable: return "cl_audit couldn't tell whether Claude Code's sign-in is already open for \(folder), so it didn't open one. Try again."
            case .notOpened: return "Terminal didn't open."
            case .windowStillOpen: return "An earlier Claude Code sign-in window is still open. Close it, then try again."
            case .loginFailed(let status): return "Claude Code's sign-in failed. It ended with an error (status \(status)); its Terminal window shows why."
            case .noAccount: return "The sign-in ended, but no account is signed in to this folder. Try again."
            case .windowClosed: return "The Terminal window was closed before the sign-in ended. Try again."
            }
        }
    }

    /// Red: a refusal or a failure. Amber: the rest but "Signed in.".
    var danger: Bool { kind == .failed || kind == .refused || (kind == .wrongAccount && owner != nil) }
}
