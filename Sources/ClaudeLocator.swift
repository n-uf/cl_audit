// ClaudeLocator: where Claude Code (`claude`) is on this Mac, and the words for when it isn't.
//
// Claude Code is installed in several ways (the native installer, Homebrew, npm with its own prefix, nvm, bun, Volta),
// and the Claude app carries a copy of its own. cl_audit looks in all of them, in this order, and keeps looking: the
// window asks again whenever it comes to the front, on "Check again", every few seconds while a "not installed" note
// shows, and before any sign-in (SettingsModel.detectClaude / claudeNow). A real install always wins over the app's copy.
//
// Everything that touches the Mac is a closure in `Lookup`, so the checks can run with `claude` nowhere, or at a stub.

import AppKit

/// The `claude` found, and whether it is the Claude app's own copy (said on the first-run page).
struct ClaudeFound: Equatable {
    var path: String
    var fromApp = false
}

enum ClaudeLocator {
    /// Each way of looking, so the checks can replace them.
    struct Lookup {
        /// Files to try in order (the usual install places, nvm's newest first). Only looked at, never run.
        var candidates: () -> [String]
        /// The prefix `npm` installs globally to (runs `npm config get prefix`; nil: no npm).
        var npmPrefix: () -> String?
        /// What the login shell finds (`zsh -lc 'command -v claude'`, with a time limit).
        var shell: () -> String?
        /// The Claude app's own copy.
        var appCopy: () -> String?

        static let real = Lookup(candidates: { ClaudeLocator.realCandidates(home: NSHomeDirectory()) },
                                 npmPrefix: { ClaudeLocator.npmPrefix(home: NSHomeDirectory()) },
                                 shell: { ClaudeLocator.shellLookup() },
                                 appCopy: { ClaudeLocator.appCopy(support: expand("~/Library/Application Support")) })
    }

    /// Replaced by the checks; the app always uses `.real`.
    static var current = Lookup.real

    /// The first `claude` found, or nil. `quick`: only the file lookups (no process is run), for the first paint and for
    /// "before a sign-in"; a full look is done off the main thread.
    static func find(quick: Bool = false, lookup: Lookup? = nil) -> ClaudeFound? {
        let l = lookup ?? current
        if let p = l.candidates().first(where: isExecutable) { return ClaudeFound(path: p) }
        if !quick {
            if let prefix = l.npmPrefix() {
                let p = (prefix as NSString).appendingPathComponent("bin/claude")
                if isExecutable(p) { return ClaudeFound(path: p) }
            }
            if let p = l.shell(), isExecutable(p) { return ClaudeFound(path: p) }
        }
        if let p = l.appCopy(), isExecutable(p) { return ClaudeFound(path: p, fromApp: true) }
        return nil
    }

    static func isExecutable(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: the usual places

    /// ~/.local/bin (the native installer), ~/.claude/local, Homebrew, /usr/local, npm's ~/.npm-global, bun, Volta, then
    /// nvm's node versions, newest first.
    static func realCandidates(home: String) -> [String] {
        func at(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
        var out = [at(".local/bin/claude"), at(".claude/local/claude"), "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                   at(".npm-global/bin/claude"), at(".bun/bin/claude"), at(".volta/bin/claude")]
        out += nvmNodeBins(home: home).map { ($0 as NSString).appendingPathComponent("claude") }
        return out
    }

    /// ~/.nvm/versions/node/<version>/bin, newest version first.
    static func nvmNodeBins(home: String) -> [String] {
        let root = (home as NSString).appendingPathComponent(".nvm/versions/node")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted { newer($0, than: $1) }.map { (root as NSString).appendingPathComponent($0 + "/bin") }
    }

    /// "v22.1.0" is newer than "v9.11.2": by number, not by letters.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return a > b
    }

    static func numbers(_ s: String) -> [Int] {
        s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// The prefix npm installs global packages to, from `npm config get prefix`, when an npm can be found (Homebrew's,
    /// /usr/local's, nvm's newest, Volta's); its own folder is put first on the PATH so its `node` is found.
    static func npmPrefix(home: String, timeout: TimeInterval = 5) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + nvmNodeBins(home: home) + [(home as NSString).appendingPathComponent(".volta/bin")]
        dirs = dirs.filter { isExecutable(($0 as NSString).appendingPathComponent("npm")) }
        guard let dir = dirs.first else { return nil }
        let out = run((dir as NSString).appendingPathComponent("npm"), ["config", "get", "prefix"], path: dir, timeout: timeout)
        guard let line = out?.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }), line.hasPrefix("/") else { return nil }
        return line
    }

    /// What the login shell says `claude` is (an alias or a function says nothing usable). Slow rc files can't hang it.
    static func shellLookup(timeout: TimeInterval = 5) -> String? {
        let out = run("/bin/zsh", ["-lc", "command -v claude"], path: nil, timeout: timeout)
        return out?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { $0.hasPrefix("/") })
    }

    // MARK: the Claude app's own copy

    /// The newest copy of Claude Code the Claude app downloaded:
    /// ~/Library/Application Support/Claude*/claude-code/<version>/<id>/claude.app/Contents/MacOS/claude. A copy whose
    /// download is marked finished (a `.verified` file next to or in its folder) comes before one that isn't, newest
    /// version first; only a Mach-O program counts. The Claude app's Linux program (claude-code-vm) is another folder.
    static func appCopy(support: String) -> String? {
        let fm = FileManager.default
        func list(_ p: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted() }
        var found: [(version: String, marked: Bool, path: String)] = []
        for app in list(support) where app == "Claude" || app.hasPrefix("Claude-") {
            let base = (support as NSString).appendingPathComponent(app + "/claude-code")
            for v in list(base) where !v.hasPrefix(".") {
                let vdir = (base as NSString).appendingPathComponent(v)
                for id in list(vdir) where !id.hasPrefix(".") && !id.hasSuffix(".verified") {
                    let dir = (vdir as NSString).appendingPathComponent(id)
                    let bin = (dir as NSString).appendingPathComponent("claude.app/Contents/MacOS/claude")
                    guard isExecutable(bin), isMachO(bin) else { continue }
                    let marked = [dir + ".verified", (dir as NSString).appendingPathComponent(".verified"),
                                  (vdir as NSString).appendingPathComponent(".verified")].contains { fm.fileExists(atPath: $0) }
                    found.append((v, marked, bin))
                }
            }
        }
        let best = found.sorted { a, b in
            if a.marked != b.marked { return a.marked }
            if a.version != b.version { return newer(a.version, than: b.version) }
            return a.path < b.path
        }
        return best.first?.path
    }

    /// The file starts like a program for this Mac (not a script, not a half-written file).
    static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4), head.count == 4 else { return false }
        let magic = [UInt8](head)
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
                [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains(magic)
    }

    // MARK: version

    /// "2.1.211" from `claude --version` ("2.1.211 (Claude Code)"); nil when it doesn't answer in time. Blocks: call off
    /// the main thread.
    static func version(of path: String, timeout: TimeInterval = 5) -> String? {
        guard let out = run(path, ["--version"], path: nil, timeout: timeout) else { return nil }
        for word in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) where word.first?.isNumber == true && word.contains(".") {
            return String(word)
        }
        return nil
    }

    /// Runs a program and returns what it printed, or nil when it can't start, fails or takes longer than `timeout`
    /// (it is stopped then). Blocks.
    static func run(_ exe: String, _ args: [String], path: String?, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] { env[k] = nil }
        if let path { env["PATH"] = path + ":/usr/bin:/bin:" + (env["PATH"] ?? "") }
        p.environment = env
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); usleep(100_000); if p.isRunning { kill(p.processIdentifier, SIGKILL) }; return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The words and the install help

enum ClaudeInstall {
    /// Claude Code's own installer for macOS (code.claude.com/docs/en/setup).
    static let command = "curl -fsSL https://claude.ai/install.sh | bash"
    static let docs = URL(string: "https://code.claude.com/docs/en/setup")!

    /// The reason shown next to every sign-in key that needs Claude Code when it isn't there.
    static let missing = "Claude Code isn't installed on this Mac"
    static let missingInstall = missing + " · Install…"

    static func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// For places without a window of their own (a Dock icon's menu): says why and offers the command and the docs.
    static func showAlert() {
        guard Thread.isMainThread else { DispatchQueue.main.async { showAlert() }; return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = missing
        a.informativeText = "Signing in needs it. Paste this in Terminal, then try again:\n\n\(command)"
        a.addButton(withTitle: "Copy the command")
        a.addButton(withTitle: "Open the install page")
        a.addButton(withTitle: "Not now")
        switch a.runModal() {
        case .alertFirstButtonReturn: copyCommand()
        case .alertSecondButtonReturn: NSWorkspace.shared.open(docs)
        default: break
        }
    }
}
