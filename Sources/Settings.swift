// Settings: the Settings page of the cl_audit window. Accounts across the top; the selected account's
// settings in three columns of compact cards. Changes are saved as you make them; only a new name or
// label, or adding and removing accounts, needs Apply (that installs, renames or removes icon apps).

import AppKit
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var accounts: [AccountEntry] { didSet { scheduleSave() } }
    @Published var selection: String?
    static let dashboardID = "__dashboard__"
    @Published var message = ""
    @Published var tick = 0                 // bumped every few seconds so icon status re-reads
    private(set) var saved: [AccountEntry]
    var configFolders: [FolderChoice] { Detect.configFolders() }
    var dataFolders: [FolderChoice] { Detect.desktopDataFolders() }
    let claudePath = ClaudeCLI.find()
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    init() {
        saved = Store.load()
        accounts = saved.isEmpty
            ? [AccountEntry(id: "main", name: "main", label: "MAIN", configDir: "~/.claude")]
            : saved
        selection = accounts.first?.id
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick += 1 }
    }

    /// Picks up changes made elsewhere (e.g. an icon's own Options menu) when nothing is pending here.
    func reloadIfClean() {
        guard !needsApply else { return }
        let fresh = Store.load()
        if !fresh.isEmpty, fresh != accounts { saved = fresh; accounts = fresh }
        if !accounts.contains(where: { $0.id == selection }) { selection = accounts.first?.id }
    }

    /// What an icon app is made of (which apps exist, their names and labels). Changing it needs Apply.
    static func structure(_ list: [AccountEntry]) -> [String] { list.map { "\($0.id)|\($0.name)|\($0.label)" } }
    var needsApply: Bool { Self.structure(accounts) != Self.structure(saved) || (saved.isEmpty && !accounts.isEmpty) }

    /// Everything else is saved a moment after it changes, and the running icons follow it right away.
    private func scheduleSave() {
        saveWork?.cancel()
        guard !needsApply, problem == nil, accounts != saved else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.needsApply, self.problem == nil else { return }
            do {
                try Store.save(self.accounts); self.saved = self.accounts; self.message = "Saved"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in   // a brief confirmation
                    if self?.message == "Saved" { self?.message = "" }
                }
            }
            catch { self.message = "Couldn't save: \(error.localizedDescription)" }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    var problem: String? {
        for a in accounts { if let p = a.problem { return "\(a.name.isEmpty ? "New account" : a.name): \(p)" } }
        let names = accounts.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(names).count != names.count { return "Two accounts have the same name." }
        return FolderRules.clash(in: accounts)          // one account per Claude Code folder and per window
    }

    func binding(_ id: String) -> Binding<AccountEntry>? {
        guard accounts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.accounts.first { $0.id == id } ?? AccountEntry(id: id, name: "", label: "", configDir: "") },
            set: { new in if let i = self.accounts.firstIndex(where: { $0.id == id }) { self.accounts[i] = new } })
    }

    func add() {
        var n = accounts.count + 1
        while accounts.contains(where: { $0.name == "account \(n)" }) { n += 1 }
        let name = "account \(n)"
        let id = Store.newID(from: name, taken: accounts.map(\.id))
        let used = Set(accounts.map { expand($0.configDir) })     // suggest a settings folder no account uses yet
        let folder = configFolders.first { !used.contains(expand($0.path)) }?.path ?? ""
        accounts.append(AccountEntry(id: id, name: name, label: "ACC\(n)", configDir: folder))
        selection = id
    }

    /// A new account being set up from scratch (the "New account" tile), not yet in `accounts`.
    @Published var draft: NewAccountDraft?
    static let newID = "__new__"

    func startNew() {
        if draft == nil {
            var d = NewAccountDraft()
            let used = Set(accounts.map(\.color))
            d.color = TileColor.accents.first { !used.contains($0) } ?? .purple
            draft = d
        }
        selection = Self.newID
    }

    /// Cancels the new account and removes what its setup created (after the page has asked).
    @Published var discarding = false
    func cancelNew() {
        guard let d = draft else { return }
        guard d.started else { draft = nil; selection = accounts.first?.id; return }
        discarding = true
        let claude = claudePath
        DispatchQueue.global(qos: .userInitiated).async {
            NewAccountSetup.discard(d, claude: claude)
            DispatchQueue.main.async {
                self.discarding = false
                self.draft = nil
                self.selection = self.accounts.first?.id
                self.message = "Cancelled \(d.name.isEmpty ? "the new account" : d.name); its folders and login were removed"
            }
        }
    }

    /// Adds the new account and installs its Dock icon.
    func finishNew() {
        guard let d = draft else { return }
        accounts.append(d.entry)
        draft = nil
        selection = d.entry.id
        apply()
        message = "Added \(d.name)"
    }

    /// The account waiting for "Remove" to be confirmed.
    @Published var pendingRemoval: AccountEntry?

    func askRemove(_ id: String) { pendingRemoval = accounts.first { $0.id == id } }

    /// After confirmation: drop the account and apply at once, so its icon app, login item, status and
    /// preferences go right away (Installer.sync removes them). Claude's own folders aren't touched.
    func confirmRemove() {
        guard let e = pendingRemoval else { return }
        pendingRemoval = nil
        remove(e.id)
        var hidden = UserDefaults.standard.stringArray(forKey: "dashboardHidden") ?? []
        hidden.removeAll { $0 == e.id }
        UserDefaults.standard.set(hidden, forKey: "dashboardHidden")
        apply()
        message = "Removed \(e.name)"
    }

    func remove(_ id: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: i)
        if selection == id { selection = accounts.isEmpty ? nil : accounts[max(0, i - 1)].id }
    }

    func revert() {
        accounts = saved.isEmpty ? accounts : saved
        if !accounts.contains(where: { $0.id == selection }) { selection = accounts.first?.id }
        message = ""
    }

    func apply() {
        guard problem == nil else { return }
        do {
            try Store.save(accounts)
            saved = accounts
            message = "Applying…"
            let list = accounts
            DispatchQueue.main.async {
                let log = Installer.sync(list)
                self.message = log.isEmpty ? "Icons are up to date" : log.joined(separator: ", ")
            }
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// The choices for a picker, always including the current value.
    func choices(_ list: [FolderChoice], current: String) -> [FolderChoice] {
        if current.isEmpty || list.contains(where: { $0.path == current }) { return list }
        return list + [FolderChoice(path: current, detail: current.contains(".claude") ? Account.expectedEmail(configDir: current) : nil)]
    }
}

// MARK: - Page

struct SettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        page.alert(model.pendingRemoval.map { "Remove “\($0.name)”?" } ?? "",
                   isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } })) {
            Button("Remove", role: .destructive) { model.confirmRemove() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            Text(removalText)
        }
    }

    var removalText: String {
        guard let e = model.pendingRemoval else { return "" }
        var t = "Its Dock icon “cl_audit \(e.name)” is quit and deleted, with its open-at-login entry and saved status."
        t += "\n\nNot touched: the Claude Code folder \(e.configDir) and its login"
        t += e.desktop == .separate && !e.desktopDataDir.isEmpty ? ", and the Claude window's data folder." : "."
        if model.needsApply { t += "\n\nOther changes waiting for Apply are applied too." }
        return t
    }

    var page: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        DashboardTile(selected: model.selection == SettingsModel.dashboardID)
                            .onTapGesture { model.selection = SettingsModel.dashboardID }
                        ForEach(model.accounts) { a in AccountTile(entry: a, selected: a.id == model.selection, model: model) }
                        if model.draft != nil {
                            NewTile(selected: model.selection == SettingsModel.newID).onTapGesture { model.selection = SettingsModel.newID }
                        }
                        Button(action: model.startNew) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Set up a new Claude account")
                    }
                    .padding(.vertical, 2)
                }
                applyBar
                ShowEmailsSwitch().padding(.leading, 6)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.5)
            if model.selection == SettingsModel.newID, model.draft != nil {
                // The add-account page scrolls itself, so its action bar can stay pinned at the bottom.
                NewAccountView(draft: Binding(get: { model.draft ?? NewAccountDraft() }, set: { model.draft = $0 }), model: model)
            } else { ScrollView {
                if model.selection == SettingsModel.dashboardID {
                    DashboardSettings().padding(14)
                } else if let id = model.selection, let entry = model.binding(id) {
                    AccountSettings(entry: entry, model: model).padding(14)
                } else {
                    Text("Add an account with ＋").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                }
            } }
        }
    }

    /// The same page without scroll views, for rendering to an image (image rendering skips scroll views).
    var snapshot: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DashboardTile(selected: model.selection == SettingsModel.dashboardID)
                ForEach(model.accounts) { a in AccountTile(entry: a, selected: a.id == model.selection, model: model) }
                Spacer()
                applyBar
                ShowEmailsSwitch().padding(.leading, 6)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.5)
            if model.selection == SettingsModel.dashboardID { DashboardSettings().padding(14) }
            else if let id = model.selection, let entry = model.binding(id) { AccountSettings(entry: entry, model: model).padding(14) }
        }
    }

    var applyBar: some View {
        HStack(spacing: 8) {
            if let p = model.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption).lineLimit(2)
            } else if model.needsApply {
                Text("New names, labels or accounts need Apply").font(.caption).foregroundStyle(.secondary)
            } else if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.needsApply {
                Button("Revert", action: model.revert).buttonStyle(PillButtonStyle(tint: nil, compact: true))
                Button("Apply", action: model.apply).buttonStyle(.pill(.green, compact: true))
                    .keyboardShortcut(.defaultAction).disabled(model.problem != nil)
            }
        }
        .fixedSize()
    }
}

/// The strip's tile for an account being set up.
struct NewTile: View {
    let selected: Bool
    var body: some View {
        HStack(spacing: 8) {
            // Styled like the other tiles (highlighted only while selected), text only.
            VStack(alignment: .leading, spacing: 0) {
                Text("New account").font(.system(size: 12.5, weight: .semibold))
                Text("not added yet").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(minHeight: 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(selected ? 0.3 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}

struct AccountTile: View {
    let entry: AccountEntry
    let selected: Bool
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: preview(entry, status: Store.status(entry.id), tick: model.tick)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name.isEmpty ? "New account" : entry.name).font(.system(size: 12.5, weight: .semibold))
                Text(entry.configDir).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(selected ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(selected ? 0.3 : 0.07), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = entry.id }
        .contextMenu { Button("Remove \(entry.name)…", role: .destructive) { model.askRemove(entry.id) } }
    }
}

// MARK: - Cards and rows

struct SCard<Content: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                if let info { InfoDot(text: info) }
            }
            .padding(.bottom, 2)
            VStack(spacing: 0) { content }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

struct SRow<Control: View>: View {
    let label: String
    var info: String? = nil
    var first = false
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.82)).lineLimit(1)
                if let info { InfoDot(text: info) }
                Spacer(minLength: 6)
                control
            }
            .frame(minHeight: 28)
        }
    }
}

struct InfoDot: View {
    let text: String
    var body: some View {
        Image(systemName: "info.circle").font(.system(size: 10.5)).foregroundStyle(.tertiary).help(text)
    }
}

/// − value ＋ in small pills.
struct MiniStepper: View {
    let text: String
    let down: () -> Void
    let up: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: down) { Image(systemName: "minus").frame(width: 18, height: 16) }
            Text(text).font(.system(size: 12, weight: .medium)).monospacedDigit().frame(minWidth: 34)
            Button(action: up) { Image(systemName: "plus").frame(width: 18, height: 16) }
        }
        .buttonStyle(PillButtonStyle(tint: nil, compact: true))
    }
}

extension View {
    /// Small switch in the app's green instead of the system accent.
    func smallSwitch() -> some View {
        toggleStyle(.switch).labelsHidden().controlSize(.mini).tint(Color(nsColor: Painter.green))
    }
    func smallMenu() -> some View { labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize() }
}

extension ClickAction {
    var shortTitle: String {
        switch self {
        case .peekThenOpen: return "Usage, then Claude"
        case .open: return "Open Claude"
        case .details: return "Details panel"
        }
    }
}

extension PanelDesign {
    var shortTitle: String {
        switch self {
        case .glow: return "Glow"
        case .rings: return "Rings"
        case .numbers: return "Numbers"
        case .segments: return "Segments"
        case .pace: return "Pace"
        }
    }
}

// MARK: - The selected account

struct AccountSettings: View {
    @Binding var entry: AccountEntry
    @ObservedObject var model: SettingsModel

    var status: IconStatus? { _ = model.tick; return Store.status(entry.id) }
    var expected: String? { Account.expectedEmail(configDir: entry.configDir) }
    var mismatch: Bool {
        guard let a = status?.loginEmail, let b = expected else { return false }
        return a.lowercased() != b.lowercased()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) { accountCard; loginCard }.frame(maxWidth: .infinity)
            VStack(spacing: 10) { clickCard; behaviourCard }.frame(maxWidth: .infinity)
            VStack(spacing: 10) { iconCard; panelsCard }.frame(maxWidth: .infinity)
        }
    }

    // Account
    var accountCard: some View {
        SCard(title: "Account") {
            SRow(label: "Name", first: true) {
                TextField("", text: $entry.name).textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(maxWidth: 150)
            }
            SRow(label: "Icon label", info: "Drawn on the icon, up to 6 letters. The Dock shows the app as “cl_audit \(entry.name)”.") {
                TextField("", text: Binding(get: { entry.label },
                                            set: { entry.label = String($0.uppercased().filter { !$0.isWhitespace }.prefix(6)) }))
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(maxWidth: 90)
            }
            SRow(label: "Colour", info: "This account's colour in the launcher, the dashboard (chips, cards and charts) and the panels. The icon has its own colour, under Icon.") {
                HStack(spacing: 6) {
                    ForEach(TileColor.accents, id: \.self) { c in
                        Swatch(color: c, selected: entry.accentColor == c, size: 14)
                            .onTapGesture { entry.accent = c }
                            .help(c.rawValue.capitalized)
                    }
                }
            }
            SRow(label: "") {
                Button("Remove account…") { model.askRemove(entry.id) }.buttonStyle(.plain).font(.caption).foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    // Login
    var loginCard: some View {
        SCard(title: "Claude Code login",
              info: "The icon reads this folder's Claude Code login from the Keychain, read-only, through Apple's security tool, the same way Claude Code does. No Keychain permission is added.") {
            SRow(label: "Folder", first: true) {
                HStack(spacing: 4) {
                    Menu {
                        ForEach(model.choices(model.configFolders, current: entry.configDir), id: \.path) { c in
                            let owner = FolderRules.configOwner(c.path, among: model.accounts, except: entry.id)
                            Button {
                                entry.configDir = c.path
                            } label: {
                                Text(c.title + (owner.map { "  —  used by \($0.name)" } ?? FolderKey.canonical(c.path) == FolderKey.canonical(entry.configDir) ? "  ✓" : ""))
                            }
                            .disabled(owner != nil)
                        }
                        Divider()
                        Button("Choose another folder…") { useFolder(pickFolder()) }
                    } label: { Text(entry.configDir.isEmpty ? "Choose…" : entry.configDir) }
                    .menuStyle(.button).controlSize(.small).fixedSize()
                    Button { useFolder(pickFolder()) } label: { Image(systemName: "folder") }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).help("Choose another folder…")
                }
            }
            SRow(label: "Login") { loginStatus }
            if mismatch || status?.state == "noLogin" || status?.state == "expired" {
                SRow(label: mismatch ? "Folder is for \(expected ?? "another account")" : "Sign in again") {
                    Button("Log in…") {
                        if let claude = model.claudePath { ClaudeCLI.openLogin(claude, account: Account(entry), email: expected) }
                    }
                    .buttonStyle(.pill(.red, compact: true)).disabled(model.claudePath == nil)
                }
            }
            SRow(label: "Renew expired login",
                 info: model.claudePath == nil ? "Needs Claude Code installed; it wasn't found."
                    : "When the login has expired, the icon runs Claude Code once with a one-line Haiku prompt so Claude Code renews it, at most every 30 minutes. Uses a little of this account's usage." + (status?.renewNote.map { "\nLast: \($0)" } ?? "")) {
                Toggle("", isOn: $entry.autoRenew).smallSwitch().disabled(model.claudePath == nil)
            }
        }
    }

    @ViewBuilder var loginStatus: some View {
        if mismatch {
            Label(status?.loginEmail ?? "", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red).lineLimit(1)
                .settingsEmail()
        } else if status?.state == "expired" {
            Label("expired", systemImage: "clock.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
        } else if let e = status?.loginEmail {
            Label(e, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color(nsColor: Painter.green)).lineLimit(1)
                .settingsEmail()
        } else {
            Text(expected ?? "not logged in yet").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .settingsEmail(expected != nil)
        }
    }

    // Clicks
    var clickCard: some View {
        SCard(title: "Clicking the icon") {
            SRow(label: "Click", first: true) {
                Picker("", selection: $entry.clickAction) { ForEach(ClickAction.allCases) { Text($0.shortTitle).tag($0) } }.smallMenu()
            }
            if entry.clickAction == .peekThenOpen {
                SRow(label: "Show usage for") {
                    MiniStepper(text: PeekDuration.text(entry.peekSeconds),
                                down: { entry.peekSeconds = PeekDuration.down(entry.peekSeconds) },
                                up: { entry.peekSeconds = PeekDuration.up(entry.peekSeconds) })
                }
            }
            SRow(label: "Press and hold", info: "Experimental: press and hold shows the details panel next to a short Dock menu. Double-click or ⌥-click always shows it; right-click shows the full menu.") {
                Toggle("", isOn: $entry.longPressDetails).smallSwitch()
            }
            SRow(label: "Claude window", info: "Which Claude desktop window this account opens. A separate window has its own sign-in and uses this account's settings folder in its Code tab.") {
                Menu {
                    ForEach([DesktopMode.standard, .separate, .none]) { mode in
                        let owner = mode == .standard ? FolderRules.windowOwner(.standard, "", among: model.accounts, except: entry.id) : nil
                        Button {
                            entry.desktop = mode
                        } label: {
                            Text((mode == .standard ? "Standard" : mode == .separate ? "Separate" : "None")
                                 + (owner.map { "  —  used by \($0.name)" } ?? (entry.desktop == mode ? "  ✓" : "")))
                        }
                        .disabled(owner != nil)
                    }
                } label: { Text(entry.desktop == .standard ? "Standard" : entry.desktop == .separate ? "Separate" : "None") }
                .menuStyle(.button).controlSize(.small).fixedSize()
            }
            if entry.desktop == .separate {
                SRow(label: "Data folder") {
                    Menu {
                        ForEach(model.choices(model.dataFolders, current: entry.desktopDataDir), id: \.path) { c in
                            let owner = FolderRules.windowOwner(.separate, c.path, among: model.accounts, except: entry.id)
                            Button {
                                entry.desktopDataDir = c.path
                            } label: {
                                Text((c.path as NSString).lastPathComponent + (owner.map { "  —  used by \($0.name)" } ?? ""))
                            }
                            .disabled(owner != nil)
                        }
                        Divider()
                        Button("New: Claude-\(entry.id)") {
                            let dir = "~/Library/Application Support/Claude-\(entry.id)"
                            try? FileManager.default.createDirectory(atPath: expand(dir), withIntermediateDirectories: true)
                            entry.desktopDataDir = dir
                        }
                        .disabled(FolderRules.windowOwner(.separate, "~/Library/Application Support/Claude-\(entry.id)", among: model.accounts, except: entry.id) != nil)
                    } label: { Text(entry.desktopDataDir.isEmpty ? "Choose…" : (entry.desktopDataDir as NSString).lastPathComponent) }
                    .menuStyle(.button).controlSize(.small).fixedSize()
                }
            }
        }
    }

    // Behaviour
    var behaviourCard: some View {
        SCard(title: "Behaviour") {
            SRow(label: "Refresh every", first: true) {
                Picker("", selection: $entry.pollMinutes) { ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }.smallMenu()
            }
            SRow(label: "Notify near a limit") { Toggle("", isOn: $entry.notify).smallSwitch() }
            if entry.notify {
                SRow(label: "Notify at") {
                    MiniStepper(text: "\(entry.notifyPercent)%",
                                down: { entry.notifyPercent = max(50, entry.notifyPercent - 5) },
                                up: { entry.notifyPercent = min(100, entry.notifyPercent + 5) })
                }
            }
            SRow(label: "Open at login") { Toggle("", isOn: $entry.openAtLogin).smallSwitch() }
        }
    }

    // Icon: style, colour, frame
    var iconCard: some View {
        SCard(title: "Icon") {
            IconGallery(entry: $entry, status: status)
            SRow(label: "Colour", info: entry.color == .usage ? "By usage: the colour follows the 5-hour level." : "Tells the accounts apart: the label, the Big number tile, the panels' dot.") {
                HStack(spacing: 2) {
                    ForEach(TileColor.allCases) { c in
                        Swatch(color: c, selected: entry.color == c, size: 14).onTapGesture { entry.color = c }.help(c.title)
                    }
                }
            }
            SRow(label: "Frame") {
                HStack(spacing: 2) {
                    NoneSwatch(selected: entry.frame == nil, size: 14).onTapGesture { entry.frame = nil }.help("No frame")
                    ForEach(TileColor.allCases) { c in
                        Swatch(color: c, selected: entry.frame == c, size: 14).onTapGesture { entry.frame = c }.help(c.title)
                    }
                }
            }
        }
    }

    // Panels
    var panelsCard: some View {
        SCard(title: "Panels", info: "Click: this panel for a moment. Double-click, ⌥-click or long press: the large panel in the same design.") {
            PillPicker(options: PanelDesign.allCases, selection: $entry.panelDesign, compact: true) { $0.shortTitle }
                .frame(maxWidth: .infinity, alignment: .leading)
            CompactView(info: sampleInfo).scaleEffect(0.92, anchor: .topLeading)
                .frame(height: 134, alignment: .topLeading).padding(.top, 8)
        }
    }

    /// The panel preview: this account's latest numbers when known, otherwise samples.
    var sampleInfo: DetailsInfo {
        let s = status
        return DetailsInfo(
            name: entry.name.isEmpty ? "account" : entry.name, icon: preview(entry, status: s),
            login: s?.loginEmail, expected: expected, mismatch: false, plan: s?.plan,
            fiveHour: s?.fiveHour ?? 23, fiveHourResets: s?.fiveHourResets ?? Date().addingTimeInterval(3 * 3600 + 20 * 60),
            weekly: s?.weekly ?? 58, weeklyResets: s?.weeklyResets ?? Date().addingTimeInterval(2 * 86400 + 5 * 3600),
            updated: s?.updatedAt, source: nil, problem: nil, renewNote: nil,
            canOpenClaude: true, needsLogin: false,
            design: entry.panelDesign, accent: entry.accentNSColor)
    }

    /// A folder picked in Finder, used only if no other account has it and it's a Claude Code folder (or empty).
    func useFolder(_ path: String?) {
        guard let path else { return }
        if let owner = FolderRules.configOwner(path, among: model.accounts, except: entry.id) {
            model.message = FolderKey.canonical(owner.configDir) == FolderKey.canonical(path)
                ? "\(path) is already used by “\(owner.name)”." : "\(path) is inside, or contains, “\(owner.name)”'s folder."
            return
        }
        switch FolderKind.of(path) {
        case .other: model.message = "\(path) isn't a Claude Code folder and isn't empty."
        case .missing: model.message = "\(path) doesn't exist."
        default: entry.configDir = path
        }
    }
}

/// All icon styles as tiles with the account's numbers, grouped by family. The chosen style's good → bad
/// lane opens right under its tile, and tile and lane share one surface.
struct IconGallery: View {
    @Binding var entry: AccountEntry
    var status: IconStatus?
    static let states: [(Double, Double)] = [(5, 12), (30, 45), (58, 62), (84, 78), (97, 94)]
    static let columns = 4
    static let spacing: CGFloat = 4
    static let tileHeight: CGFloat = 74

    func model(_ st: IconStyle, _ h: Double? = nil, _ w: Double? = nil) -> TileModel {
        TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: h ?? status?.fiveHour ?? 58,
                  weekly: w ?? status?.weekly ?? 62, stale: false, style: st, tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: 45, weeklyElapsed: 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(IconFamily.allCases) { fam in
                Text(fam.title).font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 2)
                let rows = stride(from: 0, to: fam.styles.count, by: Self.columns).map {
                    Array(fam.styles[$0..<min($0 + Self.columns, fam.styles.count)])
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let col = row.firstIndex(of: entry.style) {
                        ZStack(alignment: .topLeading) {
                            TileLaneShape(column: col, columns: Self.columns, spacing: Self.spacing, tileHeight: Self.tileHeight)
                                .fill(Color.primary.opacity(0.11))
                            VStack(spacing: 0) {
                                tiles(row)
                                lane.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 9)
                            }
                        }
                        .padding(.bottom, 4)
                    } else {
                        tiles(row)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }

    func tiles(_ row: [IconStyle]) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(0..<Self.columns, id: \.self) { i in
                if i < row.count { tile(row[i]) } else { Color.clear.frame(maxWidth: .infinity) }
            }
        }
        .frame(height: Self.tileHeight)
    }

    func tile(_ st: IconStyle) -> some View {
        let on = entry.style == st
        return VStack(spacing: 3) {
            Image(nsImage: Painter.image(model(st), pixels: 112)).resizable().frame(width: 48, height: 48)
            Text(st.shortTitle).font(.system(size: 10, weight: on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { entry.style = st } }
        .help("\(st.title): \(st.blurb)")
    }

    /// The chosen style at about Dock size as the 5-hour limit fills up, under a bar in the level colours.
    var lane: some View {
        let segments = [Painter.green, Painter.green, Painter.amber, Painter.red, Painter.red]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Preview").font(.system(size: 11, weight: .semibold))
                Text("as the limit fills up").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                ForEach(0..<segments.count, id: \.self) { i in
                    Capsule().fill(Color(nsColor: segments[i])).frame(height: 3)
                }
            }
            .padding(.top, 2)
            HStack {
                Text("plenty left")
                Spacer()
                Text("half used")
                Spacer()
                Text("at limit")
            }
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(Array(Self.states.enumerated()), id: \.offset) { _, v in
                    Image(nsImage: Painter.image(model(entry.style, v.0, v.1), pixels: 96)).resizable().frame(width: 40, height: 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 2)
        }
    }
}

/// One surface for the selected tile and the lane under it: the tile's rounded top flows into the lane
/// with soft inner curves where they meet (none where the tile sits at the card's edge).
struct TileLaneShape: Shape {
    let column: Int
    let columns: Int
    let spacing: CGFloat
    let tileHeight: CGFloat
    var radius: CGFloat = 12
    var fillet: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        let w = (rect.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let x0 = CGFloat(column) * (w + spacing), x1 = x0 + w
        let th = tileHeight, r = radius, f = fillet
        let atLeft = column == 0, atRight = column == columns - 1
        var p = Path()
        p.move(to: CGPoint(x: x0 + r, y: 0))
        p.addLine(to: CGPoint(x: x1 - r, y: 0))
        p.addQuadCurve(to: CGPoint(x: x1, y: r), control: CGPoint(x: x1, y: 0))
        if atRight {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        } else {
            p.addLine(to: CGPoint(x: x1, y: th - f))
            p.addQuadCurve(to: CGPoint(x: x1 + f, y: th), control: CGPoint(x: x1, y: th))
            p.addLine(to: CGPoint(x: rect.maxX - r, y: th))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: th + r), control: CGPoint(x: rect.maxX, y: th))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        }
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - r), control: CGPoint(x: 0, y: rect.maxY))
        if atLeft {
            p.addLine(to: CGPoint(x: 0, y: r))
        } else {
            p.addLine(to: CGPoint(x: 0, y: th + r))
            p.addQuadCurve(to: CGPoint(x: r, y: th), control: CGPoint(x: 0, y: th))
            p.addLine(to: CGPoint(x: x0 - f, y: th))
            p.addQuadCurve(to: CGPoint(x: x0, y: th - f), control: CGPoint(x: x0, y: th))
            p.addLine(to: CGPoint(x: x0, y: r))
        }
        p.addQuadCurve(to: CGPoint(x: x0 + r, y: 0), control: CGPoint(x: x0, y: 0))
        p.closeSubpath()
        return p
    }
}

struct Swatch: View {
    let color: TileColor
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            if color == .usage {
                Circle().fill(AngularGradient(colors: [Color(nsColor: Painter.green), Color(nsColor: Painter.amber),
                                                       Color(nsColor: Painter.red), Color(nsColor: Painter.green)],
                                              center: .center))
            } else {
                Circle().fill(Color(nsColor: color.color(fiveHour: nil, stale: false)))
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(selected ? Color.primary.opacity(0.85) : Color.clear, lineWidth: 1.5).padding(-3))
        .padding(3)
        .contentShape(Circle())
    }
}


struct NoneSwatch: View {
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary, lineWidth: 1.5)
            Rectangle().fill(Color.secondary).frame(width: 1.5, height: size + 2).rotationEffect(.degrees(45))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(selected ? Color.primary : Color.clear, lineWidth: 2).padding(-3))
        .padding(3)
        .contentShape(Circle())
    }
}

/// The icon as the Dock would show it, with the account's latest numbers or sample ones.
/// The account's Dock icon; without a status it shows sample usage (23 % and 41 %), or none when `sample` is off.
func preview(_ e: AccountEntry, status: IconStatus?, style: IconStyle? = nil, tick: Int = 0, sample: Bool = true) -> NSImage {
    let expected = Account.expectedEmail(configDir: e.configDir)
    let warn = status?.loginEmail.map { $0.lowercased() != expected?.lowercased() } ?? false
    let m = TileModel(label: e.label.isEmpty ? "?" : e.label,
                      fiveHour: status?.fiveHour ?? (sample ? 23 : nil), weekly: status?.weekly ?? (sample ? 41 : nil),
                      stale: false, style: style ?? e.style, warn: warn && expected != nil, tint: e.color,
                      frame: e.frame)
    return Painter.image(m, pixels: 128)
}

/// Settings is a page of the one cl_audit window, not a window of its own.
enum SettingsWindow {
    static func show() {
        (NSApp.delegate as? AppDelegate)?.manager.showMain(page: .settings)
    }
}

/// App and Edit menus, so the settings window gets Quit and copy/paste shortcuts.
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettingsWindow), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit cl_audit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Dashboard", action: #selector(AppDelegate.showMainScreen), keyEquivalent: "0")
        window.addItem(withTitle: "Launcher", action: #selector(AppDelegate.showLauncher), keyEquivalent: "l")
        window.addItem(.separator())
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        NSApp.mainMenu = main
    }
}
