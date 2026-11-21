// Auth checks for ClaudeAuth (Auth/): compiled against ClaudeAuth and ProfileCore ONLY (no app sources, no AppKit or
// SwiftUI). No real Keychain and no real `claude`: the Keychain tool, the runner and Terminal are fakes that record what
// they were asked. The folder's item names (known SHA-256 vectors), its environment, the one answer (verified, guessed,
// differs, none) and the matching rule, the Keychain read's outcomes, the sign-in watch, the runs and their guards
// (nothing started, nothing made, on a folder that isn't there), the bounded record read, and a lint that Auth/ stays
// shareable and read-only on the Keychain. Fake data only: example.com addresses, zero-pattern ids, made-up tokens.
//
// Runs with HOME at Checks/.work/auth/home (Checks/run.sh sets and guards it); it makes folders only there.

import Foundation
import ProfileCore
@testable import ClaudeAuth

setbuf(stdout, nil)
let home = NSHomeDirectory()
guard home.hasSuffix("/Checks/.work/auth/home") else { print("refusing: HOME is \(home)"); exit(2) }
var passed = 0, failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passed += 1 } else { failed += 1; print("FAIL (line \(line)): \(what)") }
}
func uuid(_ n: Int) -> String { "00000000-0000-4000-8000-" + String(format: "%012d", n) }
let fm = FileManager.default
func mkdir(_ p: String) { try? fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
func write(_ p: String, _ s: String) { try? Data(s.utf8).write(to: URL(fileURLWithPath: p)) }
func record(_ p: String, email: String?, account: String?, org: String?, orgName: String? = nil, plan: String? = nil) {
    var o: [String: Any] = [:]
    if let email { o["emailAddress"] = email }
    if let account { o["accountUuid"] = account }
    if let org { o["organizationUuid"] = org }
    if let orgName { o["organizationName"] = orgName }
    if let plan { o["planDisplayName"] = plan }
    let j: [String: Any] = email == nil && account == nil ? ["projects": [:]] : ["oauthAccount": o, "projects": [:]]
    try? JSONSerialization.data(withJSONObject: j).write(to: URL(fileURLWithPath: p))
}
/// The tools every section starts from: a Keychain tool, a runner and a Terminal that stop the run if called, so nothing
/// real is touched unless a section passes its own fake.
var fakes = AuthTools(stored: KeychainSignInReader(tool: { _ in fatalError("the real Keychain tool was asked") }),
                      run: { _ in fatalError("a real claude run was asked") },
                      openTerminal: { _ in fatalError("Terminal was asked") },
                      mayLaunch: { _, f in f.isReady }, readRecord: { RecordFile.oauthAccount($0) },
                      environment: { [:] }, userName: "ann")
func bobWord() -> SignedInAccount { SignedInAccount(email: "bob@example.com", organizationName: "Example Org", origin: .process) }
/// Every directory under the home folder now (to see that nothing here made one).
func dirs() -> Set<String> {
    var out = Set<String>()
    let e = fm.enumerator(atPath: home)
    while let p = e?.nextObject() as? String {
        var d: ObjCBool = false
        if fm.fileExists(atPath: home + "/" + p, isDirectory: &d), d.boolValue { out.insert(p) }
    }
    return out
}

// ============ 1. the folder: default or not, the record, the Keychain item's names ============
do {
    mkdir(home + "/.claude")
    for spelling in ["~/.claude", home + "/.claude", home + "/.claude/", "~/.Claude", home + "/./.claude"] {
        check(AuthFolder(path: spelling, home: home).isDefault, "the default folder however it is spelled: \(spelling)")
    }
    try? fm.createSymbolicLink(atPath: home + "/claude-link", withDestinationPath: home + "/.claude")
    check(AuthFolder(path: "~/claude-link", home: home).isDefault, "a link to ~/.claude is the default folder")
    check(!AuthFolder(path: "~/.claude-work", home: home).isDefault && !AuthFolder(path: "~/.claude/work", home: home).isDefault,
          "another folder, or one inside ~/.claude, is not the default one")
    check(AuthFolder(path: "~/.claude-work", isDefault: true, home: home).isDefault, "the app's own answer wins when it gives one")
    check(AuthFolder(path: "~/.claude-work", home: home).path == home + "/.claude-work", "~ is expanded")

    let def = AuthFolder(path: "~/.claude", home: home)
    check(def.recordPath == home + "/.claude.json", "the default folder's record is ~/.claude.json")
    check(AuthFolder(path: "~/.claude-work", home: home).recordPath == home + "/.claude-work/.claude.json", "any other's is inside it")

    check(def.keychainItems == ["Claude Code-credentials"] && def.keychainItem == "Claude Code-credentials",
          "the default folder's item: \(def.keychainItems)")
    let work = AuthFolder(path: "/tmp/sample/.claude-work", home: home)
    // known vectors (shasum -a 256 of the path as CLAUDE_CONFIG_DIR is set, and with a trailing slash)
    check(work.keychainItems == ["Claude Code-credentials-5a84af42", "Claude Code-credentials-0cab8c8c"],
          "another folder's items: the name, \"-\" and 8 hex of the path's SHA-256: \(work.keychainItems)")
    check(work.keychainItem == "Claude Code-credentials-5a84af42", "the folder's own item comes first")
    check(AuthFolder.sha8("/tmp/sample/.claude-work") == "5a84af42", "sha8")
}

// ============ 2. the environment a claude run gets ============
do {
    var base = ["HOME": home, "PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere", "KEEP": "1"]
    for k in AuthFolder.providerVariables { base[k] = "set-by-the-shell" }
    let other = AuthFolder(path: "~/.claude-work", home: home).environment(base)
    check(AuthFolder.providerVariables.allSatisfy { other[$0] == nil }, "no key, token or other provider is passed on")
    check(other["CLAUDE_CONFIG_DIR"] == home + "/.claude-work", "another folder: CLAUDE_CONFIG_DIR is that folder, never the shell's")
    check(other["KEEP"] == "1" && other["HOME"] == home, "the rest stays")
    check(other["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin", "the install places first on PATH: \(other["PATH"] ?? "")")
    let def = AuthFolder(path: "~/.claude", home: home).environment(base)
    check(def["CLAUDE_CONFIG_DIR"] == nil, "the default folder: CLAUDE_CONFIG_DIR unset (set, Claude Code takes it for a custom folder)")
    check(AuthFolder(path: "~/.claude", home: home).environment([:])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
          "no PATH: no empty entry (the current folder) at its end")
    check(AuthFolder(path: "~/.claude", home: home).environment(["PATH": ""])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
          && AuthFolder(path: "~/.claude", home: home).environment(["PATH": ":/usr/bin::"])["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin",
          "an empty PATH or empty entries in it: none kept")
    check(AuthFolder.providerVariables.contains("ANTHROPIC_BASE_URL") && AuthFolder.providerVariables.contains("ANTHROPIC_CUSTOM_HEADERS"),
          "a base URL or extra headers from the shell never reach a run (the sign-in would go to another host)")
}

// ============ 3. ready to run claude on: never made, never a link ============
do {
    mkdir(home + "/real-folder")
    write(home + "/a-file", "x")
    try? fm.createSymbolicLink(atPath: home + "/folder-link", withDestinationPath: home + "/real-folder")
    check(AuthFolder(path: "~/real-folder", home: home).isReady, "a plain folder is ready")
    check(!AuthFolder(path: "~/no-such-folder", home: home).isReady, "a folder that isn't there isn't")
    check(!fm.fileExists(atPath: home + "/no-such-folder"), "...and asking didn't make it")
    check(!AuthFolder(path: "~/folder-link", home: home).isReady, "a link isn't ready (launching never goes through one)")
    check(!AuthFolder(path: "~/folder-link/", home: home).isReady && !AuthFolder(path: home + "/folder-link//", home: home).isReady,
          "a link named with a trailing slash isn't either (lstat would follow it)")
    check(AuthFolder(path: "~/real-folder/", home: home).isReady, "a plain folder with a trailing slash is")
    check(!AuthFolder(path: "~/a-file", home: home).isReady, "a file isn't")
    check(AuthFolder(path: "~/.claude", home: home).isReady, "the default folder always is")
}

// ============ 4. identity: each source, the matching rule, the one answer ============
do {
    let r = SignedInAccount.record(["accountUuid": uuid(1), "emailAddress": "ann@example.com", "organizationUuid": uuid(51),
                                    "organizationName": "Example Org", "planDisplayName": "Ultra", "accessToken": "never-read"])
    check(r?.accountID == uuid(1) && r?.email == "ann@example.com" && r?.organizationID == uuid(51) && r?.organizationName == "Example Org"
          && r?.plan == "Ultra" && r?.origin == .record && r?.source == .guessed, "the record: its named fields, guessed")
    check(SignedInAccount.record(nil) == nil && SignedInAccount.record(["planDisplayName": "Max"]) == nil
          && SignedInAccount.record(["emailAddress": "  "]) == nil, "a record that names nobody: signed out")

    let p = SignedInAccount.process(["email": "ANN@example.com", "organization": "Example Org", "subscriptionType": "max", "apiProvider": "firstParty"])
    check(p?.email == "ANN@example.com" && p?.organizationName == "Example Org" && p?.accountID == nil && p?.source == .verified,
          "a running claude's initialize account: address and organisation name, verified")
    check(SignedInAccount.process(["apiProvider": "firstParty"]) == nil && SignedInAccount.process(nil) == nil,
          "a process that names nobody (a key, a token)")

    let reply = try! JSONSerialization.data(withJSONObject: ["account": ["uuid": uuid(1), "email_address": "ann@example.com"],
                                                             "organization": ["uuid": uuid(51), "name": "Example Org"]])
    let s = SignedInAccount.server(reply)
    check(s?.accountID == uuid(1) && s?.email == "ann@example.com" && s?.organizationID == uuid(51) && s?.source == .verified,
          "Anthropic's reply about the sign-in: ids, address, organisation, verified")
    check(SignedInAccount.server(Data("not json".utf8)) == nil && SignedInAccount.server(Data("{}".utf8)) == nil, "a reply naming nobody")

    // matching
    check(p!.matches(r!) && r!.matches(p!), "no id on one side: the address (any case) and the organisation's name")
    check(!SignedInAccount(email: "ann@example.com", organizationName: "Other Org", origin: .process).matches(r!),
          "the same address in another organisation: another account (a personal plan and a team seat)")
    check(SignedInAccount(email: "ann@example.com", origin: .process).matches(r!), "an organisation only one side names doesn't tell them apart")
    check(!SignedInAccount(email: "bob@example.com", organizationName: "Example Org", origin: .process).matches(r!), "another address")
    check(!SignedInAccount(organizationName: "Example Org", origin: .process).matches(SignedInAccount(organizationName: "Example Org", origin: .record)),
          "no address and no id: never the same")
    check(SignedInAccount(accountID: uuid(1).uppercased(), organizationID: uuid(51), origin: .server).matches(r!),
          "both with ids: the ids, whatever the case")
    check(!SignedInAccount(accountID: uuid(2), email: "ann@example.com", organizationID: uuid(51), origin: .server).matches(r!),
          "both with ids: the ids decide, not the address")
    check(!SignedInAccount(accountID: uuid(1), organizationID: uuid(52), origin: .server).matches(r!), "the same id in another organisation")
    check(SignedInAccount(accountID: uuid(3), organizationID: "", origin: .server).organizationID == nil
          && SignedInAccount(accountID: uuid(3), organizationID: " ", origin: .server).matches(SignedInAccount(accountID: uuid(3), origin: .record)),
          "an empty organisation is kept as none, and none on both sides is the same")
    check(!SignedInAccount(accountID: uuid(3), origin: .server).matches(SignedInAccount(accountID: uuid(3), organizationID: uuid(51), origin: .record)),
          "both with ids: an organisation only one side has is another seat (ProfileCore's AccountID)")
    check(SignedInAccount(email: " ann@example.com\n", origin: .process).email == "ann@example.com"
          && SignedInAccount(email: "ann@example.com ", origin: .process).matches(r!), "values are kept trimmed")
    check(p!.match(r!) == .seat && SignedInAccount(email: "ann@example.com", origin: .process).match(r!) == .address
          && bobWord().match(r!) == .different, "match: seat, address only, different")
    check(!SignedInAccount(email: "ann@example.com", organizationID: uuid(52), organizationName: "Example Org", origin: .server).matches(r!),
          "by address: the organisations' ids when both have one, before their names")
    check(r!.identity == AccountIdentity(account: uuid(1), email: "ann@example.com", organization: uuid(51), source: .guessed),
          "ProfileCore's identity from it")

    // the one answer
    let none = FolderSignIn.answer(record: nil, verified: nil)
    check(none.verdict == .none && none.account == nil, "nobody named: none")
    let guessed = FolderSignIn.answer(record: r, verified: nil)
    check(guessed.verdict == .guessed && guessed.account == r && guessed.account?.source == .guessed, "the record alone: guessed")
    let agreed = FolderSignIn.answer(record: r, verified: p)
    check(agreed.verdict == .verified && agreed.account?.accountID == uuid(1) && agreed.account?.organizationID == uuid(51)
          && agreed.account?.email == "ANN@example.com" && agreed.account?.plan == "Ultra" && agreed.account?.source == .verified,
          "the process agrees with the record: verified, with the record's ids and plan")
    let bob = SignedInAccount(email: "bob@example.com", organizationName: "Example Org", origin: .process)
    let differs = FolderSignIn.answer(record: r, verified: bob)
    check(differs.verdict == .differs && differs.account == bob && differs.record == r,
          "the process names another account than the record: differs, the process's word is the account")
    let loose = FolderSignIn.answer(record: r, verified: SignedInAccount(email: "ann@example.com", origin: .process))
    check(loose.verdict == .verified && loose.account?.accountID == nil && loose.account?.organizationID == nil && loose.account?.plan == nil
          && loose.record == r, "the same address but no organisation to compare: verified, without the record's ids or plan (maybe another seat's)")
    let alone = FolderSignIn.answer(record: nil, verified: s)
    check(alone.verdict == .verified && alone.account == s, "a verified word with no record: verified")
    check(FolderSignIn.answer(record: nil, verified: r).verdict == .none, "a record passed as the verified word is never taken for one")
    check(agreed.isSignedIn(to: SignedInAccount(accountID: uuid(1), organizationID: uuid(51), origin: .record))
          && !none.isSignedIn(to: r!), "isSignedIn(to:)")
}

// ============ 5. the Keychain item: read with a fake `security` ============
do {
    let folder = AuthFolder(path: "/tmp/sample/.claude-work", home: home)
    var asked: [[String]] = []
    func fake(_ answers: [String: (Int32, String)]) -> KeychainSignIn.Tool {
        return { args in
            asked.append(args)
            let service = args[args.firstIndex(of: "-s")! + 1]
            let key = service + (args.contains("-a") ? "|user" : "|any")
            let a = answers[key] ?? (KeychainSignIn.notFoundStatus, "")
            return (a.0, Data(a.1.utf8))
        }
    }
    let item = folder.keychainItems[0], slash = folder.keychainItems[1]

    asked = []
    if case .notFound = KeychainSignIn.read(folder, user: "ann", tool: fake([:])) {} else { check(false, "no item anywhere: notFound") }
    check(asked == [["find-generic-password", "-s", item, "-w", "-a", "ann"], ["find-generic-password", "-s", item, "-w"],
                    ["find-generic-password", "-s", slash, "-w", "-a", "ann"], ["find-generic-password", "-s", slash, "-w"]],
          "each name, under the user's account then any; read only (find, never add or delete): \(asked)")

    let json = #"{"claudeAiOauth":{"accessToken":"sk-made-up-0000","refreshToken":"made-up-refresh","expiresAt":1800000000000,"subscriptionType":"max"}}"#
    asked = []
    if case let .token(t, expires, plan) = KeychainSignIn.read(folder, user: "ann", tool: fake([slash + "|any": (0, json + "\n")])) {
        check(t == "sk-made-up-0000" && expires == Date(timeIntervalSince1970: 1_800_000_000) && plan == "max", "the token's named fields")
    } else { check(false, "the item under the second name, any account: read") }
    check(asked.count == 4, "it stops at the first item found")

    let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
    if case .token = KeychainSignIn.read(folder, user: "ann", tool: fake([item + "|user": (0, hex)])) {} else { check(false, "hex output is decoded") }

    asked = []
    if case .denied = KeychainSignIn.read(folder, user: "ann", tool: fake([item + "|user": (51, "")])) {} else { check(false, "refused: denied") }
    check(asked.count == 1, "a refused read stops there (no second prompt)")
    if case .denied = KeychainSignIn.read(folder, user: "ann", tool: fake([item + "|user": (-1, "")])) {} else { check(false, "timed out: denied") }
    if case .unreadable = KeychainSignIn.read(folder, user: "ann", tool: fake([item + "|user": (0, "not a sign-in")])) {} else {
        check(false, "an item in an unknown form: unreadable")
    }
    if case .unreadable = KeychainSignIn.read(folder, user: "ann", tool: fake([item + "|user": (0, #"{"claudeAiOauth":{}}"#)])) {} else {
        check(false, "a sign-in without a token: unreadable")
    }
    // through the authenticator: its tools and user name
    var tools = fakes
    tools.stored = KeychainSignInReader(tool: fake([item + "|user": (0, json)])); tools.userName = "ann"
    if case .token = Authenticator(folder, tools: tools).readSignIn() {} else { check(false, "Authenticator.readSignIn uses its tools") }
    // an app that never reads the store (cl_quick) passes no reader: nothing is read, nothing is asked
    tools.stored = nil
    check(Authenticator(folder, tools: tools).readSignIn() == nil && AuthTools.system.stored == nil,
          "no reader: readSignIn is nil, and the plain system tools carry none")
    check(AuthTools.systemWithKeychain.stored is KeychainSignInReader, "systemWithKeychain: the Keychain reader")
}

// ============ 6. the sign-in watch ============
do {
    mkdir(home + "/.claude-watch")
    let folder = AuthFolder(path: "~/.claude-watch", home: home)
    var tools = fakes
    tools.mayLaunch = { _, _ in false }
    let auth = Authenticator(folder, tools: tools)
    var w = SignInChangeWatch()
    var reads = 0
    func look() -> Bool { w.look(stamp: auth.recordStamp()) { reads += 1; return auth.record() } }

    check(!look() && w.seen == nil && reads == 0, "no record: nothing read, no change")
    record(folder.recordPath, email: "ann@example.com", account: uuid(1), org: uuid(51))
    check(!look() && w.seen?.accountID == uuid(1) && reads == 1, "the first account named isn't a change")
    check(!look() && reads == 1, "an unchanged record isn't read again")
    record(folder.recordPath, email: "ann@example.com", account: uuid(1), org: uuid(51), plan: "Max")
    check(!look() && reads == 2, "rewritten for the same account: read, no change")
    record(folder.recordPath, email: nil, account: nil, org: nil)
    check(!look() && w.seen?.accountID == uuid(1), "signed out: no change, the last account kept")
    record(folder.recordPath, email: "bob@example.com", account: uuid(2), org: uuid(51))
    check(look() && w.seen?.accountID == uuid(2), "signed in to another account: a change")
    record(folder.recordPath, email: "bob@example.com", account: uuid(2).uppercased(), org: uuid(51))
    check(!look(), "the same id in another case: no change")
    check(auth.signIn().verdict == .guessed && auth.signIn().account?.email == "bob@example.com", "the answer from the record: guessed")
    check(auth.signIn(verified: SignedInAccount.process(["email": "bob@example.com"])).verdict == .verified, "...verified with the process's word")
}

// ============ 7. the runs: renew, sign-out, sign-in, and their guards ============
do {
    mkdir(home + "/.claude-runs")
    let folder = AuthFolder(path: "~/.claude-runs", home: home)
    record(folder.recordPath, email: "ann@example.com", account: uuid(1), org: uuid(51))
    var ran: [ClaudeCommand] = [], launches: [String] = [], opened: [URL] = []
    var exit: Int32? = 0
    var tools = fakes
    tools.run = { ran.append($0); return exit }
    tools.openTerminal = { opened.append($0); return true }
    tools.environment = { ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "made-up", "CLAUDE_CONFIG_DIR": "/tmp/elsewhere"] }
    tools.mayLaunch = { what, f in launches.append(what); return f.isReady }
    let auth = Authenticator(folder, tools: tools)
    let claude = "/opt/sample/bin/claude"
    try? fm.createSymbolicLink(atPath: home + "/.claude-runs-link", withDestinationPath: home + "/.claude-runs")
    let before = dirs()

    // renew
    check(auth.renew(claude: claude) == .done && ran.count == 1, "renew runs once")
    check(ran.last == ClaudeCommand(executable: claude, arguments: ["-p", "Reply with OK.", "--model", "haiku", "--no-session-persistence"],
                                    environment: folder.environment(tools.environment()), timeout: 120),
          "renew: the one-line prompt on Haiku, nothing saved, on this folder only, 2 minutes at most")
    check(ran.last?.environment["CLAUDE_CONFIG_DIR"] == folder.path && ran.last?.environment["ANTHROPIC_API_KEY"] == nil, "renew's environment")
    let ann = SignedInAccount(accountID: uuid(1), organizationID: uuid(51), origin: .record)
    check(auth.renew(claude: claude, expecting: ann) == .done && ran.count == 2, "renew for the account the folder is signed in to")
    check(auth.renew(claude: claude, expecting: SignedInAccount(accountID: uuid(2), organizationID: uuid(51), origin: .record)) == .otherAccount
          && ran.count == 2, "the folder signed in to another account: never renewed in this one's name, nothing runs")
    var noRecord = tools; noRecord.readRecord = { _ in nil }
    check(Authenticator(folder, tools: noRecord).renew(claude: claude, expecting: ann) == .otherAccount && ran.count == 2,
          "a record naming nobody (signed out, unreadable, too large): not renewed for the account expected")
    check(Authenticator(folder, tools: noRecord).renew(claude: claude) == .done && ran.count == 3, "...while renew with no account expected runs")
    check(auth.renew(claude: claude, expecting: SignedInAccount(email: "ann@example.com", origin: .record)) == .otherAccount && ran.count == 3,
          "an account expected by its address alone: not renewed (the seat on that address may be another)")
    exit = 1
    check(auth.renew(claude: claude) == .failed, "a run that ends badly: failed")
    exit = nil
    check(auth.renew(claude: claude) == .failed, "a run that couldn't start or timed out: failed")
    exit = 0

    // sign-out
    let n = ran.count
    check(auth.signOut(claude: claude) == .done && ran.count == n + 1 && ran.last?.arguments == ["auth", "logout"]
          && ran.last?.environment["CLAUDE_CONFIG_DIR"] == folder.path, "sign-out: claude auth logout on this folder")
    check(launches.contains("renew") && launches.contains("logout"), "every run asks the guard first: \(launches)")

    // sign-in
    let script = URL(fileURLWithPath: home + "/sign-in.command"), marker = URL(fileURLWithPath: home + "/signed-in.done")
    check(auth.startSignIn(claude: claude, email: "o'neil@example.com", script: script, marker: marker) == .done && opened == [script],
          "the sign-in script is written and opened in Terminal")
    let withBackslash = SignInScript.lines(claude: claude, folder: folder, email: nil, shown: #"~/a\cb"#)
    check(withBackslash.contains(#"print -r -- 'Signing in to Claude Code for ~/a\cb…'"#) && !withBackslash.contains { $0.hasPrefix("echo '") },
          "the lines it shows are printed raw (zsh's echo would take a backslash for an escape)")
    let text = (try? String(contentsOf: script, encoding: .utf8)) ?? ""
    let mode = ((try? fm.attributesOfItem(atPath: script.path))?[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o700, "the script is the owner's only")
    write(script.path, "an older script")
    _ = try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
    check(auth.startSignIn(claude: claude, email: nil, script: script) == .done
          && ((try? fm.attributesOfItem(atPath: script.path))?[.posixPermissions] as? NSNumber)?.intValue == 0o700
          && !((try? String(contentsOf: script, encoding: .utf8)) ?? "").contains("older"), "a script left from before is replaced, owner only")
    _ = auth.startSignIn(claude: claude, email: "o'neil@example.com", script: script, marker: marker)
    check(text.contains("export CLAUDE_CONFIG_DIR='\(folder.path)'") && text.contains("unset " + AuthFolder.providerVariables.joined(separator: " ")),
          "the script: this folder, no key or other provider")
    check(text.contains("'\(claude)' auth login --claudeai --email 'o'\\''neil@example.com'"), "claude auth login --email, the address quoted")
    check(text.contains("if [ $s -eq 0 ]; then : > '\(marker.path)'; fi"), "the marker when the login ended well")
    check(!text.contains("rm -f"), "the script stays unless asked to remove itself")
    check(launches.last == "login", "the sign-in asks the guard too")
    let def = SignInScript.lines(claude: claude, folder: AuthFolder(path: "~/.claude", home: home), email: nil, removesItself: true, shown: "~/.claude")
    check(def.contains("unset CLAUDE_CONFIG_DIR") && !def.contains { $0.hasPrefix("export CLAUDE_CONFIG_DIR") }
          && def.contains("'\(claude)' auth login --claudeai") && def[1] == "rm -f -- \"$0\"" && def.contains("print -r -- 'Signing in to Claude Code for ~/.claude…'"),
          "the default folder signs in with CLAUDE_CONFIG_DIR unset; a script asked to removes itself first")

    // a folder that isn't there: nothing starts and nothing is made
    let gone = Authenticator(AuthFolder(path: "~/.claude-gone", home: home), tools: tools)
    let ranBefore = ran.count, openedBefore = opened.count
    let goneScript = URL(fileURLWithPath: home + "/gone.command")
    check(gone.renew(claude: claude) == .folderNotReady && gone.signOut(claude: claude) == .folderNotReady
          && gone.startSignIn(claude: claude, email: "ann@example.com", script: goneScript) == .folderNotReady,
          "a folder that isn't there: folderNotReady for each")
    check(ran.count == ranBefore && opened.count == openedBefore && !fm.fileExists(atPath: goneScript.path), "...nothing ran, opened or written")
    check(!fm.fileExists(atPath: home + "/.claude-gone"), "...and the folder wasn't made")
    // a link to a folder: never launched through
    check(Authenticator(AuthFolder(path: "~/.claude-runs-link", home: home), tools: tools).renew(claude: claude) == .folderNotReady,
          "a link to a folder: not launched through")
    // the app's own guard decides
    var no = tools; no.mayLaunch = { _, _ in false }
    check(Authenticator(folder, tools: no).renew(claude: claude) == .folderNotReady && ran.count == ranBefore, "the app's guard says no: nothing runs")
    check(dirs() == before, "one profile, one folder: no folder was made by any of it (\(dirs().subtracting(before)))")
}

// ============ 8. the record, read safely ============
do {
    mkdir(home + "/rec")
    record(home + "/rec/ok.json", email: "ann@example.com", account: uuid(1), org: uuid(51))
    check(RecordFile.oauthAccount(home + "/rec/ok.json")?["accountUuid"] as? String == uuid(1), "a plain record is read")
    check(mkfifo(home + "/rec/fifo.json", 0o600) == 0, "a FIFO made")
    let t = Date()
    check(RecordFile.oauthAccount(home + "/rec/fifo.json") == nil && Date().timeIntervalSince(t) < 2, "a FIFO returns nil at once")
    write(home + "/rec/big.json", String(repeating: " ", count: 2048) + "{}")
    check(RecordFile.oauthAccount(home + "/rec/big.json", max: 1024) == nil, "a record over the cap isn't read")
    check(RecordFile.oauthAccount(home + "/rec/none.json") == nil && RecordFile.oauthAccount(home + "/rec") == nil, "none, or a folder")
}

// ============ 8b. the real runners' timeouts, with harmless stand-ins (sleep, true, false) ============
do {
    var t = Date()
    let slow = KeychainSignIn.run(["5"], timeout: 1, executable: "/bin/sleep")
    check(slow.status == -1 && slow.output.isEmpty && Date().timeIntervalSince(t) < 4, "a Keychain read that runs out of time: stopped, refused (-1)")
    check(KeychainSignIn.run([], timeout: 5, executable: "/usr/bin/true").status == 0, "one that ends: its status")
    t = Date()
    check(AuthRun.system(ClaudeCommand(executable: "/bin/sleep", arguments: ["5"], environment: [:], timeout: 1)) == nil
          && Date().timeIntervalSince(t) < 4, "a claude run that runs out of time: stopped, nil")
    check(AuthRun.system(ClaudeCommand(executable: "/usr/bin/true", arguments: [], environment: [:], timeout: 5)) == 0
          && AuthRun.system(ClaudeCommand(executable: "/usr/bin/false", arguments: [], environment: [:], timeout: 5)) == 1
          && AuthRun.system(ClaudeCommand(executable: home + "/no-such-program", arguments: [], environment: [:], timeout: 5)) == nil,
          "a run's status; nil when it can't start")
    // what the run started goes with it: a child of a run that runs out of time is gone too (its own process group)
    let childFile = home + "/auth-child.pid"
    try? FileManager.default.removeItem(atPath: childFile)
    t = Date()
    let timedOut = AuthRun.system(ClaudeCommand(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $! > '\(childFile)'; sleep 30"], environment: [:], timeout: 2))
    let child = (try? String(contentsOfFile: childFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
    var childGone = false
    let until = Date().addingTimeInterval(2)
    while child > 0 && !childGone && Date() < until { childGone = kill(child, 0) != 0; if !childGone { usleep(20_000) } }
    check(timedOut == nil && child > 0 && childGone && Date().timeIntervalSince(t) < 7,
          "a claude run that runs out of time: what it started is gone with it (child \(child))")
    try? FileManager.default.removeItem(atPath: childFile)
    // …but a normal end leaves what it started running (Claude Code's updater, say): only a timeout ends the group
    let ended = AuthRun.system(ClaudeCommand(executable: "/bin/sh", arguments: ["-c", "sleep 20 >/dev/null 2>&1 & echo $! > '\(childFile)'"], environment: [:], timeout: 10))
    let left = (try? String(contentsOfFile: childFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? -1
    let leftRunning = left > 0 && kill(left, 0) == 0
    if left > 0 { kill(left, SIGKILL) }
    check(ended == 0 && leftRunning, "a claude run that ends normally: what it left running is left alone (child \(left))")
    try? FileManager.default.removeItem(atPath: childFile)
    // one that ignores the request to end is killed after the grace
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "trap '' TERM; sleep 10"]
    try? p.run()
    usleep(200_000)
    t = Date()
    AuthRun.stop(p, grace: 0.5)
    check(!p.isRunning && Date().timeIntervalSince(t) < 3, "a process that ignores SIGTERM is killed after the grace")
}

// ============ 9. lint: Auth/ stays shareable, never logs, never writes the Keychain; Core/ never imports it ============
do {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let auth = repo.appendingPathComponent("Auth")
    let files = ((try? fm.contentsOfDirectory(atPath: auth.path)) ?? []).filter { $0.hasSuffix(".swift") }
    check(files.count >= 5, "Auth/'s sources found: \(files)")
    for f in files {
        let s = (try? String(contentsOf: auth.appendingPathComponent(f), encoding: .utf8)) ?? ""
        let imports = s.split(separator: "\n").filter { $0.hasPrefix("import ") }.map { String($0.dropFirst(7)) }
        check(Set(imports).isSubset(of: ["Foundation", "CryptoKit", "ProfileCore", "Runs"]),
              "\(f): imports only Foundation, CryptoKit, ProfileCore and Runs (the one runner): \(imports)")
        check(!s.contains("Process()"), "\(f): starts no process of its own (Runs' Runner does)")
        for bad in ["print(", "NSLog", "Logger(", "os_log", "debugPrint", "dump("] { check(!s.contains(bad), "\(f): never logs or prints (\(bad))") }
        for bad in ["add-generic-password", "delete-generic-password", "SecItemAdd", "SecItemUpdate", "SecItemDelete"] {
            check(!s.contains(bad), "\(f): never writes the Keychain (\(bad))")
        }
        // ClaudeAuth keeps nothing of its own in the preferences: the one use is ClaudeSignIn's look at (and removal from)
        // Terminal's kept window profiles, in Terminal's own domain, through the preferences system
        let defaults = s.components(separatedBy: "UserDefaults").count - 1
        if f == "ClaudeSignIn.swift" {
            check(defaults == s.components(separatedBy: "UserDefaults(suiteName: \"com.apple.Terminal\")").count - 1,
                  "\(f): its only use of the preferences is Terminal's own domain (com.apple.Terminal)")
        } else {
            check(defaults == 0, "\(f): keeps nothing in the preferences (UserDefaults)")
        }
        // the Keychain read is Keychain.swift's alone (an app that never reads it leaves that file out and still builds)
        if f != "Keychain.swift" {
            for bad in ["KeychainSignIn", "/usr/bin/security", "find-generic-password", "SecItem", "import Security"] {
                check(!s.contains(bad), "\(f): no Keychain outside Keychain.swift (\(bad))")
            }
        }
    }
    let core = repo.appendingPathComponent("Core")
    for f in ((try? fm.contentsOfDirectory(atPath: core.path)) ?? []).filter({ $0.hasSuffix(".swift") }) {
        let s = (try? String(contentsOf: core.appendingPathComponent(f), encoding: .utf8)) ?? ""
        check(!s.contains("import ClaudeAuth") && !s.contains("import Security"), "Core/\(f): never imports ClaudeAuth or Security")
    }
}

print("auth: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
