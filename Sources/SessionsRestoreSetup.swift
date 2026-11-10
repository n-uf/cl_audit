// SessionsRestoreSetup: Claude Code's setup (SessionsSetup.swift) in a backup, planned against what is in the profile's Claude Code
// folder now. The same rules for an import and a restore:
//
// - left out unless asked ("Add them"): a skill missing here was most likely deleted on purpose, and an import's files can't prove
//   they were made for a move; the preview lists every unit as New, Already here (same content) or Different here (stays as it is);
// - never over, never into what is here: a skill folder that exists (same or different) gets nothing added inside it, CLAUDE.md,
//   settings.json, keybindings.json and the plugin files stay as they are, an @-included file comes only when it is missing and with a
//   CLAUDE.md that comes too;
// - never through a link: a skills/, agents/, commands/ or output-styles/ (or any folder on the way) that is a link here gets nothing,
//   and the preview says where it points;
// - files are written like the transcripts: cloned from the backup (a real copy across volumes) into a name that is free, 0600 (0700
//   for a file the manifest marks executable: only inside a skill that this run adds, and a script only when the settings.json
//   that points to it is added by this run too), and Undo takes back exactly those files, if still unchanged.

import Foundation

extension SessionsRestore {
    struct SetupPlan: Equatable {
        enum Status: Equatable { case new, same, different, blocked(String) }
        struct Entry: Equatable {
            var unit: Setup.Unit
            var status: Status
            var files: Int
            var bytes: Int64
        }
        var present = false
        var leftOut = true                      // the choice: left out unless asked
        var entries: [Entry] = []
        var notes: [String] = []                // "skills here is a link to ~/x: nothing added there"
        var execNames: [String] = []            // files that are (or, if added, would be) made executable
        var execManual: [String] = []           // scripts that stay 0600: their settings.json isn't added by this run
        var hooks: [String] = []                // the commands of the file's hooks and status line: what would run
        var settingsDiffer: [String] = []       // names (never values) in which settings.json here and there differ
        var missingPaths: [String] = []         // "hook points to /opt/x.sh: not here"
        var leftOutAtSource: [String] = []      // what the source left out (links …), by name
        var extra = Setup.Extra()
        var added: [Setup.Unit] = []            // the units whose files the plan writes
        var envBlanked = false                  // the backup's settings.json has its env values blanked (a plain backup's)
        var keysBlanked: [String] = []          // where its settings.json held a key and has a blank now ("permissions.allow[2]": names only)
        var keysLeftOut: [String] = []          // what the backup left out for holding a key ("script hooks/x.sh", "the plugin marketplaces")
        var hooksDropped: [String] = []         // hooks of its settings.json the backup dropped for holding a key ("PreToolUse (Bash)")
        var rulesDropped: [String] = []         // permission rules it dropped for holding one ("permissions.deny[1]")

        func entries(_ s: Status) -> [Entry] { entries.filter { $0.status == s } }
        var newEntries: [Entry] { entries.filter { $0.status == .new } }
        var blocked: [Entry] { entries.filter { if case .blocked = $0.status { return true }; return false } }
        var counts: Setup.Counts { Setup.Counts(entries.map(\.unit)) }
        var newCounts: Setup.Counts { Setup.Counts(newEntries.map(\.unit)) }
        var addedNames: [String] { added.map { $0.kind == .skill ? "skill \($0.name)" : $0.name } }
        var isEmpty: Bool { entries.isEmpty }
    }

    private struct SetupFile {
        var item: SessionsBackup.Item
        var comps: [String]                     // inside the Claude Code folder
        var rel: String { comps.joined(separator: "/") }
    }

    static func planSetup(_ p: inout Plan, _ t: Target, items: [SessionsBackup.Item], leftOutAtSource: [String], reader: Reader, add: Bool) {
        var sp = SetupPlan()
        sp.present = !items.isEmpty
        sp.leftOut = !add
        sp.leftOutAtSource = leftOutAtSource
        defer { p.setup = sp }
        guard !items.isEmpty else { return }

        var groups: [Setup.Unit: [SetupFile]] = [:]
        for it in items {
            guard let c = components(it.path), c.count >= 2 else { continue }
            let f = SetupFile(item: it, comps: Array(c.dropFirst()))
            groups[Setup.unit(of: f.rel), default: []].append(f)
        }
        for k in groups.keys { groups[k]?.sort { $0.rel < $1.rel } }

        var isDir: ObjCBool = false
        let code: Tree? = FileManager.default.fileExists(atPath: t.codeDir, isDirectory: &isDir) && isDir.boolValue ? Tree(path: t.codeDir) : nil
        if code == nil { sp.notes.append("The Claude Code folder isn't there, so nothing of the setup is added.") }

        // a top folder here that is a link: said once, with where it points (nothing is added through it)
        var linkedTops = Set<String>()
        for top in Setup.topFolders + ["plugins"] where groups.values.contains(where: { $0.contains { $0.comps.first == top } }) {
            let path = (t.codeDir as NSString).appendingPathComponent(top)
            var st = stat()
            if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                var buf = [CChar](repeating: 0, count: 1025)
                let n = readlink(path, &buf, 1024)
                sp.notes.append("\(top) here is a link to \(n > 0 ? tilde(String(cString: buf)) : "somewhere"): nothing added there")
                linkedTops.insert(top)
            }
        }

        enum D { case absent, same, different, blocked }
        func dest(_ f: SetupFile) -> D {
            guard let tree = code else { return .blocked }
            switch tree.dir(Array(f.comps.dropLast()), create: false) {
            case .blocked: return .blocked
            case .absent: return .absent
            case .dir(let dfd):
                defer { close(dfd) }
                var st = stat()
                guard fstatat(dfd, f.comps.last!, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return .absent }
                guard (st.st_mode & S_IFMT) == S_IFREG else { return .different }
                let fd = openat(dfd, f.comps.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { return .different }
                defer { close(fd) }
                return sha(fd: fd) == f.item.sha ? .same : .different
            }
        }
        func blockedWords(_ f: SetupFile) -> String {
            if let top = f.comps.first, linkedTops.contains(top) { return "\(top) here is a link" }
            return code == nil ? "the Claude Code folder isn't there" : "a folder on the way is a link or a file"
        }

        var status: [Setup.Unit: SetupPlan.Status] = [:]
        for (u, files) in groups {
            let states = files.map(dest)
            if let i = states.firstIndex(of: .blocked) { status[u] = .blocked(blockedWords(files[i])); continue }
            if u.kind == .skill, let tree = code {
                // a skill folder that exists here, same or different, gets nothing added inside it
                var exists = false
                if case .dir(let sfd) = tree.dir(["skills"], create: false) {
                    var st = stat(); exists = fstatat(sfd, u.name, &st, AT_SYMLINK_NOFOLLOW) == 0; close(sfd)
                }
                status[u] = !exists && states.allSatisfy({ $0 == .absent }) ? .new : states.allSatisfy({ $0 == .same }) ? .same : .different
            } else {
                status[u] = states.allSatisfy({ $0 == .absent }) ? .new : states.allSatisfy({ $0 == .same }) ? .same : .different
            }
        }
        sp.entries = groups.keys.sorted().map { u in
            SetupPlan.Entry(unit: u, status: status[u] ?? .different, files: groups[u]!.count, bytes: groups[u]!.reduce(0) { $0 + $1.item.bytes })
        }

        // which units this plan adds
        let claudeNew = status[Setup.Unit(kind: .claude, name: "CLAUDE.md")] == .new
        let settingsNew = status[Setup.Unit(kind: .settings, name: "settings.json")] == .new
        var added: [Setup.Unit] = []
        var pieces: [Piece] = []
        for u in groups.keys.sorted() where status[u] == .new {
            if u.kind == .include, !claudeNew { continue }                  // an included file comes with the CLAUDE.md that includes it
            added.append(u)
            for f in groups[u]! {
                var exec = false
                if f.item.exec == true {
                    exec = u.kind == .skill || (u.kind == .script && settingsNew)
                    if exec { sp.execNames.append(f.rel) } else if u.kind == .script { sp.execManual.append(f.rel) }
                }
                if add {
                    pieces.append(Piece(kind: .setup, rel: ["setup"] + f.comps, base: .code, dirs: Array(f.comps.dropLast()), leaf: f.comps.last!, bytes: f.item.bytes, exec: exec))
                }
            }
        }
        sp.added = add ? added : []
        sp.execNames.sort(); sp.execManual.sort()
        // settings.json is written first: a script is made executable only when the run really created the settings.json that names it
        p.setupPieces = pieces.filter { $0.rel == ["setup", "settings.json"] } + pieces.filter { $0.rel != ["setup", "settings.json"] }

        // what settings.json would make run (the hooks' commands and the status line), and how it differs when one is here
        func backupData(_ rel: [String]) -> Data? {
            guard let f = reader.file(["setup"] + rel) else { return nil }
            defer { close(f.fd) }
            return read(f.fd, size: f.st.st_size)
        }
        let sdata = groups[Setup.Unit(kind: .settings, name: "settings.json")] != nil ? backupData(["settings.json"]) : nil
        let pdata = groups[Setup.Unit(kind: .plugins, name: "plugins/installed_plugins.json")] != nil ? backupData(["plugins", "installed_plugins.json"]) : nil
        sp.extra = Setup.Extra(settings: sdata, plugins: pdata)
        if let d = sdata, Setup.settingsInfo(d) != nil {
            // (the same parse as the scripts the import accepts and makes executable: hooks and the status line's command only)
            sp.hooks = Setup.commands(inSettings: d).prefix(30).map { String($0.prefix(200)) }
            if status[Setup.Unit(kind: .settings, name: "settings.json")] == .different {
                let here = FileManager.default.contents(atPath: (t.codeDir as NSString).appendingPathComponent("settings.json"))
                sp.settingsDiffer = here.map { Setup.settingsDifferences(here: $0, there: d) } ?? []
            }
            // absolute paths in its commands that are not on this Mac (and that this plan wouldn't put there either)
            let willBe = Set(groups.values.joined().filter { status[Setup.unit(of: $0.rel)] == .new }.map { Setup.normalize(t.codeDir + "/" + $0.rel) })
            sp.missingPaths = Setup.commandPaths(inSettings: d, home: NSHomeDirectory()).filter {
                !FileManager.default.fileExists(atPath: $0) && !willBe.contains(Setup.normalize($0))
            }.map { "hook points to \(tilde($0)): not here" }
        }
    }

    /// After settings.json was added by a run: the hook and status-line paths in it that aren't on this Mac.
    static func setupMissingPaths(_ t: Target) -> [String] {
        guard let d = FileManager.default.contents(atPath: (t.codeDir as NSString).appendingPathComponent("settings.json")) else { return [] }
        return Setup.commandPaths(inSettings: d, home: NSHomeDirectory()).filter { !FileManager.default.fileExists(atPath: $0) }.map { "hook points to \(tilde($0)): not here" }
    }
}
