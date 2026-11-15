// ClaudeAuth · the authenticator: one folder's sign-in, behind one type. It answers which account the folder is signed in
// to (verified or guessed), reads its Keychain item, and starts a sign-in, a renew or a sign-out on it. Every tool it
// uses is in AuthTools, so an app passes its own (cl_audit its FolderGuard and bounded reader) and the checks pass fakes.

import Foundation
import ProfileCore
import Runs

/// The tools an authenticator works with. `system` is the real Mac's.
public struct AuthTools {
    /// Runs `security` (KeychainSignIn.Tool).
    public var security: KeychainSignIn.Tool
    /// Runs `claude` (AuthRun.Runner).
    public var run: AuthRun.Runner
    /// Opens a sign-in script in Terminal: true when it opened.
    public var openTerminal: (URL) -> Bool
    /// Asked right before anything is started on the folder ("login", "renew", "logout"): false and nothing starts.
    /// Never makes the folder.
    public var mayLaunch: (_ what: String, _ folder: AuthFolder) -> Bool
    /// Reads a record file's oauthAccount block (bounded; never blocking on a FIFO).
    public var readRecord: (_ path: String) -> [String: Any]?
    /// The environment `claude` runs are made from (AuthFolder.environment cleans it).
    public var environment: () -> [String: String]
    /// The user's account name, which Claude Code stores the Keychain item under.
    public var userName: String

    public init(security: @escaping KeychainSignIn.Tool, run: @escaping AuthRun.Runner, openTerminal: @escaping (URL) -> Bool,
                mayLaunch: @escaping (String, AuthFolder) -> Bool, readRecord: @escaping (String) -> [String: Any]?,
                environment: @escaping () -> [String: String], userName: String) {
        self.security = security; self.run = run; self.openTerminal = openTerminal; self.mayLaunch = mayLaunch
        self.readRecord = readRecord; self.environment = environment; self.userName = userName
    }

    public static var system: AuthTools {
        AuthTools(security: KeychainSignIn.system, run: AuthRun.system,
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
    public func record() -> SignedInAccount? { SignedInAccount.record(tools.readRecord(folder.recordPath)) }

    /// The one answer: the record, with a verified word where the caller has one (a running claude's `initialize`
    /// account, or Anthropic's reply about the folder's sign-in).
    public func signIn(verified: SignedInAccount? = nil) -> FolderSignIn {
        FolderSignIn.answer(record: record(), verified: verified)
    }

    /// The record's stamp, for SignInChangeWatch.look.
    public func recordStamp() -> RecordStamp { RecordStamp.of(folder.recordPath) }

    // MARK: the Keychain item

    /// The folder's sign-in from its Keychain item (KeychainSignIn.read). Blocks up to 30 s on a locked Keychain: off the
    /// main thread.
    public func readSignIn() -> Login { KeychainSignIn.read(folder, user: tools.userName, tool: tools.security) }

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
    /// (SignInScript.lines). Never on a folder that isn't there: a new folder is made by the app first.
    public func startSignIn(claude: String, email: String?, script: URL, marker: URL? = nil, removesItself: Bool = false,
                            shown: String? = nil, done: String = SignInScript.doneWords,
                            failed: String = SignInScript.failedWords) -> Outcome {
        guard tools.mayLaunch("login", folder) else { return .folderNotReady }
        let lines = SignInScript.lines(claude: claude, folder: folder, email: email, marker: marker, removesItself: removesItself,
                                       shown: shown, done: done, failed: failed)
        // owner only from the start (it holds the address): made new, 0700, never through a link; one left from before
        // is removed first (removeItem doesn't follow a link at the end)
        try? FileManager.default.removeItem(at: script)
        let fd = open(script.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o700)
        guard fd >= 0 else { return .failed }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fchmod(fd, 0o700) == 0, (try? h.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))) != nil,
              (try? h.close()) != nil else { return .failed }
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
