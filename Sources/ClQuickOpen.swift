// Opening cl_quick (ClQuick.swift has its item's words and its notice, which the Dock tile plug-in shares): the app's alone,
// so the plug-in, which runs in the Dock's process, carries no code that opens a URL.

import AppKit

extension ClQuick {
    static let site = URL(string: "https://cl-quick.n-uf.com")!

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")

    /// cl_quick's chat on this Claude Code folder (`~` expanded, the whole path percent-encoded as one query value).
    static func chatURL(configDir: String) -> URL? {
        var c = URLComponents()
        c.scheme = "cl-quick"; c.host = "chat"
        let folder = (configDir as NSString).expandingTildeInPath
        // (a query value: only ASCII letters, digits and "-._~/" stay as they are; everything else, a space included, is
        // percent-encoded, so the folder comes back whole)
        guard let v = folder.addingPercentEncoding(withAllowedCharacters: Self.plain) else { return nil }
        c.percentEncodedQuery = "folder=" + v
        return c.url
    }

    /// The item's action: cl_quick's chat on the profile's Claude Code folder (nil: none known), or its site when it isn't
    /// installed.
    static func open(configDir: String?) {
        guard installed else { NSWorkspace.shared.open(site); return }
        if let configDir, let u = chatURL(configDir: configDir) { NSWorkspace.shared.open(u) }
        else { NSWorkspace.shared.open(URL(string: "cl-quick://chat")!) }
    }
}
