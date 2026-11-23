// Runs · the environment a `claude` run gets: never a key, a token, another provider, a base URL or extra headers from the
// caller's own environment (the shell's settings), which would make Claude Code sign in some other way or send its sign-in to
// another host. `ClaudeEnvironment` is the one allow-list for a run of Claude Code itself; `ProviderEnvironment` the list of
// what never reaches one (and what the finder's own programs, the login shell and npm, run without).

import Foundation

/// The environment of a `claude` run: an allow-list. Only who and where the user is, the language, and the network's
/// proxies and certificates come from the caller's environment; nothing else (no key or token, no other provider and its
/// credentials, no model override, no custom headers, no telemetry export, no Node options). Then the folder, the PATH,
/// and Claude Code's non-essential traffic off.
public enum ClaudeEnvironment {
    /// What is taken from the caller's environment, by name (and every `LC_*`).
    public static let passed: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "TERM", "__CF_USER_TEXT_ENCODING",
                                             "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY", "no_proxy",
                                             "ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
                                             // a company's certificates and client certificate (mTLS, a TLS-inspecting proxy)
                                             "CLAUDE_CODE_CERT_STORE", "CLAUDE_CODE_CLIENT_CERT", "CLAUDE_CODE_CLIENT_KEY",
                                             "CLAUDE_CODE_CLIENT_KEY_PASSPHRASE"]

    /// Claude Code's non-essential traffic off: telemetry, error reports, update checks.
    public static let quiet = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"]

    /// A run that leaves nothing in the folder: Claude Code's built-in AGENTS.md plugin otherwise notes the session's id
    /// in plugins/store/ (a once-per-session marker), and an auto-memory folder appears in projects/ (checked against Claude
    /// Code 2.1.318). For a run that keeps no session (the short ask, an incognito chat).
    public static let traceless = ["CLAUDE_CODE_AGENTS_MD_ROWS_EVERY_PROCESS": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"]

    /// The usual install places, after `claude`'s own folder and before the caller's PATH.
    public static let installPlaces = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    /// The environment for `claude` at `claude` (its folder goes first on the PATH: an npm install needs its `node`; nil:
    /// not known) on the folder `configDir` (nil: Claude Code's default folder, so CLAUDE_CONFIG_DIR stays unset).
    /// `traceless`: the run leaves nothing in the folder (`traceless` above).
    public static func make(_ base: [String: String], claude: String? = nil, configDir: String?, traceless: Bool = false) -> [String: String] {
        var env = base.filter { passed.contains($0.key) || $0.key.hasPrefix("LC_") }
        if let configDir { env["CLAUDE_CONFIG_DIR"] = configDir }
        // claude's own folder (never "/" for a claude at the root, never a relative one)
        let own = claude.map { ($0 as NSString).deletingLastPathComponent }.flatMap { $0.hasPrefix("/") && $0 != "/" ? $0 : nil }
        env["PATH"] = path([own].compactMap { $0 } + installPlaces, then: base["PATH"])
        for (k, v) in quiet { env[k] = v }
        if traceless { for (k, v) in Self.traceless { env[k] = v } }
        return env
    }

    /// `first`, then the caller's PATH, as one PATH: absolute entries only (never an empty one, the current folder, nor a
    /// relative one), in order.
    public static func path(_ first: [String], then rest: String?) -> String {
        (first + (rest ?? "").split(separator: ":").map(String.init)).filter { $0.hasPrefix("/") }.joined(separator: ":")
    }
}

public enum ProviderEnvironment {
    /// The variables that would make Claude Code use a key, a token or another provider instead of the folder's claude.ai
    /// sign-in, or send it elsewhere.
    public static let variables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                                   "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                                   "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"]

    /// `base` without them and without CLAUDE_CONFIG_DIR (the caller sets the folder, or leaves it unset for the default one).
    public static func cleaned(_ base: [String: String]) -> [String: String] {
        var env = base
        for k in variables + ["CLAUDE_CONFIG_DIR"] { env[k] = nil }
        return env
    }
}
