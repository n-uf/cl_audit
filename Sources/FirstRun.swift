// FirstRun: "Set up cl_audit", the page a fresh install opens on instead of a profile it made by itself.
//
//   1  Claude Code   found (with its version and where), or how to install it, checked again by itself
//   2  Account       a Claude Code folder on this Mac that is signed in (one click), or Sign in… (Claude Code's own
//                    browser sign-in in Terminal, in a folder of its own); the address is optional
//   3  Name          prefilled from the account (a team's name, else the address's name part), a colour, Done
//
// Who sees it: no profile exists (a fresh install, or every profile removed), or the only profile is the "main" that
// cl_audit 26.11.1 made by itself on ~/.claude when it found no profiles (FirstRun.isImplicitMain: exactly as made, never
// signed in, nothing of its own). Anyone who has set a profile up (a name, a look, a setting, a sign-in) never sees it.
// Done adds the profile like New profile does (NewAccountDraft, NewAccountSetup.createOrConnect, finishNew's seat link),
// and takes the implicit "main" out of the list in the same save, which removes its icon app.

import AppKit
import SwiftUI

// MARK: - Logic (no views: the checks drive it)

/// What has been picked on the first-run page so far.
struct FirstRunDraft: Equatable {
    var folder: String?             // the Claude Code folder whose account becomes the profile
    var signInDir: String?          // the folder Sign in… uses
    var signInAsked: Date?          // when Terminal was opened for it
    var seatAtAsk: Seat?            // what the folder was signed in to then: a new sign-in is another account than this
    var email = ""                  // optional: filled into Claude Code's sign-in
    var name = ""
    var nameEdited = false
    var color: TileColor = .purple
    var problem: String?

    var waiting: Bool { folder == nil && signInAsked != nil }
}

enum FirstRun {
    enum Step: Int { case claudeCode = 1, account, name }

    /// The profile cl_audit 26.11.1 made by itself on a fresh install.
    static var implicitMain: AccountEntry { AccountEntry(id: "main", name: "main", label: "MAIN", configDir: "~/.claude") }

    /// That profile as it was made: nothing changed in it, no standby account, and ~/.claude isn't signed in. A "main"
    /// someone renamed, restyled or signed in to is a profile they use.
    /// `signedInCounts: false` leaves the sign-in out (the page is already up: a sign-in landing in ~/.claude from it
    /// must not take the page away before Done).
    static func isImplicitMain(_ e: AccountEntry, signedInCounts: Bool = true) -> Bool {
        e == implicitMain && (!signedInCounts || Account.signedInSeat(configDir: "~/.claude") == nil)
    }

    /// The first-run page is for: no profile at all, or only the implicit "main".
    static func needed(_ list: [AccountEntry], signedInCounts: Bool = true) -> Bool {
        list.isEmpty || (list.count == 1 && isImplicitMain(list[0], signedInCounts: signedInCounts))
    }

    static func step(claude: Bool, draft: FirstRunDraft) -> Step {
        if !claude { return .claudeCode }
        return draft.folder == nil ? .account : .name
    }

    /// A Claude Code folder that is signed in, offered in step 2.
    struct FoundFolder: Equatable, Identifiable {
        var path: String
        var email: String
        var detail: String          // "Max · Personal"
        var id: String { path }
    }

    /// The Claude Code folders on this Mac (~/.claude, ~/.claude-*) that are signed in: address and ids only, never the
    /// sign-in itself.
    static func foundFolders(folders: [FolderChoice] = Detect.configFolders(), among accounts: [AccountEntry] = []) -> [FoundFolder] {
        folders.compactMap { f in
            guard Account.signedInSeat(configDir: f.path) != nil, let email = Account.expectedEmail(configDir: f.path),
                  !accounts.contains(where: { !isImplicitMain($0, signedInCounts: false) && FolderKey.canonical($0.configDir) == FolderKey.canonical(f.path) }) else { return nil }
            let facts = AccountFacts.of(configDir: f.path)
            let detail = [facts?.plan.map(Account.planWords), facts?.org].compactMap { $0 }.joined(separator: " · ")
            return FoundFolder(path: f.path, email: email, detail: detail)
        }
    }

    /// A team's name (the organisation), else the address's name part; names can't hold / or :.
    static func suggestedName(folder: String) -> String {
        let facts = AccountFacts.of(configDir: folder)
        var name = facts?.org.flatMap { $0 == "Personal" ? nil : $0 } ?? ""
        if name.isEmpty, let email = facts?.seat.email ?? Account.expectedEmail(configDir: folder) {
            name = String(email.split(separator: "@").first ?? "")
        }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Claude" : name
    }

    /// The folder Sign in… signs in to: ~/.claude when nothing is signed in there (the usual Claude app then shares it),
    /// else a new ~/.claude-<name> (the address's name part when typed).
    static func signInFolder(email: String) -> String {
        if Account.signedInSeat(configDir: "~/.claude") == nil { return "~/.claude" }
        let local = email.split(separator: "@").first.map(String.init) ?? "account"
        let id = Store.newID(from: local, taken: [])
        var dir = "~/.claude-\(id)", n = 2
        while FolderKind.of(dir) != .missing { dir = "~/.claude-\(id)-\(n)"; n += 1 }
        return dir
    }

    /// Why the optional address can't be used, or nil (empty is fine).
    static func addressProblem(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.isEmpty { return nil }
        return e.contains("@") && !e.hasPrefix("@") && !e.hasSuffix("@") && !e.contains(" ") ? nil : "That doesn't look like an email address; leave it empty to type it in the browser."
    }
}

// MARK: - The model's part

extension SettingsModel {
    /// The account's folder picked in step 2 (one click): the name is filled in from it.
    func firstRunPick(_ path: String) {
        firstRun.folder = path
        firstRun.problem = nil
        if !firstRun.nameEdited { firstRun.name = FirstRun.suggestedName(folder: path) }
    }

    /// "Change" in step 2: back to choosing.
    func firstRunChangeAccount() {
        firstRun.folder = nil; firstRun.signInAsked = nil; firstRun.seatAtAsk = nil; firstRun.problem = nil
    }

    /// Sign in…: Claude Code's own browser sign-in in Terminal, in ~/.claude when it has no account or else a new folder.
    /// Says why when it can't (the install help opens when Claude Code is missing).
    func firstRunSignIn() {
        if let p = FirstRun.addressProblem(firstRun.email) { firstRun.problem = p; return }
        guard let claude = requireClaude() else { firstRun.problem = claudeLooked ? ClaudeInstall.missing : noClaudeWhy; return }
        let email = firstRun.email.trimmingCharacters(in: .whitespaces)
        let dir = firstRun.signInDir ?? FirstRun.signInFolder(email: email)
        if dir != "~/.claude" {
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: expand(dir)), withIntermediateDirectories: true)
        }
        let probe = AccountEntry(id: "setup", name: "setup", label: "SETUP", configDir: dir)
        guard ClaudeCLI.openLogin(claude, account: Account(probe), email: email.isEmpty ? nil : email) else {
            firstRun.problem = "Terminal didn't open."; return
        }
        firstRun.signInDir = dir
        firstRun.seatAtAsk = Account.signedInSeat(configDir: dir)
        firstRun.signInAsked = Date()
        firstRun.problem = nil
    }

    func firstRunCancelSignIn() { firstRun.signInAsked = nil; firstRun.seatAtAsk = nil; firstRun.problem = nil }

    /// Every few seconds: the sign-in started here has landed once the folder names an account other than the one it
    /// had when Sign in… was pressed; the profile then waits for its name.
    func followFirstRun() {
        guard isFirstRun, firstRun.waiting, let asked = firstRun.signInAsked, let dir = firstRun.signInDir else { return }
        if Date().timeIntervalSince(asked) > 3600 { firstRunCancelSignIn(); return }
        guard let seat = Account.signedInSeat(configDir: dir) else { return }
        if let before = firstRun.seatAtAsk, seat.same(before) { return }
        firstRunPick(dir)
    }

    /// Done: the profile on the picked folder, named and coloured, saved and its Dock icon installed; the implicit
    /// "main" of an older version goes in the same save. Returns why it can't, or nil.
    @discardableResult
    func finishFirstRun() -> String? {
        let wasFirstRun = isFirstRun
        if let why = commitFirstRun() { return why }
        guard wasFirstRun else { return nil }
        apply()                                     // saves the list as it is now and installs the Dock icon app
        message = "Set up \(accounts.first?.name ?? "the profile")"
        return nil
    }

    /// Everything Done does except saving and installing (Apply): the folder connected, the profile in the list, the
    /// implicit "main" out of it, the page's choices reset. Apart so the checks can run it without touching the Dock.
    func commitFirstRun() -> String? {
        guard isFirstRun else { return nil }
        guard let folder = firstRun.folder, Account.signedInSeat(configDir: folder) != nil else { return "Choose an account first (step 2)." }
        let name = firstRun.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the profile a name." }
        if name.contains("/") || name.contains(":") { return "The name can't contain / or :." }
        var d = NewAccountDraft()
        d.name = name; d.color = firstRun.color; d.share = []
        d.source = .existing; d.existingDir = folder
        do { try NewAccountSetup.createOrConnect(&d) } catch { return error.localizedDescription }
        var e = d.entry
        if var s = Account.signedInSeat(configDir: e.configDir) { s.linkedAt = Date(); e.seat = s }
        // an older version's own "main", exactly as made: nothing in it, and it goes (even when ~/.claude got signed in
        // meanwhile, from this page: that account is the new profile's now)
        accounts.removeAll { FirstRun.isImplicitMain($0, signedInCounts: false) }
        accounts.append(e)
        refreshFirstRun()
        firstRun = FirstRunDraft(color: firstRun.color)
        selection = e.id
        return nil
    }
}

// MARK: - The page

/// "Claude Code isn't installed on this Mac · Install…", wherever a sign-in key needs it.
struct ClaudeMissingLine: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.face) private var face

    var body: some View {
        if model.claudeKnownMissing {
            let warning = HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(face.caution)
                Text(ClaudeInstall.missing + " ·").font(.system(size: 11)).foregroundStyle(face.caution).lineLimit(1).fixedSize()
            }
            let install = Button("Install…") { model.showInstallHelp() }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            // one line when it fits, else the key under the words (never cut off)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { warning; install }
                VStack(alignment: .leading, spacing: 4) { warning; install }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            // while this note shows, cl_audit looks again every few seconds (backing off); when it goes, it stops
            .onAppear { model.claudeNotes += 1 }
            .onDisappear { model.claudeNotes = max(0, model.claudeNotes - 1) }
        }
    }
}

/// How to get Claude Code, or that it's here: step 1 of the first-run page and the install sheet's content.
struct ClaudeInstallCard: View {
    @ObservedObject var model: SettingsModel
    var title = "Claude Code"
    @State private var copied = false
    @State private var checking = false
    @Environment(\.face) private var face

    var body: some View {
        SCard(title: title, info: "cl_audit signs in through Claude Code's own sign-in and reads its usage the way Claude Code does. It looks in the usual places, in the login shell and in the Claude app's own copy, and looks again by itself every few seconds while this is showing.") {
            if let c = model.claude { found(c) }
            else if !model.claudeLooked { looking }
            else { missing }
        }
    }

    /// Before the first full look is done nothing is known: never "isn't installed" yet.
    private var looking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Looking for Claude Code…").font(.system(size: 12.5)).foregroundStyle(face.muted)
        }
        .padding(.vertical, 4)
    }

    private func found(_ c: ClaudeFound) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(FaceTheme.ledOn).font(.system(size: 14))
                // the Claude app's copy lives in a long path: said as "from the Claude app", the path is in the tooltip
                Text("Claude Code\(model.claudeVersion.map { " " + $0 } ?? "") · \(c.fromApp ? "from the Claude app" : tilde(c.path))")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(face.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(tilde(c.path))
            }
            if c.fromApp {
                SRowLine(text: "The Claude app keeps its own copy, and it works for signing in. If you install Claude Code itself later, cl_audit uses that one.")
            }
        }
        .padding(.vertical, 4)
    }

    private var command: some View {
        Text(ClaudeInstall.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(face.text)
            .textSelection(.enabled)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(WellShape(well: face.track, radius: 5))
    }

    private var copyKey: some View {
        Button(copied ? "Copied" : "Copy") {
            ClaudeInstall.copyCommand()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        }
        .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
    }

    private var missing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(face.caution).font(.system(size: 13))
                Text("Claude Code isn't on this Mac").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(face.text)
            }
            Text("Open Terminal, paste this and press Return (it takes a minute). cl_audit notices by itself when it's done.")
                .font(.system(size: 11.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            // the command on one line beside Copy; in a narrow card it wraps whole under no key (never cut off), Copy under it
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { command.lineLimit(1).fixedSize(horizontal: true, vertical: false); copyKey }
                VStack(alignment: .leading, spacing: 8) { command.fixedSize(horizontal: false, vertical: true); copyKey }
            }
            HStack(spacing: 8) {
                Button("Install page") { NSWorkspace.shared.open(ClaudeInstall.docs) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                Button {
                    checking = true
                    model.detectClaude(force: true) { checking = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9.5, weight: .semibold))
                        Text(checking ? "Checking…" : "Check again")
                    }
                }
                .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(checking)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The install help as a sheet, for a sign-in key somewhere else in Settings.
struct ClaudeInstallSheet: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ClaudeInstallCard(model: model, title: "Install Claude Code")
            HStack {
                Spacer()
                Button(model.claude == nil ? "Close" : "Done") { model.installHelp = false }
                    .buttonStyle(.primaryKey(compact: true))
            }
        }
        .padding(16).frame(width: 440)
        .background(ChassisBackground())
        .face(FacePrefs.shared.face)
    }
}

struct FirstRunPage: View {
    @ObservedObject var model: SettingsModel
    var width: CGFloat = 708
    @Environment(\.face) private var face
    @ObservedObject private var privacy = Privacy.shared
    @State private var finishing: String?

    private var step: FirstRun.Step { FirstRun.step(claude: model.claude != nil, draft: model.firstRun) }
    private var tint: Color { Color(nsColor: model.firstRun.color.color(fiveHour: nil, stale: false)) }
    private var cardWidth: CGFloat { min(520, max(300, width - 32)) }

    var body: some View {
        let _ = model.tick                                  // the folders on this Mac are looked at again every few seconds
        VStack(alignment: .leading, spacing: 10) {
            Text("Set up cl_audit").font(.system(size: 17, weight: .semibold)).foregroundStyle(face.text)
            Text("cl_audit shows how much of its limits each Claude account has used. Three steps, about a minute.")
                .font(.system(size: 12)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
            DisplayWindow(text: topText, dim: topDim, tone: step == .claudeCode ? .amber : .normal, height: 24, size: 10)
            claudeCard
            accountCard
            nameCard
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .environment(\.settingsColumnWidth, cardWidth)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var topText: String { "Step \(step.rawValue) of 3" }
    private var topDim: String {
        switch step {
        case .claudeCode: return "· Claude Code"
        case .account: return model.firstRun.waiting ? "· signing in…" : "· the account"
        case .name: return "· name it"
        }
    }

    // MARK: 1

    private var claudeCard: some View { ClaudeInstallCard(model: model, title: "1 · Claude Code") }

    // MARK: 2

    private var accountCard: some View {
        let ready = model.claude != nil
        let found = FirstRun.foundFolders(among: model.accounts)
        return SCard(title: "2 · Account", info: "The claude.ai account to watch first. Claude Code folders on this Mac that are signed in are listed (their address only, never the sign-in). Sign in… opens Claude Code's own sign-in in Terminal; the browser's claude.ai account decides which account it is. More accounts and profiles come later, in Settings.") {
            VStack(alignment: .leading, spacing: 8) {
                if !ready {
                    Text("Needs Claude Code first (step 1).").font(.system(size: 11.5)).foregroundStyle(face.muted)
                } else if let folder = model.firstRun.folder {
                    chosen(folder)
                } else if model.firstRun.waiting {
                    waiting
                } else {
                    if found.isEmpty {
                        Text("No signed-in Claude Code folder found on this Mac.").font(.system(size: 11.5)).foregroundStyle(face.muted)
                    } else {
                        Text("Found on this Mac").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.muted)
                        ForEach(found) { f in foundRow(f) }
                    }
                    signInRow
                }
                if let p = model.firstRun.problem { Text(p).font(.system(size: 11)).foregroundStyle(face.danger).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.vertical, 4)
            .opacity(ready ? 1 : 0.55)
        }
    }

    private func foundRow(_ f: FirstRun.FoundFolder) -> some View {
        Button { model.firstRunPick(f.path) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Privacy.masked(f.email)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(face.text).settingsEmail(true)
                    Text(([f.detail].filter { !$0.isEmpty } + ["in \(f.path)"]).joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(face.muted)
                }
                Spacer(minLength: 6)
                Text("Use").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.soft)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(face.text.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chosen(_ folder: String) -> some View {
        let email = Account.expectedEmail(configDir: folder) ?? "signed in"
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(FaceTheme.ledOn).font(.system(size: 14))
            VStack(alignment: .leading, spacing: 1) {
                Text(Privacy.masked(email)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(face.text).settingsEmail(true)
                    .lineLimit(1).truncationMode(.middle)
                Text("in \(folder)").font(.system(size: 10.5)).foregroundStyle(face.muted)
            }
            Spacer(minLength: 6)
            Button("Change") { model.firstRunChangeAccount() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
        }
    }

    private var signInRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.firstRun.signInDir == nil ? "Or sign in to a Claude account" : "Sign in again").font(.system(size: 11, weight: .semibold)).foregroundStyle(face.muted)
            HStack(spacing: 6) {
                WellField(placeholder: "Address (optional)", text: Binding(get: { model.firstRun.email },
                                                                                   set: { model.firstRun.email = $0; model.firstRun.problem = nil }),
                          onSubmit: { model.firstRunSignIn() }, onCancel: {})
                Button("Sign in…") { model.firstRunSignIn() }
                    .buttonStyle(.pill(FaceTheme.ledOn, compact: true)).fixedSize()
            }
            SRowLine(text: "Terminal opens with Claude Code's sign-in; approve in the browser. The address only fills it in: the browser's claude.ai account decides.")
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 6) {
            let state = HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    LED(color: FaceTheme.ledAmber, lit: Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                }
                Text("signing in…").font(.system(size: 12)).foregroundStyle(face.caution).lineLimit(1).fixedSize()
            }
            let keys = HStack(spacing: 6) {
                Button("Show Terminal") { _ = Installer.run("/usr/bin/open", ["-a", "Terminal"]) }
                    .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
                Button("Cancel") { model.firstRunCancelSignIn() }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            }
            // one line when it fits; in a narrow card the keys go on a line of their own
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { state; Spacer(minLength: 6); keys }
                VStack(alignment: .leading, spacing: 6) { state; keys }
            }
            SRowLine(text: "Finish in the browser\(model.firstRun.email.isEmpty ? "" : " as \(Privacy.masked(model.firstRun.email))"); cl_audit goes on by itself once the account shows up.")
        }
    }

    // MARK: 3

    private var nameCard: some View {
        let ready = step == .name
        return SCard(title: "3 · Name and colour", info: "What cl_audit calls this profile, and its colour in the dashboard and panels. Both can be changed later in Settings.") {
            VStack(spacing: 0) {
                SRow(label: "Name", first: true, stacked: cardWidth < 400) {
                    SField(placeholder: "e.g. work", text: Binding(get: { model.firstRun.name },
                                                                    set: { model.firstRun.name = $0; model.firstRun.nameEdited = true; finishing = nil }), width: nil)
                        .disabled(!ready)
                }
                SRow(label: "Colour", stacked: cardWidth < 400) {
                    FlowLayout(spacing: 6) {
                        ForEach(TileColor.accents, id: \.self) { c in
                            Swatch(color: c, selected: model.firstRun.color == c, size: 16).onTapGesture { if ready { model.firstRun.color = c } }
                        }
                    }
                    .padding(.vertical, 6)
                    .alignmentGuide(.rowLine) { d in d[VerticalAlignment.center] }
                }
                HStack(spacing: 8) {
                    if let f = finishing { Text(f).font(.system(size: 11)).foregroundStyle(face.danger).lineLimit(2) }
                    Spacer(minLength: 6)
                    Button("Done") { finishing = model.finishFirstRun() }
                        .buttonStyle(.primaryKey(compact: true)).disabled(!ready || model.firstRun.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 8)
            }
            .opacity(ready ? 1 : 0.55)
        }
    }
}
