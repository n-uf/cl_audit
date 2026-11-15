// ClaudeAuth · the runs: Claude Code's own sign-in in Terminal (`claude auth login`), renew (one "Reply with OK." on
// Haiku, nothing saved, so Claude Code swaps its access key), and sign-out (`claude auth logout`, which removes the
// folder's Keychain item itself). Each runs `claude` on the one folder only (AuthFolder.environment) and only when the
// folder is there (never made here). Nothing here sees a password or a token.

import Foundation
import Runs

/// One `claude` run, as the runner gets it (the checks record it and run nothing).
public struct ClaudeCommand: Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Stopped after this many seconds (then the run failed).
    public var timeout: TimeInterval

    public init(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.timeout = timeout
    }
}

public enum AuthRun {
    /// Runs a command: its exit status, or nil when it couldn't start or ran out of time. Blocks: call off the main thread.
    public typealias Runner = (ClaudeCommand) -> Int32?

    /// The renew run's arguments: a one-line prompt on Haiku, no session kept.
    public static let renewArguments = ["-p", "Reply with OK.", "--model", "haiku", "--no-session-persistence"]
    public static let signOutArguments = ["auth", "logout"]

    public static func renewCommand(_ claude: String, _ folder: AuthFolder, base: [String: String]) -> ClaudeCommand {
        ClaudeCommand(executable: claude, arguments: renewArguments, environment: folder.environment(base), timeout: 120)
    }

    public static func signOutCommand(_ claude: String, _ folder: AuthFolder, base: [String: String]) -> ClaudeCommand {
        ClaudeCommand(executable: claude, arguments: signOutArguments, environment: folder.environment(base), timeout: 120)
    }

    /// The real runner (Runs' Runner): in the temporary folder, no input, output dropped, in a process group of its own
    /// (`ownGroup`): past the command's timeout the whole group is asked to end, then killed after 5 seconds, so what `claude`
    /// started in it (a hook, an MCP server, a shell tool) goes with it. A normal end leaves the group alone
    /// (`killGroupOnEnd` false): whatever Claude Code leaves running then (an updater, say) is its own business.
    public static func system(_ c: ClaudeCommand) -> Int32? {
        Runs.Runner.run(Program(c.executable, c.arguments, environment: c.environment, timeout: c.timeout, grace: 5, ownGroup: true,
                                killGroupOnEnd: false))?.status
    }

    /// Waits for a process to end without running the run loop (Runs' Runner.waitQuietly).
    static func waitQuietly(_ p: Process) { Runs.Runner.waitQuietly(p) }

    /// Stops a process that ran out of time (Runs' Runner.stop: SIGTERM, `grace` seconds, SIGKILL, waited for).
    static func stop(_ p: Process, grace: TimeInterval = 5) { Runs.Runner.stop(p, grace: grace) }
}

/// The Terminal script of a sign-in: Claude Code's own `claude auth login` for the folder, with an address filled in.
/// The person signs in in the browser.
public enum SignInScript {
    /// Line by line. The default folder runs with CLAUDE_CONFIG_DIR UNSET (also against one the login shell exports), any
    /// other with it set; a key or another provider from the login shell's own settings is unset first.
    /// `marker`: a file the script makes when the login ends well (exit 0), for a sign-in again on the account already
    /// in use, where the record doesn't change and so says nothing. `removesItself`: the script deletes its own file
    /// first (it holds the address; zsh keeps reading the file it opened).
    /// `shown`: the folder as the first line names it (cl_audit writes ~); `done`, `failed`: the app's own last line.
    public static func lines(claude: String, folder: AuthFolder, email: String?, marker: URL? = nil, removesItself: Bool = false,
                             shown: String? = nil, done: String = doneWords, failed: String = failedWords) -> [String] {
        var lines = ["#!/bin/zsh -l"]
        if removesItself { lines.append("rm -f -- \"$0\"") }
        lines.append("clear")
        lines.append("unset " + AuthFolder.providerVariables.joined(separator: " "))
        lines.append(folder.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(q(folder.path))")
        // print -r: zsh's echo would take a backslash in a path for an escape
        lines.append("print -r -- \(q("Signing in to Claude Code for \(shown ?? folder.path)…"))")
        var cmd = "\(q(claude)) auth login --claudeai"
        if let email, !email.isEmpty { cmd += " --email \(q(email))" }
        lines += [cmd, "s=$?"]
        if let marker { lines.append("if [ $s -eq 0 ]; then : > \(q(marker.path)); fi") }
        lines += ["echo",
                  "if [ $s -eq 0 ]; then print -r -- \(q(done)); else print -r -- \(q(failed)); fi"]
        return lines
    }

    public static let doneWords = "Done. The new sign-in is picked up by itself within seconds."
    public static let failedWords = "The sign-in did not finish. Close this window and try again."

    /// A shell word: in single quotes, any single quote in it closed, escaped and opened again.
    public static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
