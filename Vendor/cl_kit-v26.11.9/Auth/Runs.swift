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
        ClaudeCommand(executable: claude, arguments: renewArguments, environment: folder.environment(base, claude: claude), timeout: 120)
    }

    public static func signOutCommand(_ claude: String, _ folder: AuthFolder, base: [String: String]) -> ClaudeCommand {
        ClaudeCommand(executable: claude, arguments: signOutArguments, environment: folder.environment(base, claude: claude), timeout: 120)
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
    /// `watch`: the script as ClaudeSignIn runs it (see Watch).
    public static func lines(claude: String, folder: AuthFolder, email: String?, marker: URL? = nil, removesItself: Bool = false,
                             shown: String? = nil, done: String = doneWords, failed: String = failedWords,
                             watch: Watch? = nil) -> [String] {
        var lines = ["#!/bin/zsh -l"]
        if removesItself { lines.append("rm -f -- \"$0\"") }
        if let watch {
            // asked to end (ClaudeSignIn's stop, timeout or next start; the window closed): a clean end, once the login it
            // waits for has ended, so a window set to close when the shell exits cleanly closes
            lines.append("trap 'exit 0' TERM HUP")
            lines.append("print -r -- $$ > \(q(watch.pid.path))")
        }
        lines.append("clear")
        lines.append("unset " + AuthFolder.providerVariables.joined(separator: " "))
        lines.append(folder.isDefault ? "unset CLAUDE_CONFIG_DIR" : "export CLAUDE_CONFIG_DIR=\(q(folder.path))")
        // print -r: zsh's echo would take a backslash in a path for an escape
        lines.append("print -r -- \(q("Signing in to Claude Code for \(shown ?? folder.path)…"))")
        var cmd = "\(q(claude)) auth login --claudeai"
        if let email, !email.isEmpty { cmd += " --email \(q(email))" }
        if let declined = watch?.declined {
            // Claude Code's errors go on to the window as they come (tee, byte by byte: a prompt without a line end shows at
            // once) and are looked through for the browser's refusal; only a mark is kept, never the text, made as soon as
            // the words come (a login may go on waiting after them); the rest is read to its end, so tee never stops. Its
            // output and its input stay the window's own.
            lines.append("exec 3>&1 4>&2")
            lines.append("\(cmd) 2>&1 1>&3 3>&- | tee /dev/fd/4 | { grep -F -m 1 -e \(q(Watch.declinedText)) >/dev/null && : > \(q(declined.path)); cat >/dev/null; }")
            lines.append("s=${pipestatus[1]}")
        } else {
            lines += [cmd, "s=$?"]
        }
        if let marker { lines.append("if [ $s -eq 0 ]; then : > \(q(marker.path)); fi") }
        if let watch { lines.append("print -r -- $s > \(q(watch.status.path))") }
        lines += ["echo",
                  "if [ $s -eq 0 ]; then print -r -- \(q(done)); else print -r -- \(q(failed)); fi"]
        if watch != nil {
            // a sign-in that didn't end well stays on screen to be read, until Return or the next start or stop (trap)
            lines += ["if [ $s -ne 0 ]; then read -r; fi", "exit 0"]
        }
        return lines
    }

    /// The files of a sign-in that ClaudeSignIn follows: the script's own pid (written first: ClaudeSignIn ends it, and its
    /// window with it), the login's exit status (written when it ends), and a mark made when Claude Code says the person
    /// declined in the browser. With it, the script ends cleanly (0) when it is asked to end or after a login that ended
    /// well, and stays open after one that didn't.
    public struct Watch: Equatable {
        public var pid: URL
        public var status: URL
        /// nil: Claude Code's errors aren't looked through (they go straight to the window).
        public var declined: URL?

        public init(pid: URL, status: URL, declined: URL? = nil) { self.pid = pid; self.status = status; self.declined = declined }

        /// What Claude Code 2.1.318 says when the browser's sign-in was refused ("OAuth error: access_denied", its own
        /// pattern for that refusal).
        public static let declinedText = "OAuth error: access_denied"
    }

    /// Writes a file that holds an address or a command: made new, owner only (`mode`: 0700 for a script that runs, 0600 for
    /// one that is only read) from the start, never through a link; one left from before is removed first (removeItem doesn't
    /// follow a link at the end). False when it couldn't be.
    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o700) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { return false }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return fchmod(fd, mode) == 0 && (try? h.write(contentsOf: data)) != nil && (try? h.close()) != nil
    }

    public static let doneWords = "Done. The new sign-in is picked up by itself within seconds."
    public static let failedWords = "The sign-in did not finish. Close this window and try again."

    /// A shell word: in single quotes, any single quote in it closed, escaped and opened again.
    public static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
