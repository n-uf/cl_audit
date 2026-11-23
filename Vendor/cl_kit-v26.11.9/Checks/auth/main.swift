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
    check(other["KEEP"] == nil && other["HOME"] == home, "an allow-list: HOME stays, anything not on it (KEEP) doesn't")
    check(other["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin", "the install places first on PATH: \(other["PATH"] ?? "")")
    check(AuthFolder(path: "~/.claude-work", home: home).environment(base, claude: "/opt/sample/bin/claude")["PATH"]
            == "/opt/sample/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin"
          && other["DISABLE_TELEMETRY"] == "1" && other["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == nil
          && AuthFolder(path: "~/.claude-work", home: home).environment(base, traceless: true)["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] == "1",
          "claude's own folder first when given; non-essential traffic off; traceless only when asked")
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
    check(p!.maybeSame(r!) && r!.maybeSame(p!), "no id on one side: the address (any case) and the organisation's name")
    check(!SignedInAccount(email: "ann@example.com", organizationName: "Other Org", origin: .process).maybeSame(r!),
          "the same address in another organisation: another account (a personal plan and a team seat)")
    check(SignedInAccount(email: "ann@example.com", origin: .process).maybeSame(r!), "an organisation only one side names doesn't tell them apart")
    check(!SignedInAccount(email: "bob@example.com", organizationName: "Example Org", origin: .process).maybeSame(r!), "another address")
    check(!SignedInAccount(organizationName: "Example Org", origin: .process).maybeSame(SignedInAccount(organizationName: "Example Org", origin: .record)),
          "no address and no id: never the same")
    check(SignedInAccount(accountID: uuid(1).uppercased(), organizationID: uuid(51), origin: .server).maybeSame(r!),
          "both with ids: the ids, whatever the case")
    check(!SignedInAccount(accountID: uuid(2), email: "ann@example.com", organizationID: uuid(51), origin: .server).maybeSame(r!),
          "both with ids: the ids decide, not the address")
    check(!SignedInAccount(accountID: uuid(1), organizationID: uuid(52), origin: .server).maybeSame(r!), "the same id in another organisation")
    check(SignedInAccount(accountID: uuid(3), organizationID: "", origin: .server).organizationID == nil
          && SignedInAccount(accountID: uuid(3), organizationID: " ", origin: .server).maybeSame(SignedInAccount(accountID: uuid(3), origin: .record)),
          "an empty organisation is kept as none, and none on both sides is the same")
    check(SignedInAccount(accountID: uuid(3), origin: .server).match(SignedInAccount(accountID: uuid(3), organizationID: uuid(51), origin: .record)) == .seatNotKnown,
          "both with ids: an organisation only one side has is the same account, its seat not known (the one comparison)")
    check(SignedInAccount(email: " ann@example.com\n", origin: .process).email == "ann@example.com"
          && SignedInAccount(email: "ann@example.com ", origin: .process).maybeSame(r!), "values are kept trimmed")
    check(p!.match(r!) == .seat && SignedInAccount(email: "ann@example.com", origin: .process).match(r!) == .seatNotKnown
          && bobWord().match(r!) == .different, "match: seat, seat not known, different")
    check(!SignedInAccount(email: "ann@example.com", organizationID: uuid(52), organizationName: "Example Org", origin: .server).maybeSame(r!),
          "by address: the organisations' ids when both have one, before their names")
    check(r!.identity == AccountIdentity(account: uuid(1), email: "ann@example.com", organization: uuid(51), organizationName: "Example Org",
                                         source: .guessed),
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
    check(loose.verdict == .seatNotKnown && loose.account?.accountID == nil && loose.account?.organizationID == nil && loose.account?.plan == nil
          && loose.record == r, "the same address but no organisation to compare: seat not known, without the record's ids or plan (maybe another seat's)")
    let alone = FolderSignIn.answer(record: nil, verified: s)
    check(alone.verdict == .verified && alone.account == s, "a verified word with no record: verified")
    check(FolderSignIn.answer(record: nil, verified: r).verdict == .none, "a record passed as the verified word is never taken for one")
    check(agreed.isSignedIn(to: SignedInAccount(accountID: uuid(1), organizationID: uuid(51), origin: .record))
          && !none.isSignedIn(to: r!), "isSignedIn(to:)")
}

// ============ 4b. the account rule, settled: one case per disagreement (D1-D5) and per risk ============
// Samples: wu@example.com with a personal plan and a Team seat (one address, one account id, two organisations), and
// zedekiah@example.com. Ids are zero-pattern; nothing real is read.
do {
    let wuID = uuid(101), zedID = uuid(102), personal = uuid(151), team = uuid(152)
    let wuPersonal = SignedInAccount(accountID: wuID, email: "wu@example.com", organizationID: personal,
                                     organizationName: "Wu Personal", plan: "Max", origin: .record)
    let wuTeam = SignedInAccount(accountID: wuID, email: "wu@example.com", organizationID: team,
                                 organizationName: "Example Team", plan: "Team", origin: .record)
    let zed = SignedInAccount(accountID: zedID, email: "zedekiah@example.com", organizationID: uuid(153),
                              organizationName: "Zed Org", plan: "Pro", origin: .record)
    /// A running claude's `initialize` account, as it says it (an address and maybe its organisation's name; no ids).
    func word(_ email: String, _ org: String?) -> SignedInAccount {
        var a: [String: Any] = ["email": email]
        if let org { a["organization"] = org }
        return SignedInAccount.process(a)!
    }

    // D1 · signed in when the id OR the address names someone
    let idOnly = SignedInAccount.record(["accountUuid": wuID, "organizationUuid": personal])
    let addressOnly = SignedInAccount.record(["emailAddress": "wu@example.com"])
    check(FolderSignIn.answer(record: idOnly, verified: nil).isSignedIn && FolderSignIn.answer(record: addressOnly, verified: nil).isSignedIn,
          "D1: a record with an account id alone, or an address alone, is signed in")
    check(FolderSignIn.answer(record: nil, verified: word("wu@example.com", nil)).isSignedIn,
          "D1: a running claude's word alone (an address, no id) is signed in")
    check(!FolderSignIn.answer(record: SignedInAccount.record(["planDisplayName": "Max"]), verified: nil).isSignedIn,
          "D1: a record that names nobody is signed out")
    let placeholder = AccountKey(addressOnly!)
    check(placeholder?.account == "email:wu@example.com" && placeholder?.isPlaceholder == true && placeholder?.seatKnown == false,
          "D1: a saved key with no id yet: the address stands in, seat not known")
    let upgraded = placeholder?.upgraded(with: wuTeam)
    check(upgraded == AccountKey(account: wuID) && upgraded?.isPlaceholder == false && upgraded?.seatKnown == false,
          "D1: the placeholder is upgraded in place once the id appears; the seat stays not known (the first seen isn't the numbers')")
    check(placeholder?.upgraded(with: zed) == nil, "D1: never upgraded with another account's id")
    check(AccountKey(SignedInAccount(accountID: wuID.uppercased(), email: "WU@example.com", origin: .record))?.account == wuID,
          "D1: a key's id in its normal form")

    // D2 · a personal plan and a Team seat on one address are two seats
    check(wuPersonal.match(wuTeam) == .different && !wuPersonal.identity.matches(wuTeam.identity),
          "D2: one address, one account id, two organisations: two seats (both comparisons are one)")
    check(AccountKey(wuPersonal) != AccountKey(wuTeam) && AccountKey(wuTeam)?.text == wuID + "|" + team,
          "D2: two saved keys, (account id, organisation)")
    let teamWord = FolderSignIn.answer(record: wuPersonal, verified: word("wu@example.com", "Example Team"))
    check(teamWord.verdict == .differs && teamWord.account?.organizationID == nil && teamWord.account?.plan == nil
          && teamWord.numbersBelongTo?.organizationName == "Example Team" && teamWord.numbersBelongTo?.organizationID != personal,
          "D2: the process on the Team seat, the record on the personal plan: differs, the numbers the Team seat's, nothing of the personal plan's")
    let noOrg = FolderSignIn.answer(record: wuTeam, verified: word("wu@example.com", nil))
    check(noOrg.verdict == .seatNotKnown && noOrg.account?.accountID == nil && noOrg.account?.organizationID == nil
          && noOrg.account?.plan == nil && noOrg.numbersBelongTo == noOrg.verified,
          "D2: only one side names an organisation: same address, seat not known, no plan or ids borrowed from the record")
    check(AccountKey(account: wuID).upgraded(with: wuTeam) == AccountKey(account: wuID)
          && AccountKey(account: wuID).upgraded(with: wuPersonal) == AccountKey(account: wuID),
          "D2: a key with no seat isn't given the first seat seen on its account: it stays apart")
    check(AccountKey(account: wuID).upgraded(with: wuTeam, seatOfTheNumbers: true) == AccountKey(wuTeam)
          && AccountKey(wuPersonal)?.upgraded(with: wuTeam, seatOfTheNumbers: true) == nil,
          "D2: ...only when the caller says the numbers' own source named that seat; a seat's key never moves to the other seat")
    check(AccountKey(account: wuID.uppercased(), organization: team.uppercased()) == AccountKey(wuTeam)
          && AccountKey(text: AccountKey(wuTeam)!.text.uppercased()) == AccountKey(wuTeam), "a key as written: case doesn't count")
    let savedUpper = Data(#"{"account":"\#(wuID.uppercased())","organization":"\#(team.uppercased())"}"#.utf8)
    check((try? JSONDecoder().decode(AccountKey.self, from: savedUpper)) == AccountKey(wuTeam)
          && (try? JSONDecoder().decode(AccountKey.self, from: JSONEncoder().encode(placeholder!))) == placeholder,
          "a saved key read back: in lower case, its round trip unchanged")
    // a key with an id holds no address: the address the app saved beside it is added for the comparison
    let teamKey = AccountKey(wuTeam)!
    check(teamKey.identity.email == nil && teamKey.identity(email: "wu@example.com").email == "wu@example.com"
          && teamKey.identity(email: "wu@example.com").accountID == wuID && teamKey.identity(email: " ").email == nil
          && placeholder!.identity(email: "zedekiah@example.com").email == "wu@example.com",
          "identity(email:): the saved address beside an id key; an empty one is none; a placeholder keeps its own")
    check(teamKey.match(word("wu@example.com", "Example Team")) == .different
          && teamKey.match(word("wu@example.com", "Example Team"), email: "wu@example.com") == .seatNotKnown
          && teamKey.match(word("zedekiah@example.com", "Example Team"), email: "wu@example.com") == .different
          && AccountKey(account: wuID, organization: AccountKey.namePrefix + "example team")
               .match(word("WU@example.com", "EXAMPLE TEAM"), email: "wu@example.com") == .seat,
          "match(_:email:): a running claude's word (no id) compared with an id key by its saved address; the organisation by name where the key keeps one")
    check(AccountKey(account: AccountKey.addressPrefix + "wu@example.com", organization: AccountKey.namePrefix + "example team")
            .upgraded(with: wuTeam) == AccountKey(wuTeam)
          && AccountKey(account: wuID, organization: AccountKey.namePrefix + "example team").upgraded(with: wuPersonal) == nil,
          "D2: a name placeholder becomes the organisation's id for the same seat, never for the other")
    check(AccountKey(text: AccountKey(wuTeam)!.text) == AccountKey(wuTeam) && AccountKey(text: placeholder!.text) == placeholder
          && AccountKey(text: AccountKey(account: "email:a|b%c@example.com", organization: "name:x|y").text)
             == AccountKey(account: "email:a|b%c@example.com", organization: "name:x|y")
          && AccountKey(text: "") == nil && AccountKey(text: "a|b|c") == nil, "D2: a key's text reads back, '|' and '%' escaped")

    // D3 · a verified word beats the record, and the numbers stay with it
    let landed = FolderSignIn.answer(record: zed, verified: word("wu@example.com", "Wu Personal"))
    check(landed.verdict == .differs && landed.account?.email == "wu@example.com" && landed.record == zed
          && landed.numbersBelongTo?.email == "wu@example.com" && landed.numbersBelongTo?.accountID != zedID,
          "D3: the process says wu, the record zedekiah: differs, the numbers wu's, never moved to zedekiah")
    let serverReply = try! JSONSerialization.data(withJSONObject: ["account": ["uuid": wuID, "email_address": "wu@example.com"],
                                                                   "organization": ["uuid": personal, "name": "Wu Personal"]])
    let server = SignedInAccount.server(serverReply)
    check(FolderSignIn.answer(record: wuTeam, verified: server).verdict == .differs
          && FolderSignIn.answer(record: wuTeam, verified: server).numbersBelongTo?.organizationID == personal,
          "D3: Anthropic's reply for the stored sign-in is the same kind of verified word: it beats the record")
    let agreed = FolderSignIn.answer(record: wuPersonal, verified: server)
    check(agreed.verdict == .verified && agreed.numbersBelongTo?.plan == "Max" && agreed.numbersBelongTo?.organizationID == personal,
          "D3: the verified word and the record on one seat: verified, the record's plan added")
    check(FolderSignIn.answer(record: wuPersonal, verified: nil).numbersBelongTo == nil,
          "D3: the record alone is a guess: no numbers are its")

    // D4 · the kit answers Claude Code's account only, and calls nothing plainly "in use" (the lint in 9 holds the names)
    check(FolderSignIn.answer(record: wuPersonal, verified: nil).account == wuPersonal, "D4: Claude Code's account is the folder's")

    // D5 · the organisation's id decides when both have one; else its name, case not counting
    check(FolderSignIn.answer(record: wuTeam, verified: word("WU@example.com", "EXAMPLE TEAM")).verdict == .verified,
          "D5: the name in another case is the same organisation")
    let renamedByID = SignedInAccount(accountID: wuID, organizationID: team, organizationName: "Another Name", origin: .server)
    check(renamedByID.match(wuTeam) == .seat, "D5: the ids agree: the names don't count")
    check(SignedInAccount(accountID: wuID, organizationID: personal, organizationName: "Example Team", origin: .server).match(wuTeam) == .different,
          "D5: the ids differ: the same name doesn't make them one")

    // risk · a sign-in under a running claude: the file names the new account before the process stops
    var chat = ProcessTrail(launchedOn: wuPersonal)
    chat.said(word("wu@example.com", "Wu Personal"))
    check(chat.verified?.accountID == wuID && chat.verified?.organizationID == personal && chat.verified?.origin == .process,
          "risk: the word on the seat it started on takes the launch record's ids and organisation id")
    let under = FolderSignIn.answer(record: zed, trail: chat)
    check(under.verdict == .differs && under.numbersBelongTo?.accountID == wuID && under.numbersBelongTo?.organizationID == personal,
          "risk: a sign-in to zedekiah under a running claude on wu: differs, the numbers wu's (with its ids), never zedekiah's")
    check(FolderSignIn.answer(record: wuTeam, trail: chat).verdict == .differs
          && FolderSignIn.answer(record: wuTeam, trail: chat).numbersBelongTo?.organizationID == personal,
          "risk: a switch to the Team seat on the same address under it: differs, the numbers stay the personal plan's")

    // risk · personal plus Team on one address, the process started just after a sign-in landed
    var early = ProcessTrail(launchedOn: wuPersonal)
    early.said(word("wu@example.com", "Example Team"))
    check(early.verified?.accountID == nil && early.verified?.organizationID == nil && early.verified?.plan == nil,
          "risk: a word on another seat than the launch record takes nothing from it")
    check(FolderSignIn.answer(record: wuTeam, trail: early).verdict == .verified
          && FolderSignIn.answer(record: wuTeam, trail: early).numbersBelongTo?.organizationID == team,
          "risk: ...and once the record names the Team seat, the two agree on it")

    // risk · one-sided organisation: same address, seat not known, nothing borrowed
    var unnamed = ProcessTrail(launchedOn: wuTeam)
    unnamed.said(word("wu@example.com", nil))
    let oneSided = FolderSignIn.answer(record: wuTeam, trail: unnamed)
    check(oneSided.verdict == .seatNotKnown && oneSided.numbersBelongTo?.organizationID == nil && oneSided.numbersBelongTo?.plan == nil,
          "risk: a word with no organisation against a Team seat's record: seat not known, no plan or ids taken")
    check(AccountKey(oneSided.numbersBelongTo!)?.seatKnown == false, "risk: ...its numbers keyed as a seat not known, never onto both seats")

    // risk · an organisation renamed while the process runs keeps its numbers
    var renamed = ProcessTrail(launchedOn: wuTeam)
    renamed.said(word("wu@example.com", "Example Team"))
    var wuTeamRenamed = wuTeam; wuTeamRenamed.organizationName = "Example Team Renamed"
    check(FolderSignIn.answer(record: wuTeamRenamed, trail: renamed).verdict == .verified
          && FolderSignIn.answer(record: wuTeamRenamed, trail: renamed).numbersBelongTo?.organizationID == team,
          "risk: renamed while it runs: the launch organisation id says it is the same seat, the numbers stay")
    check(FolderSignIn.answer(record: wuTeamRenamed, verified: word("wu@example.com", "Example Team")).verdict == .differs,
          "risk: ...which the word alone, without its trail, can't tell")

    // risk · a process that said nothing is trusted only while the record names the seat it started on
    var silent = ProcessTrail(launchedOn: wuPersonal)
    silent.said(SignedInAccount.process(["apiProvider": "firstParty"]))
    silent.said(wuPersonal)
    check(silent.word == nil && silent.verified == nil, "risk: a word naming nobody, or a record passed for one, isn't a word")
    var rewritten = wuPersonal; rewritten.plan = "Max 20x"
    let unchanged = FolderSignIn.answer(record: rewritten, trail: silent)
    check(unchanged.verdict == .guessed && unchanged.numbersBelongTo == rewritten,
          "risk: silent, the record rewritten for the same seat: its numbers the record's")
    let moved = FolderSignIn.answer(record: zed, trail: silent)
    check(moved.verdict == .guessed && moved.account == zed && moved.numbersBelongTo == nil,
          "risk: silent, the record changed to zedekiah since its launch: its numbers are no one's")
    check(FolderSignIn.answer(record: wuTeam, trail: silent).numbersBelongTo == nil && FolderSignIn.answer(record: nil, trail: silent).numbersBelongTo == nil
          && FolderSignIn.answer(record: wuPersonal, trail: ProcessTrail(launchedOn: nil)).numbersBelongTo == nil,
          "risk: ...nor after a switch to the other seat, a sign-out, or with nobody named at its launch")
}

// ============ 4b2. finding accounts on this Mac: each source on a throwaway home with sample records ============
do {
    let h = home + "/finding"
    mkdir(h + "/.claude/backups"); mkdir(h + "/.claude-work/backups"); mkdir(h + "/.claude-switch/accounts/alt")
    mkdir(h + "/.claude-notes")
    let wu = uuid(201), zed = uuid(202), personal = uuid(251), team = uuid(252)
    // the default folder's record is in the home folder; its backups beside it and in ~/.claude/backups
    record(h + "/.claude.json", email: "wu@example.com", account: wu.uppercased(), org: personal, orgName: "Wu Personal", plan: "Max")
    record(h + "/.claude.json.backup.1700000000", email: "wu@example.com", account: wu, org: team, orgName: "Example Team")
    record(h + "/.claude/backups/.claude.json.backup.1", email: "zedekiah@example.com", account: zed, org: uuid(253))
    record(h + "/.claude-work/.claude.json", email: "zedekiah@example.com", account: zed, org: uuid(253), plan: "Pro")
    record(h + "/.claude-switch/accounts/alt/.claude.json", email: "wu@example.com", account: wu, org: team)
    write(h + "/.claude-notes/.claude.json", #"{"oauthAccount":{"accountUuid":"not-an-id","emailAddress":"wu@example.com","accessToken":"never-read"}}"#)
    try? fm.createSymbolicLink(atPath: h + "/.claude-linked", withDestinationPath: h + "/.claude-work")

    let def = AuthFolder(path: "~/.claude", home: h), work = AuthFolder(path: "~/.claude-work", home: h)
    check(AccountSources.folderRecordFiles(def) == [h + "/.claude.json", h + "/.claude/backups/.claude.json.backup.1", h + "/.claude.json.backup.1700000000"]
          && AccountSources.folderRecordFiles(work) == [h + "/.claude-work/.claude.json"],
          "a folder's record and its backups (the default folder's in the home folder too), names only")
    check(AccountSources.claudeFolders(home: h) == ["~/.claude", "~/.claude-linked", "~/.claude-notes", "~/.claude-work"],
          "the Claude Code folders in a home: ~/.claude first, then ~/.claude-*, a link to a folder too; never ~/.claude-switch")
    // a linked default folder (a dotfiles set-up): found, and it is the default folder, its backups read through the link
    let h2 = home + "/finding-linked"
    mkdir(h2 + "/dotfiles/claude/backups"); mkdir(h2 + "/real-work")
    try? fm.createSymbolicLink(atPath: h2 + "/.claude", withDestinationPath: h2 + "/dotfiles/claude")
    try? fm.createSymbolicLink(atPath: h2 + "/.claude-work", withDestinationPath: h2 + "/real-work")
    write(h2 + "/.claude-file", "not a folder")
    record(h2 + "/dotfiles/claude/backups/.claude.json.backup", email: "wu@example.com", account: wu, org: personal)
    let linkedDefault = AuthFolder(path: "~/.claude", home: h2)
    check(AccountSources.claudeFolders(home: h2) == ["~/.claude", "~/.claude-work"] && linkedDefault.isDefault
          && AccountSources.folderRecordFiles(linkedDefault) == [h2 + "/.claude.json", h2 + "/.claude/backups/.claude.json.backup"],
          "a linked ~/.claude and ~/.claude-*: found (never a file); the linked default folder's backups through the link")
    // backups by their exact names
    check(AccountSources.isBackupName(".claude.json.backup") && AccountSources.isBackupName(".claude.json.backup.1700000000123")
          && !AccountSources.isBackupName(".claude.json.backup.") && !AccountSources.isBackupName(".claude.json.backup.old")
          && !AccountSources.isBackupName(".claude.json.backupX") && !AccountSources.isBackupName(".claude.json.backup.1.2")
          && !AccountSources.isBackupName(".claude.json") && !AccountSources.isBackupName(".claude.json.backup.١٢٣"),
          "a backup's name: .claude.json.backup, or that, a dot and ASCII digits; nothing else")
    let homeFiles = AccountSources.homeRecordFiles(home: h)
    check(homeFiles.contains(h + "/.claude.json") && homeFiles.contains(h + "/.claude-work/.claude.json")
          && homeFiles.contains(h + "/.claude-switch/accounts/alt/.claude.json") && homeFiles.contains(h + "/.claude-linked/.claude.json"),
          "every record in the home: each ~/.claude* and the switch folder's accounts")
    let own = AccountSources.records(AccountSources.folderRecordFiles(def))
    check(own.map(\.accountID) == [wu, zed, wu] && own[0].organizationID == personal && own[0].email == "wu@example.com"
          && own[0].plan == "Max" && own[0].organizationName == "Wu Personal" && own[0].source == .record
          && own[1].source == .backup && own[2].organizationID == team,
          "the records' named fields: the id in its normal form, a backup told apart")
    let all = AccountSources.records(homeFiles)
    let notes = all.first { $0.path.hasSuffix(".claude-notes/.claude.json") }
    check(notes?.accountID == "not-an-id" && notes?.email == "wu@example.com" && notes?.seat == nil,
          "a record whose account id isn't UUID-shaped: kept with its address and plan (as cl_audit kept them), naming no seat; no token field exists")
    var odd = FoundAccounts(all.filter { $0.accountID == "not-an-id" })
    odd.add([FoundAccount(accountID: zed, organizationID: uuid(254), organizationType: "claude_max", source: .record, path: "r1")!,
             FoundAccount(accountID: zed, organizationID: uuid(254), organizationName: "Later Name", source: .record, path: "r2")!,
             FoundAccount(accountID: uuid(205), plan: " Max ", source: .record, path: "r3")!])
    check(odd.emails["not-an-id"] == "wu@example.com" && odd.seats == [SeatID(account: zed, organization: uuid(254))]
          && odd.organizationTypes[uuid(254)] == "claude_max" && odd.organizationNames[uuid(254)] == nil
          && odd.plans[uuid(205)] == " Max " && odd.idsAlone.isEmpty && odd.accounts == ["not-an-id", zed, uuid(205)],
          "an organisation's name and type from one record (a type without a name keeps no later name); a plan as written; a record with no organisation is never an id alone; accounts in the order seen")
    check(FoundAccount(accountID: "", source: .record, path: "x") == nil
          && FoundAccount(accountID: uuid(206).uppercased(), organizationID: "", source: .record, path: "x")?.organizationID == nil,
          "a sighting needs an account id; an empty organisation is none; ids in their normal form")
    var found = FoundAccounts(own)
    found.add(AccountSources.records([work.recordPath]))
    check(found.seats == [SeatID(account: wu, organization: personal), SeatID(account: zed, organization: uuid(253)), SeatID(account: wu, organization: team)]
          && found.organization(of: wu.uppercased()) == personal && found.emails[zed] == "zedekiah@example.com"
          && found.plans[wu] == "Max" && found.plans[zed] == "Pro" && found.organizationNames[team] == "Example Team",
          "put together, first seen first: the record's organisation before a backup's; a later plan fills only what was missing")

    // the desktop app's sessions (an option: cl_audit's)
    let data = h + "/AppData"
    let code = data + "/claude-code-sessions/\(wu)/\(team)", agent = data + "/local-agent-mode-sessions/\(zed.uppercased())/\(uuid(253))"
    mkdir(code); mkdir(agent); mkdir(data + "/claude-code-sessions/not-an-id/\(team)")
    write(code + "/local_\(uuid(301)).json", "{}"); write(code + "/notes.txt", "x")
    write(agent + "/session.json", #"{"emailAddress":"zedekiah@example.com","messages":[]}"#)
    let used = Date(timeIntervalSince1970: 1_800_000_000)
    try? fm.setAttributes([.modificationDate: used], ofItemAtPath: code + "/local_\(uuid(301)).json")
    let sessions = AccountSources.appSessions(dataDir: data)
    check(sessions.count == 2 && sessions[0] == FoundAccount(accountID: wu, organizationID: team, lastUsed: used, source: .appSessions, path: code)
          && sessions[1].accountID == zed && sessions[1].email == "zedekiah@example.com" && sessions[1].source == .appAgentSessions,
          "the desktop app's sessions: UUID-named pairs, the last entry's date; an agent session's address")
    check(AccountSources.isEntryName("local_\(uuid(301)).json") && !AccountSources.isEntryName("notes.txt") && AccountSources.appSessions(dataDir: h + "/none").isEmpty,
          "entries by name; no data folder, no sessions")
    // agent records: bounded (1 MB by default), never through a link, never opened for an address already known
    let agent2 = data + "/local-agent-mode-sessions/\(uuid(207))/\(uuid(257))"
    mkdir(agent2)
    write(agent2 + "/big.json", #"{"emailAddress":"wu@example.com","pad":""# + String(repeating: "x", count: 2 << 20) + "\"}")
    write(h + "/outside.json", #"{"emailAddress":"zedekiah@example.com"}"#)
    try? fm.createSymbolicLink(atPath: agent2 + "/linked.json", withDestinationPath: h + "/outside.json")
    let s2 = AccountSources.appSessions(dataDir: data).first { $0.accountID == uuid(207) }
    check(s2 != nil && s2?.email == nil, "an agent record over 1 MB isn't opened, a linked one is never followed: no address")
    check(AccountSources.appSessions(dataDir: data, knownAccounts: [zed.uppercased()]).first { $0.accountID == zed }?.email == nil
          && AccountSources.appSessions(dataDir: data, records: -1).first { $0.accountID == zed }?.email == nil
          && AccountSources.appSessions(dataDir: data, max: -5).first { $0.accountID == zed }?.email == nil
          && AccountSources.appSessions(dataDir: data, max: 1 << 10).first { $0.accountID == zed }?.email == "zedekiah@example.com",
          "an account whose address is known: its records never opened; a negative count or size opens none; a small one still reads a small record")
    mkdir(h + "/AppDataRootLink")
    try? fm.createSymbolicLink(atPath: h + "/AppDataRootLink/claude-code-sessions", withDestinationPath: data + "/claude-code-sessions")
    check(AccountSources.appSessions(dataDir: h + "/AppDataRootLink").isEmpty,
          "a session root that is a link is never followed")

    // transcripts (an option: cl_audit's; it reads chats)
    mkdir(h + "/.claude-work/projects/p1")
    write(h + "/.claude-work/projects/p1/a.jsonl", #"{"type":"user","accountUuid":"\#(zed.uppercased())"}"# + "\n" + #"{"accountUuid":"\#(wu)"}"#)
    write(h + "/.claude-work/projects/p1/late.jsonl", String(repeating: " ", count: 70_000) + #"{"accountUuid":"\#(uuid(209))"}"#)
    check(mkfifo(h + "/.claude-work/projects/p1/pipe.jsonl", 0o600) == 0, "a FIFO made")
    let t = Date()
    let ids = AccountSources.transcriptAccounts(folder: work)
    check(Set(ids.map(\.accountID)) == [zed, wu] && ids.allSatisfy { $0.organizationID == nil && $0.source == .transcript }
          && Date().timeIntervalSince(t) < 2, "transcripts: ids alone, from each one's first 64 KB only, a FIFO skipped at once")
    found.add(ids)
    check(found.idsAlone.isEmpty && found.accounts == [wu, zed], "an id alone already seen by a seat adds nothing")
    found.add([FoundAccount(accountID: uuid(210), source: .transcript, path: "x")!])
    check(found.idsAlone == [uuid(210)] && found.accounts.last == uuid(210), "a new id alone is kept apart (no organisation known)")
    // the cap and the head with other transcripts present; links never followed out of the folder; negative sizes
    let p2 = h + "/.claude-work/projects/p2"
    mkdir(p2)
    write(p2 + "/newest.jsonl", #"{"accountUuid":"\#(uuid(211))"}"#)
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: p2 + "/newest.jsonl")
    check(AccountSources.transcriptAccounts(folder: work, cap: 1).map(\.accountID) == [uuid(211)],
          "the cap: only the newest transcripts are read")
    check(Set(AccountSources.transcriptAccounts(folder: work, head: 70).map(\.accountID)) == [uuid(211), zed]
          && AccountSources.transcriptAccounts(folder: work, cap: -1).isEmpty && AccountSources.transcriptAccounts(folder: work, head: -1).isEmpty,
          "the head: only the first bytes of each, whatever else is there; a negative cap or head reads nothing")
    mkdir(h + "/elsewhere/p")
    write(h + "/elsewhere/p/x.jsonl", #"{"accountUuid":"\#(uuid(212))"}"#)
    write(h + "/elsewhere/y.jsonl", #"{"accountUuid":"\#(uuid(213))"}"#)
    try? fm.createSymbolicLink(atPath: h + "/.claude-work/projects/linked", withDestinationPath: h + "/elsewhere/p")
    try? fm.createSymbolicLink(atPath: p2 + "/linked.jsonl", withDestinationPath: h + "/elsewhere/y.jsonl")
    let after = Set(AccountSources.transcriptAccounts(folder: work).map(\.accountID))
    check(!after.contains(uuid(212)) && !after.contains(uuid(213)) && after.contains(uuid(211)),
          "a linked project folder or transcript is never followed out of the folder")
    check(RecordFile.head(h + "/.claude-work/projects/p1/late.jsonl", bytes: 10)?.count == 10 && RecordFile.head(h + "/none", bytes: 10) == nil,
          "RecordFile.head: the first bytes whatever the size; nothing for a file that isn't there")
}

// ============ 4c. the one folder reader ============
do {
    mkdir(home + "/.claude-reader")
    let folder = AuthFolder(path: "~/.claude-reader", home: home)
    var parses = 0
    // the record's real file and parse, with a stamp that moves by each write here (no waiting on the clock)
    var writes = 0
    func write(_ email: String?, _ account: String?, _ org: String?, orgName: String? = nil, plan: String? = nil) {
        record(folder.recordPath, email: email, account: account, org: org, orgName: orgName, plan: plan); writes += 1
    }
    let stamp: (String) -> RecordStamp = { fm.fileExists(atPath: $0) ? RecordStamp(size: UInt64(writes)) : .none }
    let reader = FolderRecordReader(parse: { parses += 1; return RecordFile.oauthAccount($0) }, stamp: stamp)
    check(reader.look(folder) == FolderRecordReader.Look(account: nil, stamp: .none, generation: 0, changed: false) && parses == 0,
          "no record: nobody, nothing parsed")
    write("wu@example.com", uuid(101), uuid(151), orgName: "Wu Personal", plan: "Max")
    var l = reader.look(folder)
    check(l.account?.accountID == uuid(101) && l.account?.organizationName == "Wu Personal" && !l.changed && l.generation == 0 && parses == 1,
          "the first parse: the record's named fields, no change")
    check(!reader.look(folder).changed && parses == 1, "an unchanged stamp: not parsed again")
    write("wu@example.com", uuid(101), uuid(151), orgName: "Wu Personal", plan: "Max 20x")
    l = reader.look(folder)
    check(!l.changed && l.generation == 0 && l.account?.plan == "Max 20x" && parses == 2, "rewritten for the same seat: parsed, no change")
    write("wu@example.com", uuid(101), nil)
    check(reader.look(folder).generation == 0, "the organisation lost (a seat only not known now): the same account, no change")
    write("wu@example.com", uuid(101), uuid(151), orgName: "Wu Personal")
    check(reader.look(folder).generation == 0, "...and gained back: no change")
    write("wu@example.com", uuid(101), uuid(152), orgName: "Example Team")
    // two callers (the menu, the watch) each keep the generation they last saw: each sees the change, whoever parsed it
    let menuSaw = 0, watchSaw = 0
    let first = reader.look(folder), second = reader.look(folder)
    check(first.changed && !second.changed && first.generation == 1 && second.generation == 1
          && second.generation != menuSaw && second.generation != watchSaw,
          "another seat now (the organisation's id differs): one change, seen by every caller through the generation")
    write(nil, nil, nil)
    l = reader.look(folder)
    check(l.changed && l.generation == 2 && l.account == nil, "signed out: a change, nobody named")
    write("wu@example.com", uuid(101), uuid(152))
    check(reader.look(folder).generation == 3, "signed in after it: a change")
    reader.forget(path: folder.recordPath)
    write("zedekiah@example.com", uuid(102), uuid(153))
    check(!reader.look(folder).changed && reader.look(folder).generation == 0, "forgotten: the next look is a first parse")
    // the watch and the authenticator read through the one reader: one parse for both
    var w = SignInChangeWatch()
    var tools = fakes; tools.reader = reader; tools.readRecord = { _ in fatalError("the reader was passed: readRecord isn't asked") }
    let auth = Authenticator(folder, tools: tools)
    let before = parses
    check(!w.look(reader, folder: folder) && auth.record()?.accountID == uuid(102) && parses == before,
          "the watch and Authenticator.record share the reader's parse")
    write("wu@example.com", uuid(101), uuid(152))
    check(w.look(reader, folder: folder) && parses == before + 1 && auth.record()?.accountID == uuid(101) && parses == before + 1,
          "another account: the watch says so, both read the one new parse")
    write(nil, nil, nil)
    check(!w.look(reader, folder: folder) && reader.look(folder).generation > 0,
          "signed out: no change for the watch (it says only that another account signed in), a change for the reader")
    // a parse a write overtook is never kept
    var tick = 0
    let racing = FolderRecordReader(parse: { _ in parses += 1; return ["emailAddress": "wu@example.com"] },
                                    stamp: { _ in tick += 1; return RecordStamp(size: UInt64(tick)) })
    parses = 0
    _ = racing.look(path: "/nowhere"); _ = racing.look(path: "/nowhere")
    check(parses == 2, "the stamp moved while it read: not kept, parsed again next look")
    check(mkfifo(home + "/.claude-reader/fifo.json", 0o600) == 0, "a FIFO made")
    let t = Date()
    check(FolderRecordReader().look(path: home + "/.claude-reader/fifo.json").account == nil && Date().timeIntervalSince(t) < 2,
          "a FIFO: nobody, at once")
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
    check(auth.signIn(verified: SignedInAccount.process(["email": "bob@example.com"])).verdict == .seatNotKnown,
          "...with a process's word that names no organisation (the record names one): seat not known")
    check(auth.signIn(verified: SignedInAccount(email: "bob@example.com", organizationID: uuid(51), origin: .server)).verdict == .verified,
          "...verified with a word on the same seat")
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
                                    environment: folder.environment(tools.environment(), claude: claude), timeout: 120),
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
        // D4: ClaudeAuth answers "Claude Code's account" and declares nothing named plainly "in use" (that word is for an
        // app's own question, the one its rows tick): no type, function, property, enum case or extension member, at any
        // access level. ClaudeAuth only: ProfileCore's older Headline.Owner.inUse is outside this lint. Tuple labels aren't
        // declarations (TerminalProfiles' `inUse`: the window settings Terminal itself names as its default or startup ones,
        // not an account).
        let declaration = try! NSRegularExpression(pattern: #"\b(case|func|var|let|struct|enum|class|protocol|typealias|actor)\s+`?(\w+)"#)
        for line in s.split(separator: "\n").map(String.init) {
            let code = line.components(separatedBy: "//")[0]
            var names = declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)).map {
                (code as NSString).substring(with: $0.range(at: 2))
            }
            // every name of an enum's case list ("case a, b(X), c")
            if let r = code.range(of: #"^\s*(public\s+)?(indirect\s+)?case\s+[A-Za-z_`]"#, options: .regularExpression) {
                let list = code[code.index(before: r.upperBound)...].replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                names += list.split(separator: ",").map { $0.split(separator: "=")[0].trimmingCharacters(in: CharacterSet(charactersIn: " `")) }
            }
            for name in names { check(!name.lowercased().contains("inuse"), "\(f): nothing declared plainly \"in use\": \(name)") }
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
