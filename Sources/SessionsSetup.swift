// SessionsSetup: Claude Code's setup, the part of a profile's Claude Code folder (~/.claude, ~/.claude-<name>) that is the
// operator's own configuration rather than history, so that a move to another Mac, an export or a backup carries it:
//
//   CLAUDE.md                 and every .md file it pulls in with `@path` (recursively, 5 deep) that is a plain file inside the folder
//   skills/<name>/…           each skill is one unit: its whole folder
//   agents/…  commands/…  output-styles/…     each file is one unit
//   keybindings.json
//   settings.json             hooks, permissions, env, statusLine: SENSITIVE
//   <scripts>                 every file inside the folder that a command in settings.json points to: SENSITIVE
//   plugins/installed_plugins.json            the list of installed plugins (so Claude Code can reinstall them)
//   plugins/known_marketplaces.json           the marketplaces: SENSITIVE (it can hold addresses with credentials)
//
// Never: a sign-in (.claude.json*, .credentials*), settings.local.json (machine-local by Claude Code's own definition), plugin
// caches and repos (everything else under plugins/), projects/, todos/, statsig/, shell-snapshots/, ide/, a dot-file, version
// history and build leftovers (.git, .hg, .svn, node_modules, .venv, venv, __pycache__, .DS_Store, *.pyc: counted, not an error).
// A link is never followed: a skill that is one, or contains one anywhere, a link in place of CLAUDE.md, an agent, a command, an
// included file, or skills/ itself, is left out and listed (with where it points, on this Mac's page only: a target is never
// written into a file). What an `@` include or a hook script points to outside the folder is listed, not carried.
//
// "Sensitive" setup (settings.json, its scripts, the marketplaces) can hold tokens no key scan recognises: it travels only in the
// encrypted disk image; a zip leaves it out and says so.

import CryptoKit
import Foundation

enum Setup {
    enum Kind: String, Codable, CaseIterable {
        case claude, include, skill, agent, command, style, keybindings, settings, script, plugins, marketplaces
    }

    struct Unit: Hashable, Comparable {
        var kind: Kind
        var name: String                    // CLAUDE.md; the file's path (include, script, agent, command, style); the skill's folder name
        static func < (a: Unit, b: Unit) -> Bool { (a.kind.rawValue, a.name) < (b.kind.rawValue, b.name) }
        var sensitive: Bool { kind == .settings || kind == .script || kind == .marketplaces }
    }

    /// One file of the setup: where it is in the Claude Code folder, where it is now, how big, whether its owner-execute bit is set.
    struct FileRec: Equatable {
        var rel: String
        var src: String
        var bytes: Int64
        var exec: Bool
        var unit: Unit { Setup.unit(of: rel) }
    }

    /// Something left out because it is (or holds) a link: `target` is shown on this Mac's page only.
    struct Linked: Equatable {
        var label: String                   // "skill foo", "agents", "CLAUDE.md"
        var kind: Kind
        var target: String
    }

    struct Found {
        var files: [FileRec] = []
        var linked: [Linked] = []
        var outside: [String] = []          // "CLAUDE.md includes ~/x/y.md: outside ~/.claude, not carried", "hook script outside ~/.claude: ~/bin/foo.sh"
        var leftOutBuild = 0                // .git, node_modules, .DS_Store, *.pyc …
        var leftOutNames: [String] = []     // files with a sign-in name, left out one by one
        var cut: [String] = []              // folders a walk stopped in (too deep, too many files): their unit is left out whole
        /// The units holding a file settings.json's hooks or status line run, from the live settings.json (also a linked one, which
        /// isn't carried); nil: it couldn't be read.
        var hookUnits: Set<Unit>? = []
    }

    // MARK: what is where

    static let topFolders = ["skills", "agents", "commands", "output-styles"]
    /// Folders of the Claude Code folder that are history or machine state, never setup (for includes and scripts).
    static let neverFolders: Set<String> = ["projects", "todos", "plugins", "statsig", "shell-snapshots", "ide"]
    static let buildDirs: Set<String> = [".git", ".hg", ".svn", "node_modules", ".venv", "venv", "__pycache__"]
    static let maxFiles = 20_000

    static func buildLeftover(_ name: String, isDir: Bool) -> Bool {
        isDir ? buildDirs.contains(name) : (name == ".DS_Store" || name.hasSuffix(".pyc"))
    }

    /// A name that is never carried, at any depth, whatever it is called otherwise: a sign-in (.claude.json*, .credentials*) and
    /// settings.local.json; settings.json only at the top (it is the setup's own file there and nowhere else).
    static func excludedName(_ name: String, top: Bool) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix(".claude.json") || n.hasPrefix(".credentials") || n == "settings.local.json" { return true }
        return n == "settings.json" && !top
    }

    /// The unit a file of the Claude Code folder belongs to, by its path in it.
    static func unit(of rel: String) -> Unit {
        let c = rel.split(separator: "/").map(String.init)
        guard let first = c.first else { return Unit(kind: .include, name: rel) }
        if c.count == 1 {
            if first == "CLAUDE.md" { return Unit(kind: .claude, name: first) }
            if first == "keybindings.json" { return Unit(kind: .keybindings, name: first) }
            if first == "settings.json" { return Unit(kind: .settings, name: first) }
        }
        if c.count == 2, first == "plugins" {
            if c[1] == "installed_plugins.json" { return Unit(kind: .plugins, name: rel) }
            if c[1] == "known_marketplaces.json" { return Unit(kind: .marketplaces, name: rel) }
        }
        if c.count >= 3, first == "skills" { return Unit(kind: .skill, name: c[1]) }
        if c.count >= 2, first == "agents" { return Unit(kind: .agent, name: c.dropFirst().joined(separator: "/")) }
        if c.count >= 2, first == "commands" { return Unit(kind: .command, name: c.dropFirst().joined(separator: "/")) }
        if c.count >= 2, first == "output-styles" { return Unit(kind: .style, name: c.dropFirst().joined(separator: "/")) }
        return Unit(kind: rel.lowercased().hasSuffix(".md") ? .include : .script, name: rel)
    }

    /// Why a setup path (relative to the Claude Code folder, as its names) can't be carried or imported, or nil. Only the exact
    /// excluded names are refused, never a name that merely contains "auth" or "token": `auth.py`, `token-counter.md` and
    /// `credentials-guide.md` are legitimate skill files.
    static func pathProblem(_ c: [String]) -> String? {
        guard !c.isEmpty, c.count <= 10 else { return "a path that isn't a plain one, or is nested too deep" }
        for (i, n) in c.enumerated() {
            if n.hasPrefix(".") { return "a dot-file or hidden folder (\(n.prefix(30)))" }
            if excludedName(n, top: c.count == 1) { return "a name that is never carried (\(n.prefix(30)))" }
            if buildLeftover(n, isDir: i < c.count - 1) || buildLeftover(n, isDir: false) { return "version history or a build leftover (\(n.prefix(30)))" }
        }
        let first = c[0]
        if c.count == 1 {                                 // CLAUDE.md, keybindings.json, settings.json, a top-level include or script
            // `claude.md`, `Settings.json` or `KEYBINDINGS.JSON` is that file on this Mac's disks: under another case it would pass as an
            // include or a script, made executable or never shown as the file it is
            if ["CLAUDE.md", "settings.json", "keybindings.json"].contains(where: { c[0] != $0 && c[0].compare($0, options: [.caseInsensitive]) == .orderedSame }) {
                return "a file that is another of the setup's under a different case (\(c[0].prefix(30)))"
            }
            return nil
        }
        // `Skills`, `PLUGINS` or `Projects` is the place of that name on this Mac's disks (they ignore case and Unicode forms): a name
        // that is one of those places only under another case or form is refused, so no manifest gets past the rules made for the
        // exact name (a plugin cache, a skill folder that exists, a link on the way) by spelling it differently
        if (topFolders + ["plugins"] + neverFolders.sorted()).contains(where: { first != $0 && first.compare($0, options: [.caseInsensitive]) == .orderedSame }) {
            return "a place that is never carried, or only under its exact name (\(first.prefix(30)))"
        }
        if first == "plugins" {
            return c.count == 2 && (c[1] == "installed_plugins.json" || c[1] == "known_marketplaces.json") ? nil : "a plugin file that isn't the list (caches and repos are never carried)"
        }
        if topFolders.contains(first) {
            if first == "skills" && c.count < 3 { return "a file directly in skills/ (a skill is a folder)" }
            return nil
        }
        if neverFolders.contains(first) { return "a folder that is history or machine state (\(first))" }
        return nil
    }

    /// Whether the unit's file may carry the owner-execute bit: inside a skill's own folder, or a script settings.json points to.
    static func execAllowed(_ rel: String) -> Bool {
        let k = unit(of: rel).kind
        return k == .skill || k == .script
    }

    static func sensitive(_ rel: String) -> Bool { unit(of: rel).sensitive }

    /// The kinds of unit that can hold a file a hook runs without being sensitive by their own kind.
    static let holderKinds: Set<Kind> = [.skill, .agent, .command, .style, .include]

    /// The units (a skill, an agent, a command, an output style) that hold a file a command of settings.json runs: what such a unit
    /// holds can carry a token no key scan recognises, the same reason settings.json and its scripts travel only in the image.
    /// No settings.json: none. nil: a settings.json that isn't a JSON object, so nothing can tell what its hooks run.
    static func hookUnits(rels: [String], settings: Data?) -> Set<Unit>? {
        guard let s = settings else { return [] }
        guard settingsInfo(s) != nil else { return nil }
        let named = namedPaths(in: s, among: rels)
        return Set(named.map(unit(of:)).filter { holderKinds.contains($0.kind) })
    }

    /// The hook-held units of a Claude Code folder, from its settings.json as it is now, also when that is a link (which is never
    /// carried): it is read only to learn the paths its hooks and status line run; its target is never written or shown. Nothing
    /// else is followed. No settings.json: none. nil: one that can't be read (a link to nowhere or to something that isn't a plain
    /// file, too big, not a JSON object).
    static func hookUnits(codeDir: String, rels: [String]) -> Set<Unit>? {
        let path = (codeDir as NSString).appendingPathComponent("settings.json")
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? [] : nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK)                // (the one link followed: settings.json's own, to read it)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= 8 << 20, let d = SessionsRestore.read(fd, size: st.st_size) else { return nil }
        return hookUnits(rels: rels, settings: d)
    }

    /// The units a zip leaves out with settings.json: the ones that hold a file its hooks or status line run (`known`), or, when that
    /// couldn't be learned (settings.json unreadable, a backup from before it was recorded), every one that holds a file with the
    /// execute bit.
    static func heldUnits(known: Set<Unit>?, files: [(rel: String, exec: Bool)]) -> Set<Unit> {
        if let k = known { return k }
        return Set(files.filter(\.exec).map { unit(of: $0.rel) }.filter { holderKinds.contains($0.kind) })
    }

    /// A unit as a backup.json records it ("skill:guard"): names only.
    static func key(_ u: Unit) -> String { "\(u.kind.rawValue):\(u.name)" }
    static func unit(key: String) -> Unit? {
        guard let i = key.firstIndex(of: ":"), let k = Kind(rawValue: String(key[..<i])) else { return nil }
        return Unit(kind: k, name: String(key[key.index(after: i)...]))
    }

    // MARK: reading the disk

    private static func lst(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    private static func target(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: 1025)
        let n = readlink(path, &buf, 1024)
        return n > 0 ? String(cString: buf) : "?"
    }

    /// Lexical normalisation: no "." or "..", one leading slash.
    static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for c in path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(c)
        }
        return "/" + out.joined(separator: "/")
    }

    static func sha(path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return SessionsRestore.sha(fd: fd)
    }

    /// The `@path` imports of a CLAUDE.md-style file (outside code spans and fenced blocks), as written: only those that end in ".md".
    static func includes(in text: String) -> [String] {
        var out: [String] = []
        var inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            // inline code spans out
            var plain = ""
            var inCode = false
            for ch in line { if ch == "`" { inCode.toggle() } else if !inCode { plain.append(ch) } }
            var prev: Character = " "
            var i = plain.startIndex
            while i < plain.endIndex {
                let ch = plain[i]
                if ch == "@", prev.isWhitespace || "([{\"'".contains(prev) {
                    var j = plain.index(after: i)
                    var tok = ""
                    while j < plain.endIndex, !plain[j].isWhitespace { tok.append(plain[j]); j = plain.index(after: j) }
                    while let l = tok.last, ".,;:!?)]}\"'".contains(l), !tok.lowercased().hasSuffix(".md") { tok.removeLast() }
                    if tok.lowercased().hasSuffix(".md"), tok.count > 3 { out.append(tok) }
                    i = j; prev = " "; continue
                }
                prev = ch
                i = plain.index(after: i)
            }
        }
        return out
    }

    /// The files of a skill folder (or any folder): every plain file, a link anywhere says so. `links` gets where the first one points.
    private static func walk(_ dir: String, _ rel: String, depth: Int, into found: inout Found, files: inout [FileRec], link: inout String?, count: inout Int) {
        guard depth <= 6, count < maxFiles else { found.cut.append(rel); return }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for n in names {
            let path = (dir as NSString).appendingPathComponent(n), r = rel + "/" + n
            guard let st = lst(path) else { continue }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFLNK { if link == nil { link = target(path) }; continue }
            if kind == S_IFDIR {
                if buildLeftover(n, isDir: true) { found.leftOutBuild += 1; continue }
                walk(path, r, depth: depth + 1, into: &found, files: &files, link: &link, count: &count)
            } else if kind == S_IFREG {
                if buildLeftover(n, isDir: false) { found.leftOutBuild += 1; continue }
                if excludedName(n, top: false) { found.leftOutNames.append(r); continue }
                if st.st_nlink > 1 { found.leftOutNames.append(r + " (a hard link)"); continue }
                count += 1
                files.append(FileRec(rel: r, src: path, bytes: Int64(st.st_size), exec: st.st_mode & 0o100 != 0))
            }
        }
    }

    /// The files an import may take as "included": the `@` closure of the carried CLAUDE.md, the way the export found them (a path
    /// relative to the file that names it, up to 5 deep; `~/…` and absolute paths are matched by their tail, since the file doesn't
    /// say where the other Mac's Claude Code folder was). `carried` is every setup path the file holds, `read` gives a carried file's
    /// bytes. Anything else that looks like an include (a leftover .md in a folder of its own) isn't one.
    static func includeClosure(carried: Set<String>, read: (String) -> Data?) -> Set<String> {
        var out = Set<String>()
        guard carried.contains("CLAUDE.md") else { return out }
        var visited: Set<String> = ["CLAUDE.md"]
        func follow(_ rel: String, depth: Int) {
            guard depth < 5, let d = read(rel) else { return }
            let dir = (rel as NSString).deletingLastPathComponent
            for tok in includes(in: String(decoding: d, as: UTF8.self)) {
                var hits: [String] = []
                if tok.hasPrefix("~/") || tok.hasPrefix("/") {
                    let p = normalize(tok.hasPrefix("~/") ? "/~home/" + tok.dropFirst(2) : tok)
                    hits = carried.filter { p.hasSuffix("/" + $0) }.sorted()
                } else {
                    let r = String(normalize("/" + (dir.isEmpty ? "" : dir + "/") + tok).dropFirst())
                    if carried.contains(r) { hits = [r] }
                }
                for r in hits where !visited.contains(r) {
                    visited.insert(r)
                    if unit(of: r).kind == .include { out.insert(r) }
                    follow(r, depth: depth + 1)
                }
            }
        }
        follow("CLAUDE.md", depth: 0)
        return out
    }

    /// The carried paths that a command of this settings.json names: the in-folder tail of a path in a hook or status-line command
    /// (`~`, `$HOME` and `${HOME}` expanded, the folder's own name not needed: the tail after it is what is compared).
    static func namedPaths(in settings: Data, among rels: [String]) -> Set<String> {
        let paths = commandPaths(inSettings: settings, home: "/~home").map(normalize)
        return Set(rels.filter { r in paths.contains { $0.hasSuffix("/" + r) } })
    }

    /// What of Claude Code's setup a Claude Code folder holds now. Nothing is written; no link is followed.
    static func scan(codeDir: String, home: String = NSHomeDirectory()) -> Found {
        var found = Found()
        var top = stat()
        // (the folder itself may be a link, which the person set up; what is below it never is)
        guard stat(codeDir, &top) == 0, (top.st_mode & S_IFMT) == S_IFDIR else { return found }
        let base = codeDir
        var have = Set<String>()
        var count = 0
        func add(_ f: FileRec) { if have.insert(f.rel).inserted { found.files.append(f) } }
        func plain(_ rel: String) -> FileRec? {
            let path = (base as NSString).appendingPathComponent(rel)
            guard let st = lst(path), (st.st_mode & S_IFMT) == S_IFREG, st.st_nlink == 1 else { return nil }
            return FileRec(rel: rel, src: path, bytes: Int64(st.st_size), exec: st.st_mode & 0o100 != 0)
        }
        /// A single file at `rel` (CLAUDE.md, keybindings.json …): carried, or listed when it is a link.
        func single(_ rel: String, label: String, kind: Kind) {
            let path = (base as NSString).appendingPathComponent(rel)
            guard let st = lst(path) else { return }
            if (st.st_mode & S_IFMT) == S_IFLNK { found.linked.append(Linked(label: label, kind: kind, target: target(path))); return }
            if let f = plain(rel) { add(f); count += 1 }
        }

        // CLAUDE.md and what it pulls in
        single("CLAUDE.md", label: "CLAUDE.md", kind: .claude)
        if have.contains("CLAUDE.md") {
            var visited: Set<String> = ["CLAUDE.md"]
            func follow(_ rel: String, depth: Int) {
                guard depth < 5, let f = plain(rel), f.bytes <= 4 << 20, let d = FileManager.default.contents(atPath: f.src) else { return }
                let dirRel = (rel as NSString).deletingLastPathComponent
                let importerDir = dirRel.isEmpty ? base : (base as NSString).appendingPathComponent(dirRel)
                for tok in includes(in: String(decoding: d, as: UTF8.self)) {
                    var abs: String
                    if tok.hasPrefix("~/") { abs = (home as NSString).appendingPathComponent(String(tok.dropFirst(2))) }
                    else if tok.hasPrefix("/") { abs = tok }
                    else { abs = (importerDir as NSString).appendingPathComponent(tok) }
                    abs = normalize(abs)
                    let b = normalize(base)
                    guard abs.hasPrefix(b + "/") else { found.outside.append("\(rel) includes \(tok): outside \(tilde(base)), not carried"); continue }
                    let r = String(abs.dropFirst(b.count + 1))
                    let comps = r.split(separator: "/").map(String.init)
                    if visited.contains(r) { continue }
                    if pathProblem(comps) != nil || comps.first.map(neverFolders.contains) == true { continue }
                    // any link on the way (or at the file) is never followed
                    var cur = base, linked: String?
                    for c in comps { cur = (cur as NSString).appendingPathComponent(c); if let s = lst(cur), (s.st_mode & S_IFMT) == S_IFLNK { linked = target(cur); break } }
                    if let t = linked { found.linked.append(Linked(label: "included file \(r)", kind: .include, target: t)); continue }
                    visited.insert(r)
                    // (a file inside skills/, agents/, commands/ comes with its own unit if that is carried; here only the include's own)
                    if let f = plain(r) { if unit(of: r).kind == .include { add(f); count += 1 }; follow(r, depth: depth + 1) }
                }
            }
            follow("CLAUDE.md", depth: 0)
        }

        // skills/, agents/, commands/, output-styles/
        for folder in topFolders {
            let dir = (base as NSString).appendingPathComponent(folder)
            guard let st = lst(dir) else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK { found.linked.append(Linked(label: folder, kind: folder == "skills" ? .skill : folder == "agents" ? .agent : folder == "commands" ? .command : .style, target: target(dir))); continue }
            guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for n in names {
                let path = (dir as NSString).appendingPathComponent(n)
                guard let s = lst(path) else { continue }
                let k = s.st_mode & S_IFMT
                if folder == "skills" {
                    if k == S_IFLNK { found.linked.append(Linked(label: "skill \(n)", kind: .skill, target: target(path))); continue }
                    guard k == S_IFDIR, !n.hasPrefix("."), !buildLeftover(n, isDir: true) else { if buildLeftover(n, isDir: true) { found.leftOutBuild += 1 }; continue }
                    var files: [FileRec] = [], link: String?
                    var sub = Found()
                    walk(path, "skills/" + n, depth: 0, into: &sub, files: &files, link: &link, count: &count)
                    if let t = link { found.linked.append(Linked(label: "skill \(n) (it holds a link)", kind: .skill, target: t)); continue }
                    // a skill the walk had to stop in is left out whole and listed: never carried in part, never as a whole "New" one
                    if !sub.cut.isEmpty { found.leftOutNames.append("skills/\(n) (too deep or too many files: left out whole)"); continue }
                    found.leftOutBuild += sub.leftOutBuild; found.leftOutNames += sub.leftOutNames
                    for f in files { add(f) }
                } else {
                    let kind: Kind = folder == "agents" ? .agent : folder == "commands" ? .command : .style
                    if k == S_IFLNK { found.linked.append(Linked(label: "\(folder.dropLast()) \(n)", kind: kind, target: target(path))); continue }
                    if k == S_IFDIR {
                        if n.hasPrefix(".") || buildLeftover(n, isDir: true) { if buildLeftover(n, isDir: true) { found.leftOutBuild += 1 }; continue }
                        var files: [FileRec] = [], link: String?
                        var sub = Found()
                        walk(path, folder + "/" + n, depth: 0, into: &sub, files: &files, link: &link, count: &count)
                        found.leftOutBuild += sub.leftOutBuild; found.leftOutNames += sub.leftOutNames
                        if let t = link { found.linked.append(Linked(label: "\(folder) folder \(n) (it holds a link)", kind: kind, target: t)); continue }
                        if !sub.cut.isEmpty { found.leftOutNames.append("\(folder)/\(n) (too deep or too many files: left out whole)"); continue }
                        for f in files { add(f) }
                    } else if k == S_IFREG {
                        if n.hasPrefix(".") || buildLeftover(n, isDir: false) { if buildLeftover(n, isDir: false) { found.leftOutBuild += 1 }; continue }
                        if excludedName(n, top: false) { found.leftOutNames.append(folder + "/" + n); continue }
                        if let f = plain(folder + "/" + n) { add(f); count += 1 }
                    }
                }
            }
        }

        // keybindings, settings and the plugin list
        single("keybindings.json", label: "keybindings.json", kind: .keybindings)
        single("settings.json", label: "settings.json", kind: .settings)
        let pdir = (base as NSString).appendingPathComponent("plugins")
        if let ps = lst(pdir) {
            if (ps.st_mode & S_IFMT) == S_IFLNK { found.linked.append(Linked(label: "plugins", kind: .plugins, target: target(pdir))) }
            else if (ps.st_mode & S_IFMT) == S_IFDIR {
                single("plugins/installed_plugins.json", label: "the plugin list", kind: .plugins)
                single("plugins/known_marketplaces.json", label: "the plugin marketplaces", kind: .marketplaces)
            }
        }

        // the scripts settings.json points to
        if let f = found.files.first(where: { $0.rel == "settings.json" }), let d = FileManager.default.contents(atPath: f.src), d.count <= 8 << 20 {
            for path in commandPaths(inSettings: d, home: home) {
                let abs = normalize(path), b = normalize(base)
                if abs.hasPrefix(b + "/") {
                    let r = String(abs.dropFirst(b.count + 1)), comps = r.split(separator: "/").map(String.init)
                    if have.contains(r) { continue }
                    if pathProblem(comps) != nil { continue }
                    // a file inside skills/, agents/, commands/ or output-styles/ comes with its unit or not at all: a unit left out (a
                    // link, a build leftover, the walk's cap) never leaves one file of it behind as a "unit" of its own
                    if let top = comps.first, topFolders.contains(top) { continue }
                    var cur = base, linked: String?
                    for c in comps { cur = (cur as NSString).appendingPathComponent(c); if let s = lst(cur), (s.st_mode & S_IFMT) == S_IFLNK { linked = target(cur); break } }
                    if let t = linked { found.linked.append(Linked(label: "script \(r)", kind: .script, target: t)); continue }
                    if let rec = plain(r) { add(rec) }
                } else if let st = lst(abs), (st.st_mode & S_IFMT) == S_IFREG, !systemPath(abs) {
                    found.outside.append("hook script outside \(tilde(base)): \(tilde(abs)), not carried")
                }
            }
        }
        found.files.sort { $0.rel < $1.rel }
        found.outside = Array(Set(found.outside)).sorted()
        // what the hooks run, from settings.json as it is (a linked one too: read for its command paths only, never carried)
        found.hookUnits = hookUnits(codeDir: base, rels: found.files.map(\.rel))
        return found
    }

    private static func systemPath(_ p: String) -> Bool {
        ["/usr/", "/bin/", "/sbin/", "/System/", "/Library/", "/Applications/", "/opt/homebrew/", "/private/"].contains { p.hasPrefix($0) }
    }

    // MARK: settings.json

    /// The commands of a settings.json's hooks and its status line: the only ones Claude Code runs on its own. The one parse behind
    /// the scripts an export carries, the hook-held units it keeps out of a zip, the scripts an import accepts and makes executable,
    /// and the preview's "What its hooks run": a `command` under any other key (an MCP server's, say) is none of these.
    static func commands(inSettings data: Data) -> [String] {
        guard let s = settingsInfo(data) else { return [] }
        return s.hookCommands + (s.statusLineCommand.map { [$0] } ?? [])
    }

    /// The absolute paths named in the commands of a settings.json: tokens that start with `~/`, `$HOME/`, `${HOME}/` or `/` (a
    /// relative one depends on where the command runs, so it isn't guessed). The command is split on spaces, quotes and shell
    /// punctuation; each token is expanded against `home`.
    static func commandPaths(inSettings data: Data, home: String) -> [String] {
        var out: [String] = []
        let seps = CharacterSet(charactersIn: " \t\n\"'`;|&()<>=,{}")
        for cmd in commands(inSettings: data) {
            for raw in cmd.components(separatedBy: seps) where !raw.isEmpty {
                var t = raw
                if t.hasPrefix("~/") { t = home + String(t.dropFirst(1)) }
                else if t.hasPrefix("$HOME/") { t = home + String(t.dropFirst(5)) }
                else if t.hasPrefix("${HOME}/") { t = home + String(t.dropFirst(7)) }
                guard t.hasPrefix("/"), t.count > 1 else { continue }
                if !out.contains(t) { out.append(t) }
            }
        }
        return out
    }

    struct SettingsInfo: Equatable {
        var hookCommands: [String] = []
        var statusLine: String?
        var statusLineCommand: String?          // the status line's command, when it has one
        var keys: [String: [String]] = [:]      // "hooks" → event names, "permissions" → allow/deny/…, "env" → names: never values
        var other: [String] = []                // the other top-level keys (names only)
    }

    static func settingsInfo(_ data: Data) -> SettingsInfo? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var s = SettingsInfo()
        if let h = j["hooks"] as? [String: Any] {
            s.keys["hooks"] = h.keys.sorted()
            for (_, v) in h.sorted(by: { $0.key < $1.key }) {
                for entry in (v as? [Any]) ?? [] {
                    if let e = entry as? [String: Any] {
                        for hk in (e["hooks"] as? [Any]) ?? [] { if let c = (hk as? [String: Any])?["command"] as? String { s.hookCommands.append(c) } }
                        if let c = e["command"] as? String { s.hookCommands.append(c) }
                    }
                }
            }
        }
        if let sl = j["statusLine"] as? [String: Any] {
            s.statusLineCommand = sl["command"] as? String
            s.statusLine = s.statusLineCommand ?? (sl["type"] as? String) ?? "set"
        }
        if let p = j["permissions"] as? [String: Any] { s.keys["permissions"] = p.keys.sorted() }
        if let e = j["env"] as? [String: Any] { s.keys["env"] = e.keys.sorted() }
        s.other = j.keys.filter { !["hooks", "statusLine", "permissions", "env"].contains($0) }.sorted()
        return s
    }

    /// The names (never values) in which a local settings.json and an imported one differ: "hooks.PreToolUse", "permissions.allow",
    /// "env.FOO", "model".
    static func settingsDifferences(here: Data, there: Data) -> [String] {
        guard let a = (try? JSONSerialization.jsonObject(with: here)) as? [String: Any], let b = (try? JSONSerialization.jsonObject(with: there)) as? [String: Any] else { return ["the file itself"] }
        var out: [String] = []
        func same(_ x: Any?, _ y: Any?) -> Bool {
            switch (x, y) {
            case (nil, nil): return true
            case (let u?, let v?): return (u as AnyObject).isEqual(v as AnyObject)
            default: return false
            }
        }
        for k in Set(a.keys).union(b.keys).sorted() {
            if ["hooks", "permissions", "env"].contains(k), let x = a[k] as? [String: Any] ?? (a[k] == nil ? [:] : nil), let y = b[k] as? [String: Any] ?? (b[k] == nil ? [:] : nil) {
                for s in Set(x.keys).union(y.keys).sorted() where !same(x[s], y[s]) { out.append("\(k).\(s)") }
            } else if !same(a[k], b[k]) { out.append(k) }
        }
        return out
    }

    /// How many plugins the installed-plugins list names. Assumed layout (Claude Code's own, not verified against a real one in
    /// this build): a JSON object with a `plugins` object of name → entry, or an object of name → entry itself, or an array.
    static func pluginCount(_ data: Data) -> Int {
        guard let j = try? JSONSerialization.jsonObject(with: data) else { return 0 }
        if let o = j as? [String: Any] {
            if let p = o["plugins"] as? [String: Any] { return p.count }
            if let p = o["plugins"] as? [Any] { return p.count }
            return o.filter { $0.key != "version" }.count
        }
        return (j as? [Any])?.count ?? 0
    }

    // MARK: words

    struct Extra: Equatable {
        var hooks = 0
        var statusLine = false
        var plugins = 0
        var settingsReadable = true

        init() {}
        init(settings: Data?, plugins pdata: Data?) {
            if let d = settings, let s = Setup.settingsInfo(d) { hooks = s.hookCommands.count; statusLine = s.statusLine != nil } else { settingsReadable = settings == nil }
            if let p = pdata { plugins = Setup.pluginCount(p) }
        }
    }

    struct Counts: Equatable {
        var claude = 0, includes = 0, skills = 0, agents = 0, commands = 0, styles = 0, keybindings = 0, settings = 0, scripts = 0, plugins = 0, marketplaces = 0
        init(_ units: [Unit]) {
            for u in units {
                switch u.kind {
                case .claude: claude += 1
                case .include: includes += 1
                case .skill: skills += 1
                case .agent: agents += 1
                case .command: commands += 1
                case .style: styles += 1
                case .keybindings: keybindings += 1
                case .settings: settings += 1
                case .script: scripts += 1
                case .plugins: plugins += 1
                case .marketplaces: marketplaces += 1
                }
            }
        }
        var total: Int { claude + includes + skills + agents + commands + styles + keybindings + settings + scripts + plugins + marketplaces }
    }

    private static func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) \(k == 1 ? one : many)" }

    /// "CLAUDE.md, 23 skills, 4 agents, 6 commands"; with the added parts "settings.json with 4 hooks and a status line, … , keybindings,
    /// 2 plugins to reinstall". `none` when there are no units.
    static func words(_ c: Counts, extra: Extra = Extra()) -> String {
        var p: [String] = []
        if c.claude > 0 { p.append(c.includes > 0 ? "CLAUDE.md with \(n(c.includes, "included file", "included files"))" : "CLAUDE.md") }
        if c.settings > 0 {
            var w = "settings.json"
            var with: [String] = []
            if extra.hooks > 0 { with.append(n(extra.hooks, "hook", "hooks")) }
            if extra.statusLine { with.append("a status line") }
            if !with.isEmpty { w += " with " + with.joined(separator: " and ") }
            p.append(w)
        }
        if c.scripts > 0 { p.append(n(c.scripts, "script", "scripts")) }
        if c.skills > 0 { p.append(n(c.skills, "skill", "skills")) }
        if c.agents > 0 { p.append(n(c.agents, "agent", "agents")) }
        if c.commands > 0 { p.append(n(c.commands, "command", "commands")) }
        if c.styles > 0 { p.append(n(c.styles, "output style", "output styles")) }
        if c.keybindings > 0 { p.append("keybindings") }
        if c.plugins > 0 { p.append(extra.plugins > 0 ? n(extra.plugins, "plugin", "plugins") + " to reinstall" : "the plugin list") }
        if c.marketplaces > 0 { p.append("the plugin marketplaces") }
        if p.isEmpty { return c.includes > 0 ? n(c.includes, "included file", "included files") : "none" }
        return p.joined(separator: ", ")
    }

    /// "settings.json, the 3 scripts it runs and the plugin marketplaces" (what only the encrypted image carries); `held`: units that
    /// hold a script it runs ("1 skill that holds a script it runs").
    /// `unknown`: settings.json couldn't tell which files its hooks run, so `held` is every unit with an executable file.
    static func sensitiveWords(_ c: Counts, held: Counts = Counts([]), unknown: Bool = false) -> String? {
        var p: [String] = []
        if c.settings > 0 { p.append("settings.json") }
        if c.scripts > 0 { p.append(c.scripts == 1 ? "the script it runs" : "the \(c.scripts) scripts it runs") }
        if held.total > 0, unknown { p.append("\(words(held)) with an executable file (settings.json couldn't be read, so which files its hooks run isn't known)") }
        else if held.total > 0 { p.append("\(words(held)) that \(held.total == 1 ? "holds" : "hold") a script it runs") }
        if c.marketplaces > 0 { p.append("the plugin marketplaces") }
        guard !p.isEmpty else { return nil }
        return p.count == 1 ? p[0] : p.dropLast().joined(separator: ", ") + " and " + p.last!
    }

    /// The units of a list of paths, grouped.
    static func units(of rels: [String]) -> [Unit] { Array(Set(rels.map(unit(of:)))).sorted() }
}
