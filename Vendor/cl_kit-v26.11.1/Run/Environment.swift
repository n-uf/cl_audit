// Runs · the environment a `claude` run gets: never a key, a token, another provider, a base URL or extra headers from the
// caller's own environment (the shell's settings), which would make Claude Code sign in some other way or send its sign-in to
// another host.

import Foundation

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
