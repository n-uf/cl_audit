// Accounts: a profile is one Claude Code folder, and the folder holds one signed-in account at a time (cl_quick's model).
// The account signed in there is the one in use, the profile's `seat`; the others it has had or was given wait in
// `standby`: remembered on the profile (address, ids, plan, when last in use), signed out, with no folder or Keychain
// item of their own, never read, so they show no usage. A switch signs Claude Code in again on the same folder as one
// of them (SwitchRunner.swift). cl_audit never copies or moves a sign-in: the folder's sign-in is Claude Code's own,
// made in Terminal.
//
// Here: what a standby account is, the account book (what a switch affects, which standby account to offer), what Claude
// Code recorded about a folder's account (no tokens). The accounts found on this Mac are AccountList.swift's.

import Foundation
import ProfileCore

// (StandbyAccount, AccountBook, AccountNote and StandbyTidy are ProfileCore's: Core/Standby.swift)

extension AccountEntry: StandbyHolder {}

extension AccountBook {
    /// What a switch affects, for the Switch page: Claude Code in Terminal and editors on the folder (for any folder but
    /// ~/.claude, those that use it through CLAUDE_CONFIG_DIR), sessions running now included; not the Claude app, which
    /// runs its own claude with its own sign-in. `email` as it should be shown (masked where the caller masks).
    static func switchWords(folder: String, email: String, isDefault: Bool) -> String {
        (isDefault ? "Terminal and editors on \(folder)" : "Terminal and editors using \(folder)")
            + " move to \(email), sessions running now included; the Claude app keeps its own sign-in."
            + " Finish the sign-in in Terminal and the browser as that account."
    }
}

extension AccountNote {
    /// "ultra-3 came from Work's standby accounts: it signed in to this profile's folder." / "ultra-3 left for Main: it
    /// signed in to Main's folder, so it's Main's account now."
    var words: String {
        let a = Privacy.masked(email.isEmpty ? "An account" : email)
        switch kind {
        case .came: return "\(a) came from \(profile)'s standby accounts: it signed in to this profile's folder."
        case .left: return "\(a) left for \(profile): it signed in to \(profile)'s folder, so it's \(profile)'s account now."
        case .standsBy: return "\(a) stands by on \(profile) now: it was \(profile)'s account in use, and an account stands by on one profile only."
        case .tidied: return "Standby list tidied: one entry per account."
        case .noCopy: return "The profiles file was updated, but its copy as it was before (accounts.json.pre-…) couldn't be kept."
        }
    }
}

/// What 26.11.13 and earlier kept for a standby account besides what it still keeps: the folder its own sign-in was kept
/// in. Read once, when the profiles file is read, to list that folder as left over (AccountEntry.leftoverFolders).
struct LegacyStandbyFolder: Decodable { var configDir: String? }

/// One element of a list read on its own: nil when it can't be read, so the rest of the list still is.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension AccountEntry {
    /// Every seat this profile has: the one in use and its standby accounts'.
    var seats: [Seat] { [seat].compactMap { $0 } + standby.compactMap(\.seat) }

    /// The profile has this seat, in use or standing by.
    func has(_ s: Seat?) -> Bool { s.map { x in seats.contains { x.same($0) } } ?? false }
}

/// What Claude Code recorded about the account a folder is signed in to (the oauthAccount block of its .claude.json):
/// enough to show and compare it. No sign-in: that's in the Keychain and isn't read here.
struct AccountFacts: Equatable {
    var seat: Seat
    var plan: String?              // Claude's own name ("Ultra"), when recorded
    var org: String?               // "Personal", or a team's name

    static func of(configDir: String) -> AccountFacts? { of(claudeJSON: Account.claudeJSON(configDir: configDir)) }

    static func of(claudeJSON path: String) -> AccountFacts? {
        guard let o = SafeRead.oauthAccount(path) else { return nil }        // bounded, non-blocking
        return of(oauthAccount: o)
    }

    static func of(oauthAccount o: [String: Any]) -> AccountFacts? {
        guard let account = o["accountUuid"] as? String, !account.isEmpty else { return nil }
        let plan = (o["planDisplayName"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return AccountFacts(seat: Seat(account: account, organization: o["organizationUuid"] as? String, email: o["emailAddress"] as? String),
                            plan: plan, org: orgWords(type: o["organizationType"] as? String, name: o["organizationName"] as? String))
    }

    /// A personal plan's organisation is "Personal" (Claude names it after the address); a team's has its own name.
    static func orgWords(type: String?, name: String?) -> String? {
        if let t = type?.lowercased(), !t.isEmpty, !t.contains("team"), !t.contains("enterprise") { return "Personal" }
        return name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

enum AccountDiscovery {
    /// What Claude Code recorded about every account it knows on this Mac, by account id: each Claude Code folder's
    /// .claude.json and the backups Claude Code keeps of the usual one.
    static func knownFacts(home: String = NSHomeDirectory()) -> [String: AccountFacts] {
        var files = Detect.configFolders().map { Account.claudeJSON(configDir: $0.path) }
        files.append((home as NSString).appendingPathComponent(".claude.json.backup"))
        let backups = (home as NSString).appendingPathComponent(".claude/backups")
        for n in ((try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []).sorted() where n.hasPrefix(".claude.json.backup") {
            files.append((backups as NSString).appendingPathComponent(n))
        }
        var out: [String: AccountFacts] = [:]
        for f in files {
            guard let facts = AccountFacts.of(claudeJSON: f), facts.seat.email != nil else { continue }
            if out[facts.seat.account] == nil { out[facts.seat.account] = facts }
        }
        return out
    }

    /// The accounts a Claude window's data folder has used (its Code tab files sessions under <account>/<organisation>),
    /// with when it last did. Only ids and dates are read; no session is opened.
    static func windowSeats(dataDir: String) -> [(seat: Seat, used: Date?)] {
        let root = (expand(dataDir) as NSString).appendingPathComponent("claude-code-sessions")
        let fm = FileManager.default
        var out: [(Seat, Date?)] = []
        for a in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted() where isUUID(a) {
            let adir = (root as NSString).appendingPathComponent(a)
            for o in ((try? fm.contentsOfDirectory(atPath: adir)) ?? []).sorted() where isUUID(o) {
                let odir = (adir as NSString).appendingPathComponent(o)
                let names = (try? fm.contentsOfDirectory(atPath: odir)) ?? []
                let dates = names.filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }.compactMap {
                    (try? fm.attributesOfItem(atPath: (odir as NSString).appendingPathComponent($0)))?[.modificationDate] as? Date
                }
                guard !dates.isEmpty else { continue }       // no session ever filed there: not an account it used
                out.append((Seat(account: a, organization: o, email: nil), dates.max()))
            }
        }
        return out
    }

    static func isUUID(_ s: String) -> Bool { UUID(uuidString: s) != nil }

}
