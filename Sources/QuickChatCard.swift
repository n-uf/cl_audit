// Settings ▸ General ▸ Quick chat: the quick chat's shortcut (off until turned on, checked for clashes), the profile it
// chats on, its default model and thinking, what it uses and sends, where it keeps things, whether its chats count
// in a profile's sessions and backups, and Remove quick chat data…. Saved to usage-n-uf/quick-chat/settings.json; the
// agent reads it again at once (QuickChat.swift).

import AppKit
import SwiftUI

struct QuickChatCard: View {
    @State private var s = QuickChatSettings.load()
    @State private var profiles = Store.load()
    @State private var mark = Agent.readMark()
    @State private var chats: [QuickChatData.Chats] = []
    @State private var own: Int64 = 0
    @State private var removedWords: String?
    @State private var removing = false
    @Environment(\.face) private var face

    var body: some View {
        SCard(title: "Quick chat", info: "A floating chat over any app: a bar first, a chat window after the first message. Your own Claude Code answers it, signed in to the account a profile has in use and counting against its limits; it sends nothing but your messages. Also in each profile's menu bar and Dock icon menus.") {
            SRow(label: "Shortcut", info: "Opens the quick chat from any app. Off until you turn it on. It's registered the way macOS's own app shortcuts are, so macOS asks for no Accessibility permission and it sees no other key.", first: true, stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        SSwitch(isOn: bind(\.shortcutOn), on: "\(s.shortcut.title) opens it", off: "off")
                        Picker("", selection: bind(\.shortcut)) { ForEach(QuickChatShortcut.allCases) { Text($0.title).tag($0) } }
                            .smallMenu().disabled(!s.shortcutOn)
                    }
                    shortcutNote
                }
            }
            SRow(label: "Profile", info: "The profile the shortcut chats on: on the account it has in use, following it when the profile switches. A profile's own menu bar or Dock icon menu opens the chat on that profile.") {
                Picker("", selection: Binding(get: { s.profile ?? "" }, set: { s.profile = $0.isEmpty ? nil : $0; save() })) {
                    Text("The first, \(profiles.first?.name ?? "none")").tag("")
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                .smallMenu()
            }
            SRow(label: "Model", info: "The model a new chat starts with. Haiku is fast and light on the week. The chat's own picker changes it for one chat; every answer says which model gave it.") {
                Picker("", selection: bind(\.model)) { ForEach(QuickChatModelChoice.allCases) { Text($0.title).tag($0) } }.smallMenu()
            }
            SRow(label: "Thinking", info: "How long Claude thinks before it answers in a new chat. Off answers at once; more thinking uses more of the week. The chat's own picker changes it for one chat.") {
                Picker("", selection: bind(\.thinking)) { ForEach(QuickChatThinking.allCases) { Text($0.title).tag($0) } }.smallMenu()
            }
            SRowLine(text: "Tools: none. A quick chat answers; it doesn't run commands or open files. It sends your messages only, through Claude Code, with Claude Code's own telemetry off; cl_audit sends nothing.")
            SRow(label: "Where it keeps things", info: "Each chat is a Claude Code session, which Claude Code keeps in the profile's own folder and deletes after 30 days by default, like its other sessions. Claude Code runs in quick chat's work folder, so claude --resume there lists the chats.", stacked: true) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chats, id: \.profile) { c in
                        place("Chats · \(c.name): \(c.count), \(Self.size(c.bytes))", path: c.folder)
                    }
                    place("Work folders and settings: \(Self.size(own))", path: QuickChatSettings.folder)
                    Text("Nothing in macOS preferences.").font(.system(size: 10.5)).foregroundStyle(face.muted)
                }
            }
            SRow(label: "Counting", info: "Whether quick chats count in a profile's Sessions card and go into its backups. Off: they're left out, so a backup is only the profile's own work.") {
                SSwitch(isOn: bind(\.counted), on: "in sessions and backups", off: "left out")
            }
            SRow(label: "Remove", info: "Moves every profile's quick chats, the work folders and the settings to the Trash: the chat closes first and the shortcut turns off. A profile's other sessions stay as they are.", stacked: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Button(removing ? "Removing…" : "Remove quick chat data…") { confirmRemove() }
                        .buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize().disabled(removing)
                    if let removedWords {
                        Text(removedWords).font(.system(size: 10.5)).foregroundStyle(face.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear(perform: reload)
    }

    // MARK: the shortcut's words

    @ViewBuilder private var shortcutNote: some View {
        if !s.shortcutOn {
            note("Off: Quick chat in a profile's menu bar or Dock icon menu opens it.", face.muted)
        } else if let state = mark?.quickChat, state != "on" {
            note(state + " Pick another.", face.caution)
        } else if let clash = s.shortcut.clash() {
            note(clash + " Pick another, or change that one's shortcut.", face.caution)
        } else {
            note("Free on this Mac.", face.ok)
        }
    }

    private func note(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    private func place(_ title: String, path: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12)).foregroundStyle(face.soft)
            HStack(spacing: 8) {
                Text(tilde(path.path)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(face.muted)
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Button("Show in Finder") { Self.reveal(path) }.buttonStyle(PillButtonStyle(tint: nil, compact: true)).fixedSize()
            }
        }
    }

    // MARK: keeping it

    private func bind<V>(_ path: WritableKeyPath<QuickChatSettings, V>) -> Binding<V> {
        Binding(get: { s[keyPath: path] }, set: { s[keyPath: path] = $0; save() })
    }

    private func save() {
        try? s.save()
        // the agent registers the shortcut (or says why it can't): read its answer a moment later
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { mark = Agent.readMark() }
    }

    private func reload() {
        s = QuickChatSettings.load()
        profiles = Store.load()
        mark = Agent.readMark()
        let list = profiles
        DispatchQueue.global(qos: .userInitiated).async {
            let c = list.map(QuickChatData.chats)
            let o = QuickChatData.ownBytes()
            DispatchQueue.main.async { chats = c; own = o }
        }
    }

    private func confirmRemove() {
        let count = chats.reduce(0) { $0 + $1.count }
        let bytes = chats.reduce(Int64(0)) { $0 + $1.bytes } + own
        let a = NSAlert()
        a.messageText = "Move quick chat data to the Trash?"
        a.informativeText = "\(count == 1 ? "1 quick chat" : "\(count) quick chats"), the work folders and the settings (\(Self.size(bytes))). The chat closes and the shortcut turns off. A profile's other sessions stay as they are; you can bring these back from the Trash."
        a.addButton(withTitle: "Move to Trash")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        removing = true
        let list = profiles
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = QuickChatData.remove(list)
            DispatchQueue.main.async {
                removing = false
                removedWords = failed.isEmpty ? "Moved to the Trash. The quick chat starts fresh the next time you open it."
                    : "Couldn't move \(failed.joined(separator: ", ")) to the Trash."
                reload()
            }
        }
    }

    static func size(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    /// Shows the folder in Finder, or the nearest one above it that exists (quick chat makes them when it first runs).
    static func reveal(_ url: URL) {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u = u.deletingLastPathComponent() }
        NSWorkspace.shared.open(u)
    }
}
