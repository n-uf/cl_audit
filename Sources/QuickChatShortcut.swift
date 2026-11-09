// QuickChatShortcut: the quick chat's shortcut (QuickChat.swift), off until turned on in Settings ▸ General ▸ Quick chat.
//
// It's registered the way macOS's own app shortcuts are (RegisterEventHotKey), so macOS asks for no Accessibility
// permission and it sees no other key. Before it's kept, it's checked against macOS's own shortcuts that use Space
// (Spotlight, Finder search, the input sources) and the Claude app's Quick Entry; registering it also fails, and says so,
// when another app holds it already.

import AppKit
import Carbon.HIToolbox

enum QuickChatShortcut: String, CaseIterable, Codable, Identifiable {
    case optionSpace, controlOptionSpace, optionShiftSpace, controlSpace, commandSpace
    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionSpace: return "⌥Space"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionShiftSpace: return "⌥⇧Space"
        case .controlSpace: return "⌃Space"
        case .commandSpace: return "⌘Space"
        }
    }

    /// Space, with these modifiers (Carbon's flags).
    var keyCode: UInt32 { UInt32(kVK_Space) }
    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return UInt32(optionKey)
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .optionShiftSpace: return UInt32(optionKey | shiftKey)
        case .controlSpace: return UInt32(controlKey)
        case .commandSpace: return UInt32(cmdKey)
        }
    }

    /// The same modifiers as macOS writes them in its own shortcuts' settings (NSEvent's flags).
    var cocoaModifiers: Int {
        switch self {
        case .optionSpace: return 1 << 19
        case .controlOptionSpace: return 1 << 18 | 1 << 19
        case .optionShiftSpace: return 1 << 19 | 1 << 17
        case .controlSpace: return 1 << 18
        case .commandSpace: return 1 << 20
        }
    }

    /// Who else uses it on this Mac, in words, or nil when nothing known does. macOS's own come from its settings
    /// (com.apple.symbolichotkeys; one never changed there is on, with its usual keys).
    func clash(symbolic: [String: Any]? = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")) -> String? {
        // macOS's shortcuts that use Space: id, what it does, its usual modifiers, and whether it's on before anyone
        // changes it (Spotlight and the previous input source are; Finder's search and the next input source aren't)
        let system: [(id: String, does: String, usual: Int, onByDefault: Bool)] = [
            ("64", "opens Spotlight", 1 << 20, true), ("65", "opens a Finder search", 1 << 20 | 1 << 19, false),
            ("60", "switches to the previous input source", 1 << 18, true),
            ("61", "switches to the next input source", 1 << 18 | 1 << 19, false)]
        for s in system {
            if let entry = symbolic?[s.id] as? [String: Any] {
                guard (entry["enabled"] as? NSNumber)?.boolValue ?? false,
                      let params = (entry["value"] as? [String: Any])?["parameters"] as? [NSNumber], params.count >= 3,
                      params[1].intValue == Int(kVK_Space), params[2].intValue == cocoaModifiers else { continue }
                return "\(title) \(s.does) in macOS."
            } else if s.onByDefault, s.usual == cocoaModifiers {
                return "\(title) \(s.does) in macOS."
            }
        }
        // the Claude app's Quick Entry is ⌥Space unless changed there; only worth saying where the app is
        if self == .optionSpace, NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") != nil {
            return "\(title) also opens the Claude app's Quick Entry when that's turned on."
        }
        return nil
    }
}

/// The registered shortcut. Main thread only.
final class QuickChatHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: () -> Void = {}

    /// Registers it (any earlier one goes first). nil: done; otherwise why not, in words.
    func register(_ s: QuickChatShortcut) -> String? {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
                guard let data else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<QuickChatHotKey>.fromOpaque(data).takeUnretainedValue()
                DispatchQueue.main.async { hotKey.onPress() }
                return noErr
            }, 1, &spec, me, &handler)
            guard status == noErr else { return "macOS didn't take it (\(status))." }
        }
        let id = EventHotKeyID(signature: OSType(0x7163_6874), id: 1)    // 'qcht'
        let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return "Another app already uses \(s.title)."
        default: return "macOS didn't take \(s.title) (\(status))."
        }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    var isRegistered: Bool { ref != nil }
}
