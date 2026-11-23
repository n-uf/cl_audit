// ClaudeAuth · the authenticator: one folder's sign-in, behind one type. It answers which account the folder is signed in
// to (verified or guessed), reads its stored sign-in through the app's reader (cl_audit's Keychain reader; none in
// cl_quick), and starts a sign-in, a renew or a sign-out on it. Every tool it uses is in AuthTools, so an app passes its own
// (cl_audit its FolderGuard, bounded reader and Keychain reader) and the checks pass fakes.

import Foundation
import ProfileCore
import Runs

/// The tools an authenticator works with. `system` is the real Mac's, without a stored sign-in reader (Keychain.swift adds
/// `systemWithKeychain` where it is compiled in).
public struct AuthTools {
    /// Reads the folder's stored sign-in (StoredSignIn.swift); nil: this app never reads it (cl_quick).
    public var stored: StoredSignInReader?
    /// Runs `claude` (AuthRun.Runner).
    public var run: AuthRun.Runner
    /// Opens a sign-in script in Terminal: true when it opened.
    public var openTerminal: (URL) -> Bool
    /// Asked right before anything is started on the folder ("login", "renew", "logout"): false and nothing starts.
    /// Never makes the folder.
    public var mayLaunch: (_ what: String, _ folder: AuthFolder) -> Bool
    /// Reads a record file's oauthAccount block (bounded; never blocking on a FIFO).
    public var readRecord: (_ path: String) -> [String: Any]?
    /// The one folder reader the app shares (FolderRecordReader): when set, the record is read through it (one parse per
    /// write for every part of the app), and `readRecord` isn't asked.
    public var reader: FolderRecordReader?
    /// The environment `claude` runs are made from (AuthFolder.environment cleans it).
    public var environment: () -> [String: String]
    /// The user's account name, which Claude Code stores the Keychain item under.
    public var userName: String

    public init(stored: StoredSignInReader? = nil, run: @escaping AuthRun.Runner, openTerminal: @escaping (URL) -> Bool,
                mayLaunch: @escaping (String, AuthFolder) -> Bool, readRecord: @escaping (String) -> [String: Any]?,
                environment: @escaping () -> [String: String], userName: String) {
        self.stored = stored; self.run = run; self.openTerminal = openTerminal; self.mayLaunch = mayLaunch
        self.readRecord = readRecord; self.environment = environment; self.userName = userName
    }

    public static var system: AuthTools {
        AuthTools(stored: nil, run: AuthRun.system,
                  // `open` hands the script to Terminal and returns: a minute is plenty
                  openTerminal: { url in Runs.Runner.run(Program("/usr/bin/open", ["-a", "Terminal", url.path], timeout: 60))?.ok ?? false },
                  mayLaunch: { _, folder in folder.isReady },
                  readRecord: { RecordFile.oauthAccount($0) },
                  environment: { ProcessInfo.processInfo.environment },
                  userName: NSUserName())
    }
}

public struct Authenticator {
    public let folder: AuthFolder
    public var tools: AuthTools

    public init(_ folder: AuthFolder, tools: AuthTools = .system) { self.folder = folder; self.tools = tools }

    // MARK: who

    /// The account the folder's record names now (guessed), or nil when it names nobody.
    public func record() -> SignedInAccount? {
        if let reader = tools.reader { return reader.look(folder).account }
        return SignedInAccount.record(tools.readRecord(folder.recordPath))
    }

    /// The one answer: the record, with a verified word where the caller has one (a running claude's `initialize`
    /// account, or Anthropic's reply about the folder's sign-in).
    public func signIn(verified: SignedInAccount? = nil) -> FolderSignIn {
        FolderSignIn.answer(record: record(), verified: verified)
    }

    /// The one answer with a running claude's trail: its word over the record, and whose its numbers are.
    public func signIn(trail: ProcessTrail) -> FolderSignIn { FolderSignIn.answer(record: record(), trail: trail) }

    /// The record's stamp, for SignInChangeWatch.look.
    public func recordStamp() -> RecordStamp { RecordStamp.of(folder.recordPath) }

    // MARK: the stored sign-in

    /// The folder's stored sign-in, through the app's reader (cl_audit: its Keychain item, Keychain.swift; blocks up to
    /// 30 s on a locked Keychain: off the main thread). nil when the app passes no reader (cl_quick never reads it).
    public func readSignIn() -> Login? { tools.stored?.read(folder, user: tools.userName) }

    // MARK: runs

    public enum Outcome: Equatable {
        case done
        /// The folder isn't there as a plain folder (or the app's guard said no): nothing started.
        case folderNotReady
        /// The folder is signed in to another account than the one asked for: nothing started.
        case otherAccount
        /// It ran (or tried to) and didn't end well, or the script couldn't be written or opened.
        case failed
    }

    /// Starts Claude Code's own sign-in in Terminal on the folder, with `email` filled in (`claude auth login --email`).
    /// The script is written to `script` (owner only) and opened; `marker`, `shown`, `done`, `failed` go into it
    /// (SignInScript.lines; `watch` too, for ClaudeSignIn). Never on a folder that isn't there: a new folder is made by the
    /// app first.
    public func startSignIn(claude: String, email: String?, script: URL, marker: URL? = nil, removesItself: Bool = false,
                            shown: String? = nil, done: String = SignInScript.doneWords,
                            failed: String = SignInScript.failedWords, watch: SignInScript.Watch? = nil) -> Outcome {
        guard tools.mayLaunch("login", folder) else { return .folderNotReady }
        let lines = SignInScript.lines(claude: claude, folder: folder, email: email, marker: marker, removesItself: removesItself,
                                       shown: shown, done: done, failed: failed, watch: watch)
        guard SignInScript.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: script) else { return .failed }
        return tools.openTerminal(script) ? .done : .failed
    }

    /// Renews the sign-in: Claude Code run once on the folder (AuthRun.renewArguments), which swaps its access key as part
    /// of the call. `expecting`: the account the folder should be signed in to; unless its record names that account
    /// (another one, or nobody, or a record that can't be read), nothing runs: never another account's sign-in renewed
    /// in its name. Blocks up to 2 minutes: off the main thread.
    public func renew(claude: String, expecting: SignedInAccount? = nil) -> Outcome {
        guard tools.mayLaunch("renew", folder) else { return .folderNotReady }
        // the same seat, not the address alone (a personal plan and a team seat can share one)
        if let expecting { guard let now = record(), now.match(expecting) == .seat else { return .otherAccount } }
        return tools.run(AuthRun.renewCommand(claude, folder, base: tools.environment())) == 0 ? .done : .failed
    }

    /// Signs the folder out with Claude Code's own `claude auth logout` (which removes its Keychain item). Blocks: off
    /// the main thread.
    public func signOut(claude: String) -> Outcome {
        guard tools.mayLaunch("logout", folder) else { return .folderNotReady }
        return tools.run(AuthRun.signOutCommand(claude, folder, base: tools.environment())) == 0 ? .done : .failed
    }
}

/// A record file read safely: a regular file only (a FIFO or a device returns at once), at most `max` bytes.
public enum RecordFile {
    /// Claude Code's .claude.json can be large (projects, history): read up to 64 MB.
    public static let max = 64 << 20

    public static func oauthAccount(_ path: String, max: Int = max) -> [String: Any]? {
        guard let data = read(path, max: max),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return j["oauthAccount"] as? [String: Any]
    }

    static func read(_ path: String, max: Int) -> Data? {
        // a regular file before it is opened (opening a device can do something), and the same file once it is
        var before = stat()
        guard stat(path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_dev == before.st_dev, st.st_ino == before.st_ino,
              st.st_size <= off_t(max) else { return nil }
        guard let data = try? h.read(upToCount: max + 1), data.count <= max else { return nil }
        return data
    }
}
