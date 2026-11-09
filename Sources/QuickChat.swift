// QuickChat: a floating chat on the account a profile has in use (issue #11). It looks like ChatGPT's classic quick
// chat in Claude's colours: a bar first, and after the first message a chat window that stays floating over any app,
// on every Space, until Esc hides it. It never brings cl_audit or the Claude app forward.
//
// It lives in the cl_audit agent (Agent.swift), which runs at login with no Dock icon and already draws the menu bar
// icons. The talk with Claude Code is QuickChatEngine.swift; the bar and the window are QuickChatViews.swift.
//
// Its files: chats are Claude Code sessions, kept by Claude Code in the profile's own folder under
// projects/<quick chat's work folder>/; the work folder is usage-n-uf/quick-chat/<profile id>/ (empty); its settings are
// usage-n-uf/quick-chat/settings.json. Nothing in macOS preferences.

import AppKit
import SwiftUI

// MARK: - Settings

/// The model a chat answers with: a family, or whatever the profile itself uses in Claude Code.
enum QuickChatModelChoice: String, CaseIterable, Codable, Identifiable {
    case haiku, sonnet, opus, profile
    var id: String { rawValue }
    /// For `--model`; "" leaves it to the profile.
    var flag: String { self == .profile ? "" : rawValue }
    var title: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        case .profile: return "Profile's default"
        }
    }
}

/// How long Claude thinks before it answers: off, or Claude Code's effort.
enum QuickChatThinking: String, CaseIterable, Codable, Identifiable {
    case off, low, medium, high, xhigh
    var id: String { rawValue }
    var effort: String? { self == .off ? nil : rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra"
        }
    }
}

struct QuickChatSettings: Codable, Equatable {
    /// The profile the shortcut chats on; nil: the first profile.
    var profile: String? = nil
    var model: QuickChatModelChoice = .haiku
    var thinking: QuickChatThinking = .off

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        model = (try? c.decodeIfPresent(QuickChatModelChoice.self, forKey: .model)) ?? .haiku
        thinking = (try? c.decodeIfPresent(QuickChatThinking.self, forKey: .thinking)) ?? .off
    }

    static var folder: URL { Store.folder.appendingPathComponent("quick-chat") }
    static var url: URL { folder.appendingPathComponent("settings.json") }
    /// Posted (distributed) after the settings were saved, so the agent reads them again.
    static let changed = Notification.Name("local.usage-n-uf.quick-chat-changed")

    static func load() -> QuickChatSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(QuickChatSettings.self, from: d) else { return .init() }
        return s
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: Self.url, options: .atomic)
        DistributedNotificationCenter.default().postNotificationName(Self.changed, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Quick chat's work folder for a profile: Claude Code runs there.
    static func workFolder(_ profileID: String) -> String { folder.appendingPathComponent(profileID).path }
}

// MARK: - A chat

/// The profile a chat answers on, and its account in use.
struct QuickChatTarget: Equatable {
    var profileID: String
    var name: String
    var configDir: String
    var isDefaultDir: Bool
    var email: String?

    init(_ e: AccountEntry) {
        let a = Account(e)
        profileID = e.id; name = e.name; configDir = a.configDir; isDefaultDir = a.isDefaultDir
        email = e.seat?.email ?? Account.expectedEmail(configDir: a.configDir)
    }
    var workFolder: String { QuickChatSettings.workFolder(profileID) }
}

/// Why an answer didn't come.
enum QuickChatProblem: Equatable {
    case notInstalled
    case notSignedIn(profile: String, id: String)
    /// `claude` ended before the answer was done: its exit and the end of what it wrote.
    case stopped(detail: String)
    /// Claude Code answered with an error of its own.
    case refused(text: String)
    case noProfile
}

struct QuickChatTurn: Identifiable, Equatable {
    enum Phase: Equatable { case waiting, streaming, done, stopped, failed }
    let id = UUID()
    var question: String
    var answer = ""
    var thinking = ""
    /// The model that answered ("Haiku 5.5"), from Claude Code.
    var model = ""
    /// Its thinking setting when asked; nil: off.
    var thinkingTitle: String? = nil
    var started = Date()
    var seconds: Double? = nil
    var phase: Phase = .waiting
    var problem: QuickChatProblem? = nil

    var busy: Bool { phase == .waiting || phase == .streaming }
}

/// The chat's state, drawn by QuickChatViews and driven by its keys. Main thread only.
final class QuickChatModel: ObservableObject {
    @Published var turns: [QuickChatTurn] = []
    @Published var field = ""
    /// A problem shown in the bar, before the chat has a message (Claude Code missing, no profile).
    @Published var barProblem: QuickChatProblem?
    @Published var target: QuickChatTarget?
    @Published var choice: QuickChatModelChoice = .haiku
    @Published var thinking: QuickChatThinking = .off
    /// The full name each choice answered with last ("Haiku 5.5"), for its key.
    @Published var knownModels: [QuickChatModelChoice: String] = [:]
    /// Asks the field to take the keyboard.
    @Published var focusTick = 0
    /// Asks the window to scroll to the end.
    @Published var scrollTick = 0

    var isWindow: Bool { !turns.isEmpty }
    var busy: Bool { turns.last?.busy ?? false }
    var modelTitle: String { knownModels[choice] ?? choice.title }

    // set by QuickChat
    var resolveClaude: (@escaping (String?) -> Void) -> Void = { $0(nil) }
    var hide: () -> Void = {}
    var openProfileSettings: (String) -> Void = { _ in }
    var defaults: () -> QuickChatSettings = { .init() }

    private var process: QuickChatProcess?
    private var processKey = ""
    private var session: String?
    private var pending = "", pendingThinking = ""
    private var flushWork: DispatchWorkItem?
    private var idleTimer: Timer?
    /// A `claude` sits idle this long after an answer, then it's closed; the next message goes on with the session.
    static let idleSeconds: TimeInterval = 10 * 60

    // MARK: keys

    func send() {
        let q = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        guard target != nil else { barProblem = .noProfile; return }
        field = ""
        barProblem = nil
        turns.append(QuickChatTurn(question: q, thinkingTitle: thinking.effort == nil ? nil : thinking.title))
        scrollTick += 1
        ask(q)
    }

    /// Stop: the answer ends where it is; the session goes on with the next message.
    func stop() {
        guard busy, let i = turns.indices.last else { return }
        flush()
        turns[i].phase = .stopped
        turns[i].seconds = Date().timeIntervalSince(turns[i].started)
        process?.stop()
    }

    /// Retry a failed answer, or ask the last question again.
    func again() {
        guard !busy, let i = turns.indices.last else { return }
        turns[i].answer = ""; turns[i].thinking = ""; turns[i].problem = nil; turns[i].phase = .waiting
        turns[i].started = Date(); turns[i].seconds = nil
        turns[i].thinkingTitle = thinking.effort == nil ? nil : thinking.title
        scrollTick += 1
        ask(turns[i].question)
    }

    /// A new chat: the process goes, the session stays in Claude Code's folder, the pickers go back to the defaults.
    func newChat() {
        closeProcess()
        session = nil
        turns = []
        field = ""
        barProblem = nil
        let d = defaults()
        choice = d.model; thinking = d.thinking
        focusTick += 1
    }

    // MARK: talking to Claude Code

    private func ask(_ q: String) {
        guard let target else { fail(.noProfile); return }
        resolveClaude { [weak self] path in
            guard let self else { return }
            guard let path else { self.fail(.notInstalled); return }
            let cmd = QuickChatCommand(claude: path, configDir: target.configDir, isDefaultDir: target.isDefaultDir,
                                       workFolder: target.workFolder, model: self.choice.flag, effort: self.thinking.effort,
                                       resume: self.session)
            // the same `claude` while nothing it runs with changed; a new one goes on with the session
            let key = [path, target.configDir, target.email ?? "", cmd.model, cmd.effort ?? ""].joined(separator: "|")
            if self.process?.isRunning != true || key != self.processKey {
                self.closeProcess()
                let p = QuickChatProcess(cmd)
                p.onEvent = { [weak self, weak p] e in guard let self, let p, p === self.process else { return }; self.handle(e) }
                p.onExit = { [weak self, weak p] status, tail in
                    guard let self, let p, p === self.process else { return }
                    self.exited(status, tail)
                }
                do { try p.start() } catch {
                    self.fail(.stopped(detail: "Claude Code couldn't start: \(error.localizedDescription)")); return
                }
                self.process = p
                self.processKey = key
            }
            self.idleTimer?.invalidate()
            if self.process?.send(q) != true { self.fail(.stopped(detail: "Claude Code didn't take the message.")) }
        }
    }

    private func handle(_ e: QuickChatEvent) {
        guard let i = turns.indices.last else { return }
        switch e {
        case .started(let s, let model):
            session = s
            if !model.isEmpty { setModel(model, turn: i) }
        case .text(let t):
            pending += t
            scheduleFlush()
        case .thinking(let t):
            pendingThinking += t
            scheduleFlush()
        case .message(let text, let model, let error):
            if !model.isEmpty, !model.hasPrefix("<") { setModel(model, turn: i) }
            if error == "authentication_failed", let target {
                turns[i].problem = .notSignedIn(profile: target.name, id: target.profileID)
            } else if let error, turns[i].answer.isEmpty, pending.isEmpty {
                turns[i].problem = .refused(text: text.isEmpty ? error : text)
            }
        case .limit:
            break
        case .done(let isError, let text, let ms, let s):
            flush()
            if !s.isEmpty { session = s }
            guard turns[i].busy else { return }
            turns[i].seconds = ms > 0 ? Double(ms) / 1000 : Date().timeIntervalSince(turns[i].started)
            if isError || turns[i].problem != nil {
                turns[i].phase = .failed
                if turns[i].problem == nil { turns[i].problem = .refused(text: text.isEmpty ? "Claude Code couldn't answer." : text) }
            } else {
                if turns[i].answer.isEmpty { turns[i].answer = text }
                turns[i].phase = .done
            }
            scrollTick += 1
            idleTimer?.invalidate()
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
                guard let self, !self.busy else { return }
                self.closeProcess()
            }
        case .ignored:
            break
        }
    }

    private func setModel(_ id: String, turn i: Int) {
        let name = QuickChatParse.modelName(id)
        turns[i].model = name
        knownModels[choice] = name
    }

    private func exited(_ status: Int32, _ tail: String) {
        process = nil
        processKey = ""
        flush()
        guard let i = turns.indices.last, turns[i].busy else { return }
        var detail = "claude exited with code \(status)"
        if !tail.isEmpty { detail += ": \(tail)" }
        fail(.stopped(detail: detail))
    }

    private func fail(_ p: QuickChatProblem) {
        guard let i = turns.indices.last, turns[i].busy else {
            if turns.isEmpty { barProblem = p }
            return
        }
        // nothing asked yet and Claude Code isn't there: the bar says so and keeps the question
        if p == .notInstalled || p == .noProfile, turns.count == 1, turns[i].answer.isEmpty {
            field = turns[i].question
            turns = []
            barProblem = p
            return
        }
        turns[i].phase = .failed
        turns[i].problem = p
        turns[i].seconds = Date().timeIntervalSince(turns[i].started)
        scrollTick += 1
    }

    private func closeProcess() {
        idleTimer?.invalidate()
        process?.onEvent = { _ in }
        process?.onExit = { _, _ in }
        process?.stop()
        process = nil
        processKey = ""
        pending = ""; pendingThinking = ""
    }

    /// Answer pieces are drawn at most every 50 ms.
    private func scheduleFlush() {
        guard flushWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func flush() {
        flushWork?.cancel(); flushWork = nil
        guard let i = turns.indices.last, !pending.isEmpty || !pendingThinking.isEmpty else { return }
        if turns[i].busy {
            turns[i].answer += pending
            turns[i].thinking += pendingThinking
            if !pending.isEmpty { turns[i].phase = .streaming }
            scrollTick += 1
        }
        pending = ""; pendingThinking = ""
    }

    /// Shut down (the agent quits).
    func shutdown() { closeProcess() }
}

// MARK: - The controller, in the agent

final class QuickChat {
    static let shared = QuickChat()
    /// Posted (distributed) by the Dock icons' menus, cl_audit's window and `--quick-chat`: open it (object: a profile id).
    static let openNote = Notification.Name("local.usage-n-uf.quick-chat-open")

    let model = QuickChatModel()
    private var panel: QuickChatPanel?
    private var host: QuickChatHostingView?
    private var entries: () -> [AccountEntry] = { [] }
    private var settings = QuickChatSettings.load()
    private var claudePath: String?
    private var looking: [(String?) -> Void] = []
    private var observers: [NSObjectProtocol] = []
    private var placed = false

    /// Open: the panel is up, so the agent may keep windows (MenuBarItems leaves its activation policy alone).
    var isOpen: Bool { panel?.isVisible == true }

    func start(entries: @escaping () -> [AccountEntry]) {
        self.entries = entries
        model.choice = settings.model
        model.thinking = settings.thinking
        model.resolveClaude = { [weak self] done in self?.resolveClaude(done) ?? done(nil) }
        model.hide = { [weak self] in self?.hide() }
        model.openProfileSettings = { id in Installer.openSettings(account: id) }
        model.defaults = { [weak self] in self?.settings ?? .init() }
        let dn = DistributedNotificationCenter.default()
        observers.append(dn.addObserver(forName: Self.openNote, object: nil, queue: .main) { [weak self] note in
            self?.open(profile: note.object as? String)
        })
        observers.append(dn.addObserver(forName: QuickChatSettings.changed, object: nil, queue: .main) { [weak self] _ in
            self?.settings = QuickChatSettings.load()
        })
    }

    func toggle() { isOpen ? hide() : open() }

    /// Opens the bar (or the chat as it was) over whatever is in front. `profile`: chat on that one (its menu's item).
    func open(profile: String? = nil) {
        let list = entries()
        let pick = list.first { $0.id == (profile ?? settings.profile) } ?? list.first
        let target = pick.map(QuickChatTarget.init)
        if target != model.target {
            if let t = model.target, let n = target, t.profileID != n.profileID { model.newChat() }   // another profile: a new chat
            model.target = target
        }
        if target != nil, model.barProblem == .noProfile { model.barProblem = nil }
        // the agent runs with no windows while it has no menu bar icon; a panel needs the accessory role (still no Dock icon)
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        let p = panel ?? makePanel()
        if !placed { place(p); placed = true }
        p.orderFrontRegardless()
        p.makeKey()
        model.focusTick += 1
        if claudePath == nil { resolveClaude { _ in } }   // look early, off the main thread
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func shutdown() { model.shutdown() }

    private func makePanel() -> QuickChatPanel {
        let p = QuickChatPanel()
        p.onEscape = { [weak self] in self?.hide() }
        let root = QuickChatRoot(model: model) { [weak self] size in self?.fit(size) }
        let h = QuickChatHostingView(rootView: root)
        p.contentView = h
        panel = p; host = h
        return p
    }

    /// The panel takes the size of what it shows, its top edge staying where it is.
    private func fit(_ size: CGSize) {
        guard let p = panel, size.width > 0, size.height > 0 else { return }
        var f = p.frame
        guard abs(f.width - size.width) > 0.5 || abs(f.height - size.height) > 0.5 else { return }
        let top = f.maxY
        f.size = size
        f.origin.y = top - size.height
        if let vis = p.screen?.visibleFrame, f.minY < vis.minY { f.origin.y = vis.minY }
        p.setFrame(f, display: true)
        p.invalidateShadow()
    }

    /// The first time: centred on the screen with the mouse, its top a quarter of the way down.
    private func place(_ p: QuickChatPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        let w = QuickChatRoot.width
        let top = vis.maxY - vis.height * 0.22
        p.setFrame(NSRect(x: vis.midX - w / 2, y: top - 140, width: w, height: 140), display: false)
    }

    /// Where `claude` is: found once, off the main thread (ClaudeLocator), and again when it's gone.
    private func resolveClaude(_ done: @escaping (String?) -> Void) {
        if let p = claudePath, ClaudeLocator.isExecutable(p) { done(p); return }
        claudePath = nil
        looking.append(done)
        guard looking.count == 1 else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = ClaudeLocator.find()?.path
            DispatchQueue.main.async {
                guard let self else { return }
                self.claudePath = found
                let waiting = self.looking
                self.looking = []
                waiting.forEach { $0(found) }
            }
        }
    }
}

// MARK: - The panel

/// A floating panel that takes the keyboard without bringing the agent (or anything else) forward, on every Space and
/// over full-screen apps.
final class QuickChatPanel: NSPanel {
    var onEscape: () -> Void = {}

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: QuickChatRoot.width, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape() }
}

/// Drags the panel from anywhere that isn't a key or the field.
final class QuickChatHostingView: NSHostingView<QuickChatRoot> {
    override var mouseDownCanMoveWindow: Bool { true }
}
