// ClQuick: cl_audit's "Quick chat" items (the menu bar's, the Dock icon's menu) open cl_quick, the one quick chat, on the
// profile's Claude Code folder: cl-quick://chat?folder=<the folder's absolute path, percent-encoded>. With no cl_quick on
// this Mac the item reads "Get cl_quick…" and opens its site. cl_audit has no chat of its own.

import AppKit

enum ClQuick {
    static let site = URL(string: "https://cl-quick.n-uf.com")!

    /// The Dock icon's app and its plug-in start nothing themselves: they ask the agent with this note (object: the profile
    /// id), and the agent opens cl_quick.
    static let openNote = Notification.Name("local.usage-n-uf.quick-chat-open")

    /// cl_quick is on this Mac: an app answers its URL scheme.
    static var installed: Bool { NSWorkspace.shared.urlForApplication(toOpen: URL(string: "cl-quick://")!) != nil }

    /// The menu item's words.
    static var itemTitle: String { installed ? "Quick chat" : "Get cl_quick…" }

    /// cl_quick's chat on this Claude Code folder (`~` expanded, the whole path percent-encoded as one query value).
    static func chatURL(configDir: String) -> URL? {
        var c = URLComponents()
        c.scheme = "cl-quick"; c.host = "chat"
        let folder = (configDir as NSString).expandingTildeInPath
        // (a query value: "&", "=", "+" and "#" are encoded too, so the folder comes back whole)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#")
        guard let v = folder.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        c.percentEncodedQuery = "folder=" + v
        return c.url
    }

    /// The item's action: cl_quick's chat on the profile's folder, or its site when it isn't installed.
    static func open(_ e: AccountEntry?) {
        guard installed else { NSWorkspace.shared.open(site); return }
        if let e, let u = chatURL(configDir: e.configDir) { NSWorkspace.shared.open(u) }
        else { NSWorkspace.shared.open(URL(string: "cl-quick://chat")!) }
    }
}
