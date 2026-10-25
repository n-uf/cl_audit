// Settings: the Settings page of the cl_audit window. Accounts across the top; the selected account's
// settings in three columns of compact cards. Changes are saved as you make them; only a new name or
// label, or adding and removing accounts, needs Apply (that installs, renames or removes icon apps).

import AppKit
import Combine
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var accounts: [AccountEntry] { didSet { scheduleSave() } }
    @Published var selection: String? { didSet { if oldValue != selection, note != nil { hideNote() } } }
    static let dashboardID = "__dashboard__"
    @Published var message = ""
    @Published var tick = 0                 // bumped every few seconds so icon status re-reads
    private(set) var saved: [AccountEntry]
    var configFolders: [FolderChoice] { Detect.configFolders() }
    var dataFolders: [FolderChoice] { Detect.desktopDataFolders() }
    let claudePath = ClaudeCLI.find()
    private var timer: Timer?
    private var saveWork: DispatchWorkItem?

    /// "What this does now", after a change to a setting without a picture of its own.
    @Published var note: SettingNote?
    private var noteHide: DispatchWorkItem?
    private var noteHovered = false
    private var emailsWatch: AnyCancellable?

    func showNote(_ n: SettingNote) {
        withAnimation(.easeOut(duration: 0.18)) { note = n }
        scheduleNoteHide()
    }
    func hideNote() {
        noteHide?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { note = nil }
    }
    func hoverNote(_ on: Bool) {
        noteHovered = on
        if on { noteHide?.cancel() } else { scheduleNoteHide() }
    }
    private func scheduleNoteHide() {
        noteHide?.cancel()
        guard !noteHovered else { return }
        let w = DispatchWorkItem { [weak self] in self?.hideNote() }
        noteHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    init() {
        saved = Store.load()
        accounts = saved.isEmpty
            ? [AccountEntry(id: "main", name: "main", label: "MAIN", configDir: "~/.claude")]
            : saved
        selection = Self.dashboardID
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick += 1 }
        // after the change, not inside it: an animated note started while the window is redrawing for the
        // change itself left the Emails key and the cards showing the old state
        emailsWatch = Privacy.shared.$show.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.showNote(SettingNotes.emails(on)) }
    }

    /// Picks up changes made elsewhere (e.g. an icon's own Options menu) when nothing is pending here.
    func reloadIfClean() {
        guard !needsApply else { return }
        let fresh = Store.load()
        if !fresh.isEmpty, fresh != accounts { saved = fresh; accounts = fresh }
        if !isValid(selection) { selection = Self.dashboardID }
    }

    /// A selection that still points at something: an account, the Dashboard tile, or a new account being set up.
    func isValid(_ id: String?) -> Bool {
        id == Self.dashboardID || (id == Self.newID && draft != nil) || accounts.contains { $0.id == id }
    }

    /// Settings opened from inside the app: the Dashboard tile, unless a new account is being set up.
    func openDefault() {
        reloadIfClean()
        if !(selection == Self.newID && draft != nil) { selection = Self.dashboardID }
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
        for a in accounts { if let p = a.problem { return "\(a.name.isEmpty ? "New profile" : a.name): \(p)" } }
        let names = accounts.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(names).count != names.count { return "Two profiles have the same name." }
        return FolderRules.clash(in: accounts)          // one account per Claude Code folder and per window
    }

    func binding(_ id: String) -> Binding<AccountEntry>? {
        guard accounts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.accounts.first { $0.id == id } ?? AccountEntry(id: id, name: "", label: "", configDir: "") },
            set: { new in
                guard let i = self.accounts.firstIndex(where: { $0.id == id }) else { return }
                let old = self.accounts[i]
                self.accounts[i] = new
                if let n = SettingNotes.note(from: old, to: new) { self.showNote(n) }
            })
    }

    func add() {
        var n = accounts.count + 1
        while accounts.contains(where: { $0.name == "profile \(n)" }) { n += 1 }
        let name = "profile \(n)"
        let id = Store.newID(from: name, taken: accounts.map(\.id))
        let used = Set(accounts.map { expand($0.configDir) })     // suggest a settings folder no account uses yet
        let folder = configFolders.first { !used.contains(expand($0.path)) }?.path ?? ""
        accounts.append(AccountEntry(id: id, name: name, label: "ACC\(n)", configDir: folder))
        selection = id
    }

    /// A new account being set up from scratch (the "New profile" tile), not yet in `accounts`.
    @Published var draft: NewAccountDraft?
    static let newID = "__new__"

    func startNew() {
        if draft == nil {
            var d = NewAccountDraft()
            let used = Set(accounts.map(\.color))
            d.color = TileColor.accents.first { !used.contains($0) } ?? .purple
            d.template = accounts.first(where: { $0.id == selection }) ?? accounts.first
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
                self.message = "Cancelled \(d.name.isEmpty ? "the new profile" : d.name); its folders and login were removed"
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

    /// Drops the account and applies at once: Installer.sync quits and deletes its icon app and everything macOS
    /// keeps for it. Then its Terminal scripts go and, if asked, its folders (signed out first). Other changes
    /// waiting for Apply are applied with it.
    func removeAccount(_ e: AccountEntry, deleteFolders: Bool) {
        remove(e.id)
        var hidden = UserDefaults.standard.stringArray(forKey: "dashboardHidden") ?? []
        hidden.removeAll { $0 == e.id }
        UserDefaults.standard.set(hidden, forKey: "dashboardHidden")
        let claude = claudePath
        apply {
            self.message = deleteFolders ? "Removed \(e.name); deleting its folders…" : "Removed \(e.name)"
            DispatchQueue.global(qos: .userInitiated).async {
                let failed = deleteFolders ? AccountRemoval.deleteFolders(e, claude: claude) : []
                AccountRemoval.removeScripts(e.configDir)
                DispatchQueue.main.async {
                    self.message = !failed.isEmpty ? "Removed \(e.name), but couldn't delete " + failed.joined(separator: ", ")
                        : deleteFolders ? "Removed \(e.name) and deleted its folders" : "Removed \(e.name); its folders are kept"
                }
            }
        }
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

    /// A name or label edit being saved (its Dock icon app is renamed or rebuilt), why the last one couldn't be,
    /// and what the last one did, for the top strip's display.
    @Published var saving = false
    @Published var unsaved: String?
    @Published var savedNote: String?
    private var savedNoteClear: DispatchWorkItem?

    /// Saves a name or label change at once (no Apply): the Dock icon apps follow, then the display says so.
    func saveNow(_ what: String) {
        saving = true
        unsaved = nil
        apply { [weak self] in
            guard let self else { return }
            self.saving = false
            self.savedNote = what
            self.savedNoteClear?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.savedNote = nil }
            self.savedNoteClear = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        }
    }

    func apply(then done: (() -> Void)? = nil) {
        guard problem == nil else { return }
        do {
            try Store.save(accounts)
            saved = accounts
            message = "Applying…"
            let list = accounts
            DispatchQueue.main.async {
                let log = Installer.sync(list)
                self.message = log.isEmpty ? "Icons are up to date" : log.joined(separator: ", ")
                DockManager.afterAccountsChanged(list)       // pins a new icon into the group, when managed
                done?()
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
    @Environment(\.face) private var face

    var body: some View {
        page.sheet(item: $model.pendingRemoval) { e in RemoveAccountSheet(entry: e, model: model) }
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
                            TileKey(selected: false, leading: 0, trailing: 0) {
                                Image(systemName: "plus").font(.system(size: 15, weight: .light)).frame(width: 42)
                            }
                        }
                        .buttonStyle(PressableKey()).help("Add a profile")
                    }
                    .padding(.vertical, 3).padding(.horizontal, 2)
                }
                applyBar
            }
            .padding(8)
            .background(SurfaceShape(surface: face.strip, radius: 7))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
            if model.selection == SettingsModel.newID, model.draft != nil {
                // The add-account page scrolls itself, so its action bar can stay pinned at the bottom.
                NewAccountView(draft: Binding(get: { model.draft ?? NewAccountDraft() }, set: { model.draft = $0 }), model: model)
            } else { GeometryReader { geo in ScrollView {
                let w = geo.size.width - 32
                if model.selection == SettingsModel.dashboardID {
                    DashboardSettings(width: w).padding(.horizontal, 16).padding(.vertical, 14)
                } else if let id = model.selection, let entry = model.binding(id) {
                    AccountSettings(entry: entry, model: model, width: w).padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    Text("Add a profile with ＋").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                }
            } }
            } // the setting note floats over the whole window (MainWindowView), so the Emails key shows it on the dashboard too
        }
    }

    /// The same page without scroll views, for rendering to an image (image rendering skips scroll views).
    var snapshot: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DashboardTile(selected: model.selection == SettingsModel.dashboardID)
                ForEach(model.accounts) { a in AccountTile(entry: a, selected: a.id == model.selection, model: model) }
                TileKey(selected: false, leading: 0, trailing: 0) { Image(systemName: "plus").font(.system(size: 15, weight: .light)).frame(width: 42) }
                Spacer()
                applyBar
            }
            .padding(8)
            .background(SurfaceShape(surface: face.strip, radius: 7))
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)
            if model.selection == SettingsModel.dashboardID { DashboardSettings().padding(14) }
            else if let id = model.selection, let entry = model.binding(id) { AccountSettings(entry: entry, model: model).padding(14) }
        }
    }

    var applyBar: some View {
        HStack(spacing: 8) {
            // why a name or label wasn't saved, or what the last save did
            if let p = model.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(face.danger).font(.caption).lineLimit(2)
            } else if let u = model.unsaved {
                Label(u, systemImage: "exclamationmark.triangle.fill").foregroundStyle(face.danger).font(.caption).lineLimit(2)
            } else if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(face.muted).lineLimit(1)
            }
        }
        .fixedSize()
    }
}

/// "What this does now": the setting note after a change, floating at the bottom of the window on every page.
struct SettingNoteOverlay: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear.allowsHitTesting(false)
            if let n = model.note {
                SettingNoteBanner(note: n, hover: model.hoverNote, close: model.hideNote)
                    .id(n.id)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

/// Settings in the window's top strip: whether everything is saved, in a display window.
struct SettingsStatus: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let w = UpdatedButton.width + 40, h = TopStrip.height
        Group {
            if model.saving { DisplayWindow(text: "Saving…", tone: .amber, height: h, width: w) }
            else if model.unsaved != nil || model.problem != nil { DisplayWindow(text: "Not saved", dim: "· see below", tone: .warn, height: h, width: w) }
            else if let done = model.savedNote { DisplayWindow(text: "Saved", dim: "· \(done)", tone: .ok, height: h, width: w) }
            else if model.selection == SettingsModel.newID { DisplayWindow(text: "New profile", dim: "· not added yet", height: h, width: w) }
            else { DisplayWindow(text: "Saved", dim: "· as you change", height: h, width: w) }
        }
        .help(model.unsaved ?? model.problem ?? "Settings are saved as you change them; a name or label when you press Return")
    }
}

/// The strip's tile for an account being set up.
struct NewTile: View {
    let selected: Bool
    var body: some View {
        // a wide key like the other tiles, text only
        TileKey(selected: selected) { TileText(title: "New profile", sub: "not added yet") }
    }
}

struct AccountTile: View {
    let entry: AccountEntry
    let selected: Bool
    @ObservedObject var model: SettingsModel

    var body: some View {
        TileKey(selected: selected, leading: 5) {
            HStack(spacing: 9) {
                Image(nsImage: preview(entry, status: Store.status(entry.id), tick: model.tick)).resizable().frame(width: 32, height: 32)
                TileText(title: entry.name.isEmpty ? "New profile" : entry.name, sub: entry.configDir)
            }
        }
        .onTapGesture { model.selection = entry.id }
        .contextMenu { Button("Remove \(entry.name)…", role: .destructive) { model.askRemove(entry.id) } }
    }
}

/// A tile in the profile strip: a wide key; the chosen one latched down with its strip lit.
struct TileKey<Content: View>: View {
    let selected: Bool
    var leading: CGFloat = 12
    var trailing: CGFloat = 12
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        content
            .foregroundStyle(face.legend)
            .shadow(color: face.legendShadow, radius: 0, y: face.legendShadowY)
            .padding(.leading, leading).padding(.trailing, trailing)
            .frame(minHeight: 42)
            .background(RaisedShape(finish: selected ? face.keyDown : face.key, radius: 4, pressed: selected))
            .overlay { if selected { LampStrip() } }
            .contentShape(Rectangle())
    }
}

/// A tile's two lines: its name in spaced capitals and a quieter line under it.
struct TileText: View {
    let title: String
    let sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .bold)).tracking(1).textCase(.uppercase).lineLimit(1)
            Text(sub).font(.system(size: 10.5)).opacity(0.65).lineLimit(1)
        }
        .fixedSize()
    }
}

// MARK: - Cards and rows

/// A settings card: a raised module with a printed label, an engraved rule after it, and its rows.
struct SCard<Content: View>: View {
    let title: String
    var info: String? = nil
    @ViewBuilder let content: Content
    @Environment(\.face) private var face

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Printed(text: title)
                if let info { InfoDot(text: info) }
                EngravedRule(dark: face.light ? .black(0.28) : nil).frame(minWidth: 12)
            }
            .padding(.bottom, 4)
            VStack(spacing: 0) { content }
        }
        .padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RaisedShape(finish: face.module, radius: face.moduleRadius))
    }
}

/// A settings row: the label in a fixed column and the control right after it (never pushed to the card's
/// far edge), or, for wide controls, the label above the control.
struct SRow<Control: View>: View {
    let label: String
    var info: String? = nil
    var first = false
    var stacked = false
    var picture: AnyView? = nil        // a small illustration inside the (i)
    @ViewBuilder let control: Control
    @Environment(\.face) private var face

    static var labelWidth: CGFloat { 128 }

    var body: some View {
        VStack(spacing: 0) {
            if !first { EngravedRule() }
            if stacked {
                VStack(alignment: .leading, spacing: 6) { title; control }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    title.frame(width: Self.labelWidth, alignment: .leading)
                    control
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
            }
        }
    }

    private var title: some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(face.soft).lineLimit(1)
            if let info { InfoDot(text: info, picture: picture) }
        }
    }
}

/// A small text field for settings rows (name, icon label), on an engraved line. Without `commit` every keystroke
/// goes straight to `text`. With it, the edit is kept here until Return or leaving the field, then handed to
/// `commit`, which saves it or returns why it can't; Esc puts the old text back.
struct SField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 180
    var mono = false
    var transform: (String) -> String = { $0 }
    var commit: ((String) -> String?)? = nil
    var cancel: (() -> Void)? = nil
    @State private var draft: String?
    @State private var problem: String?
    @FocusState private var focused: Bool
    @Environment(\.face) private var face

    var body: some View {
        TextField(placeholder, text: Binding(get: { draft ?? text }, set: { v in
            if commit == nil { text = transform(v) } else { draft = transform(v) }
        }))
            .textFieldStyle(.plain).font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
            .foregroundStyle(face.text)
            .focused($focused)
            .onSubmit(finish)
            .onExitCommand { draft = nil; problem = nil; cancel?() }
            .onChange(of: focused) { f in if !f { finish() } }
            .padding(.vertical, 3)
            .overlay(alignment: .bottom) {
                VStack(spacing: 0) {
                    Rectangle().fill(problem != nil ? face.danger : face.light ? Color.black(0.35) : Color.black(0.5)).frame(height: 1)
                    Rectangle().fill(face.light ? Color.white(0.6) : Color.white(0.04)).frame(height: 1)
                }
                .offset(y: 2)
            }
            .frame(width: width)
            .help(problem ?? (commit != nil ? "Return or click elsewhere saves it; Esc puts it back" : ""))
    }

    private func finish() {
        guard let commit, let d = draft else { return }
        if d == text { draft = nil; problem = nil; return }
        if let p = commit(d) { problem = p } else { draft = nil; problem = nil }
    }
}

/// The (i) next to a setting: click it for a short explanation in a popover (hover shows it too).
struct InfoDot: View {
    let text: String
    var picture: AnyView? = nil
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "info.circle.fill" : "info.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(hover || open ? Color.secondary : Color.secondary.opacity(0.6))
                .frame(width: 16, height: 16)          // a bigger target than the glyph
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(text)
        .accessibilityLabel("About this setting")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if let picture { picture }
            }
            .frame(width: 260, alignment: .leading).padding(12)
        }
    }
}

/// − value ＋ in small pills.
struct MiniStepper: View {
    let text: String
    let down: () -> Void
    let up: () -> Void
    /// − and + keys round a small display window.
    var body: some View {
        HStack(spacing: 6) {
            Button(action: down) { Image(systemName: "minus").font(.system(size: 9, weight: .bold)).frame(width: 8) }
            DisplayWindow(text: text).frame(minWidth: 54)
            Button(action: up) { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 8) }
        }
        .buttonStyle(PillButtonStyle(tint: nil, compact: true))
    }
}

extension View {
    /// The on/off switch: a small key with an LED, green while on.
    func smallSwitch() -> some View {
        toggleStyle(LEDSwitchStyle()).labelsHidden()
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
    @State private var dockRestarting = false     // a few seconds after Show in the Dock changes
    @Binding var entry: AccountEntry
    @ObservedObject var model: SettingsModel
    var width: CGFloat = 1280
    @Environment(\.face) private var face

    var status: IconStatus? { _ = model.tick; return Store.status(entry.id) }
    var expected: String? { Account.expectedEmail(configDir: entry.configDir) }
    var mismatch: Bool {
        guard let a = status?.loginEmail, let b = expected else { return false }
        return a.lowercased() != b.lowercased()
    }

    /// The cards in three groups, a column each when there's room: the profile (Profile · Claude Code ·
    /// Updates and alerts), its Dock icon (Dock icon · Opening and closing · Dock icon clicks), and Icon.
    var body: some View {
        // the profile itself, then its Dock icon (what it does, how clicks work), then how the icon looks
        SettingsColumns(width: width, groups: [
            [AnyView(accountCard), AnyView(codeCard), AnyView(updatesCard)],
            [AnyView(dockIconCard), AnyView(openCloseCard), AnyView(clickCard)],
            [AnyView(iconCard)]])
    }

    // Account
    var accountCard: some View {
        SCard(title: "Profile") {
            SRow(label: "Name", info: "What cl_audit calls this profile; its Dock icon app is “cl_audit \(entry.name.isEmpty ? "…" : entry.name)”. Saved when you press Return or click elsewhere (Esc puts it back); saving restarts that Dock icon.", first: true) {
                SField(placeholder: "name", text: $entry.name, width: 170,
                       commit: { v in save("Dock icon renamed") { $0.name = v } }, cancel: { model.unsaved = nil })
            }
            SRow(label: "Icon label", info: "Up to 6 letters printed on this profile's Dock icon, like MAIN or WORK, so you can tell the icons apart. Saved when you press Return or click elsewhere (Esc puts it back).") {
                SField(placeholder: "LABEL", text: $entry.label, width: 80, mono: true,
                       transform: { String($0.uppercased().filter { !$0.isWhitespace }.prefix(6)) },
                       commit: { v in save("icon label changed") { $0.label = v } }, cancel: { model.unsaved = nil })
            }
            SRow(label: "Colour", info: "This profile's colour inside cl_audit: the dot by its name on the dashboard and in the launcher, its Show key, its share of the history charts and the dot on its usage panel. The Dock icon's own colour is under Icon.") {
                SwatchRow(colors: TileColor.accents, selected: entry.accentColor) { if let c = $0 { entry.accent = c } }
            }
            Button("Remove profile…") { model.askRemove(entry.id) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(face.danger)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).padding(.bottom, 4)
                .overlay(alignment: .top) { EngravedRule() }
        }
    }

    // Claude Code and window
    var codeCard: some View {
        SCard(title: "Claude Code",
              info: "The Claude Code folder this profile uses and its sign-in. Its Claude window comes with it: the usual Claude app for the profile using ~/.claude, its own Claude window (own sign-in, chats and settings) for any other.") {
            SRow(label: "Folder", info: "The Claude Code folder for this profile, like ~/.claude: its sign-in, settings and history live there. One profile per folder.", first: true) {
                HStack(spacing: 6) {
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
                    } label: { MenuWell(text: entry.configDir.isEmpty ? "Choose…" : entry.configDir, mono: true) }
                    .faceMenu()
                    Button { useFolder(pickFolder()) } label: { Image(systemName: "folder").font(.system(size: 10.5)) }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).help("Choose another folder…")
                }
            }
            SRow(label: "Login", info: "The claude.ai account this folder is signed in to. The Dock icon reads the sign-in from the Keychain, read-only, the same way Claude Code does; no new Keychain permission.") { loginStatus }
            if mismatch || status?.state == "noLogin" || status?.state == "expired" {
                SRow(label: mismatch ? "Wrong account" : "Sign in again") {
                    Button("Log in…") {
                        if let claude = model.claudePath { ClaudeCLI.openLogin(claude, account: Account(entry), email: expected) }
                    }
                    .buttonStyle(.pill(.red, compact: true)).disabled(model.claudePath == nil)
                }
            }
            SRow(label: "Renew sign-in",
                 info: model.claudePath == nil ? "Needs Claude Code installed; it wasn't found."
                    : "Claude Code's sign-in uses a short-lived access key, which Claude Code swaps for a fresh one whenever it runs. The Dock icon only reads that key, so after a while without Claude Code it runs out and the usage stops updating. On: the Dock icon then runs Claude Code once in the background (a one-line prompt, \"Reply with OK.\", on Haiku, nothing saved) so it swaps the key; at most every 30 min, using a sliver of this profile's usage. Off: the usage waits until you next use Claude Code." + (status?.renewNote.map { "\nLast: \($0)" } ?? "")) {
                Toggle("", isOn: $entry.autoRenew).smallSwitch().disabled(model.claudePath == nil)
            }
        }
    }

    @ViewBuilder var loginStatus: some View {
        if mismatch {
            Label(status?.loginEmail ?? "", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(face.danger).lineLimit(1)
                .settingsEmail()
        } else if status?.state == "expired" {
            Label("expired", systemImage: "clock.badge.exclamationmark").font(.system(size: 12)).foregroundStyle(face.caution)
        } else if let e = status?.loginEmail {
            HStack(spacing: 7) {
                LED(color: FaceTheme.ledOn)
                Text(e).font(.system(size: 12)).foregroundStyle(face.ok).lineLimit(1).settingsEmail()
            }
        } else {
            Text(expected ?? "not logged in yet").font(.system(size: 12)).foregroundStyle(face.muted).lineLimit(1)
                .settingsEmail(expected != nil)
        }
    }

    // Dock icon clicks
    var clickCard: some View {
        SCard(title: "Dock icon clicks", info: "What a click on this profile's Dock icon does, and how the usage panel it opens looks. Double-click or ⌥-click always opens the large panel.") {
            // hidden from the Dock there's nothing to click: say so, offer the way back, and dim the rest
            notInUse("click it")
            clickRows.dockOnly(entry.iconHidden)
        }
    }

    @ViewBuilder private var clickRows: some View {
        VStack(spacing: 0) {
            SRow(label: "Click", info: "Usage, then Claude: the usage panel for a moment, then the Claude window. Open Claude: the Claude window straight away. Details panel: the large usage panel, and Claude only when you ask.", first: true, picture: AnyView(ClickPicture(action: entry.clickAction, seconds: entry.peekSeconds))) {
                Menu {
                    Picker("", selection: $entry.clickAction) { ForEach(ClickAction.allCases) { Text($0.shortTitle).tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { MenuWell(text: entry.clickAction.shortTitle) }
                .faceMenu()
            }
            if entry.clickAction == .peekThenOpen {
                SRow(label: "Usage shows for", info: "How long the usage panel stays up after a click before the Claude window opens.") {
                    MiniStepper(text: PeekDuration.text(entry.peekSeconds),
                                down: { entry.peekSeconds = PeekDuration.down(entry.peekSeconds) },
                                up: { entry.peekSeconds = PeekDuration.up(entry.peekSeconds) })
                }
            }
            SRow(label: "Press and hold", info: "Press and hold the icon for its details panel and a short menu. Double-click or ⌥-click also opens the panel; right-click shows the full menu.") {
                Toggle("", isOn: $entry.longPressDetails).smallSwitch()
            }
            SRow(label: "Usage panel", info: "How the usage panel looks when you click or press and hold this Dock icon. The dashboard's cards have one style for all profiles, in General.", stacked: true) {
                // the keys and, under them, the panel at its own size (the card grows with the taller designs)
                VStack(spacing: 7) {
                    PillPicker(options: PanelDesign.allCases, selection: $entry.panelDesign, compact: true, fill: true) { $0.shortTitle }
                    CompactView(info: sampleInfo).fixedSize().frame(maxWidth: .infinity)
                }
                .padding(7)
                .background(SurfaceShape(surface: face.strip, radius: 7))
            }
        }
    }

    /// While the Dock icon is hidden, at the top of a card that's only about the Dock: why it's faded, and the key
    /// that puts the icon back.
    @ViewBuilder func notInUse(_ what: String) -> some View {
        if entry.iconHidden {
            HStack(spacing: 10) {
                Text("Not in use · show in the Dock to \(what)").font(.system(size: 8.5, weight: .semibold)).tracking(1.3)
                    .textCase(.uppercase).foregroundStyle(face.print).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("Show in the Dock") { showInDock(true) }.buttonStyle(PillButtonStyle(compact: true)).disabled(dockRestarting)
                    .help("Puts this Dock icon back in the Dock (the Dock restarts)")
            }
            .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
            .faceWindow(radius: 6)
            .padding(.bottom, 6)
        }
    }

    /// Shows or hides the Dock icon; the Dock restarts, so "Restarting the Dock…" shows for a few seconds.
    func showInDock(_ on: Bool) {
        entry.iconHidden = !on
        // a running Dock icon app applies it itself (it restarts); one that isn't running would only at its next
        // start, so its pin is taken out or put back here, in its own preferences' place
        let app = Installer.appURL(entry)
        if !Installer.isRunning(app), let d = UserDefaults(suiteName: Installer.bundleID(entry)) {
            dockLog.log("\(entry.id, privacy: .public): Show in the Dock \(on ? "on" : "off", privacy: .public) while stopped")
            if on { DockManager.repin(app, defaults: d) } else { DockManager.unpinRemembering(app, defaults: d) }
        }
        // the Dock icon app restarts, then the Dock (twice when putting a pin back): about 10 s, during which the
        // switch waits, so quick flips can't start changes that undo each other
        dockRestarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { dockRestarting = false }
    }

    // Dock icon: whether it shows in the Dock and starts at login, and where it is now
    var dockIconCard: some View {
        let state = UsageIconState.of(entry)
        let app = Installer.appURL(entry)
        return SCard(title: "Dock icon") {
            // the label, the switch and what it does now on one line; the Dock restart is said in the (i), and shown
            // in a display window while it happens
            SRow(label: "Show in the Dock", info: "On: pinned in the Dock, there even while it's stopped (a click starts it). Off: no place in the Dock; it still runs in the background, refreshing and alerting. Changing this restarts the Dock, which takes the pin out or puts it back.", first: true) {
                // while the change is applied: no clicks, the LED pulses (green turning on, amber turning off)
                LEDSwitchKey(on: !entry.iconHidden,
                             pulse: dockRestarting ? (entry.iconHidden ? FaceTheme.ledAmber : FaceTheme.ledOn) : nil) {
                    showInDock(entry.iconHidden)
                }
                .help(dockRestarting ? (entry.iconHidden ? "Taking it out of the Dock…" : "Putting it in the Dock…") : "")
            }
            SRow(label: "Open at login", info: "Starts this Dock icon when you log in to the Mac, so its usage refreshes and alerts keep working without opening cl_audit.") { Toggle("", isOn: $entry.openAtLogin).smallSwitch() }
            // one display, the full width of the row whatever it says: what the Dock icon is doing now
            SRow(label: "Now") {
                HStack(spacing: 6) {
                    Group {
                        if dockRestarting { DisplayWindow(text: "Restarting the Dock…", tone: .amber, fill: true) }
                        else {
                            switch state {
                            case .inDock: DisplayWindow(text: "Running", dim: "· in the Dock", tone: .ok, fill: true, dimTone: .ok)
                            case .hidden: DisplayWindow(text: "Running", dim: "· hidden", tone: .ok, fill: true, dimTone: .amber)
                            case .notPinned: DisplayWindow(text: "Running", dim: "· unpinned", tone: .ok, fill: true, dimTone: .amber)
                            case .notRunning:
                                if entry.iconHidden { DisplayWindow(text: "Stopped", dim: "· hidden", fill: true, dimTone: .amber) }
                                else if DockManager.isPinned(app) { DisplayWindow(text: "Stopped", dim: "· in the Dock", fill: true) }
                                else { DisplayWindow(text: "Stopped", dim: "· not in the Dock", fill: true, dimTone: .amber) }
                            case .missing: DisplayWindow(text: "Missing", dim: "· reinstall", tone: .warn, fill: true, dimTone: .warn)
                            }
                        }
                    }
                    if state == .notPinned && !dockRestarting {
                        Button("Pin") { DockManager.pin(app) }.buttonStyle(.pill(FaceTheme.led, compact: true)).fixedSize()
                            .help("Pin it in the Dock, after the other cl_audit icons. This restarts the Dock.")
                    }
                }
            }
        }
    }

    // Opening and closing: how the Dock icon and the Claude window follow each other
    @ViewBuilder var openCloseCard: some View {
        do {
            SCard(title: "Opening and closing") {
                OpenCloseQuestions(profile: entry.name.isEmpty ? "this profile" : entry.name, lifecycle: $entry.lifecycle)
            }
        }
    }

    // Updates and alerts
    var updatesCard: some View {
        SCard(title: "Updates and alerts") {
            SRow(label: "Refresh every", info: "How often the Dock icon asks Anthropic for this profile's usage. Shorter is fresher; each check is one small request.", first: true) {
                Menu {
                    Picker("", selection: $entry.pollMinutes) { ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) } }
                        .pickerStyle(.inline).labelsHidden()
                } label: { MenuWell(text: "\(entry.pollMinutes) min") }
                .faceMenu()
            }
            SRow(label: "Notify at", info: "A Mac notification when this profile's 5-hour or weekly usage reaches this level. Off: no notifications.") {
                HStack(spacing: 8) {
                    Toggle("", isOn: $entry.notify).smallSwitch()
                    if entry.notify {
                        MiniStepper(text: "\(entry.notifyPercent)%",
                                    down: { entry.notifyPercent = max(50, entry.notifyPercent - 5) },
                                    up: { entry.notifyPercent = min(100, entry.notifyPercent + 5) })
                    }
                }
            }
        }
    }

    // Icon: style, colour, frame
    var iconCard: some View {
        SCard(title: "Icon") {
            // how it looks in the Dock: nothing to see while it's hidden
            notInUse("see it")
            iconRows.dockOnly(entry.iconHidden)
        }
    }

    @ViewBuilder private var iconRows: some View {
        VStack(spacing: 0) {
            IconGallery(entry: $entry, status: status)
            SRow(label: "Colour", info: "The colour of this profile's Dock icon: its label and tiles. By usage (the last swatch): it follows the 5-hour level, green to red. The profile's colour inside cl_audit is under Profile.", stacked: true) {
                SwatchRow(colors: TileColor.allCases, selected: entry.color) { if let c = $0 { entry.color = c } }
            }
            SRow(label: "Frame", info: "A thin ring in this colour round the Dock icon, to spot it quickly among the others. The crossed circle: no ring.", stacked: true) {
                SwatchRow(colors: TileColor.allCases, selected: entry.frame, none: true) { entry.frame = $0 }
            }
            SRow(label: "Claude open dot", info: "An orange dot at the Dock icon's top-left corner while this profile's Claude window is open. While you pick it here, the icons above show it too.", stacked: true) {
                DotChoice(entry: $entry)
            }
        }
    }

    /// A name or label edit, saved at once; if it clashes with another profile it isn't kept and the reason shows.
    func save(_ what: String, _ change: (inout AccountEntry) -> Void) -> String? {
        let old = entry
        change(&entry)
        if let p = model.problem {
            entry = old
            model.unsaved = p
            return p
        }
        model.saveNow(what)
        return nil
    }

    /// The panel preview: this account's latest numbers when known, otherwise samples.
    var sampleInfo: DetailsInfo {
        let s = status
        return DetailsInfo(
            name: entry.name.isEmpty ? "profile" : entry.name, icon: preview(entry, status: s),
            login: s?.loginEmail, expected: expected, mismatch: false, plan: s?.plan,
            fiveHour: s?.fiveHour ?? 23, fiveHourResets: s?.fiveHourResets ?? Date().addingTimeInterval(3 * 3600 + 20 * 60),
            weekly: s?.weekly ?? 58, weeklyResets: s?.weeklyResets ?? Date().addingTimeInterval(2 * 86400 + 5 * 3600),
            updated: s?.updatedAt, source: nil, problem: nil, renewNote: nil,
            needsLogin: false,
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
    @Environment(\.face) private var face
    static let states: [(Double, Double)] = [(5, 12), (30, 45), (58, 62), (84, 78), (97, 94)]
    static let columns = 4
    static let spacing: CGFloat = 4
    static let tileHeight: CGFloat = 74

    func model(_ st: IconStyle, _ h: Double? = nil, _ w: Double? = nil) -> TileModel {
        TileModel(label: entry.label.isEmpty ? "?" : entry.label, fiveHour: h ?? status?.fiveHour ?? 58,
                  weekly: w ?? status?.weekly ?? 62, stale: false, style: st, tint: entry.color, frame: entry.frame,
                  fiveHourElapsed: 45, weeklyElapsed: 60, windowOpen: entry.windowDot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(IconFamily.allCases) { fam in
                Printed(text: fam.title, size: 9).padding(.top, 6).padding(.bottom, 2)
                let rows = stride(from: 0, to: fam.styles.count, by: Self.columns).map {
                    Array(fam.styles[$0..<min($0 + Self.columns, fam.styles.count)])
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    if let col = row.firstIndex(of: entry.style) {
                        ZStack(alignment: .topLeading) {
                            TileLaneShape(column: col, columns: Self.columns, spacing: Self.spacing, tileHeight: Self.tileHeight)
                                .fill(LinearGradient(stops: face.win.stops, startPoint: .top, endPoint: .bottom)
                                    .shadow(.inner(color: face.win.inner, radius: face.win.innerRadius, y: face.win.innerY)))
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
                .foregroundStyle(on ? face.text : face.muted)
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
                Text("as the limit fills up").font(.system(size: 10.5)).foregroundStyle(face.muted)
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
            .font(.system(size: 9.5)).foregroundStyle(face.muted)
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
        .overlay(Circle().stroke(Color.black(0.45), lineWidth: 1))
        .overlay { if selected { SwatchRing() } }
        .padding(4)
        .contentShape(Circle())
    }
}

/// The chosen swatch: a ring lit in the LED's orange, a little apart from the colour.
struct SwatchRing: View {
    var body: some View {
        Circle().stroke(FaceTheme.led, lineWidth: 1.5).padding(-3.5)
            .shadow(color: FaceTheme.led.opacity(0.55), radius: 3)
    }
}


struct NoneSwatch: View {
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary, lineWidth: 1.5)
            Rectangle().fill(Color.hex(0xf87171)).frame(width: 1.5, height: size + 2).rotationEffect(.degrees(45))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { if selected { SwatchRing() } }
        .padding(4)
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
