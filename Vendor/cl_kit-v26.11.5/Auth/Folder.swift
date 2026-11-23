// ClaudeAuth · the folder: one Claude Code folder, the one a profile signs in. Where its sign-in record and its Keychain
// item are, and the environment that runs `claude` on it (and on nothing else).
//
// ClaudeAuth owns the Claude Code sign-in of a profile's ONE folder: its Keychain item's name, reading that item (named
// fields only), the watch for a changed sign-in, starting a sign-in, renew and sign-out, and the one answer "which
// account is this folder signed in to, verified or guessed". It sits beside ProfileCore (Core/), above it: it may use
// Process and the Keychain tool, ProfileCore never does and never imports it. No app's screens, words or global state:
// every tool is a parameter (AuthTools), so cl_audit and cl_quick can both build it, and the checks run it with fakes.
//
// One profile, one folder: nothing here makes a second or hidden Claude Code folder, and nothing copies or moves a
// sign-in or a Keychain item from one folder to another. A token is never printed, logged, kept on disk or returned
// beyond the Login it was read into.

import CryptoKit
import Foundation
import Runs

/// One Claude Code folder, as `claude` is pointed at it: the default one (~/.claude, run with CLAUDE_CONFIG_DIR unset) or
/// any other (run with CLAUDE_CONFIG_DIR set to `path`).
public struct AuthFolder: Equatable, Hashable {
    /// The folder's path, expanded (no ~), as CLAUDE_CONFIG_DIR is set to it: the Keychain item's name is made from it.
    public let path: String
    /// Claude Code's default folder: run with CLAUDE_CONFIG_DIR UNSET. Set to ~/.claude, Claude Code takes it for a custom
    /// folder (its record inside the folder, its Keychain item with a hash), which is not the default folder's sign-in.
    public let isDefault: Bool
    /// The home folder the default folder and its record are in (a parameter, so the checks use a throwaway home).
    public let home: String

    /// `isDefault`: the app's own answer where it has one (cl_audit's FolderKey); else the rule below.
    public init(path: String, isDefault: Bool? = nil, home: String = NSHomeDirectory()) {
        self.home = home
        self.path = Self.expand(path, home: home)
        self.isDefault = isDefault ?? Self.isDefault(path, home: home)
    }

    /// The default folder however it is spelled: ~ or the full path, a trailing slash, a link to it, another case (the
    /// disk ignores case). The same rule as cl_audit's FolderKey.canonical.
    public static func isDefault(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        canonical(path, home: home) == canonical(home + "/.claude", home: home)
    }

    static func canonical(_ path: String, home: String) -> String {
        var p = URL(fileURLWithPath: expand(path, home: home)).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.lowercased()
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    // MARK: the sign-in record

    /// The file where Claude Code records which account the folder is signed in to (oauthAccount): the default folder
    /// keeps it in the home folder (~/.claude.json), any other inside the folder.
    public var recordPath: String {
        isDefault ? (home as NSString).appendingPathComponent(".claude.json") : (path as NSString).appendingPathComponent(".claude.json")
    }

    // MARK: the Keychain item

    /// The Keychain item (a generic password's service) Claude Code keeps the folder's sign-in in: "Claude Code-credentials"
    /// for the default folder, else that name, "-" and the first 8 hex characters of the SHA-256 of CLAUDE_CONFIG_DIR as
    /// it was set. The folder's own name comes first; the second spelling is the path with a trailing slash, which a
    /// folder set up that way was signed in under.
    public var keychainItems: [String] {
        if isDefault { return [Self.keychainBase] }
        return [path, path + "/"].map { Self.keychainBase + "-" + Self.sha8($0) }
    }

    /// The folder's own item name (the first of `keychainItems`): named only, for words like "Claude Code keeps it in
    /// your Keychain as …".
    public var keychainItem: String { keychainItems[0] }

    public static let keychainBase = "Claude Code-credentials"

    /// The first 8 hex characters of a text's SHA-256.
    public static func sha8(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: running claude on it

    /// The variables that would make Claude Code use a key, a token or another provider instead of the folder's claude.ai
    /// sign-in, or send it to another host (a base URL, extra headers): never passed on to a `claude` run here (Runs'
    /// ProviderEnvironment, the one list).
    public static var providerVariables: [String] { ProviderEnvironment.variables }

    /// The environment a `claude` run on this folder gets: Runs' one allow-list (ClaudeEnvironment: who and where the user
    /// is, the language, the network's proxies and certificates; never a key, a token, another provider or anything else of
    /// the caller's), CLAUDE_CONFIG_DIR set to this folder unless it is the default one, `claude`'s own folder (when given)
    /// and the usual install places first on PATH, Claude Code's non-essential traffic off.
    public func environment(_ base: [String: String], claude: String? = nil, traceless: Bool = false) -> [String: String] {
        ClaudeEnvironment.make(base, claude: claude, configDir: isDefault ? nil : path, traceless: traceless)
    }

    /// The folder is there to run `claude` on: the default one always; any other only as a plain folder, never a link.
    /// Never makes it: Claude Code would make a folder that isn't there again, signed in, and a folder the person deleted
    /// would come back. (cl_audit passes its FolderGuard instead, which says the same and logs.)
    public var isReady: Bool {
        if isDefault { return true }
        // lstat follows a link named with a trailing slash ("link/"): looked at without it
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        var st = stat()
        return lstat(p, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}
