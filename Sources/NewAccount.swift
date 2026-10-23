// New account from scratch: one page in Settings with the details on the left and a checklist on the
// right. It creates the Claude Code settings folder and a desktop data folder, links shared items from
// ~/.claude, runs the Claude Code sign-in, opens the account's own Claude window, and on Finish adds the
// account and installs its Dock icon. Each step ticks itself off as it completes.

import AppKit
import SwiftUI

/// Items that can be shared from ~/.claude by linking them into the new folder.
enum SharedItem: String, CaseIterable, Identifiable {
    case instructions = "CLAUDE.md", agents, skills, commands, memory = "projects"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .instructions: return "instructions"
        case .agents: return "agents"
        case .skills: return "skills"
        case .commands: return "commands"
        case .memory: return "memory & history"
        }
    }
}

struct NewAccountDraft: Equatable {
    var name = ""
    var color: TileColor = .purple
    var share: Set<SharedItem> = [.instructions, .agents, .skills, .commands]
    /// Folders this setup created (not ones that already existed); Cancel deletes only these.
    var createdConfigDir: String?
    var createdDataDir: String?
    var started: Bool { createdConfigDir != nil || createdDataDir != nil }

    var id: String { Store.newID(from: name, taken: []) }
    var label: String { String(name.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)) }
    var configDir: String { "~/.claude-\(id)" }
    var dataDir: String { "~/Library/Application Support/Claude-\(id)" }

    var entry: AccountEntry {
        var e = AccountEntry(id: id, name: name, label: label.isEmpty ? "NEW" : label, configDir: configDir)
        e.desktop = .separate
        e.desktopDataDir = dataDir
        e.color = color
        e.accent = color
        return e
    }
}

/// What has been done so far, read from disk each time (so it stays right if things happen elsewhere).
enum NewAccountSetup {
    static let shared = URL(fileURLWithPath: expand("~/.claude"))

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: expand(path)) }

    static func foldersReady(_ d: NewAccountDraft) -> Bool { exists(d.configDir) && exists(d.dataDir) }

    static func linksReady(_ d: NewAccountDraft) -> Bool {
        d.share.allSatisfy { item in
            !FileManager.default.fileExists(atPath: shared.appendingPathComponent(item.rawValue).path)
                || exists((d.configDir as NSString).appendingPathComponent(item.rawValue))
        }
    }

    /// Signed in when Claude Code has recorded this folder's account (it writes it right after the login).
    static func signedInEmail(_ d: NewAccountDraft) -> String? {
        exists(d.configDir) ? Account.expectedEmail(configDir: d.configDir) : nil
    }

    /// The other account that already uses this login, if any (the browser often signs in with the
    /// claude.ai account it's already using).
    static func takenBy(_ email: String, accounts: [AccountEntry]) -> AccountEntry? {
        accounts.first { e in
            let known = [Store.status(e.id)?.loginEmail, Account.expectedEmail(configDir: e.configDir)]
            return known.contains { $0?.lowercased() == email.lowercased() }
        }
    }

    /// What Cancel will undo, for the confirmation.
    static func discardSummary(_ d: NewAccountDraft) -> String {
        guard d.started else { return "Nothing has been created yet." }
        var parts: [String] = []
        if d.createdConfigDir != nil, let e = signedInEmail(d) { parts.append("signs out the Claude Code login (\(Privacy.masked(e)))") }
        if d.createdConfigDir != nil, windowOpen(d) { parts.append("quits its Claude window") }
        let dirs = [d.createdConfigDir, d.createdDataDir.map { _ in "its desktop data folder" }].compactMap { $0 }
        if !dirs.isEmpty { parts.append("deletes " + dirs.joined(separator: " and ")) }
        let first = parts.joined(separator: ", ")
        return first.prefix(1).uppercased() + first.dropFirst() + ". Nothing in ~/.claude is touched."
    }

    /// Undoes what this setup created: the login it made, the window it opened, the folders it created.
    /// Folders that existed before are left alone. Blocks for the sign-out; call off the main thread.
    static func discard(_ d: NewAccountDraft, claude: String?) {
        let fm = FileManager.default
        if let dir = d.createdConfigDir {
            if let claude, signedInEmail(d) != nil { ClaudeCLI.logout(claude, configDir: dir) }
            let account = Account(d.entry)
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Launcher.claudeBundleID)
                .filter { Launcher.isWindow(of: account, $0) }
            apps.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(4)
            while apps.contains(where: { !$0.isTerminated }) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            try? fm.removeItem(at: URL(fileURLWithPath: expand(dir)))      // removes the links, not what they point to
            try? fm.removeItem(at: ClaudeCLI.loginScript(dir))
        }
        if let dir = d.createdDataDir { try? fm.removeItem(at: URL(fileURLWithPath: expand(dir))) }
    }

    static func windowOpen(_ d: NewAccountDraft) -> Bool {
        Launcher.activity(for: [Account(d.entry)])[expand(d.configDir)]?.desktopOpen ?? false
    }

    /// Creates both folders and links the chosen items from ~/.claude. Existing files are left alone.
    /// Records in the draft which folders it created, so Cancel can remove exactly those.
    static func createFolders(_ d: inout NewAccountDraft) throws {
        let fm = FileManager.default
        let config = URL(fileURLWithPath: expand(d.configDir))
        if !exists(d.configDir) { try fm.createDirectory(at: config, withIntermediateDirectories: true); d.createdConfigDir = d.configDir }
        if !exists(d.dataDir) {
            try fm.createDirectory(at: URL(fileURLWithPath: expand(d.dataDir)), withIntermediateDirectories: true)
            d.createdDataDir = d.dataDir
        }
        for item in d.share {
            let src = shared.appendingPathComponent(item.rawValue)
            let dst = config.appendingPathComponent(item.rawValue)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path),
                  (try? fm.destinationOfSymbolicLink(atPath: dst.path)) == nil else { continue }
            try fm.createSymbolicLink(at: dst, withDestinationURL: src)
        }
    }
}

struct NewAccountView: View {
    @Binding var draft: NewAccountDraft
    @ObservedObject var model: SettingsModel
    @State private var error: String?
    @ObservedObject private var privacy = Privacy.shared
    @State private var confirmCancel = false
    @State private var signingOut = false

    var problem: String? {
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
        if model.accounts.contains(where: { $0.name.lowercased() == draft.name.lowercased() }) { return "Another account already has that name." }
        if model.accounts.contains(where: { expand($0.configDir) == expand(draft.configDir) }) { return "Another account already uses \(draft.configDir)." }
        return nil
    }

    var body: some View {
        let _ = model.tick                                // re-check the steps every few seconds
        let folders = NewAccountSetup.foldersReady(draft)
        let links = folders && NewAccountSetup.linksReady(draft)
        let signedIn = NewAccountSetup.signedInEmail(draft)
        // The account is whichever one the sign-in used (the browser's claude.ai session decides it), so
        // the only check is that no other account here already uses it.
        let taken = signedIn.flatMap { NewAccountSetup.takenBy($0, accounts: model.accounts) }
        let rightAccount = signedIn != nil && taken == nil
        let wrongAccount = signedIn != nil && !rightAccount
        let window = folders && NewAccountSetup.windowOpen(draft)

        HStack(alignment: .top, spacing: 10) {
            SCard(title: "New Claude account") {
                SRow(label: "Name", info: "Shown in the Dock as “cl_audit \(draft.name)”; also names the folders.", first: true) {
                    TextField("e.g. personal", text: $draft.name)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(maxWidth: 160)
                        .disabled(draft.started)        // the folders are named after it
                }
                SRow(label: "Icon label · colour") {
                    HStack(spacing: 6) {
                        Text(draft.label.isEmpty ? "–" : draft.label).font(.system(size: 12, weight: .semibold))
                        ForEach([TileColor.orange, .blue, .purple, .teal, .pink], id: \.self) { c in
                            Swatch(color: c, selected: draft.color == c, size: 13).onTapGesture { draft.color = c }
                        }
                    }
                }
                SRow(label: "Claude Code folder") { folderText(draft.configDir) }
                SRow(label: "Desktop data folder") { folderText(draft.dataDir) }
                VStack(alignment: .leading, spacing: 4) {
                    SRow(label: "Share from main", info: "Linked from ~/.claude, so changes there show up in every account. The login, plugins and usage stay separate.") {
                        EmptyView()
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 4) {
                        ForEach(SharedItem.allCases) { item in
                            Toggle(item.title, isOn: Binding(get: { draft.share.contains(item) },
                                                             set: { on in if on { draft.share.insert(item) } else { draft.share.remove(item) } }))
                                .toggleStyle(.checkbox).font(.system(size: 11)).lineLimit(1).fixedSize()
                        }
                    }
                    .padding(.bottom, 4)
                }
                .disabled(folders)
            }
            .frame(maxWidth: .infinity)

            SCard(title: "Steps") {
                step(done: folders && links, title: "Create the folders" + (draft.share.isEmpty ? "" : " and links"), first: true) {
                    Button("Create") {
                        do { try NewAccountSetup.createFolders(&draft); error = nil; model.tick += 1 }
                        catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.pill(Color(nsColor: draft.color.color(fiveHour: nil, stale: false)), compact: true))
                    .disabled(problem != nil)
                }
                step(done: rightAccount, waiting: wrongAccount,
                     title: signInTitle(signedIn, taken: taken),
                     note: wrongAccount
                        ? "The browser signed in with the claude.ai account it was already using. Sign out here, then sign in again and open the link Terminal shows in a private browser window (or sign out of claude.ai in the browser first)."
                        : "Opens Terminal; you approve in the browser. The browser uses the claude.ai account it's signed in to, so for a different account open the link Terminal shows in a private window.") {
                    if wrongAccount {
                        Button(signingOut ? "Signing out…" : "Sign out") { signOut() }
                            .buttonStyle(.pill(.orange, compact: true))
                            .disabled(signingOut || model.claudePath == nil)
                    } else {
                        Button("Sign in…") {
                            if let claude = model.claudePath {
                                ClaudeCLI.openLogin(claude, account: Account(draft.entry), email: nil)
                            }
                        }
                        .buttonStyle(.pill(Color(nsColor: draft.color.color(fiveHour: nil, stale: false)), compact: true))
                        .disabled(!folders || model.claudePath == nil)
                    }
                }
                step(done: window, title: window ? "Claude window open" : "Open the Claude window",
                     note: window ? "Sign in there once, if you haven't." : "Its own Claude window with its own sign-in. Optional if you only use the terminal.") {
                    Button(window ? "Show" : "Open window") { Launcher.openClaude(Account(draft.entry)) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(!folders)
                }
                step(done: false, title: "Add the Dock icon", note: "Finish adds the account and installs “cl_audit \(draft.name)”.") {
                    EmptyView()
                }
                HStack {
                    if let p = problem ?? error { Text(p).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    else if wrongAccount { Text("Sign out, then sign in with the right account to finish.").font(.caption).foregroundStyle(.orange) }
                    else if !rightAccount { Text("You can finish before signing in, and sign in later.").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button(model.discarding ? "Cancelling…" : "Cancel") { confirmCancel = true }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).disabled(model.discarding)
                    Button("Finish") { model.finishNew() }.buttonStyle(.pill(.green, compact: true))
                        .disabled(problem != nil || !folders || wrongAccount || model.discarding)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .alert("Cancel the new account\(draft.name.isEmpty ? "" : " “\(draft.name)”")?", isPresented: $confirmCancel) {
            Button(draft.started ? "Cancel and clean up" : "Cancel setup", role: .destructive) { model.cancelNew() }
            Button("Keep setting up", role: .cancel) {}
        } message: {
            Text(NewAccountSetup.discardSummary(draft))
        }
    }

    func signInTitle(_ signedIn: String?, taken: AccountEntry?) -> String {
        guard let e = signedIn.map(Privacy.masked) else { return "Sign in to Claude Code" }
        if let taken { return "Signed in as \(e), which “\(taken.name)” already uses" }
        return "Signed in as \(e)"
    }

    /// Signs out the wrong login so the sign-in can be done again.
    func signOut() {
        guard let claude = model.claudePath else { return }
        signingOut = true
        let dir = draft.configDir
        DispatchQueue.global(qos: .userInitiated).async {
            ClaudeCLI.logout(claude, configDir: dir)
            DispatchQueue.main.async { signingOut = false; model.tick += 1 }
        }
    }

    func folderText(_ path: String) -> some View {
        HStack(spacing: 4) {
            Text(path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Text(NewAccountSetup.exists(path) ? "exists" : "new").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    func step<C: View>(done: Bool, waiting: Bool = false, title: String, note: String? = nil, first: Bool = false,
                       @ViewBuilder action: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SRow(label: "", first: first) {
                HStack(spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : waiting ? "exclamationmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color(nsColor: Painter.green) : waiting ? Color.orange : Color.secondary)
                    Text(title).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    if !done { action() }
                }
            }
            if let note, !done { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 24).padding(.bottom, 4) }
        }
    }
}
