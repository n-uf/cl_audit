// ClaudeAuth · the Keychain item: the folder's sign-in, read with Apple's `security` tool the way Claude Code reads it.
// Claude Code stores the item through that tool, so the item already trusts it: no prompt, and no new Keychain
// permission for the app (reading it through the Keychain API needs "Always Allow", which is lost every time Claude Code
// saves a renewed sign-in). Read only: never written, copied, moved or deleted here (sign-out is Claude Code's own
// `claude auth logout`). The text read stays in memory: only Login's named fields come out (ProfileCore's Login.parse),
// and nothing of it is printed or logged.
//
// The one file of ClaudeAuth that touches the Keychain: an app that never reads it (cl_quick) leaves this file out of its
// build, and ClaudeAuth reaches the store only through StoredSignInReader (StoredSignIn.swift), which cl_audit wires to
// `KeychainSignInReader` here (`AuthTools.systemWithKeychain`).

import Foundation
import ProfileCore
import Runs

/// The Keychain as the stored sign-in (StoredSignIn.swift): `security` run by `tool` (the checks pass a fake).
public struct KeychainSignInReader: StoredSignInReader {
    public var tool: KeychainSignIn.Tool
    public init(tool: @escaping KeychainSignIn.Tool = KeychainSignIn.system) { self.tool = tool }
    public func read(_ folder: AuthFolder, user: String) -> Login { KeychainSignIn.read(folder, user: user, tool: tool) }
}

extension AuthTools {
    /// The real Mac's tools with the Keychain reader (cl_audit's).
    public static var systemWithKeychain: AuthTools {
        var t = AuthTools.system
        t.stored = KeychainSignInReader()
        return t
    }
}

public enum KeychainSignIn {
    /// What runs `security`: arguments in, exit status and output out. The checks pass a fake (no real Keychain).
    public typealias Tool = ([String]) -> (status: Int32, output: Data)

    /// `security`'s exit status for "no such item".
    public static let notFoundStatus: Int32 = 44

    /// The folder's sign-in: a token (with its expiry and plan), no item at all (`.notFound`), an item refused or that
    /// timed out (`.denied`), or an item whose text isn't a sign-in in a known form (`.unreadable`). Each item name the
    /// folder may have (AuthFolder.keychainItems), first under the user's own account name, then under any.
    public static func read(_ folder: AuthFolder, user: String = NSUserName(), tool: Tool = system) -> Login {
        for service in folder.keychainItems {
            for account in [user as String?, nil] {
                var args = ["find-generic-password", "-s", service, "-w"]
                if let account { args += ["-a", account] }
                let (status, out) = tool(args)
                if status == notFoundStatus { continue }
                if status != 0 { return .denied }
                return Login.parse(out)
            }
        }
        return .notFound
    }

    /// The real tool: /usr/bin/security, its output kept in memory only; a locked Keychain can keep it waiting, so after
    /// `timeout` seconds it is stopped and the read counts as refused.
    public static func system(_ args: [String]) -> (status: Int32, output: Data) { run(args, timeout: 30) }

    /// `executable`: the checks run a stand-in (the timeout with /bin/sleep); the app, `security` only.
    /// Through Runs' Runner (its output read while it runs, kept in memory only): stopped by the timeout, ended by a signal,
    /// or a text not read whole (never a cut-short sign-in taken for one), it is refused (-1) whatever it printed.
    static func run(_ args: [String], timeout: TimeInterval, executable: String = "/usr/bin/security") -> (status: Int32, output: Data) {
        guard let r = Runner.run(Program(executable, args, timeout: timeout, grace: 5, keepOutput: true, outputCap: 4 << 20, drain: 10)),
              !r.signaled, r.complete else { return (-1, Data()) }
        return (r.status, r.output)
    }
}
