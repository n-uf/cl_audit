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
    /// runs its own claude with its own sign-in. `email` as it should be shown ("hidden address" where the caller hides it: AddressSettings.words).
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
        let a = AddressSettings.words(email.isEmpty ? "An account" : email)
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

    /// The profile has this account, in use or standing by (one remembered by its address only included), by the one owner
    /// rule (AccountIdentity.sameAccount: the ids in any case).
    func has(_ s: Seat?) -> Bool {
        guard let s else { return false }
        let who = AccountIdentity(s)
        return seat.map { who.sameAccount(AccountIdentity($0)) } == true || standby.contains { who.sameAccount($0.identity) }
    }
}

/// What Claude Code recorded about the account a folder is signed in to (the oauthAccount block of its .claude.json):
/// enough to show and compare it. No sign-in: that's in the Keychain and isn't read here.
struct AccountFacts: Equatable {
    var seat: Seat
    var plan: String?              // Claude's own name ("Ultra"), when recorded
    var org: String?               // "Personal", or a team's name

    /// Read again only when the file changed (ClaudeFiles), so it can be asked on every tick.
    static func of(configDir: String) -> AccountFacts? {
        guard let r = Account.record(configDir: configDir), let seat = r.seat else { return nil }
        return AccountFacts(seat: seat, plan: r.plan, org: orgWords(type: r.organizationType, name: r.organizationName))
    }

    /// A personal plan's organisation is "Personal" (Claude names it after the address); a team's has its own name. A name
    /// that holds an address or an account id (a personal organisation whose type isn't recorded: "<address>'s Organization")
    /// is a personal one too: never shown, and never proposed as a profile name (AddressSettings.hides, word by word).
    static func orgWords(type: String?, name: String?) -> String? {
        if let t = type?.lowercased(), !t.isEmpty, !t.contains("team"), !t.contains("enterprise") { return "Personal" }
        guard let n = name.flatMap({ $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }) else { return nil }
        return n.split(whereSeparator: { $0 == " " }).contains(where: { AddressSettings.hides(String($0)) }) || AddressSettings.hides(n) ? "Personal" : n
    }
}
