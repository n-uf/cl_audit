// Runs · the claude finder: where Claude Code (`claude`) is on this Mac. Claude Code is installed in several ways (the native
// installer, Homebrew, npm with its own prefix, nvm, bun, Volta), and the Claude desktop app carries a copy of its own. The
// finder looks in all of them, in one fixed order, and a real install always wins over the desktop app's copy. Every look at
// the Mac is a closure in `Lookup`, so the checks run with `claude` nowhere, or at a stand-in; the kit keeps no state of its
// own (a caller that caches the answer keeps it itself).

import Foundation

/// The `claude` found, and whether it is the desktop app's own copy.
public struct ClaudeFound: Equatable {
    public var path: String
    public var fromApp: Bool

    public init(path: String, fromApp: Bool = false) { self.path = path; self.fromApp = fromApp }
}

public enum ClaudeFinder {
    /// Each way of looking.
    public struct Lookup {
        /// The usual places, in their order (`usualPlaces`): only looked at, never run.
        public var candidates: () -> [String]
        /// What the login shell finds (`zsh -lc 'command -v claude'`, with a time limit).
        public var shell: () -> String?
        /// Places tried after the login shell: Volta, then nvm's node versions, newest first (`morePlaces`).
        public var more: () -> [String]
        /// The prefix `npm` installs globally to (`npm config get prefix`; nil: no npm).
        public var npmPrefix: () -> String?
        /// The desktop app's own copy.
        public var appCopy: () -> String?

        public init(candidates: @escaping () -> [String], shell: @escaping () -> String?, more: @escaping () -> [String] = { [] },
                    npmPrefix: @escaping () -> String?, appCopy: @escaping () -> String?) {
            self.candidates = candidates; self.shell = shell; self.more = more; self.npmPrefix = npmPrefix; self.appCopy = appCopy
        }

        /// This Mac's: the user's home folder, the caller's environment (cleaned) for the shell and npm.
        public static func real(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment)
            -> Lookup {
            Lookup(candidates: { ClaudeFinder.usualPlaces(home: home) },
                   shell: { ClaudeFinder.shellLookup(environment: environment) },
                   more: { ClaudeFinder.morePlaces(home: home) },
                   npmPrefix: { ClaudeFinder.npmPrefix(home: home, environment: environment) },
                   appCopy: { ClaudeFinder.appCopy(support: (home as NSString).appendingPathComponent("Library/Application Support")) })
        }
    }

    /// The first `claude` found, or nil, in this order: the usual places, the login shell, Volta, nvm, npm's prefix, and last
    /// the desktop app's own copy. `quick`: only the usual places (file lookups, no process run): what it returns is always
    /// what the full look would return too, and it never returns the app's copy. The full look runs programs (the login
    /// shell, npm): off the main thread.
    public static func find(quick: Bool = false, lookup: Lookup = .real()) -> ClaudeFound? {
        if let p = lookup.candidates().first(where: isExecutable) { return ClaudeFound(path: p) }
        if quick { return nil }
        if let p = lookup.shell(), isExecutable(p) { return ClaudeFound(path: p) }
        if let p = lookup.more().first(where: isExecutable) { return ClaudeFound(path: p) }
        if let prefix = lookup.npmPrefix() {
            let p = (prefix as NSString).appendingPathComponent("bin/claude")
            if isExecutable(p) { return ClaudeFound(path: p) }
        }
        if let p = lookup.appCopy(), isExecutable(p) { return ClaudeFound(path: p, fromApp: true) }
        return nil
    }

    /// A full path to a file (not a folder) this user may run.
    public static func isExecutable(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: the places

    /// Homebrew, /usr/local, ~/.local/bin (the native installer), ~/.claude/local, ~/.npm-global, ~/.bun, in that order.
    /// Never reordered: a Mac where an app found a `claude` before finds the same one.
    public static func usualPlaces(home: String) -> [String] {
        func at(_ rel: String) -> String { (home as NSString).appendingPathComponent(rel) }
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", at(".local/bin/claude"), at(".claude/local/claude"),
                at(".npm-global/bin/claude"), at(".bun/bin/claude")]
    }

    /// Tried only after the login shell: Volta, then nvm's node versions, newest first.
    public static func morePlaces(home: String) -> [String] {
        [(home as NSString).appendingPathComponent(".volta/bin/claude")]
            + nvmNodeBins(home: home).map { ($0 as NSString).appendingPathComponent("claude") }
    }

    /// ~/.nvm/versions/node/<version>/bin, newest version first.
    public static func nvmNodeBins(home: String) -> [String] {
        let root = (home as NSString).appendingPathComponent(".nvm/versions/node")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names.sorted { newer($0, than: $1) }.map { (root as NSString).appendingPathComponent($0 + "/bin") }
    }

    /// "v22.1.0" is newer than "v9.11.2": by number, not by letters.
    public static func newer(_ a: String, than b: String) -> Bool {
        let x = numbers(a), y = numbers(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return a > b
    }

    static func numbers(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }

    /// The prefix npm installs global packages to, from `npm config get prefix`, when an npm can be found (Homebrew's,
    /// /usr/local's, nvm's newest, Volta's); its own folder goes first on the PATH so its `node` is found.
    public static func npmPrefix(home: String, environment: [String: String], timeout: TimeInterval = 5) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + nvmNodeBins(home: home) + [(home as NSString).appendingPathComponent(".volta/bin")]
        dirs = dirs.filter { isExecutable(($0 as NSString).appendingPathComponent("npm")) }
        guard let dir = dirs.first else { return nil }
        let out = output((dir as NSString).appendingPathComponent("npm"), ["config", "get", "prefix"],
                         environment: lookupEnvironment(environment, path: dir), timeout: timeout)
        guard let line = out?.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }), line.hasPrefix("/") else { return nil }
        return line
    }

    /// What the login shell says `claude` is (an alias or a function says nothing usable). Slow rc files can't hang it, and
    /// rc files that print a lot can't block it (Runner reads while it runs).
    public static func shellLookup(environment: [String: String], timeout: TimeInterval = 5) -> String? {
        let out = output("/bin/zsh", ["-lc", "command -v claude"], environment: lookupEnvironment(environment, path: nil), timeout: timeout)
        return out?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last(where: { $0.hasPrefix("/") })
    }

    // MARK: the desktop app's own copy

    /// The newest copy of Claude Code the desktop app downloaded:
    /// <support>/Claude*/claude-code/<version>/<id>/claude.app/Contents/MacOS/claude. A copy whose download is marked finished
    /// (a `.verified` file next to or in its folder) comes before one that isn't, newest version first; only a Mach-O
    /// program counts (never a script or a half-written file).
    public static func appCopy(support: String) -> String? {
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

    /// The file starts like a program for this Mac.
    public static func isMachO(_ path: String) -> Bool {
        guard let h = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4), head.count == 4 else { return false }
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF], [0xFE, 0xED, 0xFA, 0xCE],
                [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains([UInt8](head))
    }

    // MARK: its version

    /// "2.1.211" from `claude --version` ("2.1.211 (Claude Code)"); nil when it doesn't answer in time. Runs the program
    /// found: blocks, off the main thread.
    public static func version(of path: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                               timeout: TimeInterval = 5) -> String? {
        guard let out = output(path, ["--version"], environment: lookupEnvironment(environment, path: nil), timeout: timeout) else { return nil }
        for word in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) where word.first?.isNumber == true && word.contains(".") {
            return String(word)
        }
        return nil
    }

    /// The environment the finder's programs run with: no key, token or other provider (ProviderEnvironment), `path` first
    /// on PATH.
    static func lookupEnvironment(_ base: [String: String], path: String?) -> [String: String] {
        var env = ProviderEnvironment.cleaned(base)
        // absolute entries only, never a trailing ":" (the current folder) when the caller has no PATH
        if let path { env["PATH"] = ClaudeEnvironment.path([path, "/usr/bin", "/bin"], then: env["PATH"]) }
        return env
    }

    /// What a finder's program printed, when it ended well and its output came whole (never a part cut at the cap).
    static func output(_ exe: String, _ args: [String], environment: [String: String], timeout: TimeInterval) -> String? {
        guard let r = Runner.run(Program(exe, args, environment: environment, timeout: timeout, grace: 0.1, keepOutput: true)),
              r.status == 0, r.complete else { return nil }
        return String(data: r.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
