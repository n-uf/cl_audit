// ClQuick: cl_audit's "Quick chat" items (the menu bar's, the Dock icon's menu) open cl_quick, the one quick chat, on the
// profile's Claude Code folder: cl-quick://chat?folder=<the folder's absolute path, percent-encoded>. With no cl_quick on
// this Mac the item reads "Get cl_quick…" and opens its site. cl_audit has no chat of its own.

import AppKit

enum ClQuick {
    /// The Dock icon's app and its plug-in start nothing themselves: they ask the agent with this note (object: the profile
    /// id), and the agent opens cl_quick.
    static let openNote = AppPlaces.quickChatOpen

    /// Whether an app answers cl_quick's URL scheme; checks give their own answer.
    nonisolated(unsafe) static var installedProbe: () -> Bool = { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "cl-quick://")!) != nil }

    /// cl_quick is on this Mac.
    static var installed: Bool { installedProbe() }

    /// The menu item's words.
    static var itemTitle: String { installed ? "Quick chat" : "Get cl_quick…" }

    // (opening cl_quick, its chat URL and its site, is the app's alone, ClQuickOpen.swift: the Dock tile plug-in compiles
    // this file and must carry no code that opens a URL)
}
